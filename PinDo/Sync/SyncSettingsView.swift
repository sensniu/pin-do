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
    init(_ connection: SyncConnection?) {
        server = connection?.server ?? "https://dav.jianguoyun.com/dav/"
        directory = connection?.directory ?? ""
        username = connection?.username ?? ""
    }
    var connection: SyncConnection { SyncConnection(server: server, directory: directory, username: username) }
    var valid: Bool { (try? connection.root) != nil }
}

struct SyncSettingsView: View {
    @ObservedObject var sync: SyncCoordinator
    @StateObject private var draft: SyncSettingsDraft
    @Environment(\.dismiss) private var dismiss
    init(sync: SyncCoordinator) {
        self.sync = sync
        _draft = StateObject(wrappedValue: SyncSettingsDraft(sync.configuration))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("WebDAV 同步").font(.title2.weight(.semibold))
            Text("连接后，更改会自动同步。离线时先保存在本机，也可以随时点击白板上的刷新按钮。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("服务器地址", text: $draft.server)
                TextField("同步目录（必填）", text: $draft.directory, prompt: Text("例如 PinDo，需手动填写"))
                TextField("账号", text: $draft.username)
                SecureField(sync.configuration == nil ? "应用授权密码" : "新密码（留空保留原密码）", text: $draft.password)
            }.textFieldStyle(.roundedBorder)
            Text("使用专用目录；多台设备填写同一个目录。目录不存在时会尝试创建，父目录需已存在。连接会合并其中的 PinDo 数据，不会用本机数据覆盖整个目录。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Image(systemName: sync.enabled ? "arrow.triangle.2.circlepath" : "pause.circle")
                Text(sync.message)
                Spacer()
                if let date = sync.lastSuccess { Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
            }.font(.callout)
            if let error = draft.error ?? sync.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                if sync.enabled { Button("暂停自动同步") { sync.pause() }.disabled(sync.busy) }
                if !sync.conflicts.isEmpty {
                    Button("处理冲突（\(sync.conflicts.count)）") { dismiss(); sync.showingConflicts = true }
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(draft.connecting)
                Button(draft.connecting ? "正在连接…" : "连接并合并") {
                    draft.connecting = true; draft.error = nil
                    Task {
                        do { try await sync.connect(draft.connection, password: draft.password); draft.password = "" }
                        catch { draft.error = error.localizedDescription }
                        draft.connecting = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(!draft.valid || draft.connecting || sync.busy)
            }
        }.padding(24).frame(width: 550)
    }
}

struct SyncRefreshButton: View {
    @ObservedObject var sync: SyncCoordinator
    var body: some View {
        Button {
            if !sync.enabled { sync.showingSettings = true }
            else { sync.requestSync() }
        } label: {
            HStack(spacing: 4) {
                if sync.busy { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
                else { Image(systemName: sync.error == nil ? "arrow.clockwise" : "exclamationmark.arrow.triangle.2.circlepath").font(.system(size: 15)) }
                if !sync.conflicts.isEmpty { Text("\(sync.conflicts.count)").font(.caption) }
            }.frame(minWidth: 30, minHeight: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(sync.busy)
            .help(sync.error ?? (sync.message + " · 点击同步，右键设置"))
            .accessibilityLabel("同步：" + sync.message)
            .contextMenu {
                Button("立即同步") { sync.requestSync() }.disabled(!sync.enabled || sync.busy)
                Button("同步设置…") { sync.showingSettings = true }
                Button("处理冲突…") { sync.showingConflicts = true }.disabled(sync.conflicts.isEmpty)
            }
    }
}

struct SyncConflictsView: View {
    @ObservedObject var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("同步冲突").font(.title2.weight(.semibold))
            Text("不同设备修改了同一内容。所有候选已保存；选择一个版本后，其他版本仍保留在同步历史中。")
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
            }.frame(minHeight: 240, maxHeight: 440)
            if let error = sync.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 640)
    }
}

struct SyncMenuItems: View {
    @ObservedObject var sync: SyncCoordinator
    var body: some View {
        Group {
            Button("立即同步") { sync.requestSync() }.disabled(!sync.enabled || sync.busy)
            Button("WebDAV 同步设置…") { sync.showingSettings = true }
            Button("处理同步冲突…") { sync.showingConflicts = true }
        }
    }
}
