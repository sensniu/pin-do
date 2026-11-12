import AppKit
import Combine
import SwiftUI

@MainActor
final class ProjectManagementModel: ObservableObject {
    @Published var name = ""
    @Published var newName = ""
    @Published var editingID: UUID?
    @Published var color = Color.blue
    @Published var deleting: Project?
    @Published var confirming = false
    @Published var archiving: Project?
    @Published var confirmingArchive = false
    @Published var showArchived = false
}

struct ProjectManagementView: View {
    @ObservedObject var model: BoardModel
    @StateObject private var form = ProjectManagementModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("项目管理").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("新项目名称", text: $form.newName).onSubmit { createProject() }.accessibilityLabel("新项目名称")
                Button("新建", action: createProject).disabled(form.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section(status: .active)
                    Divider().padding(.vertical, 8)
                    DisclosureGroup("已归档 · \(model.projects.filter { $0.status == .archived }.count)", isExpanded: $form.showArchived) {
                        section(status: .archived).padding(.top, 8)
                    }
                }
            }
            if let message = model.errorMessage { Text(message).font(.callout).foregroundStyle(.red) }
        }
        .padding(24).frame(width: 590, height: 510)
        .alert("归档「\(form.archiving?.name ?? "")」？", isPresented: $form.confirmingArchive) {
            Button("取消", role: .cancel) {}
            Button("归档并转移") {
                if let project = form.archiving { model.archiveProject(project.id); clearEditor(project.id) }
            }
        } message: {
            Text("这 \(model.activeItems.filter { $0.projectID == form.archiving?.id }.count) 项未完成待办将转入未分配项目。以后恢复项目不会自动移回这些事项。")
        }
        .alert("删除项目「\(form.deleting?.name ?? "")」？", isPresented: $form.confirming) {
            if let project = form.deleting {
                let count = model.activeItems.filter { $0.projectID == project.id }.count
                Button(count == 0 ? "删除项目" : "转入未分配项目", role: .destructive) {
                    model.deleteProject(project.id, action: .transferToUnassigned); clearEditor(project.id)
                }
                if count > 0 {
                    Button("放弃这 \(count) 项待办", role: .destructive) {
                        model.deleteProject(project.id, action: .abandon); clearEditor(project.id)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            let count = model.activeItems.filter { $0.projectID == form.deleting?.id }.count
            Text(count > 0 ? "项目中有 \(count) 项未完成待办，请选择如何处理。已完成记录和原项目关联会保留。" : "项目将从列表移除，已完成记录和历史项目关联会保留。")
        }
    }

    @ViewBuilder private func section(status: ProjectStatus) -> some View {
        let projects = model.projects.filter { $0.status == status }.sorted { $0.createdAt < $1.createdAt }
        if projects.isEmpty { Text("暂无项目").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
        ForEach(projects) { project in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(Color(red: project.red, green: project.green, blue: project.blue)).frame(width: 10, height: 10)
                    Text(model.projectLabel(project)).lineLimit(1).help(project.name)
                    Spacer()
                    Button("编辑") {
                        form.editingID = project.id; form.name = project.name
                        form.color = Color(red: project.red, green: project.green, blue: project.blue)
                    }.buttonStyle(.borderless)
                    Menu {
                        if status == .active {
                            Button("归档项目…") {
                                if model.activeItems.contains(where: { $0.projectID == project.id }) {
                                    form.archiving = project; form.confirmingArchive = true
                                } else { model.archiveProject(project.id); clearEditor(project.id) }
                            }
                        } else { Button("恢复项目") { model.restoreProject(project.id) } }
                        Divider()
                        Button("删除项目…", role: .destructive) { form.deleting = project; form.confirming = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("项目操作：\(project.name)")
                }
                if form.editingID == project.id {
                    HStack {
                        TextField("项目名称", text: $form.name).onSubmit { saveEdit() }.accessibilityLabel("项目名称")
                        ColorPicker("项目颜色", selection: $form.color, supportsOpacity: false).labelsHidden().accessibilityLabel("项目颜色")
                        Button("保存", action: saveEdit).disabled(form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("取消") { form.editingID = nil }
                    }.padding(.top, 4)
                }
            }.font(.system(size: 13)).padding(10)
                .background(.primary.opacity(form.editingID == project.id ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func createProject() {
        if model.createProject(name: form.newName) { form.newName = "" }
    }
    private func saveEdit() {
        guard let id = form.editingID, let color = NSColor(form.color).usingColorSpace(.sRGB) else { return }
        if model.updateProject(id, name: form.name, color: ProjectColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)) { form.editingID = nil }
    }
    private func clearEditor(_ id: UUID) { if model.errorMessage == nil, form.editingID == id { form.editingID = nil } }
}
