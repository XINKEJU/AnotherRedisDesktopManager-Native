import SwiftUI
import AppKit

// MARK: - Command palette (⌘K)

/// One palette line. Section headers are rows so the arrow keys walk a single
/// flat list instead of juggling an index per section.
enum PaletteRow: Identifiable {
    case header(String)
    case item(PaletteItem)

    var id: String {
        switch self {
        case .header(let title): return "§" + title
        case .item(let item): return item.id
        }
    }

    var isSelectable: Bool {
        if case .item = self { return true }
        return false
    }
}

/// A thing the palette can act on. `run` closes over whatever the action needs,
/// so keys, connections and commands all take the same path through the view.
struct PaletteItem: Identifiable {
    enum Kind { case key, connection, command }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: String
    /// Offsets into `title` whose characters matched the query, highlighted.
    let hits: Set<Int>
    let favourite: Bool
    let run: () -> Void
}

// MARK: - Matching

/// Subsequence matcher with the scoring a palette needs: a contiguous hit beats
/// a scattered one, a hit at a namespace boundary beats one mid-word, and a
/// short name beats a long one at an otherwise equal score.
enum QuickOpenMatcher {
    struct Match { let score: Int; let hits: Set<Int> }

    /// Redis keys and connection names are namespace-ish, so these are the
    /// places a query is most likely to start a word.
    private static let boundaries: Set<Character> = [":", "-", "_", ".", "/", " ", "@", "#"]

    static func match(_ needle: String, in text: String) -> Match? {
        let q = needle.lowercased()
        guard !q.isEmpty, !text.isEmpty else { return nil }
        let lower = text.lowercased()
        // Cheap reject first: one missing character ends the search before any
        // per-character work starts, which is most of the cost on a large page.
        for ch in q where !lower.contains(ch) { return nil }

        if let range = lower.range(of: q) {
            let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
            var score = 1000 - min(start * 4, 320)
            if start == 0 {
                score += 260
            } else if boundaries.contains(Array(text.prefix(start)).last ?? ":") {
                score += 130
            }
            score -= text.count / 16
            return Match(score: score, hits: Set(start..<(start + q.count)))
        }

        // Greedy earliest match: it never misses a subsequence that exists, and
        // the boundary/adjacency bonuses recover most better alignments without
        // the cost of a dynamic-programming search per candidate.
        var hits = Set<Int>()
        var score = 0
        var last = -2
        var prev: Character = ":"
        var offset = 0
        var qi = q.startIndex
        for (ch, low) in zip(text, lower) {
            if qi < q.endIndex, low == q[qi] {
                var step = 8
                if offset == 0 || boundaries.contains(prev) { step += 26 }
                if offset == last + 1 { step += 12 }
                score += step
                hits.insert(offset)
                last = offset
                qi = q.index(after: qi)
            }
            prev = ch
            offset += 1
            if qi == q.endIndex { break }
        }
        guard qi == q.endIndex else { return nil }
        score = 300 + score - (hits.min() ?? 0) - text.count / 16
        return Match(score: score, hits: hits)
    }

    /// Highest `limit` scores, best first. Sorting the whole candidate list is
    /// the easy way to lose a frame on a large page, so only the top rows are
    /// kept and everything else is dropped while it is scored.
    static func top<T>(_ limit: Int, _ candidates: [(T, Match)]) -> [(T, Match)] {
        var best: [(T, Match)] = []
        best.reserveCapacity(limit + 1)
        for candidate in candidates {
            if best.count < limit {
                best.append(candidate)
                if best.count == limit { best.sort { $0.1.score > $1.1.score } }
            } else if candidate.1.score > best[limit - 1].1.score {
                best.removeLast()
                best.append(candidate)
                var index = limit - 1
                while index > 0, best[index - 1].1.score < best[index].1.score {
                    best.swapAt(index, index - 1)
                    index -= 1
                }
            }
        }
        return best
    }
}

// MARK: - Commands

/// A palette entry that runs something instead of opening something.
struct PaletteCommand {
    let title: String
    let hint: String
    let icon: String
    let featured: Bool
    let run: (AppStore) -> Void
}

extension PaletteCommand {
    /// `featured` keeps the empty palette a short list of what a user reaches
    /// for twice a day; everything else still appears once they type.
    ///
    /// Nothing here destroys data: deleting keys stays behind the list's own
    /// confirmation, so the palette never needs a second one.
    static let all: [PaletteCommand] = {
        var list: [PaletteCommand] = [
            PaletteCommand(title: "Refresh Keys", hint: "⌘R", icon: "arrow.clockwise", featured: true,
                           run: { $0.refreshKeys(reset: true) }),
            PaletteCommand(title: "Load all", hint: "", icon: "tray.full", featured: true,
                           run: { $0.loadAllKeys() }),
            PaletteCommand(title: "Search Keys", hint: "⌘F", icon: "magnifyingglass", featured: true,
                           run: { store in
                               store.activeTab = .keys
                               store.searchFocusRequest += 1
                           }),
            PaletteCommand(title: "New Key", hint: "⇧⌘N", icon: "plus.circle", featured: true,
                           run: { $0.showingNewKey = true }),
            PaletteCommand(title: "New Connection", hint: "⌘N", icon: "plus.rectangle.on.rectangle", featured: true,
                           run: { store in
                               store.editingConnection = nil
                               store.showingConnectionEditor = true
                           }),
            PaletteCommand(title: "Settings…", hint: "⌘,", icon: "gearshape", featured: true,
                           run: { $0.showingSettings = true }),
            PaletteCommand(title: "Toggle Tree View", hint: "", icon: "list.bullet.indent", featured: false,
                           run: { store in
                               store.showTree.toggle()
                               store.buildTree()
                           }),
            PaletteCommand(title: "Merge single-child levels", hint: "", icon: "arrow.triangle.merge", featured: false,
                           run: { $0.collapseTreeChains.toggle() }),
            PaletteCommand(title: "Only without expiry", hint: "", icon: "clock.badge.questionmark", featured: false,
                           run: { $0.onlyNoExpiry.toggle() }),
            PaletteCommand(title: "Add to Favorites", hint: "", icon: "star", featured: false,
                           run: { store in
                               guard let key = store.selectedKey else { return }
                               if let index = store.favoriteKeys.firstIndex(of: key) {
                                   store.favoriteKeys.remove(at: index)
                               } else {
                                   store.favoriteKeys.append(key)
                               }
                               store.saveFavorites()
                           }),
            PaletteCommand(title: "Batch Delete…", hint: "", icon: "rectangle.3.group", featured: false,
                           run: { $0.showingBatchDelete = true }),
            PaletteCommand(title: "Rename…", hint: "", icon: "pencil", featured: false,
                           run: { $0.showingRename = true }),
            PaletteCommand(title: "Set TTL…", hint: "", icon: "timer", featured: false,
                           run: { $0.showingTTL = true }),
            PaletteCommand(title: "Keyboard Shortcuts…", hint: "", icon: "keyboard", featured: false,
                           run: { $0.showingHotKeys = true }),
            PaletteCommand(title: "Connect", hint: "", icon: "bolt", featured: false,
                           run: { store in
                               if let connection = store.selectedConnection { store.connect(to: connection) }
                           }),
            PaletteCommand(title: "Disconnect", hint: "", icon: "bolt.slash", featured: false,
                           run: { $0.disconnect() })
        ]
        // The nine workspace tabs are commands too, and ⌘1…⌘9 is exactly the
        // kind of thing a palette exists to make unnecessary to remember.
        for (index, tab) in MainTab.allCases.enumerated() {
            list.append(PaletteCommand(title: tab.title,
                                       hint: index < 9 ? "⌘\(index + 1)" : "",
                                       icon: tab.icon,
                                       featured: false) { $0.activeTab = tab })
        }
        return list
    }()
}

// MARK: - Result building

extension QuickOpenMatcher {
    /// Keys scanned per keystroke, capped: a palette that ranked all 200k
    /// loaded keys would feel slower than one that finds the row you wanted.
    private static let scanLimit = 30_000

    static func rows(query: String, store: AppStore) -> [PaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let commandsOnly = trimmed.hasPrefix(">")
        let needle = commandsOnly
            ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            : trimmed
        var rows: [PaletteRow] = []

        if needle.isEmpty && !commandsOnly {
            append(&rows, header: L10n("Favorites"), items: favourites(store))
            append(&rows, header: L10n("Recent"), items: recents(store))
            append(&rows, header: L10n("Connections"), items: connections(store, needle: ""))
            append(&rows, header: L10n("Commands"), items: commands(store, needle: "", featuredOnly: true))
            return rows
        }

        if !commandsOnly {
            append(&rows, header: L10n("Keys"), items: keys(store, needle: needle))
        }
        append(&rows, header: L10n("Connections"), items: connections(store, needle: needle))
        append(&rows, header: L10n("Commands"), items: commands(store, needle: needle, featuredOnly: false))
        return rows
    }

    private static func append(_ rows: inout [PaletteRow], header: String, items: [PaletteItem]) {
        guard !items.isEmpty else { return }
        rows.append(.header(header))
        rows.append(contentsOf: items.map { PaletteRow.item($0) })
    }

    /// The type pill and the expiry carry what a row needs; the name is the
    /// whole point of the row, so it gets all the remaining width.
    private static func keyItem(_ key: String, store: AppStore, hits: Set<Int>,
                                favourites: Set<String>) -> PaletteItem {
        let ttl = store.keyMeta[key]?.ttl ?? 0
        return PaletteItem(id: "key:" + key,
                           kind: .key,
                           title: key,
                           subtitle: ttl > 0 ? ARDMFormat.ttl(ttl) : "",
                           icon: "",
                           hits: hits,
                           favourite: favourites.contains(key),
                           run: { store.selectKey(key) })
    }

    private static func keys(_ store: AppStore, needle: String) -> [PaletteItem] {
        var scored: [(String, Match)] = []
        scored.reserveCapacity(128)
        for key in store.keys.prefix(scanLimit) {
            if let hit = match(needle, in: key) { scored.append((key, hit)) }
        }
        let favourites = Set(store.favoriteKeys)
        return top(40, scored).map { key, hit in
            keyItem(key, store: store, hits: hit.hits, favourites: favourites)
        }
    }

    private static func favourites(_ store: AppStore) -> [PaletteItem] {
        let favourites = Set(store.favoriteKeys)
        return store.favoriteKeys.prefix(8).map {
            keyItem($0, store: store, hits: [], favourites: favourites)
        }
    }

    private static func recents(_ store: AppStore) -> [PaletteItem] {
        let favourites = Set(store.favoriteKeys)
        return store.recentKeys.prefix(8).map {
            keyItem($0, store: store, hits: [], favourites: favourites)
        }
    }

    private static func connections(_ store: AppStore, needle: String) -> [PaletteItem] {
        let scored: [(ARDMConnectionConfig, Match)] = store.connections.compactMap { connection in
            guard !needle.isEmpty else { return (connection, Match(score: 0, hits: [])) }
            guard let hit = match(needle, in: "\(connection.name) \(connection.host):\(connection.port) \(connection.group)")
            else { return nil }
            return (connection, hit)
        }
        return top(8, scored).map { connection, _ in
            // Highlight whichever half of the searched string the query hit:
            // the score came from name + host, but only one of them is on screen.
            let hits = needle.isEmpty ? Set<Int>()
                : match(needle, in: connection.name)?.hits
                ?? match(needle, in: connection.host)?.hits
                ?? []
            return PaletteItem(id: "conn:" + connection.identifier,
                               kind: .connection,
                               title: connection.name,
                               subtitle: "\(connection.host):\(connection.port)",
                               icon: "",
                               hits: hits,
                               favourite: false,
                               run: { store.switchConnection(connection.identifier) })
        }
    }

    /// Commands are matched against the label the row actually shows. The
    /// English name stays a searchable alias — a Chinese UI user who learned
    /// "settings" should still land on 设置… — but an alias hit cannot be
    /// highlighted, since those offsets are not on screen.
    private static func commands(_ store: AppStore, needle: String,
                                 featuredOnly: Bool) -> [PaletteItem] {
        PaletteCommand.all
            .filter { !featuredOnly || $0.featured }
            .compactMap { command -> (PaletteCommand, Match)? in
                guard !needle.isEmpty else { return (command, Match(score: 0, hits: [])) }
                if let hit = match(needle, in: L10n(command.title)) { return (command, hit) }
                if let hit = match(needle, in: command.title) {
                    return (command, Match(score: hit.score - 150, hits: []))
                }
                return nil
            }
            .sorted { $0.1.score > $1.1.score }
            .prefix(14)
            .map { command, hit in
                PaletteItem(id: "cmd:" + command.title + command.hint,
                            kind: .command,
                            title: L10n(command.title),
                            subtitle: command.hint,
                            icon: command.icon,
                            hits: needle.isEmpty ? [] : hit.hits,
                            favourite: false,
                            run: { command.run(store) })
            }
    }
}

// MARK: - The palette

/// Top-floating panel over the three columns: the work behind it stays visible
/// rather than dimmed, and it goes away on Esc, on ↩, or on a click outside.
struct QuickOpenPalette: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var rows: [PaletteRow] = []
    @State private var selection = 0
    @State private var settle: DispatchWorkItem?
    @FocusState private var fieldFocused: Bool

    private static let rowHeight: CGFloat = 30
    private static let headerHeight: CGFloat = 22

    var body: some View {
        ZStack(alignment: .top) {
            // Transparent but hit-tested: a click anywhere else closes the
            // palette, which is what the keyboard-first clients do.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.5)
                content
                Divider().opacity(0.5)
                footer
            }
            .frame(width: 620, height: panelHeight, alignment: .top)
            .ardmGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refresh()
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: query) { _, text in scheduleRefresh(text) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ARDMFont.body, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L10n("Search keys, connections and commands…"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: ARDMFont.title))
                .focused($fieldFocused)
                .onSubmit { activate(selection) }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .accessibilityIdentifier("quickopen.field")
            Text("esc")
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.14)))
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    // MARK: Results

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: store.keys.isEmpty ? "cylinder.questionmark" : "magnifyingglass")
                    .font(.system(size: ARDMIcon.emptyState))
                    .foregroundStyle(.tertiary)
                Text(store.keys.isEmpty ? L10n("Load keys first") : L10n("No matches"))
                    .font(.system(size: ARDMFont.body))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            switch row {
                            case .header(let title):
                                Text(title)
                                    .font(.system(size: ARDMFont.micro, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .frame(height: Self.headerHeight)
                            case .item(let item):
                                rowView(item, index: index, active: index == selection)
                                    .id(index)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selection) { _, newValue in
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func rowView(_ item: PaletteItem, index: Int, active: Bool) -> some View {
        HStack(spacing: 8) {
            leadingMark(for: item)
            highlighted(item.title, item.hits)
                .font(item.kind == .key
                      ? .system(size: ARDMFont.monoRow, design: .monospaced)
                      : .system(size: ARDMFont.body))
                .lineLimit(1)
                .truncationMode(item.kind == .key ? .middle : .tail)
            Spacer(minLength: 8)
            if item.favourite {
                Image(systemName: "star.fill")
                    .font(.system(size: ARDMFont.micro))
                    .foregroundStyle(.tertiary)
            }
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: ARDMFont.micro))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering in if hovering { selection = index } }
        .onTapGesture { activate(index) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityLabel(item.title)
    }

    @ViewBuilder private func leadingMark(for item: PaletteItem) -> some View {
        switch item.kind {
        case .key:
            if let meta = store.keyMeta[item.title] {
                ARDMTypeBadge(type: meta.type)
            } else {
                ARDMTypeBadge(type: .string, dimmed: true)
            }
        case .connection:
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: ARDMFont.small))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
        case .command:
            Image(systemName: item.icon)
                .font(.system(size: ARDMFont.small))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
        }
    }

    /// Matched characters take the accent colour and more weight, so the eye
    /// lands on the part of the name the query actually explained.
    private func highlighted(_ text: String, _ hits: Set<Int>) -> Text {
        guard !hits.isEmpty else { return Text(text) }
        var out = Text("")
        for (offset, character) in text.enumerated() {
            let piece = Text(String(character))
            out = out + (hits.contains(offset)
                         ? piece.foregroundStyle(Color.accentColor).fontWeight(.semibold)
                         : piece.foregroundStyle(.primary))
        }
        return out
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(selectableCount) " + L10n("results"))
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            Text("↑↓ · ↩ · > " + L10n("commands"))
                .font(.system(size: ARDMFont.micro))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: ardmScaled(26))
    }

    // MARK: Behaviour

    private var selectableCount: Int { rows.filter(\.isSelectable).count }

    private var panelHeight: CGFloat {
        let headers = rows.count - selectableCount
        let body = CGFloat(selectableCount) * Self.rowHeight + CGFloat(headers) * Self.headerHeight
        return min(max(44 + body + 24 + 8, 150), 460)
    }

    /// Debounced so a fast typist pays for one pass over the key list rather
    /// than one per keystroke — short enough that the result still feels
    /// immediate.
    private func scheduleRefresh(_ text: String) {
        settle?.cancel()
        let work = DispatchWorkItem { refresh(text) }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func refresh(_ text: String = "") {
        // Stay on the same row across a refresh when it is still a result;
        // otherwise land on the first thing that can be opened.
        let previousID: String? = switch rows[safe: selection] {
        case .item(let item): item.id
        default: nil
        }
        rows = QuickOpenMatcher.rows(query: text.isEmpty ? query : text, store: store)
        if let previousID,
           let index = rows.firstIndex(where: { row in
               if case .item(let item) = row { return item.id == previousID }
               return false
           }) {
            selection = index
        } else {
            selection = rows.firstIndex(where: \.isSelectable) ?? 0
        }
    }

    /// Arrow keys skip section headers, which are not things you can open.
    private func move(_ delta: Int) {
        guard selectableCount > 0 else { return }
        var index = selection
        repeat {
            let next = index + delta
            if next < 0 || next >= rows.count { return }
            index = next
        } while !rows[index].isSelectable
        selection = index
    }

    private func activate(_ index: Int) {
        guard index >= 0, index < rows.count, case .item(let item) = rows[index] else { return }
        item.run()
        close()
    }

    private func close() {
        settle?.cancel()
        store.showingQuickOpen = false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
