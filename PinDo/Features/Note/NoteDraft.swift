import Foundation

struct NoteDraft: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let isNew: Bool
    var title: String
    var notes: String
    var hasDeadline: Bool
    var dueAt: Date
    var stars: Int
    var projectID: UUID?
    var syncBaseline: SyncBaseline? = nil

    init(item: TodoItem? = nil, now: Date) {
        id = item?.id ?? UUID()
        isNew = item == nil
        title = item?.title ?? ""
        notes = item?.notes ?? ""
        hasDeadline = item?.dueAt != nil
        dueAt = item?.dueAt ?? now.addingTimeInterval(3_600)
        stars = item?.stars ?? 1
        projectID = item?.projectID
    }

    init(id: UUID, isNew: Bool, title: String, notes: String, hasDeadline: Bool,
         dueAt: Date, stars: Int, projectID: UUID?) {
        self.id = id; self.isNew = isNew; self.title = title; self.notes = notes
        self.hasDeadline = hasDeadline; self.dueAt = dueAt; self.stars = stars; self.projectID = projectID
    }

    var canSubmit: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

