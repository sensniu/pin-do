import XCTest

final class BoardFlowTests: XCTestCase {
    @MainActor
    final class DraftStore: TodoPersisting {
        var draft: NoteDraft?
        func commit(_ item: TodoItem, event: TodoEvent, clearDraft: Bool) throws -> TodoItem { item }
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
        func commit(_ item: TodoItem, event: TodoEvent, clearDraft: Bool) throws -> TodoItem { throw StoreFailure.inconsistentStore }
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
        let reserved = model.undo!.originalFrame
        for id in model.layout.positions.keys {
            XCTAssertFalse(model.layout.frame(for: id)!.intersects(reserved))
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

    @MainActor
    func testWindowResizeDoesNotRearrangeUntilNextAllowedTrigger() {
        let items = (0..<12).map { TodoItem(title: "\($0)") }
        let model = BoardModel(items: items)
        model.updateViewport(CGSize(width: 1120, height: 680))
        let before = model.layout
        let revision = model.layoutRevision
        model.updateViewport(CGSize(width: 680, height: 1100))
        XCTAssertEqual(model.layout, before)
        XCTAssertEqual(model.layoutRevision, revision)
        model.selectScope(.all)
        XCTAssertNotEqual(model.layout, before)
        XCTAssertEqual(model.layoutRevision, revision + 1)
    }

    @MainActor
    func testRestoredScopeAndDraftCompletionFromAnotherBoard() {
        let project = Project(name: "project", color: 0)
        let item = TodoItem(title: "unassigned")
        let model = BoardModel(items: [item], projects: [project], uptime: { 10 })
        model.restoreScope(.project(project.id))
        XCTAssertEqual(model.selectedScope, .project(project.id))
        XCTAssertTrue(model.visibleItems.isEmpty)
        var draft = NoteDraft(item: item, now: .now)
        draft.title = "saved before completion"
        model.draft = draft
        model.completeEditing(draft)
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.items[0].status, .completed)
        XCTAssertEqual(model.items[0].title, draft.title)
        model.undoCompletion()
        XCTAssertEqual(model.items[0].status, .active)
        XCTAssertNil(model.items[0].projectID)
        model.restoreScope(.project(UUID()))
        XCTAssertEqual(model.selectedScope, .all)
    }

    @MainActor
    func testEditorCompletionFailureKeepsDraftAndActiveItem() {
        let item = TodoItem(title: "keep")
        let model = BoardModel(items: [item], persistence: FailingStore())
        var draft = NoteDraft(item: item, now: .now)
        draft.title = "unsaved"
        model.draft = draft
        model.completeEditing(draft)
        XCTAssertEqual(model.draft, draft)
        XCTAssertEqual(model.activeItems, [item])
        XCTAssertNil(model.undo)
    }

    @MainActor
    func testCompletionFailureAfterSuccessfulEditRestoresEditor() {
        final class Store: TodoPersisting {
            var commits = 0
            func saveDraft(_ draft: NoteDraft?) throws {}
            func commit(_ item: TodoItem, event: TodoEvent, clearDraft: Bool) throws -> TodoItem {
                commits += 1
                if commits == 2 { throw StoreFailure.inconsistentStore }
                return item
            }
        }
        let item = TodoItem(title: "original")
        let model = BoardModel(items: [item], persistence: Store())
        var draft = NoteDraft(item: item, now: .now)
        draft.title = "edited"
        model.draft = draft
        model.completeEditing(draft)
        XCTAssertEqual(model.draft, draft)
        XCTAssertEqual(model.items[0].title, "edited")
        XCTAssertEqual(model.items[0].status, .active)
        XCTAssertNil(model.undo)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testTextResizePreservesViewportRevisionAndUndoReservation() {
        let items = (0..<12).map { TodoItem(title: "item \($0)") }
        let model = BoardModel(items: items, uptime: { 10 })
        let completed = items[3]
        let point = model.layout.positions[completed.id]
        model.complete(completed.id)
        let viewport = model.viewportBounds, revision = model.layoutRevision
        var draft = NoteDraft(item: items[0], now: .now)
        draft.title = "这里是用于测试自动换行的很长的事项标题"
        draft.notes = "备注第一行\n第二行\n第三行"
        model.submit(draft)
        XCTAssertEqual(model.viewportBounds, viewport)
        XCTAssertEqual(model.layoutRevision, revision)
        let reservation = model.undo!.originalFrame
        for item in model.visibleItems { XCTAssertFalse(model.layout.frame(for: item.id)!.intersects(reservation)) }
        model.undoCompletion()
        XCTAssertEqual(model.layout.positions[completed.id], point)
        let frames = model.visibleItems.compactMap { model.layout.frame(for: $0.id) }
        for i in frames.indices { for j in frames.indices where j > i { XCTAssertFalse(frames[i].intersects(frames[j])) } }
    }

}

