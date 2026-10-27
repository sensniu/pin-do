import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: BoardModel
    @StateObject private var sidebar = SidebarState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let width = sidebar.effectiveWidth(window: geometry.size.width)
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    BoardView(model: model) { sidebar.toggle() }
                    if sidebar.shown && sidebar.pinned { panel(width: width, window: geometry.size.width) }
                }
                .allowsHitTesting(model.draft == nil)
                if sidebar.shown && !sidebar.pinned {
                    Color.black.opacity(0.08)
                        .onTapGesture { sidebar.shown = false }
                    panel(width: width, window: geometry.size.width)
                        .shadow(color: .black.opacity(0.16), radius: 14, x: -5)
                        .allowsHitTesting(model.draft == nil)
                }
                if let draft = model.draft {
                    Color.black.opacity(scheme == .dark ? 0.5 : 0.12)
                    ScrollView(.vertical) {
                        NoteEditorView(
                            draft: draft, now: .now, projects: model.activeProjects, projectLabel: model.projectLabel,
                            submit: { model.submit($0) }, cancel: { model.cancelEditing() },
                            abandon: { model.abandon($0) }, draftChanged: { model.updateDraft($0) }
                        )
                        .id(draft.id)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $sidebar.managing) { ProjectManagementView(model: model) }
        .alert("PinDo", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("知道了") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private func panel(width: CGFloat, window: CGFloat) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(.primary.opacity(0.12)).frame(width: 5)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if sidebar.dragStart == nil { sidebar.dragStart = width }
                        sidebar.width = min(max(200, window - 480), min(420, max(200, (sidebar.dragStart ?? width) - value.translation.width)))
                    }
                    .onEnded { _ in sidebar.dragStart = nil; sidebar.save() })
                .help("拖动调整项目栏宽度")
                .accessibilityLabel("调整项目栏宽度")
            ProjectSidebarView(model: model, state: sidebar)
        }
        .frame(width: width)
        .background(scheme == .dark ? Color(white: 0.09) : Color(white: 0.97))
    }
}
