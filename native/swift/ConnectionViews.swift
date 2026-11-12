import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Value-semantic draft so every field is editable with real bindings

struct ConnectionDraft {
    var identifier = ""
    var name = "New Connection"
    var host = "127.0.0.1"
    var port = "6379"
    var auth = ""
    var username = ""
    var db = 0
    var group = ""
    var separator = ":"
    var readOnly = false
    var cluster = false
    var connectionName = ""
    var sshEnabled = false
    var sshHost = ""
    var sshPort = "22"
    var sshUser = "root"
    var sshPassword = ""
    var sshPrivateKey = ""
    var sshPassphrase = ""
    var sshTimeout = "30"
    var tlsEnabled = false
    var tlsCA = ""
    var tlsCert = ""
    var tlsKey = ""
    var tlsSNI = ""
    var tlsIdentityPath = ""
    var sentinelEnabled = false
    var sentinelMaster = "mymaster"
    var sentinelNodePassword = ""
    var natMapText = ""
    var autoReconnect = true

    init() {}

    init(_ c: ARDMConnectionConfig) {
        identifier = c.identifier
        name = c.name; host = c.host; port = "\(c.port)"; auth = c.auth
        username = c.username; db = c.db; group = c.group; separator = c.separator
        readOnly = c.readOnly; cluster = c.cluster; connectionName = c.connectionName
        sshEnabled = c.sshEnabled; sshHost = c.sshHost; sshPort = "\(c.sshPort)"
        sshUser = c.sshUser; sshPassword = c.sshPassword; sshPrivateKey = c.sshPrivateKey
        sshPassphrase = c.sshPassphrase; sshTimeout = "\(c.sshTimeout)"
        tlsEnabled = c.tlsEnabled; tlsCA = c.tlsCA; tlsCert = c.tlsCert
        tlsKey = c.tlsKey; tlsSNI = c.tlsSNI; tlsIdentityPath = c.tlsIdentityPath
        sentinelEnabled = c.sentinelEnabled; sentinelMaster = c.sentinelMaster
        sentinelNodePassword = c.sentinelNodePassword; autoReconnect = c.autoReconnect
        natMapText = c.natMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
    }

    func apply(to c: ARDMConnectionConfig) {
        if !identifier.isEmpty { c.identifier = identifier }
        c.name = name; c.host = host; c.port = Int(port) ?? 6379
        c.auth = auth; c.username = username; c.db = db
        c.group = group; c.separator = separator; c.readOnly = readOnly
        c.cluster = cluster; c.connectionName = connectionName
        c.sshEnabled = sshEnabled; c.sshHost = sshHost; c.sshPort = Int(sshPort) ?? 22
        c.sshUser = sshUser; c.sshPassword = sshPassword; c.sshPrivateKey = sshPrivateKey
        c.sshPassphrase = sshPassphrase; c.sshTimeout = Int(sshTimeout) ?? 30
        c.tlsEnabled = tlsEnabled; c.tlsCA = tlsCA; c.tlsCert = tlsCert
        c.tlsKey = tlsKey; c.tlsSNI = tlsSNI; c.tlsIdentityPath = tlsIdentityPath
        c.sentinelEnabled = sentinelEnabled; c.sentinelMaster = sentinelMaster
        c.sentinelNodePassword = sentinelNodePassword; c.autoReconnect = autoReconnect
        var map: [String: String] = [:]
        for line in natMapText.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { map[String(pair[0]).trimmingCharacters(in: .whitespaces)] = String(pair[1]).trimmingCharacters(in: .whitespaces) }
        }
        c.natMap = map
    }
}

// MARK: - Sidebar (Connections.vue / ConnectionMenu.vue / ConnectionWrapper.vue)

struct ConnectionSidebar: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var showingNewGroup = false
    @State private var newGroupName = ""

    private var groups: [(String, [ARDMConnectionConfig])] {
        let filtered = store.connections.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.group.localizedCaseInsensitiveContains(query) }
        let grouped = Dictionary(grouping: filtered) { $0.group.isEmpty ? "Ungrouped" : $0.group }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tabs.vue: one tab per open connection, all sockets stay alive.
            if !store.openConnectionIDs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.openConnectionIDs, id: \.self) { id in
                            let config = store.connections.first { $0.identifier == id }
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(id == store.activeConnectionID ? Color.green : Color.gray)
                                    .frame(width: 6, height: 6)
                                Text(config?.name ?? id).font(.system(size: 10)).lineLimit(1)
                                Button { store.closeConnection(id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8))
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(
                                id == store.activeConnectionID ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                            .onTapGesture { store.switchConnection(id) }
                            .contextMenu {
                                Button(L10n("Close Connection")) { store.closeConnection(id) }
                                Button(L10n("Refresh")) { store.switchConnection(id); store.refreshKeys(reset: true) }
                                Divider()
                                Button("Close Other Tabs") {
                                    for other in store.openConnectionIDs where other != id { store.closeConnection(other) }
                                }
                                Button("Close Tabs to the Left") {
                                    guard let index = store.openConnectionIDs.firstIndex(of: id) else { return }
                                    for other in store.openConnectionIDs.prefix(index) { store.closeConnection(other) }
                                }
                                Button("Close Tabs to the Right") {
                                    guard let index = store.openConnectionIDs.firstIndex(of: id) else { return }
                                    for other in store.openConnectionIDs.suffix(from: index + 1) { store.closeConnection(other) }
                                }
                            }
                        }
                    }
                }
                .frame(height: 30)
                .padding(.horizontal, 6)
                Divider()
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n("Search"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 70)
                Button { store.editingConnection = nil; store.showingConnectionEditor = true } label: {
                    Image(systemName: "plus")
                }.help(L("message.new_connection", "New Connection"))
                Button { if let c = store.selectedConnection { store.connect(to: c) } } label: {
                    Image(systemName: "bolt.fill")
                }.help(L10n("Connect")).disabled(store.selectedConnection == nil)
                Menu {
                    Button(L10n("Connect")) { if let c = store.selectedConnection { store.connect(to: c) } }
                    Button(L10n("Disconnect")) { store.disconnect() }
                    Divider()
                    Button("Import / Export…") { store.showingImportExport = true }
                    Button("New Group…") { showingNewGroup = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }
            .padding(8)
            .fixedSize(horizontal: false, vertical: true)

            List(selection: $store.selectedConnectionID) {
                if !store.favoriteKeys.isEmpty {
                    Section(L10n("Favorites")) {
                        ForEach(store.favoriteKeys, id: \.self) { key in
                            Label(key, systemImage: "star.fill")
                                .font(.system(size: store.scaled(12)))
                                .onTapGesture { store.selectKey(key) }
                                .draggable(key)
                        }
                    }
                }
                ForEach(groups, id: \.0) { groupName, configs in
                    Section(groupName) {
                        ForEach(configs, id: \.identifier) { config in
                            ConnectionRow(config: config)
                                .tag(config.identifier)
                                .draggable(config.identifier)
                                .dropDestination(for: String.self) { identifiers, _ in
                                    guard let dragged = identifiers.first, dragged != config.identifier,
                                          let from = store.connections.firstIndex(where: { $0.identifier == dragged }),
                                          let to = store.connections.firstIndex(where: { $0.identifier == config.identifier }) else {
                                        return false
                                    }
                                    let moved = store.connections.remove(at: from)
                                    store.connections.insert(moved, at: to > from ? to - 1 : to)
                                    store.saveConnections()
                                    return true
                                }
                        }
                    }
                    .dropDestination(for: String.self) { identifiers, _ in
                        guard let id = identifiers.first else { return false }
                        if let config = store.connections.first(where: { $0.identifier == id }) {
                            config.group = groupName == "Ungrouped" ? "" : groupName
                            store.saveConnections()
                            return true
                        }
                        return false
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .alert(L10n("New Group"), isPresented: $showingNewGroup) {
            TextField(L10n("Group name"), text: $newGroupName)
            Button(L10n("Cancel"), role: .cancel) { }
            Button(L10n("Create")) {
                guard !newGroupName.isEmpty else { return }
                let config = ARDMConnectionConfig()
                config.name = newGroupName
                config.group = newGroupName
                store.connections.append(config)
                store.saveConnections()
                newGroupName = ""
            }
        } message: { Text("Creates a group with a placeholder connection. Drag connections onto a group to move them.") }
    }
}

struct ConnectionRow: View {
    @EnvironmentObject var store: AppStore
    let config: ARDMConnectionConfig
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: store.connected && store.selectedConnectionID == config.identifier ? "bolt.fill" : "server.rack")
                .foregroundStyle(store.connected && store.selectedConnectionID == config.identifier ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.name).lineLimit(1)
                Text("\(config.host):\(config.port) · DB\(config.db)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if config.readOnly { Image(systemName: "lock").font(.system(size: 9)) }
            if config.tlsEnabled { Image(systemName: "lock.shield").font(.system(size: 9)) }
            if config.sshEnabled { Image(systemName: "network").font(.system(size: 9)) }
        }
        .font(.system(size: store.scaled(12)))
        .onTapGesture(count: 2) { store.connect(to: config) }
        .contextMenu {
            Button(L10n("Connect")) { store.connect(to: config) }
            Button(L10n("Close Connection")) { store.disconnect() }
            Divider()
            Button(L("message.edit_connection", "Edit Connection")) { store.editingConnection = config; store.showingConnectionEditor = true }
            Button(L10n("Duplicate Connection")) { duplicate() }
            Button(L10n("Copy Host")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(config.host, forType: .string) }
            Divider()
            Button(L10n("Delete Connection"), role: .destructive) { delete() }
        }
    }

    private func duplicate() {
        guard let copy = config.copy() as? ARDMConnectionConfig else { return }
        copy.identifier = UUID().uuidString
        copy.name = config.name + " (copy)"
        store.connections.append(copy)
        store.saveConnections()
    }

    private func delete() {
        store.connections.removeAll { $0.identifier == config.identifier }
        store.saveConnections()
        if store.selectedConnectionID == config.identifier { store.disconnect() }
    }
}

// MARK: - Connection editor (NewConnectionDialog.vue, four tabs)

struct ConnectionEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var draft = ConnectionDraft()
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.editingConnection == nil ? L("message.new_connection", "New Connection") : L("message.edit_connection", "Edit Connection"))
                    .font(.headline)
                Spacer()
                Button(L10n("Test Connection")) { test() }.disabled(testing)
                if testing { ProgressView().scaleEffect(0.6) }
            }
            .padding(12)

            if !testResult.isEmpty {
                Text(testResult).font(.caption).foregroundStyle(testResult.contains("success") ? .green : .red)
                    .padding(.horizontal, 12)
            }

            TabView {
                generalTab.tabItem { Label(L10n("General"), systemImage: "server.rack") }
                sshTab.tabItem { Label(L10n("SSH"), systemImage: "network") }
                tlsTab.tabItem { Label(L10n("TLS"), systemImage: "lock.shield") }
                advancedTab.tabItem { Label(L10n("Advanced"), systemImage: "slider.horizontal.3") }
            }
            .padding(12)

            Divider()
            HStack {
                Button(L10n("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n("Save")) { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .onAppear { draft = store.editingConnection.map(ConnectionDraft.init) ?? ConnectionDraft() }
    }

    private var generalTab: some View {
        Form {
            TextField(L10n("Name"), text: $draft.name)
            TextField(L10n("Host"), text: $draft.host)
            TextField(L10n("Port"), text: $draft.port)
            HStack {
                TextField(L10n("Username (ACL)"), text: $draft.username)
                SecureField(L10n("Password"), text: $draft.auth)
            }
            Stepper("Database: \(draft.db)", value: $draft.db, in: 0...15)
            TextField(L10n("Client name"), text: $draft.connectionName)
            TextField(L10n("Key separator"), text: $draft.separator)
            TextField(L10n("Group"), text: $draft.group)
            Toggle(L10n("Read-only mode"), isOn: $draft.readOnly)
            Toggle(L10n("Cluster mode"), isOn: $draft.cluster)
        }
        .formStyle(.grouped)
    }

    private var sshTab: some View {
        Form {
            Toggle(L10n("SSH tunnel"), isOn: $draft.sshEnabled)
            TextField(L10n("SSH host"), text: $draft.sshHost)
            HStack { TextField(L10n("Port"), text: $draft.sshPort); TextField(L10n("User"), text: $draft.sshUser) }
            SecureField(L10n("Password / key passphrase"), text: $draft.sshPassword)
            HStack {
                TextField(L10n("Private key path"), text: $draft.sshPrivateKey)
                Button("Browse…") { if let path = chooseFile() { draft.sshPrivateKey = path } }
            }
            SecureField(L10n("Key passphrase"), text: $draft.sshPassphrase)
            TextField(L10n("Timeout (s)"), text: $draft.sshTimeout)
            Text("Uses /usr/bin/ssh -L with SSH_ASKPASS; replaces tunnel-ssh.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .disabled(!draft.sshEnabled)
    }

    private var tlsTab: some View {
        Form {
            Toggle(L10n("TLS / SSL"), isOn: $draft.tlsEnabled)
            TextField(L10n("SNI / peer name"), text: $draft.tlsSNI)
            fileRow("CA certificate", $draft.tlsCA)
            fileRow("Client certificate (PEM)", $draft.tlsCert)
            fileRow("Private key (PEM)", $draft.tlsKey)
            fileRow("PKCS#12 identity (.p12)", $draft.tlsIdentityPath)
            Text("Mutual TLS loads the client identity via Security.framework (SecPKCS12Import / SecItemImport).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
            Toggle(L10n("Sentinel"), isOn: $draft.sentinelEnabled)
            TextField(L10n("Master name"), text: $draft.sentinelMaster)
            SecureField(L10n("Sentinel node password"), text: $draft.sentinelNodePassword)
            Divider()
            Text("Cluster NAT map — one `internal:port=public:port` per line")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.natMapText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 90)
                .border(Color.secondary.opacity(0.3))
            Toggle(L10n("Auto reconnect with backoff"), isOn: $draft.autoReconnect)
        }
        .formStyle(.grouped)
    }

    private func fileRow(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            TextField(label, text: binding)
            Button("Browse…") { if let path = chooseFile() { binding.wrappedValue = path } }
        }
    }

    private func chooseFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if let bookmark = ARDMAppServices.bookmark(for: url) {
            var bookmarks = UserDefaults.standard.dictionary(forKey: "ARDMScopedBookmarks") ?? [:]
            bookmarks[url.path] = bookmark
            UserDefaults.standard.set(bookmarks, forKey: "ARDMScopedBookmarks")
        }
        return url.path
    }

    private func makeConfig() -> ARDMConnectionConfig {
        let config = store.editingConnection ?? ARDMConnectionConfig()
        draft.apply(to: config)
        return config
    }

    private func test() {
        testing = true
        testResult = ""
        store.testConnection(makeConfig()) { ok, message in
            testing = false
            testResult = message
        }
    }

    private func save() {
        let config = makeConfig()
        if let index = store.connections.firstIndex(where: { $0.identifier == config.identifier }) {
            store.connections[index] = config
        } else {
            store.connections.append(config)
        }
        store.saveConnections()
        store.selectedConnectionID = config.identifier
        dismiss()
    }
}

// MARK: - Import / export (Setting.vue, FileInput.vue, DeleteBatch.vue)

struct ImportExportSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var selection = 0
    @State private var connectionJSON = ARDMAppServices.exportConnectionsJSON()
    @State private var keyJSON = "[]"

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $selection) {
                Text(L10n("Connections")).tag(0)
                Text(L10n("Keys")).tag(1)
            }
            .pickerStyle(.segmented)
            TextEditor(text: selection == 0 ? $connectionJSON : $keyJSON)
                .font(.system(size: 11, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button(L10n("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selection == 0 ? connectionJSON : keyJSON, forType: .string)
                }
                Button("Save to File…") { saveToFile() }
                Button("Load from File…") { loadFromFile() }
                Spacer()
                Button(L10n("Import / Apply")) { apply() }.buttonStyle(.borderedProminent)
                Button(L10n("Close")) { dismiss() }
            }
        }
        .padding(16)
        .onChange(of: selection) { _, newValue in
            if newValue == 1 { keyJSON = store.exportKeys(Array(store.checkedKeys.isEmpty ? [store.selectedKey ?? ""] : store.checkedKeys)) }
        }
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = selection == 0 ? "ardm-connections.json" : "ardm-keys.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (selection == 0 ? connectionJSON : keyJSON).write(to: url, atomically: true, encoding: .utf8)
        store.notify("Exported to \(url.lastPathComponent)")
    }

    private func loadFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if selection == 0 { connectionJSON = text } else { keyJSON = text }
    }

    private func apply() {
        if selection == 0 {
            guard let data = connectionJSON.data(using: .utf8) else { return }
            do {
                try ARDMAppServices.importConnectionsJSON(data)
                store.reloadConnections()
                store.notify("Connections imported")
            } catch { store.fail(error.localizedDescription) }
        } else {
            store.importKeyValues(keyJSON)
        }
        dismiss()
    }
}
