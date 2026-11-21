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
    /// Gap between siblings inside one control cluster (icon button + menu,
    /// stepper + field). Scaled like everything else: at 字号 16 a fixed 2pt gap
    /// reads as glued together.
    static var controlSpacing: CGFloat { ardmScaled(2) }
    static var rowSpacing: CGFloat { ardmScaled(6) }
    /// The one radius a plain control wears. `ARDMRadius.control` is the
    /// definition; this alias stays because the existing call sites use it.
    static var corner: CGFloat { ARDMRadius.control }
    /// Search field height; matches the control beside it.
    static var fieldHeight: CGFloat { ardmScaled(26) }
    /// Key row height. The reference clients pack rows into 24pt, which is the
    /// smallest height that fits a checkbox beside a type chip — but at that
    /// height a page of keys reads as a spreadsheet, so the baseline starts one
    /// step looser and scales with the text so neither overflows the other.
    static var rowHeight: CGFloat { ardmScaled(27) }
    /// Horizontal inset of the key list. Aliased to `paneInset` so a pane's
    /// header and its rows can never drift apart; step 3 still re-decides the
    /// value (10 → 8 or 12) against the row pictures.
    static var listInset: CGFloat { paneInset }
    /// Height shared by the database tab strip and the filter strips above it.
    static var stripHeight: CGFloat { paneHeader }
    /// Height of all three column headers: the sidebar's action row, the key
    /// list's database strip, the detail pane's tab strip. They were 36, an
    /// unscaled 30 and a scaled 30, so the top edges of the three panes never
    /// lined up — and at a larger 字号 the unscaled one clipped its buttons.
    static var paneHeader: CGFloat { ardmScaled(30) }
    /// Leading inset of every pane, so a column's header label sits on the same
    /// vertical line as the rows under it. Was 8 in the sidebar, 6 above the key
    /// list and detail tabs, 10 in the list itself.
    static var paneInset: CGFloat { ardmScaled(10) }
    /// Height of the bottom status bar.
    static var barHeight: CGFloat { ardmScaled(24) }
    /// Invisible drag strip beside a column divider. The hairline itself is
    /// `ARDMStroke.width`; this is only the target that catches the pointer.
    static let dividerHitWidth: CGFloat = 7
    /// Sidebar rows: a connection, or one of the sixteen databases. Looser than
    /// the 19pt they were, which made the column read as a compact index.
    static var sideRow: CGFloat { ardmScaled(24) }
}

// MARK: - Design tokens
//
// The type scale (`ARDMFont`), the icon scale (`ARDMIcon`) and `ARDMMetrics`
// already exist, yet the interface still drifted, because those cover only
// glyphs and control heights. What a screen is actually made of — gaps between
// blocks, corner radii, how dim a piece of text should be, how strong a border
// is — had no home, so every call site invented one. The survey before this
// section was written: 101 padding literals across 16 distinct values, 92
// spacing values across 13, 19 radii across 7, and 46 `.opacity()` calls using
// 24 different alphas, which is how the same "secondary label" role ended up
// five shades grey.
//
// These enums are definitions only. Nothing here changes a pixel until a view
// stops passing its own number, which is what the following steps do — each
// migration step replaces a documented old value, so a drift can be traced back.

/// Block spacing on a 4pt grid with a 2pt subdivision, the way AppKit's own
/// layout guides are drawn. `controlSpacing` (2) stays in `ARDMMetrics` because
/// it is inside a control, not between blocks.
///
/// Snap rules for the migration steps: 4 stays; 5→4; 6→6 (half step, allowed
/// only inside dense rows); 7→8; 10→8 in lists and 12 in panes; 14→16;
/// 20 and 24 stay as pane/overlay insets.
enum ARDMSpace {
    /// Hairline gap: badge padding, icon-to-text kerning inside a control.
    static var xxs: CGFloat { ardmScaled(2) }
    /// Tight pairing: label to its value, chip to chip.
    static var xs: CGFloat { ardmScaled(4) }
    /// Half step, reserved for rows shorter than `ARDMMetrics.rowHeight`.
    static var s: CGFloat { ardmScaled(6) }
    /// The default gap between elements in a row or a list.
    static var m: CGFloat { ardmScaled(8) }
    /// Gap between rows of controls, or between a control and a divider.
    static var l: CGFloat { ardmScaled(12) }
    /// Default horizontal inset inside a pane.
    static var xl: CGFloat { ardmScaled(16) }
    /// Outer inset of a card, sheet or overlay.
    static var xxl: CGFloat { ardmScaled(20) }
    /// Window-level breathing room (empty states, welcome panes).
    static var xxxl: CGFloat { ardmScaled(24) }
}

/// Four corner radii, one per kind of surface. The old mix was 3, 4, 5, 6, 8,
/// 10 and 14 with no rule; 3/4 were badges, 5/6 controls, 8/10 cards and 14 the
/// quick-open panel. The four values below are the ones the app already draws
/// at the default 字号, chosen so that adopting a token never moves a pixel on
/// its own — a surface changes shape only when a call site is migrated.
enum ARDMRadius {
    /// Type pills and count badges — small enough that a larger radius turns
    /// them into lozenges at 17pt tall. Replaces 3 and 4.
    static var badge: CGFloat { ardmScaled(4) }
    /// Buttons, fields, chips, selected rows. Replaces 5 and 6.
    static var control: CGFloat { ardmScaled(6) }
    /// Cards, grouped sections, inset wells. Replaces 8 and 10.
    static var card: CGFloat { ardmScaled(8) }
    /// Floating panels: the Cmd-K palette and sheet-class surfaces. Replaces 14.
    static var overlay: CGFloat { ardmScaled(12) }
}

/// Text emphasis, taken from the system label ramp instead of from a hand-picked
/// alpha. `Color.secondary.opacity(0.55)` and `Color.secondary.opacity(0.6)`
/// looked different in the two appearances and neither matched a documented
/// contrast; these four are what macOS itself uses for the same four roles.
///
/// Migration map for the 46 `.opacity()` sites that decorated text:
/// plain `Color.secondary` → `.secondary`; `.opacity(0.6…0.65)` → `.tertiary`;
/// `.opacity(0.4…0.55)` → `.tertiary`, or `.quaternary` when the text is
/// disabled rather than quiet; `Color.primary` → `.primary`.
enum ARDMInk {
    static var primary: Color { Color(nsColor: .labelColor) }
    static var secondary: Color { Color(nsColor: .secondaryLabelColor) }
    static var tertiary: Color { Color(nsColor: .tertiaryLabelColor) }
    static var quaternary: Color { Color(nsColor: .quaternaryLabelColor) }
    /// Text that sits on an accent-coloured selection. White, not
    /// `.primary`, because the selection is dark in both appearances.
    static var onAccent: Color { Color.white }
}

/// Non-text washes: hover, selection, tracks, inset wells. Five steps, because
/// that is how many distinct jobs the 46 opacity calls were actually doing
/// (0.09/0.10/0.13/0.16 were all "hovered", 0.045/0.06/0.07 all "track").
enum ARDMTint {
    static let hoverAlpha: Double = 0.10
    static let pressedAlpha: Double = 0.16
    static let selectedAlpha: Double = 0.12
    static let trackAlpha: Double = 0.06
    static let wellAlpha: Double = 0.18

    /// Pointer hover on a row, chip or icon button.
    static func hover() -> Color { Color(nsColor: .secondaryLabelColor).opacity(hoverAlpha) }
    static func pressed() -> Color { Color(nsColor: .secondaryLabelColor).opacity(pressedAlpha) }
    /// The selected key row, the active tab, the checked checkbox track.
    static func selected(_ base: Color = Color.accentColor) -> Color { base.opacity(selectedAlpha) }
    /// Unfilled progress, zebra stripe, the groove behind a segmented strip.
    static func track() -> Color { Color(nsColor: .secondaryLabelColor).opacity(trackAlpha) }
    /// A recessed panel: the editor gutter, a grouped box on a grouped view.
    static func well() -> Color { Color(nsColor: .secondaryLabelColor).opacity(wellAlpha) }
}

/// Borders and separators. The old set was `Color.secondary.opacity(0.14 / 0.2 /
/// 0.22 / 0.3)` plus `Divider()`; `.separatorColor` is the colour macOS draws
/// its own hairlines with, so it is what a client should use for a hairline.
enum ARDMStroke {
    /// 1pt hairline between rows, columns and above a status bar.
    static var hairline: Color { Color(nsColor: .separatorColor) }
    /// Outline of an idle control (field, chip, well).
    static var control: Color { Color(nsColor: .separatorColor) }
    /// Outline of a control that is drop-target armed or otherwise emphasised.
    static var emphasised: Color { Color(nsColor: .secondaryLabelColor).opacity(0.30) }
    /// Focus ring.
    static var focus: Color { Color.accentColor.opacity(0.60) }
    /// Full-strength accent, for the leading edge of a selected row.
    static var accent: Color { Color.accentColor }
    static let width: CGFloat = 1
    static let emphasisedWidth: CGFloat = 1.5
}

/// Geometry and colour recipe of the type pill / count badge, which used to be
/// spelled out inline twice (`.fill(tint.opacity(0.10))` +
/// `.strokeBorder(tint.opacity(0.45), lineWidth: 0.8)`).
enum ARDMBadge {
    static var height: CGFloat { ardmScaled(17) }
    /// Not on the `ARDMSpace` grid, deliberately: a pill this short needs 5pt
    /// of side bearing to keep the "string" / "zset" words from touching the
    /// outline. Steps 3 and 4 re-decide this against screenshots, not in here.
    static var hPadding: CGFloat { ardmScaled(5) }
    static var radius: CGFloat { ARDMRadius.badge }
    static var strokeWidth: CGFloat { 0.8 }
    static let fillAlpha: Double = 0.10
    static let strokeAlpha: Double = 0.45
    static let textAlpha: Double = 0.90
    /// The same pill on a row that is not selected: 0.04 wash, 0.18 outline.
    static let dimFillAlpha: Double = 0.04
    static let dimStrokeAlpha: Double = 0.18
    static let selectedFillAlpha: Double = 0.12
    static let selectedStrokeAlpha: Double = 0.38
    static let selectedTextAlpha: Double = 0.75
}

/// The colours that carry meaning rather than identity, which were duplicated
/// verbatim in two files (the TTL ramp appears in DetailViews and again in
/// KeyBrowserViews) and drifted into a third amber for the group folder.
enum ARDMAccent {
    /// TTL under five minutes, and anything else that should pull the eye.
    static let danger = Color(red: 0.85, green: 0.30, blue: 0.26)
    /// TTL under an hour.
    static let warn = Color(red: 0.86, green: 0.55, blue: 0.16)
    /// A live/connected indicator.
    static let ok = Color.green
    /// Tree group folder. Deliberately not `warn`: this one is identity, the
    /// other two are urgency, and sharing a value between them would make every
    /// folder read as an expiry.
    static let group = Color(red: 0.84, green: 0.63, blue: 0.26)
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
// `if #available(macOS 26.0)` guards the runtime, not the compile time: the
// Glass symbols must exist in the SDK used to build. Gate them on the compiler
// too so an Xcode 15/16 toolchain compiles the material fallback instead of
// failing with "cannot find 'Glass' in scope". Xcode 26 ships Swift 6.1+.
#if compiler(>=6.1)
@available(macOS 26.0, *)
private func ardmGlassVariant(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

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
        #if compiler(>=6.1)
        if #available(macOS 26.0, *) {
            self.glassEffect(ardmGlassVariant(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
        #else
        self.background(.regularMaterial, in: shape)
        #endif
    }

    /// Groups sibling glass shapes so they blend and morph instead of drawing
    /// individual frosted circles over each other. No-op below macOS 26.
    @ViewBuilder
    func ardmGlassContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if compiler(>=6.1)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }

    /// Prominent buttons pick up the glass button style on 26+, bordered below.
    @ViewBuilder
    func ardmGlassButton() -> some View {
        #if compiler(>=6.1)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
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
