import Foundation
import SwiftData

/// A fresh, read-only context; the single fetch contains business rows and their conflict metadata.
actor AnalyticsReader: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor
    init(container: ModelContainer) {
        modelContainer = container
        let context = ModelContext(container); context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }
    func read() throws -> AnalyticsInput {
        try Task.checkCancellation()
        let context = ModelContext(modelContainer); context.autosaveEnabled = false
        let values = try context.fetch(FetchDescriptor<StoreRecord>()).map { StoredValue(key: $0.key, bucket: $0.bucket, payload: $0.payload) }
        return try Self.decode(values)
    }
    nonisolated static func decode(_ values: [StoredValue]) throws -> AnalyticsInput {
        let decoder = JSONDecoder()
        var items: [TodoItem] = [], projects: [Project] = [], issues: [UUID: Set<String>] = [:]
        for value in values {
            if value.bucket.hasPrefix("todo-") {
                let item = try decoder.decode(TodoItem.self, from: value.payload)
                try StoreArchive.validate(item)
                guard value.key == "todo:" + item.id.uuidString, value.bucket == "todo-" + item.status.rawValue else { throw StoreFailure.inconsistentStore }
                items.append(item)
            } else if value.bucket == "project" {
                let project = try decoder.decode(Project.self, from: value.payload)
                try StoreArchive.validate(project)
                guard value.key == "project:" + project.id.uuidString else { throw StoreFailure.inconsistentStore }
                projects.append(project)
            } else if value.bucket == "sync-state" {
                let state = try decoder.decode(SyncState.self, from: value.payload)
                guard value.key == "sync-state", state.version == 1 else { throw StoreFailure.inconsistentStore }
                for conflict in try SyncGraph(state.changes).conflicts() where conflict.entity.hasPrefix("todo:") {
                    guard let id = UUID(uuidString: String(conflict.entity.dropFirst(5))) else { throw StoreFailure.inconsistentStore }
                    issues[id, default: []].insert(conflict.field)
                }
            }
        }
        guard Set(items.map(\.id)).count == items.count, Set(projects.map(\.id)).count == projects.count else { throw StoreFailure.inconsistentStore }
        return AnalyticsInput(items: items, projects: projects, issues: issues)
    }
}
