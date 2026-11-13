import Foundation
import SwiftUI

// MARK: - Status / SlowLog / MemoryAnalysis / Cluster / Pub-Sub / MONITOR

extension AppStore {
    func loadStatus() {
        guard connected else { return }
        send(["INFO"]) { result in
            guard case .success(let reply) = result else { return }
            let text = ardmString(reply)
            var sections: [InfoSection] = []
            var currentName = "server"
            var fields: [(String, String)] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.hasPrefix("# ") {
                    if !fields.isEmpty { sections.append(InfoSection(name: currentName, fields: fields)) }
                    currentName = String(raw.dropFirst(2)); fields = []
                } else if raw.contains(":"), let range = raw.range(of: ":") {
                    let k = String(raw[raw.startIndex..<range.lowerBound])
                    let v = String(raw[range.upperBound...])
                    fields.append((k, v))
                }
            }
            if !fields.isEmpty { sections.append(InfoSection(name: currentName, fields: fields)) }
            self.infoSections = sections
            // INFO keyspace: one `dbN:keys=..,expires=..,avg_ttl=..` line per database.
            var keyspace: [(String, String)] = []
            for section in sections where section.name.lowercased() == "keyspace" {
                keyspace.append(contentsOf: section.fields)
            }
            self.keyspaceStats = keyspace
        }
    }

    func loadSlowLog() {
        send(["SLOWLOG", "GET", "128"]) { result in
            guard case .success(let reply) = result else { return }
            self.slowLogRows = ardmRows(reply)
        }
        // Surface the active thresholds (upstream SlowLog.vue shows these).
        send(["CONFIG", "GET", "slowlog-log-slower-than", "slowlog-max-len"]) { result in
            guard case .success(let reply) = result else { return }
            let flat = ardmArray(reply)
            var index = 0
            while index + 1 < flat.count {
                let name = ardmString(flat[index]).lowercased()
                let value = Int(ardmString(flat[index + 1])) ?? 0
                if name.contains("slower-than") { self.slowLogSlowerThan = value }
                if name.contains("max-len") { self.slowLogMaxLen = value }
                index += 2
            }
        }
    }

    /// Scan every key with MEMORY USAGE and keep those at/above the minimum size.
    /// Mirrors upstream MemoryAnalysis per-key mode instead of only MEMORY STATS.
    /// Per-key MEMORY USAGE. Keys are scanned in pages and measured 200 at a time
    /// inside one MULTI/EXEC round trip, so a 100k-key database needs ~500 round
    /// trips instead of 100k. The scan is cancellable and reports progress.
    func loadMemoryPerKey() {
        guard connected, !memoryScanRunning else { return }
        let minimum = memoryMinSize
        memoryScanRunning = true
        memoryScanned = 0
        memoryScanTotal = max(dbSize, 1)
        memoryPerKeyRows = []
        memoryScanToken += 1
        let token = memoryScanToken

        onBackground {
            var cursor: UInt = 0
            var rows: [(String, Int)] = []
            var scanned = 0
            do {
                repeat {
                    if self.memoryScanToken != token { break }
                    let batch = try self.scanBatch(pattern: "*", cursor: &cursor)
                    scanned += batch.count
                    var pending: [String] = []
                    for key in batch {
                        pending.append(key)
                        if pending.count >= 200 {
                            rows.append(contentsOf: try self.memoryUsageRows(pending, minimum: minimum))
                            pending.removeAll(keepingCapacity: true)
                            if self.memoryScanToken != token { break }
                        }
                    }
                    if !pending.isEmpty, self.memoryScanToken == token {
                        rows.append(contentsOf: try self.memoryUsageRows(pending, minimum: minimum))
                    }
                    let progress = scanned
                    self.onMain { self.memoryScanned = progress }
                } while cursor != 0 && rows.count < 5000 && self.memoryScanToken == token

                rows.sort { $0.1 > $1.1 }
                let top = Array(rows.prefix(500))
                let cancelled = self.memoryScanToken != token
                self.onMain {
                    self.memoryScanRunning = false
                    self.memoryPerKeyRows = top
                    if cancelled { self.notify(L10n("Memory scan cancelled")) }
                    else { self.notify("\(rows.count) key(s) ≥ \(Int(minimum)) bytes") }
                }
            } catch {
                self.onMain {
                    self.memoryScanRunning = false
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    func cancelMemoryScan() {
        memoryScanToken += 1
        memoryScanRunning = false
    }

    /// Measures a chunk of keys. Uses one transaction per chunk (pipelined reads),
    /// falling back to single calls in read-only mode where MULTI is rejected.
    private func memoryUsageRows(_ keys: [String], minimum: Double) throws -> [(String, Int)] {
        guard let client else { return [] }
        if !readOnly {
            var error: NSError?
            let replies = client.sendTransaction(keys.map { ["MEMORY", "USAGE", $0] }, error: &error)
            if let error { throw error }
            guard let results = replies.last as? [Any] else { return [] }
            var out: [(String, Int)] = []
            for (index, reply) in results.enumerated() where index < keys.count {
                guard let bytes = Int(ardmString(reply)), Double(bytes) >= minimum else { continue }
                out.append((keys[index], bytes))
            }
            return out
        }
        var out: [(String, Int)] = []
        for key in keys {
            var error: NSError?
            let reply = client.send(["MEMORY", "USAGE", key], error: &error)
            if error != nil { continue }
            guard let bytes = Int(ardmString(reply)), Double(bytes) >= minimum else { continue }
            out.append((key, bytes))
        }
        return out
    }

    func loadMemory() {
        send(["MEMORY", "STATS"]) { result in
            guard case .success(let reply) = result else { return }
            let rows = ardmRows(reply)
            var stats: [(String, Double)] = []
            var index = 0
            while index + 1 < rows.count {
                let name = rows[index].first ?? "\(index)"
                let value = Double(rows[index + 1].first ?? "") ?? 0
                stats.append((name, value))
                index += 2
            }
            self.memoryStats = stats
        }
    }

    func loadClusterTopology() {
        onBackground {
            guard let client = self.client else { return }
            var error: NSError?
            let topology = client.clusterTopology(&error)
            let slots = topology["slots"] as? [[String: Any]] ?? []
            let nodes = topology["nodes"] as? [[String: Any]] ?? []
            self.onMain {
                self.clusterSlots = slots
                self.clusterNodes = nodes
                if let error { self.fail(error.localizedDescription) }
                else { self.notify("\(slots.count) slot ranges, \(nodes.count) nodes") }
            }
        }
    }

    func startPubSub() {
        guard connected else { return }
        let channel = pubsubChannel.trimmingCharacters(in: .whitespaces)
        guard !channel.isEmpty else { fail("Enter a channel name first"); return }
        let command = pubsubPattern ? ["PSUBSCRIBE", channel] : ["SUBSCRIBE", channel]
        startLive(command, label: pubsubPattern ? "PSUBSCRIBE \(channel)" : "SUBSCRIBE \(channel)")
    }

    func startMonitor() { startLive(["MONITOR"], label: "MONITOR") }

    private func startLive(_ command: [String], label: String) {
        // MONITOR / SUBSCRIBE push streams must not share the browsing connection,
        // so prefer the dedicated CLI client (created lazily on connect).
        let liveClient = cliClient ?? client
        guard let liveClient else { return }
        liveEvents = []
        liveRunning = true
        liveClient.startLive(withCommand: command, onEvent: { rows in
            let message = rows.map { ardmString($0) }.joined(separator: " | ")
            self.liveEvents.insert(LiveEvent(time: Date(), text: message), at: 0)
            if self.liveEvents.count > 1000 { self.liveEvents.removeLast() }
        }, onError: { message in
            self.liveRunning = false
            self.fail("\(label): \(message)")
        })
        notify("\(label) started")
    }

    func stopLive() {
        client?.stopLive()
        cliClient?.stopLive()
        liveRunning = false
        notify("Live stream stopped")
    }

    func publish(_ channel: String, _ message: String) {
        send(["PUBLISH", channel, message]) { result in
            if case .success(let reply) = result { self.notify("Delivered to \(ardmString(reply)) subscribers") }
        }
    }

    func startAutoRefresh() {
        Timer.scheduledTimer(withTimeInterval: max(1, Double(statusRefreshSeconds)), repeats: true) { [weak self] _ in
            guard let self, self.connected, self.activeTab == .status else { return }
            self.loadStatus()
        }
    }
}

// MARK: - CLI history / completion / command reference

extension AppStore {
    func commandNames() -> [String] {
        Array(commandReference.keys).sorted()
    }

    func completions(for prefix: String) -> [String] {
        let lowered = prefix.lowercased()
        let key = lowered.split(separator: " ").first.map(String.init) ?? lowered
        guard !key.isEmpty else { return [] }
        var candidates = commandNames().filter { $0.lowercased().hasPrefix(key) }
        if candidates.isEmpty {
            candidates = keys.filter { $0.lowercased().contains(key) }.prefix(20).map { $0 }
        }
        return Array(candidates.prefix(20))
    }

    func commandSignature(_ name: String) -> String {
        guard let value = commandReference[name] else { return "" }
        if let text = value as? String { return text }
        if let list = value as? [String] { return list.joined(separator: "\n") }
        return ""
    }

    func runCLI() {
        let raw = cliInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let parts = parseCommandLine(raw)
        guard !parts.isEmpty else { return }
        if cliHistory.last != raw { cliHistory.append(raw); saveCliHistory() }
        cliHistoryIndex = cliHistory.count
        cliInput = ""
        let head = parts.first?.uppercased() ?? ""
        switch head {
        case "MULTI":
            if multiQueue != nil { cliOutput = "(error) ERR MULTI calls can not be nested" }
            else { multiQueue = []; cliOutput = "OK" }
            activeTab = .cli
            return
        case "DISCARD":
            if multiQueue == nil { cliOutput = "(error) ERR DISCARD without MULTI" }
            else { multiQueue = nil; cliOutput = "OK" }
            activeTab = .cli
            return
        case "EXEC":
            guard let queued = multiQueue else {
                cliOutput = "(error) ERR EXEC without MULTI"; activeTab = .cli; return
            }
            multiQueue = nil
            executeTransaction(queued)
            return
        default:
            if multiQueue != nil {
                multiQueue?.append(parts)
                cliOutput = "QUEUED"
                activeTab = .cli
                return
            }
        }
        // Run on the dedicated CLI connection (mirrors upstream client.duplicate())
        // so long-running or blocking commands never stall the key browser.
        sendOnCli(parts) { result in
            switch result {
            case .success(let reply):
                self.cliOutput = ardmString(reply)
                self.activeTab = .cli
                self.notify("\(parts.first ?? "") · \(ardmArray(reply).count) element(s)")
                // A mutating command must refresh the key list (upstream refreshKeyList).
                if self.client?.isWriteCommand(parts) ?? false { self.refreshKeys(reset: false) }
            case .failure(let error):
                self.cliOutput = "ERR \(error.localizedDescription)"
            }
        }
    }

    func parseCommandLine(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    func previousCLICommand() {
        guard !cliHistory.isEmpty else { return }
        cliHistoryIndex = max(0, cliHistoryIndex - 1)
        cliInput = cliHistory[cliHistoryIndex]
    }

    func nextCLICommand() {
        guard !cliHistory.isEmpty else { return }
        cliHistoryIndex = min(cliHistory.count, cliHistoryIndex + 1)
        cliInput = cliHistoryIndex == cliHistory.count ? "" : cliHistory[cliHistoryIndex]
    }
}

// MARK: - Syntax highlighting (NSTextView/Monaco replacement via AttributedString)

func highlighted(_ text: String, size: CGFloat) -> AttributedString {
    var result = AttributedString(text)
    result.font = .system(size: size, design: .monospaced)
    let keywords = ["GET", "SET", "DEL", "HGETALL", "HSET", "SCAN", "SELECT", "INFO", "PING",
                    "LRANGE", "SMEMBERS", "ZRANGE", "XRANGE", "JSON.GET", "JSON.SET", "MONITOR",
                    "SUBSCRIBE", "PUBLISH", "TTL", "EXPIRE", "CLUSTER", "SLOWLOG", "MEMORY"]
    for word in keywords {
        var search = result
        while let range = search.range(of: word, options: [.caseInsensitive]) {
            result[range].foregroundColor = .blue
            result[range].font = .system(size: size, weight: .bold, design: .monospaced)
            if range.upperBound < result.endIndex {
                search = AttributedString(result[range.upperBound..<result.endIndex])
            } else { break }
        }
    }
    return result
}
