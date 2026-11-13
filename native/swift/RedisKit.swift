import Foundation

// MARK: - RESP value conversion (ObjC NSObject graph -> Swift)

func ardmString(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    if let s = value as? String { return s }
    if let d = value as? Data {
        return String(data: d, encoding: .utf8) ?? "<binary \(d.count) bytes>"
    }
    if let n = value as? NSNumber { return n.stringValue }
    if let a = value as? [Any] { return a.map { ardmString($0) }.joined(separator: "\n") }
    if let d = value as? [String: Any] { return d.description }
    return "\(value)"
}

func ardmData(_ value: Any?) -> Data {
    guard let value, !(value is NSNull) else { return Data() }
    if let d = value as? Data { return d }
    return ardmString(value).data(using: .utf8) ?? Data()
}

func ardmArray(_ value: Any?) -> [Any] {
    guard let value, !(value is NSNull) else { return [] }
    if let a = value as? [Any] { return a }
    return [value]
}

func ardmRows(_ value: Any?) -> [[String]] {
    ardmArray(value).map { item -> [String] in
        if let nested = item as? [Any] { return nested.map { ardmString($0) } }
        return [ardmString(item)]
    }
}

enum ARDMKitError: LocalizedError {
    case notConnected
    case noSelection
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to any Redis server"
        case .noSelection: return "Nothing selected"
        }
    }
}

// MARK: - Threading helpers

extension AppStore {
    func onBackground(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }
    func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - Command execution

extension AppStore {
    /// Synchronous command, must be called from a background queue.
    @discardableResult
    func sendSync(_ args: [String]) throws -> Any {
        guard let client else { throw ARDMKitError.notConnected }
        var error: NSError?
        let reply = client.send(args, error: &error)
        if let error { throw error }
        return reply
    }

    @discardableResult
    func sendRawSync(_ args: [Any]) throws -> Any {
        guard let client else { throw ARDMKitError.notConnected }
        var error: NSError?
        let reply = client.sendArguments(args, error: &error)
        if let error { throw error }
        return reply
    }

    /// Async command whose reply is delivered back on the main thread.
    func send(_ args: [String], completion: @escaping (Result<Any, Error>) -> Void = { _ in }) {
        onBackground {
            do {
                let reply = try self.sendSync(args)
                self.onMain { completion(.success(reply)) }
            } catch {
                self.onMain { self.fail(error.localizedDescription); completion(.failure(error)) }
            }
        }
    }

    func execute(_ args: [String]) {
        send(args) { result in
            if case .success(let reply) = result {
                self.cliOutput = ardmString(reply)
                self.activeTab = .cli
                // A successful mutating command must refresh the key list (upstream refreshKeyList).
                if self.client?.isWriteCommand(args) ?? false { self.refreshKeys(reset: false) }
                self.notify("\(args.first ?? "") OK")
            }
        }
    }
}

// MARK: - Connection lifecycle

extension AppStore {
    func connect(to config: ARDMConnectionConfig) {
        selectedConnectionID = config.identifier
        if openConnectionIDs.contains(config.identifier) {
            switchConnection(config.identifier)
            // Re-clicking Connect on a dropped tab revives it instead of no-oping.
            if let state = connectionStates[config.identifier], !state.isOnline {
                reconnect(id: config.identifier, manual: true)
            }
            return
        }
        statusText = L10n("Connecting to") + " \(config.name)…"
        connectionStates[config.identifier] = .connecting
        onBackground {
            let client = ARDMRedisClient(config: config)
            client.onLog = { log in
                let entry = LogEntry(time: log.time, connection: log.connectionName,
                                     command: log.command, cost: log.cost)
                self.onMain { self.logs.insert(entry, at: 0); if self.logs.count > 5000 { self.logs.removeLast() } }
            }
            do {
                try client.connect()
                let size = client.dbSize(nil)
                self.onMain {
                    // Drop any stale CLI connection from a previous session first.
                    self.cliClient?.disconnect()
                    self.cliClient = nil
                    self.clients[config.identifier] = client
                    if !self.openConnectionIDs.contains(config.identifier) {
                        self.openConnectionIDs.append(config.identifier)
                    }
                    self.activeConnectionID = config.identifier
                    self.client = client
                    self.connected = true
                    self.connectionStates[config.identifier] = .connected
                    self.startKeepalive()
                    self.selectedDB = config.db
                    self.dbSize = size
                    self.separator = config.separator.isEmpty ? self.separator : config.separator
                    self.readOnly = config.readOnly
                    self.statusText = L10n("Connected:") + " \(config.name) @ \(client.hostUsed):\(client.portUsed)"
                    self.refreshKeys(reset: true)
                    self.loadStatus()
                    self.fetchRedisVersion()
                }
            } catch {
                self.onMain {
                    self.connectionStates[config.identifier] = .failed(error.localizedDescription)
                    self.connected = false
                    self.client = nil
                    self.fail("Connect failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Lazily open a dedicated CLI connection (mirrors upstream client.duplicate()) so that
    /// long-running or blocking commands such as MONITOR do not stall key browsing.
    @discardableResult
    func ensureCliClient() -> ARDMRedisClient? {
        if let existing = cliClient, existing.isConnected { return existing }
        guard let config = selectedConnection else { return nil }
        let dup = (config.copy() as? ARDMConnectionConfig) ?? config
        let client = ARDMRedisClient(config: dup)
        do {
            try client.connect()
        } catch {
            return nil
        }
        client.onLog = { log in
            let entry = LogEntry(time: log.time, connection: log.connectionName,
                                 command: log.command, cost: log.cost)
            self.onMain { self.logs.insert(entry, at: 0); if self.logs.count > 5000 { self.logs.removeLast() } }
        }
        cliClient = client
        return client
    }

    /// Run a command on the dedicated CLI connection (falling back to the main client).
    func sendOnCli(_ args: [String], completion: @escaping (Result<Any, Error>) -> Void = { _ in }) {
        onBackground {
            if let cli = self.ensureCliClient() {
                var error: NSError?
                let reply = cli.send(args, error: &error)
                if let error {
                    self.onMain { self.fail(error.localizedDescription); completion(.failure(error)) }
                } else {
                    self.onMain { completion(.success(reply)) }
                }
                return
            }
            do {
                let reply = try self.sendSync(args)
                self.onMain { completion(.success(reply)) }
            } catch {
                self.onMain { self.fail(error.localizedDescription); completion(.failure(error)) }
            }
        }
    }

    func fetchRedisVersion() {
        onBackground {
            guard let client = self.client else { return }
            var error: NSError?
            let info = ardmString(client.send(["INFO", "server"], error: &error))
            guard error == nil else { return }
            let version = info.split(separator: "\n")
                .first { $0.contains("redis_version") }
                .map { line -> String in
                    let parts = line.split(separator: ":")
                    return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                } ?? ""
            self.onMain { self.redisVersion = version }
        }
    }

    func testConnection(_ config: ARDMConnectionConfig, completion: @escaping (Bool, String) -> Void) {
        onBackground {
            let client = ARDMRedisClient(config: config)
            do {
                try client.connect()
                let pong = ardmString(client.send(["PING"], error: nil))
                client.disconnect()
                let ok = pong.uppercased().contains("PONG")
                self.onMain { completion(ok, ok ? "Connection successful" : "Unexpected reply: \(pong)") }
            } catch {
                self.onMain { completion(false, "Connection failed: \(error.localizedDescription)") }
            }
        }
    }

    func disconnect() {
        if let id = activeConnectionID { closeConnection(id) }
        else { clearActiveState() }
    }

    /// Tabs.vue: switch to another already-open connection without dropping the others.
    func switchConnection(_ id: String) {
        guard let target = clients[id] else { return }
        if let current = activeConnectionID, !keys.isEmpty { keyCache[current] = keys }
        client?.stopLive()
        liveRunning = false
        let config = connections.first { $0.identifier == id }
        activeConnectionID = id
        selectedConnectionID = id
        client = target
        connected = target.isConnected
        if connectionStates[id] == nil {
            connectionStates[id] = target.isConnected ? .connected : .disconnected
        }
        selectedDB = target.selectedDB
        if let config {
            separator = config.separator.isEmpty ? separator : config.separator
            readOnly = config.readOnly
        }
        keys = keyCache[id] ?? []
        keyNodes = []
        buildTree()
        selectedKey = nil
        keyRows = []
        statusText = L10n("Switched to") + " \(config?.name ?? id)"
        if keys.isEmpty { refreshKeys(reset: true) }
        loadStatus()
    }

    func closeConnection(_ id: String) {
        clients[id]?.stopLive()
        clients[id]?.disconnect()
        clients.removeValue(forKey: id)
        keyCache.removeValue(forKey: id)
        openConnectionIDs.removeAll { $0 == id }
        connectionStates.removeValue(forKey: id)
        if activeConnectionID == id {
            if let next = openConnectionIDs.first { switchConnection(next) }
            else { clearActiveState() }
        }
    }

    func disconnectAll() {
        for id in openConnectionIDs { clients[id]?.stopLive(); clients[id]?.disconnect() }
        clients.removeAll()
        keyCache.removeAll()
        openConnectionIDs.removeAll()
        clearActiveState()
    }

    private func clearActiveState() {
        stopKeepalive()
        stopStatusTimer()
        if let id = activeConnectionID { connectionStates[id] = .disconnected }
        client = nil
        connected = false
        activeConnectionID = nil
        keys = []
        keyNodes = []
        selectedKey = nil
        keyRows = []
        liveEvents = []
        liveRunning = false
        statusText = L10n("Disconnected")
    }

    func changeDatabase(_ db: Int) {
        send(["SELECT", "\(db)"]) { result in
            if case .success = result {
                self.selectedDB = db
                self.client?.selectedDB = db
                self.refreshKeys(reset: true)
                self.notify("Switched to DB \(db)")
            }
        }
    }
}

// MARK: - Status auto refresh

extension AppStore {
    func startStatusTimer() {
        stopStatusTimer()
        let interval = TimeInterval(max(1, statusRefreshSeconds))
        statusTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.onBackground { self?.loadStatus() }
        }
    }

    func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
}

// MARK: - Key browsing (SCAN, filtering, tree, pagination)

extension AppStore {
    func effectivePattern() -> String {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "*" }
        switch matchMode {
        case .exact: return text
        case .glob: return text.contains("*") || text.contains("?") || text.contains("[") ? text : "*\(text)*"
        case .fuzzy: return "*\(text.split(separator: " ").joined(separator: "*"))*"
        }
    }

    func refreshKeys(reset: Bool = true) {
        guard connected else { return }
        statusText = L10n("Scanning keys…")
        onBackground {
            do {
                var cursor: UInt = 0
                var collected: [String] = []
                repeat {
                    let batch = try self.scanBatch(pattern: self.effectivePattern(), cursor: &cursor)
                    collected.append(contentsOf: batch)
                } while cursor != 0 && collected.count < self.pageSize
                self.onMain {
                    self.keys = (NSOrderedSet(array: collected).array as? [String] ?? collected).sorted()
                    self.scanCursor = cursor
                    self.scanFinished = cursor == 0
                    self.buildTree()
                    if let id = self.activeConnectionID { self.keyCache[id] = self.keys }
                    self.dbSize = self.client?.dbSize(nil) ?? self.dbSize
                    self.statusText = "\(self.keys.count) " + L10n("keys loaded") + " · DB \(self.selectedDB) · " + L10n("total") + " \(self.dbSize)"
                }
            } catch {
                self.onMain { self.fail("SCAN failed: \(error.localizedDescription)") }
            }
        }
    }

    func scanBatch(pattern: String, cursor: inout UInt) throws -> [String] {
        guard let client else { throw ARDMKitError.notConnected }
        var error: NSError?
        var local = cursor
        let keys = client.scanKeys(matching: pattern, cursor: &local, count: UInt(max(1, pageSize)), error: &error)
        if let error { throw error }
        cursor = local
        return keys
    }

    func loadMoreKeys() {
        guard connected, !scanFinished else { return }
        onBackground {
            do {
                var cursor = self.scanCursor
                var collected: [String] = []
                repeat {
                    let batch = try self.scanBatch(pattern: self.effectivePattern(), cursor: &cursor)
                    collected.append(contentsOf: batch)
                } while cursor != 0 && collected.count < self.pageSize
                self.onMain {
                    let merged = (NSOrderedSet(array: self.keys + collected).array as? [String] ?? self.keys + collected)
                    self.keys = merged.sorted()
                    self.scanCursor = cursor
                    self.scanFinished = cursor == 0
                    self.buildTree()
                    if let id = self.activeConnectionID { self.keyCache[id] = self.keys }
                    self.statusText = "\(self.keys.count) " + L10n("keys loaded")
                }
            } catch {
                self.onMain { self.fail(error.localizedDescription) }
            }
        }
    }

    /// Reproduce KeyListVirtualTree.vue: split each key by the separator into a hierarchy.
    func buildTree() {
        let sep = separator.isEmpty ? ":" : separator
        var root: [String: Any] = [:]
        // One pass builds both the tree and the folder → member index used by the
        // tri-state checkboxes, so rows never rescan the key list.
        var membership: [String: [String]] = [:]
        for key in keys {
            let parts = key.components(separatedBy: sep)
            insert(&root, parts, full: key)
            guard parts.count > 1 else { continue }
            var prefix = ""
            for part in parts.dropLast() {
                prefix = prefix.isEmpty ? part : prefix + sep + part
                membership[prefix, default: []].append(key)
            }
        }
        groupMembership = membership
        keyNodes = makeNodes(root, prefix: "", sep: sep)
    }

    private func insert(_ node: inout [String: Any], _ parts: [String], full: String) {
        guard let head = parts.first else { return }
        if parts.count == 1 {
            node[head] = ["__leaf__": full] as [String: Any]
            return
        }
        var child = node[head] as? [String: Any] ?? [:]
        insert(&child, Array(parts.dropFirst()), full: full)
        node[head] = child
    }

    private func makeNodes(_ dict: [String: Any], prefix: String, sep: String) -> [KeyNode] {
        // The tree only has one column, so length ordering is not meaningful here;
        // it still honours the A→Z / Z→A direction chosen in the header.
        let ordered: [String] = keySortOrder == .nameDesc
            ? dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            : dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ordered.compactMap { name -> KeyNode? in
            let path = prefix.isEmpty ? name : prefix + sep + name
            guard let value = dict[name] as? [String: Any] else { return nil }
            if let leaf = value["__leaf__"] as? String {
                return KeyNode(id: leaf, name: name, fullPath: leaf, isLeaf: true, children: nil)
            }
            let children = makeNodes(value, prefix: path, sep: sep)
            return KeyNode(id: "group:" + path, name: name, fullPath: path, isLeaf: false,
                           children: children.isEmpty ? nil : children)
        }
    }

    /// Keys after the search box and the local filter, in the current sort order.
    ///
    /// Called several times per body evaluation, so the result is cached and
    /// invalidated by the didSet hooks on `keys` / `searchText` / `matchMode` /
    /// `localFilter` / `localFilterRegex` / `keySortOrder` (see AppStore). Without
    /// the cache a single keystroke over a large page filtered *and* ICU-sorted the
    /// whole list once per call site.
    func filteredKeys() -> [String] {
        if let cached = filteredKeysCache { return cached }
        let result = computeFilteredKeys()
        filteredKeysCache = result
        return result
    }

    private func computeFilteredKeys() -> [String] {
        let base = sortedBaseKeys()
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let local = localFilter
        guard !text.isEmpty || !local.isEmpty else { return base }

        // Hoist everything that used to be recomputed per key: the "*"-stripped
        // needle, the fuzzy word list, the compiled regex, and — the expensive one
        // — the lowercased form of every key. `lowercased()` allocates a String per
        // key, which on a 200k page is ~100 ms of pure allocation per keystroke.
        let globNeedle = text.replacingOccurrences(of: "*", with: "")
        let fuzzyWords = text.split(separator: " ")
        let regex: NSRegularExpression? = (!local.isEmpty && localFilterRegex)
            ? try? NSRegularExpression(pattern: local, options: [.caseInsensitive])
            : nil
        // The local filter used to call localizedCaseInsensitiveContains, which runs
        // the ICU collator once per key (~134 ms for 200k). Matching against the
        // precomputed lowercase copy is the same answer for key names and much
        // cheaper; locale-specific case folding only differs for a handful of
        // scripts that do not appear in Redis key names.
        let localNeedle = local.lowercased()
        let needsLowered = !text.isEmpty || (!local.isEmpty && regex == nil)
        let lowered = needsLowered ? lowercasedBaseKeys() : []

        // One pass over an already sorted array: a subsequence of a sorted list is
        // still sorted, so filtering never needs to re-sort.
        var matched: [String] = []
        matched.reserveCapacity(base.count)
        for index in base.indices {
            let key = base[index]
            if !text.isEmpty {
                let lower = lowered[index]
                switch matchMode {
                case .exact where lower != text: continue
                case .glob where !lower.contains(globNeedle): continue
                case .fuzzy where !fuzzyWords.allSatisfy({ lower.contains($0) }): continue
                default: break
                }
            }
            if !local.isEmpty {
                if let regex {
                    if regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) == nil {
                        continue
                    }
                } else if localFilterRegex {
                    // Regex mode with a pattern that does not compile: no filter,
                    // which is what the previous implementation did too.
                } else if !lowered[index].contains(localNeedle) {
                    continue
                }
            }
            matched.append(key)
        }
        return matched
    }

    /// The full key list in the current column order, computed once per change to
    /// `keys` or `keySortOrder`.
    private func sortedBaseKeys() -> [String] {
        if let cached = sortedKeysCache { return cached }
        let sorted = sortedKeys(keys)
        sortedKeysCache = sorted
        return sorted
    }

    /// Lowercased copy of `sortedBaseKeys()`, in the same order. Built on the first
    /// search and reused until the key list or its ordering changes, so typing does
    /// not re-allocate a lowercased String for every key on every keystroke.
    private func lowercasedBaseKeys() -> [String] {
        if let cached = lowercasedKeysCache { return cached }
        let lowered = sortedBaseKeys().map { $0.lowercased() }
        lowercasedKeysCache = lowered
        return lowered
    }

    /// Applies the column-header ordering. `localizedStandardCompare` gives users
    /// the same natural ordering as the Finder (item2 before item10).
    func sortedKeys(_ input: [String]) -> [String] {
        switch keySortOrder {
        case .none:
            return input
        case .nameAsc:
            return input.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case .nameDesc:
            return input.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        case .lengthAsc:
            return input.sorted {
                $0.count == $1.count
                    ? $0.localizedStandardCompare($1) == .orderedAscending
                    : $0.count < $1.count
            }
        case .lengthDesc:
            return input.sorted {
                $0.count == $1.count
                    ? $0.localizedStandardCompare($1) == .orderedAscending
                    : $0.count > $1.count
            }
        }
    }

    /// Clicking the "Key" header cycles scan order → A→Z → Z→A.
    func toggleNameSort() {
        switch keySortOrder {
        case .none, .lengthAsc, .lengthDesc: keySortOrder = .nameAsc
        case .nameAsc: keySortOrder = .nameDesc
        case .nameDesc: keySortOrder = .none
        }
    }
}

// MARK: - Key operations

extension AppStore {
    func selectKey(_ key: String) {
        selectedKey = key
        checkedKeys.removeAll()
        rowOffset = 0
        oversizeOffset = 0
        reloadKeyDetail()
    }

    func reloadKeyDetail() {
        guard let key = selectedKey, connected else { return }
        onBackground {
            guard let client = self.client else { return }
            var error: NSError?
            let type = client.type(ofKey: key, error: &error)
            let ttl = client.ttl(ofKey: key, error: &error)
            if type == .hash || type == .set {
                // HLEN / SCARD give an immediate count without streaming the whole key.
                let count = ardmString(client.send(type == .hash ? ["HLEN", key] : ["SCARD", key], error: &error))
                self.onMain {
                    self.selectedKeyType = type
                    self.selectedKeyTTL = ttl
                    self.hashLen = Int(count) ?? 0
                    self.keyRawValue = Data()
                    self.editorText = ""
                }
                self.scanRows(reset: true, type: type)
                self.refreshPTTL()
                return
            }
            // ZSet with an active pattern uses ZSCAN; otherwise fall through to the
            // ordered ZRANGE WITHSCORES read so scores stay sorted (matches upstream).
            if type == .zSet && self.rowSearchPattern != "*" && !self.rowSearchPattern.isEmpty {
                self.onMain {
                    self.selectedKeyType = type
                    self.selectedKeyTTL = ttl
                    self.keyRawValue = Data()
                    self.editorText = ""
                }
                self.scanRows(reset: true, type: type)
                self.refreshPTTL()
                return
            }
            let value = client.value(ofKey: key, type: type, error: &error)
            let rows = self.rowsForType(type, key: key, value: value)
            let raw = ardmData(value)
            let detected = ARDMFormatters.detectViewer(for: raw)
            // Stream consumer groups + consumers (KeyContentStream.vue panel).
            var groups: [[String: Any]] = []
            var consumers: [[String: Any]] = []
            if type == .stream {
                if let rawGroups = client.send(["XINFO", "GROUPS", key], error: &error) as? [[Any]] {
                    groups = rawGroups.map { entry -> [String: Any] in
                        var dict: [String: Any] = [:]
                        var i = 0
                        while i + 1 < entry.count { dict[ardmString(entry[i])] = entry[i + 1]; i += 2 }
                        return dict
                    }
                }
                if let firstName = groups.first?["name"] as? String,
                   let rawConsumers = client.send(["XINFO", "CONSUMERS", key, firstName], error: &error) as? [[Any]] {
                    consumers = rawConsumers.map { entry -> [String: Any] in
                        var dict: [String: Any] = [:]
                        var i = 0
                        while i + 1 < entry.count { dict[ardmString(entry[i])] = entry[i + 1]; i += 2 }
                        return dict
                    }
                }
            }
            self.onMain {
                self.selectedKeyType = type
                self.selectedKeyTTL = ttl
                self.keyRows = rows
                self.keyRawValue = raw
                self.editorText = ardmString(value)
                self.viewerName = detected.isEmpty ? "Text" : detected
                self.renderValue()
                self.streamGroups = groups
                self.streamConsumers = consumers
                self.statusText = "\(key) · \(typeName(type)) · TTL \(ttl)"
                self.refreshPTTL()
                if type == .timeSeries { self.loadTimeSeriesInfo() }
            }
        }
    }

    func renderValue() {
        var error: NSError?
        if viewerName == "Custom" {
            renderedValue = ARDMFormatters.renderCustom(keyRawValue, script: customViewerScript, error: &error)
        } else if viewerName == "OverSize" {
            // Huge values are paged instead of being cut off at the first 4 KB.
            renderedValue = ARDMFormatters.render(keyRawValue, as: viewerName,
                                                  offset: UInt(max(0, oversizeOffset)),
                                                  length: UInt(oversizeChunkSize),
                                                  error: &error)
        } else {
            renderedValue = ARDMFormatters.render(keyRawValue, as: viewerName, error: &error)
        }
        if let error {
            renderedValue = "Viewer error: \(error.localizedDescription)"
        } else if viewerName != "Text" && !renderedValue.isEmpty {
            // The editable pane must show the DECODED text, so saving can encode it
            // back with the same viewer instead of re-encoding the raw bytes.
            editorText = renderedValue
        }
    }

    func deleteKeys(_ targets: [String]) {
        guard !targets.isEmpty else { return }
        send(["DEL"] + targets) { result in
            if case .success = result {
                self.keys.removeAll { targets.contains($0) }
                self.checkedKeys.removeAll()
                if targets.contains(self.selectedKey ?? "") { self.selectedKey = nil; self.keyRows = [] }
                self.buildTree()
                self.notify("Deleted \(targets.count) key(s)")
            }
        }
    }

    func renameKey(_ newName: String) {
        guard let key = selectedKey else { return }
        send(["RENAME", key, newName]) { result in
            if case .success = result {
                if let index = self.keys.firstIndex(of: key) { self.keys[index] = newName }
                self.selectedKey = newName
                self.buildTree()
                self.reloadKeyDetail()
                self.notify("Renamed")
            }
        }
    }

    func setTTL(_ seconds: Int) {
        guard let key = selectedKey else { return }
        let command = seconds < 0 ? ["PERSIST", key] : ["EXPIRE", key, "\(seconds)"]
        send(command) { result in
            if case .success = result { self.selectedKeyTTL = seconds; self.notify("TTL updated") }
        }
    }

    func createKey(name: String, type: ARDMKeyType, value: String, ttl: Int) {
        var commands: [[String]] = []
        switch type {
        case .list: commands = [["RPUSH", name, value]]
        case .set: commands = [["SADD", name, value]]
        case .hash: commands = [["HSET", name, "field", value]]
        case .zSet: commands = [["ZADD", name, "0", value]]
        case .stream: commands = [["XADD", name, "*", "field", value]]
        case .vector: commands = [["VADD", name, "VALUES", "1", value, vectorQuantization]]
        case .reJSON: commands = [["JSON.SET", name, "$", value]]
        default: commands = [["SET", name, value]]
        }
        if ttl > 0 { commands.append(["EXPIRE", name, "\(ttl)"]) }
        onBackground {
            do {
                for command in commands { try self.sendSync(command) }
                self.onMain { self.refreshKeys(reset: true); self.selectKey(name); self.notify("Key created") }
            } catch { self.onMain { self.fail(error.localizedDescription) } }
        }
    }

    func batchDelete(pattern: String) {
        onBackground {
            do {
                var cursor: UInt = 0
                var victims: [String] = []
                repeat {
                    let batch = try self.scanBatch(pattern: pattern, cursor: &cursor)
                    victims.append(contentsOf: batch)
                } while cursor != 0 && victims.count < 100000
                guard !victims.isEmpty else { self.onMain { self.notify("No matching keys") }; return }
                for chunk in stride(from: 0, to: victims.count, by: 500) {
                    let slice = Array(victims[chunk..<min(chunk + 500, victims.count)])
                    try self.sendSync(["UNLINK"] + slice)
                }
                self.onMain { self.refreshKeys(reset: true); self.notify("Deleted \(victims.count) keys matching \(pattern)") }
            } catch { self.onMain { self.fail(error.localizedDescription) } }
        }
    }

    func dumpKey(_ key: String) {
        send(["DUMP", key]) { result in
            if case .success(let reply) = result {
                self.cliOutput = "DUMP \(key)\n" + ARDMFormatters.render(ardmData(reply), as: "Hex", error: nil)
                self.activeTab = .cli
            }
        }
    }

    func exportKeys(_ targets: [String]) -> String {
        var payload: [[String: String]] = []
        for key in targets {
            guard let client else { break }
            let type = client.type(ofKey: key, error: nil)
            let ttl = client.ttl(ofKey: key, error: nil)
            let value = client.value(ofKey: key, type: type, error: nil)
            payload.append(["key": key, "type": typeName(type), "ttl": "\(ttl)", "value": ardmString(value)])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func importKeyValues(_ json: String) {
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            fail("Invalid import JSON"); return
        }
        onBackground {
            do {
                for item in items {
                    guard let key = item["key"] as? String, let value = item["value"] as? String else { continue }
                    let type = (item["type"] as? String)?.lowercased() ?? "string"
                    switch type {
                    case "list": try self.sendSync(["RPUSH", key, value])
                    case "set": try self.sendSync(["SADD", key, value])
                    case "hash": try self.sendSync(["HSET", key, "field", value])
                    case "zset": try self.sendSync(["ZADD", key, "0", value])
                    default: try self.sendSync(["SET", key, value])
                    }
                    if let ttl = item["ttl"] as? String, let seconds = Int(ttl), seconds > 0 {
                        try self.sendSync(["EXPIRE", key, "\(seconds)"])
                    }
                }
                self.onMain { self.refreshKeys(reset: true); self.notify("Imported \(items.count) keys") }
            } catch { self.onMain { self.fail(error.localizedDescription) } }
        }
    }
}

func typeName(_ type: ARDMKeyType) -> String {
    switch type {
    case .string: return "string"
    case .list: return "list"
    case .set: return "set"
    case .zSet: return "zset"
    case .hash: return "hash"
    case .stream: return "stream"
    case .reJSON: return "ReJSON"
    case .timeSeries: return "TimeSeries"
    case .vector: return "Vector"
    case .array: return "Array"
    default: return "unknown"
    }
}
