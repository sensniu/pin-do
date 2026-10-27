import SwiftUI

struct ProjectSidebarView: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var state: SidebarState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("项目").font(.headline)
                Spacer()
                Button { state.togglePinned() } label: {
                    Image(systemName: state.pinned ? "pin.fill" : "pin")
                }
                .help(state.pinned ? "取消固定项目栏" : "固定项目栏")
                .accessibilityLabel(state.pinned ? "取消固定项目栏" : "固定项目栏")
                Button { state.toggle() } label: { Image(systemName: "xmark") }
                    .help("隐藏项目栏").accessibilityLabel("隐藏项目栏")
            }
            .buttonStyle(.plain)
            ScrollView {
                VStack(spacing: 5) {
                    row("全部待办", icon: "square.grid.2x2", scope: .all, count: model.activeItems.count)
                    row("未分配项目", icon: "tray", scope: .unassigned, count: model.activeItems.filter { $0.projectID == nil }.count)
                    Divider().padding(.vertical, 9)
                    ForEach(model.activeProjects) { project in
                        row(model.projectLabel(project), icon: "folder", scope: .project(project.id),
                            count: model.activeItems.filter { $0.projectID == project.id }.count, project: project)
                    }
                    if model.activeProjects.isEmpty {
                        Text("从项目管理中新建项目").font(.caption).foregroundStyle(.secondary).padding(.vertical, 15)
                    }
                }
            }
            Spacer(minLength: 0)
            Divider()
            Button { state.managing = true } label: {
                Label("项目管理", systemImage: "folder.badge.gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).padding(.vertical, 8)
        }
        .padding(16)
    }

    private func row(_ title: String, icon: String, scope: BoardScope, count: Int, project: Project? = nil) -> some View {
        Button {
            model.selectScope(scope)
            if !state.pinned && model.errorMessage == nil { state.shown = false }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(project.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .secondary)
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 3)
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }
            .font(.system(size: 13)).padding(10)
            .background(model.selectedScope == scope ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title)
    }
}
