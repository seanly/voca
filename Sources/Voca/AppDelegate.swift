import AppKit
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor()
    private let speechEngine = SpeechEngine()
    private let textInjector = TextInjector()
    private lazy var overlayPanel = OverlayPanel()

    private var isEnabled = true
    private var isRecording = false
    private var isFinishing = false
    private var lastPartialResult = ""
    private var finalResultTimer: Timer?

    private var enableMenuItem: NSMenuItem!
    private var llmItem: NSMenuItem!
    private var llmModelItems: [NSMenuItem] = []
    private var promptItems: [NSMenuItem] = []
    private var promptMenuItem: NSMenuItem!
    private lazy var settingsWindow = SettingsWindow(onModelsChanged: { [weak self] in
        self?.refreshLLMModelMenu()
    })
    private lazy var promptWindow = PromptWindow(onPromptsChanged: { [weak self] in
        self?.refreshPromptMenu()
    })
    private var languageItems: [NSMenuItem] = []
    private var selectedLocaleCode: String {
        get { UserDefaults.standard.string(forKey: "selectedLocaleCode") ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLocaleCode") }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedCode = selectedLocaleCode
        if !savedCode.isEmpty {
            speechEngine.locale = Locale(identifier: savedCode)
        }

        setupMainMenu()
        setupStatusBar()
        setupSpeechCallbacks()

        SpeechEngine.requestPermissions { [weak self] granted, errorMsg in
            if !granted, let msg = errorMsg {
                self?.showAlert(title: "Permission Required", message: msg)
            }
        }

        if !keyMonitor.start() {
            showAccessibilityAlert()
        }

        keyMonitor.onFnDown = { [weak self] in self?.fnDown() }
        keyMonitor.onFnUp = { [weak self] in self?.fnUp() }
        keyMonitor.onEscDown = { [weak self] in self?.escDown() }
    }

    // MARK: - Key events

    private func fnDown() {
        guard isEnabled, !isRecording else { return }
        LLMRefiner.shared.cancel()
        isRecording = true
        keyMonitor.isSessionActive = true
        lastPartialResult = ""

        updateStatusIcon(recording: true)
        overlayPanel.show(text: "Listening...")
        NSSound(named: .init("Tink"))?.play()

        speechEngine.startRecording()
    }

    private func fnUp() {
        guard isRecording else { return }
        isRecording = false

        updateStatusIcon(recording: false)
        speechEngine.stopRecording()

        finalResultTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.finishTranscription()
        }
    }

    private func escDown() {
        // Cancel LLM refinement if in progress
        LLMRefiner.shared.cancel()

        // Dismiss overlay panel
        overlayPanel.dismiss()

        // Reset state
        lastPartialResult = ""
        finalResultTimer?.invalidate()
        finalResultTimer = nil
        keyMonitor.isSessionActive = false
        isFinishing = false

        // If was recording, stop it
        if isRecording {
            isRecording = false
            updateStatusIcon(recording: false)
            speechEngine.cancel()
        }
    }

    // MARK: - Speech callbacks

    private func setupSpeechCallbacks() {
        speechEngine.onPartialResult = { [weak self] text in
            guard let self else { return }
            self.lastPartialResult = text
            self.overlayPanel.updateText(text)
        }

        speechEngine.onFinalResult = { [weak self] text in
            guard let self else { return }
            self.lastPartialResult = text
            self.finalResultTimer?.invalidate()
            self.finalResultTimer = nil
            self.finishTranscription()
        }

        speechEngine.onError = { [weak self] msg in
            guard let self else { return }
            self.overlayPanel.updateText("Error: \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.overlayPanel.dismiss()
            }
        }

        speechEngine.onAudioLevel = { [weak self] level in
            self?.overlayPanel.updateAudioLevel(level)
        }

        speechEngine.onLocaleUnavailable = { [weak self] msg in
            self?.showAlert(title: "Language Unavailable", message: msg)
        }
    }

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

        let refiner = LLMRefiner.shared
        if let model = refiner.currentModel, model.isConfigured {
            overlayPanel.showRefining()
            refiner.refine(text) { [weak self] result in
                guard let self else { return }
                let finalText: String
                switch result {
                case .success(let refined):
                    finalText = refined.isEmpty ? text : refined
                    self.handleFinalText(finalText, wasRefined: finalText != text)
                case .failure(let error):
                    NSLog("[LLMRefiner] Refine failed: %@", error.localizedDescription)
                    finalText = text
                    self.handleFinalText(finalText, wasRefined: false, error: error.localizedDescription)
                }
            }
        } else {
            handleFinalText(text, wasRefined: false)
        }
    }
    
    private func handleFinalText(_ text: String, wasRefined: Bool, error: String? = nil) {
        if error != nil {
            // Show raw text with red border to indicate error
            overlayPanel.updateText(text)
            overlayPanel.showError()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.injectTextAndCleanup(text)
            }
        } else if wasRefined {
            // Show refined text briefly with sparkle
            overlayPanel.updateText("✨ \(text)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.injectTextAndCleanup(text)
            }
        } else {
            // Inject immediately
            overlayPanel.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.injectTextAndCleanup(text)
            }
        }
    }
    
    private func injectTextAndCleanup(_ text: String) {
        overlayPanel.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.textInjector.inject(text)
            NSSound(named: .init("Pop"))?.play()
        }
        lastPartialResult = ""
        isFinishing = false
        keyMonitor.isSessionActive = false
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        // Setup minimal main menu with Edit menu to support copy/paste in text fields
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll), keyEquivalent: "a"))

        mainMenu.addItem(editMenuItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(recording: false)

        let menu = NSMenu()

        enableMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enableMenuItem.target = self
        enableMenuItem.state = .on
        menu.addItem(enableMenuItem)

        menu.addItem(.separator())

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
            item.state = code == selectedLocaleCode ? .on : .off
            languageItems.append(item)
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // Prompt - direct prompt list
        promptMenuItem = NSMenuItem(title: "Prompt", action: nil, keyEquivalent: "")
        let promptMenu = NSMenu()
        refreshPromptMenu(in: promptMenu)
        promptMenuItem.submenu = promptMenu
        menu.addItem(promptMenuItem)

        // LLM Refinement - direct model list
        llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()
        refreshLLMModelMenu(in: llmMenu)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        menu.addItem(.separator())

        // Settings submenu
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        
        let modelSettingsItem = NSMenuItem(title: "Manage Models...", action: #selector(openLLMSettings), keyEquivalent: ",")
        modelSettingsItem.target = self
        settingsMenu.addItem(modelSettingsItem)
        
        let promptSettingsItem = NSMenuItem(title: "Manage Prompts...", action: #selector(openPromptSettings), keyEquivalent: "")
        promptSettingsItem.target = self
        settingsMenu.addItem(promptSettingsItem)
        
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        let name = recording ? "mic.fill" : "mic"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Voca")
        button.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        enableMenuItem.state = isEnabled ? .on : .off
        keyMonitor.isEnabled = isEnabled

        if !isEnabled {
            if isRecording {
                speechEngine.cancel()
                overlayPanel.dismiss()
                isRecording = false
                keyMonitor.isSessionActive = false
                updateStatusIcon(recording: false)
            }
        }
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        selectedLocaleCode = code
        speechEngine.locale = code.isEmpty ? .current : Locale(identifier: code)

        for item in languageItems {
            item.state = (item.representedObject as? String) == code ? .on : .off
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? UUID else { return }
        let refiner = LLMRefiner.shared
        // Toggle: if already selected, deselect (disable); otherwise select
        if refiner.selectedModelId == modelId {
            refiner.selectedModelId = nil
        } else {
            refiner.selectModel(id: modelId)
        }
        refreshLLMModelMenu()
    }
    
    private func refreshLLMModelMenu(in menu: NSMenu? = nil) {
        let targetMenu = menu ?? llmItem?.submenu
        targetMenu?.removeAllItems()
        llmModelItems.removeAll()
        
        let refiner = LLMRefiner.shared
        let models = refiner.models
        let selectedId = refiner.selectedModelId
        
        // Add model items
        for model in models where model.isEnabled {
            let item = NSMenuItem(
                title: model.name.isEmpty ? "Unnamed" : model.name,
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model.id
            item.state = (model.id == selectedId) ? .on : .off
            item.toolTip = "\(model.model) @ \(model.apiBaseURL)"
            llmModelItems.append(item)
            targetMenu?.addItem(item)
        }
        
        // Show placeholder if no models
        if llmModelItems.isEmpty {
            let item = NSMenuItem(title: "No models configured", action: nil, keyEquivalent: "")
            item.isEnabled = false
            targetMenu?.addItem(item)
        }
    }
    
    @objc private func selectPrompt(_ sender: NSMenuItem) {
        guard let promptId = sender.representedObject as? UUID else { return }
        let refiner = LLMRefiner.shared
        // Toggle: if already selected, deselect; otherwise select
        if refiner.selectedPromptId == promptId {
            refiner.selectedPromptId = nil
        } else {
            refiner.selectPrompt(id: promptId)
        }
        refreshPromptMenu()
    }
    
    private func refreshPromptMenu(in menu: NSMenu? = nil) {
        let targetMenu = menu ?? promptMenuItem?.submenu
        targetMenu?.removeAllItems()
        promptItems.removeAll()
        
        let refiner = LLMRefiner.shared
        let prompts = refiner.prompts
        let selectedId = refiner.selectedPromptId
        
        // Add prompt items
        for prompt in prompts where prompt.isEnabled {
            let item = NSMenuItem(
                title: prompt.name.isEmpty ? "Unnamed" : prompt.name,
                action: #selector(selectPrompt(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = prompt.id
            item.state = (prompt.id == selectedId) ? .on : .off
            item.toolTip = String(prompt.content.prefix(100)) + (prompt.content.count > 100 ? "..." : "")
            promptItems.append(item)
            targetMenu?.addItem(item)
        }
        
        // Show placeholder if no prompts
        if promptItems.isEmpty {
            let item = NSMenuItem(title: "No prompts available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            targetMenu?.addItem(item)
        }
    }

    @objc private func openLLMSettings() {
        settingsWindow.makeKeyAndOrderFront(nil as AnyObject?)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func openPromptSettings() {
        promptWindow.makeKeyAndOrderFront(nil as AnyObject?)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        keyMonitor.stop()
        NSApp.terminate(nil)
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
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
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
