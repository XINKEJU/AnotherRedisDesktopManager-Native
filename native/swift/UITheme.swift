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
