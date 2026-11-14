import Foundation
import AppKit
import JavaScriptCore
import CryptoKit
import Security

/// Process-wide services that used to live in Transport.m: fonts, command
/// reference, custom formatters, connection import/export, auto-update,
/// downloads/install and security-scoped bookmarks.
enum ARDMAppServices {

    // MARK: - Paths

    private static func resourcePath(_ name: String) -> String {
        ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent(name)
    }

    /// Fall back to the checkout's src/commands.js when running unbundled,
    /// without relying on a machine-specific absolute path.
    private static func sourceCommandPath() -> String? {
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
                let candidate = (dir as NSString).appendingPathComponent("src/commands.js")
                if fm.fileExists(atPath: candidate) { return candidate }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
        }
        return nil
    }

    // MARK: - Fonts (font-list / font-manager.js)

    static func availableFonts() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Command reference (commands.js)

    static func commandReference() -> [String: Any] {
        var source = try? String(contentsOfFile: resourcePath("commands.js"), encoding: .utf8)
        if source == nil, let fallback = sourceCommandPath() {
            source = try? String(contentsOfFile: fallback, encoding: .utf8)
        }
        guard let script = source, let context = JSContext() else { return [:] }
        context.evaluateScript("var module = { exports: {} };")
        context.evaluateScript(script)
        let value = context.evaluateScript("JSON.stringify(module.exports.allCMD || {})")
        let json = value?.toString() ?? "{}"
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else { return [:] }
        return dict
    }

    // MARK: - Custom formatters (CustomFormatter.vue)

    static func customFormatters() -> [[String: String]] {
        if let saved = UserDefaults.standard.array(forKey: "ARDMCustomFormatters") as? [[String: String]],
           !saved.isEmpty {
            return saved
        }
        return [["name": "Default", "script": "return new TextDecoder().decode(bytes);"]]
    }

    static func saveCustomFormatters(_ items: [[String: String]]) {
        UserDefaults.standard.set(items, forKey: "ARDMCustomFormatters")
    }

    // MARK: - Connection import / export (Setting.vue)

    static func exportConnectionsJSON() -> String {
        let raw: [Any] = ARDMConnectionConfig.loadAll().map { $0.toDictionary() }
        guard let data = try? JSONSerialization.data(withJSONObject: raw,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return "[]"
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func importConnectionsJSON(_ data: Data) throws {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        guard let incoming = parsed as? [Any] else {
            throw NSError(domain: "me.qii404.ardm.native", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "The file does not contain a connection array",
            ])
        }
        var merged = ARDMConnectionConfig.loadAll()
        for item in incoming {
            guard let dict = item as? [String: Any] else { continue }
            let config = ARDMConnectionConfig.fromDictionary(dict)
            config.identifier = UUID().uuidString
            merged.append(config)
        }
        ARDMConnectionConfig.saveAll(merged)
    }

    // MARK: - Auto update (UpdateCheck.vue / electron-updater)

    // This is the native rewrite's own repository, not the upstream Electron project.
    private static let updateAPI =
        "https://api.github.com/repos/XINKEJU/AnotherRedisDesktopManager-Native/releases/latest"
    private static let bundleIdentifier = "me.qii404.ardm.native"

    private static var updateAssetURL: URL?
    private static var updateAssetName: String?
    private static var updateVersion: String?
    static var updateSHA256: String?
    private static var updateChecksumSource: String?

    // MARK: Update primitives

    private static func hexString(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes { out += String(format: "%02x", byte) }
        return out
    }

    /// Streaming SHA-256 of a file; nil when the file cannot be read.
    static func sha256OfFile(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        handle.closeFile()
        return hexString(Array(hasher.finalize()))
    }

    private static func isHexDigest(_ text: String) -> Bool {
        guard text.count == 64 else { return false }
        return text.lowercased().unicodeScalars.allSatisfy { scalar in
            scalar.value < 128 && "0123456789abcdef".unicodeScalars.contains(scalar)
        }
    }

    /// Pull the digest for `assetName` out of a checksum file. Accepts the common
    /// layouts: `sha256sum` output ("<hash>  <name>" / "<hash> *<name>"), a
    /// single-entry "<asset>.sha256" (bare hash, or one line), and one hash per line.
    static func checksumForAsset(_ text: String, _ assetName: String) -> String? {
        guard !text.isEmpty else { return nil }
        let wanted = assetName.lowercased()
        let wantedLeaf = (wanted as NSString).lastPathComponent
        let lines = text.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }
            let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard let first = tokens.first else { continue }
            let digest = first.lowercased()
            if !isHexDigest(digest) { continue }
            if tokens.count == 1 { return digest }           // bare hash: single-entry file
            var name = tokens[tokens.count - 1].lowercased()
            if name.hasPrefix("*") { name = String(name.dropFirst()) }
            while name.hasPrefix("./") { name = String(name.dropFirst(2)) }
            if name == wanted || name == wantedLeaf ||
                (name as NSString).lastPathComponent == wantedLeaf {
                return digest
            }
        }
        // A "<asset>.sha256" attachment often has a header line; a lone digest is
        // still unambiguous, so accept it when nothing matched by name.
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if isHexDigest(line.lowercased()) { return line.lowercased() }
        }
        return nil
    }

    /// Verify the bundle's code signature (seal integrity, all architectures) and
    /// report its team identifier. Ad-hoc signatures carry no provenance, which is
    /// why an ad-hoc build additionally requires a published SHA-256.
    static func inspectBundle(_ appPath: String) -> (teamID: String?, adHoc: Bool, reason: String?) {
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL,
                                                       [], &code)
        guard createStatus == errSecSuccess, let staticCode = code else {
            return (nil, false, "无法读取代码签名（OSStatus \(createStatus)）")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let validity = SecStaticCodeCheckValidity(staticCode, flags, nil)
        guard validity == errSecSuccess else {
            return (nil, false,
                    "代码签名校验失败（OSStatus \(validity)），安装包可能被篡改或未正确签名")
        }
        var teamID: String?
        var adHoc = false
        var info: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let dict = info as? [String: Any] {
            if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
                teamID = team
            }
            if let number = dict[kSecCodeInfoFlags as String] as? NSNumber {
                adHoc = (number.intValue & Int(SecCodeSignatureFlags.adhoc.rawValue)) != 0
            }
        }
        return (teamID, adHoc, nil)
    }

    private static func bundleIdentifier(atPath appPath: String) -> String? {
        let plist = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOfFile: plist),
              let identifier = info["CFBundleIdentifier"] as? String else { return nil }
        return identifier
    }

    private static func bundleVersion(atPath appPath: String) -> String? {
        let plist = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOfFile: plist),
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return version
    }

    /// Team identifier of the running app; nil for ad-hoc / unsigned builds.
    private static func runningTeamIdentifier() -> String? {
        let inspected = inspectBundle(Bundle.main.bundlePath)
        guard inspected.reason == nil else { return nil }
        return inspected.adHoc ? nil : inspected.teamID
    }

    /// Small text asset, fetched synchronously (the caller is already off the main thread).
    private static func fetchText(_ urlString: String, timeout: TimeInterval) -> String? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("ARDM-Native", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var payload: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, code == 200, let data, !data.isEmpty, data.count <= 65536 {
                payload = data
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return nil
        }
        guard let payload else { return nil }
        return String(data: payload, encoding: .utf8)
    }

    /// Move the verified bundle into place without ever destroying the only copy:
    /// prepare → rename old to the rollback slot → rename new in → restore on failure.
    /// All three paths live in the same directory, so each rename is atomic.
    static func installBundle(_ newApp: String, destination: String, backup: String) -> String? {
        let fm = FileManager.default
        let parent = (destination as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: parent) else {
            return "没有写入 \(parent) 的权限，请把应用移到可写位置或手动安装。"
        }
        let hadPrevious = fm.fileExists(atPath: destination)
        try? fm.removeItem(atPath: backup)     // single rollback slot
        if hadPrevious {
            do {
                try fm.moveItem(atPath: destination, toPath: backup)
            } catch {
                return "无法备份当前版本，已中止（未改动任何文件）：\(error.localizedDescription)"
            }
        }
        do {
            try fm.moveItem(atPath: newApp, toPath: destination)
        } catch {
            var restore = ""
            if hadPrevious, (try? fm.moveItem(atPath: backup, toPath: destination)) != nil {
                restore = "，旧版本已恢复"
            }
            return "替换失败（\(error.localizedDescription)）\(restore)。"
        }
        return nil
    }

    // MARK: Update API

    static func checkForUpdate(_ completion: @escaping (String, URL?) -> Void) {
        var request = URLRequest(url: URL(string: updateAPI)!)
        request.setValue("ARDM-Native", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let task = URLSession.shared.dataTask(with: request) { data, _, networkError in
            var status: String
            var page: URL?
            updateAssetURL = nil
            updateAssetName = nil
            updateVersion = nil
            updateSHA256 = nil
            updateChecksumSource = nil
            if let networkError {
                status = "Update check unavailable: \(networkError.localizedDescription)"
            } else {
                let release = data.flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                } ?? nil
                let tag = release?["tag_name"] as? String
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                if tag == nil {
                    status = "No release published for this native build yet."
                } else if tag == current || tag == "v" + current {
                    status = "You are up to date (\(current))"
                } else {
                    let assets = (release?["assets"] as? [Any]) ?? []
                    var checksumURL: String?
                    let checksumNames = ["sha256sums", "sha256sums.txt", "checksums.txt",
                                         "sha256.txt", "sha256sum.txt"]
                    for asset in assets {
                        guard let asset = asset as? [String: Any],
                              let name = asset["name"] as? String else { continue }
                        let lower = name.lowercased()
                        if lower.hasSuffix(".dmg") || lower.hasSuffix(".zip") {
                            if updateAssetURL == nil {
                                updateAssetURL = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
                                updateAssetName = name
                            }
                        } else if lower.hasSuffix(".sha256") || checksumNames.contains(lower) {
                            if checksumURL == nil {
                                checksumURL = asset["browser_download_url"] as? String
                            }
                        }
                    }
                    updateVersion = tag
                    if updateAssetURL != nil, let checksumURL, !checksumURL.isEmpty {
                        let text = fetchText(checksumURL, timeout: 8)
                        updateSHA256 = checksumForAsset(text ?? "", updateAssetName ?? "")
                        if updateSHA256 != nil {
                            updateChecksumSource = URL(string: checksumURL)?.lastPathComponent
                        }
                    }
                    let detail = updateAssetName ?? "no macOS asset"
                    let trust = updateSHA256 != nil
                        ? "SHA-256 ✓ (from \(updateChecksumSource ?? ""))"
                        : "no SHA-256 published"
                    status = "New release \(tag ?? "") (current \(current)) — \(detail) · \(trust)"
                    if let html = release?["html_url"] as? String { page = URL(string: html) }
                }
            }
            DispatchQueue.main.async { completion(status, page) }
        }
        task.resume()
    }

    static func pendingUpdateVersion() -> String? { updateVersion }
    static func pendingUpdateAssetName() -> String? { updateAssetName }
    static func pendingUpdateHasChecksum() -> Bool { (updateSHA256?.isEmpty == false) }

    static func downloadUpdate(_ completion: @escaping (String, URL?) -> Void) {
        guard let asset = updateAssetURL else {
            completion("Run 'Check for Updates' first; no downloadable macOS asset was found.", nil)
            return
        }
        let task = URLSession.shared.downloadTask(with: asset) { location, response, error in
            var status: String
            var local: URL?
            let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if location == nil || error != nil || (httpCode != 0 && httpCode != 200) {
                status = "Download failed: "
                    + (error?.localizedDescription ?? "HTTP \(httpCode)")
            } else {
                let fm = FileManager.default
                let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let name = asset.lastPathComponent.isEmpty ? "ARDM-Native-Update.dmg" : asset.lastPathComponent
                let dest = (dir as NSString).appendingPathComponent(name)
                try? fm.removeItem(atPath: dest)
                do {
                    try fm.moveItem(atPath: location!.path, toPath: dest)
                    let actual = sha256OfFile(dest)
                    let team = runningTeamIdentifier()
                    if let expected = updateSHA256, !expected.isEmpty {
                        if actual == expected {
                            status = "Downloaded and verified (SHA-256 ✓) → \(dest)"
                            local = URL(fileURLWithPath: dest)
                        } else {
                            try? fm.removeItem(atPath: dest)
                            status = "Verification failed: the downloaded file's SHA-256 does not match the "
                                + "value published by the release. The file was deleted."
                        }
                    } else if let team, !team.isEmpty {
                        // A Developer ID signature provides provenance, so a missing
                        // checksum is tolerable here; it is still verified at install.
                        status = "Downloaded → \(dest) (no checksum published; the Developer ID signature will be verified)"
                        local = URL(fileURLWithPath: dest)
                    } else {
                        try? fm.removeItem(atPath: dest)
                        status = "Refused: this ad-hoc build has no code-signing identity, so a published "
                            + "SHA-256 is required to establish provenance. Ask the release owner to attach "
                            + "SHA256SUMS (see native/package.sh)."
                    }
                } catch {
                    status = "Could not save update: \(error.localizedDescription)"
                }
            }
            DispatchQueue.main.async { completion(status, local) }
        }
        task.resume()
    }

    static func installUpdate(_ url: URL, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var status: String?
            let work = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent(UUID().uuidString)
            try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)

            // 1. Re-verify the archive. It sat in ~/Downloads, so anything could have
            //    touched it between download and install (TOCTOU).
            if let expected = updateSHA256, !expected.isEmpty {
                if sha256OfFile(url.path) != expected {
                    try? fm.removeItem(atPath: work)
                    let refused = "Installation refused: the downloaded archive no longer matches its published "
                        + "SHA-256 (re-download the update)."
                    DispatchQueue.main.async { completion(refused) }
                    return
                }
            }

            // 2. Extract into a private temporary directory.
            let ext = url.pathExtension.lowercased()
            var mountPoint: String?
            if ext == "dmg" {
                let mount = (work as NSString).appendingPathComponent("vol")
                mountPoint = mount
                try? fm.createDirectory(atPath: mount, withIntermediateDirectories: true)
                let attach = Process()
                attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                attach.arguments = ["attach", url.path, "-nobrowse", "-quiet", "-mountpoint", mount]
                attach.standardError = FileHandle.nullDevice
                try? attach.run()
                attach.waitUntilExit()
            } else if ext == "zip" {
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", url.path, work]
                unzip.standardError = FileHandle.nullDevice
                try? unzip.run()
                unzip.waitUntilExit()
            }

            // 3. Locate the bundle and reject anything that is not this application.
            let searchRoot = mountPoint ?? work
            var sourceApp: String?
            var foundOther: String?
            var candidates: [String] = []
            for entry in (try? fm.contentsOfDirectory(atPath: searchRoot)) ?? [] {
                let full = (searchRoot as NSString).appendingPathComponent(entry)
                if entry.hasSuffix(".app") {
                    candidates.append(full)
                } else if fm.fileExists(atPath: (full as NSString).appendingPathComponent("Contents/Info.plist")) {
                    candidates.append(full)
                }
            }
            if ext == "zip", candidates.isEmpty {
                // ditto may keep a wrapping folder; search one level down.
                if let walk = fm.enumerator(atPath: work) {
                    for case let relative as String in walk {
                        if relative.hasSuffix(".app") {
                            candidates.append((work as NSString).appendingPathComponent(relative))
                            break
                        }
                    }
                }
            }
            for candidate in candidates {
                let identifier = bundleIdentifier(atPath: candidate)
                if identifier == bundleIdentifier {
                    sourceApp = candidate
                    break
                }
                if let identifier, !identifier.isEmpty, foundOther == nil { foundOther = identifier }
            }

            if sourceApp == nil {
                status = foundOther.map {
                    "The update contains “\($0)”, not \(bundleIdentifier). Refusing to install."
                } ?? "The update package did not contain an installable .app bundle. "
                    + "(Zips must keep the enclosing .app folder — use `ditto -c -k --keepParent`.)"
            } else {
                // 4. Verify the signature before it touches /Applications.
                let inspected = inspectBundle(sourceApp!)
                let installTeam = runningTeamIdentifier()
                if let reason = inspected.reason {
                    status = "Installation refused: \(reason)."
                } else if let installTeam, !installTeam.isEmpty, installTeam != (inspected.teamID ?? "") {
                    status = "Installation refused: the update is signed by team “\(inspected.teamID ?? "none")”, "
                        + "but this build is signed by “\(installTeam)”."
                } else if (inspected.teamID ?? "").isEmpty,
                          (updateSHA256 ?? "").isEmpty {
                    status = "Installation refused: unsigned update with no published SHA-256 — provenance "
                        + "cannot be established."
                } else {
                    // 5. Stage inside /Applications so the swap is a same-volume rename.
                    let currentApp = Bundle.main.bundlePath
                    let currentLeaf = (currentApp as NSString).lastPathComponent
                    let destName = currentLeaf.hasSuffix(".app")
                        ? currentLeaf
                        : (sourceApp! as NSString).lastPathComponent
                    let dest = ("/Applications" as NSString).appendingPathComponent(destName)
                    let backup = dest + ".previous"
                    let staged = ("/Applications" as NSString)
                        .appendingPathComponent(".ardm-new-\(UUID().uuidString).app")

                    do {
                        try fm.copyItem(atPath: sourceApp!, toPath: staged)
                        // 6. Re-check the staged copy, then swap with rollback.
                        let stagedInspection = inspectBundle(staged)
                        if let reason = stagedInspection.reason {
                            try? fm.removeItem(atPath: staged)
                            status = "Installation refused: \(reason)."
                        } else if let swapError = installBundle(staged, destination: dest, backup: backup) {
                            try? fm.removeItem(atPath: staged)
                            status = "Install failed: \(swapError)"
                        } else {
                            let version = bundleVersion(atPath: dest) ?? "?"
                            status = "Installed \(version) to \(dest). The previous version is kept as "
                                + "“\((backup as NSString).lastPathComponent)” — rename it back "
                                + "to .app to roll back, or delete it once the new version checks out."
                            NSWorkspace.shared.open(URL(fileURLWithPath: dest))
                        }
                    } catch {
                        let downloads = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
                        let fallback = (downloads as NSString).appendingPathComponent(destName)
                        try? fm.removeItem(atPath: fallback)
                        if (try? fm.copyItem(atPath: sourceApp!, toPath: fallback)) != nil {
                            status = "没有写入 /Applications 的权限，未做任何替换。新版本已放到 \(fallback)，可手动拖入「应用程序」文件夹。"
                        } else {
                            status = "Install failed while staging: \(error.localizedDescription)"
                        }
                    }
                }
            }

            if let mountPoint {
                let detach = Process()
                detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", mountPoint, "-quiet", "-force"]
                detach.standardError = FileHandle.nullDevice
                try? detach.run()
                detach.waitUntilExit()
            }
            try? fm.removeItem(atPath: work)
            DispatchQueue.main.async { completion(status ?? "Install finished.") }
        }
    }

    // MARK: - Security-scoped bookmarks (FileInput.vue)

    static func bookmark(for url: URL) -> Data? {
        var data = try? url.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        // Non-sandboxed builds cannot create security-scoped bookmarks for arbitrary paths.
        if data == nil {
            data = try? url.bookmarkData(options: [],
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        }
        return data
    }

    static func resolveBookmark(_ bookmark: Data) -> URL? {
        var stale = false
        var url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        if url == nil {
            url = try? URL(resolvingBookmarkData: bookmark, options: [],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        _ = url?.startAccessingSecurityScopedResource()
        return url
    }
}

/// The sidebar divider stops at its own lower bound, but a pointer that keeps
/// going past that floor means "hide this column" — the gesture every Mac
/// sidebar has. The rule lives here rather than in the view so it can be
/// checked without driving a mouse.
enum ARDMSidebarDrag {
    /// Overshoot past the narrowest width, in points, that counts as intent.
    static let collapseTravel: Double = 56

    /// Width to report for a raw pointer position, and whether that position is
    /// far enough past `lower` to collapse when the drag is released.
    static func settle(raw: Double, lower: Double, limit: Double) -> (width: Double, collapse: Bool) {
        (Swift.min(limit, Swift.max(lower, raw)), lower - raw > collapseTravel)
    }
}
