import XCTest

final class BoardFlowTests: XCTestCase {
    @MainActor
    final class DraftStore: TodoPersisting {
        var draft: NoteDraft?
        func commit(_ item: TodoItem, event: TodoEvent, clearDraft: Bool) throws {}
        func saveDraft(_ draft: NoteDraft?) throws { self.draft = draft }
    }

    @MainActor
    func testReplacedBoardCannotOverwriteRestoredDraftOnDisappear() {
        let store = DraftStore()
        let oldBoard = BoardModel(items: [], persistence: store)
        var oldDraft = NoteDraft(now: .now)
        oldDraft.title = "before restore"
        oldBoard.updateDraft(oldDraft)
        var restoredDraft = NoteDraft(now: .now)
        restoredDraft.title = "restored"
        store.draft = restoredDraft
        oldBoard.retireAfterRestore()
        XCTAssertTrue(oldBoard.flushDraft())
        XCTAssertEqual(store.draft, restoredDraft)
    }

    @MainActor
    final class FailingStore: TodoPersisting {
        func commit(_ item: TodoItem, event: TodoEvent, clearDraft: Bool) throws { throw StoreFailure.inconsistentStore }
        func saveDraft(_ draft: NoteDraft?) throws { throw StoreFailure.inconsistentStore }
    }

    @MainActor
    func testSaveFailureDoesNotRemoveOrPretendToCreateNotes() {
        let item = TodoItem(title: "keep me")
        let model = BoardModel(items: [item], persistence: FailingStore())
        model.complete(item.id)
        XCTAssertEqual(model.activeItems, [item])
        XCTAssertNil(model.undo)
        XCTAssertNotNil(model.errorMessage)
        var draft = NoteDraft(now: .now)
        draft.title = "not saved"
        model.draft = draft
        model.submit(draft)
        XCTAssertEqual(model.items, [item])
        XCTAssertEqual(model.draft, draft)
    }

    @MainActor
    func testEditingAndCompletingDoNotRearrangeBoard() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = TodoItem(title: "one", dueAt: now.addingTimeInterval(1_000), createdAt: now)
        let second = TodoItem(title: "two", createdAt: now)
        let model = BoardModel(items: [first, second], date: { now }, uptime: { 10 })
        let before = model.layout
        var draft = NoteDraft(item: first, now: now)
        draft.dueAt = now.addingTimeInterval(-1)
        draft.title = "changed"
        model.submit(draft)
        XCTAssertEqual(model.layout, before)
        XCTAssertEqual(model.layoutRevision, 0)
        model.complete(first.id)
        XCTAssertEqual(model.layout, before)
        XCTAssertEqual(model.activeItems.map(\.id), [second.id])
        model.undoCompletion()
        XCTAssertEqual(model.layout, before)
        XCTAssertEqual(model.activeItems.count, 2)
    }

    @MainActor
    func testOnlyLatestCompletionCanBeUndone() {
        let items = [TodoItem(title: "one"), TodoItem(title: "two")]
        let model = BoardModel(items: items, uptime: { 10 })
        model.complete(items[0].id)
        let firstReceipt = model.undo?.id
        model.complete(items[1].id)
        XCTAssertNotEqual(model.undo?.id, firstReceipt)
        model.undoCompletion()
        XCTAssertEqual(model.activeItems.map(\.id), [items[1].id])
        XCTAssertEqual(model.items.first?.status, .completed)
        XCTAssertNil(model.undo)
    }

    @MainActor
    func testAddingDuringUndoReservesOriginalPosition() {
        let now = Date.now
        let first = TodoItem(title: "one", dueAt: now.addingTimeInterval(1_000))
        let second = TodoItem(title: "two")
        let model = BoardModel(items: [first, second], date: { now }, uptime: { 10 })
        let original = model.layout.positions[first.id]!
        model.complete(first.id)
        var draft = NoteDraft(now: now)
        draft.title = "new"
        model.submit(draft)
        XCTAssertEqual(model.layoutRevision, 1)
        let reserved = BoardLayoutEngine.frame(at: original)
        for position in model.layout.positions.values {
            XCTAssertFalse(BoardLayoutEngine.frame(at: position).intersects(reserved))
        }
        model.undoCompletion()
        XCTAssertEqual(model.layout.positions[first.id], original)
        XCTAssertEqual(model.activeItems.count, 3)
    }

    @MainActor
    func testExpiredReceiptCannotRestoreAndAbandonIsSeparate() {
        var uptime: TimeInterval = 10
        let first = TodoItem(title: "one")
        let second = TodoItem(title: "two")
        let model = BoardModel(items: [first, second], uptime: { uptime })
        model.complete(first.id)
        uptime = 13
        model.undoCompletion()
        XCTAssertNil(model.undo)
        XCTAssertEqual(model.items[0].status, .completed)
        model.abandon(second.id)
        XCTAssertEqual(model.items[1].status, .abandoned)
        XCTAssertNil(model.items[1].completedAt)
        XCTAssertNotNil(model.items[1].abandonedAt)
    }

    @MainActor
    func testEmptyTitleDoesNotAddAndStarsAreClamped() {
        let model = BoardModel(items: [])
        var draft = NoteDraft(now: .now)
        draft.title = "   \n"
        model.submit(draft)
        XCTAssertTrue(model.items.isEmpty)
        draft.title = "  new  "
        draft.stars = 9
        model.submit(draft)
        XCTAssertEqual(model.items.first?.title, "new")
        XCTAssertEqual(model.items.first?.stars, 3)
    }
}

