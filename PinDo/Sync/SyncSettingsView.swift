import SwiftUI
import Combine

@MainActor
final class SyncSettingsDraft: ObservableObject {
    @Published var server: String
    @Published var directory: String
    @Published var username: String
    @Published var password = ""
    @Published var error: String?
    @Published var connecting = false
    @Published var connectionExpanded = false
    @Published var issuesExpanded = false
    private var original: SyncConnection
    init(_ connection: SyncConnection?) {
        let value = connection ?? SyncConnection(server: "https://dav.jianguoyun.com/dav/", directory: "", username: "")
        original = value; server = value.server; directory = value.directory; username = value.username
    }
    var connection: SyncConnection { SyncConnection(server: server, directory: directory, username: username) }
    var valid: Bool { (try? connection.root) != nil }
    var changed: Bool { connection != original || !password.isEmpty }
    func reset() { server = original.server; directory = original.directory; username = original.username; password = ""; error = nil }
    func accept() { original = connection; password = "" }
}

struct SyncRefreshButton: View {
    @ObservedObject var sync: SyncCoordinator
    var body: some View {
        HStack(spacing: 2) {
            Button { sync.performPrimaryAction() } label: {
                if sync.busy { ProgressView().controlSize(.small).frame(width: 28, height: 30) }
                else { Image(systemName: sync.configuration == nil ? "cloud" : !sync.enabled ? "play.circle" : sync.error == nil ? "arrow.clockwise" : "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 15)).frame(width: 28, height: 30).contentShape(Rectangle()) }
            }.buttonStyle(.plain).disabled(sync.busy).help(sync.primaryActionTitle).accessibilityLabel(sync.primaryActionTitle)
            Menu {
                Button(sync.primaryActionTitle) { sync.performPrimaryAction() }.disabled(sync.busy)
                Button("同步状态…") { sync.showSettings?(false) }
                if !sync.conflicts.isEmpty { Button("处理冲突（\(sync.conflicts.count)）…") { sync.showSettings?(true) } }
                if sync.error != nil { Button("查看同步问题…") { sync.showSettings?(true) } }
                if sync.enabled { Divider(); Button("暂停同步") { sync.pause() }.disabled(sync.busy) }
            } label: {
                HStack(spacing: 2) {
                    if !sync.conflicts.isEmpty { Text("\(sync.conflicts.count)").font(.caption) }
                    Image(systemName: "chevron.down").font(.system(size: 9)).frame(width: 14, height: 30)
                }
            }.menuStyle(.borderlessButton).fixedSize().help("同步状态与设置").accessibilityLabel("同步状态与设置")
        }
    }
}

struct SyncConflictsView: View {
    @ObservedObject var sync: SyncCoordinator
        var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("同步冲突").font(.title2.weight(.semibold))
            Text("不同设备修改了同一内容。未解决的候选会保留；采用某个版本后，已解决的旧候选会清理。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if sync.conflicts.isEmpty { Text("没有待处理冲突").padding() }
                    if !sync.retainedItems.isEmpty {
                        DisclosureGroup("已结束事项的保留内容（\(sync.retainedItems.count)）") {
                            ForEach(sync.retainedItems) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title).font(.headline)
                                    Text(item.notes).textSelection(.enabled)
                                    Text(item.status == .completed ? "已完成" : item.status == .abandoned ? "已放弃" : "状态待确认").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            }
                        }
                    }
                    ForEach(sync.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(sync.title(for: conflict.entity) + " · " + conflict.fieldLabel).font(.headline)
                            ForEach(conflict.candidates) { candidate in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(sync.describe(candidate)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    Button("采用此版本") { sync.resolve(conflict, candidate: candidate) }
                                }.padding(12).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }.frame(minHeight: 180, maxHeight: 330)
            if let error = sync.error { Text(error).foregroundStyle(.red).font(.caption) }
        }
    }
}
