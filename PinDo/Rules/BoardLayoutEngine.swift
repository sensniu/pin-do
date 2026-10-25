import Foundation

struct BoardLayout: Equatable {
    var positions: [UUID: CGPoint] = [:]
    var bounds: CGRect = .zero
}

struct BoardLayoutEngine {
    // The 9-point inset keeps the original 194-point text width in a smaller card.
    static let noteSize = CGSize(width: 212, height: 170)
    static let notePadding: CGFloat = 9
    static let gap: CGFloat = 16

    func layout(items: [TodoItem], now: Date, reserved: [CGRect] = []) -> BoardLayout {
        guard !items.isEmpty || !reserved.isEmpty else { return BoardLayout() }
        let ordered = TodoOrdering().sorted(items.filter { $0.status == .active }, now: now)
        let stepX = Self.noteSize.width + Self.gap
        let stepY = Self.noteSize.height + Self.gap
        // Enough extra rings for the single short-lived undo reservation.
        let radius = Int(ceil(sqrt(Double(ordered.count + reserved.count)))) + 2
        var slots: [CGPoint] = []
        for x in -radius...radius {
            for y in -radius...radius {
                let center = CGPoint(x: CGFloat(x) * stepX, y: CGFloat(y) * stepY)
                let frame = Self.frame(at: center)
                if !reserved.contains(where: { $0.intersects(frame) }) { slots.append(center) }
            }
        }
        slots.sort {
            let left = $0.x * $0.x + $0.y * $0.y
            let right = $1.x * $1.x + $1.y * $1.y
            if left != right { return left < right }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.x < $1.x
        }
        var output = BoardLayout()
        var bounds = CGRect.null
        for (item, position) in zip(ordered, slots) {
            output.positions[item.id] = position
            bounds = bounds.union(Self.frame(at: position))
        }
        for frame in reserved { bounds = bounds.union(frame) }
        output.bounds = bounds.isNull ? .zero : bounds
        return output
    }

    static func frame(at center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - noteSize.width / 2, y: center.y - noteSize.height / 2,
            width: noteSize.width, height: noteSize.height
        )
    }
}

