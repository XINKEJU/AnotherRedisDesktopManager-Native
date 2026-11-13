import SwiftUI
import AppKit

// MARK: - Application entry

@main
struct ARDMNativeApp: App {
    @NSApplicationDelegateAdaptor(ARDMAppDelegate.self) var appDelegate
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        WindowGroup(id: "ardm-main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1120, minHeight: 700)
                .preferredColorScheme(store.preferredColorScheme)
                .environment(\.dynamicTypeSize, store.dynamicTypeSize)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { ARDMCommands(store: store) }
    }
}

final class ARDMAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // win-state.js replacement: restore the last window frame, but only when
        // it still lands on a connected display — a laptop undocked from an
        // external monitor would otherwise reopen entirely off-screen.
        let defaults = UserDefaults.standard
        if let window = NSApp.windows.first {
            let saved = defaults.string(forKey: "ARDMWindowFrame").map(NSRectFromString)
            // A cramped restored frame makes the three columns unreadable.
            if let frame = saved, frame.width >= 1120, frame.height >= 700, frameIsOnScreen(frame) {
                window.setFrame(frame, display: true)
            } else if let frame = saved, frame.width >= 1120, frame.height >= 700 {
                // Keep the size, re-centre on whichever display is attached now.
                window.setContentSize(frame.size)
                window.center()
            } else {
                window.setContentSize(NSSize(width: 1240, height: 780))
                window.center()
            }
        }
        AppStore.shared.startAutoRefresh()
        applyStartupArguments()
    }

    /// A saved frame is only reusable when a decent slice of it is still inside
    /// some display's visibleFrame (menubar/dock excluded).
    private func frameIsOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return !overlap.isNull && overlap.width >= 160 && overlap.height >= 120
        }
    }

    /// Parse command-line launch flags (mirrors electron-main.js argv handling):
    /// --host/--port/--auth/--db/--name, --cluster, --ssh-*, --sentinel-*, --ssl-*.
    private func applyStartupArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains(where: { $0.hasPrefix("--") }) else { return }
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            let next = args[index + 1]
            return next.hasPrefix("--") ? nil : next
        }
        func flag(_ name: String) -> Bool { args.contains(name) }

        let store = AppStore.shared
        let config = ARDMConnectionConfig()
        config.identifier = UUID().uuidString
        if config.separator.isEmpty { config.separator = ":" }
        if let host = value("--host") { config.host = host }
        if let port = value("--port"), let parsed = Int(port) { config.port = parsed }
        if let auth = value("--auth") { config.auth = auth }
        if let user = value("--user") ?? value("--username") { config.username = user }
        if let db = value("--db"), let parsed = Int(db) { config.db = parsed }
        if config.host.isEmpty { config.host = "127.0.0.1" }
        if config.port <= 0 { config.port = 6379 }
        config.name = value("--name") ?? "\(config.host):\(config.port)"
        config.cluster = flag("--cluster")

        if flag("--ssh") || value("--ssh-host") != nil {
            config.sshEnabled = true
            if let v = value("--ssh-host") { config.sshHost = v }
            if let v = value("--ssh-port"), let parsed = Int(v) { config.sshPort = parsed }
            if let v = value("--ssh-user") { config.sshUser = v }
            if let v = value("--ssh-password") { config.sshPassword = v }
            if let v = value("--ssh-key") { config.sshPrivateKey = v }
        }
        if flag("--sentinel") || value("--sentinel-master") != nil {
            config.sentinelEnabled = true
            config.cluster = false
            if let v = value("--sentinel-master") { config.sentinelMaster = v }
            if let v = value("--sentinel-password") { config.sentinelNodePassword = v }
        }
        if flag("--ssl") || flag("--tls") {
            config.tlsEnabled = true
            if let v = value("--tls-ca") { config.tlsCA = v }
            if let v = value("--tls-cert") { config.tlsCert = v }
            if let v = value("--tls-key") { config.tlsKey = v }
            if let v = value("--tls-sni") { config.tlsSNI = v }
        }
        if config.sentinelEnabled && config.cluster { config.cluster = false }

        store.connections.append(config)
        store.saveConnections()
        store.connect(to: config)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let window = NSApp.windows.first {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "ARDMWindowFrame")
        }
        AppStore.shared.disconnectAll()
    }
}

// MARK: - Menu bar (electron-main.js replacement)

struct ARDMCommands: Commands {
    let store: AppStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("message.new_connection", "New Connection")) { newConnection() }
                .keyboardShortcut("n", modifiers: .command)
            Button(L10n("New Key")) { store.showingNewKey = true }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandMenu(L10n("Redis")) {
            Button(L10n("Connect")) { if let c = store.selectedConnection { store.connect(to: c) } }
            Button(L10n("Disconnect")) { store.disconnect() }
            Divider()
            Button(L10n("Refresh Keys")) { store.refreshKeys(reset: true) }
                .keyboardShortcut("r", modifiers: .command)
            Button(L10n("Import Connections…")) { store.showingImportExport = true }
            Button(L10n("Export Connections…")) { store.showingImportExport = true }
        }
        CommandMenu(L10n("Keys")) {
            Button(L10n("Delete Selected Key")) { if let key = store.selectedKey { store.deleteKeys([key]) } }
                .keyboardShortcut(.delete, modifiers: .command)
            Button(L10n("Batch Delete…")) { store.showingBatchDelete = true }
            Button(L10n("Rename…")) { store.showingRename = true }
            Button(L10n("Set TTL…")) { store.showingTTL = true }
            Divider()
            Button(L10n("Copy Key Name")) { copySelectedKey() }
            Button(L10n("Add to Favorites")) { addFavorite() }
        }
        CommandMenu(L10n("Workspace")) {
            // ⌘1 … ⌘9 switch between the nine workspace tabs (upstream HotKeys.vue).
            ForEach(MainTab.allCases) { tab in
                if let index = MainTab.allCases.firstIndex(of: tab), index < 9 {
                    Button(L10n(tab.title)) { store.activeTab = tab }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                } else {
                    Button(L10n(tab.title)) { store.activeTab = tab }
                }
            }
            Divider()
            Button(L10n("Search Keys")) {
                store.activeTab = .keys
                store.searchFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: .command)
            Button(L10n("Toggle Tree View")) { store.showTree.toggle(); store.buildTree() }
            Button(L10n("Settings…")) { store.showingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
            Button(L10n("Keyboard Shortcuts…")) { store.showingHotKeys = true }
            Divider()
            // keymaster equivalents that the stock Window menu does not cover.
            Button(L10n("Toggle Maximize")) { NSApp.keyWindow?.zoom(nil) }
                .keyboardShortcut(.return, modifiers: .command)
            Button(L10n("Minimize")) { NSApp.keyWindow?.miniaturize(nil) }
                .keyboardShortcut("m", modifiers: .command)
            Button(L10n("Toggle Full Screen")) { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandMenu(L10n("Tools")) {
            Button(L10n("Command Log")) { store.activeTab = .logs }
            Button(L10n("Custom Formatters…")) { store.showingFormatterManager = true }
            Button(L10n("JSON Editor…")) { store.showingJsonEditor = true }
            Divider()
            Button(L10n("Check for Updates…")) { checkUpdate() }
        }
        CommandMenu(L10n("Language")) {
            ForEach(store.languages, id: \.self) { code in
                Button(languageDisplayName(code)) { store.language = code }
            }
        }
    }

    private func newConnection() {
        store.editingConnection = nil
        store.showingConnectionEditor = true
    }

    private func copySelectedKey() {
        guard let key = store.selectedKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    private func addFavorite() {
        guard let key = store.selectedKey, !store.favoriteKeys.contains(key) else { return }
        store.favoriteKeys.append(key)
        store.saveFavorites()
    }

    private func checkUpdate() {
        ARDMAppServices.checkForUpdate { status, url in
            store.updateStatus = status
            store.showingSettings = true
            if let url { NSWorkspace.shared.open(url) }
        }
    }
}

// MARK: - Root layout

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationSplitView {
            ConnectionSidebar()
                // Persisted sidebar width (upstream localStorage.sideWidth, 200–1500px).
                .navigationSplitViewColumnWidth(min: 200,
                                                ideal: CGFloat(min(1500, max(200, store.sidebarWidth))),
                                                max: 1500)
        } content: {
            KeyBrowserView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 480)
        } detail: {
            DetailPane()
        }
        .toolbar { MainToolbar() }
        .safeAreaInset(edge: .bottom) { StatusBar() }
        .modifier(ARDMSheets())
        .alert(L10n("Error"), isPresented: Binding(get: { store.errorMessage != nil },
                                            set: { if !$0 { store.errorMessage = nil } })) {
            Button(L10n("OK"), role: .cancel) { }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

struct MainToolbar: ToolbarContent {
    @EnvironmentObject var store: AppStore

    // Keep the title bar uncluttered. Tab switching lives in the detail pane's
    // own labelled tab strip; everything else is grouped into one menu.
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { store.editingConnection = nil; store.showingConnectionEditor = true } label: {
                Label(L10n("New Connection"), systemImage: "plus")
            }
            .help(L10n("New Connection"))
            .accessibilityLabel(L10n("New Connection"))
            .accessibilityIdentifier("toolbar.newConnection")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(L10n("Database"), selection: $store.selectedDB) {
                ForEach(0..<16, id: \.self) { Text("DB \($0)").tag($0) }
            }
            .frame(width: 96)
            .accessibilityLabel(L10n("Database"))
            .accessibilityIdentifier("toolbar.database")
            .onChange(of: store.selectedDB) { _, newValue in store.changeDatabase(newValue) }
            Menu {
                Button(L10n("Connect")) { if let c = store.selectedConnection { store.connect(to: c) } }
                Button(L10n("Disconnect")) { store.disconnect() }
                Divider()
                Button(L10n("Refresh Keys")) { store.refreshKeys(reset: true) }
                Button(L10n("New Key")) { store.showingNewKey = true }
                Button(L10n("Batch Delete")) { store.showingBatchDelete = true }
                Divider()
                Button(L10n("Import / Export…")) { store.showingImportExport = true }
                Button(L10n("Custom Formatters…")) { store.showingFormatterManager = true }
                Button(L10n("JSON Editor…")) { store.showingJsonEditor = true }
                Divider()
                Button(L10n("Settings…")) { store.showingSettings = true }
            } label: {
                Label(L10n("Tools"), systemImage: "ellipsis.circle")
            }
            .help(L10n("Tools"))
            .accessibilityLabel(L10n("Tools"))
            .accessibilityIdentifier("toolbar.tools")
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var store: AppStore

    // The DB index and the UI language used to be repeated here even though the
    // toolbar picker and the Language menu already show them. The bar now only
    // carries what appears nowhere else: socket state, counters, live mode.
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(store.connected ? Color.green : Color.gray).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(store.statusText).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if store.connected {
                Text("\(store.keys.count) / \(store.dbSize) " + L10n("keys")).font(.caption)
                if store.liveRunning {
                    Label(L10n("LIVE"), systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .accessibilityLabel(L10n("LIVE"))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status.bar")
        .font(store.uiFont(11))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - All sheets in one place

struct ARDMSheets: ViewModifier {
    @EnvironmentObject var store: AppStore

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $store.showingConnectionEditor) {
                ConnectionEditorView()
                    .environmentObject(store)
                    .frame(minWidth: 620, minHeight: 520)
            }
            .sheet(isPresented: $store.showingSettings) {
                SettingsView()
                    .environmentObject(store)
                    .frame(minWidth: 640, minHeight: 560)
            }
            .sheet(isPresented: $store.showingNewKey) {
                NewKeySheet().environmentObject(store).frame(width: 480, height: 300)
            }
            .sheet(isPresented: $store.showingBatchDelete) {
                BatchDeleteSheet().environmentObject(store).frame(width: 480, height: 260)
            }
            .sheet(isPresented: $store.showingRename) {
                TextInputSheet(title: L10n("Rename Key"), prompt: L10n("New name"), initial: store.selectedKey ?? "") { value in
                    store.renameKey(value)
                }
                .environmentObject(store).frame(width: 420, height: 180)
            }
            .sheet(isPresented: $store.showingTTL) {
                VStack(spacing: 12) {
                    Toggle(L10n("Milliseconds (PTTL / PEXPIRE)"), isOn: $store.ttlInMilliseconds)
                    TextInputSheet(
                        title: L10n("Set TTL"),
                        prompt: store.ttlInMilliseconds ? L10n("Milliseconds (-1 to persist)") : L10n("Seconds (-1 to persist)"),
                        initial: "\(store.ttlInMilliseconds ? store.selectedKeyTTLMillis : store.selectedKeyTTL)") { value in
                            guard let amount = Int(value) else { return }
                            if store.ttlInMilliseconds { store.setTTLMillis(amount) } else { store.setTTL(amount) }
                        }
                }
                .environmentObject(store).frame(width: 460, height: 220)
            }
            .sheet(isPresented: $store.showingImportExport) {
                ImportExportSheet().environmentObject(store).frame(width: 640, height: 480)
            }
            .sheet(isPresented: $store.showingHotKeys) {
                HotKeysSheet().environmentObject(store).frame(width: 520, height: 420)
            }
            .sheet(isPresented: $store.showingFormatterManager) {
                FormatterManagerSheet().environmentObject(store).frame(width: 640, height: 440)
            }
            .sheet(isPresented: $store.showingJsonEditor) {
                JsonEditorSheet().environmentObject(store).frame(width: 640, height: 480)
            }
            .sheet(isPresented: $store.showingZSetBatch) {
                ZSetBatchSheet().environmentObject(store)
            }
            .sheet(isPresented: $store.showingHexEditor) {
                HexEditorSheet().environmentObject(store)
            }
    }
}

struct TextInputSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let title: String
    let prompt: String
    let initial: String
    let onConfirm: (String) -> Void
    @State private var value = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            TextField(prompt, text: $value).textFieldStyle(.roundedBorder)
            HStack {
                Button(L10n("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n("OK")) { onConfirm(value); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .onAppear { value = initial }
    }
}
