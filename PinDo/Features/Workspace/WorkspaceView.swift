import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: BoardModel
    @Binding var managingProjects: Bool
    @Binding var managingAppearance: Bool
    @EnvironmentObject private var settings: AppearanceSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    ProjectTabBarView(model: model)
                    Divider().opacity(0.5)
                    BoardView(model: model)
                }
                .allowsHitTesting(model.draft == nil)
                .accessibilityHidden(model.draft != nil)
                if let draft = model.draft {
                    Color.black.opacity(scheme == .dark ? 0.35 : 0.10).ignoresSafeArea()
                    NoteEditorView(
                        draft: draft, now: .now, showsProjectBorder: model.selectedScope == .all,
                        projects: model.activeProjects, projectLabel: model.projectLabel,
                        maxHeight: max(320, geometry.size.height - 48),
                        submit: { model.submit($0) }, cancel: { model.cancelEditing() },
                        abandon: { model.abandon($0) }, complete: { model.completeEditing($0) },
                        draftChanged: { model.updateDraft($0) }
                    )
                    .id(draft.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .background(WorkspaceStyle.canvas(scheme))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.draft?.id)
            .overlay(alignment: .topTrailing) {
                if let notice = model.notice {
                    Text(notice).font(.system(size: 12)).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 100).padding(.trailing, 24)
                        .accessibilityLabel(notice)
                        .task(id: notice) {
                            do { try await Task.sleep(for: .seconds(3)) } catch { return }
                            if model.notice == notice { model.notice = nil }
                        }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $managingProjects) { ProjectManagementView(model: model) }
        .sheet(isPresented: $managingAppearance) { AppearanceSettingsView(settings: settings) }
        .alert("操作未保存", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
