// Exports the app icon: the menu bar gauge at "normal" (first segment lit) on a dark rounded tile, Dimmer-style.
// Compiled together with Sources/StatusIcon.swift so both icons share one drawing function.
// build.sh runs: swiftc -parse-as-library Sources/StatusIcon.swift icon.swift → <tool> <out.iconset>
import AppKit

@main
enum IconExport {
    static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
                try render(px).write(to: out.appendingPathComponent(name))
            }
        }
    }

    static func render(_ px: Int) -> Data {
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// 1024-unit canvas, Big Sur grid: 824×824 rounded square with 100 margin.
    static func draw() {
        let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 24
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.set()
        NSColor(srgbRed: 0.106, green: 0.114, blue: 0.133, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: NSColor(srgbRed: 0.082, green: 0.090, blue: 0.106, alpha: 1),
                   ending: NSColor(srgbRed: 0.227, green: 0.247, blue: 0.290, alpha: 1))!
            .draw(in: tile, angle: 90)

        // Soft glow on the lit segment, like Dimmer's bright window.
        let glow = NSShadow()
        glow.shadowBlurRadius = 60
        glow.shadowColor = NSColor(srgbRed: 0.85, green: 0.95, blue: 1, alpha: 0.5)
        StatusIcon.drawGauge(in: NSRect(x: 512 - 260, y: 512 - 260, width: 520, height: 520),
                             litSegments: 1, ink: .white, unlitAlpha: 0.22, litShadow: glow)
    }
}
