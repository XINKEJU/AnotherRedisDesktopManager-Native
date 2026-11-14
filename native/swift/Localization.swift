import Foundation
import JavaScriptCore

/// Runtime localization moved out of Services.m. Language tables are the same
/// `src/i18n/langs/*.js` modules; they are evaluated with JavaScriptCore and
/// cached as JSON.
final class ARDMLocalization {

    private static let sharedInstance = ARDMLocalization()

    static func shared() -> ARDMLocalization { sharedInstance }

    static let allLanguages = ["cn", "de", "en", "es", "fr", "it", "ko", "pt", "ru", "tr", "tw", "ua", "vi"]

    let languages = ARDMLocalization.allLanguages

    private let tables: [String: [String: Any]]
    private let englishIndex: [String: String]

    private var storedLanguage: String
    var currentLanguage: String {
        get { storedLanguage }
        set {
            storedLanguage = newValue
            UserDefaults.standard.set(newValue, forKey: "ARDMLanguage")
        }
    }

    private init() {
        var loaded: [String: [String: Any]] = [:]
        for code in ARDMLocalization.allLanguages {
            loaded[code] = ARDMLocalization.loadTable(code) ?? [:]
        }
        tables = loaded
        // Upstream tables nest their strings (`message.new_connection`), so a flat
        // pass over the top level indexes nothing and every English-text lookup
        // degrades to identity. Flatten first. Key order is applied because
        // several keys share one English string ("Refresh"), and an unordered
        // dictionary walk would pick a different one per launch.
        var index: [String: String] = [:]
        for (key, text) in ARDMLocalization.flatten(loaded["en"] ?? [:], "").sorted(by: { $0.key < $1.key }) {
            index[text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = key
        }
        englishIndex = index
        storedLanguage = UserDefaults.standard.string(forKey: "ARDMLanguage") ?? "en"
    }

    /// Dotted key path -> string value for every leaf of a nested table.
    private static func flatten(_ table: [String: Any], _ prefix: String) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in table {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let text = value as? String {
                out[path] = text
            } else if let nested = value as? [String: Any] {
                out.merge(flatten(nested, path)) { _, newest in newest }
            }
        }
        return out
    }

    // MARK: - Table loading

    private static func resourceLanguagesDirectory() -> String {
        ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("langs")
    }

    /// Fall back to the checkout's src/i18n/langs when running unbundled,
    /// without a machine-specific absolute path.
    private static func sourceRoot() -> String? {
        let fm = FileManager.default
        var starts: [String] = []
        if let env = ProcessInfo.processInfo.environment["ARDM_PROJECT_ROOT"], !env.isEmpty {
            starts.append(env)
        }
        let bundle = Bundle.main.bundlePath
        if !bundle.isEmpty { starts.append(bundle) }
        starts.append(fm.currentDirectoryPath)
        for start in starts {
            var dir = start
            for _ in 0..<6 where dir.count > 1 {
                let candidate = (dir as NSString).appendingPathComponent("src/i18n/langs/en.js")
                if fm.fileExists(atPath: candidate) { return dir }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
        }
        return nil
    }

    private static func loadTable(_ code: String) -> [String: Any]? {
        let fm = FileManager.default
        let fileName = "\(code).js"
        var candidates = [(resourceLanguagesDirectory() as NSString).appendingPathComponent(fileName)]
        if let root = sourceRoot() {
            candidates.append(((root as NSString).appendingPathComponent("src/i18n/langs") as NSString)
                .appendingPathComponent(fileName))
        }
        for path in candidates {
            guard fm.fileExists(atPath: path),
                  var source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            source = source.replacingOccurrences(of: "export default", with: "module.exports =")
            guard let context = JSContext() else { return nil }
            context.evaluateScript("var module = { exports: {} };")
            context.evaluateScript(source)
            let json = context.evaluateScript("JSON.stringify(module.exports || {})")?.toString() ?? "{}"
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let table = object as? [String: Any] else { return nil }
            return table
        }
        return nil
    }

    // MARK: - Lookup

    private static func lookup(_ key: String, in table: [String: Any]) -> String? {
        if let value = table[key] as? String { return value }
        var node: Any = table
        for part in key.components(separatedBy: ".") {
            guard let dict = node as? [String: Any], let next = dict[part] else { return nil }
            node = next
        }
        return node as? String
    }

    func t(_ key: String) -> String {
        let table = tables[currentLanguage] ?? tables["en"] ?? [:]
        return ARDMLocalization.lookup(key, in: table) ?? key
    }

    /// The active language's official wording for an English label, or nil when it
    /// carries none. `t(_:)` echoes the key back on a miss, which would put
    /// 「message.foo」 in front of the user, so the miss is detected here instead.
    func translation(forEnglishText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let key = englishIndex[trimmed] else { return nil }
        let value = t(key)
        guard !value.isEmpty, value != key else { return nil }
        return value
    }
}
