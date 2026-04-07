import AppKit
import Carbon

final class TextInjector {
    /// Tracks the pasteboard change count at the time we overwrote it,
    /// so we only restore if no one else has written to the clipboard since.
    private var savedChangeCount: Int = 0

    func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general

        // Save current clipboard content
        let savedText = pasteboard.string(forType: .string)
        savedChangeCount = pasteboard.changeCount

        // Write transcription to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // If a non-ASCII input source (e.g. Chinese IME) is active, temporarily
        // switch to an ASCII-capable one so the Cmd+V paste is not intercepted.
        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needSwitch = !isASCIICapable(originalSource)

        if needSwitch {
            if let asciiSource = findASCIICapableSource() {
                TISSelectInputSource(asciiSource)
                usleep(50_000) // 50ms for system to settle
            }
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

        // Restore input source after paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if needSwitch {
                TISSelectInputSource(originalSource)
            }
        }

        // Restore original clipboard content only if no one else changed it
        let expectedCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pasteboard.changeCount == expectedCount else { return }
            pasteboard.clearContents()
            if let saved = savedText {
                pasteboard.setString(saved, forType: .string)
            }
        }
    }

    // MARK: - Input Source Helpers

    private func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return false
        }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    private func findASCIICapableSource() -> TISInputSource? {
        let criteria = [kTISPropertyInputSourceIsASCIICapable: true, kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard let sourceList = TISCreateInputSourceList(criteria, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        // Prefer ABC or US keyboard
        for source in sourceList {
            if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                if id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US" {
                    return source
                }
            }
        }
        return sourceList.first
    }
}
