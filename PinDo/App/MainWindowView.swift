import SwiftUI

struct MainWindowView: View {
    @ObservedObject var environment: AppEnvironment

    var body: some View {
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
        .preferredColorScheme(environment.previewScheme)
        .onChange(of: environment.managingProjects) { _, open in
            if !open { environment.board?.refreshFromSync() }
        }
        .alert("PinDo", isPresented: Binding(
            get: { environment.notice != nil },
            set: { if !$0 { environment.notice = nil } }
        )) {
            Button("知道了") { environment.notice = nil }
        } message: { Text(environment.notice ?? "") }
        .frame(minWidth: 760, minHeight: 560)
    }
}
