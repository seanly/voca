import AppKit

/// Manages the status bar menu item, connection indicator, and menu actions.
final class StatusBarController {
    private var statusItem: NSStatusItem!
    private var enableMenuItem: NSMenuItem!
    private var serverStatusItem: NSMenuItem!
    private var languageItems: [NSMenuItem] = []

    var onToggleEnabled: (() -> Void)?
    var onChangeLanguage: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onQuit: (() -> Void)?

    private(set) var isEnabled = true

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(recording: false)

        let menu = NSMenu()

        // Enabled toggle
        enableMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enableMenuItem.target = self
        enableMenuItem.state = .on
        menu.addItem(enableMenuItem)
        menu.addItem(.separator())

        // Language submenu
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let languages: [(String, String)] = [
            ("System Default", ""),
            ("English (US)", "en-US"),
            ("中文 (简体)", "zh-CN"),
            ("中文 (繁體)", "zh-TW"),
            ("日本語", "ja-JP"),
            ("한국어", "ko-KR"),
        ]
        for (name, code) in languages {
            let item = NSMenuItem(title: name, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = code == Settings.shared.selectedLocaleCode ? .on : .off
            languageItems.append(item)
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())

        // Server status
        serverStatusItem = NSMenuItem(title: "Server: Not configured", action: nil, keyEquivalent: "")
        serverStatusItem.isEnabled = false
        menu.addItem(serverStatusItem)
        updateServerStatus(ConnectionManager.shared.state)

        menu.addItem(.separator())

        // History
        let historyItem = NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: "H")
        historyItem.keyEquivalentModifierMask = [.command, .shift]
        historyItem.target = self
        menu.addItem(historyItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - State Updates

    func updateIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        let name = recording ? "mic.fill" : "mic"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Voca")

        if recording {
            button.contentTintColor = .systemRed
        } else {
            // Color based on connection state
            switch ConnectionManager.shared.state {
            case .online:
                button.contentTintColor = .systemGreen
            case .offline:
                button.contentTintColor = .systemYellow
            case .connecting:
                button.contentTintColor = .systemOrange
            case .localOnly:
                button.contentTintColor = nil
            }
        }
    }

    func updateServerStatus(_ state: ConnectionState) {
        switch state {
        case .localOnly:
            serverStatusItem?.title = "Server: Not configured"
        case .connecting:
            serverStatusItem?.title = "Server: Connecting..."
        case .online:
            serverStatusItem?.title = "Server: Online"
        case .offline:
            serverStatusItem?.title = "Server: Offline (local mode)"
        }
        updateIcon(recording: false)
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        enableMenuItem.state = isEnabled ? .on : .off
        onToggleEnabled?()
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Settings.shared.selectedLocaleCode = code
        for item in languageItems {
            item.state = (item.representedObject as? String) == code ? .on : .off
        }
        onChangeLanguage?(code)
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openHistory() { onOpenHistory?() }
    @objc private func quit() { onQuit?() }
}
