import CryptoKit
import Foundation

struct StoreMetadata: Codable, Sendable {
    var formatVersion: Int = 2
    static var record: StoredValue {
        StoredValue(key: "storage-meta", bucket: "storage-meta", payload: Data("{\"formatVersion\":2}".utf8))
    }
}

/// Deliberately frozen v0.1 payloads; never decode old data with the current TodoItem.
enum LegacyDataMigration {
    struct Item: Codable {
        let id: UUID
        let title: String
        let notes: String
        let dueAt: Date?
        let stars: Int
        let category: TodoCategory?
        let status: TodoStatus
        let createdAt: Date
        let updatedAt: Date
        let completedAt: Date?
        let abandonedAt: Date?
    }
    struct Draft: Codable {
        let id: UUID
        let isNew: Bool
        let title: String
        let notes: String
        let hasDeadline: Bool
        let dueAt: Date
        let stars: Int
        let categoryID: String
    }

    // Fixed namespaced mapping makes repeated legacy restores and interrupted migrations stable.
    static func projectID(for categoryID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("local.pindo.legacy.category:" + categoryID).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func convert(_ archive: StoreArchive) throws -> StoreArchive {
        guard archive.formatVersion == 1 else { throw StoreFailure.unsupportedVersion }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        var categories: [String: TodoCategory] = [:]
        var latest: [String: Date] = [:]
        var items: [Item] = []
        var legacyDraft: Draft?
        var output: [StoredValue] = []
        guard Set(archive.records.map(\.key)).count == archive.records.count else { throw StoreFailure.invalidBackup }
        for record in archive.records {
            switch record.bucket {
            case "todo-active", "todo-completed", "todo-abandoned":
                let item = try decoder.decode(Item.self, from: record.payload)
                guard record.key == "todo:\(item.id.uuidString)", record.bucket == "todo-\(item.status.rawValue)" else { throw StoreFailure.invalidBackup }
                items.append(item)
                if let category = item.category, item.updatedAt >= (latest[category.id] ?? .distantPast) {
                    categories[category.id] = category; latest[category.id] = item.updatedAt
                }
            case "draft":
                guard record.key == "editor-draft", legacyDraft == nil else { throw StoreFailure.invalidBackup }
                legacyDraft = try decoder.decode(Draft.self, from: record.payload)
            case "event": output.append(record)
            default: throw StoreFailure.invalidBackup
            }
        }
        if let draft = legacyDraft, !draft.categoryID.isEmpty, categories[draft.categoryID] == nil {
            guard let category = TodoCategory.examples.first(where: { $0.id == draft.categoryID }) else { throw StoreFailure.invalidBackup }
            categories[category.id] = category
        }
        let projects = categories.mapValues { Project(legacy: $0, id: projectID(for: $0.id), now: archive.createdAt) }
        for project in projects.values {
            output.append(StoredValue(key: "project:\(project.id.uuidString)", bucket: "project", payload: try encoder.encode(project)))
        }
        for old in items {
            var item = TodoItem(id: old.id, title: old.title, notes: old.notes, dueAt: old.dueAt,
                                stars: old.stars, projectID: old.category.flatMap { projects[$0.id]?.id }, createdAt: old.createdAt)
            // Do not clamp invalid legacy stars into a seemingly successful migration.
            item.stars = old.stars; item.status = old.status; item.updatedAt = old.updatedAt
            item.completedAt = old.completedAt; item.abandonedAt = old.abandonedAt
            output.append(StoredValue(key: "todo:\(item.id.uuidString)", bucket: "todo-\(item.status.rawValue)", payload: try encoder.encode(item)))
        }
        if let old = legacyDraft {
            var draft = NoteDraft(id: old.id, isNew: old.isNew, title: old.title, notes: old.notes,
                                  hasDeadline: old.hasDeadline, dueAt: old.dueAt, stars: old.stars,
                                  projectID: projects[old.categoryID]?.id)
            if !old.categoryID.isEmpty, draft.projectID == nil { throw StoreFailure.invalidBackup }
            // An editing draft must still refer to an active item.
            if !draft.isNew, !items.contains(where: { $0.id == draft.id && $0.status == .active }) { throw StoreFailure.invalidBackup }
            draft.title = old.title
            output.append(StoredValue(key: "editor-draft", bucket: "draft", payload: try encoder.encode(draft)))
        }
        output.append(StoreMetadata.record)
        let result = StoreArchive(appVersion: archive.appVersion, createdAt: archive.createdAt, records: output)
        try result.validate()
        return result
    }
}
