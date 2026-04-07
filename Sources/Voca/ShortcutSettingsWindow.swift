import AppKit

final class ShortcutSettingsWindow: NSPanel {
    var onShortcutChanged: ((HotkeyShortcut?) -> Void)?

    private let shortcutLabel = NSTextField(labelWithString: "")
    private let recordButton = NSButton()
    private let clearButton = NSButton()
    private var isRecording = false
    private var localMonitor: Any?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Trigger Shortcut"
        isReleasedWhenClosed = false
        setupUI()
        refreshDisplay()
        center()
    }

    private func setupUI() {
        guard let cv = contentView else { return }

        let descLabel = NSTextField(wrappingLabelWithString:
            "Set a custom keyboard shortcut to trigger voice input.\nLeave empty to use the Fn key (default).")
        descLabel.isSelectable = false
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        let triggerLabel = NSTextField(labelWithString: "Current:")
        triggerLabel.alignment = .right
        triggerLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        recordButton.title = "Record Shortcut"
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.translatesAutoresizingMaskIntoConstraints = false

        clearButton.title = "Use Fn Key"
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [recordButton, clearButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let currentRow = NSStackView(views: [triggerLabel, shortcutLabel])
        currentRow.orientation = .horizontal
        currentRow.spacing = 8
        currentRow.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(descLabel)
        cv.addSubview(currentRow)
        cv.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            descLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            currentRow.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 16),
            currentRow.centerXAnchor.constraint(equalTo: cv.centerXAnchor),

            buttonRow.topAnchor.constraint(equalTo: currentRow.bottomAnchor, constant: 16),
            buttonRow.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
        ])
    }

    private func refreshDisplay() {
        if let shortcut = HotkeyShortcut.load() {
            shortcutLabel.stringValue = shortcut.displayString
        } else {
            shortcutLabel.stringValue = "Fn (default)"
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        recordButton.title = "Press keys..."
        shortcutLabel.stringValue = "Waiting..."

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleRecordedKey(event)
            return nil // swallow the event
        }
    }

    private func stopRecording() {
        isRecording = false
        recordButton.title = "Record Shortcut"
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleRecordedKey(_ event: NSEvent) {
        // Require at least one modifier
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !mods.isEmpty else {
            shortcutLabel.stringValue = "Need modifier key!"
            return
        }

        let shortcut = HotkeyShortcut(
            keyCode: event.keyCode,
            modifiers: mods.rawValue
        )
        shortcut.save()
        stopRecording()
        refreshDisplay()
        onShortcutChanged?(shortcut)
    }

    @objc private func clearShortcut() {
        stopRecording()
        HotkeyShortcut.clear()
        refreshDisplay()
        onShortcutChanged?(nil)
    }

    override func close() {
        stopRecording()
        super.close()
    }
}
