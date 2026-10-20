import Foundation

/// Raw values match `kern.memorystatus_vm_pressure_level`.
enum PressureLevel: Int {
    case normal = 1, warning = 2, critical = 4
}

/// Tracks the kernel's memory pressure level. No polling: the kernel pushes every change.
final class PressureMonitor {
    private(set) var level: PressureLevel
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)

    init(onChange: @escaping (PressureLevel) -> Void) {
        level = Self.currentLevel()
        source.setEventHandler { [unowned self] in
            // Use the event's level, not a fresh sysctl read: `memory_pressure -S` simulates
            // by sending notifications without changing the sysctl value.
            let event = source.data
            level = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            onChange(level)
        }
        source.activate()
    }

    /// The dispatch source only fires on transitions, so read the starting level once;
    /// otherwise launching under pressure would show "normal" until the next change.
    private static func currentLevel() -> PressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .normal }
        return PressureLevel(rawValue: Int(value)) ?? .normal
    }
}
