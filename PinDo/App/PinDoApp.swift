import SwiftUI

@main
struct PinDoApp: App {
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate

    var body: some Scene {
        Window(AppConfiguration.windowTitle, id: AppConfiguration.windowID) {
            Group {
                if let board = environment.board {
                    WorkspaceView(model: board, managingProjects: $environment.managingProjects, managingAppearance: $environment.managingAppearance).id(ObjectIdentifier(board))
                } else if environment.opening {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("正在检查并打开本地数据…").font(.headline)
                    }
                    .frame(minWidth: 760, minHeight: 560)
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 36))
                        Text("未能打开本地数据").font(.title2)
                        Text(environment.startupError ?? "请重试。")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                        Text("现有文件已保留，应用不会自动创建空数据覆盖它们。")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("打开数据文件夹") { environment.showDataFolder() }
                            Button("重试") { environment.open() }
                        }
                    }
                    .frame(minWidth: 760, minHeight: 560).padding(30)
                }
            }
            .environmentObject(environment.appearance)
            .environmentObject(environment.sync)
            .onChange(of: scenePhase) { _, phase in if phase == .active { environment.sync.requestSync() } }
            .preferredColorScheme(environment.previewScheme)
            .onAppear { delegate.environment = environment }
            .onChange(of: environment.managingProjects) { _, open in
                if !open { environment.board?.refreshFromSync() }
            }
            .alert("PinDo", isPresented: Binding(
                get: { environment.notice != nil },
                set: { if !$0 { environment.notice = nil } }
            )) {
                Button("知道了") { environment.notice = nil }
            } message: { Text(environment.notice ?? "") }
        }
        .defaultSize(width: 1180, height: 850)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("外观设置…") { environment.managingAppearance = true }
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
                Button("新增待办") { environment.board?.beginNew() }
                    .keyboardShortcut("n")
                    .disabled(environment.board == nil || environment.board?.draft != nil || environment.managingProjects || environment.managingAppearance)
            }
            CommandMenu("白板") {
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
                Button("导出备份…") { environment.exportBackup() }
                    .disabled(environment.repository == nil)
                Button("从备份恢复…") { environment.importBackup() }
                    .disabled(environment.repository == nil)
                Divider()
                Button("打开数据文件夹") { environment.showDataFolder() }
                    .disabled(environment.paths == nil)
            }
        }
    }
}

