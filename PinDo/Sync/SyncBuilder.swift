import Foundation

struct SyncBaseline: Codable, Equatable, Sendable {
    let item: TodoItem
    let fields: [String: [UUID]]
}
struct SyncProjectBaseline: Sendable {
    let project: Project
    let fields: [String: [UUID]]
}
struct SyncContents {
    var items: [TodoItem]
    var projects: [Project]
    var events: [TodoEvent]
}

enum SyncBuilder {
    static func capture(before: SyncContents, after: SyncContents, state: SyncState, baseline: SyncBaseline? = nil) throws -> SyncChange? {
        var change = SyncChange(writerID: state.writerID, date: .now, writes: [])
        var graph = try SyncGraph(state.changes)
        let compact = state.current?.protocolVersion == 3
        func add<T: Encodable>(_ entity: String, _ field: String, _ value: T, parents: [UUID]? = nil, id: UUID = UUID()) throws {
            change.writes.append(SyncWrite(id: id, entity: entity, field: field, parents: parents ?? graph.editParents(entity, field), value: try SyncCodec.encode(value)))
        }
        for project in after.projects {
            let prior = before.projects.first { $0.id == project.id }
            let entity = SyncGraph.entity("project", project.id)
            if prior == nil { try add(entity, "identity", SyncIdentity(id: project.id, createdAt: project.createdAt, updatedAt: project.updatedAt)) }
            if prior?.name != project.name { try add(entity, "name", project.name) }
            if prior?.colorValue != project.colorValue { try add(entity, "color", project.colorValue) }
            if compact && (prior == nil || prior?.status != project.status) {
                var retired: [String: Int] = [:]
                var observed: [String: Int] = [:]
                let lives = try graph.heads(entity, "lifecycle").map { try SyncCodec.decode(SyncLife.self, $0.value) }
                for life in lives {
                    for (writer, counter) in life.retired ?? [:] { retired[writer] = max(retired[writer, default: 0], counter) }
                    if let dot = life.generation { retired[dot.writer.uuidString.lowercased()] = max(retired[dot.writer.uuidString.lowercased(), default: 0], dot.counter) }
                    for (writer, counter) in life.observed ?? [:] { observed[writer] = max(observed[writer, default: 0], counter) }
                    if let dot = life.transition { observed[dot.writer.uuidString.lowercased()] = max(observed[dot.writer.uuidString.lowercased(), default: 0], dot.counter) }
                }
                let actor = state.writerID.uuidString.lowercased()
                let priorCounter = max(state.current?.counters[entity] ?? 0, max(observed[actor, default: 0], max(retired[actor, default: 0], lives.compactMap(\.generation).filter { $0.writer == state.writerID }.map(\.counter).max() ?? 0)))
                guard priorCounter < Int.max else { throw SyncFailure.invalidData }
                let dot = SyncGeneration(writer: state.writerID, counter: priorCounter + 1)
                if prior == nil && project.status != .active { retired[actor] = dot.counter }
                try add(entity, "lifecycle", SyncLife(status: project.status.rawValue, date: project.deletedAt ?? project.archivedAt,
                    generation: project.status == .active ? dot : nil, retired: retired, transition: dot, observed: observed))
            } else if prior == nil && project.status != .active {
                let activation = UUID()
                try add(entity, "lifecycle", SyncLife(status: "active", date: nil), parents: [], id: activation)
                try add(entity, "lifecycle", SyncLife(status: project.status.rawValue, date: project.deletedAt ?? project.archivedAt), parents: [activation])
            } else if prior?.status != project.status {
                try add(entity, "lifecycle", SyncLife(status: project.status.rawValue, date: project.deletedAt ?? project.archivedAt))
            }
        }
        if !change.writes.isEmpty { graph = try SyncGraph(state.changes + [change]) }
        let newEvents = after.events.filter { event in !before.events.contains { $0.id == event.id } }
        change.events = newEvents
        for item in after.items {
            let stored = before.items.first { $0.id == item.id }
            let edit = baseline?.item.id == item.id ? baseline : nil
            let prior = edit?.item ?? stored
            let entity = SyncGraph.entity("todo", item.id)
            func parents(_ field: String) -> [UUID]? { edit?.fields[field] }
            if stored == nil { try add(entity, "identity", SyncIdentity(id: item.id, createdAt: item.createdAt, updatedAt: item.updatedAt)) }
            if prior?.title != item.title { try add(entity, "title", item.title, parents: parents("title")) }
            if prior?.notes != item.notes { try add(entity, "notes", item.notes, parents: parents("notes")) }
            if prior == nil || prior?.dueAt != item.dueAt { try add(entity, "deadline", item.dueAt, parents: parents("deadline")) }
            if prior?.stars != item.stars { try add(entity, "stars", item.stars, parents: parents("stars")) }
            let event = (stored == nil && compact ? after.events : newEvents).first { $0.itemID == item.id &&
                (stored == nil ? ($0.kind == .completed && item.status == .completed || $0.kind == .abandoned && item.status == .abandoned) : [.completed, .abandoned, .completionUndone].contains($0.kind)) }
            if stored?.status != nil, stored?.status != .active, newEvents.contains(where: { $0.itemID == item.id && $0.kind == .edited }) { change.endedEdits = (change.endedEdits ?? []) + [item.id] }
            let automaticTransfer = stored?.projectID != nil && item.projectID == nil && item.projectAssignments.last.map { $0.reason == .archived || $0.reason == .deleted } == true && edit == nil
            if stored == nil || ((!automaticTransfer && prior?.projectID != item.projectID) || event?.kind == .completed || event?.kind == .abandoned) {
                let generation = try item.projectID.map { projectID in
                    let pe = SyncGraph.entity("project", projectID)
                    let current = try graph.selected(pe, "lifecycle")
                    if try SyncCodec.decode(SyncLife.self, current.value).status == "active" { return current.id }
                    if compact && item.status != .active { return current.id }
                    guard let activation = graph.writes.values.filter({ $0.entity == pe && $0.field == "lifecycle" && (try? SyncCodec.decode(SyncLife.self, $0.value).status) == "active" }).sorted(by: { $0.id.uuidString < $1.id.uuidString }).first else { throw SyncFailure.missingDependency }
                    return activation.id
                }
                let dot = try generation.flatMap { graph.writes[$0] }.map { try SyncCodec.decode(SyncLife.self, $0.value).generation } ?? nil
                try add(entity, "membership", SyncMembership(projectID: item.projectID, generation: generation, generationDot: dot), parents: parents("membership"))
            }
            if stored == nil || stored?.status != item.status {
                let observed: [UUID]?
                if let event, event.kind == .completionUndone, let completion = event.relatedCompletionID { observed = [completion] }
                else { observed = nil }
                try add(entity, "lifecycle", SyncLife(status: item.status.rawValue, date: item.completedAt ?? item.abandonedAt), parents: observed, id: event?.id ?? UUID())
            }
            for assignment in item.projectAssignments where !(stored?.projectAssignments.contains(assignment) ?? false) {
                // Automatic transfers are derived from immutable project generations on every device.
                if !compact && stored != nil && (assignment.reason == .archived || assignment.reason == .deleted) { continue }
                change.assignments.append(SyncAssignment(id: UUID(), itemID: item.id, value: assignment))
            }
        }
        if compact && change.writes.isEmpty && change.assignments.isEmpty { return nil }
        return change.writes.isEmpty && change.events.isEmpty && change.assignments.isEmpty ? nil : try SyncCodec.decode(SyncChange.self, SyncCodec.encode(change))
    }
}
