import Cocoa
import Carbon

/// Represents a user-configurable hotkey (modifier flags + key code).
struct HotkeyShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt  // Raw value of NSEvent.ModifierFlags

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// Human-readable description like "⌃⌥Space"
    var displayString: String {
        var parts: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        case 76: return "Enter"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            // Try to get the character from the key code
            let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            if let layoutDataRef {
                let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
                let layout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
                if length > 0 {
                    return String(utf16CodeUnits: chars, count: length).uppercased()
                }
            }
            return "Key\(keyCode)"
        }
    }

    // MARK: - Persistence

    private static let defaultsKey = "customHotkey"

    static func load() -> HotkeyShortcut? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

final class KeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    var onEscDown: (() -> Void)?

    /// Controls whether the monitor should intercept keys
    var isEnabled = true
    /// Controls whether we're in an active session (recording or refining) where ESC should be intercepted
    var isSessionActive = false

    /// Custom hotkey — when set, this is used instead of Fn
    var customHotkey: HotkeyShortcut? {
        didSet { hotkeyPressed = false }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnPressed = false
    private var hotkeyPressed = false

    /// ESC key code (0x35 = 53)
    private let escKeyCode: CGKeyCode = 0x35

    /// Start monitoring. Returns false if accessibility permission is missing.
    func start() -> Bool {
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    // MARK: - Private

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if the system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Handle ESC key — only suppress when session is active
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Int64(escKeyCode) && isSessionActive {
                DispatchQueue.main.async { [weak self] in self?.onEscDown?() }
                return nil
            }
        }

        // Custom hotkey mode
        if let hotkey = customHotkey, isEnabled {
            return handleCustomHotkey(type: type, event: event, hotkey: hotkey)
        }

        // Default Fn key mode
        if type == .keyDown || type == .keyUp {
            return Unmanaged.passUnretained(event)
        }
        return handleFnKey(event: event)
    }

    private func handleCustomHotkey(type: CGEventType, event: CGEvent, hotkey: HotkeyShortcut) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        // Mask to only care about modifier keys we track
        let relevantMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let currentMods = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)).intersection(relevantMask)
        let targetMods = hotkey.modifierFlags.intersection(relevantMask)

        if keyCode == hotkey.keyCode && currentMods == targetMods {
            if type == .keyDown {
                if !hotkeyPressed {
                    hotkeyPressed = true
                    DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
                }
                // Suppress all matching keyDown events (including key repeats) while held
                return nil
            } else if type == .keyUp && hotkeyPressed {
                hotkeyPressed = false
                DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleFnKey(event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let fnDown = flags.contains(.maskSecondaryFn)

        if fnDown && !fnPressed {
            fnPressed = true
            if isEnabled {
                DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
                return nil
            }
        } else if !fnDown && fnPressed {
            fnPressed = false
            if isEnabled {
                DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
