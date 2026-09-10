import AppKit
import Carbon.HIToolbox

/// A key combination, stored in the form Carbon needs and the form people read.
struct HotKeyCombination: Equatable {
    /// Virtual key code, as reported by `NSEvent.keyCode`.
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …).
    var carbonModifiers: UInt32
    /// The key's printed name, e.g. "P" or "Space".
    var keyLabel: String

    static let `default` = HotKeyCombination(
        keyCode: UInt32(kVK_ANSI_P),
        carbonModifiers: UInt32(optionKey | cmdKey),
        keyLabel: "P"
    )

    /// Menu-style rendering, in Apple's canonical modifier order.
    var displayName: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    /// A shortcut with no modifier would swallow ordinary typing system-wide.
    var isUsable: Bool { carbonModifiers != 0 && !keyLabel.isEmpty }

    private enum Key {
        static let code = "shortcut.keyCode"
        static let modifiers = "shortcut.modifiers"
        static let label = "shortcut.keyLabel"
    }

    static func load(from defaults: UserDefaults) -> HotKeyCombination {
        guard let code = defaults.object(forKey: Key.code) as? Int,
              let modifiers = defaults.object(forKey: Key.modifiers) as? Int,
              let label = defaults.string(forKey: Key.label) else { return .default }
        let stored = HotKeyCombination(
            keyCode: UInt32(code),
            carbonModifiers: UInt32(modifiers),
            keyLabel: label
        )
        return stored.isUsable ? stored : .default
    }

    func save(to defaults: UserDefaults) {
        defaults.set(Int(keyCode), forKey: Key.code)
        defaults.set(Int(carbonModifiers), forKey: Key.modifiers)
        defaults.set(keyLabel, forKey: Key.label)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    /// Printable name for a key press, falling back to names for keys that have
    /// no visible character.
    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space:      return "Space"
        case kVK_Return:     return "↩"
        case kVK_Tab:        return "⇥"
        case kVK_Escape:     return "⎋"
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        default:
            let characters = event.charactersIgnoringModifiers ?? ""
            return characters.isEmpty ? "Key \(event.keyCode)" : characters.uppercased()
        }
    }
}

/// Registers a system-wide hot key through Carbon, which — unlike an event tap —
/// works from a menu bar app with no Accessibility permission.
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?
    private var identifier: UInt32?

    /// Returns false when the combination is unusable or already taken by
    /// another app, so the UI can say so instead of silently doing nothing.
    @discardableResult
    func register(_ combination: HotKeyCombination, onPress: @escaping () -> Void) -> Bool {
        unregister()
        guard combination.isUsable else { return false }
        Self.installDispatcherIfNeeded()

        let id = Self.nextID
        Self.nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.carbonModifiers,
            EventHotKeyID(signature: OSType(0x4D454D42), id: id),   // 'MEMB'
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        Self.handlers[id] = onPress
        hotKeyRef = reference
        identifier = id
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let identifier { Self.handlers.removeValue(forKey: identifier) }
        hotKeyRef = nil
        identifier = nil
    }

    deinit { unregister() }

    private static func installDispatcherIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressed
            )
            guard status == noErr else { return status }
            DispatchQueue.main.async { GlobalHotKey.handlers[pressed.id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
