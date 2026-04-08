import AppKit

final class PromptWindow: NSPanel {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var prompts: [Prompt] = []
    private var onPromptsChanged: (() -> Void)?
    
    // MARK: - Lifecycle
    
    init(onPromptsChanged: (() -> Void)? = nil) {
        self.onPromptsChanged = onPromptsChanged
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Manage Prompts"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 400, height: 280)
        setupUI()
        loadPrompts()
        center()
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        guard let cv = contentView else { return }
        
        // Table view setup
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(editPrompt)
        
        // Add columns
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 200
        tableView.addTableColumn(nameColumn)
        
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.title = "Status"
        statusColumn.width = 120
        tableView.addTableColumn(statusColumn)
        
        // Scroll view
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        // Buttons
        let addButton = NSButton(title: "+", target: self, action: #selector(addPrompt))
        addButton.bezelStyle = .rounded
        
        let editButton = NSButton(title: "Edit", target: self, action: #selector(editPrompt))
        editButton.bezelStyle = .rounded
        
        let deleteButton = NSButton(title: "-", target: self, action: #selector(deletePrompt))
        deleteButton.bezelStyle = .rounded
        
        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.keyEquivalent = "\r"
        closeButton.bezelStyle = .rounded
        
        // Button stacks
        let leftButtons = NSStackView(views: [addButton, editButton, deleteButton])
        leftButtons.orientation = .horizontal
        leftButtons.spacing = 8
        
        let rightButtons = NSStackView(views: [closeButton])
        rightButtons.orientation = .horizontal
        rightButtons.spacing = 8
        
        let buttonRow = NSStackView(views: [leftButtons, NSView(), rightButtons])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        
        // Add to content view
        cv.addSubview(scrollView)
        cv.addSubview(buttonRow)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            
            buttonRow.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 16),
            buttonRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16)
        ])
    }
    
    // MARK: - Data
    
    private func loadPrompts() {
        prompts = LLMRefiner.shared.prompts
        tableView.reloadData()
    }
    
    // MARK: - Actions
    
    @objc private func addPrompt() {
        let editor = PromptEditorWindow(mode: .add) { [weak self] prompt in
            LLMRefiner.shared.addPrompt(prompt)
            self?.loadPrompts()
            self?.onPromptsChanged?()
        }
        editor.makeKeyAndOrderFront(nil)
    }
    
    @objc private func editPrompt() {
        let row = tableView.selectedRow
        guard row >= 0, row < prompts.count else { return }
        
        let editor = PromptEditorWindow(mode: .edit(prompts[row].id), editingPrompt: prompts[row]) { [weak self] prompt in
            LLMRefiner.shared.updatePrompt(prompt)
            self?.loadPrompts()
            self?.onPromptsChanged?()
        }
        editor.makeKeyAndOrderFront(nil)
    }
    
    @objc private func deletePrompt() {
        let row = tableView.selectedRow
        guard row >= 0, row < prompts.count else { return }
        
        let alert = NSAlert()
        alert.messageText = "Delete \"\(prompts[row].name)\"?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            LLMRefiner.shared.removePrompt(id: prompts[row].id)
            loadPrompts()
            onPromptsChanged?()
        }
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension PromptWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return prompts.count
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let prompt = prompts[row]
        
        switch tableColumn?.identifier.rawValue {
        case "name":
            return prompt.name
        case "status":
            let isSelected = LLMRefiner.shared.selectedPromptId == prompt.id
            let parts = [prompt.isEnabled ? "Enabled" : "Disabled", isSelected ? "Selected" : nil]
            return parts.compactMap { $0 }.joined(separator: ", ")
        default:
            return nil
        }
    }
}

// MARK: - Prompt Editor Window

final class PromptEditorWindow: NSPanel {
    enum EditorMode: Equatable {
        case add
        case edit(UUID)
        
        static func == (lhs: EditorMode, rhs: EditorMode) -> Bool {
            switch (lhs, rhs) {
            case (.add, .add): return true
            case (.edit(let a), .edit(let b)): return a == b
            default: return false
            }
        }
    }
    
    private let mode: EditorMode
    private let editingPrompt: Prompt?
    private let onSave: (Prompt) -> Void
    
    private let nameField = NSTextField()
    private var contentTextView: NSTextView!
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let presetPopup = NSPopUpButton()
    
    init(mode: EditorMode, editingPrompt: Prompt? = nil, onSave: @escaping (Prompt) -> Void) {
        self.mode = mode
        self.editingPrompt = editingPrompt
        self.onSave = onSave
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = mode == EditorMode.add ? "Add Prompt" : "Edit Prompt"
        isReleasedWhenClosed = false
        setupUI()
        loadData()
        center()
    }
    
    private func setupUI() {
        guard let cv = contentView else { return }
        
        // Preset selector (only for add mode)
        if mode == EditorMode.add {
            presetPopup.addItem(withTitle: "Custom...")
            presetPopup.menu?.addItem(NSMenuItem.separator())
            Prompt.presets.forEach { preset in
                presetPopup.addItem(withTitle: preset.name)
            }
            presetPopup.target = self
            presetPopup.action = #selector(presetChanged)
        }
        
        // Form fields
        nameField.placeholderString = "My Prompt"
        
        // Content text view setup - create inside scrollview
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        
        contentTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 260, height: 150), textContainer: textContainer)
        contentTextView.font = .systemFont(ofSize: 12)
        contentTextView.isRichText = false
        contentTextView.isEditable = true
        contentTextView.isSelectable = true
        contentTextView.minSize = NSSize(width: 0, height: 100)
        contentTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        contentTextView.autoresizingMask = [.width, .height]
        
        let scrollView = NSScrollView()
        scrollView.documentView = contentTextView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        // Labels
        var labels: [NSTextField] = []
        if mode == EditorMode.add {
            labels.append(NSTextField(labelWithString: "Preset:"))
        }
        labels.append(contentsOf: [
            NSTextField(labelWithString: "Name:"),
            NSTextField(labelWithString: "Content:")
        ])
        labels.forEach { $0.alignment = .right }
        
        // Build grid
        var rows: [[NSView]] = []
        if mode == EditorMode.add {
            rows.append([labels[0], presetPopup])
        }
        rows.append([labels[labels.count - 2], nameField])
        rows.append([labels[labels.count - 1], scrollView])
        
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 0).topPadding = 0
        grid.row(at: rows.count - 1).topPadding = 8
        grid.row(at: rows.count - 1).bottomPadding = 0
        grid.rowSpacing = 12
        grid.columnSpacing = 8
        
        // Enabled checkbox
        enabledCheckbox.state = .on
        enabledCheckbox.translatesAutoresizingMaskIntoConstraints = false
        
        // Buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancelButton.bezelStyle = .rounded
        
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        
        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        
        // Assemble
        cv.addSubview(grid)
        cv.addSubview(enabledCheckbox)
        cv.addSubview(buttonRow)
        
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: cv.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            
            scrollView.heightAnchor.constraint(equalToConstant: 150),
            
            enabledCheckbox.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            enabledCheckbox.leadingAnchor.constraint(equalTo: grid.leadingAnchor, constant: 80),
            
            buttonRow.topAnchor.constraint(equalTo: enabledCheckbox.bottomAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16)
        ])
        
        scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
    }
    
    private func loadData() {
        if let prompt = editingPrompt {
            nameField.stringValue = prompt.name
            contentTextView.string = prompt.content
            enabledCheckbox.state = prompt.isEnabled ? .on : .off
        } else {
            // Default to first preset content
            contentTextView.string = Prompt.presets[0].content
            enabledCheckbox.state = .on
        }
    }
    
    @objc private func presetChanged() {
        let index = presetPopup.indexOfSelectedItem
        guard index > 1 else { return } // "Custom..." or separator
        
        let preset = Prompt.presets[index - 2]
        nameField.stringValue = preset.name
        contentTextView.string = preset.content
    }
    
    @objc private func save() {
        let prompt: Prompt
        
        switch mode {
        case .add:
            prompt = Prompt(
                name: nameField.stringValue,
                content: contentTextView.string,
                isEnabled: enabledCheckbox.state == .on
            )
        case .edit:
            guard let existing = editingPrompt else { return }
            prompt = Prompt(
                id: existing.id,
                name: nameField.stringValue,
                content: contentTextView.string,
                isEnabled: enabledCheckbox.state == .on
            )
        }
        
        onSave(prompt)
        close()
    }
}
