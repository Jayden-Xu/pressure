import Carbon.HIToolbox

/// A system-wide hotkey via Carbon's RegisterEventHotKey. WindowServer does the matching, so the app
/// stays asleep until the combo is pressed, and no Accessibility permission is needed
/// (an NSEvent global monitor would wake on every keystroke and require it).
/// Lives for the whole app, so it never unregisters.
@MainActor
final class HotKey {
    private let action: () -> Void
    private var handler: EventHandlerRef?
    private var ref: EventHotKeyRef?

    /// Returns nil if the combo can't be registered (e.g. another app already owns it); the shortcut then does nothing.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: 0x5052_5353 /* 'PRSS' */, id: 1)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            RemoveEventHandler(handler)
            return nil
        }
    }
}
