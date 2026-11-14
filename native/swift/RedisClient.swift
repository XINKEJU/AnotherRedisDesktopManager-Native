import Foundation
import CoreFoundation
import CFNetwork
import Security
import Darwin

// MARK: - Helpers

private func ARDMError(_ message: String, _ code: Int) -> NSError {
    NSError(domain: "me.qii404.ardm.native", code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
}

/// Take a SecIdentity out of a Security-framework result. `as?` cannot do it:
/// a downcast to a CoreFoundation type is unconditional as far as the compiler
/// is concerned, so an unexpected payload would trap on later use instead of
/// failing here. The CFTypeID is checked first.
private func ARDMSecIdentity(_ value: Any?) -> SecIdentity? {
    guard let value else { return nil }
    let ref = value as CFTypeRef
    guard CFGetTypeID(ref) == SecIdentityGetTypeID() else { return nil }
    return (ref as! SecIdentity)
}

/// Build the kCFStreamSSLCertificates chain for mutual TLS.
/// Supports PKCS#12 (tlsIdentityPath) and a PEM certificate + private key pair.
private func ARDMMutualTLSChain(_ c: ARDMConnectionConfig) -> [Any]? {
    var identity: SecIdentity?
    if !c.tlsIdentityPath.isEmpty,
       let p12 = try? Data(contentsOf: URL(fileURLWithPath: c.tlsIdentityPath)) {
        let options = [kSecImportExportPassphrase as String: c.tlsKey] as CFDictionary
        var items: CFArray?
        if SecPKCS12Import(p12 as CFData, options, &items) == errSecSuccess,
           let array = items as? [[String: Any]],
           let first = array.first {
            identity = ARDMSecIdentity(first[kSecImportItemIdentity as String])
        }
    }
    if identity == nil && !c.tlsCert.isEmpty && !c.tlsKey.isEmpty {
        var pem = Data()
        if let cert = try? Data(contentsOf: URL(fileURLWithPath: c.tlsCert)) { pem.append(cert) }
        if let key = try? Data(contentsOf: URL(fileURLWithPath: c.tlsKey)) { pem.append(key) }
        if !pem.isEmpty {
            var format = SecExternalFormat.formatPEMSequence
            var type = SecExternalItemType.itemTypeAggregate
            var imported: CFArray?
            let status = SecItemImport(pem as CFData, nil, &format, &type, [], nil, nil, &imported)
            if status == errSecSuccess, let array = imported as? [Any] {
                for item in array {
                    if let candidate = ARDMSecIdentity(item) {
                        identity = candidate
                        break
                    }
                }
            }
        }
    }
    guard let identity else { return nil }
    var chain: [Any] = [identity]
    var certificate: SecCertificate?
    if SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate {
        chain.append(certificate)
    }
    return chain
}

func ARDMReplyToString(_ reply: Any?) -> String {
    guard let reply, !(reply is NSNull) else { return "(nil)" }
    if let value = reply as? String { return value }
    if let value = reply as? Data {
        return String(data: value, encoding: .utf8) ?? "<binary \(value.count) bytes>"
    }
    if let value = reply as? NSNumber { return value.stringValue }
    if let value = reply as? [Any] { return value.map { ARDMReplyToString($0) }.joined(separator: "\n") }
    return String(describing: reply)
}

func ARDMNormalizeArray(_ reply: Any?) -> [Any] {
    guard let reply else { return [] }
    if let value = reply as? [Any] { return value }
    if reply is NSNull { return [] }
    return [reply]
}

/// Build the command-line string recorded in the command log.
/// Masks AUTH secrets, drops keepalive PINGs, and truncates over-long args so
/// credentials never leak into the on-screen / persisted log (upstream CommandLog.vue).
private func ARDMCommandLogString(_ args: [Any]) -> String? {
    guard !args.isEmpty else { return "" }
    let first = args[0]
    var verb = (first as? String)?.uppercased() ?? String(describing: first)
    verb = verb.trimmingCharacters(in: .whitespaces)
    if verb == "PING" { return nil }   // keepalive pings must not flood the command log
    var redacted = args
    if verb == "AUTH" {
        if redacted.count >= 2 {
            redacted.replaceSubrange(1..<redacted.count, with: ["***"])
        } else {
            redacted[0] = "AUTH ***"
        }
    }
    for index in redacted.indices {
        let value = redacted[index]
        // Commands carry non-string args too: saveEditorText sends the encoded
        // value as raw Data. Never treat it as a string.
        if let text = value as? String {
            let ns = text as NSString
            if ns.length > 200 {
                redacted[index] = ns.substring(to: 200) + "…(truncated)"
            }
        } else if let data = value as? Data {
            redacted[index] = "<\(data.count) bytes>"
        } else if !(value is NSNull) {
            var description = String(describing: value)
            let ns = description as NSString
            if ns.length > 200 { description = ns.substring(to: 200) + "…(truncated)" }
            redacted[index] = description
        }
    }
    return redacted.map { value -> String in
        if let text = value as? String { return text }
        return String(describing: value)
    }.joined(separator: " ")
}

private func ARDMEncodeCommand(_ args: [Any]) -> Data {
    var out = Data()
    out.append(Data("*\(args.count)\r\n".utf8))
    for arg in args {
        let payload: Data
        if let data = arg as? Data {
            payload = data
        } else if let text = arg as? String {
            payload = Data(text.utf8)
        } else if let number = arg as? NSNumber {
            payload = Data(number.stringValue.utf8)
        } else {
            payload = Data(String(describing: arg).utf8)
        }
        out.append(Data("$\(payload.count)\r\n".utf8))
        out.append(payload)
        out.append(Data("\r\n".utf8))
    }
    return out
}

// MARK: - RESP stream reader

private final class ARDMRESPStream {

    private var readStream: CFReadStream
    private var writeStream: CFWriteStream
    private var buffer = Data()

    init(read: CFReadStream, write: CFWriteStream) {
        readStream = read
        writeStream = write
    }

    private func fillBuffer() throws {
        var chunk = [UInt8](repeating: 0, count: 8192)
        let capacity = chunk.count
        let count = chunk.withUnsafeMutableBytes { raw -> CFIndex in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return CFReadStreamRead(readStream, base, capacity)
        }
        if count > 0 {
            buffer.append(contentsOf: chunk[0..<count])
            return
        }
        throw ARDMError("Connection closed by Redis server", 2)
    }

    private func crlfIndex() -> Int? {
        let length = buffer.count
        return buffer.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index + 1 < length {
                if bytes[index] == 13 && bytes[index + 1] == 10 { return index }
                index += 1
            }
            return nil
        }
    }

    private func readLine() throws -> Data {
        var found = crlfIndex()
        while found == nil {
            try fillBuffer()
            found = crlfIndex()
        }
        let index = found!
        let line = buffer.prefix(index)
        buffer.removeFirst(index + 2)
        return Data(line)
    }

    private func readExactly(_ count: Int) throws -> Data {
        while buffer.count < count { try fillBuffer() }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw ARDMError("Failed to write to Redis", 4)
            }
            var offset = 0
            while offset < data.count {
                let written = CFWriteStreamWrite(writeStream, base + offset, CFIndex(data.count - offset))
                if written <= 0 { throw ARDMError("Failed to write to Redis", 4) }
                offset += written
            }
        }
    }

    func readReply() throws -> Any {
        let line = try readLine()
        guard let kind = line.first else { return "" }
        let body = String(data: line.dropFirst(), encoding: .utf8) ?? ""
        switch kind {
        case UInt8(ascii: "+"):
            return body
        case UInt8(ascii: "-"):
            throw ARDMError(body, 3)
        case UInt8(ascii: ":"):
            // Redis integer replies are signed 64-bit. Beyond INT64 bounds keep the
            // verbatim decimal string so the value survives without precision loss.
            if let value = Int64(body) { return NSNumber(value: value) }
            return body
        case UInt8(ascii: "$"):
            let length = Int(body) ?? 0
            if length < 0 { return NSNull() }
            let bulk = try readExactly(length)
            _ = try? readExactly(2)
            return bulk
        case UInt8(ascii: "*"):
            let count = Int(body) ?? 0
            if count < 0 { return NSNull() }
            var array: [Any] = []
            array.reserveCapacity(count)
            for _ in 0..<count { array.append(try readReply()) }
            return array
        case UInt8(ascii: "#"):
            return NSNumber(value: body == "t")
        case UInt8(ascii: ","):
            return NSNumber(value: Double(body) ?? 0)
        case UInt8(ascii: "_"):
            return NSNull()
        case UInt8(ascii: "("):
            return body
        case UInt8(ascii: "%"), UInt8(ascii: "~"), UInt8(ascii: ">"):
            let count = Int(body) ?? 0
            let total = count * (kind == UInt8(ascii: "%") ? 2 : 1)
            var array: [Any] = []
            for _ in 0..<total { array.append(try readReply()) }
            return array
        default:
            return body
        }
    }

    func close() {
        CFReadStreamClose(readStream)
        CFWriteStreamClose(writeStream)
    }
}

// MARK: - Key type

enum ARDMKeyType: UInt {
    case string = 0
    case list
    case set
    case zSet
    case hash
    case stream
    case reJSON
    case timeSeries
    case vector
    case array
    case unknown
}

// MARK: - Command log

final class ARDMCommandLog {
    var time = Date()
    var connectionName = ""
    var command = ""
    var cost: TimeInterval = 0
}

// MARK: - Redis client

final class ARDMRedisClient {

    private let config: ARDMConnectionConfig
    private var stream: ARDMRESPStream?
    private let queue = DispatchQueue(label: "me.qii404.ardm.redis")
    /// Recursive so nested send() calls from ASK/MOVED and MULTI/EXEC re-enter
    /// instead of deadlocking (the ObjC version used @synchronized(self)).
    private let lock = NSRecursiveLock()
    private var sshTask: Process?
    private var connectHost: String?
    private var connectPort = 0
    private var effectiveAuth = ""
    private var didRetry = false
    private var liveClient: ARDMRedisClient?
    private var liveQueue: DispatchQueue?
    private var liveRunningFlag = false
    private let logLimit = 5000

    private(set) var isConnected = false
    private(set) var logs: [ARDMCommandLog] = []
    var onLog: ((ARDMCommandLog) -> Void)?
    var selectedDB = 0

    init(config: ARDMConnectionConfig) {
        self.config = config
    }

    var hostUsed: String { connectHost ?? config.host }
    var portUsed: Int { connectPort != 0 ? connectPort : config.port }
    var liveRunning: Bool { liveRunningFlag }

    // MARK: Write-command classification

    private static let writeCommands: Set<String> = [
        "SET", "SETNX", "SETEX", "PSETEX", "MSET", "MSETNX", "GETSET", "APPEND", "INCR", "DECR", "INCRBY", "DECRBY",
        "INCRBYFLOAT", "DECRBYFLOAT", "COPY", "DEL", "UNLINK", "EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT", "PERSIST",
        "EXPIRETIME", "PEXPIRETIME", "RENAME", "RENAMENX", "MOVE", "SWAPDB", "RESTORE", "RESTORE-ASKING", "DUMP",
        "MIGRATE", "OBJECT", "SORT", "LMOVE", "BLMOVE", "RPOPLPUSH",
        "HSET", "HSETNX", "HMSET", "HDEL", "HINCRBY", "HINCRBYFLOAT", "HPEXPIRE", "HPEXPIREAT", "HEXPIRE", "HEXPIREAT",
        "HPERSIST", "HRANDFIELD",
        "LPUSH", "RPUSH", "LPUSHX", "RPUSHX", "LPOP", "RPOP", "LSET", "LREM", "LTRIM", "LINSERT",
        "SADD", "SREM", "SPOP", "SMOVE", "SINTERSTORE", "SUNIONSTORE", "SDIFFSTORE",
        "ZADD", "ZREM", "ZINCRBY", "ZINTERSTORE", "ZUNIONSTORE", "ZDIFFSTORE", "ZPOPMIN", "ZPOPMAX", "BZPOPMIN",
        "BZPOPMAX", "ZRANGESTORE",
        "XADD", "XDEL", "XTRIM", "XGROUP", "XACK", "XCLAIM", "XAUTOCLAIM", "XGROUP DESTROY", "XGROUP CREATE",
        "JSON.SET", "JSON.DEL", "JSON.MSET", "JSON.MERGE", "JSON.NUMINCRBY", "JSON.STRAPPEND", "JSON.ARRAPPEND",
        "JSON.ARRPOP", "JSON.ARRINSERT", "JSON.ARRTRIM", "JSON.CLEAR", "JSON.FORGET",
        "TS.ADD", "TS.CREATE", "TS.DEL", "TS.ALTER", "TS.INCRBY", "TS.DECRBY", "TS.CREATERULE", "TS.DELETERULE",
        "VADD", "VREM", "VSETATTR", "SETATTR", "ARSET", "ARDEL", "ARINSERT", "ARAPPEND", "ARPOP", "ARTRIM",
        "SETBIT", "SETRANGE", "BITFIELD", "GEOADD", "GEOSEARCHSTORE", "PFADD", "PFMERGE",
        "EVAL", "EVALSHA", "SCRIPT", "FUNCTION", "DEBUG", "MODULE", "REPLICAOF", "SLAVEOF", "ACL",
        "CONFIG SET", "CONFIG REWRITE", "CONFIG RESETSTAT", "SHUTDOWN", "FLUSHDB", "FLUSHALL", "SAVE", "BGSAVE",
        "CLIENT KILL", "CLIENT SETNAME", "CLIENT SETINFO", "CLIENT PAUSE", "CLIENT UNPAUSE", "CLIENT UNBLOCK", "SCRIPT FLUSH",
        "FAILOVER", "FAILOVER AUTH",
        "CLUSTER ADDSLOTS", "CLUSTER DELSLOTS", "CLUSTER SETSLOT", "CLUSTER MEET", "CLUSTER FORGET",
        "CLUSTER REPLICATE", "CLUSTER RESET", "CLUSTER SAVECONFIG", "CLUSTER BUMPEPOCH", "CLUSTER MYID",
        "SCHEDULE", "LATENCY", "SWAPDB",
        "PUBLISH", "SPUBLISH", "MULTI", "EXEC", "DISCARD", "WATCH", "UNWATCH",
        "FT.CREATE", "FT.ADD", "FT.ALTER", "FT.DROPINDEX", "FT.ALIASADD", "FT.ALIASDEL", "FT.ALIASUPDATE",
        "FT.DICTADD", "FT.DICTDEL", "FT.SYNUPDATE", "FT.SYNDFUPDATE",
    ]

    private func commandVerb(_ args: [Any]) -> String {
        guard let first = args.first else { return "" }
        let text = (first as? String)?.uppercased() ?? String(describing: first)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func twoTokenVerb(_ args: [Any]) -> String {
        guard args.count >= 2 else { return commandVerb(args) }
        let first = args[0] as? String ?? String(describing: args[0])
        let second = args[1] as? String ?? String(describing: args[1])
        return "\(first) \(second)".uppercased()
    }

    func isWriteCommand(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        let verb = first.uppercased().trimmingCharacters(in: .whitespaces)
        let two = args.count >= 2 ? "\(args[0]) \(args[1])".uppercased() : verb
        return ARDMRedisClient.writeCommands.contains(verb) || ARDMRedisClient.writeCommands.contains(two)
    }

    // MARK: Connection lifecycle

    func connect() throws {
        disconnect()
        connectHost = config.host
        connectPort = config.port
        effectiveAuth = config.auth
        if config.sshEnabled { try openSSHTunnel() }

        stream = try makeStream(host: connectHost ?? config.host, port: connectPort)
        isConnected = true

        if config.sentinelEnabled {
            let reply = ARDMNormalizeArray(sendImpl(["SENTINEL", "get-master-addr-by-name", config.sentinelMaster], error: nil))
            if reply.count >= 2 {
                let master = ARDMReplyToString(reply[0])
                let masterPort = Int(ARDMReplyToString(reply[1])) ?? 0
                effectiveAuth = config.sentinelNodePassword.isEmpty ? config.auth : config.sentinelNodePassword
                stream?.close()
                stream = nil
                if let newStream = try? makeStream(host: master, port: masterPort) {
                    stream = newStream
                }
                connectHost = master
                connectPort = masterPort
            }
        }

        if !effectiveAuth.isEmpty {
            var authError: NSError?
            _ = sendImpl(authArguments(), error: &authError)
            if let authError {
                disconnect()
                throw authError
            }
        }
        if !config.connectionName.isEmpty {
            _ = sendImpl(["CLIENT", "SETNAME", config.connectionName], error: nil)
        }
        if config.db > 0 {
            _ = sendImpl(["SELECT", "\(config.db)"], error: nil)
        }
        selectedDB = config.db
        var pingError: NSError?
        _ = sendImpl(["PING"], error: &pingError)
        if let pingError {
            disconnect()
            throw pingError
        }
    }

    func disconnect() {
        stream?.close()
        stream = nil
        isConnected = false
        if let sshTask {
            sshTask.terminate()
            self.sshTask = nil
        }
    }

    private func authArguments() -> [Any] {
        config.username.isEmpty ? ["AUTH", effectiveAuth] : ["AUTH", config.username, effectiveAuth]
    }

    private func makeStream(host: String, port: Int) throws -> ARDMRESPStream {
        var readRef: Unmanaged<CFReadStream>?
        var writeRef: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, host as CFString, UInt32(port), &readRef, &writeRef)
        guard let readRef, let writeRef else {
            throw ARDMError("Cannot create network stream", 8)
        }
        let read = readRef.takeRetainedValue()
        let write = writeRef.takeRetainedValue()
        if config.tlsEnabled { configureTLS(read: read, write: write) }
        guard CFReadStreamOpen(read), CFWriteStreamOpen(write) else {
            CFReadStreamClose(read)
            CFWriteStreamClose(write)
            throw ARDMError("Cannot open connection to Redis", 9)
        }
        return ARDMRESPStream(read: read, write: write)
    }

    /// Apply TLS settings, including a client identity chain for mutual TLS.
    /// By default the certificate chain is validated. Only when the connection is
    /// explicitly marked insecure (rejectUnauthorized=false) is validation relaxed.
    private func configureTLS(read: CFReadStream, write: CFWriteStream) {
        let insecure = config.tlsInsecure
        var ssl: [String: Any] = [
            "kCFStreamSSLLevel": kCFStreamSocketSecurityLevelNegotiatedSSL,
            "kCFStreamSSLValidatesCertificateChain": !insecure,
        ]
        if !config.tlsSNI.isEmpty { ssl["kCFStreamSSLPeerName"] = config.tlsSNI }
        if insecure { ssl["kCFStreamSSLAllowsAnyRoot"] = true }
        // Build the certificate chain: mutual-TLS identity (if any) plus an optional CA.
        var chain = ARDMMutualTLSChain(config) ?? []
        if !config.tlsCA.isEmpty,
           let ca = try? Data(contentsOf: URL(fileURLWithPath: config.tlsCA)),
           let certificate = SecCertificateCreateWithData(nil, ca as CFData) {
            chain.append(certificate)
        }
        if !chain.isEmpty { ssl["kCFStreamSSLCertificates"] = chain }
        let settings = ssl as CFDictionary
        let key = CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings)
        CFReadStreamSetProperty(read, key, settings)
        CFWriteStreamSetProperty(write, key, settings)
    }

    /// Translate a cluster-internal address through the configured NAT map.
    private func mappedAddress(host: String, port: Int) -> String {
        let key = "\(host):\(port)"
        return config.natMap[key] ?? key
    }

    /// Reconnect with linear backoff (300ms * attempt), up to `retryTimes` attempts (default 3).
    func reconnectWithBackoff() throws {
        guard config.autoReconnect else { throw ARDMError("Auto reconnect disabled", 12) }
        let attempts = config.retryTimes > 0 ? config.retryTimes : 3
        var last: NSError?
        for attempt in 1...attempts {
            usleep(useconds_t(300000 * attempt))
            last = nil
            do {
                try connect()
                return
            } catch let error as NSError {
                last = error
            }
        }
        throw last ?? ARDMError("Reconnect failed", 13)
    }

    // MARK: Sending

    func send(_ args: [String], error: NSErrorPointer) -> Any {
        sendImpl(args as [Any], error: error) ?? NSNull()
    }

    func sendArguments(_ args: [Any], error: NSErrorPointer) -> Any {
        sendImpl(args, error: error) ?? NSNull()
    }

    func asyncSend(_ args: [String], completion: @escaping (Any, NSError?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var error: NSError?
            let reply = self.send(args, error: &error)
            DispatchQueue.main.async { completion(reply, error) }
        }
    }

    private func sendImpl(_ args: [Any], error: NSErrorPointer) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else {
            error?.pointee = ARDMError("Not connected", 10)
            return nil
        }
        let verb = commandVerb(args)
        let two = twoTokenVerb(args)
        if config.readOnly &&
            (ARDMRedisClient.writeCommands.contains(verb) || ARDMRedisClient.writeCommands.contains(two)) {
            error?.pointee = ARDMError("You are in readonly mode! Unable to execute write command!", 11)
            return nil
        }
        let start = Date()
        do {
            try stream.write(ARDMEncodeCommand(args))
        } catch let writeError as NSError {
            error?.pointee = writeError
            return nil
        }
        do {
            let reply = try stream.readReply()
            if let logged = ARDMCommandLogString(args) {
                let log = ARDMCommandLog()
                log.time = Date()
                log.connectionName = config.name
                log.command = logged
                log.cost = Date().timeIntervalSince(start) * 1000.0
                logs.append(log)
                if logs.count > logLimit { logs.removeFirst(logs.count - logLimit) }
                onLog?(log)
            }
            return reply
        } catch let readError as NSError {
            let message = readError.localizedDescription
            if message.hasPrefix("MOVED ") || message.hasPrefix("ASK ") {
                let redirect = handleRedirect(message: message, args: args, error: error)
                if redirect.handled { return redirect.reply }
            }
            // Transparent reconnect: one backoff attempt before surfacing the error.
            if config.autoReconnect && !didRetry {
                didRetry = true
                let reconnected = (try? reconnectWithBackoff()) != nil
                didRetry = false
                if reconnected { return sendImpl(args, error: error) }
            }
            error?.pointee = readError
            return nil
        }
    }

    /// Follows a MOVED / ASK redirect. `handled` is false when the address could
    /// not be parsed, in which case the caller falls back to a reconnect.
    private func handleRedirect(message: String, args: [Any], error: NSErrorPointer) -> (handled: Bool, reply: Any?) {
        let parts = message.components(separatedBy: " ")
        guard parts.count > 2 else { return (false, nil) }
        // Strip an IPv6 bracket wrapper ([host]:port) if present, then split on the
        // LAST colon so IPv6 literals (which contain colons) parse correctly.
        var clean = parts[2]
        guard !clean.isEmpty else { return (false, nil) }
        if clean.hasPrefix("[") {
            if let close = clean.firstIndex(of: "]") {
                clean = String(clean[clean.index(after: clean.startIndex)..<close])
            }
        }
        var hpHost = clean
        var hpPort = connectPort
        if let colon = clean.lastIndex(of: ":") {
            hpHost = String(clean[..<colon])
            hpPort = Int(clean[clean.index(after: colon)...]) ?? hpPort
        }
        let mapped = mappedAddress(host: hpHost, port: hpPort)
        var targetHost = mapped
        var targetPort = hpPort
        if let colon = mapped.lastIndex(of: ":") {
            targetHost = String(mapped[..<colon])
            targetPort = Int(mapped[mapped.index(after: colon)...]) ?? hpPort
        }
        if message.hasPrefix("ASK ") {
            // ASK: one-shot redirect. Open a temporary stream, answer ASKING, then
            // restore the original connection (ASK must not permanently repoint us).
            guard let temp = try? makeStream(host: targetHost, port: targetPort) else {
                return (false, nil)
            }
            let restore = stream
            stream = temp
            if !effectiveAuth.isEmpty { _ = sendImpl(authArguments(), error: nil) }
            _ = sendImpl(["ASKING"], error: nil)
            let retry = sendImpl(args, error: error)
            stream = restore
            temp.close()
            return (true, retry)
        }
        // MOVED: the slot has migrated; permanently repoint the connection.
        connectHost = targetHost
        connectPort = targetPort
        guard let replacement = try? makeStream(host: targetHost, port: targetPort) else {
            return (false, nil)
        }
        stream?.close()
        stream = replacement
        if !effectiveAuth.isEmpty { _ = sendImpl(authArguments(), error: nil) }
        let retry = sendImpl(args, error: error)
        return (true, retry)
    }

    /// Atomic MULTI ... EXEC. The whole transaction is one critical section so a
    /// keepalive PING from another thread cannot slip between MULTI and EXEC.
    func sendTransaction(_ commands: [[String]], error: NSErrorPointer) -> [Any] {
        if config.readOnly {
            error?.pointee = ARDMError("You are in readonly mode! Unable to execute MULTI/EXEC!", 11)
            return []
        }
        lock.lock()
        defer { lock.unlock() }
        if stream == nil {
            error?.pointee = ARDMError("Not connected", 10)
            return []
        }
        var pipeline: [[Any]] = [["MULTI"]]
        pipeline.append(contentsOf: commands.map { $0 as [Any] })
        pipeline.append(["EXEC"])
        var results: [Any] = []
        results.reserveCapacity(pipeline.count)
        for args in pipeline {
            var innerError: NSError?
            let reply = sendImpl(args, error: &innerError)
            if innerError != nil || reply == nil {
                error?.pointee = innerError ?? ARDMError("Transaction failed", 12)
                // Best effort rollback so the connection is not left inside MULTI.
                if args.first as? String != "EXEC" { _ = sendImpl(["DISCARD"], error: nil) }
                return []
            }
            results.append(reply!)
        }
        return results
    }

    // MARK: Typed helpers

    func clusterTopology(_ error: NSErrorPointer) -> [AnyHashable: Any] {
        let slotsReply = sendImpl(["CLUSTER", "SLOTS"], error: error)
        var out: [[String: Any]] = []
        for slot in ARDMNormalizeArray(slotsReply) {
            let row = ARDMNormalizeArray(slot)
            if row.count < 3 { continue }
            let master = ARDMNormalizeArray(row[2])
            let host = master.count > 0 ? ARDMReplyToString(master[0]) : ""
            let port = master.count > 1 ? (Int(ARDMReplyToString(master[1])) ?? 0) : 0
            var replicas: [String] = []
            if row.count > 3 {
                for index in 3..<row.count {
                    let replica = ARDMNormalizeArray(row[index])
                    if replica.count > 1 {
                        replicas.append("\(ARDMReplyToString(replica[0])):\(ARDMReplyToString(replica[1]))")
                    }
                }
            }
            out.append(["start": row[0], "end": row[1],
                        "master": mappedAddress(host: host, port: port),
                        "replicas": replicas])
        }
        let nodesReply = sendImpl(["CLUSTER", "NODES"], error: nil)
        var nodeList: [[String: Any]] = []
        for line in ARDMReplyToString(nodesReply).components(separatedBy: "\n") where !line.isEmpty {
            let columns = line.components(separatedBy: " ")
            if columns.count > 7 {
                nodeList.append(["id": columns[0], "address": columns[1], "flags": columns[2],
                                 "slots": Array(columns[8...])])
            }
        }
        return ["slots": out, "nodes": nodeList]
    }

    func scanKeys(matching pattern: String, cursor: inout UInt, count: UInt, error: NSErrorPointer) -> [String] {
        let reply = ARDMNormalizeArray(sendImpl(
            ["SCAN", "\(cursor)", "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", "\(count)"],
            error: error))
        if reply.count < 2 { return [] }
        cursor = UInt(ARDMReplyToString(reply[0])) ?? 0
        return ARDMNormalizeArray(reply[1]).map { ARDMReplyToString($0) }
    }

    func type(ofKey key: String, error: NSErrorPointer) -> ARDMKeyType {
        let type = ARDMReplyToString(sendImpl(["TYPE", key], error: error)).lowercased()
        if type == "string" { return .string }
        if type == "list" { return .list }
        if type == "set" { return .set }
        if type == "zset" { return .zSet }
        if type == "hash" { return .hash }
        if type == "stream" { return .stream }
        if type == "rejson-rl" || type == "rejson" { return .reJSON }
        if type == "mbbloomcf" || type == "tsdb-type" { return .timeSeries }
        if type.contains("vector") { return .vector }
        if type.contains("array") { return .array }
        return .unknown
    }

    func ttl(ofKey key: String, error: NSErrorPointer) -> Int {
        Int(ARDMReplyToString(sendImpl(["TTL", key], error: error))) ?? 0
    }

    func value(ofKey key: String, type: ARDMKeyType, error: NSErrorPointer) -> Any {
        let args: [Any]
        switch type {
        case .string, .reJSON, .vector:
            args = ["GET", key]
        case .list:
            args = ["LRANGE", key, "0", "-1"]
        case .set:
            args = ["SMEMBERS", key]
        case .zSet:
            args = ["ZRANGE", key, "0", "-1", "WITHSCORES"]
        case .hash:
            args = ["HGETALL", key]
        case .stream:
            args = ["XRANGE", key, "-", "+"]
        case .timeSeries:
            args = ["TS.RANGE", key, "-", "+"]
        case .array:
            args = ["ARGET", key, "0", "-1"]
        case .unknown:
            args = ["GET", key]
        }
        return sendImpl(args, error: error) ?? NSNull()
    }

    func dbSize(_ error: NSErrorPointer) -> Int {
        Int(ARDMReplyToString(sendImpl(["DBSIZE"], error: error))) ?? 0
    }

    func infoSection(_ section: String?, error: NSErrorPointer) -> String {
        let args: [Any]
        if let section, !section.isEmpty {
            args = ["INFO", section]
        } else {
            args = ["INFO"]
        }
        return ARDMReplyToString(sendImpl(args, error: error))
    }

    // MARK: Push streams (Pub/Sub, MONITOR)

    func stopLive() {
        liveRunningFlag = false
        let live = liveClient
        liveClient = nil
        live?.disconnect()
    }

    func startLive(withCommand args: [String],
                   onEvent: @escaping ([Any]) -> Void,
                   onError: @escaping (String) -> Void) {
        stopLive()
        if liveQueue == nil { liveQueue = DispatchQueue(label: "me.qii404.ardm.live") }
        liveRunningFlag = true
        liveQueue?.async { [weak self] in
            guard let self, self.liveRunningFlag else { return }
            // Honour read-only mode on the live stream too: refuse any write verb so the
            // dedicated MONITOR/SUBSCRIBE channel cannot be used to bypass the write lock.
            let verb = self.commandVerb(args as [Any])
            let two = self.twoTokenVerb(args as [Any])
            if self.config.readOnly &&
                (ARDMRedisClient.writeCommands.contains(verb) || ARDMRedisClient.writeCommands.contains(two)) {
                self.liveRunningFlag = false
                let message = "You are in readonly mode! Unable to execute write command!"
                DispatchQueue.main.async { onError(message) }
                return
            }
            let live = ARDMRedisClient(config: self.config)
            do {
                try live.connect()
            } catch {
                self.liveRunningFlag = false
                DispatchQueue.main.async { onError(error.localizedDescription) }
                return
            }
            self.liveClient = live
            do {
                try live.rawWrite(args as [Any])
            } catch {
                self.liveRunningFlag = false
                DispatchQueue.main.async { onError(error.localizedDescription) }
                live.disconnect()
                return
            }
            while self.liveRunningFlag {
                let reply: Any
                do {
                    reply = try live.rawRead()
                } catch {
                    break
                }
                let event = ARDMNormalizeArray(reply)
                DispatchQueue.main.async { onEvent(event) }
            }
            self.liveRunningFlag = false
            live.disconnect()
            if self.liveClient === live { self.liveClient = nil }
        }
    }

    private func rawWrite(_ args: [Any]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { throw ARDMError("Not connected", 10) }
        try stream.write(ARDMEncodeCommand(args))
    }

    private func rawRead() throws -> Any {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { throw ARDMError("Not connected", 10) }
        return try stream.readReply()
    }

    // MARK: SSH tunnel

    /// Allocate a loopback port by binding port 0, reading it back, and closing.
    private func freeLocalPort() -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return 0 }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 0 }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return 0 }
        return UInt16(bigEndian: address.sin_port)
    }

    private func openSSHTunnel() throws {
        let local = freeLocalPort()
        guard local != 0 else {
            throw ARDMError("Cannot allocate a local SSH tunnel port", 5)
        }
        let sshTimeout = config.sshTimeout > 0 ? config.sshTimeout : 10
        var args = ["-N", "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ExitOnForwardFailure=yes",
                    "-o", "ConnectTimeout=\(sshTimeout)",
                    "-L", "\(local):\(config.host):\(config.port)",
                    "-p", "\(config.sshPort != 0 ? config.sshPort : 22)"]
        if config.sshKeepaliveInterval > 0 {
            args += ["-o", "ServerAliveInterval=\(config.sshKeepaliveInterval)", "-o", "ServerAliveCountMax=3"]
        }
        if config.sshAutoClose {
            // Drop the tunnel once all forwarded connections have closed (upstream autoClose).
            args += ["-o", "ServerAliveInterval=15"]
        }
        if !config.sshPrivateKey.isEmpty { args += ["-i", config.sshPrivateKey] }
        args.append("\(config.sshUser)@\(config.sshHost)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = args
        if !config.sshPassword.isEmpty {
            let script = (NSTemporaryDirectory() as NSString).appendingPathComponent("ardm_askpass.sh")
            let escaped = config.sshPassword.replacingOccurrences(of: "'", with: "'\\''")
            let body = "#!/bin/sh\necho '\(escaped)'\n"
            try? body.write(toFile: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)
            task.environment = ["SSH_ASKPASS": script,
                                "SSH_ASKPASS_REQUIRE": "force",
                                "DISPLAY": "ardm:0"]
        }
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            throw ARDMError("SSH failed: \(error.localizedDescription)", 6)
        }
        sshTask = task
        connectHost = "127.0.0.1"
        connectPort = Int(local)

        let readyTimeout = config.sshReadyTimeout > 0 ? config.sshReadyTimeout : 10
        let attempts = readyTimeout * 4   // poll every 250 ms
        for _ in 0..<attempts {
            if canConnect(port: local) { return }
            usleep(250000)
        }
        throw ARDMError("SSH tunnel did not become ready within \(readyTimeout) seconds", 7)
    }

    private func canConnect(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
