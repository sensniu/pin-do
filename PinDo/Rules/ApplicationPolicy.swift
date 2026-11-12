import Foundation

/// Only two distinct presses count as a double press. Autorepeat is a hold, never a second press.
struct QuitGesture {
    static let doublePressInterval: TimeInterval = 2
    static let holdDuration: TimeInterval = 1
    private(set) var armedUntil: TimeInterval?
    private(set) var pressedAt: TimeInterval?

    mutating func press(at now: TimeInterval, isRepeat: Bool = false) -> Bool {
        guard !isRepeat, pressedAt == nil else { return false }
        if let deadline = armedUntil, now < deadline { cancel(); return true }
        armedUntil = now + Self.doublePressInterval
        pressedAt = now
        return false
    }
    @discardableResult
    mutating func release(at now: TimeInterval? = nil) -> Bool {
        let confirmed = now.map { heldLongEnough(at: $0) } ?? false
        pressedAt = nil
        return confirmed
    }
    func heldLongEnough(at now: TimeInterval) -> Bool {
        pressedAt.map { now - $0 >= Self.holdDuration } ?? false
    }
    mutating func cancel() { armedUntil = nil; pressedAt = nil }
}

enum ApplicationLaunchPolicy {
    static func showsWindow(isLoginItem: Bool, backgroundRequested: Bool) -> Bool {
        !isLoginItem && !backgroundRequested
    }
}
