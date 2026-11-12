import SwiftUI
import AppKit

// MARK: - CLI (CliTab.vue / CliContent.vue / commands.js)

struct CLIView: View {
    @EnvironmentObject var store: AppStore
    @State private var referenceQuery = ""
    @State private var showingReference = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n("Redis CLI")).font(.headline)
                Spacer()
                Text("\(store.commandReference.count) commands loaded from commands.js")
                    .font(.caption).foregroundStyle(.secondary)
                Button(showingReference ? "Hide reference" : "Show reference") { showingReference.toggle() }
            }
            .padding(10)

            HStack(spacing: 8) {
                TextField(L10n("Enter a Redis command, e.g. HGETALL myhash"), text: $store.cliInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: store.scaled(store.fontSize), design: .monospaced))
                    .onSubmit { store.runCLI() }
                Button(L10n("Run")) { store.runCLI() }.buttonStyle(.borderedProminent)
                Button(L10n("↑")) { store.previousCLICommand() }.help(L10n("Previous command"))
                Button(L10n("↓")) { store.nextCLICommand() }.help(L10n("Next command"))
                Button(L10n("Clear")) { store.cliOutput = "" }
            }
            .padding(.horizontal, 10)

            if !store.cliInput.isEmpty && !store.completions(for: store.cliInput).isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.completions(for: store.cliInput), id: \.self) { candidate in
                            Button(candidate) { store.cliInput = candidate + " " }
                                .font(.system(size: 11, design: .monospaced))
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }

            HSplitView {
                ScrollView {
                    Text(highlighted(store.cliOutput.isEmpty ? "Results appear here." : store.cliOutput,
                                     size: store.scaled(store.fontSize)))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .border(Color.secondary.opacity(0.25))
                .frame(minWidth: 320)

                if showingReference {
                    VStack(spacing: 4) {
                        TextField(L10n("Filter commands"), text: $referenceQuery)
                            .textFieldStyle(.roundedBorder).padding(6)
                        List(filteredCommands, id: \.self) { name in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text(store.commandSignature(name).replacingOccurrences(of: "\n", with: " · "))
                                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .onTapGesture { store.cliInput = name + " " }
                        }
                    }
                    .frame(minWidth: 250)
                }
            }
            .padding(8)
        }
    }

    private var filteredCommands: [String] {
        let names = store.commandNames()
        guard !referenceQuery.isEmpty else { return Array(names.prefix(300)) }
        return names.filter { $0.localizedCaseInsensitiveContains(referenceQuery) }
    }
}

// MARK: - Status (Status.vue) with INFO charts

struct StatusView: View {
    @EnvironmentObject var store: AppStore
    @State private var autoRefresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n("Server Status")).font(.headline)
                Spacer()
                Text("every \(store.statusRefreshSeconds)s").font(.caption)
                Stepper("", value: $store.statusRefreshSeconds, in: 1...60).labelsHidden()
                Toggle(L10n("Auto refresh"), isOn: $autoRefresh).toggleStyle(.switch)
                Button(L10n("Refresh")) { store.loadStatus() }
                Button(L10n("DBSIZE")) { store.execute(["DBSIZE"]) }
            }
            .padding(10)

            if let hits = chartValues(prefix: "keyspace_hits"), let misses = chartValues(prefix: "keyspace_misses") {
                HitRateChart(hits: hits, misses: misses)
                    .padding(.horizontal, 12)
            }

            List {
                ForEach(store.infoSections) { section in
                    Section(section.name) {
                        ForEach(section.fields, id: \.0) { key, value in
                            HStack {
                                Text(key).font(.system(size: 11, design: .monospaced)).frame(width: 240, alignment: .leading)
                                Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .onAppear { store.loadStatus() }
    }

    private func chartValues(prefix: String) -> Double? {
        for section in store.infoSections {
            for (key, value) in section.fields where key == prefix { return Double(value) }
        }
        return nil
    }
}

struct HitRateChart: View {
    let hits: Double
    let misses: Double
    var body: some View {
        let total = max(1, hits + misses)
        VStack(alignment: .leading, spacing: 4) {
            Text("Cache hit rate: \(String(format: "%.1f%%", hits / total * 100))").font(.caption)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.green).frame(width: geo.size.width * hits / total)
                    Rectangle().fill(Color.red).frame(width: geo.size.width * misses / total)
                }
            }
            .frame(height: 10).cornerRadius(4)
        }
    }
}

// MARK: - Slow log (SlowLog.vue)

struct SlowLogView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack {
            HStack {
                Text(L10n("Slow Log")).font(.headline)
                Spacer()
                Button(L10n("Refresh")) { store.loadSlowLog() }
                Button(L10n("RESET")) { store.execute(["SLOWLOG", "RESET"]); store.loadSlowLog() }
            }.padding(10)
            List(store.slowLogRows.indices, id: \.self) { index in
                let row = store.slowLogRows[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(index) · \(row.first ?? "") · \(row.count > 1 ? row[1] : "") µs")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text(row.dropFirst(2).joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { store.loadSlowLog() }
    }
}

// MARK: - Memory analysis (MemoryAnalysis.vue)

struct MemoryView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(L10n("Memory Analysis")).font(.headline)
                Spacer()
                Button(L10n("Refresh")) { store.loadMemory() }
                Button(L10n("MEMORY DOCTOR")) { store.execute(["MEMORY", "DOCTOR"]) }
            }.padding(10)
            let maximum = max(1, store.memoryStats.map { $0.1 }.max() ?? 1)
            List(store.memoryStats.indices, id: \.self) { index in
                let item = store.memoryStats[index]
                HStack {
                    Text(item.0).font(.system(size: 11, design: .monospaced)).frame(width: 260, alignment: .leading)
                    GeometryReader { geo in
                        Rectangle().fill(Color.accentColor)
                            .frame(width: max(2, geo.size.width * item.1 / maximum), height: 8)
                    }
                    Text(String(format: "%.0f", item.1)).font(.system(size: 10, design: .monospaced)).frame(width: 100, alignment: .trailing)
                }
            }
        }
        .onAppear { store.loadMemory() }
    }
}

// MARK: - Cluster topology (Cluster SLOTS / NODES + NAT map)

struct ClusterView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(L10n("Cluster Topology")).font(.headline)
                Spacer()
                Button(L10n("Refresh")) { store.loadClusterTopology() }
                Button(L10n("CLUSTER INFO")) { store.execute(["CLUSTER", "INFO"]) }
            }.padding(10)
            if !store.connected {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.3x3").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(L10n("Not connected")).font(.headline)
                    Text(L10n("Connect to a Redis Cluster to inspect its topology."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section(L10n("Slot ranges")) {
                        ForEach(store.clusterSlots.indices, id: \.self) { index in
                            let slot = store.clusterSlots[index]
                            HStack {
                                Text("\(ardmString(slot["start"])) – \(ardmString(slot["end"]))")
                                    .font(.system(size: 11, design: .monospaced)).frame(width: 140, alignment: .leading)
                                Text(ardmString(slot["master"])).font(.system(size: 11, design: .monospaced))
                                Spacer()
                            }
                        }
                    }
                    Section(L10n("Nodes")) {
                        ForEach(store.clusterNodes.indices, id: \.self) { index in
                            let node = store.clusterNodes[index]
                            HStack {
                                Text(ardmString(node["id"])).font(.system(size: 10, design: .monospaced)).frame(width: 200, alignment: .leading)
                                Text(ardmString(node["address"])).font(.system(size: 10, design: .monospaced)).frame(width: 160, alignment: .leading)
                                Text(ardmString(node["flags"])).font(.system(size: 10, design: .monospaced))
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .onAppear { if store.connected { store.loadClusterTopology() } }
    }
}

// MARK: - Pub/Sub + MONITOR (startLiveWithCommand)

struct PubSubView: View {
    @EnvironmentObject var store: AppStore
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n("Pub/Sub")).font(.headline)
                Spacer()
                Toggle(L10n("Pattern (PSUBSCRIBE)"), isOn: $store.pubsubPattern).toggleStyle(.switch)
            }
            HStack {
                TextField(L10n("Channel or pattern"), text: $store.pubsubChannel).textFieldStyle(.roundedBorder)
                Button(L10n("Subscribe")) { store.startPubSub() }.buttonStyle(.borderedProminent)
                Button(L10n("Stop")) { store.stopLive() }
            }
            HStack {
                TextField(L10n("Message"), text: $message).textFieldStyle(.roundedBorder)
                Button(L10n("PUBLISH")) { store.publish(store.pubsubChannel, message) }
            }
            LiveEventList()
        }
        .padding(12)
    }
}

struct MonitorView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n("MONITOR")).font(.headline)
                Spacer()
                Button(L10n("Start")) { store.startMonitor() }.buttonStyle(.borderedProminent)
                Button(L10n("Stop")) { store.stopLive() }
                Text(store.liveRunning ? "● streaming" : "stopped").font(.caption)
                    .foregroundStyle(store.liveRunning ? .green : .secondary)
            }
            LiveEventList()
        }
        .padding(12)
    }
}

struct LiveEventList: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        List(store.liveEvents) { event in
            HStack(alignment: .top) {
                Text(event.time, style: .time).font(.system(size: 9, design: .monospaced)).frame(width: 70, alignment: .leading)
                Text(event.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .border(Color.secondary.opacity(0.25))
    }
}

// MARK: - Command log (CommandLog.vue)

struct CommandLogView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    var body: some View {
        VStack {
            HStack {
                Text(L10n("Command Log")).font(.headline)
                Spacer()
                TextField(L10n("Filter"), text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                Button(L10n("Copy all")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(filtered.map { $0.command }.joined(separator: "\n"), forType: .string)
                }
                Button(L10n("Clear")) { store.logs.removeAll() }
            }.padding(10)
            List(filtered) { entry in
                HStack {
                    Text(entry.time, style: .time).font(.system(size: 10, design: .monospaced)).frame(width: 90, alignment: .leading)
                    Text(entry.connection).font(.system(size: 10)).frame(width: 120, alignment: .leading)
                    Text(entry.command).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f ms", entry.cost)).font(.system(size: 10, design: .monospaced))
                }
            }
        }
    }

    private var filtered: [LogEntry] {
        guard !query.isEmpty else { return store.logs }
        return store.logs.filter { $0.command.localizedCaseInsensitiveContains(query) }
    }
}
