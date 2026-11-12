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
        let beforeSecond = model.layout.positions[second.id]
        model.complete(first.id)
        var draft = NoteDraft(now: now)
        draft.title = "new"
        model.submit(draft)
        XCTAssertEqual(model.layoutRevision, 0)
        XCTAssertEqual(model.layout.positions[second.id], beforeSecond)
        let reserved = model.undo!.originalFrame
        for id in model.visibleItems.map(\.id) {
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
        XCTAssertEqual(model.layout, before)
        model.reorderBoard()
        XCTAssertNotEqual(model.layout, before)
        XCTAssertEqual(model.layoutRevision, revision + 2)
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
    func testFreePlacementStacksWithoutMovingNeighborsOrCamera() {
        let items = [TodoItem(title: "A"), TodoItem(title: "B"), TodoItem(title: "C")]
        let model = BoardModel(items: items)
        let before = model.layout.positions, camera = model.viewportBounds
        let destination = before[items[1].id]!
        model.bringToFront(items[0].id)
        model.moveNote(items[0].id, to: destination)
        XCTAssertEqual(model.layout.positions[items[0].id], destination)
        XCTAssertEqual(model.layout.positions[items[1].id], before[items[1].id])
        XCTAssertEqual(model.layout.positions[items[2].id], before[items[2].id])
        XCTAssertGreaterThan(model.zIndex(for: items[0].id), model.zIndex(for: items[1].id))
        XCTAssertEqual(model.viewportBounds, camera)
        model.moveNote(items[0].id, to: CGPoint(x: -2000, y: 3000))
        XCTAssertEqual(model.viewportBounds, camera)
        model.fitBoard()
        XCTAssertTrue(model.viewportBounds.contains(model.layout.frame(for: items[0].id)!))
        let layout = model.layout
        model.moveNote(items[0].id, to: CGPoint(x: CGFloat.nan, y: 0))
        model.moveNote(UUID(), to: .zero)
        XCTAssertEqual(model.layout, layout)
    }

    @MainActor
    func testBoardsKeepIndependentPositionsAndStackOrderUntilExplicitReorderOrRestart() {
        let p = Project(name: "P")
        let a = TodoItem(title: "A", projectID: p.id), b = TodoItem(title: "B", projectID: p.id)
        let model = BoardModel(items: [a, b], projects: [p])
        model.moveNote(a.id, to: CGPoint(x: 400, y: -300)); model.bringToFront(a.id)
        let allLayout = model.layout
        model.selectScope(.project(p.id))
        model.moveNote(a.id, to: CGPoint(x: -600, y: 100)); model.bringToFront(b.id)
        let projectLayout = model.layout
        model.selectScope(.unassigned); model.selectScope(.all)
        XCTAssertEqual(model.layout, allLayout)
        model.selectScope(.project(p.id)); XCTAssertEqual(model.layout, projectLayout)
        model.reorderBoard()
        XCTAssertEqual(model.layout, BoardLayoutEngine().layout(items: [a, b], now: .now))
        model.selectScope(.all); XCTAssertEqual(model.layout, allLayout)
        let restarted = BoardModel(items: [a, b], projects: [p])
        XCTAssertNotEqual(restarted.layout.positions[a.id], allLayout.positions[a.id])
        XCTAssertEqual(restarted.layout.positions, BoardLayoutEngine().layout(items: [a, b], now: .now).positions)
    }

    @MainActor
    func testAddingAndEditingLeaveStackedNotesInPlace() {
        let now = Date.now
        let a = TodoItem(title: "A"), b = TodoItem(title: "B")
        let model = BoardModel(items: [a, b])
        model.moveNote(a.id, to: .zero); model.moveNote(b.id, to: .zero)
        let positions = model.layout.positions, camera = model.viewportBounds
        var draft = NoteDraft(now: now); draft.title = "紧急新事项"; draft.hasDeadline = true; draft.dueAt = now.addingTimeInterval(60)
        model.submit(draft)
        XCTAssertEqual(model.layout.positions[a.id], positions[a.id]); XCTAssertEqual(model.layout.positions[b.id], positions[b.id])
        let newFrame = model.layout.frame(for: draft.id)!
        XCTAssertFalse(BoardLayoutEngine.conflicts(newFrame, model.layout.frame(for: a.id)!))
        var edit = NoteDraft(item: a, now: now); edit.notes = "第一行\n第二行\n第三行"
        model.submit(edit)
        XCTAssertEqual(model.layout.positions[a.id], positions[a.id]); XCTAssertEqual(model.layout.positions[b.id], positions[b.id])
        XCTAssertEqual(model.viewportBounds, camera)
        XCTAssertTrue(model.layout.frame(for: a.id)!.intersects(model.layout.frame(for: b.id)!))
    }

    @MainActor
    func testUndoRestoresOriginalPositionEvenWhenOccupiedAfterReorder() {
        let a = TodoItem(title: "A"), b = TodoItem(title: "B")
        let model = BoardModel(items: [a, b], uptime: { 10 })
        let original = model.layout.positions[a.id]!
        model.complete(a.id)
        model.reorderBoard()
        model.moveNote(b.id, to: original)
        model.undoCompletion()
        XCTAssertEqual(model.layout.positions[a.id], original)
        XCTAssertEqual(model.layout.positions[b.id], original)
    }

    @MainActor
    func testTextResizePreservesNeighborsViewportAndUndoPosition() {
        let items = (0..<12).map { TodoItem(title: "item \($0)") }
        let model = BoardModel(items: items, uptime: { 10 })
        let completed = items[3]
        let point = model.layout.positions[completed.id]
        model.complete(completed.id)
        let viewport = model.viewportBounds, revision = model.layoutRevision, positions = model.layout.positions
        var draft = NoteDraft(item: items[0], now: .now)
        draft.title = "这里是用于测试自动换行的很长的事项标题"
        draft.notes = "备注第一行\n第二行\n第三行"
        model.submit(draft)
        XCTAssertEqual(model.viewportBounds, viewport)
        XCTAssertEqual(model.layoutRevision, revision)
        XCTAssertEqual(model.layout.positions, positions)
        model.undoCompletion()
        XCTAssertEqual(model.layout.positions[completed.id], point)
    }

}

