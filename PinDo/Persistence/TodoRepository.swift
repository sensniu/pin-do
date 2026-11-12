import Darwin
import Foundation
import SwiftData

@MainActor
protocol TodoPersisting: AnyObject {
    @discardableResult func commit(_ item: TodoItem, event: TodoEvent, clearDraft: Bool) throws -> TodoItem
    func saveDraft(_ draft: NoteDraft?) throws
}

@MainActor
protocol ProjectPersisting: TodoPersisting {
    func loadBoardData() throws -> BoardData
    func createProject(name: String) throws -> Project
    func updateProject(id: UUID, name: String, color: ProjectColor) throws -> Project
    func renameProject(id: UUID, name: String) throws -> Project
    func archiveProject(id: UUID) throws -> BoardData
    func restoreProject(id: UUID) throws -> Project
    func deleteProject(id: UUID, action: UnfinishedProjectAction) throws -> BoardData
}

final class PreparedStore: Sendable {
    let container: ModelContainer
    let descriptor: Int32
    init(container: ModelContainer, descriptor: Int32) { self.container = container; self.descriptor = descriptor }
    deinit { close(descriptor) }
}

@MainActor
final class TodoRepository: ProjectPersisting {
    let paths: AppPaths
    private let container: ModelContainer
    private let context: ModelContext
    private let backupService: Task<BackupService, Never>
    private let prepared: PreparedStore
    private let appVersion: String
    private var backupTask: Task<Void, Never>?
    var onBackupFailure: ((String) -> Void)?

    convenience init(paths: AppPaths, appVersion: String) throws {
        try self.init(paths: paths, appVersion: appVersion, prepared: Self.prepareForOpening(paths: paths, appVersion: appVersion))
    }

    init(paths: AppPaths, appVersion: String, prepared: PreparedStore) {
        self.paths = paths; self.appVersion = appVersion; self.prepared = prepared
        let container = prepared.container
        self.container = container; self.context = ModelContext(container)
        self.context.autosaveEnabled = false
        self.backupService = Task.detached(priority: .utility) { BackupService(container: container) }
    }

    nonisolated static func prepareForOpening(paths: AppPaths, appVersion: String) throws -> PreparedStore {
        let files = FileManager.default
        try files.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(paths.root.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw StoreFailure.inconsistentStore }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw StoreFailure.alreadyOpen }
        do {
            return PreparedStore(container: try prepare(paths: paths, appVersion: appVersion), descriptor: descriptor)
        } catch { close(descriptor); throw error }
    }

    /// Versioned payload migration and the manifest handshake run before any board is created.
    nonisolated private static func prepare(paths: AppPaths, appVersion: String) throws -> ModelContainer {
        let files = FileManager.default
        let hasStore = files.fileExists(atPath: paths.store.path)
        let hasManifest = files.fileExists(atPath: paths.manifest.path)
        var manifest: StoreManifest
        if hasManifest {
            manifest = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: paths.manifest))
            guard (1...2).contains(manifest.formatVersion), appVersion.compare(manifest.lastAppVersion, options: .numeric) != .orderedAscending else { throw StoreFailure.unsupportedVersion }
            guard hasStore || (manifest.migrationPending == true && manifest.upgradeSnapshot == nil && manifest.formatVersion == 2) else { throw StoreFailure.inconsistentStore }
            if let snapshot = manifest.upgradeSnapshot {
                guard manifest.migrationPending == true, snapshot.hasPrefix("before-upgrade-"), !snapshot.contains("/"), !snapshot.contains("..") else { throw StoreFailure.inconsistentStore }
                let directory = paths.backups.appendingPathComponent(snapshot)
                guard files.fileExists(atPath: directory.appendingPathComponent("PinDo.store").path),
                      files.fileExists(atPath: directory.appendingPathComponent("StoreInfo.json").path) else { throw StoreFailure.inconsistentStore }
                let previous = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: directory.appendingPathComponent("StoreInfo.json")))
                guard previous.storeID == manifest.storeID else { throw StoreFailure.inconsistentStore }
            }
        } else {
            let children = try files.contentsOfDirectory(atPath: paths.root.path)
                .filter { $0 != "store.lock" && $0 != ".DS_Store" }
            guard !hasStore, children.isEmpty else { throw StoreFailure.inconsistentStore }
            manifest = StoreManifest(storeID: UUID(), createdAt: .now, lastAppVersion: appVersion,
                                     migrationPending: true)
            try JSONEncoder().encode(manifest).write(to: paths.manifest, options: .atomic)
        }
        let schema = Schema(versionedSchema: StoreSchemaV1.self)
        let config = ModelConfiguration(schema: schema, url: paths.store, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: StoreMigrationPlan.self, configurations: [config])
        let context = ModelContext(container); context.autosaveEnabled = false
        let all = try context.fetch(FetchDescriptor<StoreRecord>())
        let metadata = all.filter { $0.key == "storage-meta" }
        let legacy = manifest.formatVersion == 1 || (manifest.migrationPending == true && manifest.upgradeSnapshot != nil)
        if metadata.isEmpty && legacy {
            var archive = StoreArchive(appVersion: manifest.lastAppVersion, createdAt: .now,
                                       records: all.map { StoredValue(key: $0.key, bucket: $0.bucket, payload: $0.payload) })
            archive.formatVersion = 1
            let converted = try archive.upgraded()
            if manifest.upgradeSnapshot == nil { manifest.upgradeSnapshot = try backupClosedStore(paths: paths) }
            manifest.formatVersion = 2; manifest.migrationPending = true; manifest.lastAppVersion = appVersion
            try JSONEncoder().encode(manifest).write(to: paths.manifest, options: .atomic)
            do {
                for row in all { context.delete(row) }
                for record in converted.records { context.insert(StoreRecord(key: record.key, bucket: record.bucket, payload: record.payload)) }
                try context.save()
            } catch { context.rollback(); throw error }
        } else if metadata.isEmpty {
            guard all.isEmpty, manifest.migrationPending == true, manifest.upgradeSnapshot == nil else { throw StoreFailure.inconsistentStore }
            let meta = StoreMetadata.record
            context.insert(StoreRecord(key: meta.key, bucket: meta.bucket, payload: meta.payload))
            try context.save()
        } else {
            guard manifest.formatVersion == 2, metadata.count == 1, metadata[0].bucket == "storage-meta", try JSONDecoder().decode(StoreMetadata.self, from: metadata[0].payload).formatVersion == 2 else { throw StoreFailure.unsupportedVersion }
            if manifest.migrationPending == true {
                let archive = StoreArchive(appVersion: appVersion, createdAt: .now,
                                           records: all.map { StoredValue(key: $0.key, bucket: $0.bucket, payload: $0.payload) })
                try archive.validate()
            } else if manifest.lastAppVersion != appVersion {
                _ = try backupClosedStore(paths: paths)
            }
        }
        manifest.formatVersion = 2; manifest.lastAppVersion = appVersion
        manifest.migrationPending = nil; manifest.upgradeSnapshot = nil
        try JSONEncoder().encode(manifest).write(to: paths.manifest, options: .atomic)
        return container
    }

    deinit { backupTask?.cancel() }

    func loadProjects() throws -> [Project] {
        try records(in: "project").map {
            let project = try JSONDecoder().decode(Project.self, from: $0.payload)
            try StoreArchive.validate(project)
            guard $0.key == "project:\(project.id.uuidString)" else { throw StoreFailure.inconsistentStore }
            return project
        }
    }

    func loadBoardData() throws -> BoardData {
        let projects = try loadProjects()
        guard Set(projects.map(\.id)).count == projects.count else { throw StoreFailure.inconsistentStore }
        let lookup = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let items = try loadActiveItems()
        guard Set(items.map(\.id)).count == items.count else { throw StoreFailure.inconsistentStore }
        for item in items {
            if let id = item.projectID, lookup[id]?.status != .active { throw StoreFailure.inconsistentStore }
            for assignment in item.projectAssignments {
                guard assignment.changedAt.timeIntervalSince1970.isFinite,
                      assignment.previousProjectID.map({ lookup[$0] != nil }) ?? true,
                      assignment.projectID.map({ lookup[$0] != nil }) ?? true else { throw StoreFailure.inconsistentStore }
            }
        }
        return BoardData(projects: projects, items: items)
    }

    func loadActiveItems() throws -> [TodoItem] {
        try records(in: "todo-active").map {
            let item = try JSONDecoder().decode(TodoItem.self, from: $0.payload)
            try StoreArchive.validate(item)
            guard $0.key == "todo:\(item.id.uuidString)", item.status == .active else { throw StoreFailure.inconsistentStore }
            return item
        }
    }

    func loadDraft() throws -> NoteDraft? {
        guard let row = try record(key: "editor-draft") else { return nil }
        let draft = try JSONDecoder().decode(NoteDraft.self, from: row.payload)
        guard (1...3).contains(draft.stars), draft.dueAt.timeIntervalSince1970.isFinite else { throw StoreFailure.inconsistentStore }
        if let id = draft.projectID, try project(id).status != .active { throw StoreFailure.inconsistentStore }
        if !draft.isNew {
            guard let row = try record(key: "todo:\(draft.id.uuidString)"), row.bucket == "todo-active" else { throw StoreFailure.inconsistentStore }
        }
        return draft
    }

    @discardableResult func commit(_ incoming: TodoItem, event: TodoEvent, clearDraft: Bool) throws -> TodoItem {
        var item = incoming
        try StoreArchive.validate(item)
        guard event.itemID == item.id else { throw StoreFailure.invalidItem }
        do {
            let key = "todo:\(item.id.uuidString)"
            let existing = try record(key: key)
            var prior: TodoItem?
            if event.kind == .created {
                guard existing == nil, item.status == .active else { throw StoreFailure.staleItem }
                item.projectAssignments = []
            } else {
                guard let existing else { throw StoreFailure.staleItem }
                prior = try JSONDecoder().decode(TodoItem.self, from: existing.payload)
                let required: TodoStatus = event.kind == .completionUndone ? .completed : .active
                guard prior?.status == required else { throw StoreFailure.staleItem }
                let expected: TodoStatus = event.kind == .completed ? .completed : (event.kind == .abandoned ? .abandoned : .active)
                guard item.status == expected, prior?.createdAt == item.createdAt else { throw StoreFailure.staleItem }
                item.projectAssignments = prior!.projectAssignments
            }
            if let id = item.projectID {
                let target = try project(id)
                if item.status == .active && target.status != .active {
                    guard event.kind == .completionUndone else { throw StoreFailure.invalidProject }
                    item.projectID = nil
                }
            }
            if let prior, prior.projectID != item.projectID {
                item.projectAssignments.append(ProjectAssignment(previousProjectID: prior.projectID, projectID: item.projectID,
                    changedAt: item.updatedAt, reason: event.kind == .completionUndone ? .completionRestored : .manual))
            }
            guard try record(key: "event:\(event.id.uuidString)") == nil else { throw StoreFailure.staleItem }
            if event.kind == .completionUndone {
                guard let id = event.relatedCompletionID, let row = try record(key: "event:\(id.uuidString)") else { throw StoreFailure.staleItem }
                let completion = try JSONDecoder().decode(TodoEvent.self, from: row.payload)
                guard completion.itemID == item.id, completion.kind == .completed else { throw StoreFailure.staleItem }
            }
            try put(item)
            context.insert(StoreRecord(key: "event:\(event.id.uuidString)", bucket: "event", payload: try JSONEncoder().encode(event)))
            if clearDraft, let draft = try record(key: "editor-draft") { context.delete(draft) }
            try context.save()
        } catch { context.rollback(); throw error }
        scheduleBackup()
        return item
    }

    func saveDraft(_ draft: NoteDraft?) throws {
        do { try putDraft(draft); try context.save() }
        catch { context.rollback(); throw error }
    }

    private func putDraft(_ draft: NoteDraft?) throws {
        let row = try record(key: "editor-draft")
        if let draft {
            guard (1...3).contains(draft.stars), draft.dueAt.timeIntervalSince1970.isFinite else { throw StoreFailure.invalidItem }
            if let id = draft.projectID, try project(id).status != .active { throw StoreFailure.invalidProject }
            let data = try JSONEncoder().encode(draft)
            if let row { row.payload = data }
            else { context.insert(StoreRecord(key: "editor-draft", bucket: "draft", payload: data)) }
        } else if let row { context.delete(row) }
    }

    func createProject(name: String) throws -> Project {
        let project = Project(name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: try loadProjects().count)
        return try saveProject(project)
    }

    func renameProject(id: UUID, name: String) throws -> Project {
        var value = try project(id)
        guard value.status != .deleted else { throw StoreFailure.invalidProject }
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines); value.updatedAt = .now
        return try saveProject(value)
    }

    func updateProject(id: UUID, name: String, color: ProjectColor) throws -> Project {
        var value = try project(id)
        guard value.status != .deleted else { throw StoreFailure.invalidProject }
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.red = color.red; value.green = color.green; value.blue = color.blue
        value.updatedAt = .now
        return try saveProject(value)
    }

    func restoreProject(id: UUID) throws -> Project {
        var value = try project(id)
        guard value.status == .archived else { throw StoreFailure.invalidProject }
        value.status = .active; value.archivedAt = nil; value.updatedAt = .now
        return try saveProject(value)
    }

    private func saveProject(_ value: Project) throws -> Project {
        do { try put(value); try context.save() } catch { context.rollback(); throw error }
        scheduleBackup(); return value
    }

    func archiveProject(id: UUID) throws -> BoardData { try changeProject(id: id, deleting: false, action: .transferToUnassigned) }
    func deleteProject(id: UUID, action: UnfinishedProjectAction) throws -> BoardData { try changeProject(id: id, deleting: true, action: action) }

    private func changeProject(id: UUID, deleting: Bool, action: UnfinishedProjectAction) throws -> BoardData {
        do {
            var value = try project(id)
            guard value.status == .active || (deleting && value.status == .archived) else { throw StoreFailure.invalidProject }
            let now = Date.now
            let items = try loadActiveItems()
            let existingDraft = try loadDraft()
            for var item in items where item.projectID == id {
                item.updatedAt = now
                if deleting && action == .abandon {
                    item.status = .abandoned; item.abandonedAt = now
                    let event = TodoEvent(itemID: item.id, kind: .abandoned, occurredAt: now)
                    context.insert(StoreRecord(key: "event:\(event.id.uuidString)", bucket: "event", payload: try JSONEncoder().encode(event)))
                } else {
                    item.projectID = nil
                    item.projectAssignments.append(ProjectAssignment(previousProjectID: id, projectID: nil, changedAt: now, reason: deleting ? .deleted : .archived))
                }
                try put(item)
            }
            if var draft = existingDraft, draft.projectID == id {
                draft.projectID = nil
                if !draft.isNew, action == .abandon && deleting { try putDraft(nil) }
                else { try putDraft(draft) }
            }
            value.status = deleting ? .deleted : .archived; value.updatedAt = now
            if deleting { value.deletedAt = now } else { value.archivedAt = now }
            try put(value)
            let output = try loadBoardData()
            try context.save()
            scheduleBackup(); return output
        } catch { context.rollback(); throw error }
    }

    private func project(_ id: UUID) throws -> Project {
        guard let row = try record(key: "project:\(id.uuidString)"), row.bucket == "project" else { throw StoreFailure.invalidProject }
        return try JSONDecoder().decode(Project.self, from: row.payload)
    }
    private func put(_ value: Project) throws {
        try StoreArchive.validate(value)
        let data = try JSONEncoder().encode(value)
        if let row = try record(key: "project:\(value.id.uuidString)") { row.payload = data }
        else { context.insert(StoreRecord(key: "project:\(value.id.uuidString)", bucket: "project", payload: data)) }
    }
    private func put(_ item: TodoItem) throws {
        try StoreArchive.validate(item)
        let data = try JSONEncoder().encode(item), key = "todo:\(item.id.uuidString)"
        if let row = try record(key: key) { row.payload = data; row.bucket = "todo-\(item.status.rawValue)" }
        else { context.insert(StoreRecord(key: key, bucket: "todo-\(item.status.rawValue)", payload: data)) }
    }

    func archive() throws -> StoreArchive {
        let archive = StoreArchive(appVersion: appVersion, createdAt: .now, records: try context.fetch(FetchDescriptor<StoreRecord>()).map {
            StoredValue(key: $0.key, bucket: $0.bucket, payload: $0.payload)
        })
        try archive.validate(); return archive
    }

    func restore(_ incoming: StoreArchive) throws {
        let archive = try incoming.upgraded()
        let before = try BackupCodec.encode(self.archive())
        try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        try before.write(to: paths.backups.appendingPathComponent("before-restore.pindobackup"), options: .atomic)
        do {
            for row in try context.fetch(FetchDescriptor<StoreRecord>()) { context.delete(row) }
            for record in archive.records { context.insert(StoreRecord(key: record.key, bucket: record.bucket, payload: record.payload)) }
            try context.save()
        } catch { context.rollback(); throw error }
        scheduleBackup()
    }

    func createAutomaticBackupNow() async throws {
        backupTask?.cancel()
        let worker = await backupService.value
        try await worker.writeAutomaticBackup(to: paths.backups, appVersion: appVersion)
    }

    private func records(in bucket: String) throws -> [StoreRecord] {
        let predicate = Predicate<StoreRecord> { row in
            PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: row, keyPath: \StoreRecord.bucket),
                rhs: PredicateExpressions.build_Arg(bucket)
            )
        }
        return try context.fetch(FetchDescriptor(predicate: predicate))
    }

    private func record(key: String) throws -> StoreRecord? {
        let predicate = Predicate<StoreRecord> { row in
            PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: row, keyPath: \StoreRecord.key),
                rhs: PredicateExpressions.build_Arg(key)
            )
        }
        let matches = try context.fetch(FetchDescriptor(predicate: predicate))
        guard matches.count <= 1 else { throw StoreFailure.inconsistentStore }
        return matches.first
    }

    private func scheduleBackup() {
        backupTask?.cancel()
        let factory = backupService
        let directory = paths.backups
        let version = appVersion
        backupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                let worker = await factory.value
                try Task.checkCancellation()
                try await worker.writeAutomaticBackup(to: directory, appVersion: version)
            } catch is CancellationError {
                return
            } catch {
                self?.onBackupFailure?(error.localizedDescription)
            }
        }
    }

    nonisolated private static func backupClosedStore(paths: AppPaths) throws -> String {
        let files = FileManager.default
        let directory = paths.backups.appendingPathComponent("before-upgrade-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try DatabaseSnapshot.copy(from: paths.store, to: directory.appendingPathComponent("PinDo.store"))
            try files.copyItem(at: paths.manifest, to: directory.appendingPathComponent("StoreInfo.json"))
            let previous = try files.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("before-upgrade-") }
                .sorted {
                    let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return left > right
                }
            for expired in previous.dropFirst(3) { try files.removeItem(at: expired) }
            return directory.lastPathComponent
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }
}

