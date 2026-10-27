import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var board: BoardModel?
    @Published private(set) var startupError: String?
    @Published private(set) var opening = false
    @Published var notice: String?
    private(set) var repository: TodoRepository?
    private(set) var paths: AppPaths?

    init() { open() }

    func open() {
        guard repository == nil, !opening else { return }
        if AppConfiguration.isPrototype {
            board = BoardModel(items: PrototypeData.items(now: .now), projects: PrototypeData.projects)
            return
        }
        opening = true; startupError = nil
        Task {
            do {
                let paths = try AppPaths.application(isDevelopment: AppConfiguration.isDevelopment)
                self.paths = paths
                let version = AppConfiguration.version
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try TodoRepository.prepareForOpening(paths: paths, appVersion: version)
                }.value
                let repository = TodoRepository(paths: paths, appVersion: version, prepared: prepared)
                let data = try repository.loadBoardData()
                let board = BoardModel(items: data.items, projects: data.projects, persistence: repository)
                board.draft = try repository.loadDraft()
                repository.onBackupFailure = { [weak self] message in
                    self?.notice = "待办已保存，但自动备份未完成：\(message)"
                }
                self.repository = repository; self.board = board; startupError = nil
            } catch {
                startupError = error.localizedDescription; board = nil
            }
            opening = false
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
            confirm.messageText = "恢复这份备份？"
            confirm.informativeText = "当前待办和历史记录将替换为备份中的内容。恢复前会在数据目录保存一份安全备份。"
            confirm.addButton(withTitle: "恢复")
            confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            guard board?.flushDraft() == true else { return }
            try repository.restore(archive)
            board?.retireAfterRestore()
            let data = try repository.loadBoardData()
            let board = BoardModel(items: data.items, projects: data.projects, persistence: repository)
            board.draft = try repository.loadDraft()
            self.board = board
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

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var environment: AppEnvironment?
    private var quitting = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, let environment else { return quitting ? .terminateLater : .terminateNow }
        quitting = true
        Task {
            let canQuit = await environment.prepareToQuit()
            quitting = false
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }
}

