import AppKit
import Combine
import SwiftUI

@MainActor
final class ProjectManagementModel: ObservableObject {
    let guardID = UUID()
    @Published var name = ""
    @Published var newName = ""
    @Published var editingID: UUID?
    @Published var color = Color.blue
    var originalName = "", originalColor = ""
    var syncBaseline: SyncProjectBaseline?
    @Published var deleting: Project?
    @Published var abandonItems = false
    var expectedItems: Set<UUID> = []
    @Published var archiving: Project?
    @Published var confirmingArchive = false
    @Published var showArchived = false
}

struct ProjectManagementView: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var navigation: AppNavigation
    @StateObject private var form = ProjectManagementModel()
    @FocusState private var newNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("项目管理").font(.title2.weight(.semibold))
                Spacer(); Button("完成") { navigation.present(nil) }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("新项目名称", text: $form.newName).focused($newNameFocused).onSubmit { _ = createProject() }.accessibilityLabel("新项目名称")
                Button("新建项目") { _ = createProject() }.disabled(form.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(form.editingID != nil || form.deleting != nil)
            Picker("项目状态", selection: Binding(get: { form.showArchived }, set: {
                guard protectForm() else { return }; form.showArchived = $0
            })) {
                Text("使用中（\(model.activeProjects.count)）").tag(false)
                Text("已归档（\(model.projects.filter { $0.status == .archived }.count)）").tag(true)
            }.pickerStyle(.segmented)
            ScrollView { VStack(alignment: .leading, spacing: 10) { section(status: form.showArchived ? .archived : .active) } }
            if let project = form.deleting { deletion(project) }
            if let message = model.errorMessage { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(24).frame(width: 620, height: 530).interactiveDismissDisabled()
        .onAppear {
            navigation.registerGuard(owner: form.guardID) { protectForm() }
            newNameFocused = navigation.createProject
        }
        .onDisappear { navigation.removeGuard(owner: form.guardID) }
        .onChange(of: navigation.createProject) { _, create in
            if create, protectForm() { form.showArchived = false; newNameFocused = true }
        }
        .alert("归档「\(form.archiving?.name ?? "")」？", isPresented: $form.confirmingArchive) {
            Button("取消", role: .cancel) {}
            Button("归档并转移待办") {
                if let project = form.archiving, verifyScope(project.id) {
                    model.errorMessage = nil; model.archiveProject(project.id); clearEditor(project.id)
                    if model.errorMessage != nil { model.refreshFromSync() }
                }
            }
        } message: { Text("\(form.expectedItems.count) 项未完成待办将转入未分配项目。恢复项目不会自动移回这些事项。") }
    }
    @ViewBuilder private func section(status: ProjectStatus) -> some View {
        let projects = model.projects.filter { $0.status == status }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        if projects.isEmpty { Text(status == .active ? "暂无使用中的项目" : "暂无已归档项目").font(.callout).foregroundStyle(.secondary).padding(.vertical, 18) }
        ForEach(projects) { project in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(Color(red: project.red, green: project.green, blue: project.blue)).frame(width: 10, height: 10)
                    Text(model.projectLabel(project)).lineLimit(1).help(project.name)
                    Spacer()
                    Button("编辑") {
                        guard protectForm() else { return }
                        form.syncBaseline = model.projectSyncBaseline(project)
                        form.editingID = project.id; form.name = project.name
                        form.originalName = project.name; form.originalColor = project.colorValue.hex
                        form.color = Color(red: project.red, green: project.green, blue: project.blue)
                    }.buttonStyle(.borderless)
                    Menu {
                        if status == .active {
                            Button("归档项目…") {
                                guard protectForm() else { return }
                                form.expectedItems = itemIDs(project.id)
                                if !form.expectedItems.isEmpty { form.archiving = model.project(project.id); form.confirmingArchive = true }
                                else { model.errorMessage = nil; model.archiveProject(project.id); clearEditor(project.id); if model.errorMessage != nil { model.refreshFromSync() } }
                            }
                        } else { Button("恢复归档项目") { if protectForm() { model.errorMessage = nil; model.restoreProject(project.id) } } }
                        Divider()
                        Button("删除项目…", role: .destructive) {
                            guard protectForm() else { return }
                            form.expectedItems = itemIDs(project.id); form.abandonItems = false; form.deleting = model.project(project.id)
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("项目操作：\(project.name)")
                }.disabled(form.deleting != nil)
                if form.editingID == project.id {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("项目名称", text: $form.name).onSubmit { _ = saveEdit() }.accessibilityLabel("项目名称")
                            ColorPicker("项目标签颜色", selection: $form.color, supportsOpacity: false).accessibilityLabel("项目颜色")
                        }
                        HStack {
                            Spacer()
                            Button("取消修改") { if protectForm() { form.editingID = nil } }
                            Button("保存项目") { _ = saveEdit() }.disabled(form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(.top, 6)
                }
            }.font(.system(size: 13)).padding(10)
                .background(.primary.opacity(form.editingID == project.id ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func deletion(_ project: Project) -> some View {
        GroupBox("删除项目「\(project.name)」") {
            VStack(alignment: .leading, spacing: 10) {
                Text("已完成/放弃结果与原项目身份会保留。此项目有 \(form.expectedItems.count) 项未完成待办。")
                    .font(.callout).foregroundStyle(.secondary)
                if !form.expectedItems.isEmpty {
                    Picker("未完成待办的处理方式", selection: $form.abandonItems) {
                        Text("保留待办并转入未分配项目").tag(false)
                        Text("放弃这些未完成待办").tag(true)
                    }.pickerStyle(.radioGroup)
                }
                HStack {
                    Spacer(); Button("取消") { form.deleting = nil }
                    Button("删除项目", role: .destructive) {
                        guard verifyScope(project.id) else { form.deleting = nil; return }
                        model.errorMessage = nil
                        model.deleteProject(project.id, action: form.abandonItems ? .abandon : .transferToUnassigned)
                        if model.errorMessage == nil { form.deleting = nil; clearEditor(project.id) }
                        else { model.refreshFromSync(); form.deleting = nil }
                    }
                }
            }.padding(6)
        }
    }
    private func itemIDs(_ project: UUID) -> Set<UUID> { Set(model.activeItems.filter { $0.projectID == project }.map(\.id)) }
    private func verifyScope(_ project: UUID) -> Bool {
        guard itemIDs(project) == form.expectedItems else { model.errorMessage = "项目中的待办已发生变化，请重新确认处理范围。"; return false }
        return true
    }
    private func currentColor() -> ProjectColor? {
        guard let value = NSColor(form.color).usingColorSpace(.sRGB) else { return nil }
        return ProjectColor(red: value.redComponent, green: value.greenComponent, blue: value.blueComponent)
    }
    private var changed: Bool {
        if !form.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return form.editingID != nil && (form.name != form.originalName || currentColor()?.hex != form.originalColor)
    }
    private func protectForm() -> Bool {
        guard changed else { form.editingID = nil; return true }
        let alert = NSAlert(); alert.messageText = "保存项目输入？"
        alert.informativeText = "项目输入尚未保存，离开前可以保存或舍弃本次修改。"
        alert.addButton(withTitle: form.editingID == nil ? "新建项目" : "保存项目")
        alert.addButton(withTitle: "舍弃修改"); alert.addButton(withTitle: "继续编辑")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return form.editingID == nil ? createProject() : saveEdit()
        case .alertSecondButtonReturn: form.newName = ""; form.editingID = nil; return true
        default: return false
        }
    }
    @discardableResult private func createProject() -> Bool {
        model.errorMessage = nil
        if model.createProject(name: form.newName) { form.newName = ""; return true }; return false
    }
    @discardableResult private func saveEdit() -> Bool {
        guard let id = form.editingID, let color = currentColor() else { return false }
        model.errorMessage = nil
        if model.updateProject(id, name: form.name, color: color, baseline: form.syncBaseline) { form.editingID = nil; return true }
        return false
    }
    private func clearEditor(_ id: UUID) { if model.errorMessage == nil, form.editingID == id { form.editingID = nil } }
}
