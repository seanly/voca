import AppKit

final class SettingsWindow: NSPanel {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var models: [LLMModel] = []
    private var onModelsChanged: (() -> Void)?
    
    // MARK: - Lifecycle
    
    init(onModelsChanged: (() -> Void)? = nil) {
        self.onModelsChanged = onModelsChanged
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Manage LLM Models"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 480, height: 300)
        setupUI()
        loadModels()
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
        
        // Add columns
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 150
        tableView.addTableColumn(nameColumn)
        
        let modelColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        modelColumn.title = "Model"
        modelColumn.width = 180
        tableView.addTableColumn(modelColumn)
        
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.title = "Status"
        statusColumn.width = 80
        tableView.addTableColumn(statusColumn)
        
        // Scroll view
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        // Buttons
        let addButton = NSButton(title: "+", target: self, action: #selector(addModel))
        addButton.bezelStyle = .rounded
        
        let editButton = NSButton(title: "Edit", target: self, action: #selector(editModel))
        editButton.bezelStyle = .rounded
        
        let deleteButton = NSButton(title: "-", target: self, action: #selector(deleteModel))
        deleteButton.bezelStyle = .rounded
        
        let testButton = NSButton(title: "Test Selected", target: self, action: #selector(testSelected))
        testButton.bezelStyle = .rounded
        
        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.keyEquivalent = "\r"
        closeButton.bezelStyle = .rounded
        
        // Button stacks
        let leftButtons = NSStackView(views: [addButton, editButton, deleteButton])
        leftButtons.orientation = .horizontal
        leftButtons.spacing = 8
        
        let rightButtons = NSStackView(views: [testButton, closeButton])
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
    
    private func loadModels() {
        models = LLMRefiner.shared.models
        tableView.reloadData()
    }
    
    // MARK: - Actions
    
    @objc private func addModel() {
        let editor = ModelEditorWindow(mode: .add) { [weak self] model in
            LLMRefiner.shared.addModel(model)
            self?.loadModels()
            self?.onModelsChanged?()
        }
        editor.makeKeyAndOrderFront(nil)
    }
    
    @objc private func editModel() {
        let row = tableView.selectedRow
        guard row >= 0, row < models.count else { return }
        
        let editor = ModelEditorWindow(mode: .edit(models[row].id), editingModel: models[row]) { [weak self] model in
            LLMRefiner.shared.updateModel(model)
            self?.loadModels()
            self?.onModelsChanged?()
        }
        editor.makeKeyAndOrderFront(nil)
    }
    
    @objc private func deleteModel() {
        let row = tableView.selectedRow
        guard row >= 0, row < models.count else { return }
        
        let alert = NSAlert()
        alert.messageText = "Delete \"\(models[row].name)\"?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            LLMRefiner.shared.removeModel(id: models[row].id)
            loadModels()
            onModelsChanged?()
        }
    }
    
    @objc private func testSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < models.count else {
            showAlert(message: "Please select a model to test")
            return
        }
        
        let model = models[row]
        guard model.isConfigured else {
            showAlert(message: "API key is not configured for this model")
            return
        }
        
        // Temporarily select this model and test
        let previousId = LLMRefiner.shared.selectedModelId
        LLMRefiner.shared.selectModel(id: model.id)
        
        let alert = NSAlert()
        alert.messageText = "Testing \(model.name)..."
        alert.informativeText = "Sending test request..."
        alert.addButton(withTitle: "Cancel")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            LLMRefiner.shared.refine("Hello, this is a test.", force: true) { result in
                alert.buttons.first?.performClick(nil)
                
                switch result {
                case .success(let text):
                    self.showAlert(message: "✅ Success: \"\(text)\"", style: .informational)
                case .failure(let error):
                    self.showAlert(message: "❌ Failed: \(error.localizedDescription)", style: .critical)
                }
                
                // Restore previous selection
                if let previousId = previousId {
                    LLMRefiner.shared.selectModel(id: previousId)
                }
            }
        }
    }
    
    private func showAlert(message: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension SettingsWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return models.count
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let model = models[row]
        
        switch tableColumn?.identifier.rawValue {
        case "name":
            return model.name
        case "model":
            return model.model
        case "status":
            let isSelected = LLMRefiner.shared.selectedModelId == model.id
            let parts = [model.isEnabled ? "Enabled" : "Disabled", isSelected ? "Selected" : nil]
            return parts.compactMap { $0 }.joined(separator: ", ")
        default:
            return nil
        }
    }
}

// MARK: - Model Editor Window

final class ModelEditorWindow: NSPanel {
    enum EditorMode: Equatable {
        case add
        case edit(UUID)  // Store just the ID for Equatable
        
        static func == (lhs: EditorMode, rhs: EditorMode) -> Bool {
            switch (lhs, rhs) {
            case (.add, .add): return true
            case (.edit(let a), .edit(let b)): return a == b
            default: return false
            }
        }
    }
    
    private let mode: EditorMode
    private let editingModel: LLMModel?
    private let onSave: (LLMModel) -> Void
    
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let keyField: NSTextField = {
        let field = NSTextField()
        // Use secure text field cell for API key
        let cell = NSSecureTextFieldCell(textCell: "")
        cell.echosBullets = true
        field.cell = cell
        return field
    }()
    private let modelField = NSTextField()
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let presetPopup = NSPopUpButton()
    
    init(mode: EditorMode, editingModel: LLMModel? = nil, onSave: @escaping (LLMModel) -> Void) {
        self.mode = mode
        self.editingModel = editingModel
        self.onSave = onSave
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = mode == EditorMode.add ? "Add Model" : "Edit Model"
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
            LLMModel.presets.forEach { preset in
                presetPopup.addItem(withTitle: "\(preset.name) (\(preset.model))")
            }
            presetPopup.target = self
            presetPopup.action = #selector(presetChanged)
        }
        
        // Form fields
        nameField.placeholderString = "My OpenAI"
        urlField.placeholderString = "https://api.openai.com/v1"
        keyField.placeholderString = "sk-..."
        modelField.placeholderString = "gpt-4o-mini"
        
        // Labels
        let labels = ["Preset:", "Name:", "API Base URL:", "API Key:", "Model:"].map { text -> NSTextField in
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        
        // Build grid
        var rows: [[NSView]] = []
        if mode == EditorMode.add {
            rows.append([labels[0], presetPopup])
        }
        rows.append(contentsOf: [
            [labels[1], nameField],
            [labels[2], urlField],
            [labels[3], keyField],
            [labels[4], modelField]
        ])
        
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
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
            
            enabledCheckbox.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            enabledCheckbox.leadingAnchor.constraint(equalTo: grid.leadingAnchor, constant: 80),
            
            buttonRow.topAnchor.constraint(equalTo: enabledCheckbox.bottomAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20)
        ])
        
        urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    }
    
    private func loadData() {
        if let model = editingModel {
            nameField.stringValue = model.name
            urlField.stringValue = model.apiBaseURL
            keyField.stringValue = model.apiKey
            modelField.stringValue = model.model
            enabledCheckbox.state = model.isEnabled ? .on : .off
        }
    }
    
    @objc private func presetChanged() {
        let index = presetPopup.indexOfSelectedItem
        guard index > 1 else { return } // "Custom..." or separator
        
        let preset = LLMModel.presets[index - 2]
        nameField.stringValue = preset.name
        urlField.stringValue = preset.apiBaseURL
        modelField.stringValue = preset.model
    }
    
    @objc private func save() {
        let model: LLMModel
        
        switch mode {
        case .add:
            model = LLMModel(
                name: nameField.stringValue,
                apiBaseURL: urlField.stringValue,
                apiKey: keyField.stringValue,
                model: modelField.stringValue,
                isEnabled: enabledCheckbox.state == .on
            )
        case .edit:
            guard let existing = editingModel else { return }
            model = LLMModel(
                id: existing.id,
                name: nameField.stringValue,
                apiBaseURL: urlField.stringValue,
                apiKey: keyField.stringValue,
                model: modelField.stringValue,
                isEnabled: enabledCheckbox.state == .on
            )
        }
        
        onSave(model)
        close()
    }
}
