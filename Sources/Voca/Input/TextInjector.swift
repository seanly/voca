import AppKit
import Carbon

/// TextInjector with dual strategy:
/// 1. Primary: Accessibility API (AXUIElement) to insert text directly
/// 2. Fallback: Clipboard-based paste (original v1 approach)
///
/// Supports injecting into a previously-snapshotted focus target,
/// restoring the original app to the foreground if the user switched away.
final class TextInjector {
    private var savedChangeCount: Int = 0

    func inject(_ text: String, restoringFocus snapshot: FocusSnapshot? = nil) {
        guard !text.isEmpty else { return }

        if let snapshot, snapshot.isAppRunning {
            injectWithSnapshot(text, snapshot: snapshot)
            return
        }

        if injectViaAccessibility(text) { return }
        injectViaClipboard(text)
    }

    // MARK: - Snapshot-Aware Injection

    private func injectWithSnapshot(_ text: String, snapshot: FocusSnapshot) {
        if snapshot.isValid(), injectIntoElement(text, element: snapshot.element) {
            return
        }

        if !snapshot.isAppFrontmost {
            activateAndInject(text, snapshot: snapshot)
        } else {
            if injectViaAccessibility(text) { return }
            injectViaClipboard(text)
        }
    }

    private func activateAndInject(_ text: String, snapshot: FocusSnapshot) {
        snapshot.app.activate()

        pollForActivation(snapshot: snapshot, attempts: 0, maxAttempts: 10) { [weak self] activated in
            guard let self else { return }
            if activated {
                if snapshot.isValid(), self.injectIntoElement(text, element: snapshot.element) {
                    return
                }
                if self.injectViaAccessibility(text) { return }
                self.injectViaClipboard(text)
            } else {
                if self.injectViaAccessibility(text) { return }
                self.injectViaClipboard(text)
            }
        }
    }

    private func pollForActivation(
        snapshot: FocusSnapshot,
        attempts: Int,
        maxAttempts: Int,
        completion: @escaping (Bool) -> Void
    ) {
        if snapshot.isAppFrontmost {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                completion(true)
            }
            return
        }
        if attempts >= maxAttempts {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pollForActivation(
                snapshot: snapshot,
                attempts: attempts + 1,
                maxAttempts: maxAttempts,
                completion: completion
            )
        }
    }

    // MARK: - Element-Level Injection

    private func injectIntoElement(_ text: String, element: AXUIElement) -> Bool {
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange)

        if rangeResult == .success {
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if result == .success {
                return true
            }
        }

        var currentValue: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)
        if valueResult == .success, let current = currentValue as? String {
            let newValue = current + text
            let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef)
            if setResult == .success {
                return true
            }
        }

        return false
    }

    // MARK: - Accessibility API Injection

    private func injectViaAccessibility(_ text: String) -> Bool {
        guard let focused = getFocusedElement() else { return false }
        return injectIntoElement(text, element: focused)
    }

    private func getFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return nil
        }
        let app = focusedApp as! AXUIElement
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }
        return (focusedElement as! AXUIElement)
    }

    // MARK: - Clipboard-Based Injection (fallback)

    private func injectViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedText = pasteboard.string(forType: .string)
        savedChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Switch to ASCII-capable input source if needed
        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needSwitch = !isASCIICapable(originalSource)

        if needSwitch, let asciiSource = findASCIICapableSource() {
            TISSelectInputSource(asciiSource)
            usleep(50_000)
        }

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 0x09
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        // Restore input source
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if needSwitch { TISSelectInputSource(originalSource) }
        }

        // Restore clipboard
        let expectedCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pasteboard.changeCount == expectedCount else { return }
            pasteboard.clearContents()
            if let saved = savedText { pasteboard.setString(saved, forType: .string) }
        }
    }

    // MARK: - Input Source Helpers

    private func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    private func findASCIICapableSource() -> TISInputSource? {
        let criteria = [kTISPropertyInputSourceIsASCIICapable: true, kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard let sourceList = TISCreateInputSourceList(criteria, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        for source in sourceList {
            if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                if id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US" { return source }
            }
        }
        return sourceList.first
    }
}
