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
        let fill: CGFloat = switch level {
        case .normal: 1.0 / 3
        case .warning: 2.0 / 3
        case .critical: 1
        }
        statusItem.button?.image = StatusIcon.menuBarImage(fill: fill, description: "内存压力：\(level.title)")
    }

    // MARK: Menu

    // Rebuilt on every open: one scan, no cache, nothing runs while the menu is closed.
    // (menuNeedsUpdate rather than menuWillOpen: it is AppKit's hook for changing items before display.)
    func menuNeedsUpdate(_ menu: NSMenu) {
        let entries = FootprintScanner.topEntries(limit: Config.topN, excluding: Config.excludedBundleIDs)
        let swap = FootprintScanner.swapUsedBytes()
        let level = monitor.level

        let rows: [(label: String, value: String, pid: pid_t?)] =
            [("内存压力", level.title, nil), ("Swap", gb(swap), nil), ("", "", nil)]  // empty = separator
            + entries.map { ($0.name, gb($0.bytes), $0.appPID) }
        let quitButtons = { (pid: pid_t) in
            [self.button("退出", #selector(self.quitApp(_:)), pid: pid), self.button("强制退出", #selector(self.forceQuitApp(_:)), pid: pid)]
        }
        let layout = RowView.Layout(rows.map { ($0.label, $0.value) },
                                    buttons: entries.contains { $0.appPID != nil } ? quitButtons(0) : [])

        menu.removeAllItems()
        for row in rows {
            guard !row.label.isEmpty else { menu.addItem(.separator()); continue }
            // Processes outside a .app get no buttons: never kill background jobs from here.
            let buttons = row.pid.map(quitButtons) ?? []
            let item = NSMenuItem()
            item.view = RowView(label: row.label, value: row.value, buttons: buttons, layout: layout)
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

    private func button(_ title: String, _ action: Selector, pid: pid_t) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.tag = Int(pid)
        button.sizeToFit()
        return button
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    // MARK: Actions

    /// Normal quit, like ⌘Q: the app saves state and may ask about unsaved documents.
    @objc private func quitApp(_ sender: NSButton) {
        menu.cancelTracking()
        NSRunningApplication(processIdentifier: pid_t(sender.tag))?.terminate()
    }

    /// SIGKILL: ends at once, even a hung app; unsaved work is lost.
    @objc private func forceQuitApp(_ sender: NSButton) {
        menu.cancelTracking()
        NSRunningApplication(processIdentifier: pid_t(sender.tag))?.forceTerminate()
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
        case .normal: "正常"
        case .warning: "警告"
        case .critical: "严重"
        }
    }
}

/// A hand-drawn menu row: label, right-aligned value, optional inline buttons.
/// Plain NSMenuItems can't do this: a disabled item is always drawn grey, whatever color its title asks for.
@MainActor
private final class RowView: NSView {
    static let labelFont = NSFont.menuFont(ofSize: 0)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: labelFont.pointSize, weight: .regular)
    static let inset: CGFloat = 14
    static let height: CGFloat = 24
    // Push buttons draw their bezel ~6 pt inside their frame, so frames overlap to look 8 pt apart.
    static let buttonGap: CGFloat = -4

    /// Shared column widths so values and buttons line up across rows.
    @MainActor
    struct Layout {
        let labelWidth: CGFloat
        let valueWidth: CGFloat
        let buttonsWidth: CGFloat

        /// `buttons` is one sample set (all app rows carry the same ones), empty if no row has any.
        init(_ rows: [(label: String, value: String)], buttons: [NSButton]) {
            labelWidth = min(220, rows.map { RowView.width($0.label, RowView.labelFont) }.max() ?? 0)
            valueWidth = rows.map { RowView.width($0.value, RowView.valueFont) }.max() ?? 0
            buttonsWidth = buttons.isEmpty ? 0 : buttons.reduce(20) { $0 + $1.frame.width + RowView.buttonGap } - RowView.buttonGap
        }

        var valueRight: CGFloat { RowView.inset + labelWidth + 28 + valueWidth }
        var totalWidth: CGFloat { valueRight + buttonsWidth + RowView.inset }
    }

    init(label: String, value: String, buttons: [NSButton], layout: Layout) {
        super.init(frame: NSRect(x: 0, y: 0, width: layout.totalWidth, height: Self.height))
        let labelField = Self.text(label, Self.labelFont)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.frame = Self.centered(x: Self.inset, width: layout.labelWidth, height: labelField.fittingSize.height)
        addSubview(labelField)

        let valueField = Self.text(value, Self.valueFont)
        valueField.alignment = .right
        valueField.frame = Self.centered(x: layout.valueRight - layout.valueWidth, width: layout.valueWidth, height: valueField.fittingSize.height)
        addSubview(valueField)

        var x = layout.valueRight + 20
        for button in buttons {
            button.frame = Self.centered(x: x, width: button.frame.width, height: button.frame.height)
            addSubview(button)
            x += button.frame.width + Self.buttonGap
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func text(_ string: String, _ font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = .labelColor
        return field
    }

    private static func centered(x: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: x, y: ((Self.height - height) / 2).rounded(), width: width, height: height)
    }

    static func width(_ string: String, _ font: NSFont) -> CGFloat {
        // +4: NSTextField's own text padding, without which it truncates.
        ceil((string as NSString).size(withAttributes: [.font: font]).width) + 4
    }
}
