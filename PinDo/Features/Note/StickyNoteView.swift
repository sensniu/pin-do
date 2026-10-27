import SwiftUI

struct StickyNoteView: View {
    let item: TodoItem
    let now: Date
    let project: Project?
    let edit: () -> Void
    let complete: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var urgency: Urgency { UrgencyPolicy().evaluate(dueAt: item.dueAt, now: now) }
    private var appearance: NoteAppearance { NoteAppearance(urgency: urgency, scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                StarsView(count: item.stars)
                Spacer()
                if let project {
                    Text(project.name)
                        .font(.system(size: 10))
                        .opacity(0.68)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(project.name)
                        .padding(.trailing, 2)
                }
                Button(action: complete) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("完成并归档")
                .accessibilityLabel("完成：\(item.title)")
                .accessibilityIdentifier("complete-\(item.id)")
            }
            .padding(.bottom, 4)

            Button(action: edit) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineSpacing(2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !item.notes.isEmpty {
                        Text(item.notes)
                            .font(.system(size: 12))
                            .lineSpacing(2)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(0.69)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        if urgency.isOverdue {
                            Image(systemName: "clock.badge.exclamationmark")
                            Text("已逾期")
                        }
                        if let dueAt = item.dueAt {
                            Text(dueAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                        } else {
                            Text("未设截止时间")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10, weight: urgency.isOverdue ? .semibold : .regular))
                    .opacity(0.68)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑：\(item.title)")
        }
        .foregroundStyle(appearance.ink)
        .padding(BoardLayoutEngine.notePadding)
        .frame(width: BoardLayoutEngine.noteSize.width, height: BoardLayoutEngine.noteSize.height)
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(appearance.border(project: project), lineWidth: project == nil ? 1 : 2)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.07), radius: 6, x: 0, y: 3)
        .accessibilityElement(children: .contain)
    }
}

