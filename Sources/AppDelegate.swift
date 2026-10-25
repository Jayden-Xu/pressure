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
        let litSegments = switch level {
        case .normal: 1
        case .warning: 2
        case .critical: 3
        }
        statusItem.button?.image = StatusIcon.menuBarImage(litSegments: litSegments, description: "Memory pressure: \(level.title.capitalized)")
    }

    // MARK: Menu

    // Rebuilt on every open: one scan, no cache, nothing runs while the menu is closed.
    // (menuNeedsUpdate rather than menuWillOpen: it is AppKit's hook for changing items before display.)
    func menuNeedsUpdate(_ menu: NSMenu) {
        let entries = FootprintScanner.topEntries(limit: Config.topN)
        let swap = FootprintScanner.swapUsedBytes()
        let level = monitor.level

        // Titles start 16 pt in, or 24 pt once any item shows a checkmark (the state column).
        // Separators always end 16 pt from the right. The hand-drawn rows follow the titles.
        let loginOn = SMAppService.mainApp.status == .enabled
        let inset: CGFloat = loginOn ? 24 : 16

        // App bars show the share of physical memory: the same ruler on every open.
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        let rows: [(label: String, value: String, share: Double?)] =
            [("Swap", gb(swap), nil), ("", "", nil)]  // empty = separator
            + entries.map { ($0.name, gb($0.bytes), Double($0.bytes) / ram) }
        let layout = RowView.Layout(rows.map { ($0.label, $0.value) }, inset: inset)

        menu.removeAllItems()
        let header = NSMenuItem()
        header.view = HeaderView(level: level, inset: inset)
        menu.addItem(header)
        menu.addItem(.separator())
        for row in rows {
            guard !row.label.isEmpty else { menu.addItem(.separator()); continue }
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

    /// Lit segments, as in the menu bar gauge.
    var segments: Int {
        switch self {
        case .normal: 1
        case .warning: 2
        case .critical: 3
        }
    }
}

/// Dark grey on a light menu, light grey on a dark one.
@MainActor private let ink = NSColor.labelColor.withAlphaComponent(0.7)

private func mono(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, kern: CGFloat = 0) -> [NSAttributedString.Key: Any] {
    [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]
}

/// Menu header, terminal style:
///
///     MEMORY PRESSURE
///     NORMAL
///     ▮▮▮▮▮▮▮▮  ▯▯▯▯▯▯▯▯  ▯▯▯▯▯▯▯▯
@MainActor
private final class HeaderView: NSView {
    private let level: PressureLevel
    private let inset: CGFloat

    init(level: PressureLevel, inset: CGFloat) {
        self.level = level
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 86))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let x = inset, w = bounds.width - x - 16
        NSAttributedString(string: "MEMORY PRESSURE", attributes: mono(10, .semibold, .secondaryLabelColor, kern: 1.5))
            .draw(at: NSPoint(x: x, y: 62))
        NSAttributedString(string: level.title, attributes: mono(30, .medium, ink, kern: 1))
            .draw(at: NSPoint(x: x - 1, y: 20))
        let gap: CGFloat = 4, seg = (w - 2 * gap) / 3
        for i in 0..<3 {
            (i < level.segments ? ink : NSColor.quaternaryLabelColor).setFill()
            NSRect(x: x + CGFloat(i) * (seg + gap), y: 10, width: seg, height: 6).fill()
        }
    }
}

/// A hand-drawn menu row: label in the menu font, value right-aligned in grey mono.
/// A plain NSMenuItem can't do this: a disabled item is always drawn grey, whatever color its title asks for,
/// and an enabled one highlights on hover as if it were clickable.
@MainActor
private final class RowView: NSView {
    static let labelFont = NSFont.menuFont(ofSize: 0)
    static let valueFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    /// Separators end this far from the right edge; values end there too.
    static let trailing: CGFloat = 16
    static let height: CGFloat = 24

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
    /// Fraction of physical memory, drawn as a thin bar under the text; nil = no bar.
    private let share: Double?
    private let layout: Layout

    init(label: String, value: String, share: Double?, layout: Layout) {
        self.label = label
        self.value = value
        self.share = share
        self.layout = layout
        super.init(frame: NSRect(x: 0, y: 0, width: layout.minWidth, height: share == nil ? Self.height : Self.height + 9))
        // Stretch with the menu so values sit at its right edge, in line with key equivalents.
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    // Drawn directly rather than with two NSTextFields per row: half the memory each time the menu opens.
    override func draw(_ dirtyRect: NSRect) {
        let truncate = NSMutableParagraphStyle()
        truncate.lineBreakMode = .byTruncatingTail
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let line = Self.labelFont.boundingRectForFont.height
        // With a bar, the text sits in the top 24 pt and the bar below it.
        let y = ((Self.height - line) / 2).rounded() + bounds.height - Self.height
        (label as NSString).draw(in: NSRect(x: layout.inset, y: y, width: layout.labelWidth, height: line),
                                 withAttributes: [.font: Self.labelFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncate])
        // Mono value, baseline-matched to the label.
        let vy = y + Self.labelFont.descender - Self.valueFont.descender
        (value as NSString).draw(in: NSRect(x: bounds.maxX - Self.trailing - layout.valueWidth, y: vy, width: layout.valueWidth, height: line),
                                 withAttributes: [.font: Self.valueFont, .foregroundColor: ink, .paragraphStyle: right])

        guard let share else { return }
        let track = NSRect(x: layout.inset, y: 5, width: bounds.maxX - Self.trailing - layout.inset, height: 2)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        ink.setFill()
        NSRect(x: track.minX, y: track.minY, width: max(2, track.width * min(1, share)), height: track.height).fill()
    }

    static func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
}
