import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sidebar status dot: green when live, amber while reconnecting, red when the
/// socket is lost, grey when nobody has connected yet.
func dotColor(_ state: ConnectionState?) -> Color {
    switch state {
    case .connected: return .green
    case .connecting: return .yellow
    case .reconnecting: return .orange
    case .failed: return .red
    default: return .secondary
    }
}

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
    var tlsInsecure = false
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
        tlsInsecure = c.tlsInsecure
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
        c.tlsInsecure = tlsInsecure
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
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    /// The List selects one string; connection rows use their identifier and
    /// database rows use "db:<identifier>:<index>". A single local binding lets
    /// the database rows be clickable without making them list selection.
    @State private var sidebarSelection: String?
    @State private var expandedConnections: Set<String> = []
    @State private var showAllDatabases: Set<String> = []

    /// Every connection is listed: the sidebar holds the connections the user
    /// made, not an index, and ⌘K already searches name, host and group.
    private var groups: [(String, [ARDMConnectionConfig])] {
        let grouped = Dictionary(grouping: store.connections) { $0.group.isEmpty ? "Ungrouped" : $0.group }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    // MARK: Connection tree

    /// A connection is a leaf until its socket is up. Once it is open the row
    /// grows a disclosure triangle listing db0…db15, so the database sits with
    /// the connection instead of in a picker at the far right of the window.
    /// Cluster connections have a single keyspace and stay leaves.
    @ViewBuilder
    private func connectionNode(_ config: ARDMConnectionConfig) -> some View {
        if store.openConnectionIDs.contains(config.identifier) && !config.cluster {
            DisclosureGroup(isExpanded: expansionBinding(config.identifier)) {
                databaseRows(config)
            } label: {
                connectionLabel(config)
            }
        } else {
            connectionLabel(config)
        }
    }

    /// Sixteen rows under a connection, twelve of them empty, made the sidebar
    /// the tallest column in the window. Empty databases collapse behind one row
    /// until asked for; the database currently in use never hides.
    @ViewBuilder
    private func databaseRows(_ config: ARDMConnectionConfig) -> some View {
        let counts = config.identifier == store.activeConnectionID ? dbKeyCounts() : [:]
        let collapsed = collapsedDatabases(config, counts: counts)
        let shown = showAllDatabases.contains(config.identifier) ? Array(0..<16) : collapsed
        ForEach(shown, id: \.self) { db in
            databaseRow(db, config: config, counts: counts)
        }
        if collapsed.count < 16 {
            toggleAllDatabasesRow(config, collapsed: collapsed.count,
                                  expanded: showAllDatabases.contains(config.identifier))
        }
    }

    private func collapsedDatabases(_ config: ARDMConnectionConfig, counts: [Int: Int]) -> [Int] {
        let selected = store.databaseIndex(for: config.identifier)
        let populated = (0..<16).filter { (counts[$0] ?? 0) > 0 }
        if populated.contains(selected) { return populated }
        return (populated + [selected]).sorted()
    }

    private func toggleAllDatabasesRow(_ config: ARDMConnectionConfig,
                                       collapsed: Int, expanded: Bool) -> some View {
        // A plain row with a tap gesture, not a Button: a Button in this List
        // takes the click as list selection and never runs its action.
        return HStack(spacing: 5) {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 7, weight: .semibold))
            Text(expanded ? L10n("Only databases with keys")
                          : L10n("All 16 databases"))
                .font(.system(size: ARDMFont.small))
            Spacer(minLength: 2)
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: ARDMMetrics.sideRow)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded { showAllDatabases.remove(config.identifier) }
            else { showAllDatabases.insert(config.identifier) }
        }
        .help(expanded ? L10n("Only databases with keys")
                       : L10n("Show the empty databases too"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(expanded ? L10n("Only databases with keys")
                                     : L10n("All 16 databases"))
        .accessibilityValue("\(collapsed)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if expanded { showAllDatabases.remove(config.identifier) }
            else { showAllDatabases.insert(config.identifier) }
        }
    }

    private func connectionLabel(_ config: ARDMConnectionConfig) -> some View {
        ConnectionRow(config: config)
            .tag(config.identifier)
            .draggable(config.identifier)
            .dropDestination(for: String.self) { identifiers, _ in
                moveConnection(identifiers.first, onto: config)
            }
    }

    private func moveConnection(_ dragged: String?, onto config: ARDMConnectionConfig) -> Bool {
        guard let dragged, dragged != config.identifier,
              let from = store.connections.firstIndex(where: { $0.identifier == dragged }),
              let to = store.connections.firstIndex(where: { $0.identifier == config.identifier }) else {
            return false
        }
        let moved = store.connections.remove(at: from)
        store.connections.insert(moved, at: to > from ? to - 1 : to)
        store.saveConnections()
        return true
    }

    private func databaseRow(_ db: Int, config: ARDMConnectionConfig, counts: [Int: Int]) -> some View {
        let current = store.databaseIndex(for: config.identifier) == db
        return HStack(spacing: 5) {
            // The same 15pt glyph column the connection row uses, so the two
            // levels of the tree line up on one edge. `cylinder.fill` rather
            // than `database.fill`: the latter is SF Symbols 6 and would render
            // nothing on the macOS 14 target this bundle declares.
            Image(systemName: "cylinder.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(current ? Color.accentColor : Color.secondary)
                .frame(width: 15, alignment: .center)
            Text("db\(db)")
                .font(.system(size: ARDMFont.small, weight: current ? .medium : .regular))
                .foregroundStyle(current ? Color.accentColor : Color.primary)
                .monospacedDigit()
            if let count = counts[db], count > 0 {
                ARDMCountBadge(count: count,
                               tint: current ? Color.accentColor : Color.secondary)
            }
            Spacer(minLength: 2)
        }
        .frame(minHeight: ARDMMetrics.sideRow)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(current ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4))
        // Two ways in on purpose: the tap handles the common case, and the tag
        // keeps the click working on list styles that route clicks through
        // selection. Both land on the same idempotent call.
        .contentShape(Rectangle())
        .onTapGesture { pickDatabase(db, config) }
        .tag("db:\(config.identifier):\(db)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("db\(db)")
        .accessibilityValue(current ? L10n("Selected") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pickDatabase(db, config) }
    }

    private func pickDatabase(_ db: Int, _ config: ARDMConnectionConfig) {
        store.selectDatabase(db, for: config.identifier)
    }

    /// "db:8071E61F-…:3" → ("8071E61F-…", 3). Connection identifiers are UUIDs,
    /// so they never contain a colon and a plain split is unambiguous.
    private func databaseSelection(_ value: String) -> (id: String, db: Int)? {
        guard value.hasPrefix("db:") else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 3, let db = Int(parts[2]) else { return nil }
        return (String(parts[1]), db)
    }

    private func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedConnections.contains(id) },
                set: { open in
                    if open { expandedConnections.insert(id) } else { expandedConnections.remove(id) }
                })
    }

    /// Per-database key counts come from INFO keyspace, which is only fetched for
    /// the active connection — the same one whose tree is open.
    private func dbKeyCounts() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for (name, stats) in store.keyspaceStats where name.hasPrefix("db") {
            guard let db = Int(name.dropFirst(2)) else { continue }
            for field in stats.split(separator: ",") {
                let pair = field.split(separator: "=")
                if pair.count == 2, pair[0] == "keys", let n = Int(pair[1]) { counts[db] = n }
            }
        }
        return counts
    }

    var body: some View {
        VStack(spacing: 0) {
            // No tab strip here: every open connection is already a row in the
            // tree below, with its own status dot and key count. Clicking that
            // row switches to it, which is all the strip used to do.
            // No search field either: a second box that looked exactly like the
            // SCAN pattern below it, for a list the user typed by hand.
            HStack(spacing: 4) {
                ARDMIconButton(systemName: "plus", help: L("message.new_connection", "New Connection")) {
                    store.editingConnection = nil
                    store.showingConnectionEditor = true
                }
                .accessibilityIdentifier("sidebar.newConnection")
                ARDMIconMenu(help: L10n("More actions")) {
                    Section {
                        Button {
                            if let c = store.selectedConnection { store.connect(to: c) }
                        } label: {
                            Label(L10n("Connect"), systemImage: "play.fill")
                        }
                        Button {
                            store.disconnect()
                        } label: {
                            Label(L10n("Disconnect"), systemImage: "stop.fill")
                        }
                    }
                    Section {
                        Button { store.showingImportExport = true } label: {
                            Label(L10n("Import / Export…"), systemImage: "arrow.up.arrow.down")
                        }
                        Button { showingNewGroup = true } label: {
                            Label(L10n("New Group…"), systemImage: "folder.badge.plus")
                        }
                    }
                }
                Spacer(minLength: 0)
                // The title bar's own sidebar toggle was removed years ago
                // because it toggled a column that could not collapse. Now that
                // it can, the affordance belongs next to the column it hides.
                ARDMIconButton(systemName: "sidebar.left", help: L10n("Collapse Sidebar")) {
                    store.sidebarCollapsed = true
                }
                .accessibilityIdentifier("sidebar.collapse")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .fixedSize(horizontal: false, vertical: true)

            List(selection: $sidebarSelection) {
                if !store.favoriteKeys.isEmpty {
                    Section(L10n("Favorites")) {
                        ForEach(store.favoriteKeys, id: \.self) { key in
                            Label(key, systemImage: "star.fill")
                                .font(store.uiFont(12))
                                .onTapGesture { store.selectKey(key) }
                                .draggable(key)
                        }
                    }
                }
                ForEach(groups, id: \.0) { groupName, configs in
                    Section(L10n(groupName)) {
                        ForEach(configs, id: \.identifier) { config in
                            connectionNode(config)
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
            // Sidebar rows default to 28pt, which turns the sixteen database
            // rows into a column twice the height of the key list beside it.
            // Connections keep their two-line height; db rows collapse to 21pt.
            .environment(\.defaultMinListRowHeight, 18)
        }
        .onAppear { sidebarSelection = store.selectedConnectionID }
        .onChange(of: sidebarSelection) { _, newValue in
            guard let value = newValue else { return }
            if let picked = databaseSelection(value) {
                store.selectDatabase(picked.db, for: picked.id)
                // Leave the connection highlighted: the database rows are a
                // sub-selection, not a second kind of list item.
                sidebarSelection = store.activeConnectionID
                return
            }
            store.selectedConnectionID = value
            // Selecting an already-open connection is the tab strip's old job:
            // bring it forward, and revive it if its socket dropped.
            if value != store.activeConnectionID, store.openConnectionIDs.contains(value),
               let config = store.connections.first(where: { $0.identifier == value }) {
                store.connect(to: config)
            }
            // Arrows now belong to this list, which takes them natively.
            store.keyListHasFocus = false
        }
        .onChange(of: store.selectedConnectionID) { _, newValue in
            if sidebarSelection != newValue { sidebarSelection = newValue }
        }
        .onChange(of: store.activeConnectionID, initial: true) { _, newValue in
            guard let newValue else { return }
            sidebarSelection = newValue
            expandedConnections.insert(newValue)
        }
        .onChange(of: store.openConnectionIDs) { _, ids in
            expandedConnections = expandedConnections.intersection(ids)
            showAllDatabases = showAllDatabases.intersection(ids)
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
        } message: { Text(L10n("Creates a group with a placeholder connection. Drag connections onto a group to move them.")) }
    }
}

struct ConnectionRow: View {
    @EnvironmentObject var store: AppStore
    let config: ARDMConnectionConfig
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            // The glyph says what the row is; the dot at the far end says how it
            // is doing. They used to be the same colour, which meant a green
            // server icon and no way to read state at a glance.
            Image(systemName: "server.rack")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 15, alignment: .center)
            // One line per connection, like the reference clients. The address
            // moved to the tooltip and the context menu: sixteen database rows
            // sit underneath, so a two-line header pushed the list off-screen.
            Text(config.name)
                .font(.system(size: ARDMFont.body))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if config.readOnly {
                Image(systemName: "lock")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            if config.tlsEnabled {
                Image(systemName: "lock.shield")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            if config.sshEnabled {
                Image(systemName: "network")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            // The whole server, not the one database the middle column happens to
            // have open — the dot beside it is per-connection, so the number
            // should be too. Only the active tab has an INFO keyspace of its own.
            if let total = serverKeyTotal() {
                ARDMCountBadge(count: total, tint: .secondary)
            }
            Circle()
                .fill(dotColor(store.connectionStates[config.identifier]))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
        .frame(minHeight: ARDMMetrics.sideRow)
        .help("\(config.name) — \(config.host):\(config.port)")
        // One element instead of five: the status and capability glyphs are
        // meaningless when read out as "bolt.fill, lock, network".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.connect(to: config) }
        .accessibilityIdentifier("sidebar.connection." + config.identifier)
        .onTapGesture(count: 2) { store.connect(to: config) }
        .contextMenu {
            Button(L10n("Connect")) { store.connect(to: config) }
            Button(L10n("Close Connection")) { store.closeConnection(config.identifier) }
            Divider()
            Button(L("message.edit_connection", "Edit Connection")) { store.editingConnection = config; store.showingConnectionEditor = true }
            Button(L10n("Duplicate Connection")) { duplicate() }
            Button(L10n("Copy Host")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(config.host, forType: .string) }
            Divider()
            Button(L10n("Delete Connection"), role: .destructive) { delete() }
        }
    }

    /// Keys across every database of the active server, from INFO keyspace.
    /// nil for a connection that is not in front, because its keyspace was
    /// never asked for — a blank is honest where a zero would lie.
    private func serverKeyTotal() -> Int? {
        guard config.identifier == store.activeConnectionID, !store.keyspaceStats.isEmpty
        else { return nil }
        var total = 0
        for (name, stats) in store.keyspaceStats where name.hasPrefix("db") {
            for field in stats.split(separator: ",") {
                let pair = field.split(separator: "=")
                if pair.count == 2, pair[0] == "keys", let n = Int(pair[1]) { total += n }
            }
        }
        return total
    }

    private var rowDescription: String {
        var parts = [config.name, "\(config.host):\(config.port)"]
        parts.append(store.connectionStates[config.identifier]?.isOnline == true
                     ? L10n("Connected") : L10n("Not connected"))
        if config.readOnly { parts.append(L10n("Read-only")) }
        if config.tlsEnabled { parts.append("TLS") }
        if config.sshEnabled { parts.append("SSH") }
        return parts.joined(separator: ", ")
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
            Text(L10n("Passwords are stored in the macOS Keychain, never in connections.json."))
                .font(.caption).foregroundStyle(.secondary)
            if store.editingConnection?.secretUnavailable == true {
                Text(L10n("The Keychain did not return the stored password — re-enter it if the server rejects the connection."))
                    .font(.caption).foregroundStyle(.orange)
            }
            Stepper("Database: \(draft.db)", value: $draft.db, in: 0...15)
            TextField(L10n("Client name"), text: $draft.connectionName)
            TextField(L10n("Key separator"), text: $draft.separator)
            TextField(L10n("Group"), text: $draft.group)
            Toggle(L10n("Read-only mode"), isOn: $draft.readOnly)
            Toggle(L10n("Cluster mode"), isOn: $draft.cluster)
                .disabled(draft.sentinelEnabled)
            if draft.sentinelEnabled {
                Text(L10n("Cluster mode is unavailable while Sentinel is enabled."))
                    .font(.caption).foregroundStyle(.orange)
            }
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
                Button(L10n("Browse…")) { if let path = chooseFile() { draft.sshPrivateKey = path } }
            }
            SecureField(L10n("Key passphrase"), text: $draft.sshPassphrase)
            TextField(L10n("Timeout (s)"), text: $draft.sshTimeout)
            Text(L10n("Uses /usr/bin/ssh -L with SSH_ASKPASS; replaces tunnel-ssh."))
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
            Toggle(L10n("Allow insecure TLS (skip certificate validation)"), isOn: $draft.tlsInsecure)
            Text(L10n("Mutual TLS loads the client identity via Security.framework (SecPKCS12Import / SecItemImport)."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
            Toggle(L10n("Sentinel"), isOn: $draft.sentinelEnabled)
                .disabled(draft.cluster)
            if draft.cluster {
                Text(L10n("Sentinel is unavailable while Cluster mode is enabled."))
                    .font(.caption).foregroundStyle(.orange)
            }
            TextField(L10n("Master name"), text: $draft.sentinelMaster)
            SecureField(L10n("Sentinel node password"), text: $draft.sentinelNodePassword)
            Divider()
            Text(L10n("Cluster NAT map — one `internal:port=public:port` per line"))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.natMapText)
                .font(store.monoFont(11))
                .frame(height: 90)
                .border(Color.secondary.opacity(0.3))
            Toggle(L10n("Auto reconnect with backoff"), isOn: $draft.autoReconnect)
        }
        .formStyle(.grouped)
    }

    private func fileRow(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            TextField(label, text: binding)
            Button(L10n("Browse…")) { if let path = chooseFile() { binding.wrappedValue = path } }
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
        // Sentinel and Cluster are mutually exclusive connection modes (upstream
        // NewConnectionDialog.vue enforces the same rule).
        if draft.sentinelEnabled && draft.cluster {
            testResult = "Sentinel and Cluster are mutually exclusive — disable one."
            return
        }
        let config = makeConfig()
        // A freshly typed secret means we can trust the Keychain path again.
        if !draft.auth.isEmpty || !draft.sshPassword.isEmpty ||
           !draft.sshPassphrase.isEmpty || !draft.sentinelNodePassword.isEmpty {
            config.secretUnavailable = false
        }
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
                .font(store.monoFont(11))
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button(L10n("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selection == 0 ? connectionJSON : keyJSON, forType: .string)
                }
                Button(L10n("Save to File…")) { saveToFile() }
                Button(L10n("Load from File…")) { loadFromFile() }
                Button(L10n("Import DUMP snapshot…")) { store.importDumpSnapshot() }
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
