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
                let pe = Self.entity("project", projectID)
                let projectLives = writes.values.filter { $0.entity == pe && $0.field == "lifecycle" }
                let itemLives = try writes.values.filter { $0.entity == write.entity && $0.field == "lifecycle" }.map { try SyncCodec.decode(SyncLife.self, $0.value) }
                let compact = try projectLives.contains { try SyncCodec.decode(SyncLife.self, $0.value).retired != nil }
                if compact && !itemLives.contains(where: { $0.status == "active" }) { continue }
                if let activation = writes[generation] {
                    guard activation.entity == pe, activation.field == "lifecycle", try SyncCodec.decode(SyncLife.self, activation.value).status == "active" else { throw SyncFailure.invalidData }
                } else if let dot = membership.generationDot {
                    let retired = try projectLives.contains { (try SyncCodec.decode(SyncLife.self, $0.value).retired?[dot.writer.uuidString.lowercased()] ?? 0) >= dot.counter }
                    guard retired else { throw SyncFailure.missingDependency }
                } else { throw SyncFailure.missingDependency }
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
    static func validate(_ write: SyncWrite) throws {
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
            if let dot = value.generationDot { guard value.projectID != nil, dot.counter > 0 else { throw SyncFailure.invalidData } }
        case "lifecycle":
            let value = try SyncCodec.decode(SyncLife.self, write.value)
            let allowed = write.entity.hasPrefix("todo:") ? ["active", "completed", "abandoned"] : ["active", "archived", "deleted"]
            guard allowed.contains(value.status), (value.status == "active") == (value.date == nil) else { throw SyncFailure.invalidData }
            if let dot = value.generation { guard value.status == "active", dot.counter > 0 else { throw SyncFailure.invalidData } }
            guard value.retired?.allSatisfy({ UUID(uuidString: $0.key)?.uuidString.lowercased() == $0.key && $0.value > 0 }) ?? true else { throw SyncFailure.invalidData }
            if let dot = value.transition { guard dot.counter > 0, (value.observed?[dot.writer.uuidString.lowercased()] ?? 0) < dot.counter else { throw SyncFailure.invalidData } }
            guard value.observed?.allSatisfy({ UUID(uuidString: $0.key)?.uuidString.lowercased() == $0.key && $0.value > 0 }) ?? true else { throw SyncFailure.invalidData }
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
            guard (assignment.value.changedAt?.timeIntervalSince1970.isFinite ?? true) else { throw SyncFailure.invalidData }
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
                .sorted { ($0.value.changedAt ?? .distantPast) == ($1.value.changedAt ?? .distantPast) ? $0.id.uuidString < $1.id.uuidString : ($0.value.changedAt ?? .distantPast) < ($1.value.changedAt ?? .distantPast) }
                .map(\.value).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            if let projectID = membership.projectID {
                guard let project = lookup[projectID] else { throw SyncFailure.missingDependency }
                let pe = Self.entity("project", projectID)
                let generations = try heads(pe, "lifecycle").filter { try SyncCodec.decode(SyncLife.self, $0.value).status == "active" }.map(\.id)
                if item.status == .active && (project.status != .active || membership.generation.map { !generations.contains($0) } == true) {
                    item.projectID = nil
                    if try heads(pe, "lifecycle").contains(where: { try SyncCodec.decode(SyncLife.self, $0.value).retired != nil }) {
                        if !item.projectAssignments.contains(where: { $0.previousProjectID == projectID && $0.projectID == nil }) {
                            item.projectAssignments.append(ProjectAssignment(previousProjectID: projectID, projectID: nil, changedAt: nil, reason: .generationExpired))
                        }
                    } else {
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
        max(fallback, writes.values.filter { $0.entity == entity && $0.field != "identity" }.compactMap(\.modifiedAt).max() ??
            changes.filter { $0.writes.contains { $0.entity == entity } && !$0.writes.contains { $0.entity == entity && $0.field == "identity" } }.map(\.date).max() ?? fallback)
    }
}

extension SyncCurrent {
    private static let snapshotWriter = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static func historical(_ write: SyncWrite) -> Bool {
        guard write.entity.hasPrefix("project:"), write.field == "lifecycle", let life = try? SyncCodec.decode(SyncLife.self, write.value) else { return false }
        return life.retired == nil && life.generation == nil // Only for reading local pre-v3 state, never newly emitted.
    }
    static func timestamp(_ write: SyncWrite, in change: SyncChange) throws -> Date {
        if let date = write.modifiedAt { return date }
        if let creation = change.writes.first(where: { $0.entity == write.entity && $0.field == "identity" }) {
            let identity = try SyncCodec.decode(SyncIdentity.self, creation.value)
            return identity.updatedAt ?? identity.createdAt
        }
        return change.date
    }
    /// A local-only transition: retain visible business/candidates, discard protocol history.
    static func upgrading(_ old: [SyncChange], writer: UUID) throws -> [SyncChange] {
        let graph = try SyncGraph(old), projection = try graph.projection()
        let compacted = try compact(old)
        var values = compacted.flatMap(\.writes).filter { !($0.entity.hasPrefix("project:") && $0.field == "lifecycle") }
        values = try values.map { write in
            guard ["title", "notes", "name"].contains(write.field) else { return write }
            return SyncWrite(id: write.id, entity: write.entity, field: write.field, parents: write.parents,
                value: try SyncCodec.encode(SyncCodec.decode(String.self, write.value)), modifiedAt: write.modifiedAt)
        }
        var activations: [UUID: [SyncWrite]] = [:]
        for project in projection.projects {
            let entity = SyncGraph.entity("project", project.id)
            let heads = graph.heads(entity, "lifecycle")
            for (index, head) in heads.enumerated() {
                let life = try SyncCodec.decode(SyncLife.self, head.value)
                let updated = SyncLife(status: life.status, date: life.date,
                    generation: life.status == "active" ? SyncGeneration(writer: writer, counter: index + 1) : nil, retired: [:], transition: SyncGeneration(writer: writer, counter: index + 1), observed: [:])
                let value = SyncWrite(id: head.id, entity: entity, field: "lifecycle", parents: [], value: try SyncCodec.encode(updated), modifiedAt: try timestamp(head, in: graph.changes.first { $0.writes.contains { $0.id == head.id } }!))
                values.append(value)
                if life.status == "active" { activations[project.id, default: []].append(value) }
            }
        }
        let items = Dictionary(uniqueKeysWithValues: projection.items.map { (SyncGraph.entity("todo", $0.id), $0) })
        values = try values.map { write in
            guard write.field == "membership", let item = items[write.entity], item.status == .active else { return write }
            let oldValue = try SyncCodec.decode(SyncMembership.self, write.value)
            let membership: SyncMembership
            if let project = oldValue.projectID, let active = activations[project]?.first(where: { $0.id == oldValue.generation }) {
                membership = SyncMembership(projectID: project, generation: active.id, generationDot: try SyncCodec.decode(SyncLife.self, active.value).generation)
            } else { membership = SyncMembership(projectID: nil, generation: nil) }
            return SyncWrite(id: write.id, entity: write.entity, field: write.field, parents: [], value: try SyncCodec.encode(membership), modifiedAt: write.modifiedAt)
        }
        var metadata = SyncChange(writerID: writer, date: .now, writes: values, events: old.flatMap(\.events), assignments: old.flatMap(\.assignments))
        metadata.endedEdits = Array(Set(old.flatMap { $0.endedEdits ?? [] } + old.flatMap(\.events).filter { $0.kind == .edited }.map(\.itemID)))
        for item in projection.items {
            for assignment in item.projectAssignments where !metadata.assignments.contains(where: { $0.itemID == item.id && $0.value == assignment }) {
                metadata.assignments.append(SyncAssignment(id: UUID(), itemID: item.id, value: assignment))
            }
        }
        let result = try snapshots(writes: values, changes: [metadata])
        _ = try SyncGraph(result).projection()
        return result
    }
    static func compact(_ changes: [SyncChange]) throws -> [SyncChange] {
        _ = try SyncGraph(changes).projection()
        var all: [UUID: SyncWrite] = [:]
        for change in changes {
            for var write in change.writes {
                if write.modifiedAt == nil { write.modifiedAt = try timestamp(write, in: change) }
                all[write.id] = write
            }
        }
        let retired = Set(all.values.flatMap(\.parents))
        let kept = all.values.filter { historical($0) || !retired.contains($0.id) }.map { write in
            historical(write) ? write : SyncWrite(id: write.id, entity: write.entity, field: write.field, parents: [], value: write.value, modifiedAt: write.modifiedAt)
        }
        return try snapshots(writes: kept, changes: changes)
    }
    /// Apply explicit observed removals. A stale editor may add a candidate without retiring an unseen value.
    static func applying(_ changes: [SyncChange], to base: [SyncChange]) throws -> [SyncChange] {
        var all = Dictionary(uniqueKeysWithValues: base.flatMap(\.writes).map { ($0.id, $0) })
        for change in changes {
            for var write in change.writes {
                guard validEntity(write.entity), SyncGraph.fields(for: write.entity.hasPrefix("todo:") ? "todo" : "project").contains(write.field) else { throw SyncFailure.invalidData }
                try SyncGraph.validate(write)
                if let existing = all[write.id] {
                    guard existing.entity == write.entity, existing.field == write.field, existing.value == write.value else { throw SyncFailure.identityCollision }
                    continue
                }
                if !historical(write) {
                    for parent in write.parents {
                        if let old = all[parent] {
                            guard old.key == write.key else { throw SyncFailure.invalidData }
                            all.removeValue(forKey: parent)
                        }
                    }
                    write = SyncWrite(id: write.id, entity: write.entity, field: write.field, parents: [], value: write.value, modifiedAt: try timestamp(write, in: change))
                } else if write.modifiedAt == nil { write.modifiedAt = try timestamp(write, in: change) }
                all[write.id] = write
            }
        }
        return try snapshots(writes: Array(all.values), changes: base + changes)
    }
    static func snapshots(writes: [SyncWrite], changes: [SyncChange]) throws -> [SyncChange] {
        var unique: [UUID: SyncWrite] = [:]
        for write in writes {
            if let previous = unique[write.id] {
                guard previous.entity == write.entity, previous.field == write.field, previous.value == write.value else { throw SyncFailure.identityCollision }
                unique[write.id] = SyncWrite(id: write.id, entity: write.entity, field: write.field,
                    parents: Array(Set(previous.parents + write.parents)).sorted { $0.uuidString < $1.uuidString }, value: write.value,
                    modifiedAt: [previous.modifiedAt, write.modifiedAt].compactMap { $0 }.max())
            } else { unique[write.id] = write }
        }
        let candidates = Array(unique.values)
        let lifecycle = try candidates.filter { $0.entity.hasPrefix("project:") && $0.field == "lifecycle" }.map { ($0, try SyncCodec.decode(SyncLife.self, $0.value)) }
        let obsolete = Set(lifecycle.filter { candidate in
            lifecycle.contains { other in
                guard other.0.entity == candidate.0.entity, other.0.id != candidate.0.id else { return false }
                if let dot = candidate.1.transition, (other.1.observed?[dot.writer.uuidString.lowercased()] ?? 0) >= dot.counter { return true }
                if let dot = candidate.1.generation, (other.1.retired?[dot.writer.uuidString.lowercased()] ?? 0) >= dot.counter { return true }
                return false
            }
        }.map { $0.0.id })
        let writes = candidates.filter { !obsolete.contains($0.id) }
        var events: [UUID: TodoEvent] = [:], assignments: [UUID: SyncAssignment] = [:]
        for change in changes {
            for event in change.events {
                if let old = events[event.id], old != event { throw SyncFailure.identityCollision }
                events[event.id] = event
            }
            for value in change.assignments {
                if let old = assignments[value.id], old != value { throw SyncFailure.identityCollision }
                assignments[value.id] = value
            }
        }
        let liveTokens = Set(writes.filter { $0.entity.hasPrefix("todo:") && $0.field == "lifecycle" }.map(\.id))
        events = events.filter { liveTokens.contains($0.key) && [.completed, .abandoned].contains($0.value.kind) }
        let ended = Set(changes.flatMap { $0.endedEdits ?? [] })
        return try Dictionary(grouping: writes, by: \.entity).map { entity, values in
            guard validEntity(entity) else { throw SyncFailure.invalidData }
            let values = values.sorted { $0.id.uuidString < $1.id.uuidString }
            let identity = values.first(where: { $0.field == "identity" })?.id ?? values[0].id
            let itemID = UUID(uuidString: String(entity.split(separator: ":").last!))!
            return SyncChange(id: identity, writerID: snapshotWriter, date: values.compactMap(\.modifiedAt).max() ?? Date(timeIntervalSince1970: 0), writes: values,
                events: events.values.filter { $0.itemID == itemID }.sorted { $0.id.uuidString < $1.id.uuidString },
                assignments: assignments.values.filter { $0.itemID == itemID }.sorted { $0.id.uuidString < $1.id.uuidString }, endedEdits: ended.contains(itemID) ? [itemID] : nil)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    /// Collapse offline intermediate values, while retaining roots observed before the pending batch.
    static func coalescing(_ newer: SyncChange, into older: SyncChange?) throws -> SyncChange {
        guard let older else { return newer }
        let oldWrites = Dictionary(uniqueKeysWithValues: older.writes.map { ($0.id, $0) })
        var rewritten = newer
        rewritten.writes = try newer.writes.map { write in
            if historical(write) { return write }
            var roots = Set<UUID>(), queue = write.parents, visited = Set<UUID>()
            while let parent = queue.popLast() {
                guard visited.insert(parent).inserted else { continue }
                if let prior = oldWrites[parent] {
                    guard prior.key == write.key else { throw SyncFailure.invalidData }
                    queue.append(contentsOf: prior.parents)
                } else { roots.insert(parent) }
            }
            return SyncWrite(id: write.id, entity: write.entity, field: write.field, parents: roots.sorted { $0.uuidString < $1.uuidString }, value: write.value, modifiedAt: try timestamp(write, in: newer))
        }
        let removed = Set(newer.writes.flatMap(\.parents))
        rewritten.writes += older.writes.filter { historical($0) || !removed.contains($0.id) }
        let metadata = try snapshots(writes: rewritten.writes, changes: [older, newer])
        rewritten.writes = metadata.flatMap(\.writes)
        rewritten.events = metadata.flatMap(\.events); rewritten.assignments = metadata.flatMap(\.assignments)
        rewritten.endedEdits = metadata.flatMap { $0.endedEdits ?? [] }
        return rewritten
    }
    static func merging(_ mutation: SyncMutation, into record: SyncEntityRecord) throws -> SyncEntityRecord {
        guard validEntity(mutation.entity), mutation.entity == record.entity, mutation.sequence > 0,
              mutation.change.writes.allSatisfy({ $0.entity == mutation.entity }) else { throw SyncFailure.invalidData }
        let item = UUID(uuidString: String(mutation.entity.split(separator: ":").last!))!
        guard mutation.change.events.allSatisfy({ $0.itemID == item }), mutation.change.assignments.allSatisfy({ $0.itemID == item }) else { throw SyncFailure.invalidData }
        let writer = mutation.writerID.uuidString.lowercased()
        if record.receipts[writer, default: 0] >= mutation.sequence {
            let receipt = record.receiptOperations?[writer]
            guard receipt?.sequence == mutation.sequence, receipt?.operationID == mutation.id, receipt?.digest == (try SyncCodec.hash(SyncCodec.encode(mutation))) else { throw SyncFailure.identityCollision }
            return record
        }
        var result = record
        let values = try applying([mutation.change], to: record.change.writes.isEmpty ? [] : [record.change])
        guard values.count == 1, let value = values.first else { throw SyncFailure.invalidData }
        result.change = value; result.receipts[writer] = mutation.sequence
        if result.receiptOperations == nil { result.receiptOperations = [:] }
        result.receiptOperations![writer] = SyncReceipt(sequence: mutation.sequence, operationID: mutation.id, digest: try SyncCodec.hash(SyncCodec.encode(mutation)))
        result.publication = SyncPublication(writerID: mutation.writerID, receipt: result.receiptOperations![writer]!)
        guard result.revision < Int.max else { throw SyncFailure.invalidData }
        result.revision += 1
        return result
    }
}
