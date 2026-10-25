import Foundation

struct Urgency: Equatable, Sendable {
    enum Band: Int, Comparable, Sendable {
        case noDeadline, later, thisWeek, nextThreeDays, nextDay, nextSixHours, overdue

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let band: Band
    let intensity: Double
    var isOverdue: Bool { band == .overdue }
}

/// Prototype thresholds. Product tuning belongs here, never in view/layout code.
struct UrgencyPolicy: Sendable {
    func evaluate(dueAt: Date?, now: Date) -> Urgency {
        guard let dueAt else { return Urgency(band: .noDeadline, intensity: 0) }
        let remaining = dueAt.timeIntervalSince(now)
        guard remaining > 0 else { return Urgency(band: .overdue, intensity: 1) }
        let hour: TimeInterval = 3_600
        let band: Urgency.Band
        switch remaining {
        case ...(6 * hour): band = .nextSixHours
        case ...(24 * hour): band = .nextDay
        case ...(72 * hour): band = .nextThreeDays
        case ...(168 * hour): band = .thisWeek
        default: band = .later
        }
        // Continuous, opaque color strength; the appearance is identical in both modes.
        let intensity = 0.12 + 0.88 * (1 - min(remaining / (168 * hour), 1))
        return Urgency(band: band, intensity: intensity)
    }
}

