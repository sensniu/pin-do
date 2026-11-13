import SwiftUI
import Combine

@MainActor
final class ProjectTabScrollState: ObservableObject {
    @Published var offsets: [UUID: CGFloat] = [:]
    @Published var contentWidth: CGFloat = 0
}
struct ProjectTabBarView: View {
    @ObservedObject var model: BoardModel
    @StateObject private var scroll = ProjectTabScrollState()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            tab("全部待办", scope: .all)
            tab("未分配项目", scope: .unassigned)
            Divider().frame(height: 18).padding(.horizontal, 2)
            GeometryReader { geometry in
                ScrollViewReader { reader in
                    HStack(spacing: 3) {
                        ScrollView(.horizontal) {
                            HStack(spacing: 4) {
                                ForEach(model.activeProjects) { project in
                                    tab(model.projectLabel(project), scope: .project(project.id), project: project)
                                        .id(BoardScope.project(project.id))
                                        .background(GeometryReader { item in
                                            Color.clear
                                                .onAppear { scroll.offsets[project.id] = item.frame(in: .named("project-tabs")).minX }
                                                .onChange(of: item.frame(in: .named("project-tabs")).minX) { _, x in scroll.offsets[project.id] = x }
                                        })
                                }
                            }
                            .padding(.horizontal, 2).padding(.vertical, 2)
                            .background(GeometryReader { content in
                                Color.clear.onAppear { scroll.contentWidth = content.size.width }
                                    .onChange(of: content.size.width) { _, width in scroll.contentWidth = width }
                            })
                        }
                        .coordinateSpace(name: "project-tabs")
                        .scrollIndicators(.hidden)
                        if scroll.contentWidth > geometry.size.width {
                            arrow("chevron.left", delta: -1, reader: reader)
                            arrow("chevron.right", delta: 1, reader: reader)
                        }
                    }
                    .onChange(of: model.selectedScope) { _, _ in reveal(reader) }
                    .onChange(of: geometry.size.width) { _, _ in reveal(reader) }
                    .onChange(of: model.projects.map { $0.name }) { _, _ in reveal(reader) }
                    .onAppear { reveal(reader) }
                }
            }.frame(height: 32)
        }
        .padding(.horizontal, 20).padding(.vertical, 2)
        .accessibilityElement(children: .contain).accessibilityLabel("白板标签栏")
    }

    private func arrow(_ symbol: String, delta: Int, reader: ScrollViewProxy) -> some View {
        Button {
            let projects = model.activeProjects
            guard !projects.isEmpty else { return }
            let leading = projects.indices.min { abs(scroll.offsets[projects[$0].id] ?? 0) < abs(scroll.offsets[projects[$1].id] ?? 0) } ?? 0
            let next = min(projects.count - 1, max(0, leading + delta))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                reader.scrollTo(BoardScope.project(projects[next].id), anchor: .leading)
            }
        } label: { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 28) }
            .buttonStyle(.plain).help(delta < 0 ? "向左浏览项目" : "向右浏览项目")
            .accessibilityLabel(delta < 0 ? "向左浏览项目" : "向右浏览项目")
    }

    private func reveal(_ reader: ScrollViewProxy) {
        guard model.selectedScope.projectID != nil else { return }
        Task { @MainActor in
            await Task.yield()
            // No explicit anchor: move only enough to reveal the resized selected tab.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { reader.scrollTo(model.selectedScope) }
        }
    }

    private func tab(_ title: String, scope: BoardScope, project: Project? = nil) -> some View {
        let selected = model.selectedScope == scope
        let fill = project.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
            ?? Color(white: scheme == .dark ? 0.22 : 0.93)
        let ink: Color = project.map { $0.colorValue.usesWhiteInk ? .white : .black } ?? (scheme == .dark ? .white : .black)
        return Button { model.selectScope(scope) } label: {
            HStack(spacing: 5) {
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 7).frame(height: 26).foregroundStyle(ink)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(ink.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 1.5 : 0.5) }
            .padding(1).contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .help(title).accessibilityLabel(title).accessibilityValue(selected ? "已选中" : "未选中")
        .accessibilityIdentifier(scope.projectID.map { "project-tab-\($0.uuidString)" } ?? (scope == .all ? "all-todos-tab" : "unassigned-tab"))
    }
}
