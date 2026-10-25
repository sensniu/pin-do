import Combine
import Foundation

@MainActor
final class BoardModel: ObservableObject {
    @Published private(set) var items: [TodoItem]
    @Published private(set) var layout: BoardLayout
    @Published private(set) var layoutRevision = 0
    @Published private(set) var fitRevision = 0
    @Published private(set) var undo: CompletionUndo?
    @Published var draft: NoteDraft?
    @Published var errorMessage: String?

    private let date: () -> Date
    private let uptime: () -> TimeInterval
    private var expiration: Task<Void, Never>?
    private let engine = BoardLayoutEngine()
    private var persistence: (any TodoPersisting)?
    private var draftSave: Task<Void, Never>?

    init(
        items: [TodoItem], date: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        persistence: (any TodoPersisting)? = nil
    ) {
        self.items = items
        self.date = date
        self.uptime = uptime
        self.persistence = persistence
        self.layout = BoardLayoutEngine().layout(items: items, now: date())
    }

    var activeItems: [TodoItem] { items.filter { $0.status == .active } }

    // A restored board replaces this session; its disappearing view must not save stale drafts.
    func retireAfterRestore() {
        draftSave?.cancel()
        expiration?.cancel()
        persistence = nil
    }

    func beginNew() {
        guard draft == nil else { return }
        draft = NoteDraft(now: date())
    }

    func edit(_ item: TodoItem) {
        guard draft == nil, item.status == .active else { return }
        draft = NoteDraft(item: item, now: date())
    }

    func cancelEditing() {
        draftSave?.cancel()
        do {
            try persistence?.saveDraft(nil)
            draft = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func updateDraft(_ value: NoteDraft) {
        guard draft?.id == value.id else { return }
        draft = value
        draftSave?.cancel()
        draftSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard let self, self.draft?.id == value.id else { return }
            do { try self.persistence?.saveDraft(value) }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    func flushDraft() -> Bool {
        draftSave?.cancel()
        do {
            try persistence?.saveDraft(draft)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func submit(_ value: NoteDraft) {
        guard value.canSubmit else { return }
        let now = date()
        if value.isNew {
            let item = TodoItem(
                id: value.id, title: value.title.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: value.notes, dueAt: value.hasDeadline ? value.dueAt : nil,
                stars: value.stars, category: value.category, createdAt: now
            )
            guard save(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true) else { return }
            relayout()
        } else if let index = items.firstIndex(where: { $0.id == value.id && $0.status == .active }) {
            var item = items[index]
            let previous = item
            item.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
            item.notes = value.notes
            item.dueAt = value.hasDeadline ? value.dueAt : nil
            item.stars = min(3, max(1, value.stars))
            item.category = value.category
            if item == previous { cancelEditing(); return }
            item.updatedAt = now
            let event = TodoEvent(itemID: item.id, kind: .edited, occurredAt: now, previousDeadline: previous.dueAt, newDeadline: item.dueAt)
            guard save(item, event: event, clearDraft: true) else { return }
            // Editing deliberately leaves layout, bounds, and viewport unchanged.
        } else {
            errorMessage = StoreFailure.staleItem.localizedDescription
            return
        }
        draftSave?.cancel()
        draft = nil
    }

    func complete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .active }),
              let position = layout.positions[id] else { return }
        let now = date()
        var item = items[index]
        item.status = .completed
        item.completedAt = now
        item.updatedAt = now
        let event = TodoEvent(itemID: id, kind: .completed, occurredAt: now)
        guard save(item, event: event, clearDraft: false) else { return }
        let receipt = CompletionUndo(
            id: event.id, itemID: id, originalPosition: position, startedAt: uptime()
        )
        expiration?.cancel()
        undo = receipt
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(CompletionUndo.duration)) }
            catch { return }
            guard let self, self.undo?.id == receipt.id else { return }
            self.undo = nil
        }
    }

    func undoCompletion() {
        guard let receipt = undo, receipt.remaining(at: uptime()) > 0,
              let index = items.firstIndex(where: { $0.id == receipt.itemID && $0.status == .completed }) else {
            undo = nil
            return
        }
        var item = items[index]
        item.status = .active
        item.completedAt = nil
        item.updatedAt = date()
        let event = TodoEvent(itemID: item.id, kind: .completionUndone, occurredAt: item.updatedAt, relatedCompletionID: receipt.id)
        guard save(item, event: event, clearDraft: false) else { return }
        expiration?.cancel()
        layout.positions[receipt.itemID] = receipt.originalPosition
        layout.bounds = layout.bounds.union(BoardLayoutEngine.frame(at: receipt.originalPosition))
        undo = nil
    }

    func abandon(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .active }) else { return }
        let now = date()
        var item = items[index]
        item.status = .abandoned
        item.abandonedAt = now
        item.updatedAt = now
        guard save(item, event: TodoEvent(itemID: id, kind: .abandoned, occurredAt: now), clearDraft: true) else { return }
        draftSave?.cancel()
        draft = nil
    }

    func fitBoard() { fitRevision += 1 }

    private func save(_ item: TodoItem, event: TodoEvent, clearDraft: Bool) -> Bool {
        do {
            try persistence?.commit(item, event: event, clearDraft: clearDraft)
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
            else { items.append(item) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func relayout() {
        let reservation: [CGRect]
        if let receipt = undo, receipt.remaining(at: uptime()) > 0 {
            reservation = [BoardLayoutEngine.frame(at: receipt.originalPosition)]
        } else {
            undo = nil
            reservation = []
        }
        layout = engine.layout(items: activeItems, now: date(), reserved: reservation)
        layoutRevision += 1
    }
}

