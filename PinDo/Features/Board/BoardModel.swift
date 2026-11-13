import Combine
import Foundation

@MainActor
final class BoardModel: ObservableObject {
    @Published private(set) var scheduleIssues: Set<UUID> = []
    @Published private(set) var items: [TodoItem]
    @Published private(set) var layout: BoardLayout
    @Published private(set) var viewportBounds: CGRect = .zero
    @Published private(set) var layoutRevision = 0
    @Published private(set) var fitRevision = 0
    @Published private(set) var zoomRevision = 0
    private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var undo: CompletionUndo?
    @Published var draft: NoteDraft?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published private(set) var projects: [Project]
    @Published private(set) var selectedScope: BoardScope = .all

    private let date: () -> Date
    private let uptime: () -> TimeInterval
    private var expiration: Task<Void, Never>?
    private let engine = BoardLayoutEngine()
    private var viewport = BoardLayoutEngine.defaultViewport
    private var measuredViewport = false
    // Layout belongs to this Mac session and this board, never to the synced TodoItem.
    // A new application session intentionally starts from automatic layouts again.
    private var boardLayouts: [BoardScope: BoardLayout] = [:]
    private var initialLayoutPending = true
    var scopeChanged: ((BoardScope) -> Void)?

    func updateViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewport = size
        if !measuredViewport {
            measuredViewport = true
            if initialLayoutPending { reorderBoard() }
        }
    }

    func restoreScope(_ scope: BoardScope) {
        activate(scope.projectID.map { project($0)?.status == .active } == false ? .all : scope)
    }

    func completeEditing(_ value: NoteDraft) {
        guard !value.isNew, value.canSubmit else { return }
        submit(value)
        guard draft == nil else { return }
        complete(value.id)
        if errorMessage != nil { draft = value }
    }
    private var persistence: (any TodoPersisting)?
    private var draftSave: Task<Void, Never>?

    init(
        items: [TodoItem], projects: [Project] = [], date: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        persistence: (any TodoPersisting)? = nil
    ) {
        self.items = items
        self.projects = projects
        self.date = date
        self.uptime = uptime
        self.persistence = persistence
        self.layout = BoardLayoutEngine().layout(items: items, now: date())
        self.viewportBounds = self.layout.bounds
        refreshScheduleIssues()
    }

    var activeItems: [TodoItem] { items.filter { $0.status == .active } }
    var visibleItems: [TodoItem] { activeItems.filter { selectedScope.includes($0) } }
    var activeProjects: [Project] { projects.filter { $0.status == .active }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt } }
    var boardTitle: String {
        switch selectedScope {
        case .all: "全部待办"
        case .unassigned: "未分配项目"
        case .project(let id): project(id)?.name ?? "未分配项目"
        }
    }
    func project(_ id: UUID?) -> Project? { projects.first { $0.id == id } }
    func projectLabel(_ project: Project) -> String {
        let matches = projects.filter { $0.status != .deleted && $0.name == project.name }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard matches.count > 1 else { return project.name }
        let number = (matches.firstIndex { $0.id == project.id } ?? 0) + 1
        return "\(project.name) · \(project.createdAt.formatted(.dateTime.month().day())) · \(number)"
    }

    func refreshFromSync() {
        guard let repository = persistence as? TodoRepository else { return }
        do {
            let data = try repository.loadBoardData()
            apply(data)
            if let draft, !draft.isNew, !items.contains(where: { $0.id == draft.id }), let stored = try repository.storedItem(draft.id) { items.append(stored) }
            if let projectID = selectedScope.projectID, project(projectID)?.status != .active, draft == nil {
                activate(.unassigned); scopeChanged?(selectedScope); return
            }
            refreshLayout()
        } catch { errorMessage = error.localizedDescription }
    }

    func selectScope(_ scope: BoardScope) {
        guard draft == nil else { return }
        do {
            if let store = persistence as? any ProjectPersisting { apply(try store.loadBoardData()) }
            if let id = scope.projectID, project(id)?.status != .active { throw StoreFailure.invalidProject }
            activate(scope)
            scopeChanged?(scope)
        } catch { errorMessage = error.localizedDescription }
    }

    private func apply(_ data: BoardData) {
        projects = data.projects
        items = data.items
        if let receipt = undo, !items.contains(where: { $0.id == receipt.itemID }) { items.append(receipt.item) }
    }

    func createProject(name: String) -> Bool {
        do {
            let value: Project
            if let store = persistence as? any ProjectPersisting { value = try store.createProject(name: name) }
            else { value = Project(name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: projects.count); try StoreArchive.validate(value) }
            projects.append(value)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func renameProject(_ id: UUID, name: String) -> Bool {
        mutateProject {
            if let store = persistence as? any ProjectPersisting { return try store.renameProject(id: id, name: name) }
            guard var value = project(id), value.status != .deleted else { throw StoreFailure.invalidProject }
            value.name = name.trimmingCharacters(in: .whitespacesAndNewlines); value.updatedAt = date()
            try StoreArchive.validate(value); return value
        }
    }

    func projectSyncBaseline(_ project: Project) -> SyncProjectBaseline? {
        do { return try (persistence as? TodoRepository)?.projectBaseline(project) }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    func updateProject(_ id: UUID, name: String, color: ProjectColor, baseline: SyncProjectBaseline? = nil) -> Bool {
        mutateProject {
            if let baseline, let store = persistence as? TodoRepository { return try store.saveProjectDraft(baseline, name: name, color: color) }
            if let store = persistence as? any ProjectPersisting { return try store.updateProject(id: id, name: name, color: color) }
            guard var value = project(id), value.status != .deleted else { throw StoreFailure.invalidProject }
            value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            value.red = color.red; value.green = color.green; value.blue = color.blue
            value.updatedAt = date(); try StoreArchive.validate(value)
            return value
        }
    }

    func restoreProject(_ id: UUID) {
        _ = mutateProject {
            if let store = persistence as? any ProjectPersisting { return try store.restoreProject(id: id) }
            guard var value = project(id), value.status == .archived else { throw StoreFailure.invalidProject }
            value.status = .active; value.archivedAt = nil; value.updatedAt = date(); return value
        }
    }

    private func mutateProject(_ action: () throws -> Project) -> Bool {
        do {
            let value = try action()
            if let index = projects.firstIndex(where: { $0.id == value.id }) { projects[index] = value }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func archiveProject(_ id: UUID) { changeProject(id, deleting: false, action: .transferToUnassigned) }
    func deleteProject(_ id: UUID, action: UnfinishedProjectAction) { changeProject(id, deleting: true, action: action) }
    private func changeProject(_ id: UUID, deleting: Bool, action: UnfinishedProjectAction) {
        guard draft == nil else { return }
        do {
            if let store = persistence as? any ProjectPersisting {
                try (persistence as? TodoRepository)?.checkProjectScope(id, expected: activeItems.filter { $0.projectID == id })
                let data = try deleting ? store.deleteProject(id: id, action: action) : store.archiveProject(id: id)
                apply(data)
            } else {
                guard let index = projects.firstIndex(where: { $0.id == id && $0.status != .deleted }) else { throw StoreFailure.invalidProject }
                for index in items.indices where items[index].status == .active && items[index].projectID == id {
                    items[index].updatedAt = date()
                    if deleting && action == .abandon { items[index].status = .abandoned; items[index].abandonedAt = date() }
                    else {
                        items[index].projectID = nil
                        items[index].projectAssignments.append(ProjectAssignment(previousProjectID: id, projectID: nil, changedAt: date(), reason: deleting ? .deleted : .archived))
                    }
                }
                projects[index].status = deleting ? .deleted : .archived
                if deleting { projects[index].deletedAt = date() } else { projects[index].archivedAt = date() }
            }
            if selectedScope == .project(id) { activate(.unassigned); scopeChanged?(.unassigned) }
            else { refreshLayout() }
        } catch { errorMessage = error.localizedDescription }
    }

    // A restored board replaces this session; its disappearing view must not save stale drafts.
    func retireAfterRestore() {
        draftSave?.cancel()
        expiration?.cancel()
        persistence = nil
    }

    func beginNew() {
        guard draft == nil else { return }
        var value = NoteDraft(now: date())
        value.projectID = selectedScope.projectID
        draft = value
    }

    func edit(_ item: TodoItem) {
        guard draft == nil, item.status == .active else { return }
        bringToFront(item.id)
        var value = NoteDraft(item: item, now: date())
        do { value.syncBaseline = try (persistence as? TodoRepository)?.baseline(for: item) }
        catch { errorMessage = error.localizedDescription; return }
        draft = value
    }

    func cancelEditing() {
        draftSave?.cancel()
        do {
            try persistence?.saveDraft(nil)
            draft = nil
            recoverInactiveScope()
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
        var value = value
        guard value.canSubmit else { return }
        if value.isNew, let id = value.projectID, project(id)?.status != .active {
            value.projectID = nil
            notice = "原项目已归档或删除，新事项将保存在未分配项目中。"
        }
        if let id = value.projectID, project(id)?.status != .active, value.syncBaseline == nil {
            errorMessage = StoreFailure.invalidProject.localizedDescription; return
        }
        let now = date()
        let start = value.resolvedStart(at: now)
        guard TodoSchedule(startAt: start, dueAt: value.hasDeadline ? value.dueAt : nil).isValid else {
            errorMessage = "预计开始不能晚于截止时间，请修改安排或移除预计开始。"; return
        }
        if value.isNew {
            let item = TodoItem(
                id: value.id, title: value.title.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: value.notes, dueAt: value.hasDeadline ? value.dueAt : nil,
                stars: value.stars, projectID: value.projectID, createdAt: now, plannedStartAt: start
            )
            guard save(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: now), clearDraft: true) else { return }
            initialLayoutPending = false
            refreshLayout()
            if let frame = layout.frame(for: item.id), !viewportBounds.contains(frame), visibleItems.count > 1 {
                notice = "已添加待办，可点击“适应”查看白板全貌。"
            }
        } else if let index = items.firstIndex(where: { $0.id == value.id && ($0.status == .active || value.syncBaseline != nil) }) {
            var item = items[index]
            let previous = item
            item.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
            item.notes = value.notes
            item.dueAt = value.hasDeadline ? value.dueAt : nil
            item.plannedStartAt = start
            item.stars = min(3, max(1, value.stars))
            item.projectID = value.projectID
            if item == previous { cancelEditing(); return }
            item.updatedAt = now
            let event = TodoEvent(itemID: item.id, kind: .edited, occurredAt: now, previousDeadline: previous.dueAt, newDeadline: item.dueAt)
            guard save(item, event: event, clearDraft: true, editing: value) else { return }
            refreshLayout()
        } else {
            errorMessage = StoreFailure.staleItem.localizedDescription
            return
        }
        draftSave?.cancel()
        draft = nil
        recoverInactiveScope()
    }

    func complete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .active }) else { return }
        let position = layout.positions[id] ?? vacantPosition(for: items[index])
        let now = date()
        var item = items[index]
        item.status = .completed
        item.completedAt = now
        item.completionSchedule = CompletionSchedule(startAt: item.plannedStartAt, dueAt: item.dueAt)
        item.updatedAt = now
        let event = TodoEvent(itemID: id, kind: .completed, occurredAt: now)
        guard save(item, event: event, clearDraft: false) else { return }
        let receipt = CompletionUndo(
            id: event.id, itemID: id, originalPosition: position, originalHeight: NoteMetrics.height(for: item), startedAt: uptime(), scope: selectedScope, item: items[index]
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
        item.completionSchedule = nil
        item.updatedAt = date()
        if let id = item.projectID, project(id)?.status != .active {
            item.projectID = nil
        }
        let event = TodoEvent(itemID: item.id, kind: .completionUndone, occurredAt: item.updatedAt, relatedCompletionID: receipt.id)
        guard save(item, event: event, clearDraft: false) else { return }
        expiration?.cancel()
        guard items[index].status == .active else {
            undo = nil; notice = "已撤回本次完成，另一设备的结束状态仍有效。"; return
        }
        if selectedScope.includes(items[index]) {
            let point = selectedScope == receipt.scope ? receipt.originalPosition : layout.positions[receipt.itemID] ?? vacantPosition(for: items[index])
            layout.positions[receipt.itemID] = point
            layout.heights[receipt.itemID] = receipt.originalHeight
            layout.bounds = layout.bounds.union(BoardLayoutEngine.frame(at: point, height: receipt.originalHeight))
        } else { notice = "已恢复到\(project(items[index].projectID)?.name ?? "未分配项目")。" }
        if receipt.scope != selectedScope, var saved = boardLayouts[receipt.scope] {
            saved.positions[receipt.itemID] = receipt.originalPosition
            saved.heights[receipt.itemID] = receipt.originalHeight
            boardLayouts[receipt.scope] = saved
        }
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
        recoverInactiveScope()
    }

    private func recoverInactiveScope() {
        guard draft == nil, let id = selectedScope.projectID, project(id)?.status != .active else { return }
        activate(.unassigned)
        scopeChanged?(selectedScope)
        notice = "原项目已归档或删除，已切换到未分配项目。"
    }

    func fitBoard() {
        layout.updateBounds(visibleIDs: Set(visibleItems.map(\.id)))
        viewportBounds = layout.bounds; fitRevision += 1
    }
    func zoomBoard(by factor: CGFloat) { guard draft == nil else { return }; zoomFactor = factor; zoomRevision += 1 }

    func bringToFront(_ id: UUID) {
        guard visibleItems.contains(where: { $0.id == id }) else { return }
        layout.stackingOrder.removeAll { $0 == id }
        layout.stackingOrder.append(id)
    }

    func zIndex(for id: UUID) -> Double {
        Double(layout.stackingOrder.firstIndex(of: id) ?? 0)
    }

    func moveNote(_ id: UUID, to point: CGPoint) {
        guard draft == nil, point.x.isFinite, point.y.isFinite,
              visibleItems.contains(where: { $0.id == id }) else { return }
        initialLayoutPending = false
        layout.positions[id] = point
        layout.updateBounds(visibleIDs: Set(visibleItems.map(\.id)))
        // Keep the camera fixed during free movement, including outside the current fitted bounds.
    }

    private func save(_ item: TodoItem, event: TodoEvent, clearDraft: Bool, editing: NoteDraft? = nil) -> Bool {
        do {
            var stored = item
            if let persistence {
                if let editing { stored = try persistence.commitDraft(item, event: event, draft: editing) }
                else { stored = try persistence.commit(item, event: event, clearDraft: clearDraft) }
            }
            else if let prior = items.first(where: { $0.id == item.id }), prior.projectID != item.projectID {
                stored.projectAssignments = prior.projectAssignments + [ProjectAssignment(previousProjectID: prior.projectID,
                    projectID: item.projectID, changedAt: item.updatedAt, reason: event.kind == .completionUndone ? .completionRestored : .manual)]
            }
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = stored }
            else { items.append(stored) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private var undoReservation: [CGRect] {
        guard let receipt = undo, receipt.remaining(at: uptime()) > 0, receipt.scope == selectedScope else { return [] }
        return [receipt.originalFrame]
    }

    private func vacantPosition(for item: TodoItem) -> CGPoint {
        let occupied = visibleItems.filter { $0.id != item.id }.compactMap { layout.frame(for: $0.id) }
        return engine.layout(items: [item], now: date(), reserved: occupied + undoReservation, viewport: viewport).positions[item.id] ?? .zero
    }

    func reorderBoard() {
        guard draft == nil else { return }
        initialLayoutPending = false
        layout = engine.layout(items: visibleItems, now: date(), viewport: viewport)
        boardLayouts[selectedScope] = layout
        viewportBounds = layout.bounds
        layoutRevision += 1
    }

    private func activate(_ scope: BoardScope) {
        boardLayouts[selectedScope] = layout
        selectedScope = scope
        layout = boardLayouts[scope] ?? engine.layout(items: visibleItems, now: date(), viewport: viewport)
        refreshLayout()
        viewportBounds = layout.bounds
        layoutRevision += 1
    }

    private func refreshScheduleIssues() {
        guard let repository = persistence as? TodoRepository else { return }
        do {
            if let state = try repository.syncState() {
                scheduleIssues = Set(try SyncGraph(state.changes).conflicts().filter { $0.field == "deadline" }
                    .compactMap { UUID(uuidString: String($0.entity.dropFirst(5))) })
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func refreshLayout() {
        refreshScheduleIssues()
        layout = engine.refreshed(layout, items: visibleItems, now: date(), reserved: undoReservation, viewport: viewport)
    }
}

