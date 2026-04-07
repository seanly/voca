import Cocoa

final class KeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    var onEscDown: (() -> Void)?

    /// Controls whether the monitor should intercept keys
    var isEnabled = true
    /// Controls whether we're in an active session (recording or refining) where ESC should be intercepted
    var isSessionActive = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnPressed = false

    /// ESC key code (0x35 = 53)
    private let escKeyCode: CGKeyCode = 0x35

    /// Start monitoring. Returns false if accessibility permission is missing.
    func start() -> Bool {
        let mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue))
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

        // Handle keyDown events (ESC key) — only suppress when session is active
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Int64(escKeyCode) && isSessionActive {
                DispatchQueue.main.async { [weak self] in self?.onEscDown?() }
                return nil // suppress ESC only during active session
            }
            return Unmanaged.passUnretained(event)
        }

        // Handle flagsChanged events (Fn key) — only suppress when enabled
        let flags = event.flags
        let fnDown = flags.contains(.maskSecondaryFn)

        if fnDown && !fnPressed {
            fnPressed = true
            if isEnabled {
                DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
                return nil // suppress Fn press (prevents emoji picker)
            }
        } else if !fnDown && fnPressed {
            fnPressed = false
            if isEnabled {
                DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
                return nil // suppress Fn release
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
