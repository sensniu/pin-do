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
        let nodes: [(Double, Double)] = [(0, 1), (6, 0.82), (24, 0.55), (72, 0.28), (168, 0.08)]
        let hours = remaining / hour
        var intensity = 0.08
        for index in 1..<nodes.count where hours <= nodes[index].0 {
            let a = nodes[index - 1], b = nodes[index]
            intensity = a.1 + (b.1 - a.1) * (hours - a.0) / (b.0 - a.0)
            break
        }
        return Urgency(band: band, intensity: intensity)
    }
}


/// Relative day names use calendar boundaries, including daylight-saving transitions.
enum DeadlineText {
    static func label(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "无截止时间" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 " + time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天 " + time
        }
        formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMddHHmm" : "yyyyMMddHHmm")
        return formatter.string(from: date)
    }
}
