import SwiftUI
import AppKit

// MARK: - Settings (Setting.vue / LanguageSelector.vue / UpdateCheck.vue / font-manager.js)

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var checkingUpdate = false
    @State private var pendingArchive: URL?
    @State private var confirmInstall = false

    /// Remembers the last visited section so reopening Settings lands where the
    /// user left off instead of always resetting to Appearance.
    @State private var section: Section = Section(storedTab: UserDefaults.standard.integer(forKey: "ARDMSettingsTab"))

    /// The five panes, in sidebar order. The raw value keeps the persisted
    /// `ARDMSettingsTab` integer meaningful across the change from a segmented
    /// picker to a list.
    enum Section: Int, CaseIterable, Identifiable {
        case appearance, keys, viewers, connections, about

        var id: Int { rawValue }

        init(storedTab: Int) {
            // 0…3 are the old picker's indices and name the same four panes;
            // the 连接 pane has no predecessor.
            self = Section(rawValue: min(max(storedTab, 0), 4)) ?? .appearance
        }

        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .keys: return "Keys"
            case .viewers: return "Viewers"
            case .connections: return "Connections"
            case .about: return "About & Updates"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "paintbrush.pointed"
            case .keys: return "key.horizontal"
            case .viewers: return "eye"
            case .connections: return "network"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                content
            }
            Divider()
            footer
        }
        // One size for every pane. The height used to follow the content, so
        // switching 外观 → 格式视图 grew the sheet by 145pt and everything behind
        // it jumped — and the tallest pane scrolled anyway.
        .frame(width: 720, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: section) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: "ARDMSettingsTab")
        }
    }

    // MARK: Sidebar

    /// System-Settings-style section list, replacing the segmented picker that
    /// shared the title row: four 88pt segments, one of which clipped
    /// 「关于与更新」 to 「关于与更…」, and no room for a fifth pane.
    private var sidebar: some View {
        List(selection: $section) {
            ForEach(Section.allCases) { item in
                Label(L10n(item.title), systemImage: item.symbol)
                    .font(.system(size: ARDMFont.body))
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 180)
        .accessibilityLabel(L10n("Settings"))
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n(section.title))
                .font(.system(size: ARDMFont.title, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch section {
                    case .appearance: appearancePane
                    case .keys: keysPane
                    case .viewers: viewersPane
                    case .connections: connectionsPane
                    case .about: aboutPane
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// A caption over a bordered card of grid-aligned rows.
    @ViewBuilder
    private func group<C: View>(_ caption: String? = nil, @ViewBuilder rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption {
                Text(L10n(caption))
                    .font(.system(size: ARDMFont.small, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { rows() }
                .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Appearance

    private var appearancePane: some View {
        Group {
            group {
                SettingsRow("Theme") {
                    Picker("", selection: $store.theme) {
                        Text(L10n("Follow system")).tag("system")
                        Text(L10n("Light")).tag("light")
                        Text(L10n("Dark")).tag("dark")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                RowDivider()
                SettingsRow("Language") {
                    Picker("", selection: $store.language) {
                        ForEach(store.languages, id: \.self) { code in
                            Text("\(code.uppercased()) — \(languageName(code))").tag(code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: store.language) { _, newValue in
                        ARDMLocalization.shared().currentLanguage = newValue
                    }
                }
                RowDivider()
                SettingsRow("Font family") {
                    Picker("", selection: $store.fontFamily) {
                        ForEach(store.fonts, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            group("Text and layout") {
                SettingsRow("Font size") {
                    Stepper(value: $store.fontSize, in: 9...24) {
                        Text("\(Int(store.fontSize)) pt")
                            .font(.system(size: ARDMFont.body, design: .monospaced))
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
                Footnote("Applies to the three columns as you change it")
                RowDivider()
                SettingsRow("Zoom") {
                    ValueSlider(value: $store.zoom, range: 0.7...1.6, step: 0.1) {
                        Text(String(format: "%.1f×", store.zoom))
                    }
                }
                RowDivider()
                SettingsRow("Sidebar width") {
                    ValueSlider(value: $store.sidebarWidth, range: 200...520, step: 10) {
                        Text("\(Int(store.sidebarWidth)) px")
                    }
                }
            }
        }
    }

    // MARK: Keys

    private var keysPane: some View {
        Group {
            group("Browsing") {
                SettingsRow("Keys per SCAN page") {
                    Stepper(value: $store.pageSize, in: 50...5000, step: 50) {
                        Text("\(store.pageSize)")
                            .font(.system(size: ARDMFont.body, design: .monospaced))
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
                RowDivider()
                SettingsRow("Key tree separator") {
                    TextField("", text: $store.separator)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: ardmScaled(70))
                        .onChange(of: store.separator) { _, _ in store.buildTree() }
                }
            }

            // The database picker used to live here as well. It switched the
            // middle column, which the breadcrumb and the sidebar already do,
            // and left this pane showing a DB that was not the one on screen.
            group("Behaviour") {
                SettingsRow("Use tree view") {
                    SettingsSwitch(isOn: $store.showTree)
                }
                RowDivider()
                SettingsRow("Read-only mode") {
                    SettingsSwitch(isOn: $store.readOnly)
                }
                Footnote("Read-only is enforced in the RESP client before any command is written.")
                RowDivider()
                LinkRow {
                    Button(L10n("Keyboard Shortcuts…")) { store.showingHotKeys = true }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Viewers

    private var viewersPane: some View {
        Group {
            group("Default viewer") {
                SettingsRow("Viewer") {
                    Picker("", selection: $store.viewerName) {
                        ForEach(store.viewers, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                RowDivider()
                SettingsRow("Formatters") {
                    HStack(spacing: 10) {
                        Text("\(store.customFormatters.count) " + L10n("saved formatters"))
                            .font(.system(size: ARDMFont.small))
                            .foregroundStyle(.secondary)
                        Button(L10n("Manage formatters…")) { store.showingFormatterManager = true }
                            .controlSize(.small)
                    }
                }
            }

            group("Custom script") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n("Custom viewer JavaScript (JavaScriptCore; `bytes` is a Uint8Array):"))
                        .font(.system(size: ARDMFont.small))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $store.customViewerScript)
                        .font(store.monoFont(ARDMFont.monoRow))
                        .frame(height: ardmScaled(96))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    Button(L10n("Test on current value")) {
                        store.viewerName = "Custom"
                        store.renderValue()
                    }
                    .controlSize(.small)
                }
                .padding(14)
            }

            // The full viewer list used to be a four-line gray paragraph at the
            // bottom of the pane. One line here, the detail still reachable.
            DisclosureGroup {
                Text(L10n("All 15 viewers (Text, Hex, Json, Binary, Msgpack, PHPSerialize, JavaSerialize, Pickle, Brotli, Gzip, Deflate, DeflateRaw, Protobuf, OverSize, Custom) are implemented with Foundation / zlib / JavaScriptCore."))
                    .font(.system(size: ARDMFont.small))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Text(L10n("Viewers are built on Foundation, zlib and JavaScriptCore."))
                    .font(.system(size: ARDMFont.small))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Connections

    private var connectionsPane: some View {
        group {
            LinkRow {
                Button(L10n("Import / Export…")) { store.showingImportExport = true }
                    .controlSize(.small)
            }
            Footnote("Passwords are stored in the macOS Keychain, never in connections.json.")
        }
    }

    // MARK: About & updates

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            group {
                InfoRow(L10n("Application"), "Another Redis Desktop Manager (Native)")
                RowDivider()
                InfoRow(L10n("Version"),
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7.4")
                RowDivider()
                InfoRow(L10n("UI"), "SwiftUI + AppKit")
                RowDivider()
                InfoRow(L10n("Redis protocol"), "RESP2 · RESP3 reply types")
                RowDivider()
                InfoRow(L10n("Localization"), "\(store.languages.count) " + L10n("languages"))
            }

            group("Updates") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button(L10n("Check for Updates")) {
                            checkingUpdate = true
                            ARDMAppServices.checkForUpdate { status, url in
                                checkingUpdate = false
                                store.updateStatus = status
                                if let url, UserDefaults.standard.bool(forKey: "ARDMOpenReleaseOnUpdate") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        .controlSize(.small)
                        .disabled(checkingUpdate)
                        Button(L10n("Download & verify")) {
                            checkingUpdate = true
                            store.updateStatus = L10n("Downloading…")
                            ARDMAppServices.downloadUpdate { status, file in
                                checkingUpdate = false
                                store.updateStatus = status
                                guard let file else { return }
                                pendingArchive = file
                                confirmInstall = true      // never replace the app without an explicit OK
                            }
                        }
                        .controlSize(.small)
                        .disabled(checkingUpdate || ARDMAppServices.pendingUpdateVersion() == nil)
                        if checkingUpdate {
                            ProgressView().controlSize(.small)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: ardmScaled(14)) {
                        Text(L10n("Open release page when available"))
                            .font(.system(size: ARDMFont.body))
                            .frame(width: settingsLabelWidth, alignment: .leading)
                        SettingsSwitch(isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "ARDMOpenReleaseOnUpdate") },
                            set: { UserDefaults.standard.set($0, forKey: "ARDMOpenReleaseOnUpdate") }))
                        Spacer(minLength: 0)
                    }

                    if let version = ARDMAppServices.pendingUpdateVersion() {
                        Text(L10n("Pending:") + " \(version) · "
                             + (ARDMAppServices.pendingUpdateHasChecksum()
                                ? L10n("SHA-256 available")
                                : L10n("no SHA-256 published")))
                            .font(.system(size: ARDMFont.small))
                            .foregroundStyle(.secondary)
                    }

                    Text(store.updateStatus.isEmpty ? L10n("No update check has been run yet.") : store.updateStatus)
                        .font(.system(size: ARDMFont.small))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .alert(L10n("Install this update?"), isPresented: $confirmInstall) {
                    Button(L10n("Cancel"), role: .cancel) { pendingArchive = nil }
                    Button(L10n("Install and relaunch")) { installPendingUpdate() }
                } message: {
                    Text(installPrompt)
                }
            }

            DisclosureGroup {
                Text(L10n("External / conditional capabilities: Brotli viewer needs the system `brotli` CLI; RedisJSON / TimeSeries / Vector / Array views need the corresponding Redis modules; mutual TLS needs a PKCS#12 or PEM client identity."))
                    .font(.system(size: ARDMFont.small))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Text(L10n("Some viewers and features need extra components."))
                    .font(.system(size: ARDMFont.small))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Footer

    /// Only Close. The three links that shared this row each belong to a pane
    /// and now sit inside it, next to the settings they relate to.
    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n("Close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .frame(height: ardmScaled(44))
    }

    // MARK: Update install

    private var installPrompt: String {
        let version = ARDMAppServices.pendingUpdateVersion() ?? "?"
        let trust = ARDMAppServices.pendingUpdateHasChecksum()
            ? L10n("The archive's SHA-256 matches the published checksum.")
            : L10n("No checksum published; only the code signature can be verified.")
        return L10n("The app in /Applications will be replaced.")
            + " " + L10n("Version") + ": \(version). "
            + L10n("The current version is kept as .previous for rollback.")
            + "\n" + trust
    }

    private func installPendingUpdate() {
        guard let archive = pendingArchive else { return }
        checkingUpdate = true
        store.updateStatus = L10n("Verifying the signature and swapping the app…")
        ARDMAppServices.installUpdate(archive) { status in
            checkingUpdate = false
            store.updateStatus = status
            pendingArchive = nil
        }
    }

    private func languageName(_ code: String) -> String {
        languageDisplayName(code)
    }
}

// MARK: - Shared settings chrome

/// One label/control pair. The label column is pinned and the control follows
/// one gutter later: the old row ended with `Spacer()`, which pushed every
/// control to the far edge and left a 300pt hole in the middle of each line.
private let settingsLabelWidth = ardmScaled(150)
private let settingsRowInset = ardmScaled(14)

private struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: ardmScaled(14)) {
            Text(L10n(label))
                .font(.system(size: ARDMFont.body))
                .frame(width: settingsLabelWidth, alignment: .leading)
            control
            Spacer(minLength: 0)
        }
        .padding(.horizontal, settingsRowInset)
        .padding(.vertical, 7)
    }
}

/// Explanatory line under a row, left-aligned with the row label the way
/// System Settings does it: the control column is where the value lives, and a
/// sentence there reads as a second value.
private struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(L10n(text))
            .font(.system(size: ARDMFont.micro))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, settingsRowInset)
            .padding(.trailing, settingsRowInset)
            .padding(.bottom, 8)
    }
}

/// Hairline between two rows of the same card.
private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.16))
            .frame(height: 1)
            .padding(.horizontal, settingsRowInset)
    }
}

/// A switch without the label AppKit reserves space for.
private struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}

/// A destination rather than a setting: a row that is only a button, so it
/// doesn't need a label column pretending it holds a value.
private struct LinkRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 12) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, settingsRowInset)
        .padding(.vertical, 10)
    }
}

/// Slider with its value printed beside it in digits that don't jitter.
private struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @ViewBuilder let readout: () -> Text

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .frame(width: ardmScaled(190))
            readout()
                .font(.system(size: ARDMFont.small, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: ardmScaled(46), alignment: .trailing)
        }
    }
}

/// Read-only `label: value` line in the About pane.
private struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(spacing: ardmScaled(14)) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.system(size: ARDMFont.body))
                .frame(width: settingsLabelWidth, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .font(.system(size: ARDMFont.body))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, settingsRowInset)
        .padding(.vertical, 7)
    }
}
