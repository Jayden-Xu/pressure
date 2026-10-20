import AppKit

/// A memory chip: a body with pins on both sides and three bars inside that light up with the level
/// (1 normal, 2 warning, 3 critical). The menu bar icon and the app icon (icon.swift) both draw it with `drawChip`.
enum StatusIcon {
    /// Draws the chip into `rect` (square) in the current graphics context.
    /// Geometry is on a 16-unit grid so the menu bar version lands on whole points.
    static func drawChip(in rect: NSRect, litBars: Int, ink: NSColor, unlitAlpha: CGFloat) {
        let u = rect.width / 16
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: rect.minX + x * u, y: rect.minY + y * u, width: w * u, height: h * u)
        }

        let body = NSBezierPath(roundedRect: r(3.75, 0.75, 8.5, 14.5), xRadius: 2 * u, yRadius: 2 * u)
        body.lineWidth = 1.5 * u
        ink.setStroke()
        body.stroke()

        ink.setFill()
        for y in [3.0, 7.25, 11.5] as [CGFloat] {
            NSBezierPath(roundedRect: r(0.5, y, 2.5, 1.5), xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
            NSBezierPath(roundedRect: r(13, y, 2.5, 1.5), xRadius: 0.5 * u, yRadius: 0.5 * u).fill()
        }

        for (i, y) in ([3, 6.75, 10.5] as [CGFloat]).enumerated() {
            (i < litBars ? ink : ink.withAlphaComponent(ink.alphaComponent * unlitAlpha)).setFill()
            NSBezierPath(roundedRect: r(6, y, 4, 2.5), xRadius: 0.75 * u, yRadius: 0.75 * u).fill()
        }
    }

    /// Monochrome template, like Dimmer's: follows the menu bar's light/dark look and stays readable
    /// on any wallpaper. 16 pt wide, so the item is 32 pt like most others.
    /// Rendered once into a @2x bitmap in a device color space with device colors. A drawing-handler
    /// image is redrawn in the menu bar's color space, and ColorSync builds ~1 MB of conversion
    /// tables per color × display for that (about 8 MB on a two-display setup).
    static func menuBarImage(litBars: Int, description: String) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 2, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawChip(in: NSRect(origin: .zero, size: size), litBars: litBars, ink: NSColor(deviceWhite: 0, alpha: 1), unlitAlpha: 0.3)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
