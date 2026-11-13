import SwiftUI

@main
struct PinDoApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands { PinDoCommands(environment: delegate.environment, lifecycle: delegate) }
    }
}

struct PinDoCommands: Commands {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var navigation: AppNavigation
    @ObservedObject private var sync: SyncCoordinator
    let lifecycle: ApplicationDelegate
    init(environment: AppEnvironment, lifecycle: ApplicationDelegate) {
        self.environment = environment; navigation = environment.navigation; sync = environment.sync; self.lifecycle = lifecycle
    }
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("退出 PinDo…") { lifecycle.quit.confirmFromMenu() }.keyboardShortcut("q")
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { environment.presentSettings() }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("新建待办") { lifecycle.showBoard(); environment.newTodo() }.keyboardShortcut("n").disabled(environment.board == nil || environment.dataActionBusy)
            Divider()
            Button(sync.primaryActionTitle) { sync.performPrimaryAction() }.disabled(sync.busy || environment.repository == nil)
            Button("同步状态…") { environment.presentSettings(.sync) }
            Divider()
            Menu("备份与恢复") {
                Button("导出备份…") { lifecycle.showBoard(); environment.exportBackup() }
                Button("从备份恢复…") { lifecycle.showBoard(); environment.importBackup() }.disabled(sync.busy)
            }.disabled(environment.repository == nil || environment.dataActionBusy)
        }
        CommandGroup(after: .undoRedo) {
            Button("撤回最近完成") { environment.board?.undoCompletion() }.disabled(!environment.canUndoCompletion || navigation.panel != nil)
        }
        CommandGroup(before: .toolbar) {
            Button { lifecycle.showBoard(); environment.setWorkspace(.board) } label: { Label("白板", systemImage: navigation.mode == .board ? "checkmark" : "square.grid.2x2") }
                .disabled(environment.board == nil || navigation.panel != nil)
            Button { lifecycle.showBoard(); environment.setWorkspace(.overview) } label: { Label("概览", systemImage: navigation.mode == .overview ? "checkmark" : "chart.bar") }
                .disabled(environment.board == nil || navigation.panel != nil)
            Divider()
            Button("放大白板") { environment.board?.zoomBoard(by: 1.2) }.disabled(!environment.canUseBoardLayout)
            Button("缩小白板") { environment.board?.zoomBoard(by: 1 / 1.2) }.disabled(!environment.canUseBoardLayout)
            Button("适应白板") { environment.board?.fitBoard() }.keyboardShortcut("0").disabled(!environment.canUseBoardLayout)
            Divider()
            Button("重新排列当前白板") { environment.board?.reorderBoard() }.disabled(!environment.canUseBoardLayout)
        }
        CommandMenu("项目") {
            Button("新建项目…") { environment.presentProjects(create: true) }.disabled(environment.board == nil || environment.editing || environment.dataActionBusy)
            Button("管理项目…") { environment.presentProjects() }.disabled(environment.board == nil || environment.editing || environment.dataActionBusy)
        }
        CommandGroup(replacing: .help) {
            Button("使用说明…") { environment.presentHelp() }
            Button("快捷键说明…") { environment.presentHelp(shortcuts: true) }
        }
        #if DEBUG
        CommandMenu("开发预览") {
            Button("跟随系统") { environment.previewScheme = nil }
            Button("浅色外观") { environment.previewScheme = .light }
            Button("深色外观") { environment.previewScheme = .dark }
            Divider()
            Button("紧凑窗口") { lifecycle.window?.setContentSize(NSSize(width: 760, height: 560)) }
            Button("屏幕默认大小") { lifecycle.resetWindowSize() }
        }
        #endif
    }
}
