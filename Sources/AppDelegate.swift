import AppKit
import Carbon.HIToolbox
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var monitor: PressureMonitor!
    private var hotKey: HotKey?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        // A menu with no items never opens, so menuNeedsUpdate would never run.
        menu.addItem(NSMenuItem(title: "Pressure", action: nil, keyEquivalent: ""))
        statusItem.menu = menu

        monitor = PressureMonitor { [weak self] level in
            MainActor.assumeIsolated { self?.showIcon(for: level) }
        }
        showIcon(for: monitor.level)

        // ⌃⌥⌘P opens the menu, same as clicking the icon.
        hotKey = HotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey | optionKey | controlKey) { [weak self] in
            // Async: let the Carbon handler return before the menu's tracking loop starts.
            DispatchQueue.main.async { self?.statusItem.button?.performClick(nil) }
        }
    }

    private func showIcon(for level: PressureLevel) {
        statusItem.button?.image = StatusIcon.menuBarImage(litSegments: level.segments, description: "Memory pressure: \(level.title.capitalized)")
    }

    // MARK: Menu

    /// Only the biggest consumers.
    private static let topN = 3

    // Rebuilt on every open: one scan, no cache, nothing runs while the menu is closed.
    // (menuNeedsUpdate rather than menuWillOpen: it is AppKit's hook for changing items before display.)
    func menuNeedsUpdate(_ menu: NSMenu) {
        let entries = FootprintScanner.topEntries(limit: Self.topN)

        // Titles start 16 pt in, or 24 pt once any item shows a checkmark (the state column).
        // Separators always end 16 pt from the right. The hand-drawn rows follow the titles.
        let loginOn = SMAppService.mainApp.status == .enabled
        let inset: CGFloat = loginOn ? 24 : 16

        // App bars show the share of physical memory: the same ruler on every open.
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        let rows = entries.map { (label: $0.name, value: gb($0.bytes), share: Double($0.bytes) / ram) }
        let layout = RowView.Layout(rows.map { ($0.label, $0.value) }, inset: inset)

        menu.removeAllItems()
        let header = NSMenuItem()
        header.view = HeaderView(level: monitor.level, swap: gb(FootprintScanner.swapUsedBytes()), inset: inset)
        menu.addItem(header)
        menu.addItem(.separator())
        for row in rows {
            let item = NSMenuItem()
            item.view = RowView(label: row.label, value: row.value, share: row.share, layout: layout)
            menu.addItem(item)
        }
        if entries.isEmpty {
            let none = NSMenuItem(title: "No apps to show", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = loginOn ? .on : .off
        menu.addItem(login)
        // Own selector: macOS 26 auto-adds an ✕ symbol to items wired to terminate(_:).
        let quitSelf = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitSelf.target = self
        menu.addItem(quitSelf)
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    // MARK: Actions

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("Pressure: login item change failed: \(error)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

private extension PressureLevel {
    var title: String {
        switch self {
        case .normal: "NORMAL"
        case .warning: "WARNING"
        case .critical: "CRITICAL"
        }
    }

    /// Lit gauge segments, in the menu bar and the menu header.
    var segments: Int {
        switch self {
        case .normal: 1
        case .warning: 2
        case .critical: 3
        }
    }
}

/// Text is the system's label color; only the gauge and bars are grey (black at low alpha on the light menu).
@MainActor private enum Ink {
    static let text = NSColor.labelColor
    /// Segments, lit and unlit: the menu bar gauge's two tones, lightened.
    static let litAlpha: CGFloat = 0.5, unlitAlpha: CGFloat = 0.25  // unlit = lit × 0.25
    static let lit = NSColor.labelColor.withAlphaComponent(litAlpha)
    static let unlit = NSColor.labelColor.withAlphaComponent(litAlpha * unlitAlpha)
}

private func mono(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, kern: CGFloat = 0) -> [NSAttributedString.Key: Any] {
    [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]
}

/// Menu header, terminal style, the gauge drawn as in the menu bar:
///
///     PRESSURE              SWAP
///     ◜◝ NORMAL           0.4 GB
@MainActor
private final class HeaderView: NSView {
    private let level: PressureLevel
    private let swap: String
    private let inset: CGFloat

    init(level: PressureLevel, swap: String, inset: CGFloat) {
        self.level = level
        self.swap = swap
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 62))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let x = inset, right = bounds.maxX - RowView.trailing
        let caption = mono(9, .semibold, Ink.text, kern: 1.5)
        let value = mono(17, .medium, Ink.text, kern: 0.5)

        NSAttributedString(string: "PRESSURE", attributes: caption).draw(at: NSPoint(x: x, y: 40))
        drawRight(NSAttributedString(string: "SWAP", attributes: caption), right: right, y: 40)

        StatusIcon.drawGauge(in: NSRect(x: x, y: 9, width: 22, height: 22), litSegments: level.segments,
                             ink: Ink.lit, unlitAlpha: Ink.unlitAlpha)
        NSAttributedString(string: level.title, attributes: value).draw(at: NSPoint(x: x + 30, y: 9))
        drawRight(NSAttributedString(string: swap, attributes: value), right: right, y: 9)
    }

    private func drawRight(_ text: NSAttributedString, right: CGFloat, y: CGFloat) {
        // Kern also follows the last glyph; drop it so the text ends flush with the separators.
        let kern = text.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        text.draw(at: NSPoint(x: right - text.size().width + kern, y: y))
    }
}

/// A hand-drawn menu row: app name, value right-aligned in mono, and a segmented bar below,
/// cut like the menu bar gauge.
/// A plain NSMenuItem can't do this: a disabled item is always drawn grey, whatever color its title asks for,
/// and an enabled one highlights on hover as if it were clickable.
@MainActor
private final class RowView: NSView {
    static let labelFont = NSFont.menuFont(ofSize: 0)
    static let valueFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    /// Separators end this far from the right edge; values end there too.
    static let trailing: CGFloat = 16
    static let textHeight: CGFloat = 22
    static let height: CGFloat = textHeight + 9
    /// Bar: 20 segments, so one segment is 5% of physical memory.
    static let segments = 20, segmentGap: CGFloat = 2, barHeight: CGFloat = 3

    // Built once, not on every draw.
    static let labelAttributes: [NSAttributedString.Key: Any] = {
        let truncate = NSMutableParagraphStyle()
        truncate.lineBreakMode = .byTruncatingTail
        return [.font: labelFont, .foregroundColor: Ink.text, .paragraphStyle: truncate]
    }()
    static let valueAttributes: [NSAttributedString.Key: Any] = {
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        return [.font: valueFont, .foregroundColor: Ink.text, .paragraphStyle: right]
    }()

    /// Shared column widths so values line up across rows.
    @MainActor
    struct Layout {
        let inset: CGFloat
        let labelWidth: CGFloat
        let valueWidth: CGFloat

        /// `inset`: where the menu's titles start.
        init(_ rows: [(label: String, value: String)], inset: CGFloat) {
            self.inset = inset
            labelWidth = min(220, rows.map { RowView.width($0.label, RowView.labelFont) }.max() ?? 0)
            valueWidth = rows.map { RowView.width($0.value, RowView.valueFont) }.max() ?? 0
        }

        /// Minimum row width; the menu may be wider (standard items reserve room for icons and shortcuts), and rows stretch to it.
        var minWidth: CGFloat { max(240, inset + labelWidth + 28 + valueWidth + RowView.trailing) }
    }

    private let label: String
    private let value: String
    /// Fraction of physical memory.
    private let share: Double
    private let layout: Layout

    init(label: String, value: String, share: Double, layout: Layout) {
        self.label = label
        self.value = value
        self.share = share
        self.layout = layout
        super.init(frame: NSRect(x: 0, y: 0, width: layout.minWidth, height: Self.height))
        // Stretch with the menu so values sit at its right edge, in line with key equivalents.
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    // Drawn directly rather than with two NSTextFields per row: half the memory each time the menu opens.
    override func draw(_ dirtyRect: NSRect) {
        let line = Self.labelFont.boundingRectForFont.height
        // Text in the top part, bar below it.
        let y = ((Self.textHeight - line) / 2).rounded() + bounds.height - Self.textHeight
        (label as NSString).draw(in: NSRect(x: layout.inset, y: y, width: layout.labelWidth, height: line),
                                 withAttributes: Self.labelAttributes)
        // Mono value, baseline-matched to the label.
        let vy = y + Self.labelFont.descender - Self.valueFont.descender
        (value as NSString).draw(in: NSRect(x: bounds.maxX - Self.trailing - layout.valueWidth, y: vy, width: layout.valueWidth, height: line),
                                 withAttributes: Self.valueAttributes)

        // Segment edges rounded to whole points so every segment is equally crisp.
        let x0 = layout.inset, width = bounds.maxX - Self.trailing - x0
        let n = Self.segments, step = (width + Self.segmentGap) / CGFloat(n)
        let lit = max(1, Int((share * Double(n)).rounded()))
        for i in 0..<n {
            let left = (x0 + CGFloat(i) * step).rounded()
            let right = (x0 + CGFloat(i + 1) * step - Self.segmentGap).rounded()
            (i < lit ? Ink.lit : Ink.unlit).setFill()
            NSRect(x: left, y: 6, width: right - left, height: Self.barHeight).fill()
        }
    }

    static func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
}
