import Foundation
import SwiftData

@MainActor
extension TodoRepository {
    func syncState() throws -> SyncState? {
        guard let row = try record(key: "sync-state") else { return nil }
        let value = try JSONDecoder().decode(SyncState.self, from: row.payload)
        guard value.version == 1 else { throw SyncFailure.unsupported }
        return value
    }
    func saveSyncState(_ state: SyncState) throws {
        do { try putSyncState(state); try context.save() }
        catch { context.rollback(); throw error }
    }
    func putRestoredSyncState(_ state: SyncState) throws { try putSyncState(state) }
    func prepareCurrentSync() throws {
        guard var state = try syncState(), state.current?.protocolVersion != 3 else { return }
        var local = state.changes + state.inbox
        if let old = state.current, !old.inbox.isEmpty {
            let replacing = Set(old.inbox.keys)
            local.removeAll { $0.writes.contains { replacing.contains($0.entity) } }
            local += old.inbox.values.map(\.change)
            local = try SyncCurrent.applying(Array(old.flights.values).map(\.change) + Array(old.outbox.values).map(\.change), to: local)
        }
        state.changes = try SyncCurrent.upgrading(local, writer: state.writerID)
        state.current = CurrentSyncState()
        for change in state.changes { try state.current!.enqueue(change, writer: state.writerID) }
        // Discard protocol v1 transport history, preserving business records and unresolved candidates.
        state.libraryID = nil; state.proposedLibraryID = nil
        state.remoteCreationMode = nil; state.remoteSafetyVersion = nil
        state.published = []; state.outboxIDs = []; state.cursors = [:]; state.received = [:]
        state.inbox = []; state.outgoing = SyncCursor(); state.pending = nil; state.lastSuccess = nil
        do { try applyProjection(state); try putSyncState(state); try context.save() }
        catch { context.rollback(); throw error }
        scheduleBackup()
    }
    func resetCurrentCloud(_ library: UUID) throws {
        guard var state = try syncState() else { throw SyncFailure.invalidData }
        state.current = CurrentSyncState()
        for change in state.changes { try state.current!.enqueue(change, writer: state.writerID) }
        state.libraryID = library; state.proposedLibraryID = nil; state.lastSuccess = nil
        try saveSyncState(state)
    }
    private func appendCurrent(_ change: SyncChange, to state: inout SyncState) throws {
        if state.current == nil { state.current = CurrentSyncState() }
        let next = try SyncCurrent.applying([change], to: state.changes)
        _ = try SyncGraph(next).projection()
        try state.current!.enqueue(change, writer: state.writerID)
        state.changes = next
    }
    private func putSyncState(_ state: SyncState) throws {
        let bytes = try JSONEncoder().encode(state)
        if let row = try record(key: "sync-state") { row.payload = bytes }
        else { context.insert(StoreRecord(key: "sync-state", bucket: "sync-state", payload: bytes)) }
    }
    func syncContents() throws -> SyncContents {
        let rows = try context.fetch(FetchDescriptor<StoreRecord>())
        return try SyncContents(items: rows.filter { $0.bucket.hasPrefix("todo-") }.map { try JSONDecoder().decode(TodoItem.self, from: $0.payload) },
                                projects: loadProjects(), events: rows.filter { $0.bucket == "event" }.map { try JSONDecoder().decode(TodoEvent.self, from: $0.payload) })
    }
    func syncContentsIfEnabled() throws -> SyncContents? { try syncState() == nil ? nil : syncContents() }
    func storedItem(_ id: UUID) throws -> TodoItem? {
        try record(key: "todo:" + id.uuidString).map { try JSONDecoder().decode(TodoItem.self, from: $0.payload) }
    }
    func baseline(for item: TodoItem) throws -> SyncBaseline? {
        guard let state = try syncState() else { return nil }
        return try SyncBaseline(item: item, fields: SyncGraph(state.changes).baseline(SyncGraph.entity("todo", item.id)))
    }
    func projectBaseline(_ project: Project) throws -> SyncProjectBaseline? {
        guard let state = try syncState() else { return nil }
        return try SyncProjectBaseline(project: project, fields: SyncGraph(state.changes).baseline(SyncGraph.entity("project", project.id)))
    }
    func checkProjectScope(_ id: UUID, expected: [TodoItem]) throws {
        let actual = try loadActiveItems().filter { $0.projectID == id }
        guard Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) }) else { throw StoreFailure.staleItem }
    }
    func saveProjectDraft(_ baseline: SyncProjectBaseline, name: String, color: ProjectColor) throws -> Project {
        guard var state = try syncState() else { return try updateProject(id: baseline.project.id, name: name, color: color) }
        let entity = SyncGraph.entity("project", baseline.project.id)
        var change = SyncChange(writerID: state.writerID, date: .now, writes: [])
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if title != baseline.project.name { change.writes.append(SyncWrite(entity: entity, field: "name", parents: baseline.fields["name"] ?? [], value: try SyncCodec.encode(title))) }
        if color != baseline.project.colorValue { change.writes.append(SyncWrite(entity: entity, field: "color", parents: baseline.fields["color"] ?? [], value: try SyncCodec.encode(color))) }
        if change.writes.isEmpty { return try project(baseline.project.id) }
        try appendCurrent(change, to: &state)
        do { try applyProjection(state); try putSyncState(state); try context.save() }
        catch { context.rollback(); throw error }
        scheduleBackup(); onBusinessChange?()
        return try project(baseline.project.id)
    }
    func initializeSync() throws {
        if try syncState() != nil { try prepareCurrentSync(); return }
        let backup = try BackupCodec.encode(archive())
        try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        try StorageMaintenance.atomicWrite(backup, to: paths.backups.appendingPathComponent("before-sync.pindobackup"))
        var state = SyncState()
        let contents = try syncContents()
        state.current = CurrentSyncState()
        if let bootstrap = try SyncBuilder.capture(before: SyncContents(items: [], projects: [], events: []), after: contents, state: state) { try appendCurrent(bootstrap, to: &state) }
        _ = try SyncGraph(state.changes).projection()
        do {
            try applyProjection(state)
            try putSyncState(state)
            guard let meta = try record(key: "storage-meta") else { throw StoreFailure.inconsistentStore }
            meta.payload = try JSONEncoder().encode(StoreMetadata(formatVersion: 3))
            try context.save()
        } catch { context.rollback(); throw error }
        // Database commit is authoritative; opening repairs a manifest left at v2 by interruption here.
        var manifest = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: paths.manifest))
        manifest.formatVersion = 3
        try StorageMaintenance.atomicWrite(JSONEncoder().encode(manifest), to: paths.manifest)
        scheduleBackup()
    }
    func captureSync(_ before: SyncContents?, baseline: SyncBaseline? = nil) throws {
        guard let before, var state = try syncState() else { return }
        guard state.current != nil else { throw SyncFailure.configuration("本地同步状态尚未完成检查，原数据已保留。") }
        if let change = try SyncBuilder.capture(before: before, after: syncContents(), state: state, baseline: baseline) {
            try appendCurrent(change, to: &state)
            try applyProjection(state)
            try putSyncState(state)
        }
    }
    func stageReceived(_ incoming: [SyncChange], writer: String, cursor: SyncCursor) throws {
        guard var state = try syncState() else { throw SyncFailure.invalidData }
        let known = Dictionary(uniqueKeysWithValues: state.changes.map { ($0.id, $0) })
        for change in incoming {
            if let old = known[change.id], try SyncCodec.encode(old) != SyncCodec.encode(change) { throw SyncFailure.identityCollision }
            if let old = state.inbox.first(where: { $0.id == change.id }) {
                guard try SyncCodec.encode(old) == SyncCodec.encode(change) else { throw SyncFailure.identityCollision }
            } else if known[change.id] == nil { state.inbox.append(change) }
        }
        state.received[writer] = cursor
        try saveSyncState(state)
    }
    func applyReceived() throws {
        if var state = try syncState(), let current = state.current, !current.inbox.isEmpty {
            let replaced = Set(current.inbox.keys)
            var next = state.changes.filter { !$0.writes.contains(where: { replaced.contains($0.entity) }) }
            next += current.inbox.values.map(\.change)
            for pending in Array(current.flights.values) + Array(current.outbox.values) {
                if let cloud = current.inbox[pending.entity], cloud.receipts[pending.writerID.uuidString.lowercased(), default: 0] >= pending.sequence {
                    let proof = cloud.receiptOperations?[pending.writerID.uuidString.lowercased()]
                    guard proof?.sequence == pending.sequence, proof?.operationID == pending.id,
                          proof?.digest == (try SyncCodec.hash(SyncCodec.encode(pending))) else { throw SyncFailure.identityCollision }
                    continue
                }
                next = try SyncCurrent.applying([pending.change], to: next)
            }
            state.changes = next
            for (entity, cloud) in current.inbox { state.current!.seen[entity] = cloud.revision }
            state.current!.inbox = [:]
            do { try applyProjection(state); try putSyncState(state); try context.save() }
            catch { context.rollback(); throw error }
            scheduleBackup()
            return
        }
        guard let state = try syncState(), !state.inbox.isEmpty || state.received != state.cursors else { return }
        try acceptSync(state.inbox, cursors: state.received)
    }
    func acceptSync(_ incoming: [SyncChange], cursors: [String: SyncCursor]) throws {
        guard var state = try syncState() else { throw SyncFailure.invalidData }
        state.changes = try SyncCurrent.applying(incoming, to: state.changes)
        state.inbox = []
        for (key, cursor) in cursors {
            guard cursor.sequence >= state.cursors[key, default: SyncCursor()].sequence else { throw SyncFailure.invalidData }
            state.cursors[key] = cursor
        }
        do {
            try applyProjection(state)
            try putSyncState(state)
            try context.save()
        } catch { context.rollback(); throw error }
        scheduleBackup()
    }
    func resolveSyncConflict(_ conflict: SyncConflict, candidate: SyncWrite) throws {
        guard var state = try syncState(), conflict.candidates.contains(candidate) else { throw SyncFailure.invalidData }
        let graph = try SyncGraph(state.changes)
        // Never silently resolve a newly arrived branch that the user has not seen.
        guard Set(graph.heads(conflict.entity, conflict.field).map(\.id)) == Set(conflict.candidates.map(\.id)) else { throw StoreFailure.staleItem }
        let write = SyncWrite(entity: conflict.entity, field: conflict.field, parents: conflict.candidates.map(\.id), value: candidate.value)
        let change = SyncChange(writerID: state.writerID, date: .now, writes: [write])
        try appendCurrent(change, to: &state)
        do { try applyProjection(state); try putSyncState(state); try context.save() }
        catch { context.rollback(); throw error }
        scheduleBackup(); onBusinessChange?()
    }
    func mergeSyncBackup(_ archive: StoreArchive) throws {
        guard var state = try syncState() else { throw SyncFailure.invalidData }
        let before = try BackupCodec.encode(self.archive())
        try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        try StorageMaintenance.atomicWrite(before, to: paths.backups.appendingPathComponent("before-restore.pindobackup"))
        var imported: [SyncChange]
        if let row = archive.records.first(where: { $0.bucket == "sync-state" }) {
            let old = try JSONDecoder().decode(SyncState.self, from: row.payload)
            imported = old.current?.protocolVersion == 3 ? old.changes : try SyncCurrent.upgrading(old.changes, writer: old.writerID)
        } else {
            let contents = try SyncContents(
                items: archive.records.filter { $0.bucket.hasPrefix("todo-") }.map { try JSONDecoder().decode(TodoItem.self, from: $0.payload) },
                projects: archive.records.filter { $0.bucket == "project" }.map { try JSONDecoder().decode(Project.self, from: $0.payload) },
                events: archive.records.filter { $0.bucket == "event" }.map { try JSONDecoder().decode(TodoEvent.self, from: $0.payload) })
            var empty = SyncState(); empty.writerID = state.writerID; empty.current = CurrentSyncState()
            imported = try SyncBuilder.capture(before: SyncContents(items: [], projects: [], events: []), after: contents, state: empty).map { [$0] } ?? []
            let current = try SyncGraph(state.changes)
            // Legacy snapshots have no causal evidence. Do not replay their lifecycle over current decisions.
            for index in imported.indices {
                imported[index].writes.removeAll { ["identity", "lifecycle"].contains($0.field) && !current.heads($0.entity, $0.field).isEmpty }
                for w in imported[index].writes.indices where imported[index].writes[w].field == "membership" {
                    let write = imported[index].writes[w]
                    let membership = try SyncCodec.decode(SyncMembership.self, write.value)
                    if let projectID = membership.projectID,
                       let generation = current.writes.values.filter({ $0.entity == SyncGraph.entity("project", projectID) && $0.field == "lifecycle" && (try? SyncCodec.decode(SyncLife.self, $0.value).status) == "active" }).sorted(by: { $0.id.uuidString < $1.id.uuidString }).first?.id {
                        imported[index].writes[w] = SyncWrite(id: write.id, entity: write.entity, field: write.field, parents: write.parents,
                            value: try SyncCodec.encode(SyncMembership(projectID: projectID, generation: generation,
                                generationDot: try SyncCodec.decode(SyncLife.self, current.writes[generation]!.value).generation)))
                    }
                }
            }
        }
        for change in imported { try appendCurrent(change, to: &state) }
        do { try applyProjection(state); try putSyncState(state); try context.save() }
        catch { context.rollback(); throw error }
        scheduleBackup(); onBusinessChange?()
    }

    private func applyProjection(_ state: SyncState) throws {
        let projection = try SyncGraph(state.changes).projection()
        for project in projection.projects { try put(project) }
        for item in projection.items { try put(item) }
        for event in projection.events {
            let key = "event:" + event.id.uuidString
            let bytes = try JSONEncoder().encode(event)
            if let row = try record(key: key) {
                guard try SyncCodec.encode(JSONDecoder().decode(TodoEvent.self, from: row.payload)) == SyncCodec.encode(event) else { throw SyncFailure.identityCollision }
            } else { context.insert(StoreRecord(key: key, bucket: "event", payload: bytes)) }
        }
        let kept = Set(projection.events.map(\.id))
        for row in try records(in: "event") where !kept.contains(try JSONDecoder().decode(TodoEvent.self, from: row.payload).id) { context.delete(row) }
    }

    func stageCurrent(_ records: [SyncEntityRecord]) throws {
        guard var state = try syncState(), state.current != nil else { throw SyncFailure.invalidData }
        for record in records where record.revision > state.current!.seen[record.entity, default: 0] {
            if record.revision >= (state.current!.inbox[record.entity]?.revision ?? 0) { state.current!.inbox[record.entity] = record }
        }
        try saveSyncState(state)
    }
    func sealCurrent() throws -> [SyncMutation] {
        guard var state = try syncState(), state.current != nil else { throw SyncFailure.invalidData }
        for (entity, mutation) in state.current!.outbox where state.current!.flights[entity] == nil {
            state.current!.flights[entity] = mutation; state.current!.outbox.removeValue(forKey: entity)
        }
        try saveSyncState(state)
        return state.current!.flights.values.sorted { $0.entity < $1.entity }
    }
    func acknowledgeCurrent(_ mutation: SyncMutation) throws {
        guard var state = try syncState(), state.current != nil else { throw SyncFailure.invalidData }
        if state.current!.flights[mutation.entity]?.sequence == mutation.sequence, state.current!.flights[mutation.entity]?.id == mutation.id {
            state.current!.flights.removeValue(forKey: mutation.entity)
            state.current!.acknowledged[mutation.entity] = max(state.current!.acknowledged[mutation.entity, default: 0], mutation.sequence)
        }
        try saveSyncState(state)
    }
    func noteCleanup(_ pending: Bool) throws {
        guard var state = try syncState(), state.current != nil else { throw SyncFailure.invalidData }
        state.current!.cleanupPending = pending; try saveSyncState(state)
    }
}
