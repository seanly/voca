import AppKit
import Speech

/// Slim AppDelegate that wires all components together.
/// All logic is delegated to focused services.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let keyMonitor = KeyMonitor()
    private let audioService = AudioCaptureService()
    private let textInjector = TextInjector()
    private lazy var overlayPanel = OverlayPanel()
    private let statusBar = StatusBarController()
    private lazy var mainWindowController = SettingsWindowController()

    private var isRecording = false
    private var isFinishing = false
    private var lastPartialResult = ""
    private var finalResultTimer: Timer?
    private var recordingAppContext: String?  // Bundle ID of app where recording started
    private var recordingFocusSnapshot: FocusSnapshot?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyMonitor.shared = keyMonitor
        setupMainMenu()

        let locale = Settings.shared.selectedLocaleCode
        if !locale.isEmpty {
            audioService.locale = Locale(identifier: locale)
        }

        setupStatusBar()
        setupAudioCallbacks()
        setupOverlayCallbacks()
        setupConnectionMonitor()

        // Load saved custom shortcut
        if let savedShortcut = HotkeyShortcut.load() {
            keyMonitor.customHotkey = savedShortcut
        }

        AudioCaptureService.requestPermissions { [weak self] granted, errorMsg in
            if !granted, let msg = errorMsg { self?.showAlert(title: "Permission Required", message: msg) }
        }

        if !keyMonitor.start() { showAccessibilityAlert() }

        keyMonitor.onFnDown = { [weak self] in self?.fnDown() }
        keyMonitor.onFnUp = { [weak self] in self?.fnUp() }
        keyMonitor.onEscDown = { [weak self] in self?.escDown() }

        // Initial server health check
        ConnectionManager.shared.updateState()
    }

    // MARK: - Key Events

    private func fnDown() {
        guard statusBar.isEnabled, !isRecording else { return }
        isRecording = true
        keyMonitor.isSessionActive = true
        lastPartialResult = ""
        recordingAppContext = AppContextDetector.frontmostAppBundleId()
        recordingFocusSnapshot = FocusSnapshot.captureCurrentFocus()

        statusBar.updateIcon(recording: true)
        overlayPanel.showRecording()
        NSSound(named: .init("Tink"))?.play()

        // Choose recording mode based on connection state
        if ConnectionManager.shared.shouldUseServer {
            audioService.startServerRecording()
        } else {
            audioService.startLocalRecording()
        }
    }

    private func fnUp() {
        guard isRecording else { return }
        isRecording = false
        statusBar.updateIcon(recording: false)
        audioService.stopRecording()

        // For local mode, set a fallback timer
        if !ConnectionManager.shared.shouldUseServer {
            finalResultTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.finishTranscription()
            }
        }
    }

    private func escDown() {
        overlayPanel.dismiss()
        lastPartialResult = ""
        finalResultTimer?.invalidate()
        finalResultTimer = nil
        keyMonitor.isSessionActive = false
        keyMonitor.resetToggle()
        isFinishing = false
        recordingFocusSnapshot = nil
        if isRecording {
            isRecording = false
            statusBar.updateIcon(recording: false)
            audioService.cancel()
        }
    }

    // MARK: - Audio Callbacks

    private func setupAudioCallbacks() {
        audioService.onPartialResult = { [weak self] text in
            guard let self else { return }
            self.lastPartialResult = text
            self.overlayPanel.updatePartialText(text)
        }

        audioService.onFinalResult = { [weak self] text in
            guard let self else { return }
            self.lastPartialResult = text
            self.finalResultTimer?.invalidate()
            self.finalResultTimer = nil
            self.finishTranscription()
        }

        audioService.onError = { [weak self] msg in
            guard let self else { return }
            self.overlayPanel.updatePartialText("Error: \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.overlayPanel.dismiss() }
        }

        audioService.onAudioLevel = { [weak self] level in
            self?.overlayPanel.updateAudioLevel(level)
        }

        audioService.onLocaleUnavailable = { [weak self] msg in
            self?.showAlert(title: "Language Unavailable", message: msg)
        }

        // Server mode: audio captured, send to server
        audioService.onAudioCaptured = { [weak self] wavData in
            self?.sendToServer(audioData: wavData)
        }
    }

    // MARK: - Server Mode Transcription

    private func sendToServer(audioData: Data) {
        overlayPanel.showRefining()

        let settings = Settings.shared
        let client = VocaClient(baseURL: settings.serverURL, authToken: settings.serverAuthToken)

        client.transcribe(
            audio: audioData,
            format: "wav",
            language: settings.selectedLocaleCode,
            appContext: recordingAppContext
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let response):
                    if response.text.isEmpty {
                        self.overlayPanel.dismiss()
                    } else {
                        self.handleResult(raw: response.raw, refined: response.text, wasRefined: response.refined)
                    }
                case .failure(let error):
                    NSLog("[Voca] Server transcription failed: %@, falling back to local", error.localizedDescription)
                    // Fallback: if we have partial results from local, use those
                    if !self.lastPartialResult.isEmpty {
                        self.finishTranscription()
                    } else {
                        self.overlayPanel.updatePartialText("Server error, no local result")
                        self.overlayPanel.showError()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.overlayPanel.dismiss() }
                    }
                }
                self.keyMonitor.isSessionActive = false
            }
        }
    }

    // MARK: - Local Mode Transcription

    private func finishTranscription() {
        guard !isFinishing else { return }
        isFinishing = true
        finalResultTimer?.invalidate()
        finalResultTimer = nil

        let text = lastPartialResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            overlayPanel.dismiss()
            lastPartialResult = ""
            isFinishing = false
            keyMonitor.isSessionActive = false
            return
        }

        // Try server refinement if online
        if ConnectionManager.shared.shouldUseServer {
            overlayPanel.showRefining()
            let settings = Settings.shared
            let client = VocaClient(baseURL: settings.serverURL, authToken: settings.serverAuthToken)
            client.refineText(
                text: text,
                language: settings.selectedLocaleCode,
                appContext: recordingAppContext
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let response):
                        self.handleResult(raw: text, refined: response.text, wasRefined: response.refined)
                    case .failure:
                        // Server refinement failed, use raw text
                        self.handleResult(raw: text, refined: text, wasRefined: false)
                    }
                }
            }
            return
        }

        // Pure local mode: no refinement, use raw Apple Speech result
        handleResult(raw: text, refined: text, wasRefined: false)
    }

    // MARK: - Result Handling

    private func handleResult(raw: String, refined: String, wasRefined: Bool) {
        let unknownWords: [String]
        if Settings.shared.appleDictionaryValidationEnabled {
            unknownWords = DictionaryValidator.shared.validateEnglishWords(in: refined)
        } else {
            unknownWords = []
        }

        overlayPanel.showResult(raw: raw, refined: refined, wasRefined: wasRefined, unknownWords: unknownWords)

        // Store in local history
        HistoryStore.shared.add(
            raw: raw,
            refined: refined,
            language: Settings.shared.selectedLocaleCode,
            appContext: recordingAppContext ?? "",
            wasRefined: wasRefined
        )

        isFinishing = false
    }

    private func injectTextAndCleanup(_ text: String) {
        let snapshot = recordingFocusSnapshot
        overlayPanel.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.textInjector.inject(text, restoringFocus: snapshot)
            NSSound(named: .init("Pop"))?.play()
        }
        lastPartialResult = ""
        isFinishing = false
        keyMonitor.isSessionActive = false
        keyMonitor.resetToggle()
        recordingFocusSnapshot = nil
    }

    // MARK: - Overlay Callbacks

    private func setupOverlayCallbacks() {
        overlayPanel.onAutoInject = { [weak self] text in
            self?.injectTextAndCleanup(text)
        }
    }

    // MARK: - Connection Monitor

    private func setupConnectionMonitor() {
        ConnectionManager.shared.onStateChanged = { [weak self] state in
            self?.statusBar.updateServerStatus(state)
        }
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusBar.setup()

        statusBar.onToggleEnabled = { [weak self] in
            guard let self else { return }
            if !self.statusBar.isEnabled && self.isRecording {
                self.audioService.cancel()
                self.overlayPanel.dismiss()
                self.isRecording = false
                self.keyMonitor.isSessionActive = false
                self.statusBar.updateIcon(recording: false)
            }
            self.keyMonitor.isEnabled = self.statusBar.isEnabled
        }

        statusBar.onChangeLanguage = { [weak self] code in
            self?.audioService.locale = code.isEmpty ? .current : Locale(identifier: code)
        }

        statusBar.onOpenSettings = { [weak self] in
            self?.mainWindowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        statusBar.onOpenHistory = { [weak self] in
            self?.mainWindowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        statusBar.onQuit = { [weak self] in
            self?.keyMonitor.stop()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll), keyEquivalent: "a"))
        mainMenu.addItem(editMenuItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Alerts

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            Voca needs Accessibility permission to monitor the Fn key.

            1. Open System Settings → Privacy & Security → Accessibility
            2. Add and enable Voca
            3. Restart the app
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
