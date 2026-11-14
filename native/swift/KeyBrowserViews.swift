import SwiftUI
import AppKit

// MARK: - Key list (KeyList.vue / KeyListNormal.vue / KeyListVirtualTree.vue)

struct KeyBrowserView: View {
    @EnvironmentObject var store: AppStore
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showingFilter = false
    @State private var confirmingDelete = false
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        // Every strip here is priority 1 on purpose: the list is the only
        // flexible member, so when the column runs out of height the list
        // shrinks first and the load-more bar always survives at full height.
        VStack(spacing: 0) {
            databaseTabs
                .layoutPriority(1)
            Divider().layoutPriority(1)
            searchRow
                .layoutPriority(1)
            // Contextual, not permanent: the filter row only exists while it is
            // switched on, and the selection bar only while keys are checked.
            if showingFilter { filterRow.layoutPriority(1) }
            if !store.checkedKeys.isEmpty || store.keySelection.count > 1 { selectionRow.layoutPriority(1) }

            Divider().layoutPriority(1)

            ScrollViewReader { proxy in
                keyListSurface
                    .onAppear { scrollProxy = proxy }
            }

            loadMoreBar
                .layoutPriority(1)
        }
        .onChange(of: store.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: store.separator) { _, _ in store.buildTree() }
        // One handler for both lists: ⇧ and ⌘ land here, and the anchor decides
        // which single key the detail pane follows.
        .onChange(of: store.keySelection) { previous, _ in
            store.keyListHasFocus = true
            store.selectionChanged(previous: previous)
            listFocused = true
        }
        .alert(L10n("Delete selected keys?"), isPresented: $confirmingDelete) {
            Button(L10n("Delete"), role: .destructive) { store.deleteKeys(store.batchKeys()) }
            Button(L10n("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n("This permanently deletes") + " \(store.batchKeys().count) "
                 + L10n("selected keys."))
        }
    }

    /// List plus its keyboard plumbing, split out of `body`: the hotkey closures
    /// and the delete confirmation together pushed the whole modifier chain past
    /// the type-checker.
    private var keyListSurface: some View {
        keyList
            .focusable(true)
            .focused($listFocused)
            .background(KeyListHotKeys(store: store,
                                       focusSearch: { searchFocused = true },
                                       escape: { escStepsBack() },
                                       copySelection: { copySelectedKeys() },
                                       deleteSelection: { confirmingDelete = true },
                                       move: { down, shift in moveCaret(down: down, extending: shift) }))
    }

    /// Arrows move the caret and keep it on screen. The column is a fixed height,
    /// so a caret that scrolls out of it is a caret the user has lost.
    private func moveCaret(down: Bool, extending: Bool) {
        store.moveKeySelection(down: down, extending: extending)
        if let anchor = store.selectionAnchor {
            scrollProxy?.scrollTo(anchor, anchor: .center)
        }
    }

    /// Esc undoes the last thing rather than everything: the search needle, then
    /// the ⇧/⌘ selection, then the checkbox batch.
    private func escStepsBack() {
        if !store.searchText.isEmpty {
            store.searchText = ""
        } else if !store.localFilter.isEmpty {
            store.localFilter = ""
        } else if !store.keySelection.isEmpty {
            store.clearKeySelection()
        } else if !store.checkedKeys.isEmpty {
            store.checkedKeys.removeAll()
        }
    }

    // MARK: Database tabs

    /// One line for everything that acts before you can see a key: the open
    /// databases, how much of the keyspace is loaded, and the three verbs. Four
    /// stacked strips above a 340pt column left barely any list at all.
    private var databaseTabs: some View {
        HStack(spacing: 3) {
            // The sidebar's own collapse button is inside the sidebar, so the
            // way back has to live where the hidden column used to be. It is
            // not added to the toolbar: changing the toolbar's item set makes
            // AppKit rebuild it and drops the flexible gap that holds the
            // search and tools buttons at the trailing edge.
            if store.sidebarCollapsed {
                ARDMIconButton(systemName: "sidebar.left", help: L10n("Show Sidebar")) {
                    store.sidebarCollapsed = false
                }
                .accessibilityIdentifier("sidebar.expand")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(store.openDBTabs, id: \.self) { db in
                        databaseTab(db)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Not a second "plus": the row already ends with New Key, and two
            // identical glyphs a few points apart invite the wrong click.
            ARDMIconMenu(systemName: "square.stack.3d.up", help: L10n("Open database")) {
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
            .fixedSize()
            .accessibilityIdentifier("db.tabs.add")

            loadCounts
            listActions
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }

    /// Loaded / total as one bare pair. The old strip printed the same numbers
    /// twice in different phrasings and burned a whole row doing it.
    private var loadCounts: some View {
        HStack(spacing: 2) {
            if store.connected && !store.scanFinished {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .accessibilityLabel(L10n("Scanning"))
            }
            Text(ARDMFormat.count(store.keys.count) + " / "
                 + ARDMFormat.count(max(store.dbSize, store.keys.count)))
                .font(.system(size: ARDMFont.small))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .help(L10n("Loaded") + " / " + L10n("total"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n("Loaded") + " \(store.keys.count) / \(store.dbSize) " + L10n("keys"))
    }

    private var listActions: some View {
        HStack(spacing: 2) {
            ARDMIconButton(systemName: "arrow.clockwise", help: L10n("Refresh the key list (⌘R)")) {
                store.refreshKeys(reset: true)
            }
            .accessibilityIdentifier("key.refresh")
            ARDMIconButton(systemName: "plus", help: L10n("New Key")) {
                store.showingNewKey = true
            }
            moreMenu
        }
        .fixedSize()
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
        .frame(height: ardmScaled(24))
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

    /// Search owns most of this row; the pattern mode and the expiry filter sit
    /// beside it as compact controls rather than inside an overflow menu, which
    /// is where the reference client puts them too.
    private var searchRow: some View {
        HStack(spacing: 6) {
            ARDMSearchField(placeholder: L10n("SCAN pattern (e.g. user:*)"),
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
            .frame(height: ARDMMetrics.control)
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
                    .font(.system(size: ARDMFont.micro))
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

    @ViewBuilder
    private var keyList: some View {
        if store.keys.isEmpty {
            keyListEmptyState
        } else if store.showTree {
            List(selection: $store.keySelection) {
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
        } else {
            List(store.filteredKeys(), id: \.self, selection: $store.keySelection) { key in
                let parts = splitKey(key)
                KeyLeafRow(key: key, name: parts.name, prefix: parts.namespace)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, ARDMMetrics.rowHeight)
            .accessibilityIdentifier("key.list")
        }
    }

    /// Two equal halves, always visible. A 3000-key database is 90% "load more";
    /// hiding that behind a menu made the column look finished at 500 rows.
    /// One explanation instead of a silent blank column: nothing is loaded yet
    /// before the first connection, and an empty result means the scan really
    /// came back with zero keys.
    private var keyListEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.connected ? "list.bullet.rectangle" : "bolt.horizontal.circle")
                .font(.system(size: ARDMIcon.emptyState, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.quaternary)
            Text(store.connected ? L10n("No keys loaded") : L10n("Connect to a server to browse keys"))
                .font(.system(size: ARDMFont.body, weight: .medium))
                .foregroundStyle(.secondary)
            Text(store.connected
                 ? L10n("Scan started — use “Load all” below for the whole database")
                 : L10n("Double-click a connection, then scan its keys"))
                .font(.system(size: ARDMFont.small))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var loadMoreBar: some View {
        // Floating glass pill instead of a full-width divider strip: the list
        // scrolls under it and the two actions read as one control.
        HStack(spacing: 0) {
            Button { store.loadMoreKeys() } label: {
                Text(L10n("Load more"))
                    .frame(maxWidth: .infinity, minHeight: ARDMMetrics.control)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.scanFinished)
            .accessibilityIdentifier("key.loadMore")

            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1, height: 14)

            Button { store.loadAllKeys() } label: {
                Text(L10n("Load all"))
                    .frame(maxWidth: .infinity, minHeight: ARDMMetrics.control)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.scanFinished)
            .accessibilityIdentifier("key.loadAll")
        }
        .font(.system(size: ARDMFont.small))
        .foregroundStyle(store.scanFinished ? Color.secondary.opacity(0.55) : Color.accentColor)
        .padding(.horizontal, 8)
        .ardmGlass(in: Capsule())
        .padding(.horizontal, 14)
        .padding(.bottom, 7)
        .padding(.top, 2)
    }

    // MARK: Toolbar pieces

    private var moreMenu: some View {
        ARDMIconMenu(help: L10n("More actions")) {
            Section {
                Picker(L10n("Separator"), selection: $store.separator) {
                    ForEach([":", "/", "|", ".", "-", "_"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                Button {
                    store.expandedNodeIDs.removeAll()
                    store.buildTree()
                } label: {
                    Label(L10n("Collapse all groups"), systemImage: "rectangle.compress.vertical")
                }
            }

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
                if store.showTree {
                    Toggle(L10n("Merge single-child levels"), isOn: $store.collapseTreeChains)
                }
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
                Text(".*").font(.system(size: ARDMFont.micro, design: .monospaced))
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
            Text(L10n("Selected") + " \(store.keySelection.union(store.checkedKeys).count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The bar promises *these* keys, so it opens the same confirmation ⌫
            // does. The pattern-driven batch sheet is a different operation and
            // stays reachable from the toolbar and the ⋯ menu.
            Button(L10n("Delete selected")) { confirmingDelete = true }
                .font(.caption)
            Button(L10n("Copy selected key names")) { copySelectedKeys() }
                .font(.caption)
            Spacer(minLength: 4)
            Button {
                store.clearKeySelection()
                store.checkedKeys.removeAll()
            } label: {
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
                    .font(.system(size: ARDMFont.micro))
                    .foregroundStyle(state == .none ? Color.secondary.opacity(0.5) : Color.accentColor)
                    .onTapGesture { store.toggleGroupCheck(node.fullPath) }
                    .accessibilityLabel(L10n("Select all in group") + ": " + node.fullPath)
                    .accessibilityAddTraits(.isButton)
            }
            Image(systemName: "folder.fill")
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(Color(red: 0.84, green: 0.63, blue: 0.26))
                .accessibilityHidden(true)
            Text(node.displayPath)
                .font(.system(size: ARDMFont.body))
                .lineLimit(1)
                .truncationMode(.head)
            Text(store.scanFinished ? "(\(members.count))" : "(\(members.count)+)")
                .font(.system(size: ARDMFont.micro))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 2)
        }
        .frame(minHeight: ardmScaled(24))
        .help(node.fullPath)
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

    /// `user:cart:items` → `("user:cart:", "items")`. The flat list prints the two
    /// halves at different weights so the segment that actually differs between
    /// neighbouring rows is the one the eye lands on.
    private func splitKey(_ key: String) -> (namespace: String, name: String) {
        let sep = store.separator.isEmpty ? ":" : store.separator
        guard let range = key.range(of: sep, options: .backwards) else { return ("", key) }
        return (String(key[..<range.upperBound]), String(key[range.upperBound...]))
    }

    private func copySelectedKeys() {
        let keys = store.batchKeys()
        guard !keys.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(keys.joined(separator: "\n"), forType: .string)
        store.notify(L10n("Copied") + " \(keys.count) " + L10n("key names"))
    }
}

// MARK: - Key list keyboard

/// `/` to search, Esc to step back, ⌘C to copy names, ⌫ to delete, ↩ to open.
///
/// A local event monitor rather than menu commands, because ⌘C and ⌫ already
/// mean something inside every text field in the app. They are claimed here only
/// while neither a field editor nor a sheet owns the keyboard, and only when
/// there is a selection for them to act on — otherwise the event passes through
/// untouched and the rest of the app keeps its standard bindings.
struct KeyListHotKeys: NSViewRepresentable {
    /// Reports the window the list ends up in, so the monitor can tell the main
    /// window's keys from a dialog's.
    private final class HotKeyHost: NSView {
        var onWindowChange: (NSWindow?) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange(window)
        }
    }

    @ObservedObject var store: AppStore
    var focusSearch: () -> Void
    var escape: () -> Void
    var copySelection: () -> Void
    var deleteSelection: () -> Void
    var move: (Bool, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.configure(store: store,
                              focusSearch: focusSearch,
                              escape: escape,
                              copySelection: copySelection,
                              deleteSelection: deleteSelection,
                              move: move)
        coordinator.install()
        let view = HotKeyHost(frame: .zero)
        view.onWindowChange = { [weak coordinator] in coordinator?.hostWindow = $0 }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configure(store: store,
                                      focusSearch: focusSearch,
                                      escape: escape,
                                      copySelection: copySelection,
                                      deleteSelection: deleteSelection,
                                      move: move)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        private var monitor: Any?
        private weak var store: AppStore?
        /// The window the list actually lives in. `nil` until the representable
        /// is attached, which is treated as "no dialog is up".
        weak var hostWindow: NSWindow?
        private var focusSearch: () -> Void = {}
        private var escape: () -> Void = {}
        private var copySelection: () -> Void = {}
        private var deleteSelection: () -> Void = {}
        private var move: (Bool, Bool) -> Void = { _, _ in }

        func configure(store: AppStore, focusSearch: @escaping () -> Void,
                       escape: @escaping () -> Void, copySelection: @escaping () -> Void,
                       deleteSelection: @escaping () -> Void, move: @escaping (Bool, Bool) -> Void) {
            self.store = store
            self.focusSearch = focusSearch
            self.escape = escape
            self.copySelection = copySelection
            self.deleteSelection = deleteSelection
            self.move = move
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let claim = self.claim(event) else { return event }
                claim()
                return nil
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            self.monitor = nil
        }

        /// nil means "not ours" and the event continues to the responder chain.
        private func claim(_ event: NSEvent) -> (() -> Void)? {
            guard let window = event.window, window.attachedSheet == nil else { return nil }
            // A confirmation alert is its own window: ⌫ and Esc pressed there
            // answer the alert, and must not also fire the list behind it.
            guard hostWindow == nil || window === hostWindow else { return nil }
            // The field editor is an NSText, so this is also the guard that keeps
            // ⌘C and ⌫ behaving normally in the value pane and every dialog.
            guard !(window.firstResponder is NSText) else { return nil }
            guard let store else { return nil }
            // The palette floats over this column and owns ↑↓/↩/Esc while it is
            // up, so the list stays out of the way even before its field lands.
            guard !store.showingQuickOpen else { return nil }
            // Arrow keys arrive with `.function` set and Caps Lock rides along
            // whether or not the user meant it, so both are stripped before the
            // modifier sets are compared.
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .capsLock])

            switch Int(event.keyCode) {
            case 53:
                return store.searchText.isEmpty && store.localFilter.isEmpty
                    && store.keySelection.isEmpty && store.checkedKeys.isEmpty
                    ? nil : escape
            case 51, 117:
                return flags.isEmpty && !store.batchKeys().isEmpty ? deleteSelection : nil
            case 125, 126:
                // Only while the pointer last worked in this column: the sidebar's
                // own list takes arrows natively and must keep them.
                guard store.keyListHasFocus, flags.isEmpty || flags == .shift else { return nil }
                let down = event.keyCode == 125
                let shift = flags.contains(.shift)
                return { self.move(down, shift) }
            case 36, 76:
                guard flags.isEmpty, let anchor = store.selectionAnchor else { return nil }
                return { store.selectKey(anchor) }
            default:
                break
            }

            guard let text = event.charactersIgnoringModifiers?.lowercased() else { return nil }
            if text == "/" && flags.isEmpty { return focusSearch }
            if text == "c" && flags == .command && !store.batchKeys().isEmpty { return copySelection }
            return nil
        }
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
    /// Namespace leading up to `name`, one step quieter. The tree's indentation
    /// already says where a row sits, so there it stays empty; the flat list has
    /// no such cue and needs the prefix to tell `user:1` from `order:1` — while
    /// keeping it dim enough that the differing last segment is what you read.
    var prefix: String = ""
    @State private var hovering = false

    var body: some View {
        let checked = store.checkedKeys.contains(key)
        let meta = store.keyMeta[key]
        HStack(spacing: 6) {
            Button {
                if checked { store.checkedKeys.remove(key) } else { store.checkedKeys.insert(key) }
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: ARDMFont.small))
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary.opacity(0.42))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n("Add to batch selection") + ": " + key)
            .accessibilityValue(checked ? L10n("On") : L10n("Off"))

            // The namespace prefix recedes rather than disappearing: a leaf
            // called "1" is only identifiable by where it sits.
            HStack(spacing: 0) {
                if !prefix.isEmpty {
                    Text(prefix)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            .font(.system(size: ARDMFont.monoRow, design: .monospaced))

            Spacer(minLength: 4)

            if let meta {
                ARDMTypeBadge(type: meta.type)
                Text(meta.ttl >= 0 ? ARDMFormat.ttlLong(meta.ttl) : "永久")
                    .font(.system(size: ARDMFont.micro))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(ttlTint(meta.ttl))
                    .frame(width: 62, alignment: .trailing)
            }

            // The slot is reserved whether or not the row is hovered, so the
            // badges above never move when the pointer enters a row.
            Image(systemName: "trash")
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(hovering ? Color.secondary : Color.clear)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .onTapGesture { store.deleteKeys([key]) }
                .help(L10n("Delete"))
        }
        .frame(minHeight: ARDMMetrics.rowHeight)
        // A quiet wash that follows the pointer. The List's own selection tint
        // still paints over it, so the hover state never fights the selection.
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hovering ? Color.secondary.opacity(0.09) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        .listRowSeparator(.hidden)
        .draggable(key)
        .help(key)
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
        ("⌥⌘S", "Collapse or show the sidebar"),
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
