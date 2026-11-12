import SwiftUI
import Combine

@MainActor
final class NoteHoverState: ObservableObject { @Published var hovering = false }

struct StickyNoteView: View {
    let item: TodoItem
    let now: Date
    let height: CGFloat
    let project: Project?
    var showsProjectBorder = true
    var overview = false
    let edit: () -> Void
    let complete: () -> Void
    @EnvironmentObject private var settings: AppearanceSettings
    @Environment(\.colorScheme) private var scheme
    @StateObject private var hover = NoteHoverState()
    private var urgency: Urgency { UrgencyPolicy().evaluate(dueAt: item.dueAt, now: now) }
    private var appearance: NoteAppearance { NoteAppearance(urgency: urgency, scheme: scheme, palette: settings.palette) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                StarsView(count: item.stars)
                Spacer(minLength: 4)
                if showsProjectBorder, let project {
                    Text(project.name).font(.system(size: 10)).opacity(appearance.secondaryOpacity)
                        .lineLimit(1).help(project.name)
                }
                Button(action: overview ? edit : complete) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                        .opacity(hover.hovering ? 1 : 0.75)
                }
                .buttonStyle(.plain)
                .help(overview ? "展开后完成" : "完成待办")
                .accessibilityLabel(overview ? "展开：\(item.title)" : "完成：\(item.title)")
                .accessibilityIdentifier("complete-\(item.id)")
            }
            .padding(.bottom, 4)
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 16, weight: .semibold))
                        .lineSpacing(1).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !item.notes.isEmpty {
                        Text(item.notes).font(.system(size: 12)).lineSpacing(1).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true).opacity(appearance.secondaryOpacity)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if urgency.isOverdue { Image(systemName: "clock.badge.exclamationmark"); Text("已逾期") }
                        Text(DeadlineText.label(item.dueAt, now: now))
                    }
                    .font(.system(size: 11, weight: urgency.isOverdue ? .medium : .regular))
                    .opacity(appearance.secondaryOpacity).lineLimit(1).minimumScaleFactor(0.9)
                    .help(item.dueAt?.formatted(date: .complete, time: .shortened) ?? "无截止时间")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("编辑：\(item.title)")
        }
        .foregroundStyle(appearance.ink)
        .padding(BoardLayoutEngine.notePadding)
        .frame(width: NoteMetrics.width, height: height)
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(appearance.border(project: showsProjectBorder ? project : nil), lineWidth: showsProjectBorder && project != nil ? 1.5 : 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.2 : (hover.hovering ? 0.12 : 0.06)), radius: hover.hovering ? 9 : 4, y: hover.hovering ? 4 : 2)
        .onHover { hover.hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}
