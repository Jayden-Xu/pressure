import AppKit
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var monitor: PressureMonitor!

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
    }

    private func showIcon(for level: PressureLevel) {
        let litBars = switch level {
        case .normal: 1
        case .warning: 2
        case .critical: 3
        }
        statusItem.button?.image = StatusIcon.menuBarImage(litBars: litBars, description: "内存压力：\(level.title)")
    }

    // MARK: Menu

    // Rebuilt on every open: one scan, no cache, nothing runs while the menu is closed.
    // (menuNeedsUpdate rather than menuWillOpen: it is AppKit's hook for changing items before display.)
    func menuNeedsUpdate(_ menu: NSMenu) {
        let entries = FootprintScanner.topEntries(limit: Config.topN, excluding: Config.excludedBundleIDs)
        let swap = FootprintScanner.swapUsedBytes()
        let level = monitor.level

        let rows: [(label: String, value: String)] =
            [("内存压力", level.title), ("Swap", gb(swap)), ("", "")]  // empty = separator
            + entries.map { ($0.name, gb($0.bytes)) }
        let layout = RowView.Layout(rows)

        menu.removeAllItems()
        for row in rows {
            guard !row.label.isEmpty else { menu.addItem(.separator()); continue }
            let item = NSMenuItem()
            item.view = RowView(label: row.label, value: row.value, layout: layout)
            menu.addItem(item)
        }
        if entries.isEmpty {
            let none = NSMenuItem(title: "没有可显示的进程", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "开机启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quitSelf = NSMenuItem(title: "退出 Pressure", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitSelf)
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    // MARK: Actions

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
        case .normal: "正常"
        case .warning: "警告"
        case .critical: "严重"
        }
    }
}

/// A hand-drawn menu row: label and right-aligned value, in the normal text color.
/// A plain NSMenuItem can't do this: a disabled item is always drawn grey, whatever color its title asks for,
/// and an enabled one highlights on hover as if it were clickable.
@MainActor
private final class RowView: NSView {
    static let labelFont = NSFont.menuFont(ofSize: 0)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: labelFont.pointSize, weight: .regular)
    static let inset: CGFloat = 14
    static let height: CGFloat = 24

    /// Shared column widths so values line up across rows.
    @MainActor
    struct Layout {
        let labelWidth: CGFloat
        let valueWidth: CGFloat

        init(_ rows: [(label: String, value: String)]) {
            labelWidth = min(220, rows.map { RowView.width($0.label, RowView.labelFont) }.max() ?? 0)
            valueWidth = rows.map { RowView.width($0.value, RowView.valueFont) }.max() ?? 0
        }

        /// Minimum row width; the menu may be wider (e.g. "退出 Pressure ⌘Q"), and rows stretch to it.
        var minWidth: CGFloat { RowView.inset + labelWidth + 28 + valueWidth + RowView.inset }
    }

    private let label: String
    private let value: String
    private let layout: Layout

    init(label: String, value: String, layout: Layout) {
        self.label = label
        self.value = value
        self.layout = layout
        super.init(frame: NSRect(x: 0, y: 0, width: layout.minWidth, height: Self.height))
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
        let y = ((Self.height - Self.labelFont.boundingRectForFont.height) / 2).rounded()
        let line = Self.labelFont.boundingRectForFont.height
        (label as NSString).draw(in: NSRect(x: Self.inset, y: y, width: layout.labelWidth, height: line),
                                 withAttributes: [.font: Self.labelFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncate])
        (value as NSString).draw(in: NSRect(x: bounds.maxX - Self.inset - layout.valueWidth, y: y, width: layout.valueWidth, height: line),
                                 withAttributes: [.font: Self.valueFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: right])
    }

    static func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
}
