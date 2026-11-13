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
            // Text-only tabs with an underline, like the reference clients. The
            // nine coloured glyphs that used to sit here turned the one strip
            // that never changes into the loudest row in the window.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(MainTab.allCases) { tab in
                        let active = store.activeTab == tab
                        Button { store.activeTab = tab } label: {
                            Text(L10n(tab.title))
                                .font(.system(size: ARDMFont.small, weight: active ? .medium : .regular))
                                .foregroundStyle(active ? Color.primary : Color.secondary)
                                .padding(.horizontal, 9)
                                .frame(height: 28)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(active ? Color.accentColor : Color.clear)
                                        .frame(height: 1.5)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n(tab.title))
                        .accessibilityLabel(L10n(tab.title))
                        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("detail.tab." + tab.title)
                    }
                }
                .padding(.horizontal, 6)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("detail.tabs")

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
    @State private var showPreview = false

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
                VStack(spacing: 10) {
                    Image(systemName: "key")
                        .font(.system(size: ARDMIcon.emptyState, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.quaternary)
                    Text(L10n("Select a key to view and edit its value"))
                        .font(store.uiFont(12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(L10n("10 data types · 15 format viewers · field-level editing"))
                        .font(store.uiFont(10.5))
                        .foregroundStyle(.tertiary)
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
        .onChange(of: store.selectedKey) { _, _ in showPreview = false }
    }

    /// TTL and type-specific counters share one line: "TTL -1 · HLEN 3" reads as
    /// one piece of metadata, while two adjacent Texts read as two unrelated
    /// numbers.
    private var keyMetadata: String {
        var parts = [store.ttlInMilliseconds
                     ? "PTTL \(store.selectedKeyTTLMillis) ms"
                     : "TTL \(store.selectedKeyTTL)"]
        if store.selectedKeyType == .hash { parts.append("HLEN \(store.hashLen)") }
        return parts.joined(separator: " · ")
    }

    /// Title, type and TTL on one line, plus two icon actions and one overflow
    /// menu. The previous version printed eight text buttons under the title,
    /// which filled the whole width and still wrapped out of view on a narrow
    /// detail pane.
    /// What the size column should say: bytes for a scalar, item count for a
    /// collection. Reading "0 B" next to a 400-field hash looked like a bug.
    private var valueSizeText: String {
        switch store.selectedKeyType {
        case .string, .reJSON, .vector, .unknown, .timeSeries:
            return ARDMFormat.bytes(store.keyRawValue.count)
        default:
            return "\(store.keyRows.count) " + L10n("items")
        }
    }

    @ViewBuilder
    private func keyHeader(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // The name is the one string in the pane that has to be read
                // character by character, so it is the only one set in mono.
                Text(key)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)

                ARDMIconButton(systemName: "arrow.clockwise", help: L10n("Refresh")) {
                    store.reloadKeyDetail()
                }
                headerDivider
                ARDMIconButton(systemName: "doc.on.doc", help: L10n("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.editorText, forType: .string)
                }
                ARDMIconButton(systemName: "square.and.pencil", help: L10n("JSON Editor")) {
                    store.showingJsonEditor = true
                }
                ARDMIconMenu(help: L10n("More actions")) {
                    Button { store.showingRename = true } label: {
                        Label(L10n("Rename"), systemImage: "character.cursor.ibeam")
                    }
                    Button { store.showingTTL = true } label: {
                        Label(L10n("TTL"), systemImage: "clock")
                    }
                    Button { store.setTTL(-1) } label: {
                        Label(L10n("PERSIST"), systemImage: "pin")
                    }
                    Button { store.dumpKey(key) } label: {
                        Label(L10n("DUMP"), systemImage: "arrow.down.doc")
                    }
                    Divider()
                    Button(role: .destructive) { store.deleteKeys([key]) } label: {
                        Label(L10n("Delete"), systemImage: "trash")
                    }
                }
                .accessibilityIdentifier("detail.key.more")
                headerDivider
                ARDMIconButton(systemName: "trash", help: L10n("Delete")) {
                    store.deleteKeys([key])
                }
            }

            // Type, size and expiry as one plain meta line, the way the
            // reference header prints them ("STRING · 大小: 496 B · TTL: 23小时").
            // The type word carries the colour; no chip is needed here.
            HStack(spacing: 6) {
                Text(typeName(store.selectedKeyType).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(store.selectedKeyType.tint)
                Text("·").foregroundStyle(.quaternary)
                Text("\(L10n("Size")): \(valueSizeText)")
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.quaternary)
                Text("TTL: \(ARDMFormat.ttlLong(store.selectedKeyTTL))")
                    .foregroundStyle(ttlHeaderTint(store.selectedKeyTTL))
                Spacer(minLength: 4)
            }
            .font(.system(size: 10.5))
            .monospacedDigit()
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 1, height: 14)
            .accessibilityHidden(true)
    }

    private func ttlHeaderTint(_ ttl: Int) -> Color {
        switch ttl {
        case -1: return .secondary
        case 0..<300: return Color(red: 0.85, green: 0.30, blue: 0.26)
        case 300..<3600: return Color(red: 0.86, green: 0.55, blue: 0.16)
        default: return .secondary
        }
    }

    // MARK: String / ReJSON / Vector / unknown -> format bars + code surface

    /// Decode transforms and render views. The reference client splits these
    /// into two rows because they answer different questions ("is this gzipped?"
    /// and "show it as JSON"), and a single 15-item picker answered neither.
    private let decodeFormats: [ViewerChip] = [
        ViewerChip(id: "Gzip", title: "Gzip"), ViewerChip(id: "Deflate", title: "Deflate"),
        ViewerChip(id: "Brotli", title: "Brotli"), ViewerChip(id: "Msgpack", title: "Msgpack"),
        ViewerChip(id: "Pickle", title: "Pickle"), ViewerChip(id: "PHPSerialize", title: "PHP"),
        ViewerChip(id: "JavaSerialize", title: "Java"), ViewerChip(id: "Protobuf", title: "Proto")
    ]

    private let viewFormats: [ViewerChip] = [
        ViewerChip(id: "Text", title: "Text"), ViewerChip(id: "Json", title: "JSON"),
        ViewerChip(id: "Hex", title: "Hex"), ViewerChip(id: "Binary", title: "Binary"),
        ViewerChip(id: "OverSize", title: "OverSize")
    ]

    private var scalarEditor: some View {
        VStack(spacing: 0) {
            if store.selectedKeyType == .reJSON {
                HStack(spacing: 6) {
                    Text(L10n("JSON path")).font(.system(size: ARDMFont.micro)).foregroundStyle(.secondary)
                    TextField(L10n("$"), text: $store.jsonPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: ARDMFont.small))
                        .frame(width: 200)
                        .accessibilityLabel(L10n("JSON path field"))
                    Button(L10n("Load path")) { store.loadTypedValue() }
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            formatBar
            Divider()

            if store.viewerName == "OverSize" {
                oversizeBar
            }

            if store.selectedKeyType == .vector {
                vectorBar
            }

            codeSurface

            if canEditValue && !showsRenderedPane {
                editorFooter
            }
        }
    }

    private var formatBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(L10n("Decode"))
                    .font(.system(size: ARDMFont.micro))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(decodeFormats) { chip in
                            ARDMChip(title: chip.title, selected: store.viewerName == chip.id) {
                                selectViewer(chip.id)
                            }
                        }
                    }
                }
                Button(L10n("Auto")) {
                    selectViewer(ARDMFormatters.detectViewer(for: store.keyRawValue))
                }
                .buttonStyle(.plain)
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.secondary)
                .help(L10n("Auto detect"))
                Button(L10n("Run")) { store.renderValue() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(L10n("Re-render with the selected decoder"))
            }
            .frame(height: 26)
            .padding(.horizontal, 10)

            HStack(spacing: 4) {
                Text(L10n("View"))
                    .font(.system(size: ARDMFont.micro))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(viewFormats) { chip in
                            ARDMChip(title: chip.title, selected: store.viewerName == chip.id) {
                                selectViewer(chip.id)
                            }
                        }
                    }
                }
                // "原文 / 渲染": the same bytes read two ways. The eye button that
                // used to live in the overflow row did this invisibly.
                Picker("", selection: $showPreview) {
                    Text(L10n("Raw")).tag(false)
                    Text(L10n("Rendered")).tag(true)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 108)
                .labelsHidden()
                .disabled(canEditValue == false)
                .accessibilityLabel(L10n("Rendered"))
            }
            .frame(height: 26)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        // One glass slab behind both chip rows (macOS 26+): the chips read as a
        // single floating control instead of paint on the detail background.
        .padding(.vertical, 3)
        .ardmGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    private func selectViewer(_ viewer: String) {
        store.viewerName = viewer
        store.renderValue()
    }

    private var oversizeBar: some View {
        HStack(spacing: 8) {
            Text(L10n("Chunk")).font(.system(size: ARDMFont.micro)).foregroundStyle(.secondary)
            Button("◀") {
                store.oversizeOffset = max(0, store.oversizeOffset - store.oversizeChunkSize)
                store.renderValue()
            }
            .disabled(store.oversizeOffset == 0)
            .accessibilityLabel(L10n("Previous chunk"))
            TextField("", value: $store.oversizeOffset, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .accessibilityLabel(L10n("Chunk offset"))
                .onSubmit { store.renderValue() }
            Button("▶") {
                store.oversizeOffset += store.oversizeChunkSize
                store.renderValue()
            }
            .disabled(store.oversizeOffset + store.oversizeChunkSize >= store.keyRawValue.count)
            .accessibilityLabel(L10n("Next chunk"))
            Text("\(store.keyRawValue.count) " + L10n("bytes"))
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private var vectorBar: some View {
        HStack(spacing: 8) {
            Text(L10n("Quantization")).font(.system(size: ARDMFont.micro)).foregroundStyle(.secondary)
            Picker("", selection: $store.vectorQuantization) {
                ForEach(["NOQUANT", "Q8", "BIN"], id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 110).labelsHidden()
            .accessibilityLabel(L10n("Quantization"))
            Text(store.redisMajor < 8
                 ? L10n("Vector type requires Redis 8.0+")
                 : L10n("Applied when adding vectors with VADD"))
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    /// One surface for both modes: the editable buffer or the rendered view of
    /// it. Both get the line-number gutter and JSON colouring, which is the
    /// single most recognisable part of the reference layout.
    private var codeSurface: some View {
        let shown = showsRenderedPane ? store.renderedValue : store.editorText
        // GeometryReader pins the NSTextView wrapper to exactly the rectangle
        // the VStack allots. Left free, the scroll view reports a fitting size
        // larger than its slot and its gutter bleeds over the editor footer
        // and the status bar.
        return GeometryReader { geo in
            ARDMCodeView(
                text: showsRenderedPane ? $store.renderedValue : $store.editorText,
                isEditable: !showsRenderedPane,
                fontSize: store.scaled(13),
                fontName: store.fontFamily,
                language: ARDMCodeLanguage.detect(shown, viewer: store.viewerName),
                identifier: "detail.editor"
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Discard / save, bottom right, exactly where the reference puts them. The
    /// save button used to sit in the format row, mixed in with the viewers.
    private var editorFooter: some View {
        HStack(spacing: 8) {
            Text("\(store.keyRawValue.count) " + L10n("bytes"))
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            Button(L10n("Revert")) { store.reloadKeyDetail() }
                .controlSize(.small)
            Button(L10n("Save")) { store.saveEditorText() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canEditValue)
                .help(L10n("Save re-encodes the value using the active viewer"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .ardmGlass(in: Rectangle())
    }

    private var canEditValue: Bool {
        ARDMFormatters.encodableViewers().contains(store.viewerName)
    }

    /// Rendered-only when the viewer cannot encode back (gzip, pickle, …) or when
    /// the eye is on; otherwise the editable text is the primary surface.
    private var showsRenderedPane: Bool { showPreview || !canEditValue }

    // MARK: Hash / List / Set / ZSet / Stream / TimeSeries / Array -> editable rows

    private var collectionEditor: some View {
        VStack(spacing: 0) {
            // Paging, refresh and "add" stay on the bar; the per-type extras
            // (stream groups, TimeSeries options, module commands) moved into one
            // menu. The old single row carried up to eleven controls and had to be
            // read at 10pt to fit a normal window.
            HStack(spacing: 6) {
                Text(L10n("Offset")).font(.caption).foregroundStyle(.secondary)
                TextField("", value: $store.rowOffset, format: .number)
                    .frame(width: 54).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n("Offset"))
                Text(L10n("Limit")).font(.caption).foregroundStyle(.secondary)
                TextField("", value: $store.rowLimit, format: .number)
                    .frame(width: 54).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n("Limit"))
                ARDMIconButton(systemName: "arrow.clockwise", help: L10n("Refresh")) {
                    store.reloadKeyDetail()
                }
                ARDMIconButton(systemName: "chevron.left", help: L10n("Previous")) {
                    store.rowOffset = max(0, store.rowOffset - store.rowLimit)
                    store.loadTypedValue()
                }
                .disabled(store.rowOffset == 0)
                ARDMIconButton(systemName: "chevron.right", help: L10n("Next")) {
                    store.rowOffset += store.rowLimit
                    store.loadTypedValue()
                }
                TextField(L10n("Pattern"), text: $store.rowSearchPattern)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 70, maxWidth: 150)
                    .accessibilityLabel(L10n("Pattern"))
                    .onSubmit { store.loadTypedValue() }
                Spacer(minLength: 4)
                Button {
                    addingRow = true
                } label: {
                    Label(L10n("Add row"), systemImage: "plus")
                }
                .controlSize(.small)
                collectionMenu
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
                    .accessibilityLabel(L10n("Aggregation"))
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

            HStack(spacing: 8) {
                Text(columnTitle(0))
                    .font(.system(size: ARDMFont.micro, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: store.selectedKeyType == .zSet ? .infinity : 180,
                           alignment: .leading)
                // A zset row stores its score twice (value and extra), so the
                // old layout drew two identical numeric columns.
                if store.selectedKeyType != .zSet {
                    Text(columnTitle(1))
                        .font(.system(size: ARDMFont.micro, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if store.selectedKeyType == .zSet {
                    Text(L10n("Score"))
                        .font(.system(size: ARDMFont.micro, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .trailing)
                }
                if store.selectedKeyType == .hash {
                    Text(L10n("Field TTL"))
                        .font(.system(size: ARDMFont.micro, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Color.secondary.opacity(0.06))
            Divider()

            // Row actions moved into the context menu and a double-click: the old
            // layout put a "编辑" and a red "删除" button on every single row, which
            // turned a five-field hash into ten competing buttons.
            // `alternatesRowBackgrounds` paints its zebra pattern over the whole
            // scroll area, so a three-field hash showed ten grey bands of empty
            // space under the data. Striping the real rows only fixes that.
            List(Array(store.keyRows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 8) {
                    Text(row.field).font(store.monoFont(11))
                        .lineLimit(1)
                        .frame(maxWidth: store.selectedKeyType == .zSet ? .infinity : 180,
                               alignment: .leading)
                    if store.selectedKeyType != .zSet {
                        Text(row.value).font(store.monoFont(11))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.selectedKeyType == .zSet {
                        Text(row.extra)
                            .font(store.monoFont(11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                    }
                    if store.selectedKeyType == .hash {
                        Text(store.fieldTTLs[row.field].map(String.init) ?? "–")
                            .font(store.monoFont(11))
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editingRow = row }
                .help(L10n("Double-click to edit"))
                .contextMenu {
                    Button(L10n("Edit")) { editingRow = row }
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
                .listRowBackground(index.isMultiple(of: 2)
                                   ? Color.secondary.opacity(0.045)
                                   : Color.clear)
            }
            .listStyle(.inset)

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

    /// One overflow menu for everything that used to be a separate control in
    /// the row: load-more, zset batch, stream groups/reverse, TimeSeries reverse
    /// and the Redis-module commands.
    private var collectionMenu: some View {
        ARDMIconMenu(help: L10n("More actions")) {
            if !store.rowScanFinished {
                Button { store.scanRows(reset: false) } label: {
                    Label(L10n("Load more rows"), systemImage: "arrow.down.circle")
                }
            }
            if store.selectedKeyType == .zSet {
                Button { store.showingZSetBatch = true } label: {
                    Label(L10n("Batch…"), systemImage: "square.stack.3d.up")
                }
            }
            if !store.moduleActions().isEmpty {
                Menu {
                    ForEach(store.moduleActions()) { action in
                        Button(L10n(action.title)) {
                            if action.prompt == nil {
                                store.execute(action.build(store.selectedKey ?? "", ""))
                            } else {
                                pendingAction = action
                            }
                        }
                    }
                } label: {
                    Label(L10n("Advanced commands"), systemImage: "terminal")
                }
            }
            if store.selectedKeyType == .stream {
                Menu {
                    Button(L10n("XINFO GROUPS")) { store.streamGroup("INFO", group: "") }
                    Button(L10n("CREATE group")) { store.streamGroup("CREATE", group: "ardm-group") }
                    Button(L10n("READ group")) { store.streamGroup("READ", group: "ardm-group") }
                    Button(L10n("ACK 0-0")) { store.streamGroup("ACK", group: "ardm-group", id: "0-0") }
                    Button(L10n("DELCONSUMER")) { store.streamGroup("DESTROY", group: "ardm-group") }
                } label: {
                    Label(L10n("Consumer groups"), systemImage: "person.2")
                }
                Button {
                    store.streamReverse.toggle()
                    store.loadTypedValue()
                } label: {
                    Label(L10n("Reverse (XREVRANGE)"),
                          systemImage: store.streamReverse ? "checkmark.circle.fill" : "circle")
                }
            }
            if store.selectedKeyType == .timeSeries {
                Button {
                    store.timeSeriesReverse.toggle()
                    store.loadTypedValue()
                } label: {
                    Label(L10n("Reverse range"),
                          systemImage: store.timeSeriesReverse ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        .accessibilityIdentifier("detail.rows.more")
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

// MARK: - ZSet batch edit (pattern → action over the loaded member page)

struct ZSetBatchSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    private var matches: [String] { store.zsetBatchMembers() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n("ZSet Batch Edit")).font(.headline)
            Text(L10n("Applies to the rows currently loaded for this key (max 1000)."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(L10n("Member pattern")).frame(width: 120, alignment: .leading)
                TextField("*", text: $store.zsetBatchPattern)
                    .textFieldStyle(.roundedBorder)
                Text("\(matches.count) " + L10n("match"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text(L10n("Action")).frame(width: 120, alignment: .leading)
                Picker("", selection: $store.zsetBatchAction) {
                    Text(L10n("Delete")).tag("Delete")
                    Text(L10n("Set score")).tag("Set score")
                    Text(L10n("Add delta")).tag("Add delta")
                }
                .labelsHidden()
                .accessibilityLabel(L10n("Action"))
                .frame(width: 180)
            }

            if store.zsetBatchAction != "Delete" {
                HStack(spacing: 8) {
                    Text(L10n("Score")).frame(width: 120, alignment: .leading)
                    TextField("0", text: $store.zsetBatchScore)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }

            Spacer()
            HStack {
                Button(L10n("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n("Apply")) { store.applyZSetBatch() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(matches.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 470, height: 280)
    }
}

// MARK: - Byte-level hex grid (HexEditor.vue replacement)

struct HexEditorSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var selected = 0

    private let perRow = 16

    private var rowCount: Int {
        max(1, (store.hexBytes.count + perRow - 1) / perRow)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<rowCount, id: \.self) { row in
                        rowView(row)
                    }
                }
                .padding(10)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L10n("Hex editor")).font(.headline)
                Text(store.selectedKey ?? "").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.hexBytes.count + store.hexTail.count) " + L10n("bytes"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if store.hexWasTruncated {
                Text(L10n("Only the first 8192 bytes are editable; the remaining bytes are preserved on save."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func rowView(_ row: Int) -> some View {
        HStack(spacing: 3) {
            Text(String(format: "%08X", row * perRow))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            ForEach(0..<perRow, id: \.self) { column in
                let index = row * perRow + column
                if index < store.hexBytes.count {
                    TextField("", text: byteBinding(index))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 24, height: 18)
                        .background(selected == index
                                    ? Color.accentColor.opacity(0.30)
                                    : Color.secondary.opacity(0.07))
                        .onTapGesture { selected = index }
                } else {
                    Color.clear.frame(width: 24, height: 18)
                }
            }
            Text(ascii(row))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(L10n("Insert byte")) { store.insertHexByte(at: selected) }
            Button(L10n("Delete byte")) {
                store.deleteHexByte(at: selected)
                selected = max(0, min(selected, store.hexBytes.count - 1))
            }
            Spacer()
            Button(L10n("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L10n("Save")) { store.saveHexEditor() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    private func byteBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard store.hexBytes.indices.contains(index) else { return "" }
                return String(format: "%02X", store.hexBytes[index])
            },
            set: { text in
                let cleaned = text.uppercased().filter { $0.isHexDigit }
                guard !cleaned.isEmpty, let value = UInt8(cleaned.suffix(2), radix: 16) else { return }
                store.setHexByte(at: index, to: value)
            }
        )
    }

    private func ascii(_ row: Int) -> String {
        let start = row * perRow
        let end = min(start + perRow, store.hexBytes.count)
        guard start < end else { return "" }
        return store.hexBytes[start..<end].map { byte in
            (byte >= 0x20 && byte < 0x7F) ? String(UnicodeScalar(byte)) : "."
        }.joined()
    }
}

/// One format chip. A tuple would be shorter, but `ForEach` needs an `Identifiable`
/// element and key paths into tuple members are not supported in Swift.
struct ViewerChip: Identifiable {
    let id: String
    let title: String
}
