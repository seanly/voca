import AppKit

/// Captures the focused application and UI element at a point in time,
/// so text can be injected back into it even if the user switches away.
struct FocusSnapshot {
    let app: NSRunningApplication
    let element: AXUIElement
    let axApp: AXUIElement

    static func captureCurrentFocus() -> FocusSnapshot? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppRef
        ) == .success else { return nil }
        let axApp = focusedAppRef as! AXUIElement

        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success else { return nil }
        let element = focusedElementRef as! AXUIElement

        return FocusSnapshot(app: frontApp, element: element, axApp: axApp)
    }

    func isValid() -> Bool {
        var roleRef: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
    }

    var isAppRunning: Bool { !app.isTerminated }
    var isAppFrontmost: Bool { app.isActive }
}
