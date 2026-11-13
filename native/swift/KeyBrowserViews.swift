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
        // Every strip here is priority 1 on purpose: the list is the only
        // flexible member, so when the column runs out of height the list
        // shrinks first and the load-more bar always survives at full height.
        VStack(spacing: 0) {
            databaseTabs
                .layoutPriority(1)
            Divider().layoutPriority(1)
            headerRow
                .layoutPriority(1)
            searchRow
                .layoutPriority(1)
            groupingRow
                .layoutPriority(1)
            // Contextual, not permanent: the filter row only exists while it is
            // switched on, and the selection bar only while keys are checked.
            if showingFilter { filterRow.layoutPriority(1) }
            if !store.checkedKeys.isEmpty { selectionRow.layoutPriority(1) }

            Divider().layoutPriority(1)

            ScrollViewReader { proxy in
                keyList
                    .onAppear { scrollProxy = proxy }
            }

            loadMoreBar
                .layoutPriority(1)
        }
        .onChange(of: store.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: store.separator) { _, _ in store.buildTree() }
    }

    // MARK: Database tabs

    /// Each database opens as a tab in this column instead of replacing what the
    /// previous one was showing. The reference client works this way, and it is
    /// the reason its sidebar can stay a plain list of connections.
    private var databaseTabs: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(store.openDBTabs, id: \.self) { db in
                        databaseTab(db)
                    }
                }
                .padding(.vertical, 2)
            }
            ARDMIconMenu(systemName: "plus", help: L10n("Open database")) {
                ForEach(0..<16, id: \.self) { db in
                    Button {
                        store.changeDatabase(db)
                    } label: {
                        if store.openDBTabs.contains(db) {
                            Label("db\(db)", systemImage: "checkmark")
                        } else {
                            Text("db\(db)")
                        }
                    }
                }
            }
            .accessibilityIdentifier("db.tabs.add")
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }

    private func databaseTab(_ db: Int) -> some View {
        let active = db == store.selectedDB
        let closable = store.openDBTabs.count > 1
        return HStack(spacing: 4) {
            Button {
                guard !active else { return }
                store.changeDatabase(db)
            } label: {
                Text("db\(db)")
                    .font(.system(size: ARDMFont.small, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("db\(db)")
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)

            if closable {
                Button { store.closeDatabaseTab(db) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(active ? Color.accentColor.opacity(0.75)
                                                : Color.secondary.opacity(0.65))
                        .frame(width: 10, height: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n("Close tab") + " db\(db)")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, closable ? 4 : 7)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(active ? Color.accentColor : Color.clear)
                .frame(height: 1.5)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Header strips

    /// Loaded / total counts plus the three verbs that act on the whole list,
    /// on one 26pt line. Saying "1,788 / 2,970" once is enough; the old strip
    /// printed the same pair twice in different phrasings.
    private var headerRow: some View {
        HStack(spacing: 3) {
            Text(L10n("Loaded"))
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.tertiary)
            Text(ARDMFormat.count(store.keys.count))
                .font(.system(size: ARDMFont.small, weight: .medium))
                .monospacedDigit()
            Text("/ " + L10n("total") + " \(ARDMFormat.count(max(store.dbSize, store.keys.count))) " + L10n("keys"))
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 2)
            Button(L10n("Select all")) { store.checkedKeys.formUnion(store.filteredKeys()) }
                .buttonStyle(.plain)
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.secondary)
            ARDMIconButton(systemName: "arrow.clockwise", help: L10n("Refresh")) {
                store.refreshKeys(reset: true)
            }
            .accessibilityIdentifier("key.refresh")
            ARDMIconButton(systemName: "plus", help: L10n("New Key")) {
                store.showingNewKey = true
            }
            moreMenu
        }
        .padding(.horizontal, ARDMMetrics.listInset)
        .frame(height: 26)
    }

    /// Search owns most of this row; the pattern mode and the expiry filter sit
    /// beside it as compact controls rather than inside an overflow menu, which
    /// is where the reference client puts them too.
    private var searchRow: some View {
        HStack(spacing: 6) {
            ARDMSearchField(placeholder: L10n("Match pattern (e.g. user:*)"),
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
            matchModeMenu
            noExpiryToggle
        }
        .padding(.horizontal, ARDMMetrics.listInset)
        .padding(.bottom, 5)
    }

    private var matchModeMenu: some View {
        Menu {
            Picker(L10n("Match mode"), selection: $store.matchMode) {
                ForEach(MatchMode.allCases) { Text(L10n($0.label)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "asterisk")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(L10n(store.matchMode.label))
                    .font(.system(size: ARDMFont.micro))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
            )
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(L10n("Match mode"))
        .accessibilityLabel(L10n("Match mode"))
    }

    private var noExpiryToggle: some View {
        Button { store.onlyNoExpiry.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: store.onlyNoExpiry ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundStyle(store.onlyNoExpiry ? Color.accentColor
                                                        : Color.secondary.opacity(0.6))
                Text(L10n("Only without expiry"))
                    .font(.system(size: ARDMFont.micro))
                    .foregroundStyle(store.onlyNoExpiry ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n("Only without expiry"))
        .accessibilityLabel(L10n("Only without expiry"))
        .accessibilityValue(store.onlyNoExpiry ? L10n("On") : L10n("Off"))
    }

    /// Section caption plus the rule that decides where folders split. The old
    /// row was a bare separator menu with no label, so nothing said what it did.
    private var groupingRow: some View {
        HStack(spacing: 4) {
            Text(L10n("Custom grouping"))
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 2)
            Menu {
                Picker(L10n("Separator"), selection: $store.separator) {
                    ForEach([":", "/", "|", ".", "-", "_"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button {
                    store.showTree.toggle()
                    if store.showTree { store.buildTree() }
                } label: {
                    Label(L10n(store.showTree ? "Flat list" : "Tree view"),
                          systemImage: store.showTree ? "list.bullet" : "list.bullet.indent")
                }
                Button {
                    store.expandedNodeIDs.removeAll()
                    store.buildTree()
                } label: {
                    Label(L10n("Collapse all groups"), systemImage: "rectangle.compress.vertical")
                }
                Divider()
                Picker(L10n("Sort order"), selection: $store.keySortOrder) {
                    ForEach(KeySortOrder.allCases) { Text(L10n($0.label)).tag($0) }
                }
                .pickerStyle(.inline)
                Button { showingFilter.toggle() } label: {
                    Label(showingFilter ? L10n("Hide filter") : L10n("Filter loaded keys…"),
                          systemImage: "line.3.horizontal.decrease.circle")
                }
            } label: {
                HStack(spacing: 2) {
                    Text(L10n("Grouping rules"))
                        .font(.system(size: ARDMFont.micro))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(L10n("Grouping rules"))
            .accessibilityLabel(L10n("Grouping rules"))
        }
        .padding(.horizontal, ARDMMetrics.listInset)
        .frame(height: 22)
    }

    @ViewBuilder
    private var keyList: some View {
        if store.showTree {
            List(selection: $treeSelection) {
                ForEach(store.keyNodes) { node in
                    treeRow(node)
                }
            }
            // Plain, not sidebar: the middle column is a data list, and the
            // sidebar material behind thousands of rows turned the whole window
            // into one grey slab.
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, ARDMMetrics.rowHeight)
            .accessibilityIdentifier("key.tree")
            .onChange(of: treeSelection) { _, newValue in
                guard let id = newValue, !id.hasPrefix("group:") else { return }
                store.selectKey(id)
            }
        } else {
            List(store.filteredKeys(), id: \.self, selection: $store.selectedKey) { key in
                KeyLeafRow(key: key, name: key)
                    .tag(key)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, ARDMMetrics.rowHeight)
            .accessibilityIdentifier("key.list")
            .onChange(of: store.selectedKey) { _, newValue in
                if let key = newValue { store.selectKey(key) }
            }
        }
    }

    /// Two equal halves, always visible. A 3000-key database is 90% "load more";
    /// hiding that behind a menu made the column look finished at 500 rows.
    private var loadMoreBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                Button { store.loadMoreKeys() } label: {
                    Text(L10n("Load more"))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.scanFinished)
                .accessibilityIdentifier("key.loadMore")

                Divider().frame(height: 14)

                Button { store.loadAllKeys() } label: {
                    Text(L10n("Load all"))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.scanFinished)
                .accessibilityIdentifier("key.loadAll")
            }
            .font(.system(size: ARDMFont.small))
            .foregroundStyle(store.scanFinished ? Color.secondary.opacity(0.55) : Color.accentColor)
        }
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
            return AnyView(KeyLeafRow(key: node.fullPath, name: node.name).tag(node.fullPath))
        }
        return AnyView(
            DisclosureGroup(isExpanded: store.expansionBinding(node.fullPath)) {
                ForEach(node.children ?? []) { child in
                    treeRow(child)
                }
            } label: {
                groupLabel(node)
            }
        )
    }

    /// Folder row: amber folder, name, member count, and a tri-state marker that
    /// only appears once a batch selection exists.
    private func groupLabel(_ node: KeyNode) -> some View {
        let state = store.groupCheckState(node.fullPath)
        let members = store.keysInGroup(node.fullPath)
        return HStack(spacing: 5) {
            if !store.checkedKeys.isEmpty {
                Image(systemName: groupCheckIcon(state))
                    .font(.system(size: 10))
                    .foregroundStyle(state == .none ? Color.secondary.opacity(0.5) : Color.accentColor)
                    .onTapGesture { store.toggleGroupCheck(node.fullPath) }
                    .accessibilityLabel(L10n("Select all in group") + ": " + node.fullPath)
                    .accessibilityAddTraits(.isButton)
            }
            Image(systemName: "folder.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(red: 0.84, green: 0.63, blue: 0.26))
                .accessibilityHidden(true)
            Text(node.name)
                .font(.system(size: ARDMFont.body))
                .lineLimit(1)
            Text(store.scanFinished ? "(\(members.count))" : "(\(members.count)+)")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 2)
        }
        .frame(minHeight: 22)
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
}

// MARK: - One key row

/// Type pill, monospaced name, spelled-out expiry, and one hover action. The
/// checkbox is always present (the reference lists it on every row) because
/// revealing it only during a selection shifted the whole column sideways the
/// moment the first key was ticked.
private struct KeyLeafRow: View {
    @EnvironmentObject var store: AppStore
    let key: String
    let name: String
    @State private var hovering = false

    var body: some View {
        let checked = store.checkedKeys.contains(key)
        let meta = store.keyMeta[key]
        HStack(spacing: 6) {
            Button {
                if checked { store.checkedKeys.remove(key) } else { store.checkedKeys.insert(key) }
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary.opacity(0.42))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n("Add to batch selection") + ": " + key)
            .accessibilityValue(checked ? L10n("On") : L10n("Off"))

            Text(name)
                .font(.system(size: ARDMFont.monoRow, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let meta {
                ARDMTypeBadge(type: meta.type)
                Text(meta.ttl >= 0 ? ARDMFormat.ttlLong(meta.ttl) : "永久")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(ttlTint(meta.ttl))
                    .frame(width: 62, alignment: .trailing)
            }

            // The slot is reserved whether or not the row is hovered, so the
            // badges above never move when the pointer enters a row.
            Image(systemName: "trash")
                .font(.system(size: 10))
                .foregroundStyle(hovering ? Color.secondary : Color.clear)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .onTapGesture { store.deleteKeys([key]) }
                .help(L10n("Delete"))
        }
        .frame(minHeight: ARDMMetrics.rowHeight)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        .listRowSeparator(.hidden)
        .draggable(key)
        .contextMenu {
            Button(L10n("Open")) { store.selectKey(key) }
            Button(L10n("Copy key name")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
            }
            Button(L10n("DUMP")) { store.dumpKey(key) }
            Divider()
            Button(L10n("Rename…")) { store.selectedKey = key; store.showingRename = true }
            Button(L10n("Set TTL…")) { store.selectedKey = key; store.showingTTL = true }
            Button(L10n("Add to batch selection")) { store.checkedKeys.insert(key) }
            Divider()
            Button(L10n("Delete"), role: .destructive) { store.deleteKeys([key]) }
        }
    }

    /// Warm expiries recede, imminent ones pull the eye.
    private func ttlTint(_ ttl: Int) -> Color {
        switch ttl {
        case -1: return Color.secondary.opacity(0.55)
        case 0..<300: return Color(red: 0.85, green: 0.30, blue: 0.26)
        case 300..<3600: return Color(red: 0.86, green: 0.55, blue: 0.16)
        default: return .secondary
        }
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
