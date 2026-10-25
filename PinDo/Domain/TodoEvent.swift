import Foundation

struct TodoEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case created, edited, completed, completionUndone, abandoned
    }

    let id: UUID
    let itemID: UUID
    let kind: Kind
    let occurredAt: Date
    var relatedCompletionID: UUID?
    var previousDeadline: Date?
    var newDeadline: Date?

    init(
        id: UUID = UUID(), itemID: UUID, kind: Kind, occurredAt: Date,
        relatedCompletionID: UUID? = nil, previousDeadline: Date? = nil, newDeadline: Date? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.occurredAt = occurredAt
        self.relatedCompletionID = relatedCompletionID
        self.previousDeadline = previousDeadline
        self.newDeadline = newDeadline
    }
}

