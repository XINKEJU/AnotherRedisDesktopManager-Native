import SwiftUI
import AppKit

// MARK: - Settings (Setting.vue / LanguageSelector.vue / UpdateCheck.vue / font-manager.js)

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var checkingUpdate = false
    @State private var pendingArchive: URL?
    @State private var confirmInstall = false
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n("Settings")).font(.headline)
                Spacer()
                Text(L10n("All preferences persist to NSUserDefaults")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // A plain segmented Picker instead of TabView: the sheet sizes to
            // its content and TabView's tab bar collapsed into ellipses at
            // that width; the picker keeps the four labels readable.
            Picker("", selection: $tab) {
                Text(L10n("Appearance")).tag(0)
                Text(L10n("Keys")).tag(1)
                Text(L10n("Viewers")).tag(2)
                Text(L10n("About & Updates")).tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)

            Divider()
                .padding(.top, 12)

            Group {
                switch tab {
                case 0: appearanceTab
                case 1: keysTab
                case 2: viewersTab
                default: aboutTab
                }
            }

            Divider()
            HStack(spacing: 8) {
                Button(L10n("Keyboard Shortcuts…")) { store.showingHotKeys = true }
                Button(L10n("Import / Export…")) { store.showingImportExport = true }
                Button(L10n("Custom Formatters…")) { store.showingFormatterManager = true }
                Spacer()
                Button(L10n("Close")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 660, height: 520)
    }

    private var appearanceTab: some View {
        Form {
            Picker(L10n("Theme"), selection: $store.theme) {
                Text(L10n("Follow system")).tag("system")
                Text(L10n("Light")).tag("light")
                Text(L10n("Dark")).tag("dark")
            }
            Picker(L10n("Language"), selection: $store.language) {
                ForEach(store.languages, id: \.self) { code in
                    Text("\(code.uppercased()) — \(languageName(code))").tag(code)
                }
            }
            .onChange(of: store.language) { _, newValue in
                ARDMLocalization.shared().currentLanguage = newValue
            }
            Picker(L10n("Font family"), selection: $store.fontFamily) {
                ForEach(store.fonts, id: \.self) { Text($0).tag($0) }
            }
            Stepper(L10n("Font size") + ": \(Int(store.fontSize))", value: $store.fontSize, in: 9...24)
            HStack {
                Text(L10n("Zoom"))
                Slider(value: $store.zoom, in: 0.7...1.6, step: 0.1)
                Text(String(format: "%.1f×", store.zoom)).font(store.monoFont(11)).frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text(L10n("Sidebar width"))
                Slider(value: $store.sidebarWidth, in: 200...520, step: 10)
                Text("\(Int(store.sidebarWidth)) px").font(store.monoFont(11)).frame(width: 60, alignment: .trailing)
            }
        }
        .formStyle(.grouped)
    }

    private var keysTab: some View {
        Form {
            Stepper(L10n("Keys per SCAN page") + ": \(store.pageSize)", value: $store.pageSize, in: 50...5000, step: 50)
            TextField(L10n("Key tree separator"), text: $store.separator)
                .onChange(of: store.separator) { _, _ in store.buildTree() }
            Toggle(L10n("Use tree view"), isOn: $store.showTree)
            Toggle(L10n("Read-only mode (blocks write commands)"), isOn: $store.readOnly)
            HStack {
                Text(L10n("Database"))
                Spacer()
                Picker("", selection: $store.selectedDB) {
                    ForEach(0..<16, id: \.self) { Text("DB \($0)").tag($0) }
                }
                .frame(width: 110)
                .onChange(of: store.selectedDB) { _, newValue in store.changeDatabase(newValue) }
            }
            Text(L10n("Read-only is enforced in the RESP client before any command is written."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var viewersTab: some View {
        Form {
            Picker(L10n("Default viewer"), selection: $store.viewerName) {
                ForEach(store.viewers, id: \.self) { Text($0).tag($0) }
            }
            Text(L10n("Custom viewer JavaScript (JavaScriptCore; `bytes` is a Uint8Array):"))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $store.customViewerScript)
                .font(store.monoFont(11))
                .frame(height: 110)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button(L10n("Test on current value")) { store.viewerName = "Custom"; store.renderValue() }
                Button(L10n("Manage formatters…")) { store.showingFormatterManager = true }
                Spacer()
                Text("\(store.customFormatters.count) saved formatters").font(.caption)
            }
            Text(L10n("All 15 viewers (Text, Hex, Json, Binary, Msgpack, PHPSerialize, JavaSerialize, Pickle, Brotli, Gzip, Deflate, DeflateRaw, Protobuf, OverSize, Custom) are implemented with Foundation / zlib / JavaScriptCore."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        Form {
            LabeledContent("Application", value: "Another Redis Desktop Manager (Native)")
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7.4")
            LabeledContent("UI", value: "SwiftUI + AppKit (system frameworks, zero bundled runtime)")
            LabeledContent("Redis protocol", value: "RESP2 (RESP3 reply types parsed) over CFStream")
            LabeledContent("Localization", value: "\(store.languages.count) languages via JavaScriptCore")
            Divider()
            HStack {
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
                .disabled(checkingUpdate || ARDMAppServices.pendingUpdateVersion() == nil)
                if checkingUpdate { ProgressView().scaleEffect(0.6) }
                Toggle(L10n("Open release page when available"), isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "ARDMOpenReleaseOnUpdate") },
                    set: { UserDefaults.standard.set($0, forKey: "ARDMOpenReleaseOnUpdate") }))
            }
            if let version = ARDMAppServices.pendingUpdateVersion() {
                Text(L10n("Pending:") + " \(version) · "
                     + (ARDMAppServices.pendingUpdateHasChecksum()
                        ? L10n("SHA-256 available")
                        : L10n("no SHA-256 published")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(store.updateStatus.isEmpty ? L10n("No update check has been run yet.") : store.updateStatus)
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(L10n("External / conditional capabilities: Brotli viewer needs the system `brotli` CLI; RedisJSON / TimeSeries / Vector / Array views need the corresponding Redis modules; mutual TLS needs a PKCS#12 or PEM client identity."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .alert(L10n("Install this update?"), isPresented: $confirmInstall) {
            Button(L10n("Cancel"), role: .cancel) { pendingArchive = nil }
            Button(L10n("Install and relaunch")) { installPendingUpdate() }
        } message: {
            Text(installPrompt)
        }
    }

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
        switch code {
        case "cn": return "简体中文"
        case "tw": return "繁體中文"
        case "en": return "English"
        case "de": return "Deutsch"
        case "es": return "Español"
        case "fr": return "Français"
        case "it": return "Italiano"
        case "ko": return "한국어"
        case "pt": return "Português"
        case "ru": return "Русский"
        case "tr": return "Türkçe"
        case "ua": return "Українська"
        case "vi": return "Tiếng Việt"
        default: return code
        }
    }
}
