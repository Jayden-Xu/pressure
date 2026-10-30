import Foundation

/// Memory of the biggest apps over the last 3 h, one slot per 3 min: the same slots as `History`, so the row
/// curves line up with the chart's resolution. A scan of every process runs only when a new slot starts (from
/// the 10 s check that already runs, no timer of its own) or when the menu opens; each keeps the top `keep`
/// apps, so an app that climbs into the menu's top 3 already has its own past. Held in memory, written with
/// History's hourly flush (and on sleep / quit), pruned of apps that left the window.
@MainActor
final class AppHistory {
    static let count = 60, keep = 5
    private let defaults = UserDefaults.standard
    private var ids = [Int](repeating: -1, count: count)
    /// Per app path, 0.01 GB per slot; 0 = outside the top `keep` in that slot.
    private var series: [String: [Int]] = [:]
    private var dirty = false

    init() {
        guard let saved = defaults.array(forKey: "appIds") as? [Int], saved.count == Self.count,
              let stored = defaults.dictionary(forKey: "appSeries") as? [String: [Int]] else { return }
        ids = saved
        series = stored.filter { $0.value.count == Self.count }
    }

    func hasSlot(_ id: Int) -> Bool { ids[id % Self.count] == id }

    /// Keeps the highest value per app and slot, so a scan at menu open merges into the slot's scan.
    func record(_ top: [MemoryEntry], id: Int) {
        let i = id % Self.count
        if ids[i] != id {
            if id % History.flushEvery == 0 { flush() }
            ids[i] = id
            for key in Array(series.keys) { series[key]?[i] = 0 }
        }
        for entry in top.prefix(Self.keep) {
            let old = series[entry.path]?[i] ?? 0
            let value = max(old, Int((Double(entry.bytes) / 1_073_741_824 * 100).rounded()))
            series[entry.path, default: [Int](repeating: 0, count: Self.count)][i] = value
        }
        dirty = true
    }

    func flush() {
        guard dirty else { return }
        let newest = History.id(of: Date())
        series = series.filter { _, v in v.indices.contains { v[$0] > 0 && ids[$0] > newest - Self.count } }
        defaults.set(ids, forKey: "appIds")
        defaults.set(series, forKey: "appSeries")
        dirty = false
    }

    /// The last 3 h of one app, oldest first; nil where no scan ran (the app wasn't running, or the display slept).
    func values(of path: String) -> [Int?] {
        let newest = History.id(of: Date()), v = series[path]
        return (0..<Self.count).map { k in
            let id = newest - Self.count + 1 + k, i = id % Self.count
            return ids[i] == id ? (v?[i] ?? 0) : nil
        }
    }
}
