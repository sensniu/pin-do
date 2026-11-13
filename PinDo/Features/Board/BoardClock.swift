import AppKit
import Combine
import Foundation

@MainActor
final class BoardClock: ObservableObject {
    @Published private(set) var now: Date
    private var timer: Timer?
    private var observations: [AnyCancellable] = []

    init(now: Date = .now) { self.now = now }

    func start(items: [TodoItem]) {
        now = .now
        update(items: items)
        guard observations.isEmpty else { return }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemClockDidChange))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.now = .now }
            }
            .store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.now = .now }
            }
            .store(in: &observations)
    }

    func update(items: [TodoItem]) {
        timer?.invalidate()
        let current = Date.now
        let nextDeadline = items.flatMap { [$0.plannedStartAt, $0.dueAt].compactMap { $0 } }.filter { $0 > current }.min()
        let untilDeadline = nextDeadline?.timeIntervalSince(current) ?? 60
        let delay = max(0.05, min(60, untilDeadline))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = .now }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observations.removeAll()
    }
}

