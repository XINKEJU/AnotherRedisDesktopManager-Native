import Foundation
import UniformTypeIdentifiers

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
        // Hash / Set use cursor-based streaming scans (ioredis scan streams upstream).
        // ZSet uses ordered ZRANGE WITHSCORES for the plain view; ZSCAN is only used
        // when a search pattern is active (matches upstream ZSetContent behaviour).
        if type == .hash || type == .set {
            scanRows(reset: true)
            return
        }
        if type == .zSet {
            if rowSearchPattern != "*" && !rowSearchPattern.isEmpty {
                scanRows(reset: true)
            } else {
                onBackground { [self] in
                    do {
                        let command = self.readCommand(for: type, key: key, offset: offset, limit: limit, path: path)
                        let reply = try self.sendSync(command)
                        let rows = self.rowsForType(type, key: key, value: reply)
                        self.onMain {
                            self.keyRows = rows
                            self.statusText = "\(key) · \(typeName(type)) · \(rows.count) row(s) from \(offset)"
                        }
                    } catch { self.onMain { self.fail(error.localizedDescription) } }
                }
            }
            return
        }
        // Vector Set: there is no single read command for all elements, so fetch a
        // window of dimensions via VGETATTR and stop at the first missing index.
        // Redis < 8 has no vector type — surface a clear notice instead of failing.
        if type == .vector {
            if redisMajor < 8 {
                self.onMain {
                    self.keyRows = []
                    self.editorText = "VECTOR type requires Redis 8.0+ (current server: \(self.redisVersion.isEmpty ? "unknown" : self.redisVersion))."
                    self.statusText = "\(key) · vector · unsupported server version"
                }
                return
            }
            onBackground {
                do {
                    var rows: [KeyRow] = []
                    for i in 0..<limit {
                        let reply = try self.sendSync(["VGETATTR", key, "\(i)"])
                        let text = ardmString(reply)
                        if text.isEmpty || text == "(nil)" || text == "nil" { break }
                        rows.append(KeyRow(id: "\(i)", field: "\(i)", value: text, raw: ardmData(reply)))
                    }
                    self.onMain { self.keyRows = rows; self.statusText = "\(key) · vector · \(rows.count) dim(s) · quant=\(self.vectorQuantization)" }
                } catch { self.onMain { self.fail(error.localizedDescription) } }
            }
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
        case .stream: return streamReverse
            ? ["XREVRANGE", key, "+", "-", "COUNT", "\(limit)"]
            : ["XRANGE", key, "-", "+", "COUNT", "\(limit)"]
        case .reJSON: return ["JSON.GET", key, path]
        case .timeSeries:
            var args: [String] = timeSeriesReverse
                ? ["TS.REVRANGE", key, "-", "+"]
                : ["TS.RANGE", key, "-", "+"]
            if tsAggregation != "None" {
                args += ["AGGREGATION", tsAggregation, tsBucket]
            }
            if !tsFilterMin.isEmpty {
                let max = tsFilterMax.isEmpty ? tsFilterMin : tsFilterMax
                args += ["FILTER_BY_VALUE", tsFilterMin, max]
            }
            args += ["COUNT", "\(limit)"]
            return args
        case .vector: return ["VGETATTR", key, "0"]
        case .array: return ["ARGET", key, start, stop]
        case .unknown: return ["GET", key]
        @unknown default: return ["GET", key]
        }
    }

    // MARK: - Field-level editing

    func saveRow(_ row: KeyRow, field: String, value: String, extra: String) {
        guard let key = selectedKey else { return }
        let type = selectedKeyType
        let commands = writeCommands(for: type, key: key, row: row,
                                     field: field, value: value, extra: extra, remove: false)
        guard !commands.isEmpty else { return }
        onBackground {
            do {
                for command in commands { try self.sendSync(command) }
                self.onMain {
                    if type == .hash {
                        // Incremental update: patch the visible row instead of a full
                        // reloadKeyDetail (matches upstream's local store update).
                        if let idx = self.keyRows.firstIndex(where: { $0.field == field }) {
                            self.keyRows[idx].value = value
                            self.keyRows[idx].raw = Data(value.utf8)
                        } else {
                            self.keyRows.append(KeyRow(id: field, field: field, value: value, raw: Data(value.utf8)))
                        }
                        self.notify("Saved")
                    } else {
                        self.reloadKeyDetail()
                        self.notify("Saved")
                    }
                }
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
            // Order-preserving in-place replacement: insert the new value right after
            // the old one, then remove exactly one occurrence of the old value
            // (matches upstream ListContent.vue LINSERT AFTER + LREM behaviour).
            if value == row.value { return [["LSET", key, field, value]] }
            return [["LINSERT", key, "AFTER", row.value, value],
                    ["LREM", key, "1", row.value]]
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
            return remove ? [] : [["TS.ADD", key, field.isEmpty ? "*" : field, value, "ON_DUPLICATE", "LAST"]]
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

    // MARK: - ZSet batch edit

    /// Members of the loaded page matching the batch pattern (glob syntax).
    func zsetBatchMembers() -> [String] {
        let pattern = zsetBatchPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, pattern != "*" else { return keyRows.map(\.field) }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        guard let regex = try? NSRegularExpression(pattern: "^" + escaped + "$") else {
            return keyRows.map(\.field)
        }
        return keyRows.filter { row in
            regex.firstMatch(in: row.field, range: NSRange(row.field.startIndex..., in: row.field)) != nil
        }.map(\.field)
    }

    /// Applies one action to every matching member: delete, set score, or add delta.
    func applyZSetBatch() {
        guard let key = selectedKey, selectedKeyType == .zSet else { return }
        let members = Array(zsetBatchMembers().prefix(1000))
        guard !members.isEmpty else {
            fail(L10n("No member matches the pattern."))
            return
        }
        var commands: [[String]] = []
        switch zsetBatchAction {
        case "Set score":
            guard Double(zsetBatchScore) != nil else {
                fail(L10n("Score must be a number."))
                return
            }
            // XX keeps the batch from silently creating members that never existed.
            commands = members.map { ["ZADD", key, "XX", zsetBatchScore, $0] }
        case "Add delta":
            guard Double(zsetBatchScore) != nil else {
                fail(L10n("Score must be a number."))
                return
            }
            commands = members.map { ["ZINCRBY", key, zsetBatchScore, $0] }
        default:
            commands = members.map { ["ZREM", key, $0] }
        }
        onBackground {
            do {
                for command in commands { _ = try self.sendSync(command) }
                self.onMain {
                    self.showingZSetBatch = false
                    self.notify("\(commands.count) " + L10n("member(s) updated"))
                    self.loadTypedValue()
                }
            } catch {
                self.onMain { self.fail(error.localizedDescription) }
            }
        }
    }

    /// Stream consumer-group management (KeyContentStream.vue).
    func streamGroup(_ action: String, group: String, id: String = "0-0") {        guard let key = selectedKey else { return }
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

    /// TS.INFO — flatten labels / rules / source key into readable rows.
    func loadTimeSeriesInfo() {
        guard let key = selectedKey, selectedKeyType == .timeSeries else { return }
        onBackground {
            do {
                let reply = try self.sendSync(["TS.INFO", key])
                var rows: [[String]] = []
                let flat = ardmArray(reply)
                var i = 0
                while i + 1 < flat.count {
                    let name = ardmString(flat[i])
                    let value = flat[i + 1]
                    if let nested = value as? [Any], !nested.isEmpty {
                        // labels / rules come back as arrays of pairs.
                        let pairs = nested.map { ardmString($0) }.filter { !$0.isEmpty }
                        rows.append([name, pairs.joined(separator: " ")])
                    } else {
                        rows.append([name, ardmString(value)])
                    }
                    i += 2
                }
                self.onMain { self.tsInfo = rows; self.notify("TS.INFO · \(rows.count) field(s)") }
            } catch { self.onMain { self.fail(error.localizedDescription) } }
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
        let ttl = selectedKeyTTL
        onBackground {
            do {
                if type == .reJSON {
                    try self.sendRawSync(["JSON.SET", key, path, self.editorText])
                } else {
                    try self.sendRawSync(["SET", key, payload])
                }
                // Restore the key's TTL after an overwrite so expiration is preserved
                // (upstream KeyContentString.vue keeps the existing ttl on save).
                if ttl > 0 {
                    _ = try? self.sendRawSync(["EXPIRE", key, "\(ttl)"])
                } else if ttl == -1 {
                    _ = try? self.sendRawSync(["PERSIST", key])
                }
                self.onMain { self.reloadKeyDetail(); self.notify("Value saved") }
            } catch { self.onMain { self.fail(error.localizedDescription) } }
        }
    }

    /// Load a Protobuf schema for the viewer. Accepts either a
    /// {fieldNumber: fieldName} JSON map or a real `.proto` file.
    func loadProtobufSchema() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        let protoType = UTType(filenameExtension: "proto")
        panel.allowedContentTypes = [.json] + (protoType.map { [$0] } ?? [])
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        var schema: [NSNumber: String] = [:]
        if url.pathExtension.lowercased() == "proto" {
            let text = String(data: data, encoding: .utf8) ?? ""
            let parsed = parseProtoFile(text)
            guard !parsed.scopes.isEmpty else {
                fail("No `type name = number;` field declarations found in the .proto file.")
                return
            }
            ARDMFormatters.setProtobufScopes(parsed.scopes, root: parsed.root)
            let fieldCount = parsed.scopes[parsed.root]?.count ?? 0
            notify("Protobuf schema loaded: \(fieldCount) field(s) in \(parsed.scopes.count) message(s)")
            renderValue()
            return
        }

        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            fail("Protobuf schema must be a JSON object of {\"fieldNumber\": \"fieldName\"} or a .proto file.")
            return
        }
        for (number, name) in raw {
            if let n = Int(number) { schema[NSNumber(value: n)] = name }
        }
        ARDMFormatters.setProtobufSchema(schema)
        notify("Protobuf schema loaded: \(schema.count) fields")
        renderValue()
    }

    /// `.proto` parser: keeps every message in its own scope so nested messages can
    /// be decoded recursively, marks enums so they are labelled rather than treated
    /// as sub-messages, and records fixed-width wire kinds for correct rendering.
    private func parseProtoFile(_ text: String) -> (scopes: [String: [NSNumber: String]], root: String) {
        // Strip /* … */ comments so their braces cannot upset the block stack.
        var cleaned = ""
        var i = text.startIndex
        var inBlock = false
        while i < text.endIndex {
            let next = text.index(after: i)
            if !inBlock, text[i] == "/", next < text.endIndex, text[next] == "*" {
                inBlock = true
                i = text.index(i, offsetBy: 2)
                continue
            }
            if inBlock, text[i] == "*", next < text.endIndex, text[next] == "/" {
                inBlock = false
                i = text.index(i, offsetBy: 2)
                continue
            }
            if !inBlock { cleaned.append(text[i]) }
            i = next
        }

        let lines: [String] = cleaned.components(separatedBy: .newlines).map { raw in
            var line = raw
            if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
            return line.trimmingCharacters(in: .whitespaces)
        }

        // Pass 1: enum names, so `Status status = 1;` is not mistaken for a message.
        var enumNames = Set<String>()
        for line in lines {
            let tokens = line.split(whereSeparator: { " \t{}".contains($0) }).map(String.init)
            if tokens.count >= 2, tokens[0] == "enum" { enumNames.insert(tokens[1]) }
        }

        var scopes: [String: [NSNumber: String]] = [:]
        var stack: [(kind: String, name: String)] = []
        var root = ""
        var pending: (kind: String, name: String)?

        func messageChain(_ stack: [(kind: String, name: String)]) -> [String] {
            stack.filter { $0.kind == "message" }.map(\.name)
        }
        func qualified(_ name: String, _ stack: [(kind: String, name: String)]) -> String {
            (messageChain(stack) + [name]).filter { !$0.isEmpty }.joined(separator: ".")
        }
        func open(_ declaration: (kind: String, name: String)) {
            if declaration.kind == "message" {
                let full = qualified(declaration.name, stack)
                if root.isEmpty { root = full }
                scopes[full] = scopes[full] ?? [:]
                stack.append(("message", declaration.name))
            } else {
                stack.append(declaration)
            }
        }

        for line in lines {
            guard !line.isEmpty else { continue }
            // Closing braces (possibly several on one line, e.g. "} }").
            if line.hasPrefix("}") {
                var closers = line.filter { $0 == "}" }.count
                while closers > 0, !stack.isEmpty {
                    stack.removeLast()
                    closers -= 1
                }
                continue
            }
            let tokens = line.split(whereSeparator: { " \t{};".contains($0) }).map(String.init)
            guard let first = tokens.first else { continue }

            // Block declarations: message / enum / service / extend / oneof.
            if ["message", "enum", "service", "extend", "oneof"].contains(first) {
                guard tokens.count >= 2 else { continue }
                let declaration = (kind: first, name: tokens[1])
                if line.contains("{") {
                    open(declaration)
                } else {
                    pending = declaration
                }
                continue
            }
            if line.hasPrefix("{") {
                if let declaration = pending { open(declaration) }
                pending = nil
                continue
            }
            if first == "syntax" || first == "import" || first == "package"
                || first == "option" || first == "reserved" || first == "extensions" { continue }

            // Field declaration inside a message (enum bodies are skipped; fields
            // inside a `oneof` still belong to the enclosing message).
            guard stack.contains(where: { $0.kind == "message" }),
                  stack.last?.kind != "enum",
                  line.contains("="), line.hasSuffix(";"),
                  let eq = tokens.firstIndex(of: "="), eq >= 2, eq + 1 < tokens.count else { continue }
            let fieldName = tokens[eq - 1]
            guard let number = Int(tokens[eq + 1]) else { continue }

            var type = tokens[eq - 2]
            if ["repeated", "optional", "required"].contains(type), eq >= 3 {
                type = tokens[eq - 3]
            }
            if tokens[0].hasPrefix("map<") { type = "map" }
            let bareType = type.split(separator: ".").last.map(String.init) ?? type

            let kind: String
            switch bareType {
            case "double": kind = "double"
            case "float": kind = "float"
            case "fixed32", "sfixed32": kind = "fixed32"
            case "fixed64", "sfixed64": kind = "fixed64"
            case "string": kind = "string"
            case "bytes", "map": kind = "bytes"
            case "bool": kind = "bool"
            case "int32", "int64", "uint32", "uint64", "sint32", "sint64": kind = "varint"
            default:
                if enumNames.contains(bareType) { kind = "enum" }
                else { kind = "message" }
            }

            let descriptor: String
            if kind == "message" {
                descriptor = "message|\(fieldName)|\(qualified(bareType, stack))"
            } else {
                descriptor = "\(kind)|\(fieldName)"
            }
            let current = messageChain(stack).joined(separator: ".")
            scopes[current, default: [:]][NSNumber(value: number)] = descriptor
        }

        if root.isEmpty { root = scopes.keys.sorted().first ?? "" }
        return (scopes, root)
    }
}

// MARK: - Byte-level hex editing (HexEditor.vue replacement)

extension AppStore {
    /// Seeds the grid from the currently loaded raw value.
    func openHexEditor() {
        guard selectedKey != nil else { return }
        let raw = keyRawValue
        let limit = hexEditLimit
        hexBytes = Array(raw.prefix(limit))
        hexTail = raw.count > limit ? raw.suffix(from: limit) : Data()
        showingHexEditor = true
    }

    var hexWasTruncated: Bool { !hexTail.isEmpty }

    func setHexByte(at index: Int, to value: UInt8) {
        guard hexBytes.indices.contains(index) else { return }
        hexBytes[index] = value
    }

    func insertHexByte(at index: Int) {
        let position = min(max(0, index), hexBytes.count)
        hexBytes.insert(0x00, at: position)
    }

    func deleteHexByte(at index: Int) {
        guard hexBytes.indices.contains(index) else { return }
        hexBytes.remove(at: index)
    }

    func saveHexEditor() {
        guard let key = selectedKey else { return }
        var payload = Data(hexBytes)
        payload.append(hexTail)
        let ttl = selectedKeyTTL
        onBackground {
            do {
                try self.sendRawSync(["SET", key, payload])
                if ttl > 0 { _ = try? self.sendRawSync(["EXPIRE", key, "\(ttl)"]) }
                self.onMain {
                    self.showingHexEditor = false
                    self.reloadKeyDetail()
                    self.notify("Value saved · \(payload.count) byte(s)")
                }
            } catch {
                self.onMain { self.fail(error.localizedDescription) }
            }
        }
    }
}
