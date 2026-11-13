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
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
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
                guard let self, self.connected, self.client != nil else { return }
                self.onBackground { _ = try? self.sendSync(["PING"]) }
            }
        }
    }

    func stopKeepalive() {
        onMain {
            self.keepaliveTimer?.invalidate()
            self.keepaliveTimer = nil
        }
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
