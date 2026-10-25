import Foundation

struct NoteDraft: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let isNew: Bool
    var title: String
    var notes: String
    var hasDeadline: Bool
    var dueAt: Date
    var stars: Int
    var categoryID: String

    init(item: TodoItem? = nil, now: Date) {
        id = item?.id ?? UUID()
        isNew = item == nil
        title = item?.title ?? ""
        notes = item?.notes ?? ""
        hasDeadline = item?.dueAt != nil
        dueAt = item?.dueAt ?? now.addingTimeInterval(3_600)
        stars = item?.stars ?? 1
        categoryID = item?.category?.id ?? ""
    }

    var canSubmit: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var category: TodoCategory? { TodoCategory.examples.first { $0.id == categoryID } }
}

