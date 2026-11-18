import JavaScriptCore
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private nonisolated struct CodeSyntaxSpan: Sendable {
    let start: Int
    let length: Int
    let role: String
}

// JavaScriptCore and its values never leave this queue. The UI receives UTF-16 ranges only.
private nonisolated final class CodeSyntaxEngine: @unchecked Sendable {
    static let shared = CodeSyntaxEngine()
    private let queue = DispatchQueue(label: "penned.code-syntax", qos: .userInitiated)
    private lazy var grammar: JSValue? = {
        guard let url = CodeBlockCatalog.asset("code-syntax", extension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return nil }
        context.evaluateScript(script, withSourceURL: url)
        return context.objectForKeyedSubscript("PennedCodeSyntax")
    }()

    func tokens(_ text: String, language: String) async -> [CodeSyntaxSpan] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let result = grammar?.invokeMethod("tokens", withArguments: [text, language])?.toArray() ?? []
                continuation.resume(returning: result.compactMap { value in
                    guard let object = value as? [String: Any], let start = object["start"] as? Int,
                          let length = object["length"] as? Int, let role = object["role"] as? String else { return nil }
                    return CodeSyntaxSpan(start: start, length: length, role: role)
                })
            }
        }
    }
}

#if os(iOS)
private typealias CodePlatformColor = UIColor
#elseif os(macOS)
private typealias CodePlatformColor = NSColor
#endif

#if os(iOS) || os(macOS)
private extension CodeBlockPalette {
    func nativeColor(_ role: String) -> CodePlatformColor { CodePlatformColor(Color(vellixHex: hex(role))) }
}

@MainActor
private final class CodeTextHighlighting {
    private var task: Task<Void, Never>?
    private var spans: [CodeSyntaxSpan] = []
    private var highlightedText: String?
    private var highlightedLanguage: String?

    func update(_ text: String, language: String, palette: CodeBlockPalette, layout: NSLayoutManager, immediate: Bool,
                canApply: @escaping @MainActor () -> Bool) {
        task?.cancel()
        guard canApply() else { return }
        if text == highlightedText && language == highlightedLanguage {
            apply(spans, palette: palette, to: layout)
            return
        }
        if text.isEmpty || language == "plaintext" || language == "other" {
            apply([], palette: palette, to: layout)
            return
        }
        task = Task { [weak self, weak layout] in
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(170)) } catch { return }
            }
            let spans = await CodeSyntaxEngine.shared.tokens(text, language: language)
            guard !Task.isCancelled, let self, let layout, canApply(), layout.textStorage?.string == text else { return }
            highlightedText = text
            highlightedLanguage = language
            self.spans = spans
            apply(spans, palette: palette, to: layout)
        }
    }

    private func apply(_ spans: [CodeSyntaxSpan], palette: CodeBlockPalette, to layout: NSLayoutManager) {
        guard let storage = layout.textStorage, storage.length > 0 else { return }
        let length = storage.length
        let colors = palette.colors.mapValues { CodePlatformColor(Color(vellixHex: $0)) }
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.addAttribute(.foregroundColor, value: palette.nativeColor("text"), range: NSRange(location: 0, length: length))
        for span in spans where span.start >= 0 && span.start < length && span.length > 0 && span.length <= length - span.start {
            if let color = colors[span.role] {
                storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: span.start, length: span.length))
            }
        }
    }
}

private nonisolated struct CodeLineIndex {
    private(set) var starts = [0]

    mutating func update(_ text: String) {
        let source = text as NSString
        starts = [0]
        var offset = 0
        while offset < source.length {
            var end = 0, contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            guard end > offset else { break }
            if contentsEnd < end { starts.append(end) }
            offset = end
        }
    }

    func line(at offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
}
#endif

#if os(iOS)
struct CodeBlockTextEditor: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var code: String
    let language: String
    let palette: CodeBlockPalette
    var focusChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> Surface {
        let surface = Surface()
        surface.textView.delegate = context.coordinator
        context.coordinator.apply(self, to: surface)
        return surface
    }

    func updateUIView(_ surface: Surface, context: Context) { context.coordinator.apply(self, to: surface) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeBlockTextEditor
        private weak var surface: Surface?
        private let highlighting = CodeTextHighlighting()
        private var palette: CodeBlockPalette?
        private var language: String?

        init(parent: CodeBlockTextEditor) { self.parent = parent }

        func apply(_ parent: CodeBlockTextEditor, to surface: Surface) {
            self.parent = parent
            self.surface = surface
            if surface.textView.isEditable != parent.isEnabled { surface.textView.isEditable = parent.isEnabled }
            let appearanceChanged = palette != parent.palette || language != parent.language
            let textChanged = surface.textView.text != parent.code
            if textChanged { surface.textView.text = parent.code; surface.updateLineIndex() }
            if palette != parent.palette { surface.apply(parent.palette) }
            palette = parent.palette
            language = parent.language
            if appearanceChanged || textChanged { highlight(surface, immediate: true) }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let surface else { return }
            surface.updateLineIndex()
            parent.code = textView.text
            if textView.markedTextRange == nil { highlight(surface, immediate: false) }
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.focusChanged(true); surface?.updateSelection() }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focusChanged(false); surface?.updateSelection() }

        func textViewDidChangeSelection(_ textView: UITextView) { surface?.updateSelection() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { surface?.gutter.setNeedsDisplay() }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", range.length == 0, textView.markedTextRange == nil else { return true }
            let source = (textView.text ?? "") as NSString
            guard range.location <= source.length else { return true }
            var start = 0
            source.getLineStart(&start, end: nil, contentsEnd: nil, for: NSRange(location: range.location, length: 0))
            let indentation = source.substring(with: NSRange(location: start, length: range.location - start)).prefix { $0 == " " || $0 == "\t" }
            guard !indentation.isEmpty else { return true }
            textView.insertText("\n" + String(indentation))
            return false
        }

        private func highlight(_ surface: Surface, immediate: Bool) {
            let input = surface.textView
            highlighting.update(input.text, language: parent.language, palette: parent.palette,
                                layout: input.layoutManager, immediate: immediate) { [weak input] in
                input != nil && input?.markedTextRange == nil
            }
        }
    }

    final class Surface: UIView {
        let textView: InputView
        private let storage: NSTextStorage
        let gutter = Gutter()
        private var gutterWidth: NSLayoutConstraint!
        private var lineIndex = CodeLineIndex()
        private var palette = CodeBlockPalette(colors: [:])
        private let codeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        init() {
            let storage = NSTextStorage(), layout = ActiveLineLayout()
            let container = NSTextContainer(size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            self.storage = storage
            textView = InputView(frame: .zero, textContainer: container)
            super.init(frame: .zero)
            textView.font = codeFont
            textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 12, right: 8)
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.lineBreakMode = .byWordWrapping
            textView.textContainer.widthTracksTextView = true
            textView.alwaysBounceHorizontal = false
            textView.alwaysBounceVertical = true
            textView.showsHorizontalScrollIndicator = false
            textView.autocorrectionType = .no
            textView.spellCheckingType = .no
            textView.autocapitalizationType = .none
            textView.smartQuotesType = .no
            textView.smartDashesType = .no
            textView.smartInsertDeleteType = .no
            textView.keyboardAppearance = .dark
            textView.accessibilityLabel = "Code editor"
            textView.backgroundColor = .clear
            gutter.isAccessibilityElement = false
            gutter.isUserInteractionEnabled = false
            gutter.surface = self
            for child in [gutter, textView] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
            gutterWidth = gutter.widthAnchor.constraint(equalToConstant: 40)
            NSLayoutConstraint.activate([
                gutter.leadingAnchor.constraint(equalTo: leadingAnchor), gutter.topAnchor.constraint(equalTo: topAnchor),
                gutter.bottomAnchor.constraint(equalTo: bottomAnchor), gutterWidth,
                textView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), textView.trailingAnchor.constraint(equalTo: trailingAnchor),
                textView.topAnchor.constraint(equalTo: topAnchor), textView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) { return nil }

        func apply(_ palette: CodeBlockPalette) {
            self.palette = palette
            backgroundColor = palette.nativeColor("background")
            gutter.backgroundColor = palette.nativeColor("gutter")
            textView.tintColor = palette.nativeColor("cursor")
            textView.textColor = palette.nativeColor("text")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.tabStops = []
            paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: codeFont]).width * 4
            paragraph.lineSpacing = 2
            let attributes: [NSAttributedString.Key: Any] = [.font: codeFont, .foregroundColor: palette.nativeColor("text"), .paragraphStyle: paragraph, .ligature: 0]
            if textView.textStorage.length > 0 {
                textView.textStorage.addAttributes(attributes, range: NSRange(location: 0, length: textView.textStorage.length))
            }
            textView.typingAttributes = attributes
            updateSelection()
        }

        func updateLineIndex() {
            lineIndex.update(textView.text)
            gutterWidth.constant = max(40, CGFloat(String(lineIndex.starts.count).count) * 8 + 15)
            gutter.setNeedsDisplay()
        }

        func updateSelection() {
            let manager = textView.layoutManager, length = textView.textStorage.length
            let selection = NSIntersectionRange(textView.selectedRange, NSRange(location: 0, length: length))
            if let layout = manager as? ActiveLineLayout {
                let selected = textView.isFirstResponder && selection.length > 0 ? selection : nil
                layout.setSelectionHighlight(selected, color: palette.nativeColor("selection"))
                let index = lineIndex.line(at: textView.selectedRange.location)
                let start = lineIndex.starts[index]
                let end = index + 1 < lineIndex.starts.count ? lineIndex.starts[index + 1] : length
                let line = textView.isFirstResponder && selection.length == 0 ? NSRange(location: start, length: max(0, end - start)) : nil
                layout.setActiveLine(line, color: palette.nativeColor("activeLine"))
            }
            gutter.setNeedsDisplay()
        }

        override func layoutSubviews() { super.layoutSubviews(); gutter.setNeedsDisplay() }

        func drawLineNumbers(in rect: CGRect) {
            let layout = textView.layoutManager, container = textView.textContainer
            let inset = textView.textContainerInset.top - textView.contentOffset.y
            let visible = CGRect(x: 0, y: max(0, rect.minY - inset), width: textView.bounds.width, height: rect.height)
            let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
            let active = lineIndex.line(at: textView.selectedRange.location)
            let base = palette.nativeColor("lineNumber")
            func draw(_ line: Int, y: CGFloat) {
                guard y + codeFont.lineHeight >= rect.minY && y <= rect.maxY else { return }
                let number = String(line + 1) as NSString
                let color = textView.isFirstResponder && line == active ? palette.nativeColor("cursor") : base
                let attrs: [NSAttributedString.Key: Any] = [.font: codeFont, .foregroundColor: color]
                number.draw(at: CGPoint(x: gutter.bounds.width - 9 - number.size(withAttributes: attrs).width, y: y), withAttributes: attrs)
            }
            layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
                let start = layout.characterIndexForGlyph(at: range.location)
                let line = self.lineIndex.line(at: start)
                if self.lineIndex.starts[line] == start { draw(line, y: used.minY + inset) }
            }
            if lineIndex.starts.last == textView.textStorage.length {
                draw(lineIndex.starts.count - 1, y: layout.extraLineFragmentRect.minY + inset)
            }
            palette.nativeColor("text").withAlphaComponent(0.08).setFill()
            UIRectFill(CGRect(x: gutter.bounds.width - 1, y: rect.minY, width: 1, height: rect.height))
        }
    }

    final class Gutter: UIView {
        weak var surface: Surface?
        override func draw(_ rect: CGRect) { surface?.drawLineNumbers(in: rect) }
    }

    private final class ActiveLineLayout: NSLayoutManager {
        private var line: NSRange?
        private var fill = UIColor.clear
        private var selection: NSRange?
        private var selectionFill = UIColor.clear

        func setActiveLine(_ range: NSRange?, color: UIColor) {
            guard line != range || fill != color else { return }
            let previous = line
            line = range
            fill = color
            invalidateBackground(previous, range)
        }

        func setSelectionHighlight(_ range: NSRange?, color: UIColor) {
            guard selection != range || selectionFill != color else { return }
            let previous = selection
            selection = range
            selectionFill = color
            invalidateBackground(previous, range)
        }

        private func invalidateBackground(_ previous: NSRange?, _ range: NSRange?) {
            let text = NSRange(location: 0, length: textStorage?.length ?? 0)
            for item in [previous, range].compactMap({ $0 }) {
                let redraw = NSIntersectionRange(item, text)
                if redraw.length > 0 { invalidateDisplay(forCharacterRange: redraw) }
            }
        }

        override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
            if let line, line.length > 0, NSMaxRange(line) <= (textStorage?.length ?? 0) {
                let glyphs = NSIntersectionRange(glyphsToShow, glyphRange(forCharacterRange: line, actualCharacterRange: nil))
                if glyphs.length > 0, let context = UIGraphicsGetCurrentContext() {
                    context.saveGState()
                    context.setFillColor(fill.cgColor)
                    enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                        context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
                    }
                    context.restoreGState()
                }
            }
            if let selection, NSMaxRange(selection) <= (textStorage?.length ?? 0),
               let container = textContainers.first, let context = UIGraphicsGetCurrentContext() {
                let selectedGlyphs = glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
                let visible = NSIntersectionRange(glyphsToShow, selectedGlyphs)
                if visible.length > 0 {
                    context.saveGState()
                    context.setFillColor(selectionFill.cgColor)
                    enumerateEnclosingRects(forGlyphRange: visible, withinSelectedGlyphRange: selectedGlyphs, in: container) { rect, _ in
                        context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
                    }
                    context.restoreGState()
                }
            }
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        }
    }

    final class InputView: UITextView {
        override var keyCommands: [UIKeyCommand]? {
            (super.keyCommands ?? []) + [UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(insertIndentation))]
        }

        @objc private func insertIndentation() { if isFirstResponder { insertText("\t") } }
    }
}
#elseif os(macOS)
struct CodeBlockTextEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var code: String
    let language: String
    let palette: CodeBlockPalette
    var focusChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> Surface {
        let surface = Surface()
        surface.input.delegate = context.coordinator
        context.coordinator.apply(self, to: surface)
        return surface
    }

    func updateNSView(_ surface: Surface, context: Context) { context.coordinator.apply(self, to: surface) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeBlockTextEditor
        private weak var surface: Surface?
        private let highlighting = CodeTextHighlighting()
        private var palette: CodeBlockPalette?
        private var language: String?

        init(parent: CodeBlockTextEditor) { self.parent = parent }

        func apply(_ parent: CodeBlockTextEditor, to surface: Surface) {
            self.parent = parent
            self.surface = surface
            if surface.input.isEditable != parent.isEnabled { surface.input.isEditable = parent.isEnabled }
            let textChanged = surface.input.string != parent.code
            let styleChanged = palette != parent.palette || language != parent.language
            if textChanged { surface.input.string = parent.code; surface.updateLineIndex() }
            if palette != parent.palette { surface.apply(parent.palette) }
            palette = parent.palette
            language = parent.language
            if textChanged || styleChanged { highlight(surface, immediate: true) }
        }

        func textDidChange(_ notification: Notification) {
            guard let surface else { return }
            surface.updateLineIndex()
            parent.code = surface.input.string
            if !surface.input.hasMarkedText() { highlight(surface, immediate: false) }
        }

        func textViewDidChangeSelection(_ notification: Notification) { surface?.gutter.needsDisplay = true }

        private func highlight(_ surface: Surface, immediate: Bool) {
            let input = surface.input
            guard let layout = input.layoutManager else { return }
            highlighting.update(input.string, language: parent.language, palette: parent.palette,
                                layout: layout, immediate: immediate) { [weak input] in
                input?.hasMarkedText() == false
            }
        }
    }

    final class Surface: NSView {
        let input = NSTextView(usingTextLayoutManager: false)
        let gutter = Gutter()
        private let scroll = NSScrollView()
        private var gutterWidth: NSLayoutConstraint!
        private var lineIndex = CodeLineIndex()
        private var palette = CodeBlockPalette(colors: [:])
        private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        init() {
            super.init(frame: .zero)
            input.font = font
            input.textContainerInset = NSSize(width: 8, height: 10)
            input.textContainer?.lineFragmentPadding = 0
            input.textContainer?.widthTracksTextView = true
            input.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            input.isVerticallyResizable = true
            input.isHorizontallyResizable = false
            input.autoresizingMask = [.width]
            input.allowsUndo = true
            input.isRichText = false
            input.isAutomaticQuoteSubstitutionEnabled = false
            input.isAutomaticDashSubstitutionEnabled = false
            input.isAutomaticTextReplacementEnabled = false
            input.isAutomaticSpellingCorrectionEnabled = false
            input.setAccessibilityLabel("Code editor")
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.documentView = input
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            gutter.surface = self
            for child in [gutter, scroll] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
            gutterWidth = gutter.widthAnchor.constraint(equalToConstant: 40)
            NSLayoutConstraint.activate([
                gutter.leadingAnchor.constraint(equalTo: leadingAnchor), gutter.topAnchor.constraint(equalTo: topAnchor),
                gutter.bottomAnchor.constraint(equalTo: bottomAnchor), gutterWidth,
                scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) { return nil }

        func apply(_ palette: CodeBlockPalette) {
            self.palette = palette
            input.backgroundColor = palette.nativeColor("background")
            scroll.backgroundColor = input.backgroundColor
            input.insertionPointColor = palette.nativeColor("cursor")
            input.textColor = palette.nativeColor("text")
            input.selectedTextAttributes = [.backgroundColor: palette.nativeColor("selection"), .foregroundColor: palette.nativeColor("text")]
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.tabStops = []
            paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 4
            paragraph.lineSpacing = 2
            input.defaultParagraphStyle = paragraph
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.nativeColor("text"), .paragraphStyle: paragraph, .ligature: 0]
            if let storage = input.textStorage, storage.length > 0 {
                storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            }
            input.typingAttributes = attributes
            gutter.needsDisplay = true
        }

        func updateLineIndex() {
            lineIndex.update(input.string)
            gutterWidth.constant = max(40, CGFloat(String(lineIndex.starts.count).count) * 8 + 15)
            gutter.needsDisplay = true
        }

        @objc private func scrolled(_ notification: Notification) { gutter.needsDisplay = true }

        func drawLineNumbers(in rect: CGRect) {
            palette.nativeColor("gutter").setFill()
            NSBezierPath(rect: rect).fill()
            guard let layout = input.layoutManager, let container = input.textContainer else { return }
            let inset = input.textContainerOrigin.y - scroll.contentView.bounds.minY
            let visible = CGRect(x: 0, y: max(0, rect.minY - inset), width: scroll.contentSize.width, height: rect.height)
            let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
            let active = lineIndex.line(at: input.selectedRange().location)
            func draw(_ line: Int, y: CGFloat) {
                guard y >= rect.minY - 22 && y <= rect.maxY else { return }
                let number = String(line + 1) as NSString
                let color = input.window?.firstResponder === input && line == active ? palette.nativeColor("cursor") : palette.nativeColor("lineNumber")
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                number.draw(at: CGPoint(x: gutter.bounds.width - 9 - number.size(withAttributes: attrs).width, y: y), withAttributes: attrs)
            }
            layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
                let start = layout.characterIndexForGlyph(at: range.location)
                let line = self.lineIndex.line(at: start)
                if self.lineIndex.starts[line] == start { draw(line, y: used.minY + inset) }
            }
            if lineIndex.starts.last == input.textStorage?.length {
                draw(lineIndex.starts.count - 1, y: layout.extraLineFragmentRect.minY + inset)
            }
        }
    }

    final class Gutter: NSView {
        weak var surface: Surface?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { surface?.drawLineNumbers(in: dirtyRect) }
    }
}
#endif
