import Combine
import SwiftUI

@MainActor
final class ProjectManagementModel: ObservableObject {
    @Published var name = ""
    @Published var editingID: UUID?
    @Published var deleting: Project?
    @Published var confirming = false
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
                TextField(form.editingID == nil ? "新项目名称" : "项目名称", text: $form.name)
                    .onSubmit { saveName() }
                    .accessibilityLabel("项目名称")
                Button(form.editingID == nil ? "新建" : "保存名称") { saveName() }
                    .disabled(form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if form.editingID != nil { Button("取消") { form.editingID = nil; form.name = "" } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("当前项目", status: .active)
                    Divider().padding(.vertical, 6)
                    section("已归档", status: .archived)
                }
            }
            Text("归档会将未完成事项转入未分配项目；恢复项目不会自动移回这些事项。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(24).frame(width: 590, height: 510)
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

    @ViewBuilder private func section(_ title: String, status: ProjectStatus) -> some View {
        Text(title).font(.headline)
        let projects = model.projects.filter { $0.status == status }.sorted { $0.createdAt < $1.createdAt }
        if projects.isEmpty { Text("暂无项目").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
        ForEach(projects) { project in
            HStack {
                Circle().fill(Color(red: project.red, green: project.green, blue: project.blue)).frame(width: 8, height: 8)
                Text(model.projectLabel(project)).lineLimit(1).help(project.name)
                Spacer()
                Button("重命名") { form.editingID = project.id; form.name = project.name }
                if status == .active {
                    Button("归档") { model.archiveProject(project.id); clearEditor(project.id) }
                } else { Button("恢复") { model.restoreProject(project.id) } }
                Button { form.deleting = project; form.confirming = true } label: { Image(systemName: "trash") }
                    .help("删除项目").accessibilityLabel("删除项目：\(project.name)")
            }
            .font(.system(size: 13)).padding(.vertical, 5)
        }
    }
    private func saveName() {
        let success = form.editingID.map { model.renameProject($0, name: form.name) } ?? model.createProject(name: form.name)
        if success { form.editingID = nil; form.name = "" }
    }
    private func clearEditor(_ id: UUID) {
        if form.editingID == id { form.editingID = nil; form.name = "" }
    }
}
