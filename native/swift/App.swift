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
                .frame(minWidth: 1040, minHeight: 660)
                .preferredColorScheme(store.preferredColorScheme)
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
        // win-state.js replacement: restore the last window frame.
        let defaults = UserDefaults.standard
        if let frameString = defaults.string(forKey: "ARDMWindowFrame") {
            let frame = NSRectFromString(frameString)
            if frame.width > 400, let window = NSApp.windows.first { window.setFrame(frame, display: true) }
        }
        AppStore.shared.startAutoRefresh()
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
        CommandMenu("Redis") {
            Button(L10n("Connect")) { if let c = store.selectedConnection { store.connect(to: c) } }
            Button(L10n("Disconnect")) { store.disconnect() }
            Divider()
            Button(L10n("Refresh Keys")) { store.refreshKeys(reset: true) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Import Connections…") { store.showingImportExport = true }
            Button("Export Connections…") { store.showingImportExport = true }
        }
        CommandMenu("Keys") {
            Button(L10n("Delete Selected Key")) { if let key = store.selectedKey { store.deleteKeys([key]) } }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Batch Delete…") { store.showingBatchDelete = true }
            Button("Rename…") { store.showingRename = true }
            Button("Set TTL…") { store.showingTTL = true }
            Divider()
            Button(L10n("Copy Key Name")) { copySelectedKey() }
            Button(L10n("Add to Favorites")) { addFavorite() }
        }
        CommandMenu("View") {
            ForEach(MainTab.allCases) { tab in
                Button(tab.title) { store.activeTab = tab }
            }
            Divider()
            Button(L10n("Toggle Tree View")) { store.showTree.toggle(); store.buildTree() }
            Button("Settings…") { store.showingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
            Button("Keyboard Shortcuts…") { store.showingHotKeys = true }
        }
        CommandMenu("Tools") {
            Button(L10n("Command Log")) { store.activeTab = .logs }
            Button("Custom Formatters…") { store.showingFormatterManager = true }
            Button("JSON Editor…") { store.showingJsonEditor = true }
            Divider()
            Button("Check for Updates…") { checkUpdate() }
        }
        CommandMenu("Language") {
            ForEach(store.languages, id: \.self) { code in
                Button(code.uppercased()) { store.language = code }
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
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
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
            Button("OK", role: .cancel) { }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

struct MainToolbar: ToolbarContent {
    @EnvironmentObject var store: AppStore

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.refreshKeys(reset: true) } label: { Label(L10n("Refresh"), systemImage: "arrow.clockwise") }
                .help("Refresh the key list (⌘R)")
            Button { store.showingNewKey = true } label: { Label(L10n("New Key"), systemImage: "plus") }
                .help(L10n("Create a new key"))
            Button { store.showingBatchDelete = true } label: { Label(L10n("Batch Delete"), systemImage: "trash") }
                .help(L10n("Delete keys matching a pattern"))
            Picker(L10n("Tab"), selection: $store.activeTab) {
                ForEach(MainTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
        }
        ToolbarItemGroup(placement: .automatic) {
            Picker("DB", selection: $store.selectedDB) {
                ForEach(0..<16, id: \.self) { Text("DB \($0)").tag($0) }
            }
            .frame(width: 90)
            .onChange(of: store.selectedDB) { _, newValue in store.changeDatabase(newValue) }
            Toggle(L10n("Read-only"), isOn: $store.readOnly)
                .toggleStyle(.switch)
                .onChange(of: store.readOnly) { _, newValue in
                    store.selectedConnection?.readOnly = newValue
                    store.saveConnections()
                }
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(store.connected ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(store.statusText).lineLimit(1)
            Spacer()
            if store.connected {
                Text("DB \(store.selectedDB)").font(.caption)
                Text("\(store.keys.count) / \(store.dbSize) keys").font(.caption)
                if store.liveRunning { Label(L10n("LIVE"), systemImage: "dot.radiowaves.left.and.right").font(.caption) }
            }
            Text(store.language.uppercased()).font(.caption)
        }
        .font(.system(size: store.scaled(11)))
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
                TextInputSheet(title: "Rename Key", prompt: "New name", initial: store.selectedKey ?? "") { value in
                    store.renameKey(value)
                }
                .environmentObject(store).frame(width: 420, height: 180)
            }
            .sheet(isPresented: $store.showingTTL) {
                TextInputSheet(title: "Set TTL", prompt: "Seconds (-1 to persist)", initial: "\(store.selectedKeyTTL)") { value in
                    if let seconds = Int(value) { store.setTTL(seconds) }
                }
                .environmentObject(store).frame(width: 420, height: 180)
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
                Button("OK") { onConfirm(value); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .onAppear { value = initial }
    }
}
