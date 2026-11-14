// Core regression probe: drives ARDMRedisClient against the scripted RESP server
// in fake_redis.py, plus every formatter/localization/keychain surface.
//
// Run it through tests/run.sh — the probe expects argv[1] to be the port the
// fake server is listening on and ARDM_PROJECT_ROOT to point at the checkout so
// it can load src/i18n/langs/*.js and src/commands.js without an .app bundle.
import Foundation
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

var gPass = 0
var gFail = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    let padded = label.padding(toLength: 34, withPad: " ", startingAt: 0)
    if ok {
        gPass += 1
        print("[PASS] \(padded) \(detail)")
    } else {
        gFail += 1
        print("[FAIL] \(padded) \(detail)")
    }
}

func utf8(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let data = value as? Data { return String(data: data, encoding: .utf8) }
    return nil
}

func bytes(_ value: Any?) -> Data? {
    if let data = value as? Data { return data }
    if let text = value as? String { return text.data(using: .utf8) }
    return nil
}

func intValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) ?? 0 }
    return 0
}

func drainMainRunLoop(until deadline: Date) {
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
}

final class Box<T> {
    var value: T?
    init() {}
}

let arguments = CommandLine.arguments
let port = arguments.count > 1 ? Int(arguments[1]) ?? 16379 : 16379

let config = ARDMConnectionConfig()
config.host = "127.0.0.1"
config.port = port
config.name = "verification"
let client = ARDMRedisClient(config: config)
var err: NSError?
var connected = false
do {
    try client.connect()
    connected = true
} catch let error as NSError {
    err = error
}
check("connect / PING", connected && err == nil, err?.localizedDescription ?? "connected")
if !connected { exit(1) }

check("GET bulk string",
      bytes(client.send(["GET", "str:foo"], error: &err)) == "bar".data(using: .utf8),
      "str:foo => bar")
err = nil
check("TYPE", utf8(client.send(["TYPE", "str:foo"], error: &err)) == "string", "string")
err = nil
var cursor: UInt = 0
let scanned = client.scanKeys(matching: "*", cursor: &cursor, count: 500, error: &err)
check("SCAN cursor + key list", scanned.contains("str:foo"), scanned.joined(separator: ","))
err = nil
check("TTL", intValue(client.send(["TTL", "str:foo"], error: &err)) == 3600, "3600")
err = nil
check("HGETALL array", (client.send(["HGETALL", "hash:h"], error: &err) as? [Any]) != nil, "array reply")
err = nil
check("SET allowed (read-write)", utf8(client.send(["SET", "str:foo", "baz"], error: &err)) == "OK", "OK")
err = nil
// Regression: the editor save path sends the encoded value as raw Data.
// The command-log builder used to call -substringToIndex: on it (NSData
// answers -length with its byte count) and the process aborted with
// "unrecognized selector sent to instance". >200 bytes so the old
// truncation branch is exercised too.
var payload = Data()
for _ in 0..<300 { payload.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x62, 0x69, 0x6E, 0x61, 0x72, 0x79]) }
let binReply = client.sendArguments(["SET", "bin:payload", payload], error: &err)
check("SET raw Data payload (save path)",
      utf8(binReply) == "OK" || err == nil,
      err?.localizedDescription ?? "reply=\(String(describing: binReply))")
err = nil
let size = client.dbSize(&err)
check("DBSIZE", size == 3, "\(size)")
err = nil
let info = client.infoSection("server", error: &err)
check("INFO section", info.contains("redis_version"), "contains redis_version")
err = nil
check("Command log recorded", client.logs.count >= 8, "\(client.logs.count) entries")
client.disconnect()

let readOnly = ARDMConnectionConfig()
readOnly.host = "127.0.0.1"
readOnly.port = port
readOnly.readOnly = true
let readOnlyClient = ARDMRedisClient(config: readOnly)
var readOnlyError: NSError?
try? readOnlyClient.connect()
let blocked = readOnlyClient.send(["SET", "k", "v"], error: &readOnlyError)
check("Read-only blocks write", readOnlyError?.code == 11,
      readOnlyError?.localizedDescription ?? "no error")
readOnlyClient.disconnect()

let json = "{\"a\":1,\"b\":[2,3]}".data(using: .utf8)!
let rendered = ARDMFormatters.render(json, as: "Json", error: nil)
check("Viewer: Json", rendered.contains("\"a\""), "pretty printed")
check("Viewer: Hex", ARDMFormatters.render(json, as: "Hex", error: nil).contains("7b"), "hex dump")
let gzipSample = Data([0x1f, 0x8b])
check("Viewer: detect gzip", ARDMFormatters.detectViewer(for: gzipSample) == "Gzip", "Gzip")
check("Viewer: msgpack",
      ARDMFormatters.render(Data([0x92, 0x01, 0xa3, 0x66, 0x6f, 0x6f]), as: "Msgpack", error: nil).contains("foo"),
      "[1, foo]")
check("Viewer: custom (JavaScriptCore)",
      ARDMFormatters.renderCustom(json, script: "return bytes.length;", error: nil) == "17",
      "byte length via JS")

let localization = ARDMLocalization.shared()
check("Localization: 13 languages loaded", localization.languages.count == 13,
      "\(localization.languages.count)")
localization.currentLanguage = "cn"
let translated = localization.t("message.host")
check("Localization: cn table usable", translated != "message.host", translated)
var resolvedTables = 0
var samples: [String] = []
for code in localization.languages {
    localization.currentLanguage = code
    let translatedLabel = localization.t("message.new_connection")
    // t: falls back to the key when a table failed to load, so an exact
    // match means "missing table", not a valid translation.
    let loaded = translatedLabel != "message.new_connection" && translatedLabel != "New Connection"
    if loaded { resolvedTables += 1 }
    samples.append("\(code)=\(translatedLabel)")
}
check("Localization: 12 non-en tables resolve", resolvedTables == 12, samples.joined(separator: " "))
localization.currentLanguage = "cn"

// ---- English text -> nested upstream key (englishIndex) ----
// The upstream tables nest everything under `message.`/`info.` groups; a flat
// index over the top level finds no strings and silently disables every
// English-text lookup.
let nestedHit = localization.translation(forEnglishText: "New Connection")
check("translation(forEnglishText:) reaches nested keys",
      nestedHit != nil && nestedHit != "New Connection", nestedHit ?? "nil")
check("translation(forEnglishText:) is nil for unknown text",
      localization.translation(forEnglishText: "Zzyzx is not a label anywhere") == nil, "nil")
check("translation(forEnglishText:) tolerates surrounding spaces",
      localization.translation(forEnglishText: "  new connection \n") != nil, "case + whitespace")
var leakedKeys: [String] = []
for code in localization.languages where code != "en" {
    localization.currentLanguage = code
    for label in ["New Connection", "Test Connection", "Refresh", "Delete Connection",
                  "Close Connection", "Edit Connection", "Host", "Password", "Port"] {
        if let value = localization.translation(forEnglishText: label),
           value.hasPrefix("message.") || value.isEmpty {
            leakedKeys.append("\(code)=\(value)")
        }
    }
}
check("English-text lookups never leak a key path", leakedKeys.isEmpty, leakedKeys.joined(separator: " "))

// The label tables keep their own priority; where none of them claims a label,
// the hand-written upstream text must beat the word-wise hybrid.
let curated = Set(uiChinese.keys).union(uiAliases.keys)
    .union(uiPhraseRows.map { String($0.split(separator: "|").first ?? "") })
var preferredUpstream = 0
var wrong = 0
for code in localization.languages where code != "en" {
    localization.currentLanguage = code
    for label in ["New Connection", "Used memory", "Client List", "Database Index",
                  "Server Info", "Big Key", "Collapse all", "Expand all", "Slow Log"]
    where !curated.contains(label) {
        guard let official = localization.translation(forEnglishText: label) else { continue }
        preferredUpstream += 1
        if uiLocalized(label) != official { wrong += 1 }
    }
}
check("uiLocalized defers to upstream text when it exists",
      preferredUpstream > 0 && wrong == 0, "\(preferredUpstream) cases, \(wrong) wrong")
localization.currentLanguage = "cn"

// ---- New transport-layer capabilities ----
let transportConfig = ARDMConnectionConfig()
transportConfig.host = "127.0.0.1"
transportConfig.port = port
transportConfig.name = "transport-probe"
transportConfig.natMap = ["10.0.0.1:6379": "203.0.113.9:6380"]
transportConfig.autoReconnect = true
let transportClient = ARDMRedisClient(config: transportConfig)
var transportError: NSError?
var transportConnected = false
do {
    try transportClient.connect()
    transportConnected = true
} catch let error as NSError {
    transportError = error
}
check("Reconnect/backoff capable config", transportConnected,
      transportError?.localizedDescription ?? "connected")

transportError = nil
let binaryKey = "str:foo".data(using: .utf8)!
let binaryReply = transportClient.sendArguments(["GET", binaryKey], error: &transportError)
check("Binary arguments (NSData)",
      bytes(binaryReply) == "bar".data(using: .utf8),
      "GET <NSData> => bar")

transportError = nil
let topology = transportClient.clusterTopology(&transportError)
let slots = (topology["slots"] as? [[String: Any]]) ?? []
let master = (slots.first?["master"] as? String) ?? ""
check("Cluster SLOTS + NODES topology",
      slots.count == 1 && ((topology["nodes"] as? [Any])?.count ?? 0) == 1,
      "\(slots.count) slots")
check("Cluster NAT mapping applied", master == "203.0.113.9:6380", master)

transportError = nil
var reconnected = false
do {
    try transportClient.reconnectWithBackoff()
    reconnected = true
} catch let error as NSError {
    transportError = error
}
check("Reconnect with backoff", reconnected, transportError?.localizedDescription ?? "reconnected")

let viewers = ARDMFormatters.viewerNames()
for viewer in viewers {
    _ = ARDMFormatters.render(json, as: viewer, error: nil)
}
check("All 15 viewers render without crash", viewers.count == 15,
      "\(viewers.count) viewers")

check("Font enumeration (font-list)", ARDMAppServices.availableFonts().count > 10,
      "\(ARDMAppServices.availableFonts().count) families")
check("Command reference (commands.js)", ARDMAppServices.commandReference().count > 100,
      "\(ARDMAppServices.commandReference().count) commands")

ARDMAppServices.saveCustomFormatters([["name": "probe", "script": "return bytes.length;"]])
check("Custom formatter persistence",
      ARDMAppServices.customFormatters().first?["name"] == "probe", "saved + reloaded")
check("Connection JSON export", ARDMAppServices.exportConnectionsJSON().hasPrefix("["), "JSON array")

let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
let bookmark = ARDMAppServices.bookmark(for: tempURL)
let resolved = bookmark.flatMap { ARDMAppServices.resolveBookmark($0) }
check("Security-scoped bookmark", bookmark != nil && resolved != nil,
      resolved?.path ?? NSTemporaryDirectory())

// ---- Pub/Sub + MONITOR live streams ----
let events = Box<Int>()
events.value = 0
transportClient.startLive(withCommand: ["SUBSCRIBE", "channel"],
                          onEvent: { rows in
                              if !rows.isEmpty { events.value = (events.value ?? 0) + 1 }
                          },
                          onError: { message in
                              print("  live error: \(message)")
                          })
// Callbacks dispatch to the main queue; drain it via the main run loop.
var waited = 0
while waited < 100 && (events.value ?? 0) == 0 {
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    waited += 1
}
check("Pub/Sub live push stream", (events.value ?? 0) > 0, "\(events.value ?? 0) events")
transportClient.stopLive()
check("Live stream stop", !transportClient.liveRunning, "stopped")

// ---- New feature parity checks ----
transportError = nil
let jsonText = "{\"name\":\"foo\",\"n\":42,\"list\":[1,2]}"
let msgpack = ARDMFormatters.encode(jsonText, as: "Msgpack", error: &transportError)
let msgpackBack = ARDMFormatters.render(msgpack, as: "Msgpack", error: nil)
check("Msgpack encode -> decode",
      !msgpack.isEmpty && msgpackBack.contains("foo") && msgpackBack.contains("42"),
      "\(msgpack.count) bytes")

let php = ARDMFormatters.encode(jsonText, as: "PHPSerialize", error: &transportError)
let phpBack = ARDMFormatters.render(php, as: "PHPSerialize", error: nil)
check("PHP serialize encode -> decode", phpBack.contains("foo"),
      String(data: php, encoding: .utf8) ?? "")

let plain = "hello compression"
for codec in ["Gzip", "Deflate", "DeflateRaw"] {
    let packed = ARDMFormatters.encode(plain, as: codec, error: nil)
    let unpacked = ARDMFormatters.render(packed, as: codec, error: nil)
    check("\(codec) encode -> decode", unpacked == plain, "\(packed.count) bytes")
}

let sample = "Hello".data(using: .utf8)!
let hexDump = ARDMFormatters.render(sample, as: "Hex", error: nil)
let hexBack = ARDMFormatters.encode(hexDump, as: "Hex", error: nil)
check("Hex dump -> bytes", hexBack == sample, "hex")
let binDump = ARDMFormatters.render(sample, as: "Binary", error: nil)
let binBack = ARDMFormatters.encode(binDump, as: "Binary", error: nil)
check("Binary dump -> bytes", binBack == sample, "01001000 ...")

let big = "{\"id\":123456789012345678901}"
let bigData = ARDMFormatters.encode(big, as: "Json", error: nil)
check("Json BigInt preserved verbatim", bigData == big.data(using: .utf8), big)
check("12 viewers support write-back", ARDMFormatters.encodableViewers().count == 12,
      "\(ARDMFormatters.encodableViewers().count)")

ARDMFormatters.setProtobufSchema([NSNumber(value: 1): "user_name"])
let protobuf = Data([0x08, 0x07])
let protobufOut = ARDMFormatters.render(protobuf, as: "Protobuf", error: nil)
check("Protobuf schema field names", protobufOut.contains("user_name"), protobufOut)

// Scoped .proto schema: nested message + repeated field.
let protobufScopes: [String: [NSNumber: String]] = [
    "User": [NSNumber(value: 1): "varint|id",
             NSNumber(value: 2): "string|name",
             NSNumber(value: 3): "message|address|User.Address",
             NSNumber(value: 4): "varint|tag"],
    "User.Address": [NSNumber(value: 1): "string|city"],
]
ARDMFormatters.setProtobufScopes(protobufScopes, root: "User")
let nestedBytes: [UInt8] = [
    0x08, 0x07,                         // id = 7
    0x12, 0x03, 0x62, 0x6F, 0x62,       // name = "bob"
    0x1A, 0x04, 0x0A, 0x02, 0x4E, 0x59, // address { city = "NY" }
    0x20, 0x01, 0x20, 0x02,             // tag = [1, 2]
]
let nested = Data(nestedBytes)
let nestedOut = ARDMFormatters.render(nested, as: "Protobuf", error: nil)
check("Protobuf nested message decoded", nestedOut.contains("\"city\" : \"NY\""), nestedOut)
check("Protobuf repeated field becomes an array", nestedOut.contains("\"tag\" : ["), nestedOut)

let jsonInput = "{\"id\":7,\"name\":\"bob\",\"address\":{\"city\":\"NY\"},\"tag\":[1,2]}"
var protobufError: NSError?
let reencoded = ARDMFormatters.encode(jsonInput, as: "Protobuf", error: &protobufError)
var roundTrip: [String: Any]?
if !reencoded.isEmpty {
    let again = ARDMFormatters.render(reencoded, as: "Protobuf", error: nil)
    roundTrip = (try? JSONSerialization.jsonObject(with: again.data(using: .utf8)!)) as? [String: Any]
}
let roundTripAddress = roundTrip?["address"] as? [String: Any]
check("Protobuf JSON writes back to wire",
      (roundTrip?["id"] as? NSNumber)?.intValue == 7
          && roundTrip?["name"] as? String == "bob"
          && roundTripAddress?["city"] as? String == "NY",
      protobufError?.localizedDescription ?? "\(reencoded.count) bytes")

// OverSize viewer pages through a 10 KB value instead of clipping at 4 KB.
var bigValue = Data()
for index in 0..<10000 { bigValue.append(UInt8(index & 0xFF)) }
let chunk = ARDMFormatters.render(bigValue, as: "OverSize", offset: 4096, length: 4096, error: nil)
check("OverSize viewer pages by offset",
      chunk.contains("Bytes 4096") && chunk.contains("of 10000"),
      chunk.components(separatedBy: "\n").first ?? "")

transportError = nil
let transaction = transportClient.sendTransaction([["SET", "a", "1"], ["INCR", "counter"]], error: &transportError)
check("MULTI / QUEUED / EXEC",
      transaction.count == 4 && (transaction.last as? [Any]) != nil,
      "\(transaction.count) replies")

// ---- MULTI ... EXEC must be one critical section ----
// A second thread hammers PING while a 60-command transaction runs. The
// gap that matters is the one between two send: round-trips — the lock in
// send: is released there, so without a transaction-wide lock a PING gets
// written inside the transaction, the server queues it, and it comes back
// as "QUEUED" instead of "PONG".
do {
    let transactionConfig = ARDMConnectionConfig()
    transactionConfig.host = "127.0.0.1"
    transactionConfig.port = port
    transactionConfig.name = "tx-probe"
    let transactionClient = ARDMRedisClient(config: transactionConfig)
    try? transactionClient.connect()

    var transactionCommands: [[String]] = []
    for index in 0..<60 {
        transactionCommands.append(["SET", "tx:probe:\(index)", "1"])
    }

    let running = Box<Bool>()
    running.value = true
    let replies = Box<[Any]>()
    var pingReplies: [Any?] = []
    let group = DispatchGroup()

    DispatchQueue.global(qos: .userInitiated).async(group: group) {
        // Hammer until the transaction has finished.
        while (running.value ?? false) && pingReplies.count < 4000 {
            let reply = transactionClient.send(["PING"], error: nil)
            pingReplies.append(reply)
        }
    }
    DispatchQueue.global(qos: .userInitiated).async(group: group) {
        var inner: NSError?
        replies.value = transactionClient.sendTransaction(transactionCommands, error: &inner)
        running.value = false
    }
    let timedOut = group.wait(timeout: .now() + 20) != .success
    check("transaction finishes while another thread hammers PING", !timedOut,
          "\(pingReplies.count) pings")

    var sequenceError: NSError?
    let sequence = (transactionClient.send(["PROBE.SEQ"], error: &sequenceError) as? [Any]) ?? []
    var verbs: [String] = []
    for item in sequence {
        verbs.append(utf8(item) ?? "?")
    }
    var multiAt = Int.max
    for index in stride(from: verbs.count, to: 0, by: -1) {
        if verbs[index - 1] == "MULTI" { multiAt = index - 1; break }
    }
    var execAt = Int.max
    let execStart = multiAt == Int.max ? 0 : multiAt
    for index in execStart..<verbs.count {
        if verbs[index] == "EXEC" { execAt = index; break }
    }
    var interleaved = false
    if multiAt == Int.max || execAt == Int.max {
        interleaved = true   // a transaction that never opened is just as wrong
    } else {
        for index in (multiAt + 1)..<execAt {
            if verbs[index] == "PING" { interleaved = true }
        }
    }
    var detail = "\(pingReplies.count) pings, \(replies.value?.count ?? 0) tx replies"
    if interleaved && multiAt != Int.max {
        let window = Array(verbs[multiAt..<min(multiAt + 10, verbs.count)])
        detail = window.joined(separator: " ")
    }
    check("PING cannot interleave into MULTI...EXEC", !interleaved, detail)

    var queued = 0
    for reply in pingReplies {
        if utf8(reply) != "PONG" { queued += 1 }
    }
    check("no PING is answered with QUEUED", queued == 0, "\(queued) non-PONG replies")
    check("transaction still returns its own replies",
          (replies.value?.count ?? 0) == transactionCommands.count + 2
              && (replies.value?.last as? [Any]) != nil,
          "\(replies.value?.count ?? 0) replies")
    transactionClient.disconnect()
}

transportError = nil
let hscan = transportClient.send(["HSCAN", "hash:h", "0", "COUNT", "10"], error: &transportError)
check("HSCAN cursor streaming", (hscan as? [Any])?.count == 2, "cursor + flat array")

// ---- Security: AUTH password must never appear in the command log ----
let authConfig = ARDMConnectionConfig()
authConfig.host = "127.0.0.1"
authConfig.port = port
authConfig.name = "auth-probe"
authConfig.auth = "supersecret"
let authClient = ARDMRedisClient(config: authConfig)
var authError: NSError?
try? authClient.connect()
_ = authClient.send(["GET", "str:foo"], error: &authError)
var leaked = false
var masked = false
for case let log as ARDMCommandLog in authClient.logs {
    if log.command.contains("supersecret") { leaked = true }
    if log.command == "AUTH ***" { masked = true }
}
check("AUTH password not leaked in log", !leaked, leaked ? "LEAK" : "no plaintext")
check("AUTH masked as 'AUTH ***'", masked, masked ? "masked" : "not found")
authClient.disconnect()

// ---- Read-only must also block two-token administrative commands ----
let readOnlyAdmin = ARDMConnectionConfig()
readOnlyAdmin.host = "127.0.0.1"
readOnlyAdmin.port = port
readOnlyAdmin.name = "ro2"
readOnlyAdmin.readOnly = true
let readOnlyAdminClient = ARDMRedisClient(config: readOnlyAdmin)
try? readOnlyAdminClient.connect()
var configError: NSError?
var clientError: NSError?
let configBlocked = readOnlyAdminClient.send(["CONFIG", "SET", "foo", "bar"], error: &configError)
let clientBlocked = readOnlyAdminClient.send(["CLIENT", "KILL", "1"], error: &clientError)
check("Read-only blocks CONFIG SET", configError != nil,
      configError?.localizedDescription ?? "blocked")
check("Read-only blocks CLIENT KILL", clientError != nil,
      clientError?.localizedDescription ?? "blocked")
readOnlyAdminClient.disconnect()

// ---- Cluster MOVED redirect (IPv4 + IPv6 literal) ----
// Use a dedicated client; the MOVED reply permanently repoints the connection,
// so we must not contaminate transportClient (still used for HTTL/PTTL/RESTORE).
let redirectConfig = ARDMConnectionConfig()
redirectConfig.host = "127.0.0.1"
redirectConfig.port = port
redirectConfig.name = "moved-probe"
let redirectClient = ARDMRedisClient(config: redirectConfig)
var movedError: NSError?
try? redirectClient.connect()
transportError = nil
let redirected = redirectClient.send(["GET", "redirect:probe"], error: &transportError)
check("MOVED redirect followed (IPv4)",
      bytes(redirected) == "cross-node-ok".data(using: .utf8),
      String(describing: redirected))
transportError = nil
let redirected6 = redirectClient.send(["GET", "ipv6:probe"], error: &transportError)
check("MOVED IPv6 address parsed",
      bytes(redirected6) == "cross-node-ok".data(using: .utf8),
      String(describing: redirected6))
redirectClient.disconnect()

transportError = nil
let httl = transportClient.send(["HTTL", "hash:h", "FIELDS", "1", "f1"], error: &transportError)
check("HTTL field TTL", (httl as? [Any]) != nil, String(describing: httl))
transportError = nil
let pttl = transportClient.send(["PTTL", "str:foo"], error: &transportError)
check("PTTL milliseconds", intValue(pttl) == 3600000, String(describing: pttl))
transportError = nil
let dumpPayload = Data([0x00, 0x01, 0x02])
let restored = transportClient.sendArguments(["RESTORE", "k", "0", dumpPayload, "REPLACE"], error: &transportError)
check("RESTORE binary DUMP payload", utf8(restored) == "OK", String(describing: restored))

let readOnlyConfig = ARDMConnectionConfig()
readOnlyConfig.host = "127.0.0.1"
readOnlyConfig.port = port
readOnlyConfig.name = "readonly"
readOnlyConfig.readOnly = true
let readOnlyClient2 = ARDMRedisClient(config: readOnlyConfig)
var readOnlyError2: NSError?
try? readOnlyClient2.connect()
var blockError: NSError?
let hexpireBlocked = readOnlyClient2.send(["HEXPIRE", "hash:h", "60", "FIELDS", "1", "f1"], error: &blockError)
check("Read-only blocks HEXPIRE", blockError != nil,
      blockError?.localizedDescription ?? "blocked")
blockError = nil
_ = readOnlyClient2.send(["RESTORE", "k", "0", "x", "REPLACE"], error: &blockError)
check("Read-only blocks RESTORE", blockError != nil, blockError?.localizedDescription ?? "blocked")
readOnlyClient2.disconnect()

// ---- Round 5: integer precision, write detection, real deserializers, viewer detection ----
transportError = nil
let bigIntReply = transportClient.send(["BIGINT"], error: &transportError)
check("RESP integer > INT64 keeps digits",
      utf8(bigIntReply) == "9223372036854775808",
      String(describing: bigIntReply))

check("isWriteCommand FAILOVER = YES", transportClient.isWriteCommand(["FAILOVER"]), "admin write")
check("isWriteCommand GET = NO", !transportClient.isWriteCommand(["GET", "x"]), "read command")

let javaBytes: [UInt8] = [0xAC, 0xED, 0x00, 0x05, 0x74, 0x00, 0x03, 0x66, 0x6F, 0x6F]
let java = Data(javaBytes)
let javaOut = ARDMFormatters.render(java, as: "JavaSerialize", error: nil)
check("Java stream deserialized", javaOut.contains("foo"), javaOut)

// TC_OBJECT + TC_CLASSDESC("A", 1 int field x) + classdata(42)
let javaObject: [UInt8] = [0xAC, 0xED, 0x00, 0x05, 0x73, 0x72, 0x00, 0x01, 0x41,
                           0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x00, 0x01, 0x49, 0x00, 0x01, 0x78,
                           0x78, 0x70, 0x00, 0x00, 0x00, 0x2A]
let javaObjectOut = ARDMFormatters.render(Data(javaObject), as: "JavaSerialize", error: nil)
check("Java object fields decoded", javaObjectOut.contains("x (field I) = 42"), javaObjectOut)

let pickleBytes: [UInt8] = [0x80, 0x04, 0x95, 0, 0, 0, 0, 0, 0, 0, 0, 0x8C, 0x05,
                            0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x94, 0x2E]
let pickle = Data(pickleBytes)
let pickleOut = ARDMFormatters.render(pickle, as: "Pickle", error: nil)
check("Pickle deserialized", pickleOut.contains("hello"), "SHORT_BINUNICODE")

check("detect Brotli", ARDMFormatters.detectViewer(for: Data([0xCE, 0xB2, 0x81])) == "Brotli", "ce b2 81")
check("detect PHP serialize",
      ARDMFormatters.detectViewer(for: "a:1:{s:1:\"x\";i:1;}".data(using: .utf8)!) == "PHPSerialize",
      "a:1:{...}")
check("detect Deflate", ARDMFormatters.detectViewer(for: Data([0x78, 0x9C, 0x00, 0x00])) == "Deflate", "78 9c")
check("detect DeflateRaw", ARDMFormatters.detectViewer(for: Data([0x03, 0x00, 0x01])) == "DeflateRaw",
      "raw deflate block")
check("detect Protobuf", ARDMFormatters.detectViewer(for: Data([0x08, 0x07])) == "Protobuf",
      "field 1 varint")

// ---- Round 6: Keychain secrets + token-preserving JSON ----
let jsonData = "{\"big\":123456789012345678901,\"s\":\"x\"}".data(using: .utf8)!
let pretty = ARDMFormatters.formatJSON(jsonData, pretty: true)
check("formatJSON keeps 21-digit integer",
      (pretty ?? "").contains("123456789012345678901"), pretty ?? "")
let compact = ARDMFormatters.formatJSON(jsonData, pretty: false)
check("minifyJSON keeps 21-digit integer",
      compact == "{\"big\":123456789012345678901,\"s\":\"x\"}", compact ?? "")

let scalarData = "123456789012345678901".data(using: .utf8)!
check("formatJSON keeps bare big-number scalar",
      ARDMFormatters.formatJSON(scalarData, pretty: false) == "123456789012345678901", "scalar")
check("Json viewer keeps big-number scalar",
      ARDMFormatters.render(scalarData, as: "Json", error: nil) == "123456789012345678901", "render")

check("validateJSON accepts object", ARDMFormatters.validateJSON(jsonData), "valid")
check("validateJSON rejects unclosed object",
      !ARDMFormatters.validateJSON("{\"a\":1".data(using: .utf8)!), "unclosed")
check("validateJSON rejects mismatched brackets",
      !ARDMFormatters.validateJSON("{\"a\":[1}]".data(using: .utf8)!), "mismatch")
check("validateJSON rejects unterminated string",
      !ARDMFormatters.validateJSON("{\"a\":\"x}".data(using: .utf8)!), "unterminated")

// ---- UTF-8 pass-through (per-byte decoding turned these into latin-1 mojibake) ----
let cjkJSON = "{\"名字\":\"张三丰\",\"note\":\"联通 1928 号卡\"}".data(using: .utf8)!
let cjkPretty = ARDMFormatters.formatJSON(cjkJSON, pretty: true) ?? ""
check("formatJSON keeps CJK keys and values",
      cjkPretty.contains("\"名字\"") && cjkPretty.contains("\"张三丰\"")
          && cjkPretty.contains("联通 1928 号卡"), cjkPretty)
check("minifyJSON keeps CJK byte-for-byte",
      ARDMFormatters.formatJSON(cjkJSON, pretty: false)
          == "{\"名字\":\"张三丰\",\"note\":\"联通 1928 号卡\"}", ARDMFormatters.formatJSON(cjkJSON, pretty: false) ?? "")
check("Json viewer shows CJK without mojibake",
      ARDMFormatters.render(cjkJSON, as: "Json", error: nil).contains("张三丰"), "render")
let emojiJSON = "{\"e\":\"🎉 ok\",\"t\":\"你好\"}".data(using: .utf8)!
check("formatJSON keeps 4-byte emoji",
      ARDMFormatters.formatJSON(emojiJSON, pretty: false)
          == "{\"e\":\"🎉 ok\",\"t\":\"你好\"}", ARDMFormatters.formatJSON(emojiJSON, pretty: false) ?? "")

// Structural bytes and escapes inside string literals must stay literal.
let trickyText = #"{"u":"a{b}c]d,e:f\"g\\"}"#
let trickyJSON = trickyText.data(using: .utf8)!
check("formatJSON treats structural bytes inside strings as literal",
      ARDMFormatters.formatJSON(trickyJSON, pretty: false) == trickyText,
      ARDMFormatters.formatJSON(trickyJSON, pretty: false) ?? "nil")
check("pretty formatJSON keeps the same string value",
      (ARDMFormatters.formatJSON(trickyJSON, pretty: true) ?? "").contains(#""a{b}c]d,e:f\"g\\""#),
      ARDMFormatters.formatJSON(trickyJSON, pretty: true) ?? "nil")
check("validateJSON still rejects a string left open by an escape",
      !ARDMFormatters.validateJSON(#"{"a":"x\"}"#.data(using: .utf8)!), "escaped quote stays inside")

// Binary payloads are what Redis actually returns: no crash, decodable output.
var binaryBytes = [UInt8](("{\"b\":\"".utf8))
binaryBytes.append(contentsOf: [0xff, 0xfe, 0x80])
binaryBytes.append(contentsOf: [UInt8]("\"}".utf8))
let lossy = ARDMFormatters.formatJSON(Data(binaryBytes), pretty: false)
check("formatJSON survives invalid UTF-8 without crashing",
      lossy != nil && (lossy ?? "").contains("\"b\":"), lossy ?? "nil")

let secretConfig = ARDMConnectionConfig()
secretConfig.auth = "pw"
secretConfig.sshPassword = "sshpw"
secretConfig.sshPassphrase = "phrase"
secretConfig.sentinelNodePassword = "sentinelpw"
let redacted = secretConfig.toDictionary()
check("toDictionary redacts every secret",
      ((redacted["auth"] as? String) ?? "").isEmpty
          && ((redacted["sshPassword"] as? String) ?? "").isEmpty
          && ((redacted["sshPassphrase"] as? String) ?? "").isEmpty
          && ((redacted["sentinelNodePassword"] as? String) ?? "").isEmpty,
      "no plaintext")
check("toDictionary records hasStoredSecret",
      (redacted["hasStoredSecret"] as? NSNumber)?.boolValue == true, "hasStoredSecret=1")

let account = "ardm-verify/auth"
_ = ARDMKeychain.deleteSecret(forAccount: account)
let stored = ARDMKeychain.setSecret("s3cret", forAccount: account)
let fetched = ARDMKeychain.secret(forAccount: account)
check("Keychain stores and returns a secret", stored && fetched == "s3cret", fetched ?? "nil")
check("Keychain reports existence", ARDMKeychain.hasSecret(forAccount: account), "present")
let removed = ARDMKeychain.deleteSecret(forAccount: account)
check("Keychain deletes a secret",
      removed && ARDMKeychain.secret(forAccount: account) == nil, "gone")

let persistConfig = ARDMConnectionConfig()
persistConfig.auth = "keepme"
let authAccount = "\(persistConfig.identifier)/auth"
_ = ARDMKeychain.deleteSecret(forAccount: authAccount)
let fallback = persistConfig.persistenceDictionary()
check("persistenceDictionary keeps a secret the Keychain refused",
      fallback["auth"] as? String == "keepme", "fallback to file")
_ = ARDMKeychain.setSecret(persistConfig.auth, forAccount: authAccount)
let redacted2 = persistConfig.persistenceDictionary()
check("persistenceDictionary redacts once the Keychain has it",
      ((redacted2["auth"] as? String) ?? "").isEmpty, "redacted")
_ = ARDMKeychain.deleteSecret(forAccount: authAccount)

// Legacy plaintext hydration (the path loadAll takes on first launch).
let legacy = ARDMConnectionConfig.fromDictionary([
    "identifier": "probe-migrate", "name": "probe", "host": "127.0.0.1",
    "port": 6379, "auth": "legacypw", "sshPassword": "sshpw",
] as [String: Any])
let legacySource: [String: String] = ["auth": "legacypw", "sshPassword": "sshpw"]
let migrated = legacy.hydrateSecrets(fromKeychain: legacySource)
check("legacy plaintext hydrates the in-memory config",
      migrated && legacy.auth == "legacypw" && legacy.sshPassword == "sshpw",
      "auth=\(legacy.auth) ssh=\(legacy.sshPassword)")
check("hydrated config still redacts its snapshot",
      ((legacy.toDictionary()["auth"] as? String) ?? "").isEmpty, "redacted")

// The migration counter is consumed once and then resets.
let firstCount = ARDMConnectionConfig.consumeKeychainMigrationCount()
let secondCount = ARDMConnectionConfig.consumeKeychainMigrationCount()
check("migration counter is consumed once", secondCount == 0,
      "first=\(firstCount) second=\(secondCount)")

// The sidebar divider: the floor clamps the width, a long overshoot collapses
// the column. No mouse is involved, so the rule itself is what is under test.
let dragShort = ARDMSidebarDrag.settle(raw: 150, lower: 200, limit: 520)
check("sidebar drag clamps to the floor", dragShort.width == 200, "\(dragShort.width)")
check("short overshoot keeps the sidebar open", !dragShort.collapse, "50pt past the floor")
let dragLong = ARDMSidebarDrag.settle(raw: 140, lower: 200, limit: 520)
check("long overshoot collapses the sidebar", dragLong.collapse && dragLong.width == 200, "60pt past the floor")
let dragWide = ARDMSidebarDrag.settle(raw: 900, lower: 200, limit: 520)
check("sidebar drag clamps to the ceiling", dragWide.width == 520 && !dragWide.collapse, "\(dragWide.width)")
let dragPlain = ARDMSidebarDrag.settle(raw: 320, lower: 200, limit: 520)
check("ordinary drag width passes through", dragPlain.width == 320 && !dragPlain.collapse, "\(dragPlain.width)")

transportClient.disconnect()

exit(gFail == 0 ? 0 : 1)
