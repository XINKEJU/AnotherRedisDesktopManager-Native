import Foundation

/// Connection configuration (moved out of Redis.m, mirrors NewConnectionDialog.vue).
/// Reference type because the whole UI shares and mutates one instance per tab.
final class ARDMConnectionConfig: NSObject, NSCopying {

    var identifier: String = UUID().uuidString
    var name: String = "New Connection"
    var host: String = "127.0.0.1"
    var port: Int = 6379
    var auth: String = ""
    var username: String = ""
    var db: Int = 0
    var group: String = ""
    var separator: String = ":"
    var readOnly: Bool = false
    var cluster: Bool = false
    var connectionName: String = ""

    var sshEnabled: Bool = false
    var sshHost: String = ""
    var sshPort: Int = 22
    var sshUser: String = ""
    var sshPassword: String = ""
    var sshPrivateKey: String = ""
    var sshPassphrase: String = ""
    var sshTimeout: Int = 30
    /// SSH ServerAliveInterval (seconds); 0 = use default. Mirrors upstream keepaliveInterval.
    var sshKeepaliveInterval: Int = 0
    /// Max seconds to wait for the tunnel to become ready (mirrors upstream readyTimeout).
    var sshReadyTimeout: Int = 10
    /// Close the local forward when the connection drops (mirrors upstream autoClose).
    var sshAutoClose: Bool = true

    var tlsEnabled: Bool = false
    var tlsCA: String = ""
    var tlsCert: String = ""
    var tlsKey: String = ""
    var tlsSNI: String = ""
    var tlsInsecure: Bool = false

    var sentinelEnabled: Bool = false
    var sentinelMaster: String = ""
    var sentinelNodePassword: String = ""

    /// Cluster NAT map: keys are "internalHost:port", values are "publicHost:port".
    var natMap: [String: String] = [:]
    /// PEM bundle containing certificate + private key for mutual TLS.
    var tlsIdentityPath: String = ""
    /// Reconnect with exponential backoff after a dropped connection (default true).
    var autoReconnect: Bool = true
    /// Socket connect timeout in milliseconds (mirrors upstream connectTimeout, default 30000).
    var connectTimeout: Int = 30000
    /// Number of linear reconnect attempts before surfacing a failure (default 3).
    var retryTimes: Int = 3
    /// true when connections.json recorded a stored secret but the Keychain returned
    /// nothing (locked keychain / different user). Surfaced as a UI warning so the
    /// user is not left with a silent NOAUTH failure. Not persisted.
    var secretUnavailable: Bool = false

    override init() {
        super.init()
    }

    func copy(with zone: NSZone? = nil) -> Any {
        let c = ARDMConnectionConfig()
        c.identifier = identifier
        c.name = name; c.host = host; c.port = port
        c.auth = auth; c.username = username; c.db = db
        c.group = group; c.separator = separator
        c.readOnly = readOnly; c.cluster = cluster
        c.connectionName = connectionName
        c.sshEnabled = sshEnabled; c.sshHost = sshHost; c.sshPort = sshPort
        c.sshUser = sshUser; c.sshPassword = sshPassword
        c.sshPrivateKey = sshPrivateKey; c.sshPassphrase = sshPassphrase; c.sshTimeout = sshTimeout
        c.sshKeepaliveInterval = sshKeepaliveInterval
        c.sshReadyTimeout = sshReadyTimeout
        c.sshAutoClose = sshAutoClose
        c.tlsEnabled = tlsEnabled; c.tlsCA = tlsCA; c.tlsCert = tlsCert
        c.tlsKey = tlsKey; c.tlsSNI = tlsSNI; c.tlsInsecure = tlsInsecure
        c.sentinelEnabled = sentinelEnabled; c.sentinelMaster = sentinelMaster
        c.sentinelNodePassword = sentinelNodePassword
        c.natMap = natMap; c.tlsIdentityPath = tlsIdentityPath
        c.autoReconnect = autoReconnect
        c.connectTimeout = connectTimeout
        c.retryTimes = retryTimes
        return c
    }

    // MARK: - Persistence

    /// Plaintext secrets moved into the Keychain by the latest loadAll.
    private static var keychainMigrationCount = 0

    /// Identifiers of the secret-bearing fields, shared by every Keychain path.
    private static let secretFields = ["auth", "sshPassword", "sshPassphrase", "sentinelNodePassword"]

    static func storePath() -> String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".config/ardm-native")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("connections.json")
    }

    private func keychainAccount(_ field: String) -> String {
        "\(identifier)/\(field)"
    }

    private func secretValue(_ field: String) -> String {
        switch field {
        case "auth": return auth
        case "sshPassword": return sshPassword
        case "sshPassphrase": return sshPassphrase
        case "sentinelNodePassword": return sentinelNodePassword
        default: return ""
        }
    }

    private func setSecretValue(_ field: String, _ value: String) {
        switch field {
        case "auth": auth = value
        case "sshPassword": sshPassword = value
        case "sshPassphrase": sshPassphrase = value
        case "sentinelNodePassword": sentinelNodePassword = value
        default: break
        }
    }

    private func persistSecretsToKeychain() {
        guard !identifier.isEmpty else { return }
        // When the Keychain refused access earlier we hold empty strings that do not
        // mean "cleared" — writing them would delete a secret we simply could not
        // read. Unavailable secrets are therefore left untouched.
        for field in ARDMConnectionConfig.secretFields {
            let value = secretValue(field)
            if value.isEmpty && secretUnavailable { continue }
            ARDMKeychain.setSecret(value, forAccount: keychainAccount(field))
        }
    }

    /// Pulls each secret out of the Keychain, falling back to a legacy plaintext
    /// value in the JSON file (first launch after upgrading). Returns true when a
    /// plaintext value was found, meaning the store should be rewritten.
    func hydrateSecrets(fromKeychain source: [String: Any]) -> Bool {
        var migrated = false
        for field in ARDMConnectionConfig.secretFields {
            let stored = ARDMKeychain.secret(forAccount: keychainAccount(field))
            if let stored, !stored.isEmpty {
                setSecretValue(field, stored)
                continue
            }
            if let legacy = source[field] as? String, !legacy.isEmpty {
                setSecretValue(field, legacy)
                migrated = true
            }
        }
        let hasStored = ARDMConnectionConfig.boolValue(source["hasStoredSecret"]) ?? false
        if hasStored && auth.isEmpty && sshPassword.isEmpty
            && sshPassphrase.isEmpty && sentinelNodePassword.isEmpty {
            secretUnavailable = true
        }
        return migrated
    }

    /// Dictionary used for connections.json. Normally fully redacted; if the
    /// Keychain refused to store one of the secrets we fall back to keeping that
    /// single field in the file rather than silently losing the password.
    func persistenceDictionary() -> [String: Any] {
        var dict = toDictionary()
        var lostOne = false
        for field in ARDMConnectionConfig.secretFields {
            let value = secretValue(field)
            if value.isEmpty { continue }
            if !ARDMKeychain.hasSecret(forAccount: keychainAccount(field)) {
                dict[field] = value
                lostOne = true
            }
        }
        if lostOne { dict["hasStoredSecret"] = false }
        return dict
    }

    static func loadAll() -> [ARDMConnectionConfig] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storePath())),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let items = raw as? [Any] else { return [] }
        var out: [ARDMConnectionConfig] = []
        var needsMigration = false
        var migratedConnections = 0
        for item in items {
            guard let dict = item as? [String: Any] else { continue }
            let config = fromDictionary(dict)
            if config.hydrateSecrets(fromKeychain: dict) {
                needsMigration = true
                migratedConnections += 1
            }
            out.append(config)
        }
        // Rewrite once so legacy plaintext leaves connections.json immediately.
        if needsMigration {
            saveAll(out)
            keychainMigrationCount = migratedConnections
        }
        return out
    }

    static func consumeKeychainMigrationCount() -> Int {
        let count = keychainMigrationCount
        keychainMigrationCount = 0
        return count
    }

    static func saveAll(_ items: [ARDMConnectionConfig]) {
        var raw: [Any] = []
        for config in items {
            config.persistSecretsToKeychain()
            raw.append(config.persistenceDictionary())
        }
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted]) {
            let path = storePath()
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            // Only the owner should be able to read the (secret-free) config file.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    static func fromDictionary(_ d: [String: Any]) -> ARDMConnectionConfig {
        let c = ARDMConnectionConfig()
        if let v = d["identifier"] as? String { c.identifier = v }
        if let v = d["name"] as? String { c.name = v }
        if let v = d["host"] as? String { c.host = v }
        if let v = intValue(d["port"]) { c.port = v }
        if let v = d["auth"] as? String { c.auth = v }
        if let v = d["username"] as? String { c.username = v }
        if let v = intValue(d["db"]) { c.db = v }
        if let v = d["group"] as? String { c.group = v }
        if let v = d["separator"] as? String { c.separator = v }
        if let v = boolValue(d["readOnly"]) { c.readOnly = v }
        if let v = boolValue(d["cluster"]) { c.cluster = v }
        if let v = d["connectionName"] as? String { c.connectionName = v }
        if let v = boolValue(d["sshEnabled"]) { c.sshEnabled = v }
        if let v = d["sshHost"] as? String { c.sshHost = v }
        if let v = intValue(d["sshPort"]) { c.sshPort = v }
        if let v = d["sshUser"] as? String { c.sshUser = v }
        if let v = d["sshPassword"] as? String { c.sshPassword = v }
        if let v = d["sshPrivateKey"] as? String { c.sshPrivateKey = v }
        if let v = d["sshPassphrase"] as? String { c.sshPassphrase = v }
        if let v = intValue(d["sshTimeout"]) { c.sshTimeout = v }
        if let v = boolValue(d["tlsEnabled"]) { c.tlsEnabled = v }
        if let v = d["tlsCA"] as? String { c.tlsCA = v }
        if let v = d["tlsCert"] as? String { c.tlsCert = v }
        if let v = d["tlsKey"] as? String { c.tlsKey = v }
        if let v = d["tlsSNI"] as? String { c.tlsSNI = v }
        if let v = boolValue(d["tlsInsecure"]) { c.tlsInsecure = v }
        if let v = boolValue(d["sentinelEnabled"]) { c.sentinelEnabled = v }
        if let v = d["sentinelMaster"] as? String { c.sentinelMaster = v }
        if let v = d["sentinelNodePassword"] as? String { c.sentinelNodePassword = v }
        if let v = d["tlsIdentityPath"] as? String { c.tlsIdentityPath = v }
        if let v = boolValue(d["autoReconnect"]) { c.autoReconnect = v }
        if let v = intValue(d["connectTimeout"]) { c.connectTimeout = v }
        if let v = intValue(d["retryTimes"]) { c.retryTimes = v }
        if let v = intValue(d["sshKeepaliveInterval"]) { c.sshKeepaliveInterval = v }
        if let v = intValue(d["sshReadyTimeout"]) { c.sshReadyTimeout = v }
        if let v = boolValue(d["sshAutoClose"]) { c.sshAutoClose = v }
        if let map = d["natMap"] as? [String: String] { c.natMap = map }
        return c
    }

    /// Secrets live in the Keychain; this snapshot is safe to write to disk or
    /// export. hasStoredSecret lets the loader tell "no password" apart from
    /// "password exists but the Keychain refused access".
    func toDictionary() -> [String: Any] {
        let hasSecret = !auth.isEmpty || !sshPassword.isEmpty
            || !sshPassphrase.isEmpty || !sentinelNodePassword.isEmpty
        return [
            "identifier": identifier, "name": name, "host": host,
            "port": port, "auth": "", "username": username,
            "db": db, "group": group, "separator": separator,
            "readOnly": readOnly, "cluster": cluster,
            "connectionName": connectionName,
            "sshEnabled": sshEnabled, "sshHost": sshHost, "sshPort": sshPort,
            "sshUser": sshUser, "sshPassword": "",
            "sshPrivateKey": sshPrivateKey, "sshPassphrase": "",
            "sshTimeout": sshTimeout,
            "tlsEnabled": tlsEnabled, "tlsCA": tlsCA, "tlsCert": tlsCert,
            "tlsKey": tlsKey, "tlsSNI": tlsSNI, "tlsInsecure": tlsInsecure,
            "sentinelEnabled": sentinelEnabled, "sentinelMaster": sentinelMaster,
            "sentinelNodePassword": "",
            "natMap": natMap, "tlsIdentityPath": tlsIdentityPath,
            "autoReconnect": autoReconnect,
            "connectTimeout": connectTimeout,
            "retryTimes": retryTimes,
            "sshKeepaliveInterval": sshKeepaliveInterval,
            "sshReadyTimeout": sshReadyTimeout,
            "sshAutoClose": sshAutoClose,
            "hasStoredSecret": hasSecret || secretUnavailable,
        ]
    }

    // MARK: - JSON coercion (mirrors the ObjC STR/NUM/BOOLV macros)

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return (s as NSString).boolValue }
        return nil
    }
}
