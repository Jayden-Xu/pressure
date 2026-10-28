import Foundation

/// The last 24 h of swap and memory pressure, one slot per 3 min, kept as a ring: a time's slot is
/// `id % count`, so the newest sample overwrites the one 24 h older and the stored data never grows.
/// Fed by the 10 s pressure check that already runs (no timer of its own); a slot keeps its highest
/// swap and highest level. Held in memory and written once an hour (on the hour), plus on sleep and quit:
/// each write costs a wakeup, so fewer and bigger. A crash or power loss costs at most the last hour.
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

    init() {
        guard let flat = defaults.array(forKey: "history") as? [Int], flat.count == Self.count * 3 else { return }
        for i in 0..<Self.count { ring[i] = Slot(id: flat[3 * i], swap: flat[3 * i + 1], level: flat[3 * i + 2]) }
    }

    static func id(of date: Date) -> Int { Int(date.timeIntervalSince1970 / seconds) }

    func record(swapBytes: UInt64, level: PressureLevel) {
        let id = Self.id(of: Date()), i = id % Self.count
        if ring[i].id != id {
            if id % Self.flushEvery == 0 { flush() }
            ring[i] = Slot(id: id)
        }
        ring[i].swap = max(ring[i].swap, Int((Double(swapBytes) / 1_073_741_824 * 100).rounded()))
        ring[i].level = max(ring[i].level, level.rawValue)
        dirty = true
    }

    func flush() {
        guard dirty else { return }
        defaults.set(ring.flatMap { [$0.id, $0.swap, $0.level] }, forKey: "history")
        dirty = false
    }

    /// The last 24 h, oldest first; nil where nothing was recorded (the app wasn't running).
    func series() -> [Slot?] {
        let newest = Self.id(of: Date())
        return (0..<Self.count).map { k in
            let id = newest - Self.count + 1 + k
            let slot = ring[id % Self.count]
            return slot.id == id ? slot : nil
        }
    }
}
