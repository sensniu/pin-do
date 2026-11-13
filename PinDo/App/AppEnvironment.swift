import AppKit
import SwiftUI
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var board: BoardModel?
    @Published private(set) var startupError: String?
    @Published private(set) var opening = false
    @Published var notice: String?
    @Published var managingProjects = false
    @Published var managingAppearance = false
    let appearance = AppearanceSettings()
    let sync = SyncCoordinator()
    // Transient development preview; Release always follows the system.
    @Published var previewScheme: ColorScheme?
    private(set) var repository: TodoRepository?
    private(set) var paths: AppPaths?

    init() {
        for key in ["projects.sidebar.pinned", "projects.sidebar.width"] { UserDefaults.standard.removeObject(forKey: key) }
        open()
    }

    func open() {
        guard repository == nil, !opening else { return }
        if AppConfiguration.isPrototype {
            board = BoardModel(items: PrototypeData.items(now: .now), projects: PrototypeData.projects)
            return
        }
        opening = true; startupError = nil
        Task { [self] in
            do {
                let paths = try AppPaths.application(isDevelopment: AppConfiguration.isDevelopment)
                self.paths = paths
                let version = AppConfiguration.version
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try TodoRepository.prepareForOpening(paths: paths, appVersion: version)
                }.value
                let repository = TodoRepository(paths: paths, appVersion: version, prepared: prepared)
                try repository.prepareCompactStorage()
                let data = try repository.loadBoardData()
                let board = BoardModel(items: data.items, projects: data.projects, persistence: repository)
                self.configureScope(board)
                board.draft = try repository.loadDraft()
                board.refreshFromSync()
                repository.onBackupFailure = { [weak self] message in
                    self?.notice = "待办已保存，但自动备份未完成：\(message)"
                }
                self.repository = repository; self.board = board; startupError = nil
                sync.didReceive = { [weak self] in
                    guard let self, !self.managingProjects else { return }
                    self.board?.refreshFromSync()
                }
                sync.attach(repository)
            } catch {
                startupError = error.localizedDescription; board = nil
            }
            opening = false
        }
    }

    private func configureScope(_ board: BoardModel) {
        let saved = UserDefaults.standard.string(forKey: "workspace.lastScope") ?? "all"
        let scope: BoardScope = saved == "unassigned" ? .unassigned : UUID(uuidString: saved).map(BoardScope.project) ?? .all
        board.restoreScope(scope)
        board.scopeChanged = { value in
            let key = value.projectID?.uuidString ?? (value == .unassigned ? "unassigned" : "all")
            UserDefaults.standard.set(key, forKey: "workspace.lastScope")
        }
    }

    func showDataFolder() {
        guard let paths else { return }
        NSWorkspace.shared.open(paths.root)
    }

    func exportBackup() {
        guard let repository, board?.flushDraft() == true else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PinDo-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).pindobackup"
        panel.allowedContentTypes = [UTType(filenameExtension: "pindobackup") ?? .data]
        panel.title = "导出 PinDo 备份"
        panel.message = "包含当前待办、完成与放弃记录、操作历史及编辑草稿。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try repository.archive()
            let data = try BackupCodec.encode(archive)
            try data.write(to: url, options: .atomic)
            notice = "备份已导出。可以将它另存到其他磁盘，保护本机故障时的数据。"
        } catch { notice = "导出未完成：\(error.localizedDescription)" }
    }

    func importBackup() {
        guard let repository else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "pindobackup") ?? .data]
        panel.directoryURL = paths?.backups
        panel.title = "从备份恢复 PinDo"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try BackupCodec.decode(Data(contentsOf: url))
            let confirm = NSAlert()
            let merging = try repository.syncState() != nil
            confirm.messageText = merging ? "合并这份备份？" : "恢复这份备份？"
            confirm.informativeText = merging ? "已绑定同步：保留当前数据，合并备份中的事项与历史；不同内容保留为候选。不会用旧备份清空云端。合并前会保存安全备份。" : "当前待办和历史记录将替换为备份中的内容。恢复前会在数据目录保存一份安全备份。"
            confirm.addButton(withTitle: "恢复")
            confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            guard board?.flushDraft() == true else { return }
            try repository.restore(archive)
            board?.retireAfterRestore()
            let data = try repository.loadBoardData()
            let board = BoardModel(items: data.items, projects: data.projects, persistence: repository)
            configureScope(board)
            board.draft = try repository.loadDraft()
            board.refreshFromSync()
            self.board = board
            sync.attach(repository)
            notice = "备份已恢复。恢复前的数据位于 Backups/before-restore.pindobackup。"
        } catch { notice = "恢复未完成，原数据已保留：\(error.localizedDescription)" }
    }

    func prepareToQuit() async -> Bool {
        guard board?.flushDraft() != false else { return false }
        guard let repository else { return true }
        do {
            try await repository.createAutomaticBackupNow()
            return true
        } catch {
            notice = "退出前备份未完成，待办已保存：\(error.localizedDescription)"
            let alert = NSAlert()
            alert.messageText = "待办已保存，但备份未完成"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "返回应用")
            alert.addButton(withTitle: "仍然退出")
            return alert.runModal() == .alertSecondButtonReturn
        }
    }
}

