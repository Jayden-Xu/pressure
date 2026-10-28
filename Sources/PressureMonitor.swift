import Foundation

/// Raw values match `kern.memorystatus_vm_pressure_level`.
enum PressureLevel: Int {
    case normal = 1, warning = 2, critical = 4
}

/// Tracks the kernel's memory pressure level.
///
/// The memory pressure dispatch source alone is not enough: the kernel notifies processes largest
/// first and stops once pressure eases, so a ~10 MB process like this one often never hears about
/// a warning (measured: 3 normal↔warning transitions, 0 events). A slow sysctl check catches those.
final class PressureMonitor {
    private(set) var level: PressureLevel
    private var lastSysctlLevel: PressureLevel
    private let onChange: (PressureLevel) -> Void
    /// Every check (10 s), changed or not: the history samples here instead of running its own timer.
    var onTick: (() -> Void)?
    private let events = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    private let check = DispatchSource.makeTimerSource(queue: .main)

    init(onChange: @escaping (PressureLevel) -> Void) {
        self.onChange = onChange
        lastSysctlLevel = Self.sysctlLevel()
        level = lastSysctlLevel

        events.setEventHandler { [unowned self] in
            // Trust the event's level: `memory_pressure -S` simulates by sending notifications
            // without changing the sysctl value.
            let event = events.data
            update(event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal)
        }
        events.activate()

        // Only react when the sysctl value itself changes, so a simulated event isn't undone 10 s later.
        // Large leeway lets the system batch this wakeup with others.
        check.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(5))
        check.setEventHandler { [unowned self] in
            onTick?()
            let current = Self.sysctlLevel()
            guard current != lastSysctlLevel else { return }
            lastSysctlLevel = current
            update(current)
        }
        check.activate()
    }

    /// Reads the level now instead of waiting for the next 10 s check; the menu calls it when it opens.
    func refresh() {
        let current = Self.sysctlLevel()
        guard current != lastSysctlLevel else { return }
        lastSysctlLevel = current
        update(current)
    }

    private func update(_ new: PressureLevel) {
        guard new != level else { return }
        level = new
        onChange(new)
    }

    private static func sysctlLevel() -> PressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .normal }
        return PressureLevel(rawValue: Int(value)) ?? .normal
    }
}
