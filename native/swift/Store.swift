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
    @Published var keys: [String] = []
    @Published var keyNodes: [KeyNode] = []
    @Published var selectedKey: String?
    @Published var searchText = ""
    @Published var matchMode: MatchMode = .glob
    @Published var scanCursor: UInt = 0
    @Published var scanFinished = false
    @Published var selectedDB = 0
    @Published var dbSize = 0
    @Published var selectedKeyType: ARDMKeyType = .unknown
    @Published var selectedKeyTTL: Int = -1
    @Published var selectedKeyTTLMillis: Int = -1
    @Published var keyRows: [KeyRow] = []
    @Published var keyRawValue = Data()
    @Published var viewerName = "Text"
    @Published var renderedValue = ""
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
    @Published var checkedKeys: Set<String> = []
    @Published var favoriteKeys: [String] = []
    /// Persisted tree expansion state (KeyListVirtualTree.vue).
    @Published var expandedNodeIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ARDMExpandedNodes") ?? [])
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
    @Published var updateStatus = ""

    let languages = ARDMLocalization.shared().languages
    let fonts = ARDMAppServices.availableFonts()
    let viewers = ARDMFormatters.viewerNames()

    private init() {
        connections = ARDMConnectionConfig.loadAll()
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
