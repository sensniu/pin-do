import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var navigation: AppNavigation
    @ObservedObject private var appearanceSettings: AppearanceSettings
    @StateObject private var colors: AppearanceDraft
    @StateObject private var connection: SyncSettingsDraft

    init(environment: AppEnvironment) {
        self.environment = environment; navigation = environment.navigation; appearanceSettings = environment.appearance
        _colors = StateObject(wrappedValue: AppearanceDraft(environment.appearance.palette))
        _connection = StateObject(wrappedValue: SyncSettingsDraft(environment.sync.configuration))
    }
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("设置").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { navigation.present(nil) }.keyboardShortcut(.cancelAction)
            }
            Picker("设置分类", selection: Binding(get: { navigation.section }, set: { environment.presentSettings($0) })) {
                ForEach(SettingsSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch navigation.section {
                    case .general: GeneralSettingsPane(login: environment.login)
                    case .appearance: appearance
                    case .sync: SyncSettingsPane(sync: environment.sync, draft: connection, showIssues: navigation.showSyncIssues, available: environment.repository != nil)
                    case .data: DataSettingsPane(environment: environment)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
            }
        }.padding(24).frame(width: 660, height: 530)
            .interactiveDismissDisabled()
            .onAppear { installGuard() }
            .onDisappear { navigation.removeGuard(owner: colors.guardID) }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("便利贴颜色").font(.headline)
            Text("界面跟随系统深浅色；无截止时间为灰色。提前七天开始渐变，逾期使用固定颜色。")
                .font(.callout).foregroundStyle(.secondary)
            colorRow("渐变起点", value: $colors.start)
            colorRow("渐变终点", value: $colors.end)
            colorRow("逾期颜色", value: $colors.overdue)
            let palette = colors.palette ?? environment.appearance.palette
            HStack(spacing: 10) {
                preview("较远", color: palette.start)
                preview("临近截止", color: palette.end)
                preview("已逾期", color: palette.overdue)
            }
            if colors.palette == nil { Text("请输入有效的六位颜色值，例如 #A78BDF。").font(.caption).foregroundStyle(.red) }
            HStack {
                Button("恢复默认") { colors.reset() }
                Spacer()
                Button("取消修改") { resetColors() }
                Button("保存颜色") { _ = saveColors() }.buttonStyle(.borderedProminent).disabled(colors.palette == nil || colors.palette == environment.appearance.palette)
            }
            Text("项目名称和项目标签颜色请在“项目 → 管理项目…”中修改。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func colorRow(_ title: String, value: Binding<String>) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(get: { color(ProjectColor(hex: value.wrappedValue) ?? NotePalette.standard.start) }, set: {
                if let rgb = NSColor($0).usingColorSpace(.sRGB) { value.wrappedValue = ProjectColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent).hex }
            }), supportsOpacity: false)
            TextField("#RRGGBB", text: value).font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 100).accessibilityLabel(title + "颜色值")
        }
    }
    private func color(_ value: ProjectColor) -> Color { Color(red: value.red, green: value.green, blue: value.blue) }
    private func preview(_ title: String, color value: ProjectColor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium)); Text("便利贴内容预览").font(.caption).opacity(value.secondaryInkOpacity)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .foregroundStyle(value.usesWhiteInk ? .white : .black).background(color(value), in: RoundedRectangle(cornerRadius: 8))
    }
    @discardableResult private func saveColors() -> Bool {
        guard let value = colors.palette else { return false }
        return environment.appearance.save(value)
    }
    private func resetColors() {
        let value = environment.appearance.palette
        colors.start = value.start.hex; colors.end = value.end.hex; colors.overdue = value.overdue.hex
    }
    private func installGuard() {
        navigation.registerGuard(owner: colors.guardID) {
            if colors.palette != environment.appearance.palette {
                let alert = NSAlert()
                alert.messageText = "保存便利贴颜色的修改？"
                alert.informativeText = colors.palette == nil ? "输入尚未通过颜色校验，可以返回修改或舍弃本次输入。" : "颜色修改还没有保存。"
                if colors.palette != nil { alert.addButton(withTitle: "保存颜色") }
                alert.addButton(withTitle: "舍弃修改"); alert.addButton(withTitle: "继续编辑")
                let response = alert.runModal()
                if colors.palette != nil {
                    if response == .alertFirstButtonReturn { guard saveColors() else { return false } }
                    else if response == .alertSecondButtonReturn { resetColors() }
                    else { return false }
                } else if response == .alertFirstButtonReturn { resetColors() } else { return false }
            }
            if connection.changed && !connection.connecting {
                let alert = NSAlert(); alert.messageText = "舍弃未应用的连接信息？"
                alert.informativeText = "连接信息需要在同步页点击“连接并合并”验证后应用。"
                alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "舍弃输入")
                guard alert.runModal() == .alertSecondButtonReturn else { return false }
                connection.reset()
            }
            return true
        }
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var login: LoginItemController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("启动") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("登录时自动启动", isOn: Binding(get: { login.status == .enabled || login.status == .requiresApproval }, set: { login.setEnabled($0) }))
                        .disabled(!login.canConfigure)
                    Text(login.canConfigure ? "默认关闭。启用后登录时在后台运行，不自动弹出白板。" : "将正式版拖入“应用程序”后即可设置自动启动。")
                        .font(.callout).foregroundStyle(.secondary)
                    if login.status == .requiresApproval {
                        Text("等待系统允许").foregroundStyle(.orange)
                        Button("打开系统登录项设置…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    if login.status == .unavailable { Text("系统登录项暂不可用，请稍后重试。").font(.callout).foregroundStyle(.secondary) }
                    if let error = login.error { Text(error).foregroundStyle(.red).font(.callout) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("关闭与退出") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("关闭窗口后，PinDo 继续在状态栏运行。点击状态栏图标或 Dock 可再次打开。")
                    Text("两秒内按两次 ⌘Q，或按住约一秒后退出；从菜单退出时会再次确认。")
                }.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }
}

private struct SyncSettingsPane: View {
    @ObservedObject var sync: SyncCoordinator
    @ObservedObject var draft: SyncSettingsDraft
    let showIssues: Bool
    let available: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("同步状态") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: sync.busy ? "arrow.triangle.2.circlepath" : sync.enabled ? "cloud" : "pause.circle")
                        Text(sync.configuration == nil ? "尚未配置同步" : sync.message)
                        Spacer()
                        if sync.busy { ProgressView().controlSize(.small) }
                    }
                    if let date = sync.lastSuccess { Text("最近成功：" + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        if sync.configuration != nil { Button(sync.primaryActionTitle) { sync.performPrimaryAction() }.disabled(sync.busy || !available) }
                        if sync.enabled { Button("暂停同步") { sync.pause() }.disabled(sync.busy) }
                    }
                    Text("更改先保存在本机，再自动同步；离线不影响保存。暂停后自动与手动同步都会停止。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            if let error = draft.error ?? sync.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            if !sync.conflicts.isEmpty || !sync.retainedItems.isEmpty {
                DisclosureGroup("待处理冲突与保留内容（\(sync.conflicts.count)）", isExpanded: $draft.issuesExpanded) { SyncConflictsView(sync: sync).padding(.top, 12) }
            }
            DisclosureGroup("WebDAV 连接信息", isExpanded: $draft.connectionExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Form {
                        TextField("服务器地址", text: $draft.server).disabled(sync.isBound)
                        TextField("专用目录（必填）", text: $draft.directory, prompt: Text("例如 PinDo" )).disabled(sync.isBound)
                        TextField("账号", text: $draft.username).disabled(sync.isBound)
                        SecureField(sync.configuration == nil ? "应用授权密码" : "新密码（留空使用原密码）", text: $draft.password)
                    }.textFieldStyle(.roundedBorder).disabled(draft.connecting || sync.busy || !available)
                    Text(sync.isBound ? "此版本保持原同步库绑定；可更新应用密码。更换服务器、账号或目录需要独立迁移。" : "请手动填写专用目录，多台设备使用相同目录。首次连接自动创建缺失目录并合并数据。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if draft.changed { Button("取消输入") { draft.reset() }.disabled(draft.connecting) }
                        Spacer()
                        Button(draft.connecting ? "正在验证…" : sync.configuration == nil ? "连接并合并" : "验证并应用") {
                            draft.connecting = true; draft.error = nil
                            Task {
                                do { try await sync.connect(draft.connection, password: draft.password); draft.accept() }
                                catch { draft.error = error.localizedDescription; sync.noteConnectionError(error) }
                                draft.connecting = false
                            }
                        }.buttonStyle(.borderedProminent).disabled(!available || !draft.valid || draft.connecting || sync.busy)
                    }
                }.padding(.top, 12)
            }
            if !available { Text("本地数据尚未打开，连接操作暂不可用。现有内容已保留。").font(.callout).foregroundStyle(.secondary) }
        }
        .onAppear { draft.connectionExpanded = sync.configuration == nil; draft.issuesExpanded = showIssues || !sync.conflicts.isEmpty }
        .onChange(of: showIssues) { _, value in if value { draft.issuesExpanded = true } }
    }
}

@MainActor
private final class DataSettingsState: ObservableObject {
    @Published var backupDate: Date?
    @Published var backupError: String?
}

private struct DataSettingsPane: View {
    @ObservedObject var environment: AppEnvironment
    @StateObject private var state = DataSettingsState()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("本地数据") {
                VStack(alignment: .leading, spacing: 10) {
                    if let paths = environment.paths { Text(paths.root.path).font(.caption).textSelection(.enabled) }
                    else { Text("尚未打开数据目录").foregroundStyle(.secondary) }
                    Button("打开数据文件夹") { environment.showDataFolder() }.disabled(environment.paths == nil)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("备份与恢复") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(state.backupDate.map { "最新恢复备份：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未生成最新恢复备份")
                        .font(.callout)
                    Text("自动维护一份最新恢复备份，不累计每日或版本历史。操作前安全副本在验证成功后回收；手动导出文件由你保管。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("导出备份…") { environment.exportBackup() }
                        Button("从备份恢复…") { environment.importBackup() }.disabled(environment.sync.busy)
                    }.disabled(environment.repository == nil || environment.dataActionBusy)
                    if let error = state.backupError { Text(error).font(.caption).foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }.task { readBackup() }.onChange(of: environment.backupRevision) { _, _ in readBackup() }
    }
    private func readBackup() {
        state.backupDate = nil; state.backupError = nil
        guard let root = environment.paths?.backups else { return }
        let url = root.appendingPathComponent("recovery.latest.pindobackup")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { state.backupDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        catch { state.backupError = "无法读取备份状态：" + error.localizedDescription }
    }
}
