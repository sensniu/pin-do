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
            let frames = result.positions.keys.compactMap { result.frame(for: $0) }
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
        for id in result.positions.keys {
            XCTAssertFalse(result.frame(for: id)!.intersects(reservation))
        }
        XCTAssertTrue(result.bounds.contains(reservation))
    }

    func testWideBoardsPreferSideBySideWithoutUpscaling() {
        let items = [TodoItem(title: "one"), TodoItem(title: "two")]
        for viewport in [CGSize(width: 760, height: 440), CGSize(width: 1180, height: 740)] {
            let layout = BoardLayoutEngine().layout(items: items, now: now, viewport: viewport)
            let points = Array(layout.positions.values)
            XCTAssertEqual(points[0].y, points[1].y)
            XCTAssertNotEqual(points[0].x, points[1].x)
            XCTAssertEqual(ViewportCalculator.fitScale(bounds: layout.bounds, viewport: viewport), 1)
        }
    }

    func testExtremeViewportRatiosKeepLayoutsFiniteAndNonoverlapping() {
        for count in [1, 2, 7] {
            let items = (0..<count).map { TodoItem(title: "事项 \($0)") }
            for viewport in [CGSize(width: 6000, height: 200), CGSize(width: 1, height: 6000), CGSize(width: 6000, height: 1)] {
                let layout = BoardLayoutEngine().layout(items: items, now: now, viewport: viewport)
                XCTAssertEqual(layout.positions.count, count)
                let frames = items.compactMap { layout.frame(for: $0.id) }
                for i in frames.indices {
                    XCTAssertTrue(frames[i].midX.isFinite && frames[i].midY.isFinite)
                    for j in frames.indices where j > i {
                        XCTAssertFalse(BoardLayoutEngine.conflicts(frames[i], frames[j]))
                    }
                }
            }
        }
    }

    func testCalendarDayLabelsAcrossDSTAndYearBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 15))!
        let tonight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 30))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0, minute: 30))!
        XCTAssertTrue(DeadlineText.label(tonight, now: today, calendar: calendar).hasPrefix("今天"))
        XCTAssertTrue(DeadlineText.label(tomorrow, now: today, calendar: calendar).hasPrefix("明天"))
        let nextYear = calendar.date(from: DateComponents(year: 2027, month: 2, day: 1))!
        XCTAssertTrue(DeadlineText.label(nextYear, now: today, calendar: calendar).contains("2027"))
        XCTAssertEqual(DeadlineText.label(nil, now: today), "无截止时间")
    }

    func testMeasuredHeightRespectsVisibleTextAndCapsLongNotes() {
        let short = TodoItem(title: "短标题")
        let long = TodoItem(title: "一个需要换行显示的较长标题用于检查高度", notes: "第一行\n第二行\n第三行")
        let huge = TodoItem(title: long.title, notes: long.notes + String(repeating: "\n后续完整内容", count: 1000))
        XCTAssertLessThan(NoteMetrics.height(for: short), NoteMetrics.height(for: long))
        // Truncation adds an ellipsis; font rounding can change the last line by a point.
        XCTAssertLessThanOrEqual(abs(NoteMetrics.height(for: long) - NoteMetrics.height(for: huge)), 2)
        for item in [short, long, huge, TodoItem(title: "👩🏽‍💻👨‍👩‍👧‍👦", notes: "a\n\nb")] {
            XCTAssertGreaterThanOrEqual(NoteMetrics.height(for: item), NoteMetrics.minimumHeight)
            XCTAssertLessThanOrEqual(NoteMetrics.height(for: item), NoteMetrics.maximumHeight)
        }
    }

    func testMixedHeightLayoutAvoidsOverlapAndKeepsPriorityDistance() {
        let items = (0..<45).map { index in
            TodoItem(title: "事项 \(index)", notes: index % 3 == 0 ? "长备注的第一行\n第二行\n第三行" : "",
                     dueAt: now.addingTimeInterval(Double(index - 10) * 3600), stars: index % 3 + 1)
        }
        let result = BoardLayoutEngine().layout(items: items, now: now)
        let frames = items.compactMap { result.frame(for: $0.id) }
        for i in frames.indices { for j in frames.indices where j > i {
            XCTAssertFalse(BoardLayoutEngine.conflicts(frames[i], frames[j]))
        } }
        let distances = TodoOrdering().sorted(items, now: now).map { item in
            let point = result.positions[item.id]!
            return point.x * point.x + point.y * point.y
        }
        for i in 1..<distances.count { XCTAssertGreaterThanOrEqual(distances[i] + 0.02, distances[i - 1]) }
    }

    func testGrowthAndShrinkPreserveEveryCardPosition() {
        var first = TodoItem(title: "first")
        let second = TodoItem(title: "second"), third = TodoItem(title: "third"), beside = TodoItem(title: "beside")
        let items = [first, second, third, beside]
        var before = BoardLayout()
        for (item, point) in zip(items, [CGPoint.zero, CGPoint(x: 0, y: 128), CGPoint(x: 0, y: 256), CGPoint(x: 228, y: 0)]) {
            before.positions[item.id] = point; before.heights[item.id] = NoteMetrics.height(for: item)
        }
        first.notes = "第一行\n第二行\n第三行"
        let after = BoardLayoutEngine().refreshed(before, items: [first, second, third, beside], now: now)
        XCTAssertEqual(after.positions, before.positions)
        XCTAssertGreaterThan(after.heights[first.id]!, before.heights[first.id]!)
        XCTAssertEqual(after.positions[beside.id], before.positions[beside.id])
        first.notes = ""
        let shrunk = BoardLayoutEngine().refreshed(after, items: [first, second, third, beside], now: now)
        XCTAssertEqual(shrunk.positions[second.id], after.positions[second.id])
        XCTAssertEqual(shrunk.positions[third.id], after.positions[third.id])
    }

    func testDragTranslationUsesBoardCoordinatesAtEveryZoom() {
        let origin = CGPoint(x: -100, y: 70), delta = CGSize(width: 60, height: -30)
        for scale in [CGFloat(0.05), 0.3, 1, 2] {
            let point = ViewportCalculator.draggedPosition(origin: origin, translation: delta, scale: scale)
            let start = ViewportCalculator.position(world: origin, bounds: CGRect(x: -300, y: -200, width: 800, height: 500), viewport: CGSize(width: 900, height: 700), scale: scale, pan: CGSize(width: 20, height: -40))
            let end = ViewportCalculator.position(world: point, bounds: CGRect(x: -300, y: -200, width: 800, height: 500), viewport: CGSize(width: 900, height: 700), scale: scale, pan: CGSize(width: 20, height: -40))
            XCTAssertEqual(end.x - start.x, delta.width, accuracy: 0.001)
            XCTAssertEqual(end.y - start.y, delta.height, accuracy: 0.001)
        }
    }

    func testIncrementalPlacementLeavesExistingStackAndFindsSpaceForRemoteBatch() {
        let existing = (0..<12).map { TodoItem(title: "原有 \($0)") }
        let new = (0..<20).map { TodoItem(title: "新增 \($0)", dueAt: now.addingTimeInterval(Double($0 + 1) * 3600)) }
        var old = BoardLayoutEngine().layout(items: existing, now: now)
        for item in existing { old.positions[item.id] = .zero }
        let updated = BoardLayoutEngine().refreshed(old, items: existing + new, now: now)
        for item in existing { XCTAssertEqual(updated.positions[item.id], .zero) }
        for (index, item) in new.enumerated() {
            let frame = updated.frame(for: item.id)!
            XCTAssertFalse(BoardLayoutEngine.conflicts(frame, updated.frame(for: existing[0].id)!))
            for other in new.dropFirst(index + 1) { XCTAssertFalse(BoardLayoutEngine.conflicts(frame, updated.frame(for: other.id)!)) }
        }
        // With distant manually placed cards, an urgent insertion can use the free center.
        for item in existing { old.positions[item.id] = CGPoint(x: 4000, y: 4000) }
        let urgent = TodoItem(title: "立即处理", dueAt: now.addingTimeInterval(60))
        let result = BoardLayoutEngine().refreshed(old, items: existing + [urgent], now: now)
        let point = result.positions[urgent.id]!
        XCTAssertLessThan(hypot(point.x, point.y), 300)
    }

}

