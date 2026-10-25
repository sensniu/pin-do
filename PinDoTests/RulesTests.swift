import XCTest

final class RulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDeadlineBoundaryAndColorProgression() {
        let policy = UrgencyPolicy()
        XCTAssertEqual(policy.evaluate(dueAt: nil, now: now).band, .noDeadline)
        XCTAssertTrue(policy.evaluate(dueAt: now, now: now).isOverdue)
        XCTAssertFalse(policy.evaluate(dueAt: now.addingTimeInterval(1), now: now).isOverdue)
        let soon = policy.evaluate(dueAt: now.addingTimeInterval(3_600), now: now)
        let later = policy.evaluate(dueAt: now.addingTimeInterval(100_000), now: now)
        XCTAssertGreaterThan(soon.intensity, later.intensity)
        XCTAssertGreaterThan(soon.band, later.band)
    }

    func testUrgencyThenStarsThenStableOrder() {
        let lowStarsSoon = TodoItem(title: "soon", dueAt: now.addingTimeInterval(3_600), stars: 1, createdAt: now)
        let highStarsSoon = TodoItem(title: "important", dueAt: now.addingTimeInterval(7_200), stars: 3, createdAt: now)
        let distant = TodoItem(title: "later", dueAt: now.addingTimeInterval(400_000), stars: 3, createdAt: now)
        let late = TodoItem(title: "late", dueAt: now.addingTimeInterval(-1), stars: 3, createdAt: now)
        let input = [late, distant, lowStarsSoon, highStarsSoon]
        let result = TodoOrdering().sorted(input, now: now)
        XCTAssertEqual(result.map(\.title), ["important", "soon", "later", "late"])
        XCTAssertEqual(result, TodoOrdering().sorted(input.reversed(), now: now))
    }

    func testLayoutsDoNotOverlapAtAllTargetScales() {
        for count in [0, 1, 20, 100, 300] {
            let items = (0..<count).map { index in
                TodoItem(title: "\(index)", dueAt: now.addingTimeInterval(Double(index + 1) * 3_600), createdAt: now)
            }
            let result = BoardLayoutEngine().layout(items: items, now: now)
            XCTAssertEqual(result.positions.count, count)
            let frames = result.positions.values.map(BoardLayoutEngine.frame(at:))
            for first in frames.indices {
                for second in frames.indices where second > first {
                    XCTAssertFalse(frames[first].intersects(frames[second]), "Overlapping layout at \(count)")
                }
            }
            let viewport = CGSize(width: 850, height: 600)
            let scale = ViewportCalculator.fitScale(bounds: result.bounds, viewport: viewport)
            XCTAssertLessThanOrEqual(scale, 1)
            XCTAssertGreaterThan(scale, 0)
            if count > 0 {
                XCTAssertLessThanOrEqual(result.bounds.width * scale, viewport.width - 84 + 0.001)
                XCTAssertLessThanOrEqual(result.bounds.height * scale, viewport.height - 84 + 0.001)
            }
            XCTAssertEqual(result, BoardLayoutEngine().layout(items: items.reversed(), now: now))
        }
    }

    func testOverdueNotesAreOutsideActiveNotes() {
        let items = (0..<30).map { index in
            TodoItem(title: "\(index)", dueAt: now.addingTimeInterval(index < 20 ? 3_600 : -3_600), createdAt: now)
        }
        let result = BoardLayoutEngine().layout(items: items, now: now)
        func distance(_ item: TodoItem) -> CGFloat {
            let point = result.positions[item.id]!
            return point.x * point.x + point.y * point.y
        }
        XCTAssertGreaterThanOrEqual(items.suffix(10).map(distance).min()!, items.prefix(20).map(distance).max()!)
    }

    func testReservedPositionIsNeverAssigned() {
        let reservation = BoardLayoutEngine.frame(at: .zero)
        let items = (0..<20).map { TodoItem(title: "\($0)", createdAt: now) }
        let result = BoardLayoutEngine().layout(items: items, now: now, reserved: [reservation])
        XCTAssertEqual(result.positions.count, items.count)
        for point in result.positions.values {
            XCTAssertFalse(BoardLayoutEngine.frame(at: point).intersects(reservation))
        }
        XCTAssertTrue(result.bounds.contains(reservation))
    }
}

