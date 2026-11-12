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
                rows.append(KeyRow(id: ardmString(id), field: ardmString(id),
                                   value: fields.joined(separator: ", "),
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
        case .timeSeries: return ["TS.RANGE", key, "-", "+", "COUNT", "\(limit)"]
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

    /// Save the whole string/JSON value from the editor (ViewerText / JsonEditor).
    func saveEditorText() {
        guard let key = selectedKey else { return }
        let text = editorText
        let type = selectedKeyType
        let path = jsonPath
        let args: [String]
        switch type {
        case .reJSON: args = ["JSON.SET", key, path, text]
        case .hash, .list, .set, .zSet, .stream, .timeSeries, .vector, .array:
            args = ["SET", key, text]
        default: args = ["SET", key, text]
        }
        send(args) { result in
            if case .success = result { self.reloadKeyDetail(); self.notify("Value saved") }
        }
    }
}
