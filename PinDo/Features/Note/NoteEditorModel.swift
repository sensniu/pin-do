import Combine
import Foundation

@MainActor
final class NoteEditorModel: ObservableObject {
    @Published var draft: NoteDraft
    @Published var notesExpanded: Bool
    @Published var editingDate = false
    @Published var proposedDate: Date
    @Published var proposedStart: Date
    @Published var editingStart = false
    @Published var discardConfirmation = false
    @Published var deleteConfirmation = false
    init(draft: NoteDraft) {
        self.draft = draft
        notesExpanded = !draft.notes.isEmpty
        proposedDate = draft.dueAt
        proposedStart = draft.plannedStartAt ?? .now
    }
}
