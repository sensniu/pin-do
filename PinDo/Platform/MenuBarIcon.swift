import AppKit

/// The approved 18pt sticky note and round-head pin, drawn as a resolution-independent template.
@MainActor
enum MenuBarIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            // Keep the pin's transparent clearance inside this image, without clearing its backdrop.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.setLineCap(.round)
            context.setLineJoin(.round)

            context.saveGState()
            context.translateBy(x: 9, y: 10.75)
            context.rotate(by: -6 * .pi / 180)
            context.translateBy(x: -9, y: -10.75)
            let note = CGMutablePath()
            note.move(to: CGPoint(x: 3.5, y: 5.3))
            note.addLine(to: CGPoint(x: 14.5, y: 5.3))
            note.addQuadCurve(to: CGPoint(x: 15.3, y: 6.1), control: CGPoint(x: 15.3, y: 5.3))
            note.addLine(to: CGPoint(x: 15.3, y: 15.4))
            note.addQuadCurve(to: CGPoint(x: 14.5, y: 16.2), control: CGPoint(x: 15.3, y: 16.2))
            note.addLine(to: CGPoint(x: 3.5, y: 16.2))
            note.addQuadCurve(to: CGPoint(x: 2.7, y: 15.4), control: CGPoint(x: 2.7, y: 16.2))
            note.addLine(to: CGPoint(x: 2.7, y: 6.1))
            note.addQuadCurve(to: CGPoint(x: 3.5, y: 5.3), control: CGPoint(x: 2.7, y: 5.3))
            note.closeSubpath()
            context.addPath(note)
            context.setLineWidth(1.55)
            context.strokePath()
            context.restoreGState()

            context.saveGState()
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: 7.65, y: 0.45, width: 4.9, height: 4.9))
            context.move(to: CGPoint(x: 9.6, y: 4.3))
            context.addLine(to: CGPoint(x: 8.3, y: 7.3))
            context.setLineWidth(2.8)
            context.strokePath()
            context.restoreGState()

            context.move(to: CGPoint(x: 9.6, y: 4.3))
            context.addLine(to: CGPoint(x: 8.3, y: 7.3))
            context.setLineWidth(1.4)
            context.strokePath()
            context.fillEllipse(in: CGRect(x: 8.05, y: 0.85, width: 4.1, height: 4.1))
            context.endTransparencyLayer()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PinDo 图钉便利贴"
        return image
    }
}
