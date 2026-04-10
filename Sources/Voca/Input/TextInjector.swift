import AppKit
import Carbon

/// TextInjector with dual strategy:
/// 1. Primary: Accessibility API (AXUIElement) to insert text directly
/// 2. Fallback: Clipboard-based paste (original v1 approach)
final class TextInjector {
    private var savedChangeCount: Int = 0

    func inject(_ text: String) {
        guard !text.isEmpty else { return }

        // Try Accessibility API first
        if injectViaAccessibility(text) {
            return
        }

        // Fall back to clipboard paste
        injectViaClipboard(text)
    }

    // MARK: - Accessibility API Injection

    private func injectViaAccessibility(_ text: String) -> Bool {
        guard let focused = getFocusedElement() else { return false }

        // Try to get the existing selected text range and replace it
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &selectedRange)

        if rangeResult == .success {
            // Set selected text (replaces selection, or inserts at cursor if no selection)
            let result = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if result == .success {
                return true
            }
        }

        // Try setting the value directly (works for simple text fields)
        var currentValue: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &currentValue)
        if valueResult == .success, let current = currentValue as? String {
            let newValue = current + text
            let setResult = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, newValue as CFTypeRef)
            if setResult == .success {
                return true
            }
        }

        return false
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
