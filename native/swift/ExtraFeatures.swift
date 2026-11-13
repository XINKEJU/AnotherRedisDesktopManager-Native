import Foundation
import SwiftUI
import AppKit

// MARK: - Feature parity additions (transactions, DUMP import, hex input, tree state, keepalive)

extension AppStore {

    // MARK: CliTab.vue MULTI / EXEC / DISCARD

    func executeTransaction(_ queued: [[String]]) {
        onBackground {
            guard let client = self.client else {
                self.onMain { self.fail(ARDMKitError.notConnected.localizedDescription) }
                return
            }
            var error: NSError?
            let replies = client.sendTransaction(queued, error: &error)
            if let error {
                self.onMain { self.cliOutput = "ERR \(error.localizedDescription)"; self.activeTab = .cli }
                return
            }
            let results = ardmArray(replies.last)
            let rendered = results.isEmpty ? ardmString(replies.last) : results.enumerated()
                .map { "\($0.offset + 1)) \(ardmString($0.element))" }
                .joined(separator: "\n")
            self.onMain {
                self.cliOutput = rendered
                self.activeTab = .cli
                self.notify("EXEC · \(queued.count) commands")
            }
        }
    }

    // MARK: ConnectionMenu.vue DUMP snapshot import (keyHex,dumpHex,ttl per line)

    func importDumpSnapshot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.message = "Each line: keyHex,dumpHex,ttl  →  RESTORE key ttl dump REPLACE"
        // Restore the last-used directory from a security-scoped bookmark (resolveBookmark).
        if let data = UserDefaults.standard.data(forKey: "ARDMLastDumpBookmark"),
           let url = ARDMAppServices.resolveBookmark(data) {
            panel.directoryURL = url
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if let data = ARDMAppServices.bookmark(for: url) {
            UserDefaults.standard.set(data, forKey: "ARDMLastDumpBookmark")
        }
        var entries: [(Data, Data, Int)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2,
                  let key = ardmDataFromHex(fields[0]),
                  let dump = ardmDataFromHex(fields[1]), !dump.isEmpty else { continue }
            let ttl = fields.count > 2 ? max(0, Int(fields[2].trimmingCharacters(in: .whitespaces)) ?? 0) : 0
            entries.append((key, dump, ttl))
        }
        guard !entries.isEmpty else {
            fail("No valid DUMP lines found. Expected: keyHex,dumpHex,ttl")
            return
        }
        onBackground {
            var succeeded = 0, failed = 0
            for (key, dump, ttl) in entries {
                do {
                    try self.sendRawSync(["RESTORE", key, "\(ttl)", dump, "REPLACE"])
                    succeeded += 1
                } catch { failed += 1 }
            }
            self.onMain {
                self.notify("DUMP import: \(succeeded) succeeded, \(failed) failed")
                self.refreshKeys(reset: true)
            }
        }
    }

    // MARK: InputBinary.vue hex entry

    /// Accepts a plain hex string and presents it through the Hex viewer (editable → encodable).
    func pasteHexValue(_ hex: String) {
        guard let data = ardmDataFromHex(hex), !data.isEmpty else {
            fail("Invalid hex string")
            return
        }
        keyRawValue = data
        viewerName = "Hex"
        renderValue()   // syncs editorText to the editable hex dump
        notify("\(data.count) bytes loaded as Hex")
    }

    // MARK: KeyListVirtualTree.vue expansion state

    /// A freshly built tree arrives fully collapsed, which leaves the key column
    /// an empty grey field until the user starts clicking triangles. Open the
    /// structure shallowly instead: any folder with more than 20 children stays
    /// closed, so `session (143)` does not dump 143 UUIDs on first paint while
    /// `page (5)` still shows its five keys. Only runs while nothing is expanded,
    /// so a manual collapse is never undone.
    func autoExpandTreeIfNeeded() {
        guard expandedNodeIDs.isEmpty else { return }
        var expanded = Set<String>()
        var frontier = keyNodes.filter { !$0.isLeaf }
        var depth = 0
        while depth < 4 && !frontier.isEmpty && expanded.count < 24 {
            var next: [KeyNode] = []
            for node in frontier.prefix(12) {
                let children = node.children ?? []
                if children.count > 20 { continue }
                expanded.insert(node.fullPath)
                next.append(contentsOf: children.filter { !$0.isLeaf })
            }
            frontier = next
            depth += 1
        }
        guard !expanded.isEmpty else { return }
        expandedNodeIDs = expanded
    }

    func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { self.expandedNodeIDs.contains(id) },
            set: { expanded in
                if expanded { self.expandedNodeIDs.insert(id) } else { self.expandedNodeIDs.remove(id) }
                UserDefaults.standard.set(Array(self.expandedNodeIDs), forKey: "ARDMExpandedNodes")
            }
        )
    }

    // MARK: ConnectionWrapper.vue startPingInterval

    func startKeepalive() {
        onMain { [self] in
            self.keepaliveTimer?.invalidate()
            self.keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.pingActiveConnection()
            }
        }
    }

    func stopKeepalive() {
        onMain {
            self.keepaliveTimer?.invalidate()
            self.keepaliveTimer = nil
        }
    }

    // MARK: - Socket state, health check and auto-reconnect

    func setConnectionState(_ state: ConnectionState, for id: String) {
        connectionStates[id] = state
        if id == activeConnectionID { connected = state.isOnline }
    }

    /// State of the connection currently shown in the detail pane.
    var activeConnectionState: ConnectionState {
        guard let id = activeConnectionID else { return .disconnected }
        return connectionStates[id] ?? (connected ? .connected : .disconnected)
    }

    /// Keepalive tick. A failed PING flips the sidebar dot to “reconnecting” and
    /// starts the backoff loop right away, instead of waiting for the user's next
    /// command to fail with a confusing error.
    func pingActiveConnection() {
        guard connected, client != nil, let id = activeConnectionID else { return }
        if connectionStates[id]?.isBusy == true { return }
        onBackground {
            let healthy: Bool
            do {
                healthy = ardmString(try self.sendSync(["PING"])).uppercased().contains("PONG")
            } catch {
                healthy = false
            }
            self.onMain {
                if healthy { self.setConnectionState(.connected, for: id) }
                else { self.reconnect(id: id, manual: false) }
            }
        }
    }

    /// Runs the ObjC backoff loop off the main thread while the UI shows progress.
    func reconnect(id: String, manual: Bool = false) {
        guard let target = clients[id] ?? client else { return }
        if connectionStates[id]?.isBusy == true, !manual { return }
        let config = connections.first { $0.identifier == id }
        let total = max(1, Int(config?.retryTimes ?? 3))
        setConnectionState(.reconnecting(attempt: 1, total: total), for: id)
        statusText = L10n("Reconnecting") + " \(config?.name ?? id)…"
        onBackground {
            var failure: NSError?
            var ok = false
            do {
                try target.reconnectWithBackoff()
                ok = true
            } catch {
                failure = error as NSError
                if manual {
                    // Auto-reconnect may be disabled on this config: rebuild the socket by hand.
                    target.disconnect()
                    do {
                        try target.connect()
                        ok = true
                        failure = nil
                    } catch {
                        ok = false
                        failure = error as NSError
                    }
                }
            }
            self.onMain {
                if ok {
                    self.setConnectionState(.connected, for: id)
                    self.statusText = L10n("Connected:") + " \(config?.name ?? id)"
                    if id == self.activeConnectionID { self.refreshKeys(reset: true) }
                } else {
                    let reason = failure?.localizedDescription ?? L10n("Unknown error")
                    self.setConnectionState(.failed(reason), for: id)
                    self.statusText = L10n("Disconnected")
                    self.errorMessage = L10n("Connection lost") + ": " + reason
                }
            }
        }
    }

    // MARK: - Tree checkbox cascade (KeyListVirtualTree.vue parent/child selection)

    /// Every key stored beneath a folder node (precomputed by buildTree()).
    func keysInGroup(_ path: String) -> [String] {
        if let cached = groupMembership[path] { return cached }
        let sep = separator.isEmpty ? ":" : separator
        return keys.filter { $0.hasPrefix(path + sep) }
    }

    func groupCheckState(_ path: String) -> GroupCheckState {
        let members = keysInGroup(path)
        guard !members.isEmpty else { return .none }
        let hits = members.reduce(0) { $0 + (checkedKeys.contains($1) ? 1 : 0) }
        if hits == 0 { return .none }
        return hits == members.count ? .all : .partial
    }

    /// Checking a folder selects everything under it; unchecking clears them all.
    func toggleGroupCheck(_ path: String) {
        let members = keysInGroup(path)
        guard !members.isEmpty else { return }
        if groupCheckState(path) == .all { checkedKeys.subtract(members) }
        else { checkedKeys.formUnion(members) }
    }
}

private func ardmDataFromHex(_ hex: String) -> Data? {
    let chars = Array(hex.filter { $0.isHexDigit })
    guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(chars.count / 2)
    var index = 0
    while index < chars.count {
        let pair = String(chars[index]) + String(chars[index + 1])
        guard let byte = UInt8(pair, radix: 16) else { return nil }
        bytes.append(byte)
        index += 2
    }
    return Data(bytes)
}
