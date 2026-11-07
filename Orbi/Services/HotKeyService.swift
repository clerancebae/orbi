import Carbon.HIToolbox
import OSLog

/// Global hotkeys via Carbon `RegisterEventHotKey` (no Accessibility permission, no packages).
/// Orbi registers its bubble shortcuts only while such a bubble is open, so the keys stay free
/// for other apps the rest of the time.
@MainActor
final class HotKeyService {
    static let shared = HotKeyService()

    enum Key: UInt32 {
        case allow = 1, deny, reply

        /// ⌥⌘Y, ⌥⌘N, ⌥⌘R.
        var keyCode: UInt32 {
            switch self {
            case .allow: UInt32(kVK_ANSI_Y)
            case .deny: UInt32(kVK_ANSI_N)
            case .reply: UInt32(kVK_ANSI_R)
            }
        }

        var label: String {
            switch self {
            case .allow: "⌥⌘Y"
            case .deny: "⌥⌘N"
            case .reply: "⌥⌘R"
            }
        }
    }

    private static let modifiers = UInt32(cmdKey | optionKey)
    private static let signature: OSType = 0x4F52_4249  // "ORBI"

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private let log = Logger(subsystem: "com.berke.Orbi", category: "HotKeys")

    func isRegistered(_ key: Key) -> Bool { refs[key.rawValue] != nil }

    /// Registers (or re-targets) `key`. If another app already owns the combination, it's skipped.
    func register(_ key: Key, action: @escaping () -> Void) {
        actions[key.rawValue] = action
        guard refs[key.rawValue] == nil else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: key.rawValue)
        let status = RegisterEventHotKey(key.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[key.rawValue] = ref
        } else {
            log.error("Hotkey \(key.label, privacy: .public) unavailable (\(status))")
        }
    }

    func unregister(_ key: Key) {
        actions[key.rawValue] = nil
        if let ref = refs.removeValue(forKey: key.rawValue) { UnregisterEventHotKey(ref) }
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == HotKeyService.signature else { return OSStatus(eventNotHandledErr) }
            let hotKey = id.id
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { HotKeyService.shared.fire(hotKey) }
            return noErr
        }, 1, &spec, nil, &handler)
        if status != noErr { log.error("Installing the hotkey handler failed (\(status))") }
    }
}
