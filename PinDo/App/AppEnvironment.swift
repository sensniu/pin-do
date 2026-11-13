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
    let navigation = AppNavigation()
    let analytics = AnalyticsModel()
    let login = LoginItemController(canConfigure:
        !AppConfiguration.isDevelopment && !AppConfiguration.isPrototype &&
        Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path == "/Applications")
    @Published private(set) var editing = false
    @Published private(set) var canUndoCompletion = false
    @Published private(set) var dataActionBusy = false
    @Published private(set) var backupRevision = 0
    let appearance = AppearanceSettings()
    let sync = SyncCoordinator()
    // Transient development preview; Release always follows the system.
    @Published var previewScheme: ColorScheme?
    private(set) var repository: TodoRepository?
    private(set) var paths: AppPaths?
    private var boardObservers: Set<AnyCancellable> = []
    var managingProjects: Bool { navigation.panel == .projects }
    var canUseBoardLayout: Bool { board != nil && !editing && !dataActionBusy && navigation.mode == .board && navigation.panel == nil }

    init() {
        for key in ["projects.sidebar.pinned", "projects.sidebar.width"] { UserDefaults.standard.removeObject(forKey: key) }
        sync.showSettings = { [weak self] issues in self?.presentSettings(.sync, issues: issues) }
        open()
    }

    func open() {
        guard repository == nil, !opening else { return }
        if AppConfiguration.isPrototype {
            let board = BoardModel(items: PrototypeData.items(now: .now), projects: PrototypeData.projects)
            self.board = board; bindBoard(board)
            analytics.configure { [weak board] in
                guard let board else { throw AnalyticsFailure.unavailable }
                return AnalyticsInput(items: board.items, projects: board.projects)
            }
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
                repository.onBackupSuccess = { [weak self] in self?.backupRevision += 1 }
                self.repository = repository; self.board = board; startupError = nil
                bindBoard(board)
                analytics.configure { [weak repository] in
                    guard let repository else { throw AnalyticsFailure.unavailable }
                    return try await repository.analyticsInput()
                }
                repository.onContentsChange = { [weak self] in self?.analytics.invalidate() }
                sync.didReceive = { [weak self] in
                    guard let self else { return }
                    self.analytics.invalidate()
                    if !self.managingProjects { self.board?.refreshFromSync() }
                }
                sync.attach(repository)
            } catch {
                startupError = error.localizedDescription; board = nil
            }
            opening = false
        }
    }

    private func bindBoard(_ board: BoardModel) {
        boardObservers.removeAll()
        board.$draft.map { $0 != nil }.removeDuplicates().sink { [weak self] in self?.editing = $0 }.store(in: &boardObservers)
        board.$undo.map { $0 != nil }.removeDuplicates().sink { [weak self] in self?.canUndoCompletion = $0 }.store(in: &boardObservers)
    }
    func setWorkspace(_ mode: WorkspaceMode) {
        guard !dataActionBusy, navigation.panel == nil, board?.flushDraft() != false else { return }
        navigation.mode = mode
        if mode == .overview { navigation.overviewReturnAvailable = false }
        if mode == .overview { if AppConfiguration.isPrototype { analytics.invalidate() }; analytics.activate(scope: board?.selectedScope ?? .all) }
        else { analytics.deactivate() }
    }
    func presentSettings(_ section: SettingsSection? = nil, issues: Bool = false) {
        guard !dataActionBusy, board?.flushDraft() != false else { return }
        if navigation.present(.settings, section: section) { navigation.showSyncIssues = issues; login.refresh() }
    }
    func presentProjects(create: Bool = false) {
        guard !dataActionBusy, board != nil else { return }
        guard !editing else { notice = "请先保存或取消当前待办，再管理项目。"; return }
        if navigation.present(.projects) { navigation.createProject = create }
    }
    func presentHelp(shortcuts: Bool = false) {
        if navigation.present(.help) { navigation.showShortcuts = shortcuts }
    }
    func newTodo() {
        guard !dataActionBusy, board != nil, navigation.present(nil) else { return }
        navigation.overviewReturnAvailable = false
        setWorkspace(.board); board?.beginNew()
    }
    func editFromOverview(_ item: TodoItem) {
        guard let board else { return }
        if board.draft != nil { setWorkspace(.board); notice = "请先保存或取消当前待办，再打开其它事项。"; return }
        do {
            let value = AppConfiguration.isPrototype ? board.items.first { $0.id == item.id } : try repository?.storedItem(item.id)
            guard let stored = value, stored.status == .active else { analytics.invalidate(); return }
            setWorkspace(.board); board.refreshFromSync()
            guard navigation.mode == .board else { return }
            if !board.selectedScope.includes(stored) { board.selectScope(stored.projectID.map(BoardScope.project) ?? .unassigned) }
            board.edit(stored)
            navigation.overviewReturnAvailable = true
        } catch { notice = error.localizedDescription }
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
        guard !dataActionBusy, let repository, board?.flushDraft() == true else { return }
        dataActionBusy = true; defer { dataActionBusy = false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PinDo-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).pindobackup"
        panel.allowedContentTypes = [UTType(filenameExtension: "pindobackup") ?? .data]
        panel.title = "导出 PinDo 备份"
        panel.message = "包含当前事项、完成与放弃结果、必要同步候选及编辑草稿。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try repository.archive()
            let data = try BackupCodec.encode(archive)
            try data.write(to: url, options: .atomic)
            notice = "备份已导出。可以将它另存到其他磁盘，保护本机故障时的数据。"
        } catch { notice = "导出未完成：\(error.localizedDescription)" }
    }

    func importBackup() {
        guard !dataActionBusy, let repository else { return }
        guard sync.beginMaintenance() else { notice = "请等待当前同步完成，再恢复备份。"; return }
        dataActionBusy = true
        defer { dataActionBusy = false; sync.endMaintenance() }
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
            confirm.informativeText = merging ? "保留当前数据，合并备份中的事项与必要候选，不会用旧备份清空云端。操作前保留安全副本，验证成功后自动回收。" : "当前本地事项将替换为备份中的内容。操作前保留安全副本，验证成功后自动回收。"
            confirm.addButton(withTitle: merging ? "合并备份" : "恢复并替换本地数据")
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
            bindBoard(board); analytics.scope = board.selectedScope; analytics.invalidate()
            sync.attach(repository)
            notice = "备份已\(merging ? "合并" : "恢复")。最新恢复备份验证成功后，会回收本次操作的临时安全副本。"
        } catch { notice = "恢复未完成，原数据已保留：\(error.localizedDescription)" }
    }

    func prepareToQuit() async -> Bool {
        guard navigation.present(nil) else { return false }
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

