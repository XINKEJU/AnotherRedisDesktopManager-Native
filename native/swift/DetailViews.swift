import SwiftUI
import AppKit

// MARK: - Docked notices (Keychain migration / dropped socket)

/// Thin strip above the tab content. Shows the one-shot Keychain migration note
/// and the live reconnect state; stays hidden while everything is healthy.
struct ConnectionBanner: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if let notice = store.keychainMigrationNotice {
            row(icon: "key.fill", tint: .orange, text: notice) {
                Button(L10n("Dismiss")) { store.keychainMigrationNotice = nil }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Divider()
        } else if case .reconnecting(let attempt, let total) = store.activeConnectionState {
            row(icon: "arrow.triangle.2.circlepath", tint: .orange,
                text: L10n("Reconnecting") + " \(attempt)/\(total)…") {
                ProgressView().controlSize(.mini)
            }
            Divider()
        } else if case .failed(let reason) = store.activeConnectionState {
            row(icon: "exclamationmark.triangle.fill", tint: .red,
                text: L10n("Connection lost") + ": " + reason) {
                Button(L10n("Reconnect")) {
                    if let id = store.activeConnectionID { store.reconnect(id: id, manual: true) }
                }
                .font(.caption)
            }
            Divider()
        }
    }

    private func row<Accessory: View>(icon: String, tint: Color, text: String,
                                      @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.caption).lineLimit(2)
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
    }
}

// MARK: - Detail pane router (Tabs.vue / KeyDetail.vue)

struct DetailPane: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            // A labelled, scrollable tab strip replaces the old icon-only
            // segmented control that packed nine tabs into the title bar.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(MainTab.allCases) { tab in
                        Button { store.activeTab = tab } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab.icon).font(store.uiFont(11))
                                Text(L10n(tab.title)).font(store.uiFont(11))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(store.activeTab == tab
                                          ? Color.accentColor.opacity(0.18)
                                          : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(store.activeTab == tab ? Color.accentColor : Color.secondary)
                        .help(L10n(tab.title))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            ConnectionBanner()

            Group {
                switch store.activeTab {
                case .keys: KeyDetailView()
                case .cli: CLIView()
                case .status: StatusView()
                case .slowLog: SlowLogView()
                case .memory: MemoryView()
                case .cluster: ClusterView()
                case .pubsub: PubSubView()
                case .monitor: MonitorView()
                case .logs: CommandLogView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Key detail (KeyHeader.vue + 10 KeyContent*.vue + FormatViewer.vue)

struct KeyDetailView: View {
    @EnvironmentObject var store: AppStore
    @State private var showingHexInput = false
    @State private var pendingAction: ModuleAction?
    @State private var editingRow: KeyRow?
    @State private var addingRow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let key = store.selectedKey {
                keyHeader(key)
                Divider()
                if store.selectedKeyType == .string || store.selectedKeyType == .reJSON
                    || store.selectedKeyType == .vector || store.selectedKeyType == .unknown {
                    scalarEditor
                } else {
                    collectionEditor
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "key").font(store.uiFont(42)).foregroundStyle(.tertiary)
                    Text(L10n("Select a key to view and edit its value")).foregroundStyle(.secondary)
                    Text(L10n("10 data types · 15 format viewers · field-level editing"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $pendingAction) { action in
            TextInputSheet(title: L10n(action.title),
                           prompt: L10n(action.prompt ?? "Parameter"),
                           initial: "") { value in
                store.execute(action.build(store.selectedKey ?? "", value))
            }
            .environmentObject(store).frame(width: 480, height: 180)
        }
        .sheet(isPresented: $showingHexInput) {
            TextInputSheet(title: L10n("Paste hex"), prompt: L10n("Hex string"), initial: "") { value in
                store.pasteHexValue(value)
            }
            .environmentObject(store).frame(width: 460, height: 180)
        }
        .sheet(item: $editingRow) { row in
            RowEditorSheet(row: row) { field, value, extra, ttl in
                store.saveRow(row, field: field, value: value, extra: extra)
                if let seconds = ttl { store.setFieldTTL(field, seconds: seconds) }
            }
            .environmentObject(store)
            .frame(width: 520, height: 260)
        }
        .sheet(isPresented: $addingRow) {
            RowEditorSheet(row: KeyRow(id: "__new__", field: "", value: "")) { field, value, extra, ttl in
                store.saveRow(KeyRow(id: "__new__", field: field, value: value), field: field, value: value, extra: extra)
                if let seconds = ttl { store.setFieldTTL(field, seconds: seconds) }
            }
            .environmentObject(store)
            .frame(width: 520, height: 260)
        }
    }

    @ViewBuilder
    private func keyHeader(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "key.fill").foregroundStyle(.blue)
                Text(key).font(store.uiFont(15, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(typeName(store.selectedKeyType)).font(.caption).padding(.horizontal, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                Text(store.ttlInMilliseconds ? "PTTL \(store.selectedKeyTTLMillis) ms" : "TTL \(store.selectedKeyTTL)").font(.caption)
                if store.selectedKeyType == .hash { Text("HLEN \(store.hashLen)").font(.caption) }
            }
            HStack(spacing: 8) {
                Button(L10n("Refresh")) { store.reloadKeyDetail() }
                Button(L10n("Rename")) { store.showingRename = true }
                Button(L10n("TTL")) { store.showingTTL = true }
                Button(L10n("PERSIST")) { store.setTTL(-1) }
                Button(L10n("DUMP")) { store.dumpKey(key) }
                Button(L10n("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.editorText, forType: .string)
                }
                Button(L10n("JSON Editor")) { store.showingJsonEditor = true }
                Spacer()
                Button(L10n("Delete"), role: .destructive) { store.deleteKeys([key]) }
            }
            .font(store.uiFont(11))
        }
        .padding(12)
    }

    // MARK: String / ReJSON / Vector / unknown -> large editor + viewers

    private var scalarEditor: some View {
        VStack(spacing: 0) {
            if store.selectedKeyType == .reJSON {
                HStack {
                    Text(L10n("JSON path")).font(.caption)
                    TextField(L10n("$"), text: $store.jsonPath).textFieldStyle(.roundedBorder).frame(width: 200)
                    Button(L10n("Load path")) { store.loadTypedValue() }
                    Spacer()
                }.padding(8)
            }
            HStack {
                Picker(L10n("Viewer"), selection: $store.viewerName) {
                    ForEach(store.viewers, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 190)
                .labelsHidden()
                .onChange(of: store.viewerName) { _, _ in store.renderValue() }
                Button(L10n("Auto detect")) {
                    store.viewerName = ARDMFormatters.detectViewer(for: store.keyRawValue)
                    store.renderValue()
                }
                Button(L10n("Binary input…")) { chooseBinaryFile() }
                Button(L10n("Paste hex…")) { showingHexInput = true }
                Button(L10n("Protobuf schema")) { store.loadProtobufSchema() }
                Spacer()
                Button(L10n("Save")) { store.saveEditorText() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ARDMFormatters.encodableViewers().contains(store.viewerName))
                    .help(L10n("Save re-encodes the value using the active viewer"))
            }
            .padding(8)

            if store.selectedKeyType == .vector {
                HStack(spacing: 8) {
                    Text(L10n("Quantization")).font(.caption)
                    Picker("", selection: $store.vectorQuantization) {
                        ForEach(["NOQUANT", "Q8", "BIN"], id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 120).labelsHidden()
                    Text(store.redisMajor < 8
                         ? L10n("Vector type requires Redis 8.0+")
                         : L10n("Applied when adding vectors with VADD"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
            }

            HSplitView {
                TextEditor(text: $store.editorText)
                    .font(store.monoFont(store.fontSize))
                    .border(Color.secondary.opacity(0.25))
                    .frame(minWidth: 260)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Rendered (\(store.viewerName))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n("Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.renderedValue, forType: .string)
                        }.font(.caption)
                    }
                    ScrollView {
                        Text(highlighted(store.renderedValue, size: store.scaled(store.fontSize - 1)))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .border(Color.secondary.opacity(0.25))
                }
                .frame(minWidth: 260)
            }
            .padding(8)
        }
    }

    // MARK: Hash / List / Set / ZSet / Stream / TimeSeries / Array -> editable rows

    private var collectionEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n("Offset")).font(.caption)
                TextField("", value: $store.rowOffset, format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                Text(L10n("Limit")).font(.caption)
                TextField("", value: $store.rowLimit, format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                Button(L10n("Load page")) { store.loadTypedValue() }
                if !store.rowScanFinished {
                    Button(L10n("Load more rows")) { store.scanRows(reset: false) }
                }
                TextField(L10n("Pattern (e.g. session:*)"), text: $store.rowSearchPattern)
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                    .onSubmit { store.loadTypedValue() }
                Button(L10n("Previous")) { store.rowOffset = max(0, store.rowOffset - store.rowLimit); store.loadTypedValue() }
                Button(L10n("Next")) { store.rowOffset += store.rowLimit; store.loadTypedValue() }
                Spacer()
                Button(L10n("Add row")) { addingRow = true }
                if store.selectedKeyType == .stream { streamGroupMenu }
                if store.selectedKeyType == .stream {
                    Toggle(L10n("Reverse (XREVRANGE)"), isOn: $store.streamReverse)
                        .toggleStyle(.checkbox)
                        .onChange(of: store.streamReverse) { _, _ in store.loadTypedValue() }
                }
                moduleMenu
                if store.selectedKeyType == .timeSeries {
                    Toggle(L10n("Reverse range"), isOn: $store.timeSeriesReverse)
                        .toggleStyle(.checkbox)
                        .onChange(of: store.timeSeriesReverse) { _, _ in store.loadTypedValue() }
                }
                Button(L10n("Refresh")) { store.reloadKeyDetail() }
            }
            .padding(8)

            // TimeSeries aggregation / value filtering (TS.RANGE / TS.REVRANGE options).
            if store.selectedKeyType == .timeSeries {
                HStack(spacing: 8) {
                    Text(L10n("Aggregation")).font(.caption)
                    Picker("", selection: $store.tsAggregation) {
                        ForEach(["None", "avg", "sum", "min", "max", "range", "count", "first", "last", "std.p", "std.s", "var.p", "var.s"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .frame(width: 100).labelsHidden()
                    Text(L10n("Bucket")).font(.caption)
                    TextField("", text: $store.tsBucket).frame(width: 80).textFieldStyle(.roundedBorder)
                    Text(L10n("Filter min")).font(.caption)
                    TextField("", text: $store.tsFilterMin).frame(width: 80).textFieldStyle(.roundedBorder)
                    Text(L10n("max")).font(.caption)
                    TextField("", text: $store.tsFilterMax).frame(width: 80).textFieldStyle(.roundedBorder)
                    Button(L10n("Apply")) { store.loadTypedValue() }
                    Button(L10n("TS.INFO")) { store.loadTimeSeriesInfo() }
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.bottom, 6)
            }

            HStack {
                Text(columnTitle(0)).font(.caption.bold()).frame(width: 180, alignment: .leading)
                Text(columnTitle(1)).font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
                if store.selectedKeyType == .zSet { Text(L10n("Score")).font(.caption.bold()).frame(width: 100) }
                if store.selectedKeyType == .hash { Text(L10n("Field TTL")).font(.caption.bold()).frame(width: 80) }
                Text("").frame(width: 90)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08))
            Divider()

            List(store.keyRows) { row in
                HStack {
                    Text(row.field).font(store.monoFont(11))
                        .lineLimit(1).frame(width: 180, alignment: .leading)
                    Text(row.value).font(store.monoFont(11))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if store.selectedKeyType == .zSet {
                        Text(row.extra).font(store.monoFont(11)).frame(width: 100)
                    }
                    if store.selectedKeyType == .hash {
                        Text(store.fieldTTLs[row.field].map(String.init) ?? "–")
                            .font(store.monoFont(11)).frame(width: 80)
                    }
                    Button(L10n("Edit")) { editingRow = row }.font(.caption)
                    Button(L10n("Delete")) { store.deleteRow(row) }.font(.caption).foregroundStyle(.red)
                }
                .contextMenu {
                    Button(L10n("Copy value")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.value, forType: .string)
                    }
                    Button(L10n("View as Hex")) {
                        store.viewerName = "Hex"
                        store.keyRawValue = row.raw
                        store.renderValue()
                    }
                    Button(L10n("Copy write command")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.writeCommandString(for: row), forType: .string)
                    }
                    Button(L10n("Delete row"), role: .destructive) { store.deleteRow(row) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            if store.selectedKeyType == .stream && (!store.streamGroups.isEmpty || !store.streamConsumers.isEmpty) {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n("Consumer groups")).font(.caption.bold())
                    ScrollView {
                        ForEach(store.streamGroups.indices, id: \.self) { i in
                            let g = store.streamGroups[i]
                            Text("• \(ardmString(g["name"])) · consumers \(ardmString(g["consumers"])) · pending \(ardmString(g["pending"])) · last \(ardmString(g["last-delivered-id"]))")
                                .font(store.monoFont(10))
                        }
                        ForEach(store.streamConsumers.indices, id: \.self) { i in
                            let c = store.streamConsumers[i]
                            Text("      consumer \(ardmString(c["name"])) · pending \(ardmString(c["pending"])) · idle \(ardmString(c["idle"]))ms")
                                .font(store.monoFont(10)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxHeight: 110)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }

            if store.selectedKeyType == .timeSeries && !store.tsInfo.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("TS.INFO").font(.caption.bold())
                    ScrollView {
                        ForEach(store.tsInfo.indices, id: \.self) { i in
                            HStack {
                                Text(store.tsInfo[i].first ?? "").frame(width: 170, alignment: .leading)
                                Text(store.tsInfo[i].count > 1 ? store.tsInfo[i][1] : "")
                                Spacer()
                            }
                            .font(store.monoFont(10))
                        }
                    }
                    .frame(maxHeight: 120)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var moduleMenu: some View {
        let actions = store.moduleActions()
        if !actions.isEmpty {
            Menu(L10n("Advanced commands")) {
                ForEach(actions) { action in
                    Button(L10n(action.title)) {
                        if action.prompt == nil {
                            store.execute(action.build(store.selectedKey ?? "", ""))
                        } else {
                            pendingAction = action
                        }
                    }
                }
            }
            .font(.caption)
        }
    }

    private var streamGroupMenu: some View {
        Menu(L10n("Consumer groups")) {
            Button(L10n("XINFO GROUPS")) { store.streamGroup("INFO", group: "") }
            Button(L10n("CREATE group")) { store.streamGroup("CREATE", group: "ardm-group") }
            Button(L10n("READ group")) { store.streamGroup("READ", group: "ardm-group") }
            Button(L10n("ACK 0-0")) { store.streamGroup("ACK", group: "ardm-group", id: "0-0") }
            Button(L10n("DELCONSUMER")) { store.streamGroup("DESTROY", group: "ardm-group") }
        }
        .font(.caption)
    }

    private func columnTitle(_ column: Int) -> String {
        switch store.selectedKeyType {
        case .hash: return column == 0 ? "Field" : "Value"
        case .zSet: return column == 0 ? "Member" : "Value"
        case .list, .array: return column == 0 ? "Index" : "Value"
        case .set: return column == 0 ? "Index" : "Member"
        case .stream: return column == 0 ? "Entry ID" : "Fields"
        case .timeSeries: return column == 0 ? "Timestamp" : "Sample"
        default: return column == 0 ? "Key" : "Value"
        }
    }

    private func chooseBinaryFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        store.keyRawValue = data
        store.editorText = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
        store.viewerName = "Hex"
        store.renderValue()
    }
}

// MARK: - Row editor

struct RowEditorSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let row: KeyRow
    let onConfirm: (String, String, String, Int?) -> Void
    @State private var field = ""
    @State private var value = ""
    @State private var extra = ""
    @State private var ttl = ""

    var body: some View {
        VStack(spacing: 14) {
            Text(row.id == "__new__" ? "Add row" : "Edit row").font(.headline)
            Form {
                TextField(L10n("Field / index / member"), text: $field)
                TextField(L10n("Value"), text: $value)
                if store.selectedKeyType == .zSet { TextField(L10n("Score"), text: $extra) }
                if store.selectedKeyType == .hash {
                    TextField(L10n("Field TTL (seconds, -1 to persist)"), text: $ttl)
                }
            }
            HStack {
                Button(L10n("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n("Save")) { onConfirm(field, value, extra, ttl.isEmpty ? nil : Int(ttl)); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .onAppear {
            field = row.field; value = row.value; extra = row.extra
            ttl = row.id == "__new__" ? "" : (store.fieldTTLs[row.field].map(String.init) ?? "")
        }
    }
}

// MARK: - JsonEditor.vue replacement

struct JsonEditorSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var validation = ""

    var body: some View {
        VStack(spacing: 10) {
            Text(L10n("JSON Editor")).font(.headline)
            HStack {
                Button(L10n("Pretty")) { pretty() }
                Button(L10n("Minify")) { minify() }
                Button(L10n("Validate")) { validate() }
                Spacer()
                Text(validation).font(.caption).foregroundStyle(validation.hasPrefix("OK") ? .green : .red)
            }
            TextEditor(text: $text)
                .font(store.monoFont(12))
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button(L10n("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n("Save to key")) {
                    store.editorText = text
                    store.saveEditorText()
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .onAppear { text = store.editorText }
    }

    /// Formatting goes through the token-preserving formatter so integers beyond
    /// 2^53 are not rounded through Double (NSJSONSerialization would do that).
    private func pretty() {
        guard let formatted = ARDMFormatters.formatJSON(Data(text.utf8), pretty: true) else {
            validation = "Invalid JSON"; return
        }
        text = formatted
        validation = "OK — formatted"
    }

    private func minify() {
        guard let compact = ARDMFormatters.formatJSON(Data(text.utf8), pretty: false) else {
            validation = "Invalid JSON"; return
        }
        text = compact
        validation = "OK — minified"
    }

    private func validate() {
        validation = ARDMFormatters.validateJSON(Data(text.utf8)) ? "OK — valid JSON" : "Invalid JSON"
    }
}

// MARK: - CustomFormatter.vue management

struct FormatterManagerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var selectedIndex: Int? = 0
    @State private var name = ""
    @State private var script = ""
    @State private var testResult = ""

    private var index: Int { selectedIndex ?? 0 }

    var body: some View {
        VStack(spacing: 10) {
            Text(L10n("Custom Formatters")).font(.headline)
            HStack(spacing: 0) {
                List(Array(store.customFormatters.indices), id: \.self, selection: $selectedIndex) { index in
                    Text(store.customFormatters[index]["name"] ?? "untitled")
                        .onTapGesture { select(index) }
                }
                .frame(width: 170)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L10n("Name"), text: $name).textFieldStyle(.roundedBorder)
                    Text(L10n("JavaScript runs in JavaScriptCore with `bytes` (Uint8Array)."))
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $script)
                        .font(store.monoFont(11))
                        .border(Color.secondary.opacity(0.3))
                    HStack {
                        Button(L10n("Run on current value")) { run() }
                        Text(testResult).font(.caption).lineLimit(2)
                        Spacer()
                        Button(L10n("Save")) { save() }.buttonStyle(.borderedProminent)
                        Button(L10n("Add")) { add() }
                        Button(L10n("Delete")) { remove() }
                    }
                }
                .padding(8)
            }
            HStack {
                Button(L10n("Use as active viewer")) {
                    store.customViewerScript = script
                    store.viewerName = "Custom"
                    store.renderValue()
                }
                Spacer()
                Button(L10n("Close")) { dismiss() }
            }
        }
        .padding(16)
        .onAppear { select(0) }
    }

    private func select(_ index: Int) {
        selectedIndex = index
        guard store.customFormatters.indices.contains(index) else { return }
        name = store.customFormatters[index]["name"] ?? ""
        script = store.customFormatters[index]["script"] ?? ""
    }

    private func save() {
        guard store.customFormatters.indices.contains(index) else { return }
        var items = store.customFormatters
        items[index] = ["name": name, "script": script]
        store.customFormatters = items
    }

    private func add() {
        var items = store.customFormatters
        items.append(["name": "Formatter \(items.count + 1)", "script": "return new TextDecoder().decode(bytes);"])
        store.customFormatters = items
        select(items.count - 1)
    }

    private func remove() {
        guard store.customFormatters.count > 1, store.customFormatters.indices.contains(index) else { return }
        var items = store.customFormatters
        items.remove(at: index)
        store.customFormatters = items
        select(0)
    }

    private func run() {
        var error: NSError?
        let result = ARDMFormatters.renderCustom(store.keyRawValue, script: script, error: &error)
        testResult = error?.localizedDescription ?? String(result.prefix(160))
    }
}
