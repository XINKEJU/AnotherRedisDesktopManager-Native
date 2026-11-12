import SwiftUI
import AppKit

// MARK: - Key list (KeyList.vue / KeyListNormal.vue / KeyListVirtualTree.vue)

struct KeyBrowserView: View {
    @EnvironmentObject var store: AppStore
    @State private var treeSelection: String?
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {
            // OperateItem.vue: search, match mode, refresh, and all secondary actions.
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n("Search keys"), text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 90)
                    .onSubmit { store.refreshKeys(reset: true) }
                if !store.searchText.isEmpty {
                    Button { store.searchText = ""; store.refreshKeys(reset: true) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.plain)
                }
                Picker("", selection: $store.matchMode) {
                    ForEach(MatchMode.allCases) { Text(L10n($0.label)).tag($0) }
                }
                .frame(width: 74)
                .labelsHidden()
                Button { store.refreshKeys(reset: true) } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n("Refresh"))
                Menu {
                    Button(L10n(store.showTree ? "Flat list" : "Tree view")) { store.showTree.toggle(); store.buildTree() }
                    if !store.scanFinished { Button(L10n("Load more keys")) { store.loadMoreKeys() } }
                    Button(L10n("Batch delete…")) { store.showingBatchDelete = true }
                    Button(L10n("Export keys as JSON…")) { store.showingImportExport = true }
                    Button(L10n("Scroll to top")) { scrollToTop() }
                    Divider()
                    Button(L10n("Copy selected key names")) { copySelectedKeys() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }
            .padding(8)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("\(store.filteredKeys().count) " + L10n("keys")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !store.checkedKeys.isEmpty {
                    Button(L10n("Delete selected") + " \(store.checkedKeys.count) " + L10n("keys")) {
                        store.deleteKeys(Array(store.checkedKeys))
                    }.font(.caption)
                    Button(L10n("Clear selection")) { store.checkedKeys.removeAll() }.font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            ScrollViewReader { proxy in
            Group {
            if store.showTree {
                List(store.keyNodes, children: \.children, selection: $treeSelection) { node in
                    HStack {
                        Image(systemName: node.isLeaf ? "key" : "folder")
                            .foregroundStyle(node.isLeaf ? .blue : .orange)
                        Text(node.name).lineLimit(1)
                        Spacer()
                        if store.checkedKeys.contains(node.fullPath) { Image(systemName: "checkmark.circle.fill") }
                    }
                    .font(.system(size: store.scaled(12)))
                    .draggable(node.fullPath)
                    .contextMenu {
                        if node.isLeaf { keyMenu(node.fullPath) }
                        else {
                            Button(L10n("Select all in group")) {
                                store.checkedKeys.formUnion(store.keys.filter { $0.hasPrefix(node.fullPath + store.separator) })
                            }
                            Button(L10n("Delete group")) { store.deleteKeys(store.keys.filter { $0.hasPrefix(node.fullPath + store.separator) }) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: treeSelection) { _, newValue in
                    guard let id = newValue, !id.hasPrefix("group:") else { return }
                    store.selectKey(id)
                }
            } else {
                List(store.filteredKeys(), id: \.self, selection: $store.selectedKey) { key in
                    HStack {
                        Image(systemName: "key").foregroundStyle(.blue)
                        Text(key).lineLimit(1)
                        Spacer()
                        Button { toggleCheck(key) } label: {
                            Image(systemName: store.checkedKeys.contains(key) ? "checkmark.square" : "square")
                        }.buttonStyle(.plain)
                    }
                    .font(.system(size: store.scaled(12)))
                    .draggable(key)
                    .contextMenu { keyMenu(key) }
                    .onTapGesture(count: 2) { store.selectKey(key) }
                }
                .onChange(of: store.selectedKey) { _, newValue in
                    if let key = newValue { store.selectKey(key) }
                }
            }
            }
            .onAppear { scrollProxy = proxy }
            }
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
                    Text(rows[index].0).font(.system(size: 12, design: .monospaced)).frame(width: 110, alignment: .leading)
                    Text(rows[index].1).font(.system(size: 12))
                    Spacer()
                }
            }
            Button(L10n("Close")) { dismiss() }.padding()
        }
    }
}
