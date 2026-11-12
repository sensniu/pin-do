import Foundation

struct BoardLayout: Equatable {
    var positions: [UUID: CGPoint] = [:]
    var heights: [UUID: CGFloat] = [:]
    var stackingOrder: [UUID] = []
    var bounds: CGRect = .zero

    func frame(for id: UUID) -> CGRect? {
        positions[id].map { BoardLayoutEngine.frame(at: $0, height: heights[id] ?? NoteMetrics.minimumHeight) }
    }
}

struct BoardLayoutEngine {
    static let notePadding = NoteMetrics.padding
    static let gap: CGFloat = 16
    static let defaultViewport = CGSize(width: 1120, height: 680)

    func layout(items: [TodoItem], now: Date, reserved: [CGRect] = [], viewport: CGSize = defaultViewport) -> BoardLayout {
        let ordered = TodoOrdering().sorted(items.filter { $0.status == .active }, now: now)
        let heights = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, NoteMetrics.height(for: $0)) })
        guard !ordered.isEmpty else {
            let bounds = reserved.reduce(CGRect.null) { $0.union($1) }
            return BoardLayout(bounds: bounds.isNull ? .zero : bounds)
        }
        let ratio = max(1, viewport.width - 84) / max(1, viewport.height - 84)
        var best = BoardLayout()
        var bestScore = -Double.infinity
        // Only plausible column counts; text measurement is done once, not per candidate.
        let averageHeight = heights.values.reduce(0, +) / CGFloat(ordered.count)
        let ideal = min(ordered.count, max(1, Int(sqrt(Double(ordered.count) * Double(ratio * averageHeight / NoteMetrics.width)).rounded())))
        var columnCounts = Array(max(1, ideal - 2)...min(ordered.count, ideal + 2))
        if ordered.count <= 6 { columnCounts = Array(1...ordered.count) }
        if ordered.count == 2, reserved.isEmpty, viewport.width > viewport.height,
           viewport.width >= NoteMetrics.width * 2 + Self.gap + ViewportCalculator.padding * 2 {
            columnCounts = [2]
        }
        for columns in columnCounts {
            var output = BoardLayout(heights: heights, stackingOrder: ordered.map(\.id))
            var occupied = reserved
            var lastDistance: CGFloat = 0
            for item in ordered {
                let height = heights[item.id]!
                var choices: [CGPoint] = []
                for column in 0..<columns {
                    let x = (CGFloat(column) - CGFloat(columns - 1) / 2) * (NoteMetrics.width + Self.gap)
                    let inColumn = occupied.filter { abs($0.midX - x) < NoteMetrics.width + Self.gap - 0.01 }
                    let radialY = sqrt(max(0, lastDistance - x * x))
                    let ys = [radialY, -radialY] + inColumn.flatMap { [$0.minY - Self.gap - height / 2, $0.maxY + Self.gap + height / 2] }
                    for y in ys {
                        let point = CGPoint(x: x, y: y)
                        guard x * x + y * y >= lastDistance - 0.01 else { continue }
                        let frame = Self.frame(at: point, height: height)
                        if !inColumn.contains(where: { Self.conflicts(frame, $0) }) { choices.append(point) }
                    }
                }
                let point = choices.min(by: Self.nearer)!
                output.positions[item.id] = point
                occupied.append(Self.frame(at: point, height: height))
                lastDistance = point.x * point.x + point.y * point.y
            }
            output.bounds = occupied.reduce(CGRect.null) { $0.union($1) }
            let fit = ViewportCalculator.fitScale(bounds: output.bounds, viewport: viewport)
            let shape = abs(log(Double((output.bounds.width / output.bounds.height) / ratio)))
            let score = Double(fit) * 100 - shape
            if score > bestScore { bestScore = score; best = output }
        }
        return best
    }

    /// Reconcile content without moving any existing card. Only missing cards get a position.
    func refreshed(_ old: BoardLayout, items: [TodoItem], now: Date, reserved: [CGRect] = [], viewport: CGSize = defaultViewport) -> BoardLayout {
        let ordered = TodoOrdering().sorted(items.filter { $0.status == .active }, now: now)
        let ids = Set(ordered.map(\.id))
        var result = old
        for item in ordered { result.heights[item.id] = NoteMetrics.height(for: item) }
        let missing = ordered.filter { result.positions[$0.id] == nil }
        if !missing.isEmpty {
            // The automatic layout supplies urgency-based targets, never replacement positions.
            let targets = layout(items: ordered, now: now, viewport: viewport)
            var occupied = ids.compactMap { result.frame(for: $0) } + reserved
            for item in missing {
                let point = vacant(near: targets.positions[item.id] ?? .zero, height: result.heights[item.id]!, occupied: occupied)
                result.positions[item.id] = point
                occupied.append(Self.frame(at: point, height: result.heights[item.id]!))
            }
        }
        let known = Set(result.stackingOrder)
        result.stackingOrder.append(contentsOf: ordered.map(\.id).filter { !known.contains($0) })
        result.updateBounds(visibleIDs: ids, reserved: reserved)
        return result
    }

    private func vacant(near target: CGPoint, height: CGFloat, occupied: [CGRect]) -> CGPoint {
        var candidates = [target]
        for frame in occupied {
            let xs = [frame.minX - Self.gap - NoteMetrics.width / 2, frame.maxX + Self.gap + NoteMetrics.width / 2]
            let ys = [frame.minY - Self.gap - height / 2, frame.maxY + Self.gap + height / 2]
            candidates += xs.map { CGPoint(x: $0, y: target.y) }
            candidates += ys.map { CGPoint(x: target.x, y: $0) }
            candidates += xs.flatMap { x in ys.map { CGPoint(x: x, y: $0) } }
        }
        return candidates.filter { point in
            !occupied.contains { Self.conflicts(Self.frame(at: point, height: height), $0) }
        }.min { a, b in
            Self.nearer(CGPoint(x: a.x - target.x, y: a.y - target.y), CGPoint(x: b.x - target.x, y: b.y - target.y))
        } ?? target // With finite rectangles, the outermost top/bottom candidate is always free.
    }

    static func frame(at center: CGPoint, height: CGFloat = NoteMetrics.minimumHeight) -> CGRect {
        CGRect(x: center.x - NoteMetrics.width / 2, y: center.y - height / 2, width: NoteMetrics.width, height: height)
    }

    static func conflicts(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX + gap - 0.01 && a.maxX > b.minX - gap + 0.01 &&
        a.minY < b.maxY + gap - 0.01 && a.maxY > b.minY - gap + 0.01
    }

    private static func nearer(_ a: CGPoint, _ b: CGPoint) -> Bool {
        let l = a.x * a.x + a.y * a.y, r = b.x * b.x + b.y * b.y
        if abs(l - r) > 0.01 { return l < r }
        if a.y != b.y { return a.y < b.y }
        return a.x < b.x
    }
}

extension BoardLayout {
    mutating func updateBounds(visibleIDs: Set<UUID>, reserved: [CGRect] = []) {
        let extent = (visibleIDs.compactMap { frame(for: $0) } + reserved).reduce(CGRect.null) { $0.union($1) }
        bounds = extent.isNull ? .zero : extent
    }
}
