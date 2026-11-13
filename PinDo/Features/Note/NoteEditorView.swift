import SwiftUI

struct NoteEditorView: View {
    @StateObject private var editor: NoteEditorModel
    let initial: NoteDraft
    let now: Date
    let showsProjectBorder: Bool
    let projects: [Project]
    let projectLabel: (Project) -> String
    let submit: (NoteDraft) -> Void
    let cancel: () -> Void
    let abandon: (UUID) -> Void
    let complete: (NoteDraft) -> Void
    let draftChanged: (NoteDraft) -> Void
    let maxHeight: CGFloat
    @FocusState private var titleFocused: Bool
    private var draft: NoteDraft { editor.draft }

    init(draft: NoteDraft, now: Date, showsProjectBorder: Bool = true, projects: [Project],
         projectLabel: @escaping (Project) -> String, maxHeight: CGFloat = 650,
         submit: @escaping (NoteDraft) -> Void, cancel: @escaping () -> Void,
         abandon: @escaping (UUID) -> Void, complete: @escaping (NoteDraft) -> Void,
         draftChanged: @escaping (NoteDraft) -> Void) {
        _editor = StateObject(wrappedValue: NoteEditorModel(draft: draft))
        initial = draft; self.now = now; self.showsProjectBorder = showsProjectBorder
        self.projects = projects; self.projectLabel = projectLabel; self.maxHeight = maxHeight
        self.submit = submit; self.cancel = cancel; self.abandon = abandon
        self.complete = complete; self.draftChanged = draftChanged
    }
    private var appearance: NoteAppearance {
        NoteAppearance(urgency: UrgencyPolicy().evaluate(dueAt: draft.hasDeadline ? draft.dueAt : nil, now: now), scheme: scheme, palette: settings.palette)
    }
    @EnvironmentObject private var settings: AppearanceSettings
    @Environment(\.colorScheme) private var scheme
    private func requestCancel() {
        if draft == initial { cancel() } else { editor.discardConfirmation = true }
    }

    private var startLabel: String {
        guard let start = draft.plannedStartAt else { return "安排预计开始" }
        return "预计开始：" + (draft.startIsNow == true ? "现在" : DeadlineText.label(start, now: now))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        HStack(spacing: 2) {
                            ForEach(1...3, id: \.self) { value in
                                Button { editor.draft.stars = value } label: {
                                    Image(systemName: value <= draft.stars ? "star.fill" : "star")
                                        .font(.system(size: 15)).frame(width: 26, height: 28)
                                }.buttonStyle(.plain).help("设为 \(value) 颗星")
                                    .accessibilityLabel("重要程度 \(value) 颗星")
                            }
                        }
                        Spacer()
                        if !draft.isNew {
                            Button { complete(draft) } label: { Label("完成", systemImage: "checkmark.circle") }
                                .buttonStyle(.plain).disabled(!draft.canSubmit)
                                .help("保存修改并完成待办")
                        }
                    }
                    TextField("准备做什么？", text: $editor.draft.title, axis: .vertical)
                        .font(.system(size: 23, weight: .semibold)).textFieldStyle(.plain)
                        .lineLimit(2...5).focused($titleFocused).accessibilityLabel("待办标题")
                    HStack(spacing: 14) {
                        Button {
                            editor.proposedDate = draft.dueAt; editor.editingDate = true
                        } label: {
                            Label(draft.hasDeadline ? DeadlineText.label(draft.dueAt, now: now) : "设置截止时间", systemImage: "calendar")
                        }
                        .buttonStyle(.plain).accessibilityLabel("截止时间")
                        .popover(isPresented: $editor.editingDate) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("截止时间").font(.headline)
                                DatePicker("日期与时间", selection: $editor.proposedDate, displayedComponents: [.date, .hourAndMinute])
                                    .datePickerStyle(.field)
                                HStack {
                                    Button("清除时间") { editor.draft.hasDeadline = false; editor.editingDate = false }
                                    Spacer()
                                    Button("确定") {
                                        let time = NoteDraft.minute(Date.now)
                                        if !draft.hasDeadline, draft.plannedStartAt == nil, editor.proposedDate >= time {
                                            editor.draft.plannedStartAt = time; editor.draft.startIsNow = true
                                        }
                                        editor.draft.dueAt = NoteDraft.minute(editor.proposedDate); editor.draft.hasDeadline = true; editor.editingDate = false
                                    }
                                }
                            }.padding(20).frame(width: 330)
                        }
                        Menu {
                            Button("未分配项目") { editor.draft.projectID = nil }
                            ForEach(projects) { project in
                                Button(projectLabel(project)) { editor.draft.projectID = project.id }
                            }
                        } label: {
                            Label(projects.first { $0.id == draft.projectID }.map(projectLabel) ?? "未分配项目", systemImage: "folder")
                                .lineLimit(1)
                        }.menuStyle(.borderlessButton).accessibilityLabel("所属项目")
                    }.font(.system(size: 12)).opacity(appearance.secondaryOpacity)
                    if draft.hasDeadline {
                        HStack(spacing: 8) {
                            Button {
                                editor.proposedStart = draft.plannedStartAt ?? NoteDraft.minute(Date.now)
                                editor.editingStart = true
                            } label: {
                                Label(startLabel, systemImage: "clock")
                            }.buttonStyle(.plain).accessibilityIdentifier("planned-start")
                            Spacer(minLength: 0)
                        }.font(.system(size: 12)).opacity(appearance.secondaryOpacity)
                            .popover(isPresented: $editor.editingStart) {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("预计开始").font(.headline)
                                    DatePicker("日期与时间", selection: $editor.proposedStart, displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.field)
                                    Text("计划开始时间，不代表实际投入工时。").font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Button("清除开始") { editor.draft.plannedStartAt = nil; editor.draft.startIsNow = nil; editor.editingStart = false }
                                        Button("现在") { editor.draft.plannedStartAt = NoteDraft.minute(Date.now); editor.draft.startIsNow = true; editor.editingStart = false }
                                        Spacer()
                                        Button("确定") { editor.draft.plannedStartAt = NoteDraft.minute(editor.proposedStart); editor.draft.startIsNow = false; editor.editingStart = false }
                                    }
                                }.padding(20).frame(width: 370)
                            }
                        if let message = draft.scheduleError { Text(message).font(.caption).foregroundStyle(.red) }
                    }
                    if editor.notesExpanded {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("备注").font(.system(size: 11)).opacity(appearance.secondaryOpacity)
                            TextEditor(text: $editor.draft.notes).font(.system(size: 14))
                                .scrollContentBackground(.hidden).padding(6)
                                .frame(height: min(230, max(100, maxHeight - 320)))
                                .background(appearance.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                                .accessibilityLabel("待办备注")
                        }
                    } else {
                        Button { editor.notesExpanded = true } label: { Label("添加备注", systemImage: "text.alignleft") }
                            .buttonStyle(.plain).font(.system(size: 13)).opacity(appearance.secondaryOpacity)
                    }
                }.padding(24)
            }.scrollBounceBehavior(.basedOnSize)
            Divider().padding(.horizontal, 24)
            HStack(spacing: 12) {
                if !draft.isNew {
                    Button { editor.deleteConfirmation = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).help("放弃待办…").accessibilityLabel("放弃待办")
                        .frame(width: 28, height: 28).opacity(0.75)
                }
                Spacer()
                Button("取消", action: requestCancel).keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "添加" : "保存") { submit(draft) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent).disabled(!draft.canSubmit)
                    .help("保存 ⌘↩")
            }.controlSize(.large).padding(20)
        }
        .frame(width: 470, height: min(maxHeight, editor.notesExpanded ? 550 : (draft.hasDeadline ? 365 : 310)))
        .foregroundStyle(appearance.ink).tint(appearance.ink)
        .environment(\.colorScheme, appearance.ink == .white ? .dark : .light)
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(appearance.border(project: showsProjectBorder ? projects.first { $0.id == draft.projectID } : nil), lineWidth: showsProjectBorder ? 1.5 : 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .defaultFocus($titleFocused, draft.isNew)
        .task {
            guard draft.isNew else { return }
            await Task.yield()
            titleFocused = true
        }
        .onChange(of: editor.draft) { _, value in draftChanged(value) }
        .alert("舍弃本次修改？", isPresented: $editor.discardConfirmation) {
            Button("继续编辑", role: .cancel) {}
            Button("舍弃修改", role: .destructive, action: cancel)
        } message: { Text("这次输入的内容将不会保存。") }
        .alert("放弃此待办？", isPresented: $editor.deleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("放弃待办", role: .destructive) { abandon(draft.id) }
        } message: { Text("它将移出白板，保留为放弃记录，不计为完成。") }
    }
}
