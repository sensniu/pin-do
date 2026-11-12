import Foundation

/// An immutable per-field DAG. A write only supersedes versions it actually observed.
struct SyncGraph {
    let changes: [SyncChange]
    let writes: [UUID: SyncWrite]
    let grouped: [String: [SyncWrite]]

    init(_ changes: [SyncChange]) throws {
        var changesByID: [UUID: SyncChange] = [:]
        var writes: [UUID: SyncWrite] = [:]
        for raw in changes {
            let change = try SyncCodec.decode(SyncChange.self, SyncCodec.encode(raw))
            guard change.date.timeIntervalSince1970.isFinite else { throw SyncFailure.invalidData }
            if let old = changesByID[change.id], old != change { throw SyncFailure.identityCollision }
            changesByID[change.id] = change
            for write in change.writes {
                let pieces = write.entity.split(separator: ":")
                guard pieces.count == 2, ["todo", "project"].contains(String(pieces[0])), UUID(uuidString: String(pieces[1])) != nil,
                      Self.fields(for: String(pieces[0])).contains(write.field), !write.parents.contains(write.id),
                      Set(write.parents).count == write.parents.count else { throw SyncFailure.invalidData }
                try Self.validate(write)
                if let old = writes[write.id], old != write { throw SyncFailure.identityCollision }
                writes[write.id] = write
            }
        }
        for write in writes.values {
            for parent in write.parents {
                guard let p = writes[parent] else { throw SyncFailure.missingDependency }
                guard p.key == write.key else { throw SyncFailure.invalidData }
            }
        }
        for write in writes.values where write.field == "membership" {
            let membership = try SyncCodec.decode(SyncMembership.self, write.value)
            if let projectID = membership.projectID, let generation = membership.generation {
                guard let activation = writes[generation] else { throw SyncFailure.missingDependency }
                guard activation.entity == Self.entity("project", projectID), activation.field == "lifecycle",
                      try SyncCodec.decode(SyncLife.self, activation.value).status == "active" else { throw SyncFailure.invalidData }
            }
        }
        // Iterative topological validation, including adversarial cycles.
        var remaining = Dictionary(uniqueKeysWithValues: writes.values.map { ($0.id, $0.parents.count) })
        var children: [UUID: [UUID]] = [:]
        for write in writes.values { for parent in write.parents { children[parent, default: []].append(write.id) } }
        var queue = remaining.filter { $0.value == 0 }.map(\.key), offset = 0
        while offset < queue.count {
            let id = queue[offset]; offset += 1
            for child in children[id] ?? [] {
                remaining[child]! -= 1
                if remaining[child] == 0 { queue.append(child) }
            }
        }
        guard queue.count == writes.count else { throw SyncFailure.invalidData }
        self.changes = changesByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        self.writes = writes
        grouped = Dictionary(grouping: writes.values, by: \.key)
    }
    private static func validate(_ write: SyncWrite) throws {
        switch write.field {
        case "identity":
            let value = try SyncCodec.decode(SyncIdentity.self, write.value)
            guard write.entity.hasSuffix(value.id.uuidString.lowercased()), value.createdAt.timeIntervalSince1970.isFinite else { throw SyncFailure.invalidData }
        case "title", "name":
            guard !(try SyncCodec.decode(String.self, write.value)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SyncFailure.invalidData }
        case "notes": _ = try SyncCodec.decode(String.self, write.value)
        case "deadline": _ = try SyncCodec.decode(Date?.self, write.value)
        case "stars": guard (1...3).contains(try SyncCodec.decode(Int.self, write.value)) else { throw SyncFailure.invalidData }
        case "color": guard try SyncCodec.decode(ProjectColor.self, write.value).isValid else { throw SyncFailure.invalidData }
        case "membership":
            let value = try SyncCodec.decode(SyncMembership.self, write.value)
            guard (value.projectID == nil) == (value.generation == nil) else { throw SyncFailure.invalidData }
        case "lifecycle":
            let value = try SyncCodec.decode(SyncLife.self, write.value)
            let allowed = write.entity.hasPrefix("todo:") ? ["active", "completed", "abandoned"] : ["active", "archived", "deleted"]
            guard allowed.contains(value.status), (value.status == "active") == (value.date == nil) else { throw SyncFailure.invalidData }
        default: throw SyncFailure.unsupported
        }
    }
    static func fields(for kind: String) -> Set<String> {
        kind == "todo" ? ["identity", "title", "notes", "deadline", "stars", "membership", "lifecycle"] : ["identity", "name", "color", "lifecycle"]
    }
    static func entity(_ kind: String, _ id: UUID) -> String { kind + ":" + id.uuidString.lowercased() }
    func heads(_ entity: String, _ field: String) -> [SyncWrite] {
        let values = grouped[entity + "/" + field] ?? []
        let superseded = Set(values.flatMap(\.parents))
        return values.filter { !superseded.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func descends(_ write: SyncWrite, from ancestor: UUID) -> Bool {
        var queue = write.parents, seen = Set<UUID>()
        while let id = queue.popLast() {
            if id == ancestor { return true }
            if seen.insert(id).inserted { queue.append(contentsOf: writes[id]?.parents ?? []) }
        }
        return false
    }
    func editParents(_ entity: String, _ field: String) -> [UUID] {
        let candidates = heads(entity, field)
        // Ordinary editors show one preview. Only the conflict UI may retire unseen differing candidates.
        if field == "lifecycle" || Set(candidates.map(\.value)).count <= 1 { return candidates.map(\.id) }
        return candidates.first.map { [$0.id] } ?? []
    }
    func baseline(_ entity: String) -> [String: [UUID]] {
        Dictionary(uniqueKeysWithValues: Self.fields(for: entity.hasPrefix("todo:") ? "todo" : "project").map { ($0, editParents(entity, $0)) })
    }
    func selected(_ entity: String, _ field: String) throws -> SyncWrite {
        let values = heads(entity, field)
        guard !values.isEmpty else { throw SyncFailure.missingDependency }
        if field == "lifecycle" {
            let ranked = try values.map { ($0, try SyncCodec.decode(SyncLife.self, $0.value)) }
            let ranks = ["active": 0, "completed": 1, "archived": 1, "abandoned": 2, "deleted": 2]
            return ranked.sorted {
                let l = ranks[$0.1.status, default: -1], r = ranks[$1.1.status, default: -1]
                return l == r ? $0.0.id.uuidString < $1.0.id.uuidString : l > r
            }[0].0
        }
        return values[0]
    }
    func value<T: Decodable>(_ type: T.Type, _ entity: String, _ field: String) throws -> T {
        try SyncCodec.decode(type, selected(entity, field).value)
    }
    func conflicts() throws -> [SyncConflict] {
        var result: [SyncConflict] = []
        for key in grouped.keys.sorted() {
            guard let first = grouped[key]?.first else { continue }
            let values = heads(first.entity, first.field)
            if first.field == "lifecycle" {
                let statuses = Set(try values.map { try SyncCodec.decode(SyncLife.self, $0.value).status })
                if statuses.contains("completed") && statuses.contains("abandoned") {
                    result.append(SyncConflict(entity: first.entity, field: first.field, candidates: values))
                }
            } else if Set(values.map(\.value)).count > 1 {
                result.append(SyncConflict(entity: first.entity, field: first.field, candidates: values))
            }
        }
        return result
    }
    func projection() throws -> (items: [TodoItem], projects: [Project], events: [TodoEvent]) {
        let entities = Set(writes.values.map(\.entity)).sorted()
        var projects: [Project] = [], items: [TodoItem] = []
        var assignments: [UUID: SyncAssignment] = [:]
        for assignment in changes.flatMap(\.assignments) {
            if let previous = assignments[assignment.id], previous != assignment { throw SyncFailure.identityCollision }
            guard assignment.value.changedAt.timeIntervalSince1970.isFinite else { throw SyncFailure.invalidData }
            assignments[assignment.id] = assignment
        }
        let conflicts = try conflicts()
        for entity in entities where entity.hasPrefix("project:") {
            let identity = try value(SyncIdentity.self, entity, "identity")
            guard entity == Self.entity("project", identity.id) else { throw SyncFailure.invalidData }
            let life = try value(SyncLife.self, entity, "lifecycle")
            let color = try value(ProjectColor.self, entity, "color")
            var project = Project(id: identity.id, name: try value(String.self, entity, "name"), now: identity.createdAt)
            guard let status = ProjectStatus(rawValue: life.status) else { throw SyncFailure.invalidData }
            project.status = status; project.red = color.red; project.green = color.green; project.blue = color.blue
            project.updatedAt = updated(entity, fallback: identity.updatedAt ?? identity.createdAt)
            project.archivedAt = status == .archived ? life.date : nil
            project.deletedAt = status == .deleted ? life.date : nil
            try StoreArchive.validate(project); projects.append(project)
        }
        let lookup = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        for entity in entities where entity.hasPrefix("todo:") {
            let identity = try value(SyncIdentity.self, entity, "identity")
            guard entity == Self.entity("todo", identity.id) else { throw SyncFailure.invalidData }
            let life = try value(SyncLife.self, entity, "lifecycle")
            let membership = try value(SyncMembership.self, entity, "membership")
            var item = TodoItem(id: identity.id, title: try value(String.self, entity, "title"), notes: try value(String.self, entity, "notes"),
                                dueAt: try value(Date?.self, entity, "deadline"), stars: try value(Int.self, entity, "stars"), projectID: membership.projectID, createdAt: identity.createdAt)
            guard let status = TodoStatus(rawValue: life.status) else { throw SyncFailure.invalidData }
            item.status = conflicts.contains(where: { $0.entity == entity && $0.field == "lifecycle" }) ? .conflicted : status
            item.completedAt = item.status == .completed ? life.date : nil
            item.abandonedAt = item.status == .abandoned ? life.date : nil
            item.updatedAt = updated(entity, fallback: identity.updatedAt ?? identity.createdAt)
            item.projectAssignments = assignments.values.filter { $0.itemID == item.id }
                .sorted { $0.id.uuidString < $1.id.uuidString }.map(\.value)
            if let projectID = membership.projectID {
                guard let project = lookup[projectID] else { throw SyncFailure.missingDependency }
                let pe = Self.entity("project", projectID)
                let generations = try heads(pe, "lifecycle").filter { try SyncCodec.decode(SyncLife.self, $0.value).status == "active" }.map(\.id)
                if item.status == .active && (project.status != .active || membership.generation.map { !generations.contains($0) } == true) {
                    item.projectID = nil
                    let barriers = try (grouped[pe + "/lifecycle"] ?? []).filter { write in
                        let status = try SyncCodec.decode(SyncLife.self, write.value).status
                        return status != "active" && membership.generation.map { descends(write, from: $0) } == true
                    }
                    let firstBarriers = barriers.filter { write in !barriers.contains { $0.id != write.id && descends(write, from: $0.id) } }
                    let terminal = try firstBarriers.sorted { $0.id.uuidString < $1.id.uuidString }.first ?? selected(pe, "lifecycle")
                    let terminalLife = try SyncCodec.decode(SyncLife.self, terminal.value)
                    let date = terminalLife.date ?? project.updatedAt
                    let assignment = ProjectAssignment(previousProjectID: projectID, projectID: nil, changedAt: date, reason: terminalLife.status == "deleted" ? .deleted : .archived)
                    if !item.projectAssignments.contains(assignment) { item.projectAssignments.append(assignment) }
                }
            }
            if item.status == .active && conflicts.contains(where: { $0.entity == entity && $0.field == "membership" }) { item.projectID = nil }
            try StoreArchive.validate(item); items.append(item)
        }
        var events: [UUID: TodoEvent] = [:]
        for event in changes.flatMap(\.events) {
            if let old = events[event.id], old != event { throw SyncFailure.identityCollision }
            guard items.contains(where: { $0.id == event.itemID }) else { throw SyncFailure.missingDependency }
            events[event.id] = event
        }
        for event in events.values {
            guard event.occurredAt.timeIntervalSince1970.isFinite else { throw SyncFailure.invalidData }
            if event.kind == .completionUndone {
                guard let completionID = event.relatedCompletionID, let completion = events[completionID] else { throw SyncFailure.missingDependency }
                guard completion.kind == .completed, completion.itemID == event.itemID else { throw SyncFailure.invalidData }
            }
        }
        for assignment in changes.flatMap(\.assignments) {
            guard items.contains(where: { $0.id == assignment.itemID }),
                  assignment.value.previousProjectID.map({ lookup[$0] != nil }) ?? true,
                  assignment.value.projectID.map({ lookup[$0] != nil }) ?? true else { throw SyncFailure.missingDependency }
        }
        return (items, projects, events.values.sorted { $0.id.uuidString < $1.id.uuidString })
    }
    private func updated(_ entity: String, fallback: Date) -> Date {
        max(fallback, changes.filter { $0.writes.contains { $0.entity == entity } && !$0.writes.contains { $0.entity == entity && $0.field == "identity" } }.map(\.date).max() ?? fallback)
    }
}
