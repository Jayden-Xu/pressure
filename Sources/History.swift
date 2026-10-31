import Foundation

/// The last 24 h of swap and memory pressure, one slot per 3 min, kept as a ring: a time's slot is
/// `id % count`, so the newest sample overwrites the one 24 h older and the stored data never grows.
/// Fed by the 10 s pressure check that already runs (no timer of its own); a slot keeps its highest
/// swap and highest level. Nothing is recorded while the Mac sleeps, is off, or the app isn't running; the
/// series carries the last slot before such a gap across it, so the chart never breaks.
/// Held in memory, which is what the menu draws from, and written once an hour (on the hour), plus on sleep and quit:
/// each write costs a wakeup, so fewer and bigger. A crash or power loss costs at most the last hour.
///
/// Alongside, this week's time at each level, per day, for the menu's week rings: only time measured, so
/// it never guesses across a gap the way the chart does.
@MainActor
final class History {
    /// `swap` in 0.01 GB; `level` is a PressureLevel raw value.
    struct Slot {
        var id = -1
        var swap = 0
        var level = PressureLevel.normal.rawValue
    }

    static let count = 480, seconds = 180.0, flushEvery = 20
    private var ring = [Slot](repeating: Slot(), count: count)
    private let defaults = UserDefaults.standard
    private var dirty = false
    /// Seconds seen at each level (normal, warning, critical) on each day of this week, by the day's start
    /// (seconds since 1970). A reading adds the time since the one before, if that was at most `gapLimit` ago,
    /// to the level it held: asleep, off or quit adds nothing. At most 7 × 3 numbers.
    private var week: [Int: [Double]] = [:]
    private var lastReading: Date?
    /// The 10 s check fires at most 15 s apart (5 s leeway); a longer gap is a sleep.
    static let gapLimit = 30.0

    init() {
        if let saved = defaults.dictionary(forKey: "week") as? [String: [Double]] {
            week = saved.reduce(into: [:]) { if let k = Int($1.key), $1.value.count == 3 { $0[k] = $1.value } }
        }
        guard let flat = defaults.array(forKey: "history") as? [Int], flat.count == Self.count * 3 else { return }
        for i in 0..<Self.count { ring[i] = Slot(id: flat[3 * i], swap: flat[3 * i + 1], level: flat[3 * i + 2]) }
        if !defaults.bool(forKey: "weekSeeded") { seedWeek() }
    }

    /// The week rings came after the 24 h history: once, rebuild this week's days that the ring still holds from
    /// its recorded slots, 3 min each at the slot's level (its highest, so pressure can come out a little high).
    /// The ring holds every slot the app was running, so it covers what was measured on those days so far.
    private func seedWeek() {
        guard let start = Self.calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return }
        var days: [Int: [Double]] = [:]
        for slot in ring where slot.id >= 0 {
            let date = Date(timeIntervalSince1970: Double(slot.id) * Self.seconds)
            guard date >= start else { continue }
            let day = Int(Self.calendar.startOfDay(for: date).timeIntervalSince1970)
            let k = slot.level >= PressureLevel.critical.rawValue ? 2 : slot.level >= PressureLevel.warning.rawValue ? 1 : 0
            days[day, default: [0, 0, 0]][k] += Self.seconds
        }
        for (day, levels) in days { week[day] = levels }
        dirty = true
    }

    static func id(of date: Date) -> Int { Int(date.timeIntervalSince1970 / seconds) }

    /// Weeks start on Monday, like dimmer's.
    private static var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal
    }

    func record(swapBytes: UInt64, level: PressureLevel) {
        let now = Date()
        // The level passed in is the one that held since the last reading: the 10 s check records before it
        // reads the new level.
        if let last = lastReading, now.timeIntervalSince(last) > 0, now.timeIntervalSince(last) <= Self.gapLimit {
            let day = Int(Self.calendar.startOfDay(for: now).timeIntervalSince1970)
            if week[day] == nil {
                // A new day: drop the days of earlier weeks.
                let start = Self.calendar.dateInterval(of: .weekOfYear, for: now)?.start.timeIntervalSince1970 ?? 0
                week = week.filter { Double($0.key) >= start }
            }
            week[day, default: [0, 0, 0]][level == .critical ? 2 : level == .warning ? 1 : 0] += now.timeIntervalSince(last)
        }
        lastReading = now

        let id = Self.id(of: now), i = id % Self.count
        let reading = Slot(id: id, swap: Int((Double(swapBytes) / 1_073_741_824 * 100).rounded()), level: level.rawValue)
        if ring[i].id != id {
            if id % Self.flushEvery == 0 { flush() }
            ring[i] = Slot(id: id)
        }
        ring[i].swap = max(ring[i].swap, reading.swap)
        ring[i].level = max(ring[i].level, reading.level)
        dirty = true
    }

    func flush() {
        guard dirty else { return }
        defaults.set(ring.flatMap { [$0.id, $0.swap, $0.level] }, forKey: "history")
        defaults.set(Dictionary(uniqueKeysWithValues: week.map { (String($0.key), $0.value) }), forKey: "week")
        defaults.set(true, forKey: "weekSeeded")
        dirty = false
    }

    /// Seconds at each level (normal, warning, critical) on each day of this week, Monday first; nil for the
    /// days still to come.
    func weekDays() -> [[Double]?] {
        let cal = Self.calendar, today = cal.startOfDay(for: Date())
        guard let start = cal.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        return (0..<7).map { k in
            guard let day = cal.date(byAdding: .day, value: k, to: start) else { return nil }
            return day > today ? nil : week[Int(day.timeIntervalSince1970)] ?? [0, 0, 0]
        }
    }

    /// The last 24 h, oldest first. A slot with nothing recorded (asleep, off, app not running) carries the
    /// slot before it, also from before the window; nil only before the very first reading (a fresh install).
    func series() -> [Slot?] {
        let newest = Self.id(of: Date()), first = newest - Self.count + 1
        // The newest slot older than the window, to carry into its start.
        var carry = ring.filter { $0.id >= 0 && $0.id < first }.max { $0.id < $1.id }
        return (first...newest).map { id in
            let slot = ring[id % Self.count]
            if slot.id == id { carry = slot }
            return carry
        }
    }
}
