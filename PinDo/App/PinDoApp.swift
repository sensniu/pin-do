import SwiftUI

@main
struct PinDoApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate

    var body: some Scene {
        // AppKit owns the single board window so login launches never create a visible scene.
        Settings { EmptyView() }
            .commands { PinDoCommands(environment: delegate.environment, lifecycle: delegate) }
    }
}

struct PinDoCommands: Commands {
    @ObservedObject var environment: AppEnvironment
    let lifecycle: ApplicationDelegate
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("退出 PinDo…") { lifecycle.quit.confirmFromMenu() }.keyboardShortcut("q")
        }
        CommandGroup(replacing: .appSettings) {
            Button("外观设置…") { lifecycle.showBoard(); environment.managingAppearance = true }
                .keyboardShortcut(",")
                .disabled(environment.board == nil || environment.board?.draft != nil || environment.managingProjects || environment.managingAppearance)
        }
        #if DEBUG
        CommandMenu("开发预览") {
            Button("跟随系统") { environment.previewScheme = nil }
            Button("浅色外观") { environment.previewScheme = .light }
            Button("深色外观") { environment.previewScheme = .dark }
            Divider()
            Button("紧凑窗口") { NSApp.keyWindow?.setContentSize(NSSize(width: 760, height: 560)) }
            Button("默认窗口") { NSApp.keyWindow?.setContentSize(NSSize(width: 1180, height: 850)) }
        }
        #endif
        CommandGroup(replacing: .newItem) {
            Button("新增待办") { lifecycle.showBoard(); environment.board?.beginNew() }
                .keyboardShortcut("n")
                .disabled(environment.board == nil || environment.board?.draft != nil || environment.managingProjects || environment.managingAppearance)
        }
        CommandMenu("白板") {
            Button("重新整理白板") { environment.board?.reorderBoard() }
                .disabled(environment.board == nil || environment.board?.draft != nil || environment.managingProjects || environment.managingAppearance)
            Button("适应白板") { environment.board?.fitBoard() }
                .keyboardShortcut("0")
                .disabled(environment.board == nil || environment.board?.draft != nil || environment.managingProjects || environment.managingAppearance)
        }
        CommandMenu("项目") {
            Button("项目管理…") { environment.managingProjects = true }
                .disabled(environment.board == nil || environment.board?.draft != nil || environment.managingProjects || environment.managingAppearance)
        }
        CommandMenu("数据") {
            SyncMenuItems(sync: environment.sync)
                .disabled(environment.repository == nil || environment.board?.draft != nil || environment.managingProjects || environment.managingAppearance)
            Divider()
            Button("导出备份…") { lifecycle.showBoard(); environment.exportBackup() }
                .disabled(environment.repository == nil)
            Button("从备份恢复…") { lifecycle.showBoard(); environment.importBackup() }
                .disabled(environment.repository == nil)
            Divider()
            Button("打开数据文件夹") { environment.showDataFolder() }
                .disabled(environment.paths == nil)
        }
    }
}
