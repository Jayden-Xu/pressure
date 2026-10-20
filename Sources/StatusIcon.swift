import AppKit

/// The gauge: a vertical capsule whose fill height shows the pressure level.
/// The menu bar icon and the app icon (icon.swift) are both drawn by `drawGauge`.
enum StatusIcon {
    /// Draws the capsule into `rect` in the current graphics context. `fill` is 0...1.
    /// Line width and gap scale with the rect, so the same shape works at 16 pt and 1024 px.
    static func drawGauge(in rect: NSRect, fill: CGFloat, outline: NSColor, liquid: NSColor) {
        let line = rect.width * 0.15
        let shell = rect.insetBy(dx: line / 2, dy: line / 2)
        let shellPath = NSBezierPath(roundedRect: shell, xRadius: shell.width / 2, yRadius: shell.width / 2)
        shellPath.lineWidth = line
        outline.setStroke()
        shellPath.stroke()

        let gap = line * 0.75
        let inner = shell.insetBy(dx: line / 2 + gap, dy: line / 2 + gap)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * fill)).addClip()
        liquid.setFill()
        NSBezierPath(roundedRect: inner, xRadius: inner.width / 2, yRadius: inner.width / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Monochrome template, like Dimmer's: follows the menu bar's light/dark look and stays readable
    /// on any wallpaper. The level shows through fill height alone.
    /// Rendered once into a @2x bitmap in a device color space with device colors. A drawing-handler
    /// image is redrawn in the menu bar's color space, and ColorSync builds ~1 MB of conversion
    /// tables per color × display for that (about 8 MB on a two-display setup).
    static func menuBarImage(fill: CGFloat, description: String) -> NSImage {
        let size = NSSize(width: 10, height: 17)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 2, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let black = NSColor(deviceWhite: 0, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawGauge(in: NSRect(origin: .zero, size: size), fill: fill, outline: black, liquid: black)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
