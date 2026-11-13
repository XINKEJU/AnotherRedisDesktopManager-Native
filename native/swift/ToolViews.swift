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
                    .font(store.monoFont(store.fontSize))
                    .accessibilityLabel(L10n("Command input"))
                    .accessibilityIdentifier("cli.input")
                    .onSubmit { store.runCLI() }
                Button(L10n("Run")) { store.runCLI() }.buttonStyle(.borderedProminent)
                // "↑" / "↓" are read as punctuation, so give the history steppers words.
                Button(L10n("↑")) { store.previousCLICommand() }
                    .help(L10n("Previous command"))
                    .accessibilityLabel(L10n("Previous command"))
                Button(L10n("↓")) { store.nextCLICommand() }
                    .help(L10n("Next command"))
                    .accessibilityLabel(L10n("Next command"))
                Button(L10n("Clear")) { store.cliOutput = "" }
            }
            .padding(.horizontal, 10)

            if !store.cliInput.isEmpty && !store.completions(for: store.cliInput).isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.completions(for: store.cliInput), id: \.self) { candidate in
                            Button(candidate) { store.cliInput = candidate + " " }
                                .font(store.monoFont(11))
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
                                Text(name).font(store.monoFont(11, weight: .semibold))
                                Text(store.commandSignature(name).replacingOccurrences(of: "\n", with: " · "))
                                    .font(store.uiFont(9)).foregroundStyle(.secondary).lineLimit(2)
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
    @State private var sortAscending = true
    @State private var sectionFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n("Server Status")).font(.headline)
                Spacer()
                TextField(L10n("Filter"), text: $sectionFilter)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
                Button {
                    sortAscending.toggle()
                } label: {
                    Label(sortAscending ? L10n("A→Z") : L10n("Z→A"), systemImage: sortAscending ? "arrow.up" : "arrow.down")
                }
                Text("every \(store.statusRefreshSeconds)s").font(.caption)
                Stepper("", value: $store.statusRefreshSeconds, in: 1...60).labelsHidden()
                    .accessibilityLabel(L10n("Refresh interval"))
                    .onChange(of: store.statusRefreshSeconds) {
                        if store.statusAutoRefresh { store.startStatusTimer() }
                    }
                Toggle(L10n("Auto refresh"), isOn: $store.statusAutoRefresh)
                    .toggleStyle(.switch)
                    .onChange(of: store.statusAutoRefresh) {
                        if store.statusAutoRefresh { store.startStatusTimer() } else { store.stopStatusTimer() }
                    }
                Button(L10n("Refresh")) { store.loadStatus() }
                Button(L10n("DBSIZE")) { store.execute(["DBSIZE"]) }
            }
            .padding(10)

            if let hits = chartValues(prefix: "keyspace_hits"), let misses = chartValues(prefix: "keyspace_misses") {
                HitRateChart(hits: hits, misses: misses)
                    .padding(.horizontal, 12)
            }

            List {
                if !store.keyspaceStats.isEmpty {
                    Section(L10n("Keyspace")) {
                        ForEach(store.keyspaceStats, id: \.0) { db, stats in
                            HStack {
                                Text(db).font(store.monoFont(11)).frame(width: 80, alignment: .leading)
                                Text(stats).font(store.monoFont(11)).textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                }
                ForEach(filteredSections) { section in
                    Section(section.name) {
                        ForEach(sortedFields(section), id: \.0) { key, value in
                            HStack {
                                Text(key).font(store.monoFont(11)).frame(width: 240, alignment: .leading)
                                Text(value).font(store.monoFont(11)).textSelection(.enabled)
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

    private var filteredSections: [InfoSection] {
        guard !sectionFilter.isEmpty else { return store.infoSections }
        return store.infoSections.filter { section in
            section.name.localizedCaseInsensitiveContains(sectionFilter)
                || section.fields.contains { $0.0.localizedCaseInsensitiveContains(sectionFilter) }
        }
    }

    private func sortedFields(_ section: InfoSection) -> [(String, String)] {
        section.fields.sorted { sortAscending ? $0.0 < $1.0 : $0.0 > $1.0 }
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
                Text("log-slower-than \(store.slowLogSlowerThan) µs · max-len \(store.slowLogMaxLen)")
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n("Refresh")) { store.loadSlowLog() }
                Button(L10n("RESET")) { store.execute(["SLOWLOG", "RESET"]); store.loadSlowLog() }
            }.padding(10)
            List(store.slowLogRows.indices, id: \.self) { index in
                let row = store.slowLogRows[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(index) · \(row.first ?? "") · \(row.count > 1 ? row[1] : "") µs")
                        .font(store.monoFont(11, weight: .semibold))
                    Text(row.dropFirst(2).joined(separator: " "))
                        .font(store.monoFont(10)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { store.loadSlowLog() }
    }
}

// MARK: - Memory analysis (MemoryAnalysis.vue)

struct MemoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var selection = 0

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(L10n("Memory Analysis")).font(.headline)
                Picker("", selection: $selection) {
                    Text(L10n("Aggregate")).tag(0)
                    Text(L10n("Per key")).tag(1)
                }
                .pickerStyle(.segmented).frame(width: 200).labelsHidden()
                .accessibilityLabel(L10n("Memory analysis mode"))
                Spacer()
                if selection == 1 {
                    Text(L10n("Min bytes")).font(.caption)
                    TextField("", value: $store.memoryMinSize, format: .number).frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n("Min bytes"))
                    if store.memoryScanRunning {
                        ProgressView(value: Double(store.memoryScanned),
                                     total: Double(max(1, store.memoryScanTotal)))
                            .frame(width: 120)
                        Text("\(store.memoryScanned)").font(.caption2).foregroundStyle(.secondary)
                        Button(L10n("Cancel")) { store.cancelMemoryScan() }
                    } else {
                        Button(L10n("Scan")) { store.loadMemoryPerKey() }
                    }
                }
                Button(L10n("Refresh")) { store.loadMemory() }
                Button(L10n("MEMORY DOCTOR")) { store.execute(["MEMORY", "DOCTOR"]) }
            }.padding(10)

            if selection == 0 {
                let maximum = max(1, store.memoryStats.map { $0.1 }.max() ?? 1)
                List(store.memoryStats.indices, id: \.self) { index in
                    let item = store.memoryStats[index]
                    HStack {
                        Text(item.0).font(store.monoFont(11)).frame(width: 260, alignment: .leading)
                        GeometryReader { geo in
                            Rectangle().fill(Color.accentColor)
                                .frame(width: max(2, geo.size.width * item.1 / maximum), height: 8)
                        }
                        Text(String(format: "%.0f", item.1)).font(store.monoFont(10)).frame(width: 100, alignment: .trailing)
                    }
                }
            } else {
                if store.memoryPerKeyRows.isEmpty {
                    Text(L10n("Click Scan to measure every key with MEMORY USAGE."))
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
                let maximumKey = max(1, store.memoryPerKeyRows.map { $0.1 }.max() ?? 1)
                List(store.memoryPerKeyRows.indices, id: \.self) { index in
                    let item = store.memoryPerKeyRows[index]
                    HStack {
                        Text(item.0).font(store.monoFont(11)).frame(width: 260, alignment: .leading)
                        GeometryReader { geo in
                            Rectangle().fill(Color.orange)
                                .frame(width: max(2, geo.size.width * Double(item.1) / Double(maximumKey)), height: 8)
                        }
                        Text("\(item.1) B").font(store.monoFont(10)).frame(width: 100, alignment: .trailing)
                    }
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
                    Image(systemName: "square.grid.3x3").font(store.uiFont(36)).foregroundStyle(.tertiary)
                    Text(L10n("Not connected")).font(.headline)
                    Text(L10n("Connect to a Redis Cluster to inspect its topology."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.activeClusterMode {
                // Sending CLUSTER SLOTS to a standalone server answers
                // "ERR This instance has cluster support disabled", which used to
                // surface as a modal error alert just for opening this tab.
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.3x3").font(store.uiFont(36)).foregroundStyle(.tertiary)
                    Text(L10n("This connection is not in cluster mode.")).font(.headline)
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
                                    .font(store.monoFont(11)).frame(width: 140, alignment: .leading)
                                Text(ardmString(slot["master"])).font(store.monoFont(11))
                                Spacer()
                            }
                        }
                    }
                    Section(L10n("Nodes")) {
                        ForEach(store.clusterNodes.indices, id: \.self) { index in
                            let node = store.clusterNodes[index]
                            HStack {
                                Text(ardmString(node["id"])).font(store.monoFont(10)).frame(width: 200, alignment: .leading)
                                Text(ardmString(node["address"])).font(store.monoFont(10)).frame(width: 160, alignment: .leading)
                                Text(ardmString(node["flags"])).font(store.monoFont(10))
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if store.connected && store.activeClusterMode {
                store.loadClusterTopology()
            }
        }
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
                Text(event.time, style: .time).font(store.monoFont(9)).frame(width: 70, alignment: .leading)
                Text(event.text).font(store.monoFont(11)).textSelection(.enabled)
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
                    Text(entry.time, style: .time).font(store.monoFont(10)).frame(width: 90, alignment: .leading)
                    Text(entry.connection).font(store.uiFont(10)).frame(width: 120, alignment: .leading)
                    Text(entry.command).font(store.monoFont(11)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f ms", entry.cost)).font(store.monoFont(10))
                }
            }
        }
    }

    private var filtered: [LogEntry] {
        guard !query.isEmpty else { return store.logs }
        return store.logs.filter { $0.command.localizedCaseInsensitiveContains(query) }
    }
}
