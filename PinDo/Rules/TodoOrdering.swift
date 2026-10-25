import Foundation

struct TodoOrdering {
    private let policy = UrgencyPolicy()

    func sorted(_ items: [TodoItem], now: Date) -> [TodoItem] {
        items.sorted { lhs, rhs in
            let left = policy.evaluate(dueAt: lhs.dueAt, now: now)
            let right = policy.evaluate(dueAt: rhs.dueAt, now: now)
            // Overdue notes go after all other notes so the layout places them outside.
            if left.isOverdue != right.isOverdue { return !left.isOverdue }
            if left.band != right.band { return left.band > right.band }
            if lhs.stars != rhs.stars { return lhs.stars > rhs.stars }
            if lhs.dueAt != rhs.dueAt {
                return (lhs.dueAt ?? .distantFuture) < (rhs.dueAt ?? .distantFuture)
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

