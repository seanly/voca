import AppKit

/// Detects the frontmost application for context-aware prompt selection.
enum AppContextDetector {
    /// Returns the bundle identifier of the frontmost application.
    static func frontmostAppBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Returns the localized name of the frontmost application.
    static func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
