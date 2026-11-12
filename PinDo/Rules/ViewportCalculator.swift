import Foundation

struct ViewportCalculator {
    static let padding: CGFloat = 42

    static func fitScale(bounds: CGRect, viewport: CGSize) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        let width = max(1, viewport.width - padding * 2)
        let height = max(1, viewport.height - padding * 2)
        return min(1, width / bounds.width, height / bounds.height)
    }

    static func position(
        world: CGPoint, bounds: CGRect, viewport: CGSize, scale: CGFloat, pan: CGSize
    ) -> CGPoint {
        CGPoint(
            x: viewport.width / 2 + (world.x - bounds.midX) * scale + pan.width,
            y: viewport.height / 2 + (world.y - bounds.midY) * scale + pan.height
        )
    }

    static func draggedPosition(origin: CGPoint, translation: CGSize, scale: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + translation.width / max(0.05, scale),
                y: origin.y + translation.height / max(0.05, scale))
    }
}

