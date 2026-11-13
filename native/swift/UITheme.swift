import SwiftUI
import AppKit

// MARK: - One icon scale

/// Symbol sizes used to be picked per call site: an 8pt tab close glyph, 9pt
/// capability badges, 10pt database cylinders, 11pt tab icons, 12pt row icons
/// and a 42pt empty state. Every row ended up with a different optical weight,
/// which is what made the interface read as noisy even after the toolbars were
/// collapsed. These four sizes are the only ones the UI should use.
enum ARDMIcon {
    /// Glyph inside a chip, badge or search field.
    static let inline: CGFloat = 11
    /// Icon-only button and tab strip glyph. One step above `inline` so a
    /// symbol with wide bearings still fills its 24pt target.
    static let control: CGFloat = 12.5
    /// Leading glyph of a list row. Rows scale their text with the font size
    /// setting, so this scales too.
    static let row: CGFloat = 13
    /// Empty-state illustration.
    static let emptyState: CGFloat = 36
}

enum ARDMMetrics {
    /// Square hit target shared by every icon button and icon menu. Without it
    /// the target followed the glyph, so `plus` was wider than `play.fill` and
    /// the controls beside them never lined up.
    static let control: CGFloat = 24
    static let controlSpacing: CGFloat = 2
    static let rowSpacing: CGFloat = 6
    static let corner: CGFloat = 6
    /// Compact search field height; matches the 24pt control next to it.
    static let fieldHeight: CGFloat = 24
    /// Dense list row. The reference clients pack key rows into 24pt, which is
    /// also the smallest height that fits a 13pt checkbox beside a type chip;
    /// anything taller turns a 3000-key page into a scrolling exercise.
    static let rowHeight: CGFloat = 24
    static let listInset: CGFloat = 10
    /// Height shared by the database tab strip and the filter strips above it.
    static let stripHeight: CGFloat = 28
}

/// Type scale. Every view used to pass its own number to `uiFont`, so the key
/// list, the sidebar and the detail header drifted between 10.5 and 14pt. These
/// five steps are now the only sizes used for chrome text; editors keep their
/// own zoomable size because they hold user data, not labels.
enum ARDMFont {
    /// Counters, TTLs, badge text.
    static let micro: CGFloat = 10
    /// Secondary row text, status bar, chips.
    static let small: CGFloat = 11
    /// Default row and label text.
    static let body: CGFloat = 12
    /// Pane titles and the selected key name.
    static let title: CGFloat = 13
    /// Monospaced key names inside list rows.
    static let monoRow: CGFloat = 11.5
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
                .font(.system(size: 12))
                .focused(focus)
                .onSubmit(onSubmit)
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
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(dimmed ? Color.secondary : type.tint)
            .padding(.horizontal, 5)
            .frame(height: 15)
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
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: ARDMFont.small))
                .foregroundStyle(selected ? tint : Color.secondary)
                .padding(.horizontal, 6)
                .frame(height: 20)
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
        .help(help.isEmpty ? title : help)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Small right-aligned count used by the sidebar's database rows.
struct ARDMCountBadge: View {
    let count: Int
    var tint: Color = .secondary

    var body: some View {
        Text(ARDMFormat.count(count))
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(tint.opacity(0.9))
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 13)
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
                    .font(.system(size: 9, weight: .medium))
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
