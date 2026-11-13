import Foundation
import SwiftUI
import SwiftUI

// MARK: - Domain models

enum MainTab: String, CaseIterable, Identifiable {
    case keys, cli, status, slowLog, memory, cluster, pubsub, monitor, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keys: return "Keys"
        case .cli: return "CLI"
        case .status: return "Status"
        case .slowLog: return "Slow Log"
        case .memory: return "Memory"
        case .cluster: return "Cluster"
        case .pubsub: return "Pub/Sub"
        case .monitor: return "Monitor"
        case .logs: return "Command Log"
        }
    }
    var icon: String {
        switch self {
        case .keys: return "key.fill"
        case .cli: return "chevron.left.forwardslash.chevron.right"
        case .status: return "waveform.path.ecg"
        case .slowLog: return "tortoise.fill"
        case .memory: return "memorychip"
        case .cluster: return "square.grid.3x3"
        case .pubsub: return "dot.radiowaves.left.and.right"
        case .monitor: return "eye"
        case .logs: return "list.bullet.rectangle"
        }
    }
}

struct KeyRow: Identifiable, Equatable {
    var id: String
    var field: String
    var value: String
    var extra: String = ""
    var raw: Data = Data()
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let connection: String
    let command: String
    let cost: Double
}

struct LiveEvent: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

struct InfoSection: Identifiable {
    let id = UUID()
    var name: String
    var fields: [(String, String)]
}

/// Recursive node used by `List(..., children:)` to reproduce KeyListVirtualTree.vue.
struct KeyNode: Identifiable {
    var id: String
    var name: String
    var fullPath: String
    var isLeaf: Bool
    var children: [KeyNode]?
}

/// Recursive node for connection groups in the sidebar.
struct ConnectionGroup: Identifiable {
    var id: String
    var name: String
    var configs: [ARDMConnectionConfig]
}

enum MatchMode: String, CaseIterable, Identifiable {
    case exact, glob, fuzzy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .exact: return "Exact"
        case .glob: return "Glob"
        case .fuzzy: return "Fuzzy"
        }
    }
}

/// Live socket state per connection. Surfaced as the sidebar tab dot and the
/// reconnect banner, so a dropped socket is visible instead of silently failing
/// on the next command.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, total: Int)
    case failed(String)

    var isOnline: Bool { if case .connected = self { return true }; return false }
    var isBusy: Bool { if case .reconnecting = self { return true }; return false }

    var label: String {
        switch self {
        case .disconnected: return L10n("Disconnected")
        case .connecting: return L10n("Connecting") + "…"
        case .connected: return L10n("Connected")
        case .reconnecting(let attempt, let total): return L10n("Reconnecting") + " \(attempt)/\(total)…"
        case .failed(let reason): return L10n("Connection lost") + ": " + reason
        }
    }
}

/// Tri-state used by the tree-view checkboxes when a folder holds a mixed
/// selection (some children checked, some not).
enum GroupCheckState { case none, partial, all }

/// Column-header ordering for the key list (PaginationTable.vue's sortable header).
enum KeySortOrder: String, CaseIterable, Identifiable {
    case none, nameAsc, nameDesc, lengthAsc, lengthDesc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Scan order"
        case .nameAsc: return "Key name (A→Z)"
        case .nameDesc: return "Key name (Z→A)"
        case .lengthAsc: return "Key length (short→long)"
        case .lengthDesc: return "Key length (long→short)"
        }
    }
    var isByName: Bool { self == .nameAsc || self == .nameDesc }
    var isDescending: Bool { self == .nameDesc || self == .lengthDesc }
}

// MARK: - Localization (13 language files via JavaScriptCore)

func L(_ key: String, _ fallback: String? = nil) -> String {
    let value = ARDMLocalization.shared().t(key)
    if value.isEmpty || value == key { return fallback ?? key }
    return value
}

/// Localise a UI label. Chinese uses the explicit table; the other 12 languages
/// resolve upstream message keys, then exact phrases, then word-wise translation.
func L10n(_ english: String) -> String { uiLocalized(english) }

/// A fresh install starts in Chinese on Chinese-language macOS installations.
func uiDefaultLanguage() -> String {
    let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
    if preferred.hasPrefix("zh-hans") || preferred.hasPrefix("zh-cn") || preferred == "zh" { return "cn" }
    if preferred.hasPrefix("zh-hant") || preferred.hasPrefix("zh-tw") { return "tw" }
    return "en"
}

// MARK: - Global application state

final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var connections: [ARDMConnectionConfig] = []
    @Published var selectedConnectionID: String?
    @Published var client: ARDMRedisClient?
    @Published var connected = false
    /// Per-connection socket state keyed by config identifier. The active entry
    /// also drives the reconnect banner.
    @Published var connectionStates: [String: ConnectionState] = [:]
    /// One-shot notice shown after plaintext passwords were moved into the Keychain.
    @Published var keychainMigrationNotice: String?
    /// Tabs.vue: multiple connections stay open concurrently and can be switched.
    @Published var openConnectionIDs: [String] = []
    @Published var activeConnectionID: String?
    var clients: [String: ARDMRedisClient] = [:]
    var keyCache: [String: [String]] = [:]
    @Published var activeTab: MainTab = .keys
    @Published var statusText = L10n("Not connected")
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    // Key browser
    /// `filteredKeys()` is read from several places inside a single body
    /// evaluation (count badge, selection banner, list, toolbar). Each call used
    /// to re-filter and re-sort the entire key list, so one keystroke over a
    /// 100k-key page ran the ICU collator hundreds of thousands of times. The
    /// caches below make a body evaluation cost one pass; the didSet hooks
    /// invalidate them only when an input actually changes.
    var filteredKeysCache: [String]?
    var sortedKeysCache: [String]?
    var lowercasedKeysCache: [String]?
    @Published var keys: [String] = [] {
        didSet { invalidateKeyCaches() }
    }
    @Published var keyNodes: [KeyNode] = []
    @Published var selectedKey: String?
    @Published var searchText = "" {
        didSet { invalidateKeyCaches(scope: .filter) }
    }
    /// Second-pass filter over the keys already loaded from SCAN. Never triggers a
    /// server round-trip, so narrowing a 100k-key page stays instant.
    @Published var localFilter = "" {
        didSet { invalidateKeyCaches(scope: .filter) }
    }
    @Published var localFilterRegex = false {
        didSet { invalidateKeyCaches(scope: .filter) }
    }
    /// Incremented by the ⌘F menu command so the key search field can grab focus.
    @Published var searchFocusRequest = 0
    @Published var matchMode: MatchMode = .glob {
        didSet { invalidateKeyCaches(scope: .filter) }
    }
    /// Key-list column ordering (persisted). `.none` keeps the server's SCAN order.
    @Published var keySortOrder: KeySortOrder = KeySortOrder(
        rawValue: UserDefaults.standard.string(forKey: "ARDMKeySortOrder") ?? "none") ?? .none {
        didSet {
            UserDefaults.standard.set(keySortOrder.rawValue, forKey: "ARDMKeySortOrder")
            invalidateKeyCaches()
        }
    }
    @Published var scanCursor: UInt = 0
    @Published var scanFinished = false
    /// Which caches a change can affect. Filtering depends on the loaded keys and
    /// the sort order, so a new `keys` array drops both; a new needle only drops
    /// the filtered result and reuses the sorted list.
    enum KeyCacheScope { case all, filter }

    func invalidateKeyCaches(scope: KeyCacheScope = .all) {
        filteredKeysCache = nil
        if scope == .all {
            sortedKeysCache = nil
            lowercasedKeysCache = nil
        }
    }

    @Published var selectedDB = 0
    @Published var dbSize = 0
    @Published var selectedKeyType: ARDMKeyType = .unknown
    @Published var selectedKeyTTL: Int = -1
    @Published var selectedKeyTTLMillis: Int = -1
    @Published var keyRows: [KeyRow] = []
    @Published var keyRawValue = Data()
    @Published var viewerName = "Text"
    @Published var renderedValue = ""
    /// OverSize viewer pagination: byte offset and window size.
    @Published var oversizeOffset = 0
    let oversizeChunkSize = 4096
    @Published var editorText = ""
    @Published var jsonPath = "$"
    @Published var rowOffset = 0
    @Published var rowLimit = 100
    /// Cursor for HSCAN/SSCAN/ZSCAN streaming reads of large collections.
    @Published var rowScanCursor = "0"
    @Published var rowScanFinished = true
    /// Field-level TTLs (Redis >= 7.4 HTTL / HEXPIRE), keyed by hash field.
    @Published var fieldTTLs: [String: Int] = [:]
    @Published var ttlInMilliseconds = false
    @Published var rowSearchPattern = "*"
    @Published var timeSeriesReverse = false
    @Published var streamReverse = false
    /// HLEN of the currently selected hash (Redis >= any version).
    @Published var hashLen = 0
    /// Detected server version, e.g. "7.4.1"; gates Redis >= 7.4 field-TTL support.
    @Published var redisVersion = ""
    /// Dedicated CLI connection (mirrors upstream client.duplicate()), so long commands
    /// and MONITOR never block the key browser. Created lazily on connect.
    var cliClient: ARDMRedisClient?
    // SlowLog thresholds surfaced from CONFIG GET.
    @Published var slowLogSlowerThan = 10000
    @Published var slowLogMaxLen = 128
    /// Keyspace partition stats parsed from INFO keyspace.
    @Published var keyspaceStats: [(String, String)] = []
    /// Per-key memory usage scan (MEMORY USAGE), filtered by min size.
    @Published var memoryPerKeyRows: [(String, Int)] = []
    @Published var memoryMinSize: Double = 1024
    /// Progress / cancellation state for the per-key MEMORY USAGE scan.
    @Published var memoryScanRunning = false
    @Published var memoryScanned = 0
    @Published var memoryScanTotal = 1
    var memoryScanToken = 0
    /// Stream consumer-groups / consumers (XINFO GROUPS / XINFO CONSUMERS).
    @Published var streamGroups: [[String: Any]] = []
    @Published var streamConsumers: [[String: Any]] = []
    /// TimeSeries aggregation / filter options for TS.RANGE / TS.REVRANGE.
    @Published var tsAggregation = "None"
    @Published var tsBucket = "1000"
    @Published var tsFilterMin = ""
    @Published var tsFilterMax = ""
    @Published var tsInfo: [[String]] = []
    /// Vector quantization selector passed to VADD / shown in the detail view.
    /// Valid Redis options: NOQUANT / Q8 / BIN (Q4/Q6 on newer servers).
    @Published var vectorQuantization = "NOQUANT"
    /// Sidebar width (persisted) and key-search history (persisted).
    @Published var sidebarWidth: Double = UserDefaults.standard.double(forKey: "ARDMSidebarWidth").nonZero(or: 240) {
        didSet { UserDefaults.standard.set(sidebarWidth, forKey: "ARDMSidebarWidth") }
    }
    @Published var searchHistory: [String] = UserDefaults.standard.stringArray(forKey: "ARDMKeySearchHistory") ?? []
    @Published var checkedKeys: Set<String> = []
    @Published var favoriteKeys: [String] = []
    /// Persisted tree expansion state (KeyListVirtualTree.vue).
    @Published var expandedNodeIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ARDMExpandedNodes") ?? [])
    /// folder path → every key beneath it. Rebuilt by buildTree() so the tree's
    /// tri-state checkboxes are O(1) per row instead of scanning all keys.
    var groupMembership: [String: [String]] = [:]
    var keepaliveTimer: Timer?

    // CLI & logs
    @Published var cliInput = ""
    @Published var cliOutput = ""
    @Published var cliHistory: [String] = []
    @Published var cliHistoryIndex = 0
    /// CliTab.vue transaction queue: nil = outside MULTI, [] = inside MULTI.
    @Published var multiQueue: [[String]]?
    @Published var logs: [LogEntry] = []
    @Published var commandReference: [String: Any] = [:]

    // Monitoring
    @Published var infoSections: [InfoSection] = []
    @Published var slowLogRows: [[String]] = []
    @Published var memoryStats: [(String, Double)] = []
    @Published var clusterSlots: [[String: Any]] = []
    @Published var clusterNodes: [[String: Any]] = []
    @Published var statusRefreshSeconds = 5
    @Published var statusAutoRefresh = false
    var statusTimer: Timer?
    @Published var liveEvents: [LiveEvent] = []
    @Published var liveRunning = false
    @Published var pubsubChannel = ""
    @Published var pubsubPattern = false

    // Settings (persisted)
    @Published var language: String = UserDefaults.standard.string(forKey: "ARDMLanguage") ?? uiDefaultLanguage() {
        didSet { UserDefaults.standard.set(language, forKey: "ARDMLanguage"); ARDMLocalization.shared().currentLanguage = language }
    }
    @Published var theme: String = UserDefaults.standard.string(forKey: "ARDMTheme") ?? "system" {
        didSet { UserDefaults.standard.set(theme, forKey: "ARDMTheme") }
    }
    @Published var fontFamily: String = UserDefaults.standard.string(forKey: "ARDMFontFamily") ?? "Menlo" {
        didSet { UserDefaults.standard.set(fontFamily, forKey: "ARDMFontFamily") }
    }
    @Published var fontSize: Double = UserDefaults.standard.double(forKey: "ARDMFontSize").nonZero(or: 13) {
        didSet { UserDefaults.standard.set(fontSize, forKey: "ARDMFontSize") }
    }
    @Published var zoom: Double = UserDefaults.standard.double(forKey: "ARDMZoom").nonZero(or: 1.0) {
        didSet { UserDefaults.standard.set(zoom, forKey: "ARDMZoom") }
    }
    @Published var pageSize: Int = UserDefaults.standard.integer(forKey: "ARDMPageSize") == 0 ? 500 : UserDefaults.standard.integer(forKey: "ARDMPageSize") {
        didSet { UserDefaults.standard.set(pageSize, forKey: "ARDMPageSize") }
    }
    @Published var separator: String = UserDefaults.standard.string(forKey: "ARDMSeparator") ?? ":" {
        didSet { UserDefaults.standard.set(separator, forKey: "ARDMSeparator") }
    }
    @Published var readOnly: Bool = UserDefaults.standard.bool(forKey: "ARDMReadOnly") {
        didSet { UserDefaults.standard.set(readOnly, forKey: "ARDMReadOnly") }
    }
    @Published var showTree: Bool = UserDefaults.standard.bool(forKey: "ARDMShowTree") {
        didSet { UserDefaults.standard.set(showTree, forKey: "ARDMShowTree") }
    }
    @Published var customFormatters: [[String: String]] = ARDMAppServices.customFormatters() {
        didSet { ARDMAppServices.saveCustomFormatters(customFormatters) }
    }
    @Published var customViewerScript: String = UserDefaults.standard.string(forKey: "ARDMCustomViewer") ?? "return new TextDecoder().decode(bytes);" {
        didSet { UserDefaults.standard.set(customViewerScript, forKey: "ARDMCustomViewer") }
    }

    // Sheets
    @Published var showingConnectionEditor = false
    @Published var editingConnection: ARDMConnectionConfig?
    @Published var showingSettings = false
    @Published var showingNewKey = false
    @Published var showingBatchDelete = false
    @Published var showingRename = false
    @Published var showingTTL = false
    @Published var showingImportExport = false
    @Published var showingHotKeys = false
    @Published var showingFormatterManager = false
    @Published var showingJsonEditor = false
    /// ZSet batch editor: pattern + action applied to every loaded member.
    @Published var showingZSetBatch = false
    @Published var zsetBatchPattern = "*"
    @Published var zsetBatchAction = "Delete"
    @Published var zsetBatchScore = "0"
    /// Byte-level hex editor state. The tail beyond `hexEditLimit` is kept as-is
    /// and re-appended on save so large values are never truncated silently.
    @Published var showingHexEditor = false
    @Published var hexBytes: [UInt8] = []
    var hexTail = Data()
    let hexEditLimit = 8192
    @Published var updateStatus = ""

    let languages = ARDMLocalization.shared().languages
    let fonts = ARDMAppServices.availableFonts()
    let viewers = ARDMFormatters.viewerNames()

    private init() {
        connections = ARDMConnectionConfig.loadAll()
        // loadAll migrates legacy plaintext into the Keychain and leaves a count
        // behind; surface it once so nobody wonders where the passwords went.
        let migratedSecrets = ARDMConnectionConfig.consumeKeychainMigrationCount()
        if migratedSecrets > 0 {
            keychainMigrationNotice = "\(migratedSecrets) "
                + L10n("connection password(s) moved to the macOS Keychain; connections.json no longer stores them.")
        }
        ARDMLocalization.shared().currentLanguage = language
        commandReference = ARDMAppServices.commandReference()
        favoriteKeys = UserDefaults.standard.stringArray(forKey: "ARDMFavoriteKeys") ?? []
        cliHistory = UserDefaults.standard.stringArray(forKey: "ARDMCliHistory") ?? []
    }

    var selectedConnection: ARDMConnectionConfig? {
        connections.first { $0.identifier == selectedConnectionID }
    }

    func saveConnections() {
        ARDMConnectionConfig.saveAll(connections)
        objectWillChange.send()
    }

    func reloadConnections() {
        connections = ARDMConnectionConfig.loadAll()
    }

    func saveFavorites() {
        UserDefaults.standard.set(favoriteKeys, forKey: "ARDMFavoriteKeys")
    }

    func saveCliHistory() {
        let tail = Array(cliHistory.suffix(200))
        UserDefaults.standard.set(tail, forKey: "ARDMCliHistory")
    }

    /// Records a key-search term (de-duplicated, capped at 200) so it survives window close.
    func recordSearch(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        searchHistory.removeAll { $0 == t }
        searchHistory.insert(t, at: 0)
        if searchHistory.count > 200 { searchHistory.removeLast() }
        UserDefaults.standard.set(searchHistory, forKey: "ARDMKeySearchHistory")
    }

    var redisMajor: Int { Int(redisVersion.split(separator: ".").first ?? "0") ?? 0 }
    var redisMinor: Int {
        let parts = redisVersion.split(separator: ".")
        return parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
    }
    /// Redis >= 7.4 exposes HTTL / HEXPIRE field-level TTLs.
    var supportsFieldTTL: Bool { (redisMajor > 7) || (redisMajor == 7 && redisMinor >= 4) }

    func fail(_ message: String) {
        errorMessage = message
        statusText = message
    }

    func notify(_ message: String) {
        infoMessage = message
        statusText = message
    }

    var preferredColorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Base size is scaled by both the user font size and the zoom factor.
    func scaled(_ base: CGFloat) -> CGFloat { base * CGFloat(fontSize / 13.0) * CGFloat(zoom) }

    /// The user-selected font family is now actually applied to every editor/list font.
    func monoFont(_ base: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(fontFamily, size: scaled(base)).weight(weight)
    }
    func uiFont(_ base: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(fontFamily, size: scaled(base)).weight(weight)
    }

    /// Semantic fonts (.headline/.caption) follow the zoom setting via Dynamic Type.
    var dynamicTypeSize: DynamicTypeSize {
        switch zoom {
        case ..<0.8: return .xSmall
        case 0.8..<0.95: return .small
        case 0.95..<1.1: return .medium
        case 1.1..<1.3: return .large
        case 1.3..<1.5: return .xLarge
        default: return .xxLarge
        }
    }
}

private extension Double {
    func nonZero(or fallback: Double) -> Double { self == 0 ? fallback : self }
}
