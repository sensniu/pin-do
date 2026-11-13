import Foundation

/// Uses window frames (including the title bar), in logical screen points.
enum WindowSizing {
    static let defaultScale = sqrt(0.65)
    static let preferenceVersion = 1
    static let preferenceKey = "mainWindowSizingVersion"

    static func frame(visible: CGRect, restored: CGRect?, minimum: CGSize, upgrade: Bool) -> CGRect {
        let margin = min(32, min(visible.width, visible.height) * 0.04)
        let available = visible.insetBy(dx: margin, dy: margin)
        let recommended = CGSize(width: min(available.width, max(minimum.width, visible.width * defaultScale)),
                                 height: min(available.height, max(minimum.height, visible.height * defaultScale)))
        var size = restored?.size ?? recommended
        if upgrade, restored != nil {
            size.width = max(size.width, recommended.width)
            size.height = max(size.height, recommended.height)
        }
        let bounds = restored != nil ? visible : available
        size.width = min(bounds.width, max(minimum.width, size.width))
        size.height = min(bounds.height, max(minimum.height, size.height))
        let center = restored.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: visible.midX, y: visible.midY)
        return CGRect(x: min(bounds.maxX - size.width, max(bounds.minX, center.x - size.width / 2)),
                      y: min(bounds.maxY - size.height, max(bounds.minY, center.y - size.height / 2)),
                      width: size.width, height: size.height)
    }
}
