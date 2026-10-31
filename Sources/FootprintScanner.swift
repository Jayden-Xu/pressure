import Foundation

/// Who the system holds responsible for a process: the app it was started from, whether as a helper,
/// an XPC service (Safari for its WebKit web content) or a command typed in a terminal (Ghostty for claude).
/// Activity Monitor groups processes the same way. Exported by libquarantine in libSystem.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// One menu row: an app and every process it is responsible for, summed.
struct MemoryEntry {
    let name: String
    let bytes: UInt64
}

/// Runs only when the menu opens. Nothing is cached across opens, so every open shows fresh numbers.
enum FootprintScanner {
    static func topEntries(limit: Int) -> [MemoryEntry] {
        var apps: [String: UInt64] = [:]   // bytes, keyed by outermost .app path
        var appOf: [pid_t: String?] = [:]  // responsible pids repeat, so each is looked up once
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE

        func app(of pid: pid_t) -> String? {
            if let cached = appOf[pid] { return cached }
            let app = outermostApp(of: pid, buffer: &pathBuffer)
            appOf[pid] = app
            return app
        }

        for pid in allPIDs() where pid > 0 {
            // Processes of other users (root, _windowserver…) fail here and are skipped.
            guard let bytes = footprint(of: pid) else { continue }
            let responsible = responsibility_get_pid_responsible_for_pid(pid)
            // Processes belonging to no app (system daemons such as mdworker) are not shown.
            guard let app = (responsible > 0 ? app(of: responsible) : nil) ?? app(of: pid) else { continue }
            apps[app, default: 0] += bytes
        }

        // Display names are read lazily: only for rows that are shown.
        return apps.sorted { $0.value > $1.value }.prefix(limit).map {
            MemoryEntry(name: displayName(of: $0.key), bytes: $0.value)
        }
    }

    static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : 0
    }

    // MARK: libproc

    private static func allPIDs() -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        // Headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(max(0, Int(bytes) / MemoryLayout<pid_t>.size)))
    }

    /// Physical footprint: the same number as Activity Monitor's Memory column.
    private static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }

    /// Outermost .app containing the process's binary. Outermost wins, so helpers nested deep inside
    /// (Chrome's Helper.app) count toward the app itself. Searched in the C string, so processes outside
    /// any app (most of them) never become Swift strings.
    private static func outermostApp(of pid: pid_t, buffer: inout [CChar]) -> String? {
        buffer.withUnsafeMutableBufferPointer { buf -> String? in
            guard let base = buf.baseAddress, proc_pidpath(pid, base, UInt32(buf.count)) > 0,
                  let match = strstr(base, ".app/") else { return nil }
            match[4] = 0  // keep ".app", drop the rest
            return String(cString: base)
        }
    }

    /// Finder's localized name ("活动监视器"), without the extension even when Finder shows extensions.
    private static func displayName(of app: String) -> String {
        let name = FileManager.default.displayName(atPath: app)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
