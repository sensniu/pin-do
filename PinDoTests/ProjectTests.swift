import SwiftData
import XCTest

final class ProjectTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-project-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func insert(_ item: TodoItem, into store: TodoRepository) throws {
        try store.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: item.createdAt), clearDraft: true)
    }
    @MainActor func testBatchFailureAfterItemChangesRollsBackEveryItem() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let prepared = try TodoRepository.prepareForOpening(paths: paths, appVersion: "0.2.0")
        // Fault injection: invalid project name is detected after the batch has changed items.
        let badProject = Project(name: "")
        let context = ModelContext(prepared.container); context.autosaveEnabled = false
        context.insert(StoreRecord(key: "project:\(badProject.id.uuidString)", bucket: "project", payload: try JSONEncoder().encode(badProject)))
        let items = (0..<10).map { TodoItem(title: "item \($0)", projectID: badProject.id) }
        for item in items {
            context.insert(StoreRecord(key: "todo:\(item.id.uuidString)", bucket: "todo-active", payload: try JSONEncoder().encode(item)))
        }
        try context.save()
        let store = TodoRepository(paths: paths, appVersion: "0.2.0", prepared: prepared)
        XCTAssertThrowsError(try store.archiveProject(id: badProject.id))
        let after = try store.loadActiveItems()
        XCTAssertEqual(Set(after.map(\.id)), Set(items.map(\.id)))
        XCTAssertTrue(after.allSatisfy { $0.projectID == badProject.id && $0.projectAssignments.isEmpty })
    }

    @MainActor func testMissingProjectInBackupCannotReplaceExistingData() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0")
        let project = try store.createProject(name: "P"), itemID = UUID()
        try insert(TodoItem(id: itemID, title: "keep me", projectID: project.id), into: store)
        let source = try store.archive()
        let damaged = StoreArchive(appVersion: source.appVersion, createdAt: source.createdAt,
                                   records: source.records.filter { $0.bucket != "project" })
        XCTAssertThrowsError(try store.restore(damaged))
        XCTAssertEqual(try store.loadActiveItems().map(\.id), [itemID])
        XCTAssertEqual(try store.loadProjects().map(\.id), [project.id])
    }

    @MainActor func testProjectArchiveRenameRestoreAndSameNameKeepHistory() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var store: TodoRepository? = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0")
        let project = try store!.createProject(name: "工作")
        let active = TodoItem(title: "active", projectID: project.id)
        var completed = TodoItem(title: "completed", projectID: project.id)
        var abandoned = TodoItem(title: "abandoned", projectID: project.id)
        for item in [active, completed, abandoned] { try insert(item, into: store!) }
        completed.status = .completed; completed.completedAt = .now
        try store!.commit(completed, event: TodoEvent(itemID: completed.id, kind: .completed, occurredAt: completed.completedAt!), clearDraft: false)
        abandoned.status = .abandoned; abandoned.abandonedAt = .now
        try store!.commit(abandoned, event: TodoEvent(itemID: abandoned.id, kind: .abandoned, occurredAt: abandoned.abandonedAt!), clearDraft: false)
        let data = try store!.archiveProject(id: project.id)
        XCTAssertEqual(data.items.count, 1)
        XCTAssertNil(data.items[0].projectID)
        XCTAssertEqual(data.items[0].projectAssignments.first?.previousProjectID, project.id)
        XCTAssertEqual(data.items[0].projectAssignments.first?.reason, .archived)
        let replacement = try store!.createProject(name: "工作")
        XCTAssertNotEqual(project.id, replacement.id)
        _ = try store!.renameProject(id: project.id, name: "旧工作")
        _ = try store!.restoreProject(id: project.id)
        XCTAssertNil(try store!.loadActiveItems()[0].projectID)
        let archive = try store!.archive()
        for key in ["todo:\(completed.id.uuidString)", "todo:\(abandoned.id.uuidString)"] {
            let item = try JSONDecoder().decode(TodoItem.self, from: archive.records.first { $0.key == key }!.payload)
            XCTAssertEqual(item.projectID, project.id)
        }
        store = nil
        store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0")
        XCTAssertEqual(try store!.loadProjects().first { $0.id == project.id }?.name, "旧工作")
        XCTAssertEqual(try store!.loadActiveItems()[0].projectAssignments.count, 1)
        XCTAssertThrowsError(try store!.renameProject(id: project.id, name: " \n"))
    }
    @MainActor func testDeleteBothBranchesAndBackupRestore() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0")
        let first = try store.createProject(name: "same"), second = try store.createProject(name: "same")
        let a = TodoItem(title: "transfer", projectID: first.id), b = TodoItem(title: "abandon", projectID: second.id)
        try insert(a, into: store); try insert(b, into: store)
        let before = try BackupCodec.decode(BackupCodec.encode(store.archive()))
        _ = try store.deleteProject(id: first.id, action: .transferToUnassigned)
        _ = try store.deleteProject(id: second.id, action: .abandon)
        let active = try store.loadActiveItems()
        XCTAssertEqual(active.map(\.id), [a.id]); XCTAssertNil(active[0].projectID)
        XCTAssertEqual(active[0].projectAssignments.last?.reason, .deleted)
        let archived = try store.archive()
        let removed = try JSONDecoder().decode(TodoItem.self, from: archived.records.first { $0.key == "todo:\(b.id.uuidString)" }!.payload)
        XCTAssertEqual(removed.status, .abandoned); XCTAssertEqual(removed.projectID, second.id)
        XCTAssertTrue(try store.loadProjects().allSatisfy { $0.status == .deleted })
        XCTAssertThrowsError(try store.restoreProject(id: first.id))
        try store.restore(before)
        XCTAssertEqual(Set(try store.loadActiveItems().map(\.id)), [a.id, b.id])
        XCTAssertTrue(try store.loadProjects().allSatisfy { $0.status == .active })
    }
    @MainActor func testProjectAssignmentIsAutomaticAndNotForgedByCaller() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0")
        let a = try store.createProject(name: "A"), b = try store.createProject(name: "B")
        var item = TodoItem(title: "one", projectID: a.id)
        try insert(item, into: store)
        item.projectID = b.id
        item = try store.commit(item, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: .now), clearDraft: true)
        XCTAssertEqual(item.projectAssignments.count, 1)
        XCTAssertEqual(item.projectAssignments[0].previousProjectID, a.id)
        XCTAssertEqual(item.projectAssignments[0].projectID, b.id)
        item.projectAssignments = []
        item.title = "renamed"
        let saved = try store.commit(item, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: .now), clearDraft: true)
        XCTAssertEqual(saved.projectAssignments.count, 1)
        _ = try store.archiveProject(id: b.id)
        var invalid = saved; invalid.projectID = b.id
        XCTAssertThrowsError(try store.commit(invalid, event: TodoEvent(itemID: invalid.id, kind: .edited, occurredAt: .now), clearDraft: true))
        XCTAssertNil(try store.loadActiveItems()[0].projectID)
        XCTAssertEqual(try store.loadActiveItems()[0].projectAssignments.count, 2)
    }
    @MainActor func testArchiveNormalizesDraftAndDeletedProjectCanAbandonEditingDraft() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0")
        let p = try store.createProject(name: "P")
        let item = TodoItem(title: "one", projectID: p.id); try insert(item, into: store)
        var draft = NoteDraft(item: item, now: .now); draft.notes = "keep full draft"
        try store.saveDraft(draft)
        _ = try store.archiveProject(id: p.id)
        XCTAssertNil(try store.loadDraft()?.projectID)
        XCTAssertEqual(try store.loadDraft()?.notes, draft.notes)
        _ = try store.restoreProject(id: p.id)
        var active = try store.loadActiveItems()[0]; active.projectID = p.id
        try store.commit(active, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: .now), clearDraft: true)
        try store.saveDraft(NoteDraft(item: active, now: .now))
        _ = try store.deleteProject(id: p.id, action: .abandon)
        XCTAssertNil(try store.loadDraft())
        XCTAssertTrue(try store.loadActiveItems().isEmpty)
    }
    @MainActor func testMinimalCreationAndFilteredEditing() {
        let p = Project(name: "P"), q = Project(name: "Q")
        let model = BoardModel(items: [], projects: [p, q])
        model.beginNew(); XCTAssertNil(model.draft?.projectID)
        var draft = model.draft!; draft.title = "only title"; model.submit(draft)
        XCTAssertEqual(model.activeItems.count, 1); XCTAssertNil(model.activeItems[0].projectID)
        model.selectScope(.project(p.id)); model.beginNew()
        draft = model.draft!; XCTAssertEqual(draft.projectID, p.id)
        draft.title = "automatic"; model.submit(draft)
        XCTAssertEqual(model.visibleItems.count, 1)
        let item = model.visibleItems[0], positions = model.layout
        model.edit(item); draft = model.draft!; draft.projectID = q.id; model.submit(draft)
        XCTAssertTrue(model.visibleItems.isEmpty); XCTAssertEqual(model.layout, positions)
        model.selectScope(.project(q.id)); XCTAssertEqual(model.visibleItems.map(\.id), [item.id])
        model.selectScope(.unassigned); XCTAssertEqual(model.visibleItems.count, 1)
    }
    @MainActor func testSwitchRefreshPreservesGlobalUndoAndOriginalSlot() {
        let p = Project(name: "P"), q = Project(name: "Q")
        let a = TodoItem(title: "a", projectID: p.id), b = TodoItem(title: "b", projectID: p.id)
        let model = BoardModel(items: [a, b], projects: [p, q], uptime: { 10 })
        model.selectScope(.project(p.id))
        let position = model.layout.positions[a.id]
        model.complete(a.id); let receipt = model.undo?.id
        model.selectScope(.project(q.id)); XCTAssertEqual(model.undo?.id, receipt)
        model.selectScope(.project(p.id)); model.undoCompletion()
        XCTAssertEqual(model.layout.positions[a.id], position)
        XCTAssertFalse(BoardLayoutEngine.frame(at: model.layout.positions[a.id]!).intersects(BoardLayoutEngine.frame(at: model.layout.positions[b.id]!)))
        model.complete(a.id); model.selectScope(.project(q.id)); model.undoCompletion()
        XCTAssertTrue(model.visibleItems.isEmpty); XCTAssertTrue(model.activeItems.contains { $0.id == a.id })
        XCTAssertNotNil(model.notice)
    }
    @MainActor func testUndoAfterProjectArchivedRestoresIntoUnassignedOnDisk() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0")
        let project = try store.createProject(name: "P"), item = TodoItem(title: "one")
        var assigned = item; assigned.projectID = project.id; try insert(assigned, into: store)
        let model = BoardModel(items: [assigned], projects: [project], uptime: { 10 }, persistence: store)
        model.selectScope(.project(project.id)); model.complete(item.id)
        model.archiveProject(project.id); model.undoCompletion()
        let restored = try store.loadActiveItems()[0]
        XCTAssertEqual(restored.id, item.id); XCTAssertNil(restored.projectID)
        XCTAssertEqual(restored.projectAssignments.last?.reason, .completionRestored)
        XCTAssertEqual(model.visibleItems.map(\.id), [item.id])
        try store.archive().validate()
    }
}
