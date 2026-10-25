import AppKit

/// A pressure gauge: a thick 240° arc in three segments that light clockwise from the left with the level
/// (1 normal, 2 warning, 3 critical); unlit segments are faint.
/// The menu bar icon and the app icon (icon.swift) both draw it with `drawGauge`.
enum StatusIcon {
    /// Geometry on a 16-unit grid; the arc's bounding box is centered in the square.
    enum Grid {
        static let centerY: CGFloat = 6
        static let outerRadius: CGFloat = 8, innerRadius: CGFloat = 4.6
        static let startAngle: CGFloat = 210, sweep: CGFloat = 240, gap: CGFloat = 8  // degrees
    }

    /// Draws the gauge into `rect` (square) in the current graphics context.
    /// `litShadow`, if set, is applied to the lit segments only (the app icon's glow).
    static func drawGauge(in rect: NSRect, litSegments: Int, ink: NSColor, unlitAlpha: CGFloat, litShadow: NSShadow? = nil) {
        let u = rect.width / 16
        let center = NSPoint(x: rect.midX, y: rect.minY + Grid.centerY * u)
        let segment = (Grid.sweep - 2 * Grid.gap) / 3
        for i in 0..<3 {
            let a0 = Grid.startAngle - CGFloat(i) * (segment + Grid.gap), a1 = a0 - segment
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: Grid.outerRadius * u, startAngle: a0, endAngle: a1, clockwise: true)
            path.appendArc(withCenter: center, radius: Grid.innerRadius * u, startAngle: a1, endAngle: a0, clockwise: false)
            path.close()
            NSGraphicsContext.saveGraphicsState()
            if i < litSegments {
                litShadow?.set()
                ink.setFill()
            } else {
                ink.withAlphaComponent(ink.alphaComponent * unlitAlpha).setFill()
            }
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Monochrome template, like Dimmer's: the system tints it to match the menu bar.
    /// 16 pt wide, so the item is 32 pt like most others.
    /// Rendered once into a @2x bitmap in a device color space with device colors. A drawing-handler
    /// image is redrawn in the menu bar's color space, and ColorSync builds ~1 MB of conversion
    /// tables per color × display for that (about 8 MB on a two-display setup).
    static func menuBarImage(litSegments: Int, description: String) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 2, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawGauge(in: NSRect(origin: .zero, size: size), litSegments: litSegments, ink: NSColor(deviceWhite: 0, alpha: 1), unlitAlpha: 0.4)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
