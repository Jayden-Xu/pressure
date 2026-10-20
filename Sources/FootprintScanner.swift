import Foundation

/// One menu row: an app (every process inside its .app bundle, summed) or a process outside any .app.
struct MemoryEntry {
    let name: String
    let bytes: UInt64
}

/// Runs only when the menu opens. Nothing is cached, so every open shows fresh numbers.
enum FootprintScanner {
    static func topEntries(limit: Int, excluding excluded: Set<String>) -> [MemoryEntry] {
        var apps: [String: UInt64] = [:]  // bytes, keyed by outermost .app path
        var candidates: [(bytes: UInt64, app: String?, name: String)] = []
        var argsBuffer = [UInt8](repeating: 0, count: 64 * 1024)

        for pid in allPIDs() where pid > 0 {
            // Processes of other users (root, _windowserver…) fail here and are skipped.
            guard let bytes = footprint(of: pid) else { continue }
            var path = executablePath(of: pid)
            if path.flatMap({ outermostApp(in: $0) }) == nil, let launched = launchPath(of: pid, buffer: &argsBuffer) {
                path = launched
            }
            if let path, let app = outermostApp(in: path) {
                apps[app, default: 0] += bytes
            } else {
                let name = path.map { ($0 as NSString).lastPathComponent } ?? processName(of: pid)
                candidates.append((bytes, nil, name))
            }
        }
        for (app, bytes) in apps {
            candidates.append((bytes, app, displayName(of: app)))
        }
        candidates.sort { $0.bytes > $1.bytes }

        // Bundle IDs are read lazily: only for rows that might be shown.
        var result: [MemoryEntry] = []
        for c in candidates {
            guard result.count < limit else { break }
            if let app = c.app, let id = bundleID(of: app), excluded.contains(id) { continue }
            result.append(MemoryEntry(name: c.name, bytes: c.bytes))
        }
        return result
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

    private static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// Path the process was started from. Differs from proc_pidpath when the binary was moved after
    /// launch: Warp's self-update moves the running binary out of Warp.app to ".../old".
    private static func launchPath(of pid: pid_t, buffer: inout [UInt8]) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        // Layout: Int32 argc, then the NUL-terminated exec path.
        let path = buffer[4..<size].prefix { $0 != 0 }
        return path.isEmpty ? nil : String(decoding: path, as: UTF8.self)
    }

    private static func processName(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
    }

    /// Outermost bundle wins, so helpers nested deep inside (Chrome's Helper.app) count toward the app itself.
    private static func outermostApp(in path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// Finder's localized name ("活动监视器"), without the extension even when Finder shows extensions.
    private static func displayName(of app: String) -> String {
        let name = FileManager.default.displayName(atPath: app)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Read Info.plist directly: `Bundle(path:)` caches every bundle it opens for the life of the process.
    private static func bundleID(of app: String) -> String? {
        let plist = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
        return plist?["CFBundleIdentifier"] as? String
    }
}
