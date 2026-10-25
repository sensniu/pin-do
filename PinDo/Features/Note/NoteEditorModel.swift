import Combine

@MainActor
final class NoteEditorModel: ObservableObject {
    @Published var draft: NoteDraft

    init(draft: NoteDraft) { self.draft = draft }
}

