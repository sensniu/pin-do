import CryptoKit
import Foundation
import SwiftData

struct StoredValue: Codable, Sendable {
    let key: String
    let bucket: String
    let payload: Data
}

struct StoreArchive: Codable, Sendable {
    var formatVersion: Int = 2
    let appVersion: String
    let createdAt: Date
    let records: [StoredValue]

    func upgraded() throws -> StoreArchive {
        if formatVersion == 1 { return try LegacyDataMigration.convert(self) }
        try validate()
        return self
    }

    func validate() throws {
        if formatVersion == 1 { _ = try LegacyDataMigration.convert(self); return }
        guard [2, 3].contains(formatVersion) else { throw StoreFailure.unsupportedVersion }
        guard Set(records.map(\.key)).count == records.count else { throw StoreFailure.invalidBackup }
        let decoder = JSONDecoder()
        var items: [UUID: TodoItem] = [:], projects: [UUID: Project] = [:]
        var events: [TodoEvent] = []
        var draft: NoteDraft?
        var metadata = 0
        var syncRecords = 0
        var syncProjection: (items: [TodoItem], projects: [Project], events: [TodoEvent])?
        for record in records {
            switch record.bucket {
            case "todo-active", "todo-completed", "todo-abandoned", "todo-conflicted":
                let item = try decoder.decode(TodoItem.self, from: record.payload)
                try Self.validate(item)
                guard record.key == "todo:\(item.id.uuidString)", record.bucket == "todo-\(item.status.rawValue)" else { throw StoreFailure.invalidBackup }
                items[item.id] = item
            case "project":
                let project = try decoder.decode(Project.self, from: record.payload)
                try Self.validate(project)
                guard record.key == "project:\(project.id.uuidString)" else { throw StoreFailure.invalidBackup }
                projects[project.id] = project
            case "event":
                let event = try decoder.decode(TodoEvent.self, from: record.payload)
                guard record.key == "event:\(event.id.uuidString)", event.occurredAt.timeIntervalSince1970.isFinite else { throw StoreFailure.invalidBackup }
                events.append(event)
            case "draft":
                guard record.key == "editor-draft", draft == nil else { throw StoreFailure.invalidBackup }
                draft = try decoder.decode(NoteDraft.self, from: record.payload)
            case "sync-state":
                guard formatVersion == 3, record.key == "sync-state" else { throw StoreFailure.invalidBackup }
                let state = try JSONDecoder().decode(SyncState.self, from: record.payload)
                guard state.version == 1 else { throw StoreFailure.unsupportedVersion }
                syncProjection = try SyncGraph(state.changes).projection()
                syncRecords += 1
            case "storage-meta":
                guard record.key == "storage-meta", try decoder.decode(StoreMetadata.self, from: record.payload).formatVersion == formatVersion else { throw StoreFailure.unsupportedVersion }
                metadata += 1
            default: throw StoreFailure.invalidBackup
            }
        }
        guard metadata == 1, syncRecords == (formatVersion == 3 ? 1 : 0) else { throw StoreFailure.invalidBackup }
        for item in items.values {
            if let id = item.projectID {
                guard let project = projects[id], item.status != .active || project.status == .active else { throw StoreFailure.invalidBackup }
            }
            for assignment in item.projectAssignments {
                guard assignment.changedAt.timeIntervalSince1970.isFinite,
                      assignment.previousProjectID.map({ projects[$0] != nil }) ?? true,
                      assignment.projectID.map({ projects[$0] != nil }) ?? true else { throw StoreFailure.invalidBackup }
            }
        }
        if let draft {
            guard (1...3).contains(draft.stars), draft.dueAt.timeIntervalSince1970.isFinite,
                  draft.projectID.map({ formatVersion == 3 ? projects[$0] != nil : projects[$0]?.status == .active }) ?? true,
                  draft.isNew || items[draft.id] != nil else { throw StoreFailure.invalidBackup }
        }
        if let projection = syncProjection {
            func encodedItems(_ values: [TodoItem]) throws -> Data { try SyncCodec.encode(values.sorted { $0.id.uuidString < $1.id.uuidString }) }
            func encodedProjects(_ values: [Project]) throws -> Data { try SyncCodec.encode(values.sorted { $0.id.uuidString < $1.id.uuidString }) }
            func encodedEvents(_ values: [TodoEvent]) throws -> Data { try SyncCodec.encode(values.sorted { $0.id.uuidString < $1.id.uuidString }) }
            guard try encodedItems(Array(items.values)) == encodedItems(projection.items),
                  try encodedProjects(Array(projects.values)) == encodedProjects(projection.projects),
                  try encodedEvents(events) == encodedEvents(projection.events) else { throw StoreFailure.invalidBackup }
        }
        guard events.allSatisfy({ items[$0.itemID] != nil }) else { throw StoreFailure.invalidBackup }
        let completed = Dictionary(uniqueKeysWithValues: events.filter { $0.kind == .completed }.map { ($0.id, $0.itemID) })
        for event in events where event.kind == .completionUndone {
            guard let related = event.relatedCompletionID, completed[related] == event.itemID else { throw StoreFailure.invalidBackup }
        }
    }

    static func validate(_ project: Project) throws {
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [project.red, project.green, project.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              project.createdAt.timeIntervalSince1970.isFinite, project.updatedAt.timeIntervalSince1970.isFinite else { throw StoreFailure.invalidProject }
        switch project.status {
        case .active: guard project.archivedAt == nil, project.deletedAt == nil else { throw StoreFailure.invalidProject }
        case .archived: guard project.archivedAt != nil, project.deletedAt == nil else { throw StoreFailure.invalidProject }
        case .deleted: guard project.deletedAt != nil else { throw StoreFailure.invalidProject }
        }
    }

    static func validate(_ item: TodoItem) throws {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...3).contains(item.stars), item.createdAt.timeIntervalSince1970.isFinite,
              item.updatedAt.timeIntervalSince1970.isFinite,
              item.dueAt?.timeIntervalSince1970.isFinite ?? true else { throw StoreFailure.invalidItem }
        switch item.status {
        case .active:
            guard item.completedAt == nil, item.abandonedAt == nil else { throw StoreFailure.invalidItem }
        case .completed:
            guard item.completedAt?.timeIntervalSince1970.isFinite == true, item.abandonedAt == nil else { throw StoreFailure.invalidItem }
        case .conflicted:
            guard item.completedAt == nil, item.abandonedAt == nil else { throw StoreFailure.invalidItem }
        case .abandoned:
            guard item.abandonedAt?.timeIntervalSince1970.isFinite == true, item.completedAt == nil else { throw StoreFailure.invalidItem }
        }
    }
}

enum BackupCodec {
    private struct Envelope: Codable {
        let formatVersion: Int
        let checksum: String
        let payload: Data
    }

    static func encode(_ archive: StoreArchive) throws -> Data {
        try archive.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(archive)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return try encoder.encode(Envelope(formatVersion: 1, checksum: checksum, payload: payload))
    }

    static func decode(_ data: Data) throws -> StoreArchive {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.formatVersion == 1 else { throw StoreFailure.unsupportedVersion }
        let checksum = SHA256.hash(data: envelope.payload).map { String(format: "%02x", $0) }.joined()
        guard checksum == envelope.checksum else { throw StoreFailure.invalidBackup }
        let archive = try JSONDecoder().decode(StoreArchive.self, from: envelope.payload)
        return try archive.upgraded()
    }
}

/// A storage-confined background executor, equivalent to the public ModelActor expansion.
actor BackupService: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    init(container: ModelContainer) {
        modelContainer = container
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    func writeAutomaticBackup(to directory: URL, appVersion: String) throws {
        try Task.checkCancellation()
        // A fresh reader avoids reusing objects cached before another context's last commit.
        let snapshotContext = ModelContext(modelContainer)
        snapshotContext.autosaveEnabled = false
        let records = try snapshotContext.fetch(FetchDescriptor<StoreRecord>()).map {
            StoredValue(key: $0.key, bucket: $0.bucket, payload: $0.payload)
        }
        var archive = StoreArchive(appVersion: appVersion, createdAt: .now, records: records)
        archive.formatVersion = records.contains { $0.bucket == "sync-state" } ? 3 : 2
        let data = try BackupCodec.encode(archive)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: .now)
        let name = String(format: "daily-%04d-%02d-%02d.pindobackup", parts.year!, parts.month!, parts.day!)
        // Atomic replacement refreshes today's backup rather than accumulating files per edit.
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        let daily = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("daily-") && $0.pathExtension == "pindobackup" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for expired in daily.dropFirst(7) { try FileManager.default.removeItem(at: expired) }
    }
}

