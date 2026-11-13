import SwiftUI
import AppKit

// MARK: - Code surface with a line-number gutter

/// Which grammar the highlighter should apply. Redis values are mostly JSON or
/// plain text; XML shows up in a few feeds, everything else stays monospaced and
/// uncoloured rather than pretending to know the format.
enum ARDMCodeLanguage {
    case json
    case xml
    case text

    static func detect(_ text: String, viewer: String) -> ARDMCodeLanguage {
        if viewer == "Json" { return .json }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") { return .xml }
        return .text
    }
}

/// NSTextView-based value surface.
///
/// SwiftUI's `TextEditor` cannot draw a line-number gutter, gives no control
/// over the text container, and forces the system's own paragraph spacing. The
/// reference clients all show a numbered code block, and a 30-line JSON payload
/// without numbers is genuinely harder to read, so the editor is an AppKit text
/// view wrapped here. It stays editable: the gutter and highlighting are drawn
/// around the same storage the user types into.
struct ARDMCodeView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var fontSize: CGFloat = 12.5
    var fontName: String = ""
    var language: ARDMCodeLanguage = .text
    var identifier: String = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        // SwiftUI owns the frame; leaving the bridge to auto-translate let the
        // scroll view grow past its slot and bleed over neighbouring rows.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // No wrapping: a JSON row that soft-wraps breaks the one-line-per-number
        // contract the gutter relies on, and horizontal scrolling is what every
        // other code pane does.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier(identifier)
        if !identifier.isEmpty {
            textView.setAccessibilityLabel(identifier)
        }

        scroll.documentView = textView

        let ruler = ARDMLineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = textView
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.attach(textView: textView, ruler: ruler)
        context.coordinator.reload(text: text, language: language,
                                   fontSize: fontSize, fontName: fontName, isEditable: isEditable)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.isEditable = isEditable
        // Only touch the storage when the model really changed; writing the same
        // string back on every keystroke would reset the insertion point.
        if textView.string != text {
            context.coordinator.reload(text: text, language: language,
                                       fontSize: fontSize, fontName: fontName, isEditable: isEditable)
        } else {
            context.coordinator.applyAppearance(language: language, fontSize: fontSize,
                                                fontName: fontName, isEditable: isEditable)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isEditable = true
        private(set) weak var textView: NSTextView?
        private(set) weak var ruler: ARDMLineNumberRuler?
        private var highlightWork: DispatchWorkItem?
        private var lastLanguage: ARDMCodeLanguage = .text
        private var lastFontSize: CGFloat = 12.5
        private var lastFontName = ""

        init(text: Binding<String>) {
            self.text = text
        }

        func attach(textView: NSTextView, ruler: ARDMLineNumberRuler) {
            self.textView = textView
            self.ruler = ruler
        }

        /// Replace the whole document. Used for a new key or a new viewer, where
        /// keeping the caret would leave it pointing at unrelated text.
        func reload(text: String, language: ARDMCodeLanguage, fontSize: CGFloat,
                    fontName: String, isEditable: Bool) {
            guard let textView else { return }
            self.isEditable = isEditable
            lastLanguage = language
            lastFontSize = fontSize
            lastFontName = fontName
            textView.isEditable = isEditable
            textView.string = text
            applyAppearance(language: language, fontSize: fontSize,
                            fontName: fontName, isEditable: isEditable)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        func applyAppearance(language: ARDMCodeLanguage, fontSize: CGFloat,
                             fontName: String, isEditable: Bool) {
            guard let textView else { return }
            let fontChanged = fontSize != lastFontSize || fontName != lastFontName
            lastLanguage = language
            lastFontSize = fontSize
            lastFontName = fontName
            textView.isEditable = isEditable
            if fontChanged || textView.textStorage?.length == 0 {
                highlight()
            } else if fontChanged == false && ruler?.language != language {
                highlight()
            }
            ruler?.language = language
            ruler?.invalidate()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, let textStorage = textView.textStorage else { return }
            text.wrappedValue = textView.string
            // Highlighting on every keystroke makes a 2000-line paste stutter;
            // 120 ms after the last edit is fast enough to feel live.
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let tv = self.textView, tv.textStorage === textStorage else { return }
                self.highlight()
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let font = Self.font(size: lastFontSize, name: lastFontName)
            let selection = textView.selectedRange()
            ARDMSyntaxHighlighter.apply(to: storage, language: lastLanguage, font: font)
            if NSMaxRange(selection) <= storage.length {
                textView.setSelectedRange(selection)
            }
            ruler?.lineCount = ARDMSyntaxHighlighter.lineCount(in: storage.string)
            ruler?.invalidate()
        }

        static func font(size: CGFloat, name: String) -> NSFont {
            if !name.isEmpty, let custom = NSFont(name: name, size: size) { return custom }
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

// MARK: - Gutter

/// Draws one number per paragraph. Wrapped fragments get no number, which is the
/// behaviour every code editor has and the reason this walks paragraph ranges
/// instead of visual line fragments.
final class ARDMLineNumberRuler: NSRulerView {
    var lineCount: Int = 0
    var language: ARDMCodeLanguage = .text
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        // The gutter is part of the code surface, so it moves with the text
        // instead of sitting on the sidebar's material.
        observeScrolling()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func observeScrolling() {
        guard let content = scrollView?.contentView else { return }
        content.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                           object: content, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                           object: content, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        })
    }

    /// Width follows the digit count so the numbers stop jumping left the moment
    /// a document grows past nine, ninety-nine or nine hundred lines.
    func invalidate() {
        let digits = max(2, String(max(1, lineCount)).count)
        let wanted = CGFloat(18 + digits * 7)
        if abs(ruleThickness - wanted) > 0.5 { ruleThickness = wanted }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }

        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        // Hairline separator, matching the 1pt rules used between the panes.
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let text = textView.string
        guard !text.isEmpty, text.utf16.count <= 300_000 else { return }

        let gutterFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: gutterFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let origin = convert(NSPoint(x: 0, y: textView.textContainerInset.height), from: textView)
        let visible = textView.visibleRect
        let ns = text as NSString
        var index = 0
        var line = 1
        while index < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: index)
            var fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            fragment.origin.y += origin.y
            if fragment.maxY >= visible.minY - 4 && fragment.minY <= visible.maxY + 4 {
                let label = "\(line)" as NSString
                let size = label.size(withAttributes: attributes)
                let x = bounds.maxX - 8 - size.width
                label.draw(at: NSPoint(x: x, y: fragment.minY + (fragment.height - size.height) / 2),
                           withAttributes: attributes)
            }
            index = lineRange.upperBound
            line += 1
            _ = container
        }
    }
}

// MARK: - Highlighter

enum ARDMSyntaxHighlighter {
    static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        var count = 1
        for byte in text.utf8 where byte == 0x0A { count += 1 }
        return count
    }

    /// Base attributes first, then colour on top. Rewriting the whole storage is
    /// what keeps stale colours from surviving a new key; the size guard keeps a
    /// 5 MB payload from freezing the main thread.
    static func apply(to storage: NSTextStorage, language: ARDMCodeLanguage, font: NSFont) {
        let full = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.defaultTabInterval = 24
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 24)]

        storage.beginEditing()
        storage.setAttributes([.font: font,
                               .foregroundColor: NSColor.labelColor,
                               .paragraphStyle: paragraph],
                              range: full)
        guard storage.length <= 300_000, storage.length > 0 else {
            storage.endEditing()
            return
        }
        let text = storage.string
        switch language {
        case .json: highlightJSON(text, storage: storage)
        case .xml: highlightXML(text, storage: storage)
        case .text: break
        }
        storage.endEditing()
    }

    private static let jsonString = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"")
    private static let jsonKey = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"(?=\\s*:)")
    private static let jsonNumber = try! NSRegularExpression(pattern: "(?<![\\w\"])-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?(?![\\w\"])")
    private static let jsonLiteral = try! NSRegularExpression(pattern: "\\b(?:true|false|null)\\b")
    private static let xmlTag = try! NSRegularExpression(pattern: "</?[A-Za-z_:][\\w:.-]*")
    private static let xmlComment = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->")

    private static func highlightJSON(_ text: String, storage: NSTextStorage) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Numbers and literals first: strings are painted afterwards so a date
        // like "2026-11-13" inside a string never gets a numeric colour.
        for match in jsonNumber.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: ARDMSyntaxPalette.number, range: match.range)
        }
        for match in jsonLiteral.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: ARDMSyntaxPalette.literal, range: match.range)
        }
        for match in jsonString.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: ARDMSyntaxPalette.string, range: match.range)
        }
        for match in jsonKey.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: ARDMSyntaxPalette.key, range: match.range)
        }
    }

    private static func highlightXML(_ text: String, storage: NSTextStorage) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in xmlComment.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: ARDMSyntaxPalette.comment, range: match.range)
        }
        for match in jsonString.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: ARDMSyntaxPalette.string, range: match.range)
        }
        for match in xmlTag.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: ARDMSyntaxPalette.key, range: match.range)
        }
    }
}

private enum ARDMSyntaxPalette {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let key = dynamic(light: NSColor(srgbRed: 0.09, green: 0.36, blue: 0.75, alpha: 1),
                             dark: NSColor(srgbRed: 0.47, green: 0.73, blue: 1.00, alpha: 1))
    static let string = dynamic(light: NSColor(srgbRed: 0.05, green: 0.45, blue: 0.24, alpha: 1),
                                dark: NSColor(srgbRed: 0.58, green: 0.86, blue: 0.58, alpha: 1))
    static let number = dynamic(light: NSColor(srgbRed: 0.70, green: 0.35, blue: 0.03, alpha: 1),
                                dark: NSColor(srgbRed: 0.95, green: 0.68, blue: 0.36, alpha: 1))
    static let literal = dynamic(light: NSColor(srgbRed: 0.52, green: 0.24, blue: 0.72, alpha: 1),
                                 dark: NSColor(srgbRed: 0.80, green: 0.62, blue: 0.98, alpha: 1))
    static let comment = dynamic(light: NSColor.secondaryLabelColor,
                                 dark: NSColor.tertiaryLabelColor)
}
