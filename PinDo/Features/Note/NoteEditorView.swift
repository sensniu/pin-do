import SwiftUI

struct NoteEditorView: View {
    @StateObject private var editor: NoteEditorModel
    let now: Date
    let submit: (NoteDraft) -> Void
    let cancel: () -> Void
    let abandon: (UUID) -> Void
    let draftChanged: (NoteDraft) -> Void
    @Environment(\.colorScheme) private var scheme
    @FocusState private var titleFocused: Bool

    private var draft: NoteDraft { editor.draft }

    init(
        draft: NoteDraft, now: Date, submit: @escaping (NoteDraft) -> Void,
        cancel: @escaping () -> Void, abandon: @escaping (UUID) -> Void,
        draftChanged: @escaping (NoteDraft) -> Void
    ) {
        _editor = StateObject(wrappedValue: NoteEditorModel(draft: draft))
        self.now = now
        self.submit = submit
        self.cancel = cancel
        self.abandon = abandon
        self.draftChanged = draftChanged
    }

    private var appearance: NoteAppearance {
        NoteAppearance(
            urgency: UrgencyPolicy().evaluate(dueAt: draft.hasDeadline ? draft.dueAt : nil, now: now),
            scheme: scheme
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(spacing: 7) {
                    ForEach(1...3, id: \.self) { value in
                        Button { editor.draft.stars = value } label: {
                            Image(systemName: value <= draft.stars ? "star.fill" : "star")
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.plain)
                        .help("设为 \(value) 颗星")
                        .accessibilityLabel("重要程度 \(value) 颗星")
                    }
                }
                Spacer()
                Text(draft.isNew ? "新便利贴" : "编辑便利贴")
                    .font(.system(size: 12)).opacity(0.6)
            }

            TextField("准备做什么？", text: $editor.draft.title, axis: .vertical)
                .font(.system(size: 25, weight: .semibold))
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .focused($titleFocused)
                .accessibilityLabel("待办标题")

            VStack(alignment: .leading, spacing: 8) {
                Text("备注").font(.system(size: 11, weight: .medium)).opacity(0.6)
                TextEditor(text: $editor.draft.notes)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 112, maxHeight: 200)
                    .background(appearance.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("待办备注")
            }

            VStack(alignment: .leading, spacing: 12) {
                Toggle("设置截止时间", isOn: $editor.draft.hasDeadline)
                    .toggleStyle(.checkbox)
                if draft.hasDeadline {
                    DatePicker("截止时间", selection: $editor.draft.dueAt, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .accessibilityLabel("截止时间")
                }
                Picker("类别", selection: $editor.draft.categoryID) {
                    Text("无类别").tag("")
                    ForEach(TodoCategory.examples) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
            .font(.system(size: 13))

            Divider().overlay(appearance.ink.opacity(0.08))

            HStack(spacing: 12) {
                if !draft.isNew {
                    Button(role: .destructive) { abandon(draft.id) } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appearance.ink.opacity(0.65))
                    .help("放弃此待办，保留独立的放弃记录")
                }
                Spacer()
                Button("取消", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "贴到白板" : "保存") { submit(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSubmit)
            }
            .controlSize(.large)
        }
        .padding(28)
        .foregroundStyle(appearance.ink)
        .tint(appearance.ink)
        // Native text fields and date controls should follow the paper's ink, not the board.
        .environment(\.colorScheme, appearance.ink == .white ? .dark : .light)
        .frame(width: 470)
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(appearance.border(category: draft.category), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 35, y: 12)
        .onAppear { titleFocused = true }
        .onChange(of: editor.draft) { _, value in draftChanged(value) }
    }
}

