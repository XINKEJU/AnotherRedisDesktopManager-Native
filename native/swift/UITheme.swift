import SwiftUI
import AppKit

// MARK: - One icon scale

/// Symbol sizes used to be picked per call site: an 8pt tab close glyph, 9pt
/// capability badges, 10pt database cylinders, 11pt tab icons, 12pt row icons
/// and a 42pt empty state. Every row ended up with a different optical weight,
/// which is what made the interface read as noisy even after the toolbars were
/// collapsed. These four sizes are the only ones the UI should use.
enum ARDMIcon {
    /// Glyph inside a chip, badge or search field. Scales with the text around
    /// it, otherwise a larger 字号 leaves the magnifier a pinprick in a wider box.
    static var inline: CGFloat { ardmScaled(11) }
    /// Icon-only button and tab strip glyph. One step above `inline` so a
    /// symbol with wide bearings still fills its control-sized target.
    static var control: CGFloat { ardmScaled(12.5) }
    /// Empty-state illustration. Deliberately fixed: it is decoration, and
    /// growing it with the text would push the real content off the pane.
    static let emptyState: CGFloat = 36
}

/// Applies the live 字号 × 缩放 multiplier to a chrome dimension. Free function
/// rather than a store method because `ARDMFont` and `ARDMMetrics` are used from
/// static contexts that have no store in scope.
func ardmScaled(_ base: CGFloat) -> CGFloat { base * AppStore.shared.uiScale }

enum ARDMMetrics {
    /// Square hit target shared by every icon button and icon menu. Without it
    /// the target followed the glyph, so `plus` was wider than `play.fill` and
    /// the controls beside them never lined up.
    static var control: CGFloat { ardmScaled(26) }
    static let controlSpacing: CGFloat = 2
    static let rowSpacing: CGFloat = 6
    static let corner: CGFloat = 6
    /// Search field height; matches the control beside it.
    static var fieldHeight: CGFloat { ardmScaled(26) }
    /// Key row height. The reference clients pack rows into 24pt, which is the
    /// smallest height that fits a checkbox beside a type chip — but at that
    /// height a page of keys reads as a spreadsheet, so the baseline starts one
    /// step looser and scales with the text so neither overflows the other.
    static var rowHeight: CGFloat { ardmScaled(27) }
    static let listInset: CGFloat = 10
    /// Height shared by the database tab strip and the filter strips above it.
    static var stripHeight: CGFloat { ardmScaled(30) }
    /// Sidebar rows: a connection, or one of the sixteen databases. Looser than
    /// the 19pt they were, which made the column read as a compact index.
    static var sideRow: CGFloat { ardmScaled(24) }
}

/// Type scale. Every view used to pass its own number to `uiFont`, so the key
/// list, the sidebar and the detail header drifted between 10.5 and 14pt. These
/// five steps are now the only sizes used for chrome text; editors keep their
/// own zoomable size because they hold user data, not labels.
///
/// The steps read the live 字号 × 缩放 multiplier rather than being constants,
/// because they were constants: the two settings in 外观 changed exactly two
/// views in the whole app and left the other ninety call sites untouched.
enum ARDMFont {
    /// Counters, TTLs, badge text.
    static var micro: CGFloat { ardmScaled(11) }
    /// Secondary row text, status bar, chips.
    static var small: CGFloat { ardmScaled(12) }
    /// Default row and label text.
    static var body: CGFloat { ardmScaled(13) }
    /// Pane titles and the selected key name.
    static var title: CGFloat { ardmScaled(14) }
    /// Monospaced key names inside list rows.
    static var monoRow: CGFloat { ardmScaled(12.5) }
}

// MARK: - Liquid Glass (macOS 26 Tahoe and later)

/// Builds the glass variant outside the ViewBuilder: assignments are statements
/// and ViewBuilder only accepts declarations and view expressions.
@available(macOS 26.0, *)
private func ardmGlassVariant(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// Liquid Glass where the OS provides it, `.regularMaterial` below macOS 26.
    /// The deployment target is macOS 14, so every call site needs this bridge;
    /// on a 26+ host this renders the real glass with backdrop refraction, on
    /// older systems it silently degrades to the nearest system material.
    ///
    /// `glassEffect`'s default shape is a capsule, so the shape is always passed
    /// explicitly here — a bare `.glassEffect()` on a rectangular bar would come
    /// out as a pill.
    @ViewBuilder
    func ardmGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(ardmGlassVariant(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// Groups sibling glass shapes so they blend and morph instead of drawing
    /// individual frosted circles over each other. No-op below macOS 26.
    @ViewBuilder
    func ardmGlassContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content() }
        } else {
            content()
        }
    }

    /// Prominent buttons pick up the glass button style on 26+, bordered below.
    @ViewBuilder
    func ardmGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

// MARK: - Controls

/// Square, quiet icon button.
///
/// Three problems with the stock bordered button in a dense row: it drew a grey
/// lozenge around every glyph, the width changed with the symbol, and the accent
/// tint made secondary actions look selected. A plain button with a fixed frame
/// and a hover wash fixes all three.
struct ARDMIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = .secondary
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: ARDMIcon.control, weight: .medium))
                .frame(width: ARDMMetrics.control, height: ARDMMetrics.control)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.secondary.opacity(0.13) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Overflow menu that looks exactly like the icon button next to it.
///
/// `.menuStyle(.borderlessButton)` draws its own disclosure chevron inside the
/// frame, which used to print a second arrow on top of the ellipsis. Hiding the
/// indicator is the only way to keep the two controls optically identical.
struct ARDMIconMenu<Content: View>: View {
    private let systemName: String
    private let help: String
    private let content: () -> Content

    @State private var hovering = false

    init(systemName: String = "ellipsis",
         help: String,
         @ViewBuilder content: @escaping () -> Content) {
        self.systemName = systemName
        self.help = help
        self.content = content
    }

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemName)
                .font(.system(size: ARDMIcon.control, weight: .medium))
                .frame(width: ARDMMetrics.control, height: ARDMMetrics.control)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.secondary.opacity(0.13) : Color.clear)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Search field with the magnifier inside the border, so the glyph cannot drift
/// away from the text on narrow columns. The stock `.roundedBorder` field on a
/// sidebar background also had no visible edge, which made it read as a label.
struct ARDMSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var identifier: String = ""
    var onSubmit: () -> Void = {}
    var onClear: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ARDMIcon.inline, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: ARDMFont.body))
                .focused(focus)
                .onSubmit(onSubmit)
                // Esc behaves like the browser omni-box: clear the text, run the
                // clear hook, then hand focus back to the list.
                .onKeyPress(.escape) {
                    if !text.isEmpty {
                        text = ""
                        onClear?()
                    }
                    focus.wrappedValue = false
                    return .handled
                }
                .accessibilityLabel(placeholder)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button {
                    text = ""
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: ARDMIcon.inline))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n("Clear search"))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: ARDMMetrics.fieldHeight)
        .background(
            RoundedRectangle(cornerRadius: ARDMMetrics.corner, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: ARDMMetrics.corner, style: .continuous)
                        .strokeBorder(focus.wrappedValue ? Color.accentColor.opacity(0.6)
                                                        : Color.secondary.opacity(0.22),
                                      lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = true }
    }
}

// MARK: - Menu item helpers

/// Menu rows read better with the same glyph language as the toolbars they open
/// from, and a section header is cheaper than a divider plus guesswork.
extension View {
    /// Keeps menu rows on one line even when the localized title is long.
    func menuRow() -> some View {
        self.lineLimit(1)
    }
}

// MARK: - Data type vocabulary

/// One glyph and one tint per Redis type. The reference clients put a small type
/// marker in front of every key row; without it a list of 3000 keys is a wall of
/// identical text and the only way to tell a hash from a string is to open it.
extension ARDMKeyType {
    var symbol: String {
        switch self {
        case .string: return "text.alignleft"
        case .list: return "list.bullet"
        case .set: return "circle.grid.2x2"
        case .zSet: return "chart.bar.xaxis"
        case .hash: return "tablecells"
        case .stream: return "waveform.path.ecg"
        case .reJSON: return "curlybraces"
        case .timeSeries: return "chart.xyaxis.line"
        case .vector: return "point.3.connected.trianglepath.dotted"
        case .array: return "square.grid.3x3"
        default: return "questionmark"
        }
    }

    /// `typeName` is spelled the way Redis spells it. The reference clients
    /// print the lowercase word in the type pill (`string`, `zset`), which reads
    /// as a word rather than an acronym and costs four more points of width.
    var badgeText: String {
        switch self {
        case .string: return "string"
        case .list: return "list"
        case .set: return "set"
        case .zSet: return "zset"
        case .hash: return "hash"
        case .stream: return "stream"
        case .reJSON: return "json"
        case .timeSeries: return "ts"
        case .vector: return "vector"
        case .array: return "array"
        default: return "—"
        }
    }

    /// Muted tints only. A saturated palette across thousands of rows looks like
    /// a highlighter accident on macOS; these stay legible at 9pt.
    var tint: Color {
        switch self {
        case .string: return Color(red: 0.20, green: 0.52, blue: 0.86)
        case .hash: return Color(red: 0.62, green: 0.38, blue: 0.86)
        case .list: return Color(red: 0.16, green: 0.62, blue: 0.54)
        case .set: return Color(red: 0.85, green: 0.52, blue: 0.14)
        case .zSet: return Color(red: 0.86, green: 0.34, blue: 0.40)
        case .stream: return Color(red: 0.36, green: 0.56, blue: 0.30)
        default: return Color.secondary
        }
    }
}

/// Type pill: `string` / `hash` / `zset`, outlined in the type colour with a
/// 10% wash. The outline is what makes a column of pills read as one column
/// instead of a row of coloured words.
struct ARDMTypeBadge: View {
    let type: ARDMKeyType
    var dimmed: Bool = false

    var body: some View {
        Text(type.badgeText)
            .font(.system(size: ARDMFont.micro, weight: .medium))
            .foregroundStyle(dimmed ? Color.secondary : type.tint)
            .padding(.horizontal, 5)
            .frame(height: ardmScaled(17))
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(type.tint.opacity(dimmed ? 0.04 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(type.tint.opacity(dimmed ? 0.18 : 0.45), lineWidth: 0.8)
            )
            .fixedSize()
            .accessibilityLabel(typeName(type))
    }
}

/// One filter chip in the detail pane's format bars ("Gzip", "JSON", …).
/// Selected chips take the accent wash; the rest stay flat text so a row of
/// twelve formats does not turn into twelve buttons.
struct ARDMChip: View {
    let title: String
    var selected: Bool = false
    var tint: Color = .accentColor
    var help: String = ""
    /// The digit that picks this chip from the keyboard, printed on the chip.
    var keyHint: String = ""
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(size: ARDMFont.small))
                    .foregroundStyle(selected ? tint : Color.secondary)
                if !keyHint.isEmpty {
                    Text(keyHint)
                        .font(.system(size: ARDMFont.micro, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(selected ? tint.opacity(0.75)
                                                   : Color.secondary.opacity(0.55))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: ardmScaled(22))
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected ? tint.opacity(0.12)
                                   : (hovering ? Color.secondary.opacity(0.10) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.38) : Color.clear, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help.isEmpty ? (keyHint.isEmpty ? title : "\(title) (\(keyHint))") : help)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Small right-aligned count used by the sidebar's database rows.
struct ARDMCountBadge: View {
    let count: Int
    var tint: Color = .secondary

    var body: some View {
        Text(ARDMFormat.count(count))
            .font(.system(size: ARDMFont.micro, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(tint.opacity(0.9))
            .padding(.horizontal, 4)
            .frame(minWidth: ardmScaled(20), minHeight: ardmScaled(15))
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(0.10))
            )
            .fixedSize()
            .accessibilityLabel("\(count)")
    }
}

/// Quiet label + value pair used under the detail title ("大小 5.4 KB").
struct ARDMMetaChip: View {
    let label: String
    let value: String
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: ARDMFont.micro, weight: .medium))
                    .accessibilityHidden(true)
            }
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: ARDMFont.micro))
        .lineLimit(1)
    }
}

// MARK: - Formatting helpers

enum ARDMFormat {
    /// TTL rendered the way a person reads it, in the narrowest form that is
    /// still unambiguous: `45s`, `8m`, `23h`, `6d`. The spelled-out Chinese form
    /// ("23小时45分") wrapped onto two lines in a 330pt column and doubled the
    /// height of every row that had an expiry.
    static func ttl(_ seconds: Int) -> String {
        switch seconds {
        case -1: return "永久"
        case -2: return "已失效"
        case ..<0: return "—"
        case 0..<60: return "\(seconds)s"
        case 60..<3600: return "\(seconds / 60)m"
        case 3600..<86400: return "\(seconds / 3600)h"
        case 86400..<(86400 * 100): return "\(seconds / 86400)d"
        default: return "\(seconds / 86400)d"
        }
    }

    /// Spelled-out expiry, the way the reference key lists print it:
    /// `23小时21分`, `6天`, `永久`. Zero remainders are dropped so a week-long
    /// TTL does not read as `7天0小时`. Used where the row can afford ~62pt.
    static func ttlLong(_ seconds: Int) -> String {
        switch seconds {
        case -1: return "永久"
        case -2: return "已过期"
        case ..<0: return "—"
        case 0..<60: return "\(seconds)秒"
        case 60..<3600:
            let minutes = seconds / 60, rest = seconds % 60
            return rest == 0 ? "\(minutes)分" : "\(minutes)分\(rest)秒"
        case 3600..<86400:
            let hours = seconds / 3600, minutes = (seconds % 3600) / 60
            return minutes == 0 ? "\(hours)小时" : "\(hours)小时\(minutes)分"
        default:
            let days = seconds / 86400, hours = (seconds % 86400) / 3600
            return hours == 0 ? "\(days)天" : "\(days)天\(hours)小时"
        }
    }

    /// Byte counts with a thousands separator under 1 KB and a single decimal
    /// above it, matching how Finder reports sizes.
    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        let kb = Double(count) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    static func count(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Inline feedback pill

/// The toast layer, mounted once over the three columns. Sits above the status
/// bar so the news never lands where the eye already reads it twice.
struct ARDMToastLayer: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        // The ZStack and the animation live here so the mount point in `RootView`
        // is a single view: the longer the modifier chain on the root, the more
        // often the type checker gives up on the whole body.
        ZStack {
            if let toast = store.toast {
                ARDMToastPill(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: store.toast)
        .padding(.bottom, 32)
    }
}

/// One message, shown until it ages out. A newer `notify` replaces this pill
/// rather than queueing behind it: the last thing that happened is the thing
/// worth reading.
private struct ARDMToastPill: View {
    @EnvironmentObject var store: AppStore
    let toast: AppStore.Toast

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: ARDMFont.small, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(toast.text)
                .font(.system(size: ARDMFont.small))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .frame(height: ARDMMetrics.control)
        .ardmGlass(in: Capsule())
        .contentShape(Capsule())
        .accessibilityIdentifier("app.toast")
        .onTapGesture { store.dismissToast(toast) }
        // `.task(id:)` cancels the previous countdown when a new toast arrives,
        // so the timer can never dismiss a message that has already been
        // replaced.
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            store.dismissToast(toast)
        }
    }
}
