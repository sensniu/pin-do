import AppKit

/// An original 18pt paper / folded corner / pin mark, drawn as a template at any backing scale.
@MainActor
enum MenuBarIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let paper = NSBezierPath()
            paper.move(to: NSPoint(x: 3, y: 2))
            paper.line(to: NSPoint(x: 14.5, y: 2))
            paper.line(to: NSPoint(x: 14.5, y: 11.5))
            paper.line(to: NSPoint(x: 10.5, y: 15.5))
            paper.line(to: NSPoint(x: 3, y: 15.5)); paper.close()
            paper.lineWidth = 1.3; paper.lineJoinStyle = .round; paper.stroke()
            let fold = NSBezierPath()
            fold.move(to: NSPoint(x: 10.5, y: 15.5)); fold.line(to: NSPoint(x: 10.5, y: 11.5))
            fold.line(to: NSPoint(x: 14.5, y: 11.5)); fold.lineWidth = 1.1; fold.stroke()
            NSBezierPath(ovalIn: NSRect(x: 4.5, y: 10, width: 3.2, height: 3.2)).fill()
            let pin = NSBezierPath()
            pin.move(to: NSPoint(x: 6.5, y: 10.5)); pin.line(to: NSPoint(x: 8.2, y: 7.8))
            pin.lineWidth = 1.3; pin.lineCapStyle = .round; pin.stroke()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 7, y: 5.7)); check.line(to: NSPoint(x: 8.5, y: 4.3))
            check.line(to: NSPoint(x: 11.5, y: 7.2))
            check.lineWidth = 1.3; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PinDo 便利贴白板"
        return image
    }
}
