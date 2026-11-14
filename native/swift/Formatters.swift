import Foundation
import JavaScriptCore
import zlib

/// Value viewers and encoders moved out of Services.m. The dispatch names are
/// unchanged so the SwiftUI layer keeps calling the same API.
enum ARDMFormatters {

    // MARK: - Viewer registry

    static func viewerNames() -> [String] {
        ["Text", "Json", "Hex", "Binary", "Msgpack", "PHPSerialize", "JavaSerialize",
         "Pickle", "Protobuf", "Brotli", "Gzip", "Deflate", "DeflateRaw", "OverSize", "Custom"]
    }

    static func encodableViewers() -> [String] {
        viewerNames().filter {
            !["JavaSerialize", "Pickle", "OverSize"].contains($0)
        }
    }

    // MARK: - Protobuf schema (loaded from the selected key's .proto file)

    static func setProtobufSchema(_ schema: [NSNumber: String]?) {
        ARDMProtobuf.schema = schema
        ARDMProtobuf.scopes = nil
        ARDMProtobuf.root = nil
    }

    static func setProtobufScopes(_ scopes: [String: [NSNumber: String]]?, root: String?) {
        ARDMProtobuf.scopes = scopes
        ARDMProtobuf.root = root
    }

    static func protobufSchema() -> [NSNumber: String]? {
        ARDMProtobuf.schema
    }

    // MARK: - Detection

    private static func isPlainText(_ data: Data) -> Bool {
        for byte in data {
            if byte >= 0x20 && byte != 0x7f { continue }
            if byte == 0x09 || byte == 0x0a || byte == 0x0d { continue }
            return false
        }
        return String(data: data, encoding: .utf8) != nil
    }

    static func detectViewer(for data: Data) -> String {
        let p = [UInt8](data)
        let n = p.count
        if n >= 2 && p[0] == 0x1f && p[1] == 0x8b { return "Gzip" }
        if n >= 2 && p[0] == 0x78 && (p[1] == 0x01 || p[1] == 0x9c || p[1] == 0xda) { return "Deflate" }
        if n >= 2 && p[0] == 0xac && p[1] == 0xed { return "JavaSerialize" }
        if n >= 1 && p[0] == 0x80 && (n == 1 || p[1] <= 0x05) { return "Pickle" }
        if n >= 1 && p[0] == 0xce && n >= 2 && p[1] == 0xb2 { return "Brotli" }
        if n >= 1 && p[0] == 0x7b {
            if let text = String(data: data, encoding: .utf8),
               formatJSON(data, pretty: false) != nil || text.hasPrefix("{\"") {
                return "Json"
            }
        }
        if n >= 2 && (p[0] == 0x82 || p[0] == 0x83) && p[1] >= 0xa0 && p[1] <= 0xbf { return "Msgpack" }
        if n >= 3 && (p[0] == 0x92 || p[0] == 0x93) { return "Msgpack" }
        if n >= 1 && (p[0] == 0x9f || p[0] == 0xdf) { return "Msgpack" }
        if n >= 6 {
            var isPHP = true
            let prefix = Array(p[0..<min(10, n)])
            for (index, byte) in prefix.enumerated() {
                if byte == UInt8(ascii: ":") { break }
                if isPHP && !(byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) && byte != UInt8(ascii: "_") {
                    isPHP = false
                }
                if index == prefix.count - 1 { isPHP = isPHP && byte == UInt8(ascii: ";") }
            }
            if isPHP && (p[0] == UInt8(ascii: "a") || p[0] == UInt8(ascii: "s")
                         || p[0] == UInt8(ascii: "i") || p[0] == UInt8(ascii: "d")
                         || p[0] == UInt8(ascii: "b")) {
                if let text = String(data: data, encoding: .utf8), text.contains(":") {
                    return "PHPSerialize"
                }
            }
        }
        if n >= 2 {
            let first = Int(p[0])
            let isLetter = (first >= 65 && first <= 90) || (first >= 97 && first <= 122)
            let length = Int(p[1])
            if isLetter && length <= 4 && (n == 2 || p[2] < 0x20) { return "Protobuf" }
        }
        if n >= 2 && p[0] == 0x03 && p[1] == 0x00 { return "DeflateRaw" }
        if isPlainText(data) { return "Text" }
        if n > 0 && p[0] == 0x08 { return "Protobuf" }
        return "Hex"
    }

    // MARK: - Render

    static func render(_ data: Data, as viewer: String, error: NSErrorPointer) -> String {
        if viewer == "Text" || viewer == "Custom" { return plainText(data) }
        if viewer == "Json" {
            if let pretty = formatJSON(data, pretty: true) { return pretty }
            if let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                return jsonString(object)
            }
            return plainText(data)
        }
        if viewer == "Hex" { return hexDump(data) }
        if viewer == "Binary" { return binaryDump(data) }
        if viewer == "Msgpack" { return msgpackRender(data) }
        if viewer == "PHPSerialize" { return phpRender(data) }
        if viewer == "JavaSerialize" { return ARDMJavaReader.deserialize(data) }
        if viewer == "Pickle" { return ARDMPickle.unpickle(data) }
        if viewer == "Protobuf" { return ARDMProtobuf.dump(data) }
        if viewer == "Brotli" {
            guard let output = brotli(data, decode: true) else {
                return "Brotli: system decoder unavailable (install brotli CLI for this viewer)"
            }
            return plainText(output)
        }
        if viewer == "Gzip" { return decompressed(data, windowBits: 31, label: "gzip", error: error) }
        if viewer == "Deflate" { return decompressed(data, windowBits: 15, label: "deflate", error: error) }
        if viewer == "DeflateRaw" { return decompressed(data, windowBits: -15, label: "raw deflate", error: error) }
        return plainText(data)
    }

    static func render(_ data: Data, as viewer: String, offset: UInt, length: UInt,
                       error: NSErrorPointer) -> String {
        if viewer != "OverSize" || data.isEmpty {
            return render(data, as: viewer, error: error)
        }
        let start = min(offset, UInt(data.count))
        let span = min(length, UInt(data.count) - start)
        let chunk = data.subdata(in: Int(start)..<Int(start + span))
        let last = start + span
        return "Value too large to display inline (\(data.count) bytes).\n"
            + "Bytes \(start)–\(last) of \(data.count) "
            + "(0x\(String(start, radix: 16, uppercase: true))–0x\(String(last, radix: 16, uppercase: true))):\n"
            + hexDump(chunk)
    }

    private static func decompressed(_ data: Data, windowBits: Int32, label: String,
                                     error: NSErrorPointer) -> String {
        guard let output = inflate(data, windowBits: windowBits) else {
            if let error {
                error.pointee = NSError(domain: "ARDMFormatters", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "Decompression failed",
                ])
            }
            return ""
        }
        return plainText(output)
    }

    // MARK: - Custom viewer (JavaScriptCore sandbox)

    static func renderCustom(_ data: Data, script: String, error: NSErrorPointer) -> String {
        guard let context = JSContext() else { return "<no result>" }
        context.exceptionHandler = { _, exception in
            NSLog("ARDM custom formatter: %@", exception?.toString() ?? "unknown error")
        }
        let bytes = [UInt8](data).map { NSNumber(value: $0) }
        context.setObject(bytes, forKeyedSubscript: "ARDM_BYTES" as NSString)
        let wrapped = "var bytes = new Uint8Array(ARDM_BYTES);"
            + "var result = (function(bytes) { \(script) })(bytes); String(result);"
        guard let value = context.evaluateScript(wrapped), let result = value.toString() else {
            return "<no result>"
        }
        return result
    }

    // MARK: - Encode

    static func encode(_ text: String, as viewer: String, error: NSErrorPointer) -> Data {
        if viewer == "Protobuf" {
            return ARDMProtobuf.encode(text, error: error) ?? Data()
        }
        if viewer == "Text" || viewer == "Json" || viewer == "Custom" {
            return text.data(using: .utf8) ?? Data()
        }
        if viewer == "Hex" { return dataFromHexDump(text) }
        if viewer == "Binary" { return dataFromBinaryDump(text) }
        let utf8 = text.data(using: .utf8) ?? Data()
        if viewer == "Msgpack" {
            guard let object = jsonObject(text) else {
                set(error, 30, "Edited value is not valid JSON")
                return Data()
            }
            var out = Data()
            msgpackAppend(object, &out)
            return out
        }
        if viewer == "PHPSerialize" {
            guard let object = jsonObject(text) else {
                set(error, 30, "Edited value is not valid JSON")
                return Data()
            }
            var out = ""
            phpSerializeObject(object, &out)
            return out.data(using: .utf8) ?? Data()
        }
        if viewer == "Gzip" {
            guard let out = deflate(utf8, windowBits: 31) else {
                set(error, 31, "Compression failed")
                return Data()
            }
            return out
        }
        if viewer == "Deflate" {
            guard let out = deflate(utf8, windowBits: 15) else {
                set(error, 31, "Compression failed")
                return Data()
            }
            return out
        }
        if viewer == "DeflateRaw" {
            guard let out = deflate(utf8, windowBits: -15) else {
                set(error, 31, "Compression failed")
                return Data()
            }
            return out
        }
        if viewer == "Brotli" {
            guard let out = brotli(utf8, decode: false) else {
                set(error, 32, "System brotli CLI is required to encode")
                return Data()
            }
            return out
        }
        set(error, 33, "Viewer \(viewer) is decode-only")
        return Data()
    }

    private static func set(_ error: NSErrorPointer, _ code: Int, _ message: String) {
        if let error {
            error.pointee = NSError(domain: "ARDMFormatters", code: code, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    private static func jsonObject(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private static func jsonString(_ object: Any) -> String {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: object)
    }

    // MARK: - Text / dumps

    private static func plainText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return hexDump(data)
    }

    static func hexDump(_ data: Data) -> String {
        let p = [UInt8](data)
        let n = p.count
        var out = ""
        var i = 0
        while i < n {
            let lineEnd = min(i + 16, n)
            out += String(format: "%08lx  ", i)
            var j = i
            while j < lineEnd {
                out += String(format: "%02x ", p[j])
                j += 1
            }
            while j < i + 16 {
                out += "   "
                j += 1
            }
            out += " |"
            j = i
            while j < lineEnd {
                let byte = p[j]
                out += (byte >= 0x20 && byte != 0x7f) ? String(UnicodeScalar(byte)) : "."
                j += 1
            }
            out += "|\n"
            i = lineEnd
        }
        return out
    }

    static func binaryDump(_ data: Data) -> String {
        let p = [UInt8](data)
        let n = p.count
        var out = ""
        for i in 0..<n {
            let byte = p[i]
            var shift = 7
            while shift >= 0 {
                out += ((byte >> UInt8(shift)) & 1) != 0 ? "1" : "0"
                shift -= 1
            }
            out += (i % 4 == 3 || i == n - 1) ? "\n" : " "
        }
        return out
    }

    private static func dataFromHexDump(_ text: String) -> Data {
        var out = Data()
        for rawLine in text.components(separatedBy: "\n") {
            guard let bar = rawLine.range(of: " |") else { continue }
            let hexPart = String(rawLine[rawLine.startIndex..<bar.lowerBound])
            for token in hexPart.components(separatedBy: .whitespaces) where !token.isEmpty {
                // The first token is the offset column; skip it.
                if token.count != 2 { continue }
                if let value = UInt8(token, radix: 16) { out.append(value) }
            }
        }
        return out
    }

    private static func dataFromBinaryDump(_ text: String) -> Data {
        var out = Data()
        for token in text.components(separatedBy: .whitespacesAndNewlines) where !token.isEmpty {
            if token.count != 8 { continue }
            if let value = UInt8(token, radix: 2) { out.append(value) }
        }
        return out
    }

    // MARK: - Token-preserving JSON formatter

    /// Token-preserving JSON formatter. The payload is walked as bytes and
    /// re-emitted as bytes so that out-of-range integers keep every digit and
    /// UTF-8 text passes through untouched — decoding per byte would turn
    /// 「张三丰」 into latin-1 mojibake.
    static func formatJSON(_ data: Data, pretty: Bool) -> String? {
        let p = [UInt8](data)
        let n = p.count
        var i = 0
        while i < n && (p[i] == 0x20 || p[i] == 0x0a || p[i] == 0x0d || p[i] == 0x09) { i += 1 }
        if i >= n { return nil }
        let first = p[i]
        let scalar = first != UInt8(ascii: "{") && first != UInt8(ascii: "[")
        if scalar {
            let allowed = first == UInt8(ascii: "\"") || first == UInt8(ascii: "-")
                || (first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9"))
                || first == UInt8(ascii: "t") || first == UInt8(ascii: "f")
                || first == UInt8(ascii: "n")
            if !allowed { return nil }
        }
        var out = [UInt8]()
        out.reserveCapacity(n + 64)
        var stack: [UInt8] = []          // expected closing characters
        var depth = 0
        var inString = false
        var escape = false
        func newline(_ depth: Int) {
            out.append(0x0a)
            for _ in 0..<(depth * 2) { out.append(0x20) }
        }
        while i < n {
            let c = p[i]
            i += 1
            if inString {
                out.append(c)
                if escape {
                    escape = false
                } else if c == UInt8(ascii: "\\") {
                    escape = true
                } else if c == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            if c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09 { continue }
            switch c {
            case UInt8(ascii: "\""):
                inString = true
                out.append(c)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let closer: UInt8 = c == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                stack.append(closer)
                out.append(c)
                depth += 1
                if pretty { newline(depth) }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard let expected = stack.popLast() else { return nil }   // unbalanced closer
                if expected != c { return nil }                            // { ] mismatch
                depth -= 1
                if pretty { newline(depth) }
                out.append(c)
            case UInt8(ascii: ","):
                if pretty {
                    out.append(0x2c)
                    newline(depth)
                } else {
                    out.append(0x2c)
                }
            case UInt8(ascii: ":"):
                out.append(contentsOf: pretty ? [0x3a, 0x20] : [0x3a])
            default:
                out.append(c)
            }
        }
        if inString || !stack.isEmpty { return nil }   // unterminated string / unclosed container
        if let text = String(bytes: out, encoding: .utf8) { return text }
        return String(decoding: out, as: UTF8.self)     // invalid UTF-8 → replacement chars
    }

    static func validateJSON(_ data: Data) -> Bool {
        formatJSON(data, pretty: false) != nil
    }

    // MARK: - Msgpack

    private static func appendBigEndian(_ value: UInt64, _ count: Int, _ out: inout Data) {
        var shift = (count - 1) * 8
        while shift >= 0 {
            out.append(UInt8((value >> UInt64(shift)) & 0xff))
            shift -= 8
        }
    }

    private static func msgpackAppend(_ value: Any, _ out: inout Data) {
        if value is NSNull {
            out.append(0xc0)
            return
        }
        if let text = value as? String {
            let bytes = text.data(using: .utf8) ?? Data()
            let length = bytes.count
            if length <= 31 {          // fixstr
                out.append(0xa0 | UInt8(length))
            } else if length <= 255 {
                out.append(0xd9)
                out.append(UInt8(length))
            } else if length <= 65535 {
                out.append(0xda)
                appendBigEndian(UInt64(length), 2, &out)
            } else {
                out.append(0xdb)
                appendBigEndian(UInt64(length), 4, &out)
            }
            out.append(bytes)
            return
        }
        if let data = value as? Data {
            if data.count <= 255 {
                out.append(0xc4)
                out.append(UInt8(data.count))
            } else {
                out.append(0xc5)
                appendBigEndian(UInt64(data.count), 2, &out)
            }
            out.append(data)
            return
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                out.append(number.boolValue ? 0xc3 : 0xc2)
                return
            }
            let double = number.doubleValue
            let integer = number.int64Value
            if double != Double(integer) {
                out.append(0xcb)
                appendBigEndian(double.bitPattern, 8, &out)
            } else if integer >= 0 {
                if integer <= 127 {
                    out.append(UInt8(integer))
                } else if integer <= 255 {
                    out.append(0xcc)
                    out.append(UInt8(integer))
                } else if integer <= 65535 {
                    out.append(0xcd)
                    appendBigEndian(UInt64(integer), 2, &out)
                } else if integer <= 4294967295 {
                    out.append(0xce)
                    appendBigEndian(UInt64(integer), 4, &out)
                } else {
                    out.append(0xcf)
                    appendBigEndian(UInt64(bitPattern: integer), 8, &out)
                }
            } else if integer >= -32 {
                out.append(UInt8(bitPattern: Int8(integer)))
            } else if integer >= Int8.min {
                out.append(0xd0)
                out.append(UInt8(bitPattern: Int8(integer)))
            } else if integer >= Int16.min {
                out.append(0xd1)
                appendBigEndian(UInt64(bitPattern: Int64(Int16(integer))), 2, &out)
            } else if integer >= Int32.min {
                out.append(0xd2)
                appendBigEndian(UInt64(bitPattern: Int64(Int32(integer))), 4, &out)
            } else {
                out.append(0xd3)
                appendBigEndian(UInt64(bitPattern: integer), 8, &out)
            }
            return
        }
        if let list = value as? [Any] {
            if list.count <= 15 {
                out.append(0x90 | UInt8(list.count))
            } else if list.count <= 65535 {
                out.append(0xdc)
                appendBigEndian(UInt64(list.count), 2, &out)
            } else {
                out.append(0xdd)
                appendBigEndian(UInt64(list.count), 4, &out)
            }
            for item in list { msgpackAppend(item, &out) }
            return
        }
        if let dict = value as? [String: Any] {
            if dict.count <= 15 {
                out.append(0x80 | UInt8(dict.count))
            } else if dict.count <= 65535 {
                out.append(0xde)
                appendBigEndian(UInt64(dict.count), 2, &out)
            } else {
                out.append(0xdf)
                appendBigEndian(UInt64(dict.count), 4, &out)
            }
            for (key, item) in dict {
                msgpackAppend(key, &out)
                msgpackAppend(item, &out)
            }
            return
        }
        msgpackAppend(String(describing: value), &out)
    }

    private static func msgpackRender(_ data: Data) -> String {
        let p = [UInt8](data)
        var index = 0
        let decoded = msgpackValue(p, &index, p.count, 0)
        return jsonString(decoded ?? "(null)")
    }

    private static func readBigEndian(_ p: [UInt8], _ index: inout Int, _ count: Int, _ n: Int) -> UInt64? {
        if index + count > n { index = n; return nil }
        var value: UInt64 = 0
        for _ in 0..<count {
            value = (value << 8) | UInt64(p[index])
            index += 1
        }
        return value
    }

    private static func msgpackValue(_ p: [UInt8], _ index: inout Int, _ n: Int, _ depth: Int) -> Any? {
        if depth > 200 || index >= n { return nil }
        let tag = p[index]
        index += 1
        if tag <= 0x7f { return NSNumber(value: tag) }
        if tag >= 0xe0 { return NSNumber(value: Int8(bitPattern: tag)) }
        if (tag & 0xf0) == 0x80 {
            let count = Int(tag & 0x0f)
            var dict: [String: Any] = [:]
            for _ in 0..<count {
                guard let key = msgpackValue(p, &index, n, depth + 1),
                      let item = msgpackValue(p, &index, n, depth + 1) else { return nil }
                dict[msgpackKey(key)] = item
            }
            return dict
        }
        if (tag & 0xf0) == 0x90 {
            let count = Int(tag & 0x0f)
            var list: [Any] = []
            for _ in 0..<count {
                guard let item = msgpackValue(p, &index, n, depth + 1) else { return nil }
                list.append(item)
            }
            return list
        }
        if (tag & 0xe0) == 0xa0 {
            return msgpackString(p, &index, Int(tag & 0x1f), n)
        }
        switch tag {
        case 0xc0: return NSNull()
        case 0xc2: return NSNumber(value: false)
        case 0xc3: return NSNumber(value: true)
        case 0xc4:
            guard let length = readBigEndian(p, &index, 1, n) else { return nil }
            return msgpackBytes(p, &index, Int(length), n)
        case 0xc5:
            guard let length = readBigEndian(p, &index, 2, n) else { return nil }
            return msgpackBytes(p, &index, Int(length), n)
        case 0xc6:
            guard let length = readBigEndian(p, &index, 4, n) else { return nil }
            return msgpackBytes(p, &index, Int(length), n)
        case 0xca:
            guard let bits = readBigEndian(p, &index, 4, n) else { return nil }
            return NSNumber(value: Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 0xcb:
            guard let bits = readBigEndian(p, &index, 8, n) else { return nil }
            return NSNumber(value: Double(bitPattern: bits))
        case 0xcc, 0xcd, 0xce, 0xcf:
            let count = tag == 0xcc ? 1 : (tag == 0xcd ? 2 : (tag == 0xce ? 4 : 8))
            guard let value = readBigEndian(p, &index, count, n) else { return nil }
            return NSNumber(value: value)
        case 0xd0:
            guard let value = readBigEndian(p, &index, 1, n) else { return nil }
            return NSNumber(value: Int8(bitPattern: UInt8(truncatingIfNeeded: value)))
        case 0xd1:
            guard let value = readBigEndian(p, &index, 2, n) else { return nil }
            return NSNumber(value: Int16(bitPattern: UInt16(truncatingIfNeeded: value)))
        case 0xd2:
            guard let value = readBigEndian(p, &index, 4, n) else { return nil }
            return NSNumber(value: Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
        case 0xd3:
            guard let value = readBigEndian(p, &index, 8, n) else { return nil }
            return NSNumber(value: Int64(bitPattern: value))
        case 0xd9:
            guard let length = readBigEndian(p, &index, 1, n) else { return nil }
            return msgpackString(p, &index, Int(length), n)
        case 0xda:
            guard let length = readBigEndian(p, &index, 2, n) else { return nil }
            return msgpackString(p, &index, Int(length), n)
        case 0xdb:
            guard let length = readBigEndian(p, &index, 4, n) else { return nil }
            return msgpackString(p, &index, Int(length), n)
        case 0xdc, 0xdd:
            let countBytes = tag == 0xdc ? 2 : 4
            guard let length = readBigEndian(p, &index, countBytes, n) else { return nil }
            var list: [Any] = []
            for _ in 0..<Int(length) {
                guard let item = msgpackValue(p, &index, n, depth + 1) else { return nil }
                list.append(item)
            }
            return list
        case 0xde, 0xdf:
            let countBytes = tag == 0xde ? 2 : 4
            guard let length = readBigEndian(p, &index, countBytes, n) else { return nil }
            var dict: [String: Any] = [:]
            for _ in 0..<Int(length) {
                guard let key = msgpackValue(p, &index, n, depth + 1),
                      let item = msgpackValue(p, &index, n, depth + 1) else { return nil }
                dict[msgpackKey(key)] = item
            }
            return dict
        default:
            return String(format: "<msgpack tag 0x%02x>", tag)
        }
    }

    private static func msgpackKey(_ key: Any) -> String {
        if let text = key as? String { return text }
        if let number = key as? NSNumber { return number.description }
        return String(describing: key)
    }

    private static func msgpackString(_ p: [UInt8], _ index: inout Int, _ length: Int, _ n: Int) -> Any? {
        guard index + length <= n else { index = n; return nil }
        let slice = Data(p[index..<(index + length)])
        index += length
        return String(data: slice, encoding: .utf8) ?? slice
    }

    private static func msgpackBytes(_ p: [UInt8], _ index: inout Int, _ length: Int, _ n: Int) -> Any? {
        guard length <= n - index else { index = n; return nil }
        let slice = Data(p[index..<(index + length)])
        index += length
        return slice
    }

    // MARK: - PHP serialize

    private static func phpRender(_ data: Data) -> String {
        let p = [UInt8](data)
        var index = 0
        let decoded = phpParse(p, &index, p.count, 0)
        return decoded.map { jsonString($0) } ?? ""
    }

    /// Mirrors the ObjC `%@` key formatting: arrays are presented as a map whose
    /// keys are the stringified PHP keys (0, 1, ... or "<null>").
    private static func phpStringify(_ key: Any) -> String {
        if let text = key as? String { return text }
        if key is NSNull { return "<null>" }
        if let number = key as? NSNumber { return number.stringValue }
        return String(describing: key)
    }

    private static func phpReadUntil(_ p: [UInt8], _ index: inout Int, _ n: Int, _ delimiter: UInt8) -> Int? {
        var value = 0
        var found = false
        while index < n {
            let c = p[index]
            index += 1
            if c == delimiter {
                found = true
                break
            }
            if c < UInt8(ascii: "0") || c > UInt8(ascii: "9") { return nil }
            value = value * 10 + Int(c - UInt8(ascii: "0"))
        }
        return found ? value : nil
    }

    private static func phpParse(_ p: [UInt8], _ index: inout Int, _ n: Int, _ depth: Int) -> Any? {
        if depth > 20 || index >= n { return nil }
        let tag = p[index]
        index += 1
        switch tag {
        case UInt8(ascii: "N"):                      // N;
            if index < n { index += 1 }
            return NSNull()
        case UInt8(ascii: "b"):                      // b:0;
            if index < n && p[index] == UInt8(ascii: ":") { index += 1 }
            let value = index < n && p[index] == UInt8(ascii: "1")
            if index < n { index += 1 }
            if index < n && p[index] == UInt8(ascii: ";") { index += 1 }
            return NSNumber(value: value)
        case UInt8(ascii: "i"):                      // i:123;
            if index < n && p[index] == UInt8(ascii: ":") { index += 1 }
            var negative = false
            if index < n && p[index] == UInt8(ascii: "-") { negative = true; index += 1 }
            guard let value = phpReadUntil(p, &index, n, UInt8(ascii: ";")) else { return nil }
            return NSNumber(value: negative ? -value : value)
        case UInt8(ascii: "d"):                      // d:1.5;
            if index < n && p[index] == UInt8(ascii: ":") { index += 1 }
            var text = ""
            while index < n && p[index] != UInt8(ascii: ";") {
                text += String(UnicodeScalar(p[index]))
                index += 1
            }
            if index < n { index += 1 }
            return NSNumber(value: Double(text) ?? 0)
        case UInt8(ascii: "s"):                      // s:5:"hello";
            if index < n && p[index] == UInt8(ascii: ":") { index += 1 }
            guard let length = phpReadUntil(p, &index, n, UInt8(ascii: ":")) else { return nil }
            if index < n && p[index] == UInt8(ascii: "\"") { index += 1 }
            guard length <= n - index else { return nil }
            let slice = Data(p[index..<(index + length)])
            index += length
            if index < n && p[index] == UInt8(ascii: "\"") { index += 1 }
            if index < n && p[index] == UInt8(ascii: ";") { index += 1 }
            return String(data: slice, encoding: .utf8) ?? ""
        case UInt8(ascii: "a"):                      // a:2:{...}
            if index < n && p[index] == UInt8(ascii: ":") { index += 1 }
            guard let count = phpReadUntil(p, &index, n, UInt8(ascii: ":")) else { return nil }
            if index < n && p[index] == UInt8(ascii: "{") { index += 1 }
            var dict: [String: Any] = [:]
            for _ in 0..<count {
                guard let key = phpParse(p, &index, n, depth + 1),
                      let value = phpParse(p, &index, n, depth + 1) else { return nil }
                dict[phpStringify(key)] = value
            }
            if index < n && p[index] == UInt8(ascii: "}") { index += 1 }
            return dict
        default:
            return nil
        }
    }

    private static func phpSerializeObject(_ value: Any, _ out: inout String) {
        if value is NSNull {
            out += "N;"
            return
        }
        if let text = value as? String {
            let bytes = text.data(using: .utf8) ?? Data()
            out += "s:\(bytes.count):\"\(text)\";"
            return
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                out += "b:\(number.boolValue ? 1 : 0);"
                return
            }
            let double = number.doubleValue
            let integer = number.int64Value
            if double != Double(integer) {
                out += "d:\(double);"
            } else {
                out += "i:\(integer);"
            }
            return
        }
        if let list = value as? [Any] {
            out += "a:\(list.count):{"
            for (index, item) in list.enumerated() {
                out += "i:\(index);"
                phpSerializeObject(item, &out)
            }
            out += "}"
            return
        }
        if let dict = value as? [String: Any] {
            out += "a:\(dict.count):{"
            for (key, item) in dict {
                out += "s:\((key.data(using: .utf8) ?? Data()).count):\"\(key)\";"
                phpSerializeObject(item, &out)
            }
            out += "}"
            return
        }
        out += "N;"
    }

    // MARK: - zlib

    private static func inflate(_ data: Data, windowBits: Int32) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION,
                             Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        return data.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)
            while true {
                var status: Int32 = Z_OK
                var produced = 0
                buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(out.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    produced = out.count - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                if status == Z_STREAM_END { break }
                if status != Z_OK { return nil }
                if stream.avail_in == 0 && produced == 0 { break }
            }
            return output
        }
    }

    private static func deflate(_ data: Data, windowBits: Int32) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8,
                            Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        return data.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)
            while true {
                var status: Int32 = Z_OK
                var produced = 0
                buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(out.count)
                    status = zlib.deflate(&stream, Z_FINISH)
                    produced = out.count - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                if status == Z_STREAM_END { break }
                if status != Z_OK { return nil }
            }
            return output
        }
    }

    // MARK: - Brotli (system CLI)

    private static func brotli(_ data: Data, decode: Bool) -> Data? {
        let fm = FileManager.default
        let input = (NSTemporaryDirectory() as NSString).appendingPathComponent("ardm_br_in")
        do {
            try data.write(to: URL(fileURLWithPath: input))
        } catch {
            return nil
        }
        defer { try? fm.removeItem(atPath: input) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = decode ? ["brotli", "-d", "-c", input] : ["brotli", "-c", input]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 { return nil }
        return output.isEmpty ? nil : output
    }
}
