import AppKit
import Carbon.HIToolbox

/// Global toggle hotkey (⌃⌥V) via Carbon RegisterEventHotKey, which — unlike
/// NSEvent global monitors — needs no Accessibility permission. Carbon
/// delivers the event on the main run loop.
@MainActor
final class HotKeyManager {
    // Written once during init on the main actor; read in deinit after all
    // other references are gone. Safe without isolation, which deinit can't have.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var handlerRef: EventHandlerRef?
    fileprivate let onTap: () -> Void

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { manager.onTap() }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x564F_5053), id: 1)  // 'VOPS'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
