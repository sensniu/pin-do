import Foundation

struct BoardLayout: Equatable {
    var positions: [UUID: CGPoint] = [:]
    var heights: [UUID: CGFloat] = [:]
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
            var output = BoardLayout(heights: heights)
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

    /// Grow downward from the original top edge. Only actual collisions propagate;
    /// shrinking leaves neighboring notes and the camera in place.
    func resized(_ old: BoardLayout, item: TodoItem, visibleIDs: Set<UUID>, reserved: [CGRect]) -> BoardLayout {
        guard let original = old.frame(for: item.id) else { return old }
        let height = NoteMetrics.height(for: item)
        guard height != original.height else { return old }
        var result = old
        result.heights[item.id] = height
        result.positions[item.id] = CGPoint(x: original.midX, y: original.minY + height / 2)
        var queue = [item.id]
        let ids = visibleIDs.sorted { $0.uuidString < $1.uuidString }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard var frame = result.frame(for: id) else { continue }
            while let obstacle = reserved.filter({ Self.conflicts(frame, $0) }).max(by: { $0.maxY < $1.maxY }) {
                frame.origin.y = obstacle.maxY + Self.gap
                result.positions[id] = CGPoint(x: frame.midX, y: frame.midY)
            }
            for neighbor in ids where neighbor != id {
                guard var other = result.frame(for: neighbor), Self.conflicts(frame, other) else { continue }
                other.origin.y = frame.maxY + Self.gap
                result.positions[neighbor] = CGPoint(x: other.midX, y: other.midY)
                queue.append(neighbor)
            }
        }
        let frames = ids.compactMap { result.frame(for: $0) } + reserved
        result.bounds = frames.reduce(CGRect.null) { $0.union($1) }
        return result
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
