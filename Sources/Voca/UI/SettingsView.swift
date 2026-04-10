import SwiftUI

/// Unified main window with sidebar navigation: Home, Settings, History.
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let hostingController = NSHostingController(rootView: MainView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Voca"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 480))
        window.minSize = NSSize(width: 560, height: 400)
        window.center()
        self.init(window: window)
    }
}

// MARK: - Main View

enum SidebarItem: String, CaseIterable, Identifiable {
    case home = "Home"
    case settings = "Settings"
    case history = "History"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house"
        case .settings: return "gearshape"
        case .history: return "clock"
        }
    }
}

struct MainView: View {
    @State private var selection: SidebarItem = .home

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            switch selection {
            case .home:
                HomeView()
            case .settings:
                SettingsDetailView()
            case .history:
                HistoryView()
            }
        }
    }
}

// MARK: - Home View

struct HomeView: View {
    @State private var connectionState: ConnectionState = ConnectionManager.shared.state
    @State private var todayCount = 0
    @State private var totalCount = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Welcome card
                CardView {
                    HStack(spacing: 14) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.blue)
                            .frame(width: 48, height: 48)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Welcome to Voca")
                                .font(.headline)
                            Text("Press  Fn  to start voice input")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                // Stats
                HStack(spacing: 12) {
                    StatCard(title: "TOTAL", value: "\(totalCount)")
                    StatCard(title: "TODAY", value: "\(todayCount)")
                }

                // Current configuration
                CardView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Current Configuration")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ConfigRow(label: "Server", value: serverStatusText)
                        Divider()
                        ConfigRow(label: "Language", value: languageDisplayName)
                        Divider()
                        ConfigRow(label: "Trigger", value: HotkeyShortcut.load()?.displayString ?? "Fn Key")
                    }
                }

                // Quick actions
                HStack(spacing: 12) {
                    QuickActionButton(title: "Settings", icon: "gearshape") {}
                    QuickActionButton(title: "History", icon: "clock") {}
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refreshStats() }
    }

    private var serverStatusText: String {
        switch ConnectionManager.shared.state {
        case .localOnly: return "Not configured"
        case .connecting: return "Connecting..."
        case .online: return "Online"
        case .offline: return "Offline"
        }
    }

    private var languageDisplayName: String {
        let code = Settings.shared.selectedLocaleCode
        let map = ["": "System Default", "en-US": "English (US)", "zh-CN": "中文 (简体)",
                    "zh-TW": "中文 (繁體)", "ja-JP": "日本語", "ko-KR": "한국어"]
        return map[code] ?? code
    }

    private func refreshStats() {
        let all = HistoryStore.shared.list(limit: 10000)
        totalCount = all.count
        let calendar = Calendar.current
        todayCount = all.filter { calendar.isDateInToday($0.timestamp) }.count
    }
}

// MARK: - Settings Detail View

/// Manages shortcut recording state as a reference type so NSEvent closures work correctly.
final class ShortcutRecorder: ObservableObject {
    @Published var currentShortcut: String = HotkeyShortcut.load()?.displayString ?? "Fn Key"
    @Published var isRecording = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func startRecording() {
        isRecording = true
        currentShortcut = "Press keys..."
        KeyMonitor.shared?.isSuspended = true

        // Use both global (CGEvent level) and local monitors for full coverage
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil
        }
    }

    func stopRecording() {
        isRecording = false
        KeyMonitor.shared?.isSuspended = false
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    func resetToFn() {
        stopRecording()
        HotkeyShortcut.clear()
        KeyMonitor.shared?.customHotkey = nil
        currentShortcut = "Fn Key"
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = event.keyCode
        // Esc cancels
        if keyCode == 53 {
            DispatchQueue.main.async { [self] in
                stopRecording()
                currentShortcut = HotkeyShortcut.load()?.displayString ?? "Fn Key"
            }
            return
        }

        let relevantMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let mods = event.modifierFlags.intersection(relevantMask)

        // Require at least one modifier
        guard !mods.isEmpty else { return }

        let shortcut = HotkeyShortcut(keyCode: keyCode, modifiers: mods.rawValue)
        DispatchQueue.main.async { [self] in
            shortcut.save()
            KeyMonitor.shared?.customHotkey = shortcut
            currentShortcut = shortcut.displayString
            stopRecording()
        }
    }

    deinit {
        stopRecording()
    }
}

struct SettingsDetailView: View {
    @State private var serverURL = Settings.shared.serverURL
    @State private var authToken = Settings.shared.serverAuthToken
    @State private var showToken = false
    @State private var connectionStatus = ""
    @State private var isTesting = false
    @State private var locale = Settings.shared.selectedLocaleCode
    @StateObject private var shortcutRecorder = ShortcutRecorder()

    private let languages = [
        ("System Default", ""),
        ("English (US)", "en-US"),
        ("中文 (简体)", "zh-CN"),
        ("中文 (繁體)", "zh-TW"),
        ("日本語", "ja-JP"),
        ("한국어", "ko-KR"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Server connection
                CardView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Server Connection", systemImage: "server.rack")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Server URL", text: $serverURL)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: serverURL) { _, val in
                                    Settings.shared.serverURL = val
                                    ConnectionManager.shared.updateState()
                                }

                            HStack {
                                if showToken {
                                    TextField("Auth Token", text: $authToken)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    SecureField("Auth Token", text: $authToken)
                                        .textFieldStyle(.roundedBorder)
                                }
                                Button {
                                    showToken.toggle()
                                } label: {
                                    Image(systemName: showToken ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                            }
                            .onChange(of: authToken) { _, val in Settings.shared.serverAuthToken = val }

                            HStack(spacing: 8) {
                                Button("Test Connection") { testConnection() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(isTesting || serverURL.isEmpty)
                                if isTesting {
                                    ProgressView().controlSize(.small)
                                }
                                if !connectionStatus.isEmpty {
                                    Text(connectionStatus)
                                        .font(.caption)
                                        .foregroundStyle(connectionStatus.contains("OK") ? .green : .red)
                                }
                            }
                        }
                    }
                }

                // Language
                CardView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Speech Recognition", systemImage: "waveform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Picker("Language", selection: $locale) {
                            ForEach(languages, id: \.1) { lang in
                                Text(lang.0).tag(lang.1)
                            }
                        }
                        .onChange(of: locale) { _, val in Settings.shared.selectedLocaleCode = val }

                        Text("Used for local Apple Speech Recognition. Also sent as a hint when connected to the server.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Shortcut
                CardView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Trigger Shortcut", systemImage: "keyboard")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(shortcutRecorder.currentShortcut)
                                .font(.system(.body, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(shortcutRecorder.isRecording
                                    ? Color.accentColor.opacity(0.1)
                                    : Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(shortcutRecorder.isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                            Spacer()

                            Button(shortcutRecorder.isRecording ? "Cancel" : "Record") {
                                if shortcutRecorder.isRecording {
                                    shortcutRecorder.stopRecording()
                                    shortcutRecorder.currentShortcut = HotkeyShortcut.load()?.displayString ?? "Fn Key"
                                } else {
                                    shortcutRecorder.startRecording()
                                }
                            }
                            .controlSize(.small)

                            Button("Reset to Fn") {
                                shortcutRecorder.resetToFn()
                            }
                            .controlSize(.small)
                        }

                        Text("Hold the shortcut key to start voice input, release to finish. Press Esc to cancel recording.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // About
                CardView {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("About", systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text("Voca sends audio to dmr-plugin-voca for transcription and refinement. Without a server, local Apple Speech Recognition is used as fallback.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func testConnection() {
        isTesting = true
        connectionStatus = ""
        let client = VocaClient(baseURL: serverURL, authToken: authToken)
        client.health { ok in
            DispatchQueue.main.async {
                isTesting = false
                connectionStatus = ok ? "OK - Connected" : "Failed"
            }
        }
    }
}

// MARK: - History View

struct HistoryView: View {
    @State private var entries: [HistoryStore.LocalHistoryEntry] = []
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search history...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: searchText) { _, _ in refresh() }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            if entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundStyle(.quaternary)
                    Text(searchText.isEmpty ? "No history yet" : "No results")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }

            // Bottom bar
            HStack {
                Text("\(entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") {
                    HistoryStore.shared.clear()
                    refresh()
                }
                .controlSize(.small)
                .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refresh() }
    }

    private func refresh() {
        if searchText.isEmpty {
            entries = HistoryStore.shared.list()
        } else {
            entries = HistoryStore.shared.search(query: searchText)
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryStore.LocalHistoryEntry

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.refinedText)
                        .font(.system(size: 13))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.refinedText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(timeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if entry.wasRefined {
                        Text("Refined")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    if entry.wasRefined && entry.rawText != entry.refinedText {
                        Text("Raw: \(entry.rawText)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(entry.timestamp) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MM/dd HH:mm"
        }
        return formatter.string(from: entry.timestamp)
    }
}

// MARK: - Reusable Components

struct CardView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        CardView {
            VStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct ConfigRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.system(size: 13))
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
