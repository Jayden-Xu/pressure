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
    private let history = History()
    private let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

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
            MainActor.assumeIsolated {
                self?.showIcon(for: level)
                self?.sample()
            }
        }
        // kill / pkill (and so a reinstall) end the process without applicationWillTerminate: save first.
        signal(SIGTERM, SIG_IGN)
        termination.setEventHandler { [weak self] in
            self?.history.flush()
            NSApp.terminate(nil)
        }
        termination.activate()
        // Nothing more is recorded while asleep, so save then rather than wake the disk for it.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.history.flush() }
        }
        monitor.onTick = { [weak self] in MainActor.assumeIsolated { self?.sample() } }
        showIcon(for: monitor.level)
        sample()

        // ⌃⌥⌘P opens the menu, same as clicking the icon.
        hotKey = HotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey | optionKey | controlKey) { [weak self] in
            // Async: let the Carbon handler return before the menu's tracking loop starts.
            DispatchQueue.main.async { self?.statusItem.button?.performClick(nil) }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        history.flush()
    }

    /// Swap and level into the 24 h history; called on the monitor's existing 10 s check.
    private func sample() {
        history.record(swapBytes: FootprintScanner.swapUsedBytes(), level: monitor.level)
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
        // Opening the menu reads everything fresh (level, so the icon follows too; swap) into memory, so the
        // chart ends at this very moment. It is drawn from memory: nothing is written here.
        monitor.refresh()
        sample()
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
        header.view = HeaderView(level: monitor.level, swap: String(format: "%.2f", gib(FootprintScanner.swapUsedBytes())), inset: inset)
        menu.addItem(header)
        menu.addItem(.separator())
        let chart = NSMenuItem()
        chart.view = HistoryView(series: history.series(), inset: inset)
        menu.addItem(chart)
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
        login.attributedTitle = NSAttributedString(string: login.title, attributes: [.font: Ink.bodyFont])
        login.target = self
        login.state = loginOn ? .on : .off
        menu.addItem(login)
        // Own selector: macOS 26 auto-adds an ✕ symbol to items wired to terminate(_:).
        let quitSelf = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitSelf.attributedTitle = NSAttributedString(string: quitSelf.title, attributes: [.font: Ink.bodyFont])
        quitSelf.target = self
        menu.addItem(quitSelf)
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", gib(bytes))
    }

    private func gib(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_073_741_824
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
    /// Menu width, the same as dimmer's; only an unusually long app name widens it.
    static let menuWidth: CGFloat = 320
    static let gaugeRadius: CGFloat = 52
    /// The header's number is centered in this width, ending at the separators.
    static let columnWidth: CGFloat = 120
    /// The whole menu is SF Mono in three sizes: the header's number (medium), everything else you read
    /// (rows, stats, menu items), and captions (labels, axes), which are also spaced out (regular).
    static let hero: CGFloat = 38, body: CGFloat = 14, caption: CGFloat = 11
    static let bodyFont = NSFont.monospacedSystemFont(ofSize: body, weight: .regular)
    /// Segments, lit and unlit: the menu bar gauge's two tones, lightened.
    static let litAlpha: CGFloat = 0.5, unlitAlpha: CGFloat = 0.25  // unlit = lit × 0.25
    static let lit = NSColor.labelColor.withAlphaComponent(litAlpha)
    static let unlit = NSColor.labelColor.withAlphaComponent(litAlpha * unlitAlpha)
    /// The pressure lane above the chart: all cells the same height, the worse the level the darker; a cell
    /// with no data (the app wasn't running) is only a faint outline, so it differs from a normal one.
    static let normal = NSColor.labelColor.withAlphaComponent(0.25)
    static let warning = NSColor.labelColor.withAlphaComponent(0.5)
    static let critical = NSColor.labelColor.withAlphaComponent(0.8)
    static let noData = NSColor.labelColor.withAlphaComponent(0.2)
    /// Hairlines: guides.
    static let hair = NSColor.labelColor.withAlphaComponent(0.14)
    static let tick = NSColor.labelColor.withAlphaComponent(0.4)

}

private func mono(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, kern: CGFloat = 0) -> [NSAttributedString.Key: Any] {
    [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]
}

/// Menu header: the menu bar's gauge over the level at the left edge, the swap in large mono over
/// its label at the right edge, the unit in the label — like the rows' label left, value right.
///
///     ◜‾‾◝         1.2
///     WARNING   SWAP GB
///
/// The gauge's three segments are cut square with 3 pt gaps, like the bars below.
@MainActor
private final class HeaderView: NSView {
    private let level: PressureLevel
    /// Swap in GB, "1.2".
    private let swap: String
    /// Where the menu's titles start, so the columns split the same span as the rows.
    private let inset: CGFloat
    private static let radius = Ink.gaugeRadius, thickness: CGFloat = 15, gap: CGFloat = 5, sweep: CGFloat = 240
    private static let height: CGFloat = 126

    init(level: PressureLevel, swap: String, inset: CGFloat) {
        self.level = level
        self.swap = swap
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: Ink.menuWidth, height: Self.height))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let left = inset, right = bounds.maxX - RowView.trailing

        // Three segments over 240°, open at the bottom, lit clockwise from the left.
        // Its lower ends sit 16 above the labels' baseline.
        let r = Self.radius, w = Self.thickness, c = NSPoint(x: left + r, y: 30 + r / 2)
        let gapDeg = Self.gap / (r - w / 2) * 180 / .pi, seg = (Self.sweep - 2 * gapDeg) / 3
        for i in 0..<3 {
            let a0 = 90 + Self.sweep / 2 - CGFloat(i) * (seg + gapDeg), a1 = a0 - seg
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
            p.appendArc(withCenter: c, radius: r - w, startAngle: a1, endAngle: a0, clockwise: false)
            p.close()
            (i < level.segments ? Ink.lit : Ink.unlit).setFill()
            p.fill()
        }
        // Each label centered under its gauge or number; labels share one baseline.
        // The 38 pt value is centered on the gauge's height; its column ends at the separators.
        let label = mono(Ink.caption, .regular, Ink.text, kern: 1)
        let title = NSAttributedString(string: level.title, attributes: label)
        let unit = NSAttributedString(string: "SWAP GB", attributes: label)
        let value = NSAttributedString(string: swap, attributes: mono(Ink.hero, .medium, Ink.text, kern: 0.5))
        let x2 = right - Ink.columnWidth / 2
        Self.place(title, x: c.x, baseline: 14, anchor: 0.5)
        Self.place(unit, x: x2, baseline: 14, anchor: 0.5)
        Self.place(value, x: x2, baseline: c.y + r / 4 - 14, anchor: 0.5)
    }

    /// Ink width: kern also follows the last glyph; leave it out.
    fileprivate static func width(_ text: NSAttributedString) -> CGFloat {
        text.size().width - (text.attribute(.kern, at: max(0, text.length - 1), effectiveRange: nil) as? CGFloat ?? 0)
    }

    /// Draws `text` with its first font's baseline at `baseline`; `anchor` 0 starts it at `x`, 0.5 centers it, 1 ends it there.
    fileprivate static func place(_ text: NSAttributedString, x: CGFloat, baseline: CGFloat, anchor: CGFloat) {
        let descender = (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.descender ?? 0
        text.draw(at: NSPoint(x: (x - width(text) * anchor).rounded(), y: baseline + descender))
    }
}

/// A hand-drawn menu row: app name, value right-aligned in mono, and a segmented bar below,
/// cut like the menu bar gauge.
/// A plain NSMenuItem can't do this: a disabled item is always drawn grey, whatever color its title asks for,
/// and an enabled one highlights on hover as if it were clickable.
@MainActor
private final class RowView: NSView {
    static let labelFont = Ink.bodyFont, valueFont = Ink.bodyFont
    /// Separators end this far from the right edge; values end there too.
    static let trailing: CGFloat = 16
    static let height: CGFloat = 36
    /// Bar: 60 thin segments, so one segment is 1.7% of physical memory.
    static let segments = 60, segmentGap: CGFloat = 1, barHeight: CGFloat = 3

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
            labelWidth = min(200, rows.map { RowView.width($0.label, RowView.labelFont) }.max() ?? 0)
            valueWidth = rows.map { RowView.width($0.value, RowView.valueFont) }.max() ?? 0
        }

        /// Minimum row width; the menu may be wider (standard items reserve room for icons and shortcuts), and rows stretch to it.
        var minWidth: CGFloat { max(Ink.menuWidth, inset + labelWidth + 28 + valueWidth + RowView.trailing) }
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
        let line = Self.labelFont.ascender - Self.labelFont.descender
        // Name and value share one baseline, 21 above the bottom; the bar is below it.
        let y = 21 + Self.labelFont.descender
        (label as NSString).draw(in: NSRect(x: layout.inset, y: y, width: layout.labelWidth, height: line),
                                 withAttributes: Self.labelAttributes)
        (value as NSString).draw(in: NSRect(x: bounds.maxX - Self.trailing - layout.valueWidth, y: y, width: layout.valueWidth, height: line),
                                 withAttributes: Self.valueAttributes)

        // Segment edges rounded to whole points so every segment is equally crisp.
        let x0 = layout.inset, width = bounds.maxX - Self.trailing - x0
        let n = Self.segments, step = (width + Self.segmentGap) / CGFloat(n)
        let lit = max(1, Int((share * Double(n)).rounded()))
        for i in 0..<n {
            // Edges on half points (whole pixels on a retina screen) so every segment is equally crisp.
            let left = ((x0 + CGFloat(i) * step) * 2).rounded() / 2
            let right = ((x0 + CGFloat(i + 1) * step - Self.segmentGap) * 2).rounded() / 2
            (i < lit ? Ink.lit : Ink.unlit).setFill()
            NSRect(x: left, y: 8, width: right - left, height: Self.barHeight).fill()
        }
    }

    static func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The last 24 h as a line chart, oldest at the left, now at the right: swap as a line with a light fill,
/// a lane of segments above it for warnings (grey) and criticals (black), an hourly time axis, and the
/// peak and the average under it, each a number over its label. One point per 3 min, about a pixel each.
@MainActor
private final class HistoryView: NSView {
    private let series: [History.Slot?]
    private let inset: CGFloat
    static let height: CGFloat = 172

    init(series: [History.Slot?], inset: CGFloat) {
        self.series = series
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: Ink.menuWidth, height: Self.height))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let n = series.count, h = Self.height
        let x0 = inset, w = bounds.maxX - RowView.trailing - x0
        let top = h - 24, bottom = h - 94
        // The top guide is the highest whole GB above the peak, at least 2.
        let guide = max(2, ((series.compactMap { $0?.swap }.max() ?? 0) + 99) / 100)
        func x(_ i: Int) -> CGFloat { x0 + w * CGFloat(i) / CGFloat(n - 1) }
        func y(_ s: History.Slot) -> CGFloat { bottom + CGFloat(s.swap) / 100 / CGFloat(guide) * (top - bottom) }

        // Guides: the bottom, the middle and the top (dotted).
        for g in 0...2 {
            let gy = bottom + CGFloat(g) * (top - bottom) / 2
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x0, y: gy))
            p.line(to: NSPoint(x: x0 + w, y: gy))
            if g > 0 { p.setLineDash([1, 2], count: 2, phase: 0) }
            p.lineWidth = 0.6
            Ink.hair.setStroke()
            p.stroke()
        }
        let caption = mono(Ink.caption, .regular, Ink.text, kern: 1)

        // Swap: one line with a fill per stretch with data. Where nothing was recorded (the app wasn't running)
        // a dotted straight line joins the stretches, and runs back from the first one to the left edge.
        var run: [NSPoint] = []
        var lastEnd: NSPoint?
        func dotted(from a: NSPoint, to b: NSPoint) {
            let p = NSBezierPath()
            p.move(to: a)
            p.line(to: b)
            p.setLineDash([2, 3], count: 2, phase: 0)
            p.lineWidth = 1
            Ink.tick.setStroke()
            p.stroke()
        }
        func finishRun() {
            defer { run.removeAll() }
            guard let first = run.first, let last = run.last else { return }
            if let end = lastEnd { dotted(from: end, to: first) } else if first.x > x0 + 1 { dotted(from: NSPoint(x: x0, y: first.y), to: first) }
            lastEnd = last
            let line = NSBezierPath()
            line.move(to: first)
            for p in run.dropFirst() { line.line(to: p) }
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: last.x, y: bottom))
            area.line(to: NSPoint(x: first.x, y: bottom))
            area.close()
            // The fill fades from the top guide down to the bottom, the same for every stretch.
            NSGraphicsContext.saveGraphicsState()
            area.addClip()
            NSGradient(starting: Ink.text.withAlphaComponent(0.2), ending: Ink.text.withAlphaComponent(0.01))?
                .draw(from: NSPoint(x: x0, y: top), to: NSPoint(x: x0, y: bottom), options: [])
            NSGraphicsContext.restoreGraphicsState()
            line.lineWidth = 1.2
            line.lineJoinStyle = .round
            Ink.text.setStroke()
            line.stroke()
        }
        var stats = (peak: 0, sum: 0, count: 0)
        for (i, slot) in series.enumerated() {
            guard let s = slot else { finishRun(); continue }
            run.append(NSPoint(x: x(i), y: y(s)))
            stats.peak = max(stats.peak, s.swap)
            stats.sum += s.swap
            stats.count += 1
        }
        finishRun()
        if let end = lastEnd, end.x < x0 + w - 1 { dotted(from: end, to: NSPoint(x: x0 + w, y: end.y)) }
        // Pressure lane: one cell per real quarter hour (5 slots of 3 min, counted from the clock, not from the
        // left edge, so cells keep the same slots as the window slides), lit by the worst level inside. A cell sits
        // exactly under its slots on the line; the two at the ends are partial.
        let newest = History.id(of: Date()), firstId = newest - n + 1, per = 5
        let half = w / CGFloat(n - 1) / 2
        for g in (firstId / per)...(newest / per) {
            let a = max(g * per - firstId, 0), b = min(g * per + per - 1 - firstId, n - 1)
            let left = max(x(a) - half, x0), right = min(x(b) + half, x0 + w)
            let cell = NSRect(x: left, y: h - 12, width: right - left - 0.5, height: 8)
            guard let worst = series[a...b].compactMap({ $0?.level }).max() else {
                let outline = NSBezierPath(rect: cell.insetBy(dx: 0.25, dy: 0.25))
                outline.lineWidth = 0.5
                Ink.noData.setStroke()
                outline.stroke()
                continue
            }
            let level = worst >= PressureLevel.critical.rawValue ? 2 : worst > PressureLevel.normal.rawValue ? 1 : 0
            [Ink.normal, Ink.warning, Ink.critical][level].setFill()
            cell.fill()
        }

        // Time axis in local clock time: a tick at every whole hour in the window, longer at 3 h and 6 h,
        // labeled at 00, 06, 12 and 18. The window runs from 24 h ago to the newest slot.
        let axisY = h - 96
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: x0, y: axisY))
        axis.line(to: NSPoint(x: x0 + w, y: axisY))
        let cal = Calendar.current
        let start = Date(timeIntervalSince1970: Double(newest - n + 1) * History.seconds)
        let span = Double(n - 1) * History.seconds
        var hour = cal.nextDate(after: start, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime)
        while let t = hour, t.timeIntervalSince(start) <= span {
            let tx = x0 + w * CGFloat(t.timeIntervalSince(start) / span), clock = cal.component(.hour, from: t)
            axis.move(to: NSPoint(x: tx, y: axisY))
            axis.line(to: NSPoint(x: tx, y: axisY - (clock % 6 == 0 ? 7 : clock % 3 == 0 ? 5 : 3)))
            if clock % 6 == 0 {
                // Keep a label next to an end of the axis inside it.
                let anchor: CGFloat = tx - x0 < 12 ? 0 : x0 + w - tx < 12 ? 1 : 0.5
                HeaderView.place(NSAttributedString(string: String(format: "%02d", clock), attributes: caption), x: tx, baseline: h - 117, anchor: anchor)
            }
            hour = cal.date(byAdding: .hour, value: 1, to: t)
        }
        axis.lineWidth = 0.7
        Ink.tick.setStroke()
        axis.stroke()

        // Peak and average, each a number over its label with the unit in it, centered in its half.
        let have = stats.count > 0
        let blocks = [(have ? String(format: "%.2f", Double(stats.peak) / 100) : "--", "PEAK GB"),
                      (have ? String(format: "%.2f", Double(stats.sum) / Double(stats.count) / 100) : "--", "AVG GB")]
        for (k, block) in blocks.enumerated() {
            let cx = x0 + w * (k == 0 ? 0.25 : 0.75)
            HeaderView.place(NSAttributedString(string: block.0, attributes: mono(Ink.body, .regular, Ink.text)), x: cx, baseline: h - 148, anchor: 0.5)
            HeaderView.place(NSAttributedString(string: block.1, attributes: caption), x: cx, baseline: h - 165, anchor: 0.5)
        }
    }
}
