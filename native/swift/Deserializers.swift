import Foundation

// Binary deserializers moved out of Services.m: Java Object Serialization,
// Python Pickle, and the protobuf wire codec (JSON <-> wire). They are pure
// functions driven by ARDMFormatters.

// MARK: - Java Object Serialization

final class ARDMJavaClassDesc {
    let name: String
    let fields: [[String: String]]
    var superDesc: ARDMJavaClassDesc?

    init(name: String, fields: [[String: String]], superDesc: ARDMJavaClassDesc? = nil) {
        self.name = name
        self.fields = fields
        self.superDesc = superDesc
    }
}

final class ARDMJavaReader {
    private let bytes: [UInt8]
    private(set) var off = 0
    private var handles: [Any] = []

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    private var count: Int { bytes.count }

    private func hasBytes(_ n: Int) -> Bool { off + n <= count }

    private func u8() -> UInt8 {
        if off >= count { off = count; return 0 }
        defer { off += 1 }
        return bytes[off]
    }

    private func u16() -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<2 { value = (value << 8) | UInt16(u8()) }
        return value
    }

    private func u32() -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(u8()) }
        return value
    }

    private func u64() -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 { value = (value << 8) | UInt64(u8()) }
        return value
    }

    private func skip(_ n: Int) {
        off = min(count, off + n)
    }

    private func utf() -> String {
        if !hasBytes(2) { return "" }
        let length = Int(u16())
        if !hasBytes(length) { off = count; return "" }
        let slice = Data(bytes[off..<(off + length)])
        off += length
        return String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .isoLatin1)
            ?? ""
    }

    private func addHandle(_ value: Any?) {
        if handles.count < 10000 { handles.append(value ?? NSNull()) }
    }

    func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.description }
        if let desc = value as? ARDMJavaClassDesc { return desc.name }
        return String(describing: value)
    }

    private func skipAnnotations() {
        while off < count {
            if bytes[off] == 0x78 { off += 1; return }
            let before = off
            _ = readContent(0)
            if off <= before { break }
        }
    }

    func readClassDesc(_ depth: Int) -> ARDMJavaClassDesc? {
        if depth > 40 { return nil }
        let token = u8()
        if token == 0x70 { return nil }          // TC_NULL
        if token == 0x71 {                       // TC_REFERENCE
            let handle = Int(u32())
            if handle < handles.count, let target = handles[handle] as? ARDMJavaClassDesc {
                return target
            }
            return nil
        }
        if token == 0x7D {                       // TC_PROXYCLASSDESC
            let fieldCount = Int(u32())
            for _ in 0..<fieldCount { _ = utf() }
            let desc = ARDMJavaClassDesc(name: "<proxy>", fields: [])
            addHandle(desc)
            skipAnnotations()
            desc.superDesc = readClassDesc(depth + 1)
            return desc
        }
        if token != 0x72 { return nil }          // TC_CLASSDESC
        let name = utf()
        skip(8)                                   // serialVersionUID
        _ = u8()                                  // flags
        let fieldCount = Int(u16())
        var fields: [[String: String]] = []
        for _ in 0..<fieldCount {
            let typeByte = u8()
            let type = String(UnicodeScalar(typeByte))
            let fieldName = utf()
            if typeByte == UInt8(ascii: "L") || typeByte == UInt8(ascii: "[") {
                _ = readContent(depth + 1)
            }
            fields.append(["type": type, "name": fieldName])
        }
        skipAnnotations()
        let desc = ARDMJavaClassDesc(name: name, fields: fields)
        addHandle(desc)                           // classDesc handle precedes its super descriptor
        desc.superDesc = readClassDesc(depth + 1)
        return desc
    }

    private func readFieldValue(_ type: String, depth: Int) -> Any? {
        let c = type.first ?? "L"
        switch c {
        case "B": return NSNumber(value: Int8(bitPattern: u8()))
        case "C": return String(UnicodeScalar(u16()) ?? " ")
        case "S": return NSNumber(value: Int16(bitPattern: u16()))
        case "I": return NSNumber(value: Int32(bitPattern: u32()))
        case "J": return NSNumber(value: Int64(bitPattern: u64()))
        case "F":
            let bits = u32()
            return NSNumber(value: Float(bitPattern: bits))
        case "D":
            let bits = u64()
            return NSNumber(value: Double(bitPattern: bits))
        case "Z": return NSNumber(value: u8() != 0)
        default: return readContent(depth + 1)
        }
    }

    private func readObject(_ depth: Int) -> String {
        let desc = readClassDesc(depth)
        let className = desc?.name ?? "object"
        addHandle("<object \(className)>")
        var chain: [ARDMJavaClassDesc] = []
        var cursor = desc
        var guardCount = 0
        while let current = cursor, guardCount < 40 {
            guardCount += 1
            chain.insert(current, at: 0)
            cursor = current.superDesc
        }
        var body = ""
        for classDesc in chain {
            for field in classDesc.fields {
                let value = readFieldValue(field["type"] ?? "L", depth: depth + 1)
                body += "  \(field["name"] ?? "") (field \(field["type"] ?? "")) = \(describe(value))\n"
            }
        }
        return "\(className) {\n\(body)}"
    }

    private func readArray(_ depth: Int) -> String {
        let desc = readClassDesc(depth)
        let name = desc?.name ?? "[?"
        addHandle("<array \(name)>")
        let length = u32()
        let component: Character
        if name.count > 1 {
            component = name[name.index(name.startIndex, offsetBy: 1)]
        } else {
            component = "L"
        }
        let fieldType = (component == "L" || component == "[") ? "L" : String(component)
        var body = ""
        let limit = min(length, 2000)
        var k: UInt32 = 0
        while k < limit {
            let value = readFieldValue(fieldType, depth: depth + 1)
            body += "  [\(k)] = \(describe(value))\n"
            k += 1
        }
        if length > limit { body += "  … \(length - limit) more\n" }
        return "array \(name) (length \(length)) {\n\(body)}"
    }

    private func readEnum(_ depth: Int) -> String {
        let desc = readClassDesc(depth)
        let name = desc?.name ?? "enum"
        addHandle("<enum \(name)>")
        let constant = readContent(depth + 1)
        return "\(name).\(describe(constant))"
    }

    func readContent(_ depth: Int) -> Any? {
        if depth > 60 || off >= count { return "<truncated>" }
        let token = u8()
        switch token {
        case 0x70: return NSNull()
        case 0x71:
            let handle = Int(u32())
            if handle < handles.count { return handles[handle] }
            return "<ref #\(handle)>"
        case 0x74:
            let text = utf()
            addHandle(text)
            return text
        case 0x7C:
            let length = Int(u64())
            let take = min(length, count - off)
            let slice = Data(bytes[off..<(off + take)])
            let text = String(data: slice, encoding: .utf8) ?? "<binary string>"
            off += take
            addHandle(text)
            return text
        case 0x72:
            return readClassDesc(depth) ?? "<classdesc>"
        case 0x73:
            return readObject(depth)
        case 0x75:
            return readArray(depth)
        case 0x76:
            let desc = readClassDesc(depth)
            addHandle(desc)
            return "class \(desc?.name ?? "?")"
        case 0x7E:
            return readEnum(depth)
        case 0x77:
            let length = Int(u8())
            skip(length)
            return "<blockdata \(length)>"
        case 0x7A:
            let length = Int(u32())
            skip(length)
            return "<blockdatalong \(length)>"
        case 0x78: return "<endblockdata>"
        case 0x79: return "<reset>"
        case 0x7B:
            let inner = readContent(depth + 1)
            return "<exception \(describe(inner))>"
        default:
            return String(format: "<unknown tc 0x%02x>", token)
        }
    }

    static func deserialize(_ data: Data) -> String {
        guard data.count >= 4 else { return "<not a Java serialized stream>" }
        let p = [UInt8](data.prefix(4))
        guard p[0] == 0xac, p[1] == 0xed else { return "<not a Java serialized stream>" }
        let reader = ARDMJavaReader(data)
        reader.off = 4
        var output = String(format: "Java Object Serialization Stream (AC ED %02X %02X)\n", p[2], p[3])
        var guardCount = 0
        while reader.off < data.count && guardCount < 5000 {
            let before = reader.off
            let value = reader.readContent(0)
            let line = reader.describe(value)
            if !line.isEmpty && !line.hasPrefix("<endblockdata>") && !line.hasPrefix("<reset>") {
                output += line + "\n"
            }
            if reader.off <= before { break }
            guardCount += 1
        }
        return output
    }
}

// MARK: - Python Pickle

enum ARDMPickle {
    private final class Marker {}

    private static func describe(_ value: Any?, _ depth: Int) -> String {
        if depth > 30 { return "<deep>" }
        guard let value, !(value is NSNull) else { return "None" }
        if let text = value as? String { return "'\(text)'" }
        if let data = value as? Data { return "<bytes \(data.count)>" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "True" : "False"
            }
            return number.description
        }
        if let list = value as? [Any] {
            return "[" + list.map { describe($0, depth + 1) }.joined(separator: ", ") + "]"
        }
        if let dict = value as? NSDictionary {
            var parts: [String] = []
            for key in dict.allKeys {
                parts.append("\(key): \(describe(dict[key], depth + 1))")
            }
            return "{" + parts.joined(separator: ", ") + "}"
        }
        if let set = value as? NSSet {
            var parts: [String] = []
            for item in set { parts.append(describe(item, depth + 1)) }
            return "{" + parts.joined(separator: ", ") + "}"
        }
        return String(describing: value)
    }

    private static func isMarker(_ value: Any?, _ marker: Marker) -> Bool {
        guard let value else { return false }
        return (value as AnyObject) === marker
    }

    static func unpickle(_ data: Data) -> String {
        let p = [UInt8](data)
        let n = p.count
        var i = 0
        var stack: [Any] = []
        var memo: [Int: Any] = [:]
        let marker = Marker()
        var error: String?
        var guardCount = 0

        func readLine() -> String {
            var bytes: [UInt8] = []
            while i < n && p[i] != 0x0A {
                bytes.append(p[i])
                i += 1
            }
            if i < n { i += 1 }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }

        func pop() -> Any? {
            stack.popLast()
        }

        func popToMarker() -> [Any] {
            var items: [Any] = []
            while !stack.isEmpty && !isMarker(stack.last, marker) {
                items.insert(stack.removeLast(), at: 0)
            }
            if !stack.isEmpty { stack.removeLast() }
            return items
        }

        func readLE(_ byteCount: Int) -> UInt64 {
            var value: UInt64 = 0
            var k = byteCount - 1
            while k >= 0 {
                value = (value << 8) | (i + k < n ? UInt64(p[i + k]) : 0)
                k -= 1
            }
            i += byteCount
            return value
        }

        while i < n && guardCount < 2_000_000 {
            guardCount += 1
            let op = p[i]
            i += 1
            switch op {
            case 0x80: i += 1                                   // PROTO
            case 0x95: i += 8                                   // FRAME
            case 0x2E: i = n                                    // STOP
            case 0x28: stack.append(marker)                     // MARK
            case 0x30: if !stack.isEmpty { stack.removeLast() } // POP
            case 0x31:                                          // POP_MARK
                while !stack.isEmpty && !isMarker(stack.last, marker) { stack.removeLast() }
                if !stack.isEmpty { stack.removeLast() }
            case 0x32: stack.append(stack.last ?? NSNull())      // DUP
            case 0x4E: stack.append(NSNull())                    // NONE
            case 0x49:                                           // INT (text)
                let text = readLine()
                if text == "00" { stack.append(NSNumber(value: false)) }
                else if text == "01" { stack.append(NSNumber(value: true)) }
                else { stack.append(NSNumber(value: Int64(text) ?? 0)) }
            case 0x4A:                                           // BININT
                var value: Int32 = 0
                if i + 4 <= n { value = Int32(bitPattern: readUInt32LE(p, i)) }
                i += 4
                stack.append(NSNumber(value: value))
            case 0x4B:                                           // BININT1
                stack.append(NSNumber(value: i < n ? p[i] : 0))
                i += 1
            case 0x4D:                                           // BININT2
                var value: UInt16 = 0
                if i + 2 <= n { value = UInt16(p[i]) | (UInt16(p[i + 1]) << 8) }
                i += 2
                stack.append(NSNumber(value: value))
            case 0x4C:                                           // LONG (text)
                stack.append(NSNumber(value: Int64(readLine()) ?? 0))
            case 0x8A:                                           // LONG1
                let length = i < n ? Int(p[i]) : 0
                i += 1
                stack.append(NSNumber(value: Int64(bitPattern: readLE(length))))
            case 0x8B:                                           // LONG4
                let length = i + 4 <= n ? Int(readUInt32LE(p, i)) : 0
                i += 4
                stack.append(NSNumber(value: Int64(bitPattern: readLE(length))))
            case 0x46:                                           // FLOAT (text)
                stack.append(NSNumber(value: Double(readLine()) ?? 0))
            case 0x47:                                           // BINFLOAT
                var bits: UInt64 = 0
                var k = 0
                while k < 8 && i < n {
                    bits = (bits << 8) | UInt64(p[i])
                    i += 1
                    k += 1
                }
                stack.append(NSNumber(value: Double(bitPattern: bits)))
            case 0x53:                                           // STRING
                if i < n && p[i] == 0x27 { i += 1 }
                var text = readLine()
                if text.hasSuffix("'") { text.removeLast() }
                stack.append(text)
            case 0x56: stack.append(readLine())                  // UNICODE
            case 0x54:                                           // BINSTRING
                let length = i + 4 <= n ? Int(readUInt32LE(p, i)) : 0
                i += 4
                stack.append(decodeUTF8(p, i, length, n))
                i += length
            case 0x55:                                           // SHORT_BINSTRING
                let length = i < n ? Int(p[i]) : 0
                i += 1
                stack.append(decodeUTF8(p, i, length, n))
                i += length
            case 0x42:                                           // BINBYTES
                let length = i + 4 <= n ? Int(readUInt32LE(p, i)) : 0
                i += 4
                stack.append(decodeData(p, i, length, n))
                i += length
            case 0x43:                                           // SHORT_BINBYTES
                let length = i < n ? Int(p[i]) : 0
                i += 1
                stack.append(decodeData(p, i, length, n))
                i += length
            case 0x8C:                                           // SHORT_BINUNICODE
                let length = i < n ? Int(p[i]) : 0
                i += 1
                stack.append(decodeUTF8(p, i, length, n))
                i += length
            case 0x58:                                           // BINUNICODE
                let length = i + 4 <= n ? Int(readUInt32LE(p, i)) : 0
                i += 4
                stack.append(decodeUTF8(p, i, length, n))
                i += length
            case 0x8D:                                           // BINUNICODE8
                let length = i + 8 <= n ? Int(readUInt64LE(p, i)) : 0
                i += 8
                stack.append(decodeUTF8(p, i, length, n))
                i += length
            case 0x29: stack.append([Any]())                     // EMPTY_TUPLE
            case 0x85, 0x86, 0x87, 0x74:                         // TUPLE1/2/3/TUPLE
                if op == 0x74 {
                    stack.append(popToMarker())
                } else {
                    let wanted = op == 0x85 ? 1 : (op == 0x86 ? 2 : 3)
                    var items: [Any] = []
                    var k = 0
                    while k < wanted && !stack.isEmpty {
                        items.insert(stack.removeLast(), at: 0)
                        k += 1
                    }
                    stack.append(items)
                }
            case 0x5D: stack.append(NSMutableArray())            // EMPTY_LIST
            case 0x6C: stack.append(popToMarker())               // LIST
            case 0x61:                                           // APPEND
                let value = pop()
                if let list = stack.last as? NSMutableArray {
                    list.add(value ?? NSNull())
                }
            case 0x65:                                           // APPENDS
                let items = popToMarker()
                if let list = stack.last as? NSMutableArray {
                    list.addObjects(from: items)
                }
            case 0x7D: stack.append(NSMutableDictionary())       // EMPTY_DICT
            case 0x64:                                           // DICT
                let items = popToMarker()
                let dict = NSMutableDictionary()
                var k = 0
                while k + 1 < items.count {
                    dict[String(describing: items[k])] = items[k + 1]
                    k += 2
                }
                stack.append(dict)
            case 0x73:                                           // SETITEM
                let value = pop()
                let key = pop()
                if let dict = stack.last as? NSMutableDictionary {
                    dict[String(describing: key ?? "None")] = value ?? NSNull()
                }
            case 0x75:                                           // SETITEMS
                let items = popToMarker()
                if let dict = stack.last as? NSMutableDictionary {
                    var k = 0
                    while k + 1 < items.count {
                        dict[String(describing: items[k])] = items[k + 1]
                        k += 2
                    }
                }
            case 0x8F: stack.append(NSMutableSet())              // EMPTY_SET
            case 0x90:                                           // ADDITEMS
                let items = popToMarker()
                if let set = stack.last as? NSMutableSet {
                    set.addObjects(from: items)
                }
            case 0x70:                                           // PUT
                var index = 0
                while i < n && p[i] != 0x0A {
                    index = index * 10 + Int(p[i] - 0x30)
                    i += 1
                }
                if i < n { i += 1 }
                memo[index] = stack.last ?? NSNull()
            case 0x71:                                           // BINPUT
                let index = i < n ? Int(p[i]) : 0
                i += 1
                memo[index] = stack.last ?? NSNull()
            case 0x72:                                           // LONG_BINPUT
                let index = i + 4 <= n ? Int(readUInt32LE(p, i)) : 0
                i += 4
                memo[index] = stack.last ?? NSNull()
            case 0x94:                                           // MEMOIZE
                memo[memo.count] = stack.last ?? NSNull()
            case 0x67:                                           // GET
                var index = 0
                while i < n && p[i] != 0x0A {
                    index = index * 10 + Int(p[i] - 0x30)
                    i += 1
                }
                if i < n { i += 1 }
                stack.append(memo[index] ?? NSNull())
            case 0x68:                                           // BINGET
                let index = i < n ? Int(p[i]) : 0
                i += 1
                stack.append(memo[index] ?? NSNull())
            case 0x6A:                                           // LONG_BINGET
                let index = i + 4 <= n ? Int(readUInt32LE(p, i)) : 0
                i += 4
                stack.append(memo[index] ?? NSNull())
            case 0x63:                                           // GLOBAL
                let module = readLine()
                let name = readLine()
                stack.append("\(module).\(name)")
            case 0x93:                                           // STACK_GLOBAL
                let name = pop()
                let module = pop()
                stack.append("\(module ?? "").\(name ?? "")")
            case 0x52:                                           // REDUCE
                let callArgs = pop()
                let callable = pop()
                stack.append("\(stringify(callable))(\(stringify(callArgs)))")
            case 0x62: break                                     // BUILD
            case 0x81:                                           // NEWOBJ
                let callArgs = pop()
                let cls = pop()
                stack.append("\(stringify(cls))(\(stringify(callArgs)))")
            case 0x92:                                           // NEWOBJ_EX
                let kwargs = pop()
                let callArgs = pop()
                let cls = pop()
                stack.append("\(stringify(cls))(\(stringify(callArgs))\(stringify(kwargs)))")
            default:
                error = String(format: "unsupported opcode 0x%02X at %lu", op, UInt(guardCount))
                i = n
            }
        }

        let result: Any = stack.last ?? NSNull()
        var output = "Python Pickle (decoded)\n"
        output += describe(result, 0)
        output += "\n"
        if let error { output += "<stopped: \(error)>\n" }
        return output
    }

    private static func stringify(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "None" }
        if let text = value as? String { return text }
        return String(describing: value)
    }

    private static func decodeUTF8(_ bytes: [UInt8], _ start: Int, _ length: Int, _ n: Int) -> String {
        guard length <= n - start, start >= 0 else { return "" }
        return String(data: Data(bytes[start..<(start + length)]), encoding: .utf8) ?? ""
    }

    private static func decodeData(_ bytes: [UInt8], _ start: Int, _ length: Int, _ n: Int) -> Data {
        guard length <= n - start, start >= 0 else { return Data() }
        return Data(bytes[start..<(start + length)])
    }

    private static func readUInt32LE(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }

    private static func readUInt64LE(_ bytes: [UInt8], _ index: Int) -> UInt64 {
        var value: UInt64 = 0
        for k in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[index + k]) }
        return value
    }
}

// MARK: - Protobuf wire format

enum ARDMProtobuf {
    // Schema entries are "kind|name|childType"; the first two are always present.
    private static func kind(of descriptor: String) -> String {
        let parts = descriptor.components(separatedBy: "|")
        return parts.count >= 2 ? parts[0] : ""
    }

    private static func fieldName(of descriptor: String) -> String {
        let parts = descriptor.components(separatedBy: "|")
        return parts.count >= 2 ? parts[1] : descriptor
    }

    private static func childType(of descriptor: String) -> String? {
        let parts = descriptor.components(separatedBy: "|")
        return parts.count >= 3 ? parts[2] : nil
    }

    private static func readVarint(_ p: [UInt8], _ len: Int, _ offset: inout Int) -> UInt64 {
        var value: UInt64 = 0
        var shift = 0
        while offset < len && shift < 64 {
            let byte = p[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return value
    }

    private static func bytesAreText(_ chunk: Data) -> Bool {
        guard let text = String(data: chunk, encoding: .utf8) else { return false }
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { continue }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
        }
        return true
    }

    /// Decodes one message into a JSON-friendly dictionary. Nested messages recurse
    /// through their own scope; repeated occurrences of a field collapse into arrays.
    static func decodeMessage(_ data: Data,
                              scope: [UInt64: String],
                              depth: Int) -> [String: Any] {
        if depth > 6 { return ["__truncated": "max nesting depth"] }
        var dict: [String: Any] = [:]
        let p = [UInt8](data)
        let len = p.count
        var i = 0
        while i < len {
            let tag = readVarint(p, len, &i)
            let field = tag >> 3
            let wire = tag & 7
            if field == 0 { break }
            let descriptor = scope[field]
            let key = descriptor.map { fieldName(of: $0) } ?? "field_\(field)"
            let fieldKind = descriptor.map { kind(of: $0) } ?? ""
            var value: Any?
            if wire == 0 {
                let number = readVarint(p, len, &i)
                value = fieldKind == "bool" ? NSNumber(value: number != 0) : NSNumber(value: number)
            } else if wire == 2 {
                let length = Int(readVarint(p, len, &i))
                if length < 0 || i + length > len { break }
                let chunk = Data(p[i..<(i + length)])
                i += length
                if fieldKind == "message" {
                    let child = descriptor.flatMap { childType(of: $0) }
                    value = decodeMessage(chunk, scope: scopeFor(child) ?? [:], depth: depth + 1)
                } else if fieldKind == "bytes" {
                    value = ARDMFormatters.hexDump(chunk)
                } else if bytesAreText(chunk) {
                    value = String(data: chunk, encoding: .utf8)
                } else {
                    value = ARDMFormatters.hexDump(chunk)
                }
            } else if wire == 5 {
                if i + 4 > len { break }
                let bits = UInt32(p[i])
                    | (UInt32(p[i + 1]) << 8)
                    | (UInt32(p[i + 2]) << 16)
                    | (UInt32(p[i + 3]) << 24)
                i += 4
                value = fieldKind == "float"
                    ? NSNumber(value: Float(bitPattern: bits))
                    : NSNumber(value: bits)
            } else if wire == 1 {
                if i + 8 > len { break }
                var bits: UInt64 = 0
                for k in (0..<8).reversed() { bits = (bits << 8) | UInt64(p[i + k]) }
                i += 8
                value = fieldKind == "double"
                    ? NSNumber(value: Double(bitPattern: bits))
                    : NSNumber(value: bits)
            } else {
                break   // deprecated group wire types are not supported
            }
            guard let value else { continue }
            if let existing = dict[key] {
                if var list = existing as? [Any] {
                    list.append(value)
                    dict[key] = list
                } else {
                    dict[key] = [existing, value]
                }
            } else {
                dict[key] = value
            }
        }
        return dict
    }

    static var schema: [NSNumber: String]?
    static var scopes: [String: [NSNumber: String]]?
    static var root: String?

    static func scopeFor(_ name: String?) -> [UInt64: String]? {
        guard let name, !name.isEmpty else { return nil }
        let source = scopes ?? [:]
        if let exact = source[name] { return normalized(exact) }
        let suffix = "." + name
        for (key, value) in source where key.hasSuffix(suffix) {
            return normalized(value)
        }
        return nil
    }

    private static func activeScope() -> [UInt64: String] {
        if let rootScope = scopeFor(root) { return rootScope }
        return schema.map { normalized($0) } ?? [:]
    }

    private static func normalized(_ raw: [NSNumber: String]) -> [UInt64: String] {
        var out: [UInt64: String] = [:]
        for (key, value) in raw { out[key.uint64Value] = value }
        return out
    }

    static func dump(_ data: Data) -> String {
        let decoded = decodeMessage(data, scope: activeScope(), depth: 0)
        if decoded.isEmpty { return "<no protobuf fields decoded>" }
        guard JSONSerialization.isValidJSONObject(decoded),
              let json = try? JSONSerialization.data(withJSONObject: decoded,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: json, encoding: .utf8) else {
            return "<no protobuf fields decoded>"
        }
        return text
    }

    // MARK: Encode (JSON -> wire)

    private static func appendVarint(_ out: inout Data, _ value: UInt64) {
        var value = value
        while value >= 0x80 {
            out.append(UInt8((value & 0x7f) | 0x80))
            value >>= 7
        }
        out.append(UInt8(value & 0x7f))
    }

    private static func appendTag(_ out: inout Data, _ field: UInt64, _ wire: UInt64) {
        appendVarint(&out, (field << 3) | wire)
    }

    private static func protoError(_ message: String, _ code: Int) -> NSError {
        NSError(domain: "ARDMProtobuf", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func encodeValue(_ value: Any, kind: String, childType: String?,
                                    field: UInt64, out: inout Data,
                                    error: NSErrorPointer, depth: Int) -> Bool {
        if let list = value as? [Any], kind != "bytes" {
            for item in list {
                if !encodeValue(item, kind: kind, childType: childType, field: field,
                                out: &out, error: error, depth: depth) { return false }
            }
            return true
        }
        if kind == "message" || value is [String: Any] || value is NSDictionary {
            var nested = Data()
            let childScope = scopeFor(childType) ?? [:]
            if !encodeMessage(value, scope: childScope, out: &nested, error: error, depth: depth + 1) {
                return false
            }
            appendTag(&out, field, 2)
            appendVarint(&out, UInt64(nested.count))
            out.append(nested)
            return true
        }
        if let text = value as? String {
            let bytes = text.data(using: .utf8) ?? Data()
            appendTag(&out, field, 2)
            appendVarint(&out, UInt64(bytes.count))
            out.append(bytes)
            return true
        }
        if let number = value as? NSNumber {
            if kind == "float" || kind == "double" {
                if kind == "float" {
                    let bits = number.floatValue.bitPattern
                    appendTag(&out, field, 5)
                    withUnsafeBytes(of: bits.littleEndian) { out.append(contentsOf: $0) }
                } else {
                    let bits = number.doubleValue.bitPattern
                    appendTag(&out, field, 1)
                    withUnsafeBytes(of: bits.littleEndian) { out.append(contentsOf: $0) }
                }
                return true
            }
            appendTag(&out, field, 0)
            appendVarint(&out, UInt64(bitPattern: number.int64Value))
            return true
        }
        if let error {
            error.pointee = protoError("Unsupported protobuf value: \(value)", 40)
        }
        return false
    }

    private static func encodeMessage(_ object: Any, scope: [UInt64: String],
                                      out: inout Data, error: NSErrorPointer,
                                      depth: Int) -> Bool {
        if depth > 6 {
            if let error { error.pointee = protoError("Protobuf nesting is too deep", 41) }
            return false
        }
        guard let dictionary = object as? [String: Any] else {
            if let error { error.pointee = protoError("Protobuf input must be a JSON object", 42) }
            return false
        }
        // Reverse the scope so JSON keys can be matched by field name.
        var byName: [String: UInt64] = [:]
        for (number, descriptor) in scope {
            byName[fieldName(of: descriptor)] = number
        }
        for (key, value) in dictionary {
            var field = byName[key]
            if field == nil, key.hasPrefix("field_") {
                field = UInt64(key.dropFirst(6))
            }
            if field == nil, !key.isEmpty, key.allSatisfy({ $0.isNumber }) {
                field = UInt64(key)
            }
            guard let field, field > 0 else {
                if let error {
                    error.pointee = protoError("Unknown protobuf field: \(key)", 43)
                }
                return false
            }
            let descriptor = scope[field] ?? ""
            if !encodeValue(value, kind: kind(of: descriptor), childType: childType(of: descriptor),
                            field: field, out: &out, error: error, depth: depth) {
                return false
            }
        }
        return true
    }

    /// JSON -> protobuf wire, using the schema loaded for the active message.
    static func encode(_ text: String, error: NSErrorPointer) -> Data? {
        let input = text.data(using: .utf8) ?? Data()
        guard let object = try? JSONSerialization.jsonObject(with: input) else {
            if let error {
                error.pointee = protoError("Protobuf write-back expects a JSON object keyed by field name", 44)
            }
            return nil
        }
        let scope = activeScope()
        var out = Data()
        if !encodeMessage(object, scope: scope, out: &out, error: error, depth: 0) {
            return nil
        }
        return out
    }
}
