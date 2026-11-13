import Foundation

// MARK: - Advanced commands for module-backed key types
// Mirrors the extra operations in KeyContentVector / TimeSeries / Array / Stream.

struct ModuleAction: Identifiable {
    let id = UUID()
    let title: String
    let prompt: String?
    let build: (String, String) -> [String]
}

extension AppStore {

    func moduleActions() -> [ModuleAction] {
        guard let _ = selectedKey else { return [] }
        switch selectedKeyType {
        case .vector:
            return [
                ModuleAction(title: "VINFO", prompt: nil) { key, _ in ["VINFO", key] },
                ModuleAction(title: "VRANDMEMBER", prompt: nil) { key, _ in
                    ["VRANDMEMBER", key, "10", "WITHATTRIBS"]
                },
                ModuleAction(title: "VRANGE", prompt: "Start index (e.g. 0)") { key, input in
                    let start = input.isEmpty ? "0" : input
                    return ["VRANGE", key, start, "-1", "WITHATTRIBS"]
                },
                ModuleAction(title: "VSIM", prompt: "Vector values (comma separated)") { key, input in
                    let values = input.split(separator: ",").map(String.init)
                    return ["VSIM", key, "VALUES", "\(values.count)"] + values + ["WITHSCORES", "10"]
                },
                ModuleAction(title: "VADD (quantised)", prompt: "Element id, vector values (comma separated)") { key, input in
                    let parts = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count > 1 else { return ["VINFO", key] }
                    return ["VADD", key, "NOQUANT", "\(parts.count - 1)"] + Array(parts.dropFirst()) + [parts[0]]
                },
                ModuleAction(title: "VSETATTR", prompt: "element id, JSON attributes") { key, input in
                    let parts = input.split(separator: ",", maxSplits: 1).map(String.init)
                    return ["VSETATTR", key, parts.first ?? "", parts.count > 1 ? parts[1] : "{}"]
                },
                ModuleAction(title: "VREM", prompt: "Element id") { key, input in ["VREM", key, input] }
            ]

        case .timeSeries:
            return [
                ModuleAction(title: "TS.INFO", prompt: nil) { key, _ in ["TS.INFO", key] },
                ModuleAction(title: "TS.GET", prompt: nil) { key, _ in ["TS.GET", key] },
                ModuleAction(title: "TS.REVRANGE", prompt: nil) { key, _ in
                    ["TS.REVRANGE", key, "-", "+", "COUNT", "\(self.rowLimit)"]
                },
                ModuleAction(title: "TS.CREATE", prompt: "Retention ms (0 = none)") { key, input in
                    let retention = Int(input) ?? 0
                    return retention > 0 ? ["TS.CREATE", key, "RETENTION", "\(retention)"] : ["TS.CREATE", key]
                },
                ModuleAction(title: "TS.ALTER", prompt: "New retention ms") { key, input in
                    ["TS.ALTER", key, "RETENTION", "\(Int(input) ?? 0)"]
                },
                ModuleAction(title: "TS.DEL", prompt: "From timestamp, to timestamp") { key, input in
                    let parts = input.split(separator: ",").map(String.init)
                    return ["TS.DEL", key, parts.first ?? "-", parts.count > 1 ? parts[1] : "+"]
                },
                ModuleAction(title: "TS.INCRBY", prompt: "Value") { key, input in
                    ["TS.INCRBY", key, input.isEmpty ? "1" : input]
                },
                ModuleAction(title: "TS.DECRBY", prompt: "Value") { key, input in
                    ["TS.DECRBY", key, input.isEmpty ? "1" : input]
                },
                ModuleAction(title: "TS.QUERYINDEX", prompt: "Label filter (e.g. area=3)") { key, input in
                    ["TS.QUERYINDEX", input.isEmpty ? "area=3" : input]
                }
            ]

        case .array:
            return [
                ModuleAction(title: "ARINFO", prompt: nil) { key, _ in ["ARINFO", key] },
                ModuleAction(title: "ARLEN", prompt: nil) { key, _ in ["ARLEN", key] },
                ModuleAction(title: "ARSCAN", prompt: "Cursor (0 to start)") { key, input in
                    ["ARSCAN", key, input.isEmpty ? "0" : input, "COUNT", "\(self.rowLimit)"]
                },
                ModuleAction(title: "ARGREP", prompt: "Glob pattern") { key, input in
                    ["ARGREP", key, input.isEmpty ? "*" : input]
                },
                ModuleAction(title: "ARSET", prompt: "Index, value") { key, input in
                    let parts = input.split(separator: ",", maxSplits: 1).map(String.init)
                    return ["ARSET", key, parts.first ?? "0", parts.count > 1 ? parts[1] : ""]
                },
                ModuleAction(title: "ARDEL", prompt: "Index") { key, input in ["ARDEL", key, input] }
            ]

        case .stream:
            return [
                ModuleAction(title: "XINFO STREAM", prompt: nil) { key, _ in ["XINFO", "STREAM", key] },
                ModuleAction(title: "XINFO GROUPS", prompt: nil) { key, _ in ["XINFO", "GROUPS", key] },
                ModuleAction(title: "XINFO CONSUMERS", prompt: "Group name") { key, input in
                    ["XINFO", "CONSUMERS", key, input.isEmpty ? "ardm-group" : input]
                },
                ModuleAction(title: "XPENDING", prompt: "Group name") { key, input in
                    ["XPENDING", key, input.isEmpty ? "ardm-group" : input]
                },
                ModuleAction(title: "XTRIM MAXLEN", prompt: "Max length") { key, input in
                    ["XTRIM", key, "MAXLEN", "\(Int(input) ?? 1000)"]
                },
                ModuleAction(title: "XGROUP CREATECONSUMER", prompt: "Group, consumer") { key, input in
                    let parts = input.split(separator: ",").map(String.init)
                    return ["XGROUP", "CREATECONSUMER", key,
                            parts.first ?? "ardm-group", parts.count > 1 ? parts[1] : "ardm"]
                },
                ModuleAction(title: "XACK", prompt: "Group, id") { key, input in
                    let parts = input.split(separator: ",").map(String.init)
                    return ["XACK", key, parts.first ?? "ardm-group", parts.count > 1 ? parts[1] : "0-0"]
                }
            ]

        default:
            return []
        }
    }

    /// Human-readable time for a Stream entry ID (milliseconds part).
    func formattedStreamDate(_ id: String) -> String? {
        guard let raw = id.split(separator: "-").first, let millis = Double(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = .current
        return formatter.string(from: Date(timeIntervalSince1970: millis / 1000))
    }
}
