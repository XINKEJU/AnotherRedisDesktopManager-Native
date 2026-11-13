import SwiftUI
import AppKit

// MARK: - Key list (KeyList.vue / KeyListNormal.vue / KeyListVirtualTree.vue)

struct KeyBrowserView: View {
    @EnvironmentObject var store: AppStore
    @State private var treeSelection: String?
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showingFilter = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // One compact row. The old layout stacked four permanent bars
            // (search / count / filter / sort header) on top of a 260–330pt wide
            // column, which left almost no room for keys. Everything that is not
            // search, refresh or the overflow menu now lives inside that menu.
            HStack(spacing: 4) {
                ARDMSearchField(placeholder: L10n("Search keys"),
                                text: $store.searchText,
                                focus: $searchFocused,
                                identifier: "key.search",
                                onSubmit: {
                                    store.recordSearch(store.searchText)
                                    store.refreshKeys(reset: true)
                                },
                                onClear: {
                                    store.searchText = ""
                                    store.refreshKeys(reset: true)
                                })
                ARDMIconButton(systemName: "arrow.clockwise", help: L10n("Refresh")) {
                    store.refreshKeys(reset: true)
                }
                .accessibilityIdentifier("key.refresh")
                moreMenu
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)

            // Contextual, not permanent: the filter row only exists while it is
            // switched on, and the selection bar only while keys are checked.
            if showingFilter { filterRow }
            if !store.checkedKeys.isEmpty { selectionRow }

            Divider()

            ScrollViewReader { proxy in
            Group {
            if store.showTree {
                List(selection: $treeSelection) {
                    ForEach(store.keyNodes) { node in
                        treeRow(node)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("key.tree")
                .onChange(of: treeSelection) { _, newValue in
                    guard let id = newValue, !id.hasPrefix("group:") else { return }
                    store.selectKey(id)
                }
            } else {
                List(store.filteredKeys(), id: \.self, selection: $store.selectedKey) { key in
                    HStack {
                        Text(key).lineLimit(1)
                        Spacer()
                        Button { toggleCheck(key) } label: {
                            Image(systemName: store.checkedKeys.contains(key) ? "checkmark.square" : "square")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n("Add to batch selection") + ": " + key)
                        .accessibilityValue(store.checkedKeys.contains(key) ? L10n("On") : L10n("Off"))
                    }
                    .font(store.uiFont(12))
                    .draggable(key)
                    .contextMenu { keyMenu(key) }
                    .onTapGesture(count: 2) { store.selectKey(key) }
                }
                .accessibilityIdentifier("key.list")
                .onChange(of: store.selectedKey) { _, newValue in
                    if let key = newValue { store.selectKey(key) }
                }
            }
            }
            .onAppear { scrollProxy = proxy }
            }
        }
        .onChange(of: store.searchFocusRequest) { _, _ in searchFocused = true }
    }

    // MARK: Toolbar pieces

    private var moreMenu: some View {
        ARDMIconMenu(help: L10n("More actions")) {
            Section {
                Button {
                    store.showTree.toggle()
                    store.buildTree()
                } label: {
                    Label(L10n(store.showTree ? "Flat list" : "Tree view"),
                          systemImage: store.showTree ? "list.bullet" : "list.bullet.indent")
                }
                Button {
                    showingFilter.toggle()
                } label: {
                    Label(showingFilter ? L10n("Hide filter") : L10n("Filter loaded keys…"),
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("key.filter.toggle")
            }

            Section {
                // Match mode used to sit beside the search field as an asterisk
                // glyph, where the menu's own chevron was drawn on top of it.
                Picker(L10n("Match mode"), selection: $store.matchMode) {
                    ForEach(MatchMode.allCases) { Text(L10n($0.label)).tag($0) }
                }
                .pickerStyle(.inline)
                Picker(L10n("Sort order"), selection: $store.keySortOrder) {
                    ForEach(KeySortOrder.allCases) { Text(L10n($0.label)).tag($0) }
                }
                .pickerStyle(.inline)
            }

            Section {
                Button {
                    store.checkedKeys.formUnion(store.filteredKeys())
                } label: {
                    Label(L10n("Select all"), systemImage: "checkmark.square")
                }
                if !store.checkedKeys.isEmpty {
                    Button {
                        store.checkedKeys.removeAll()
                    } label: {
                        Label(L10n("Clear selection"), systemImage: "square.dashed")
                    }
                }
                if !store.scanFinished {
                    Button {
                        store.loadMoreKeys()
                    } label: {
                        Label(L10n("Load more keys"), systemImage: "arrow.down.circle")
                    }
                }
            }

            Section {
                Button { store.showingBatchDelete = true } label: {
                    Label(L10n("Batch delete…"), systemImage: "trash")
                }
                Button { store.showingImportExport = true } label: {
                    Label(L10n("Export keys as JSON…"), systemImage: "square.and.arrow.up")
                }
                Button { copySelectedKeys() } label: {
                    Label(L10n("Copy selected key names"), systemImage: "doc.on.doc")
                }
            }

            Section {
                if !store.searchHistory.isEmpty {
                    Menu {
                        ForEach(Array(store.searchHistory.prefix(20)), id: \.self) { term in
                            Button(term) {
                                store.searchText = term
                                store.recordSearch(term)
                                store.refreshKeys(reset: true)
                            }
                        }
                    } label: {
                        Label(L10n("Search history"), systemImage: "clock.arrow.circlepath")
                    }
                }
                Button { scrollToTop() } label: {
                    Label(L10n("Scroll to top"), systemImage: "arrow.up.to.line")
                }
            }
        }
        .accessibilityIdentifier("key.more")
    }

    /// Second-pass filter: narrows what SCAN already returned, in memory only.
    private var filterRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n("Filter loaded keys"), text: $store.localFilter)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .accessibilityLabel(L10n("Filter loaded keys"))
                .accessibilityIdentifier("key.filter")
            Button { store.localFilterRegex.toggle() } label: {
                Text(".*").font(.system(size: 10, design: .monospaced))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(store.localFilterRegex ? Color.accentColor : Color.secondary)
            .help(L10n("Treat the filter as a regular expression"))
            .accessibilityLabel(L10n("Treat the filter as a regular expression"))
            .accessibilityValue(store.localFilterRegex ? L10n("On") : L10n("Off"))
            if !store.localFilter.isEmpty {
                Text("\(store.filteredKeys().count)/\(store.keys.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button { store.localFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n("Clear filter"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selectionRow: some View {
        HStack(spacing: 8) {
            Text(L10n("Selected") + " \(store.checkedKeys.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L10n("Delete selected")) { store.deleteKeys(Array(store.checkedKeys)) }
                .font(.caption)
            Button(L10n("Copy selected key names")) { copySelectedKeys() }
                .font(.caption)
            Spacer(minLength: 4)
            Button { store.checkedKeys.removeAll() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n("Clear selection"))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 5)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Explicit DisclosureGroup tree so expansion state is observable and persistable
    /// (List(children:) keeps its state inside SwiftUI with no way to save it).
    private func treeRow(_ node: KeyNode) -> AnyView {
        if node.isLeaf {
            let checked = store.checkedKeys.contains(node.fullPath)
            return AnyView(
                HStack(spacing: 5) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                        .onTapGesture { toggleCheck(node.fullPath) }
                        .help(L10n("Add to batch selection"))
                        // The checkbox is an Image with a tap gesture, so VoiceOver
                        // sees nothing unless it is given button semantics.
                        .accessibilityLabel(L10n("Add to batch selection") + ": " + node.fullPath)
                        .accessibilityValue(checked ? L10n("On") : L10n("Off"))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { toggleCheck(node.fullPath) }
                    Text(node.name).lineLimit(1)
                    Spacer()
                }
                .font(store.uiFont(12))
                .tag(node.fullPath)
                .draggable(node.fullPath)
                .contextMenu { keyMenu(node.fullPath) }
            )
        }
        return AnyView(
            DisclosureGroup(isExpanded: store.expansionBinding(node.fullPath)) {
                ForEach(node.children ?? []) { child in
                    treeRow(child)
                }
            } label: {
                HStack(spacing: 5) {
                    // Tri-state box: checking the folder selects every key below it.
                    let state = store.groupCheckState(node.fullPath)
                    Image(systemName: groupCheckIcon(state))
                        .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                        .onTapGesture { store.toggleGroupCheck(node.fullPath) }
                        .help(L10n("Select all in group"))
                        .accessibilityLabel(L10n("Select all in group") + ": " + node.fullPath)
                        .accessibilityValue(store.keysInGroup(node.fullPath).count.description)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { store.toggleGroupCheck(node.fullPath) }
                    Image(systemName: "folder").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(node.name).lineLimit(1)
                    Spacer()
                    let members = store.keysInGroup(node.fullPath)
                    if !members.isEmpty {
                        let hits = members.reduce(0) { $0 + (store.checkedKeys.contains($1) ? 1 : 0) }
                        Text("\(hits)/\(members.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(store.uiFont(12))
                .contextMenu {
                    Button(L10n("Select all in group")) { store.toggleGroupCheck(node.fullPath) }
                    Button(L10n("Clear group selection")) {
                        store.checkedKeys.subtract(store.keysInGroup(node.fullPath))
                    }
                    Divider()
                    Button(L10n("Delete group")) {
                        store.deleteKeys(store.keys.filter { $0.hasPrefix(node.fullPath + store.separator) })
                    }
                }
            }
        )
    }

    private func groupCheckIcon(_ state: GroupCheckState) -> String {
        switch state {
        case .all: return "checkmark.square.fill"
        case .partial: return "minus.square.fill"
        case .none: return "square"
        }
    }

    private func scrollToTop() {
        let target = store.showTree ? (store.keyNodes.first?.id ?? "") : (store.filteredKeys().first ?? "")
        if !target.isEmpty { scrollProxy?.scrollTo(target) }
    }

    private func copySelectedKeys() {
        let keys = Array(store.checkedKeys.isEmpty ? [store.selectedKey ?? ""] : store.checkedKeys).filter { !$0.isEmpty }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(keys.joined(separator: "\n"), forType: .string)
    }

    private func toggleCheck(_ key: String) {
        if store.checkedKeys.contains(key) { store.checkedKeys.remove(key) }
        else { store.checkedKeys.insert(key) }
    }

    @ViewBuilder
    private func keyMenu(_ key: String) -> some View {
        Button(L10n("Open")) { store.selectKey(key) }
        Button(L10n("Copy key name")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
        }
        Button(L10n("Copy DUMP command")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("DUMP \(key)", forType: .string)
        }
        Button(L10n("DUMP")) { store.dumpKey(key) }
        Divider()
        Button(L10n("Rename…")) { store.selectedKey = key; store.showingRename = true }
        Button(L10n("Set TTL…")) { store.selectedKey = key; store.showingTTL = true }
        Button(L10n("Add to favorites")) {
            if !store.favoriteKeys.contains(key) { store.favoriteKeys.append(key); store.saveFavorites() }
        }
        Button(L10n("Add to batch selection")) { store.checkedKeys.insert(key) }
        Divider()
        Button(L10n("Delete"), role: .destructive) { store.deleteKeys([key]) }
    }
}

// MARK: - New key dialog (OperateItem.vue / newKeyDialog)

struct NewKeySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var ttl = ""
    @State private var typeIndex = 0

    private let types: [(String, ARDMKeyType)] = [
        ("String", .string), ("Hash", .hash), ("List", .list), ("Set", .set),
        ("ZSet", .zSet), ("Stream", .stream), ("ReJSON", .reJSON),
        ("TimeSeries", .timeSeries), ("Vector", .vector), ("Array", .array)
    ]

    var body: some View {
        VStack(spacing: 14) {
            Text(L10n("New Key")).font(.headline)
            Form {
                TextField(L10n("Key name"), text: $name)
                Picker(L10n("Type"), selection: $typeIndex) {
                    ForEach(0..<types.count, id: \.self) { Text(types[$0].0).tag($0) }
                }
                TextField(L10n("Value / member"), text: $value)
                TextField(L10n("TTL seconds (optional)"), text: $ttl)
            }
            HStack {
                Text(L10n("Read-only mode blocks all writes")).font(.caption).foregroundStyle(store.readOnly ? .red : .secondary)
                Spacer()
                Button(L10n("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n("Create")) {
                    store.createKey(name: name, type: types[typeIndex].1, value: value, ttl: Int(ttl) ?? -1)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || store.readOnly)
            }
        }
        .padding(20)
    }
}

// MARK: - Batch delete (DeleteBatch.vue)

struct BatchDeleteSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var pattern = ""
    @State private var previewCount = 0
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 14) {
            Text(L10n("Batch delete keys")).font(.headline)
            Text(L10n("SCAN matching a glob pattern, then UNLINK in chunks of 500."))
                .font(.caption).foregroundStyle(.secondary)
            TextField(L10n("Pattern (e.g. session:*)"), text: $pattern)
                .textFieldStyle(.roundedBorder)
                .onSubmit { preview() }
            HStack {
                Button(L10n("Preview count")) { preview() }
                Text("\(previewCount) matching keys").font(.caption)
            }
            if confirming {
                Text(L10n("⚠️ This permanently deletes every matching key."))
                    .foregroundStyle(.red).font(.caption)
            }
            HStack {
                Button(L10n("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirming ? "Confirm delete" : "Delete") {
                    if confirming { store.batchDelete(pattern: pattern); dismiss() }
                    else { confirming = true }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pattern.isEmpty || store.readOnly)
            }
        }
        .padding(24)
    }

    private func preview() {
        guard let client = store.client else { return }
        store.onBackground {
            var cursor: UInt = 0
            var count = 0
            repeat {
                var error: NSError?
                var local = cursor
                let batch = client.scanKeys(matching: pattern, cursor: &local, count: 1000, error: &error)
                count += batch.count
                cursor = local
                if error != nil { break }
            } while cursor != 0 && count < 100000
            let total = count
            store.onMain { previewCount = total }
        }
    }
}

// MARK: - Keyboard shortcuts (HotKeys.vue)

struct HotKeysSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    private let rows: [(String, String)] = [
        ("⌘N", "New connection"), ("⌘K", "New key"), ("⌘R", "Refresh keys"),
        ("⌘,", "Settings"), ("⌘Delete", "Delete selected key"),
        ("↑ / ↓", "CLI command history"), ("Tab", "CLI command completion"),
        ("Enter", "Execute CLI command / open key"), ("Double click", "Connect / open key"),
        ("Right click", "Context menu (rename, TTL, delete, copy, DUMP)"),
        ("Drag", "Move connections between groups / reorder favorites")
    ]

    var body: some View {
        VStack {
            Text(L10n("Keyboard Shortcuts")).font(.headline).padding()
            List(Array(rows.indices), id: \.self) { index in
                HStack {
                    Text(rows[index].0).font(store.monoFont(12)).frame(width: 110, alignment: .leading)
                    Text(rows[index].1).font(store.uiFont(12))
                    Spacer()
                }
            }
            Button(L10n("Close")) { dismiss() }.padding()
        }
    }
}
