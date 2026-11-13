import Foundation

// MARK: - Per-type value decoding (KeyContent*.vue, all 10 types)

extension AppStore {
    /// Pure function: decode a RESP reply into editable rows. Safe to call off the main thread.
    func rowsForType(_ type: ARDMKeyType, key: String, value: Any) -> [KeyRow] {
        let items = ardmArray(value)
        var rows: [KeyRow] = []
        switch type {
        case .string, .reJSON, .vector, .unknown:
            let data = ardmData(value)
            rows.append(KeyRow(id: "value", field: "value", value: ardmString(value), raw: data))

        case .list, .set, .array:
            for (index, item) in items.enumerated() {
                rows.append(KeyRow(id: "\(index)", field: "\(index + rowOffset)",
                                   value: ardmString(item), raw: ardmData(item)))
            }

        case .zSet, .hash:
            var index = 0
            while index + 1 < items.count {
                let first = ardmString(items[index])
                let second = ardmString(items[index + 1])
                if type == .zSet {
                    rows.append(KeyRow(id: first, field: first, value: second, extra: second, raw: ardmData(items[index])))
                } else {
                    rows.append(KeyRow(id: first, field: first, value: second, raw: ardmData(items[index + 1])))
                }
                index += 2
            }

        case .stream:
            for entry in items {
                let pair = ardmArray(entry)
                guard let id = pair.first else { continue }
                var fields: [String] = []
                if pair.count > 1 {
                    let body = ardmArray(pair[1])
                    var i = 0
                    while i + 1 < body.count {
                        fields.append("\(ardmString(body[i]))=\(ardmString(body[i + 1]))")
                        i += 2
                    }
                }
                let entryID = ardmString(id)
                let suffix = formattedStreamDate(entryID).map { " · \($0)" } ?? ""
                rows.append(KeyRow(id: entryID, field: entryID,
                                   value: fields.joined(separator: ", ") + suffix,
                                   raw: ardmData(entry)))
            }

        case .timeSeries:
            for entry in items {
                let pair = ardmArray(entry)
                let stamp = pair.first.map { ardmString($0) } ?? ""
                let sample = pair.count > 1 ? ardmString(pair[1]) : ""
                rows.append(KeyRow(id: stamp, field: stamp, value: sample, raw: ardmData(entry)))
            }
        @unknown default:
            rows.append(KeyRow(id: "value", field: "value", value: ardmString(value), raw: ardmData(value)))
        }
        return rows
    }

    /// Full typed read with pagination and RedisJSON path support (replaces the Vue KeyContent loaders).
    func loadTypedValue() {
        guard let key = selectedKey, connected else { return }
        let offset = rowOffset
        let limit = rowLimit
        let path = jsonPath
        let type = selectedKeyType
        // Hash / Set / ZSet use cursor-based streaming scans (ioredis scan streams upstream).
        if type == .hash || type == .set || type == .zSet {
            scanRows(reset: true)
            return
        }
        onBackground {
            do {
                let command = self.readCommand(for: type, key: key, offset: offset, limit: limit, path: path)
                let reply = try self.sendSync(command)
                let rows = self.rowsForType(type, key: key, value: reply)
                let raw = type == .string || type == .reJSON || type == .vector ? ardmData(reply) : Data()
                self.onMain {
                    self.keyRows = rows
                    if !raw.isEmpty {
                        self.keyRawValue = raw
                        self.editorText = ardmString(reply)
                        self.renderValue()
                    }
                    self.statusText = "\(key) · \(typeName(type)) · \(rows.count) row(s) from \(offset)"
                }
            } catch {
                self.onMain { self.fail(error.localizedDescription) }
            }
        }
    }

    func readCommand(for type: ARDMKeyType, key: String, offset: Int, limit: Int, path: String) -> [String] {
        let start = "\(offset)"
        let stop = "\(offset + limit - 1)"
        switch type {
        case .string: return ["GET", key]
        case .list: return ["LRANGE", key, start, stop]
        case .set: return ["SMEMBERS", key]
        case .zSet: return ["ZRANGE", key, start, stop, "WITHSCORES"]
        case .hash: return ["HGETALL", key]
        case .stream: return ["XRANGE", key, "-", "+", "COUNT", "\(limit)"]
        case .reJSON: return ["JSON.GET", key, path]
        case .timeSeries: return timeSeriesReverse
            ? ["TS.REVRANGE", key, "-", "+", "COUNT", "\(limit)"]
            : ["TS.RANGE", key, "-", "+", "COUNT", "\(limit)"]
        case .vector: return ["VGETATTR", key, "0"]
        case .array: return ["ARGET", key, start, stop]
        case .unknown: return ["GET", key]
        @unknown default: return ["GET", key]
        }
    }

    // MARK: - Field-level editing

    func saveRow(_ row: KeyRow, field: String, value: String, extra: String) {
        guard let key = selectedKey else { return }
        let commands = writeCommands(for: selectedKeyType, key: key, row: row,
                                     field: field, value: value, extra: extra, remove: false)
        guard !commands.isEmpty else { return }
        onBackground {
            do {
                for command in commands { try self.sendSync(command) }
                self.onMain { self.reloadKeyDetail(); self.notify("Saved") }
            } catch { self.onMain { self.fail(error.localizedDescription) } }
        }
    }

    func deleteRow(_ row: KeyRow) {
        guard let key = selectedKey else { return }
        let commands = writeCommands(for: selectedKeyType, key: key, row: row,
                                     field: row.field, value: row.value, extra: row.extra, remove: true)
        guard !commands.isEmpty else { return }
        onBackground {
            do {
                for command in commands { try self.sendSync(command) }
                self.onMain { self.reloadKeyDetail(); self.notify("Row removed") }
            } catch { self.onMain { self.fail(error.localizedDescription) } }
        }
    }

    func writeCommands(for type: ARDMKeyType, key: String, row: KeyRow,
                       field: String, value: String, extra: String, remove: Bool) -> [[String]] {
        switch type {
        case .string:
            return remove ? [["DEL", key]] : [["SET", key, value]]
        case .hash:
            return remove ? [["HDEL", key, row.field]] : [["HSET", key, field, value]]
        case .list:
            if remove { return [["LREM", key, "1", row.value]] }
            if row.id == "__new__" { return [["RPUSH", key, value]] }
            return [["LSET", key, field, value]]
        case .set:
            if remove { return [["SREM", key, row.value]] }
            var commands: [[String]] = [["SADD", key, value]]
            if !row.value.isEmpty && row.value != value { commands.append(["SREM", key, row.value]) }
            return commands
        case .zSet:
            return remove ? [["ZREM", key, row.field]] : [["ZADD", key, extra.isEmpty ? "0" : extra, value]]
        case .stream:
            return remove ? [["XDEL", key, row.field]] : [["XADD", key, "*", field, value]]
        case .reJSON:
            return remove ? [["JSON.DEL", key, jsonPath]] : [["JSON.SET", key, jsonPath, value]]
        case .timeSeries:
            return remove ? [] : [["TS.ADD", key, field.isEmpty ? "*" : field, value]]
        case .vector:
            return remove ? [["VREM", key, row.field]] : [["VSETATTR", key, field, value]]
        case .array:
            return remove ? [["ARDEL", key, field]] : [["ARSET", key, field, value]]
        case .unknown:
            return remove ? [["DEL", key]] : [["SET", key, value]]
        @unknown default:
            return remove ? [["DEL", key]] : [["SET", key, value]]
        }
    }

    /// Stream consumer-group management (KeyContentStream.vue).
    func streamGroup(_ action: String, group: String, id: String = "0-0") {
        guard let key = selectedKey else { return }
        let args: [String]
        switch action {
        case "CREATE": args = ["XGROUP", "CREATE", key, group, "0", "MKSTREAM"]
        case "DESTROY": args = ["XGROUP", "DELCONSUMER", key, group, "ardm"]
        case "ACK": args = ["XACK", key, group, id]
        case "READ": args = ["XREADGROUP", "GROUP", group, "ardm", "COUNT", "\(rowLimit)", "STREAMS", key, ">"]
        default: args = ["XINFO", "GROUPS", key]
        }
        execute(args)
    }


    // MARK: - Cursor-based streaming reads (HSCAN / SSCAN / ZSCAN)

    func scanCommand(for type: ARDMKeyType, key: String, cursor: String, count: Int) -> [String] {
        let name: String
        switch type {
        case .hash: name = "HSCAN"
        case .set: name = "SSCAN"
        case .zSet: name = "ZSCAN"
        default: name = "SCAN"
        }
        var args: [String] = [name, key, cursor]
        if rowSearchPattern != "*" { args += ["MATCH", rowSearchPattern] }
        args += ["COUNT", "\(count)"]
        return args
    }

    /// Reads one cursor batch; append mode implements the "load more" path for huge keys.
    func scanRows(reset: Bool) {
        guard let key = selectedKey, connected else { return }
        let type = selectedKeyType
        guard type == .hash || type == .set || type == .zSet else { return }
        if !reset && rowScanFinished { return }
        let cursor = reset ? "0" : rowScanCursor
        let count = rowLimit
        let pattern = rowSearchPattern
        onBackground {
            do {
                var args: [String] = []
                switch type {
                case .hash: args = ["HSCAN", key, cursor]
                case .set: args = ["SSCAN", key, cursor]
                default: args = ["ZSCAN", key, cursor]
                }
                if pattern != "*" { args += ["MATCH", pattern] }
                args += ["COUNT", "\(count)"]
                let reply = try self.sendSync(args)
                let parts = ardmArray(reply)
                let next = parts.first.map { ardmString($0) } ?? "0"
                let flat = parts.count > 1 ? parts[1] : []
                let rows = self.rowsForType(type, key: key, value: flat)
                var ttls: [String: Int] = [:]
                if type == .hash && !rows.isEmpty {
                    var ttlArgs: [String] = ["HTTL", key, "FIELDS", "\(rows.count)"]
                    ttlArgs += rows.map { $0.field }
                    // Redis < 7.4 has no HTTL: silently degrade to "no field TTL info".
                    if let ttlReply = try? self.sendSync(ttlArgs) {
                        let values = ardmArray(ttlReply)
                        for (index, row) in rows.enumerated() where index < values.count {
                            if let seconds = Int(ardmString(values[index])) { ttls[row.field] = seconds }
                        }
                    }
                }
                self.onMain {
                    if reset {
                        self.keyRows = rows
                        self.fieldTTLs = ttls
                    } else {
                        self.keyRows.append(contentsOf: rows)
                        self.fieldTTLs.merge(ttls) { _, new in new }
                    }
                    self.rowScanCursor = next
                    self.rowScanFinished = next == "0" || next.isEmpty
                    self.statusText = "\(self.keyRows.count) " + L10n("rows")
                        + (self.rowScanFinished ? "" : " · " + L10n("Load more rows"))
                }
            } catch {
                self.onMain { self.fail(error.localizedDescription) }
            }
        }
    }

    /// Field-level expiry (Redis >= 7.4). -1 removes the field TTL.
    func setFieldTTL(_ field: String, seconds: Int) {
        guard let key = selectedKey, selectedKeyType == .hash else { return }
        let command = seconds < 0
            ? ["HPERSIST", key, "FIELDS", "1", field]
            : ["HEXPIRE", key, "\(seconds)", "FIELDS", "1", field]
        send(command) { result in
            if case .success = result {
                self.notify("Field TTL updated")
                self.scanRows(reset: true)
            }
        }
    }

    /// Millisecond TTL (PTTL / PEXPIRE), matching KeyList.vue's PTTL support.
    func setTTLMillis(_ millis: Int) {
        guard let key = selectedKey else { return }
        let command = millis < 0 ? ["PERSIST", key] : ["PEXPIRE", key, "\(millis)"]
        send(command) { result in
            if case .success = result { self.notify("TTL (ms) updated"); self.reloadKeyDetail() }
        }
    }

    func refreshPTTL() {
        guard let key = selectedKey else { return }
        send(["PTTL", key]) { result in
            if case .success(let reply) = result { self.selectedKeyTTLMillis = Int(ardmString(reply)) ?? -1 }
        }
    }

    /// Per-row "copy as command" (dumpCommand in every upstream KeyContent*.vue).
    func writeCommandString(for row: KeyRow) -> String {
        let commands = writeCommands(for: selectedKeyType, key: selectedKey ?? "", row: row,
                                     field: row.field, value: row.value, extra: row.extra, remove: false)
        return commands.map { $0.joined(separator: " ") }.joined(separator: "\n")
    }

    /// Save the whole string/JSON value from the editor (ViewerText / JsonEditor).
    /// The active viewer now encodes the edited text back to its original binary format.
    func saveEditorText() {
        guard let key = selectedKey else { return }
        let viewer = viewerName
        guard ARDMFormatters.encodableViewers().contains(viewer) else {
            fail("Viewer \(viewer) is decode-only; switch to Text / Hex / Json to write back.")
            return
        }
        var error: NSError?
        let payload = ARDMFormatters.encode(editorText, as: viewer, error: &error)
        if let error { fail(error.localizedDescription); return }
        let type = selectedKeyType
        let path = jsonPath
        onBackground {
            do {
                if type == .reJSON {
                    try self.sendRawSync(["JSON.SET", key, path, self.editorText])
                } else {
                    try self.sendRawSync(["SET", key, payload])
                }
                self.onMain { self.reloadKeyDetail(); self.notify("Value saved") }
            } catch { self.onMain { self.fail(error.localizedDescription) } }
        }
    }

    /// Load a {fieldNumber: fieldName} JSON map for the Protobuf viewer.
    func loadProtobufSchema() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            fail("Protobuf schema must be a JSON object of {\"fieldNumber\": \"fieldName\"}.")
            return
        }
        var schema: [NSNumber: String] = [:]
        for (number, name) in raw {
            if let n = Int(number) { schema[NSNumber(value: n)] = name }
        }
        ARDMFormatters.setProtobufSchema(schema)
        notify("Protobuf schema loaded: \(schema.count) fields")
        renderValue()
    }
}
