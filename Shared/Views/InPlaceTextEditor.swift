import CoreGraphics
import CoreMedia
import CoreText
import MontageEngine
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A text layer's words, typed into where the layer shows in the preview:
/// laid over it at its size and turned as it's turned, in its font, sizes
/// and colours. Each piece keeps its own formatting as it's typed around,
/// and what's typed goes into the clip as it's typed, as one undo step.
///
/// Return or Escape stops editing, as does clicking or tapping away;
/// Shift-Return starts a new line, as Option-Return also does on a Mac.
struct InPlaceTextEditor: View {
    @Environment(ProjectEditor.self) private var editor
    let clip: Clip
    let layer: LayerPlacement
    let mapping: PreviewMapping

    var body: some View {
        let transform = layer.transform
        // The layer's own scale and turn, from where its picture shows.
        let layerScale = max(hypot(transform.a, transform.b), 1e-3)
        let angle = atan2(transform.b, transform.a)
        let points = mapping.scale * layerScale
        let text = clip.textContent
        let display = TextDisplay(style: text.style, at: editor.clipTime(in: clip), points: points)
        // As wide as the words, wrapped where the renderer wraps them, and
        // centred where the layer is, as the renderer draws them: lines
        // aligned to one side line up with the drawn ones.
        let size = InPlaceTextLayout.size(of: text, display: display, wrapWidth: text.style.wrapWidth * mapping.renderSize.width * points)
        let width = size.width, height = size.height

        InPlaceTextView(text: text, display: display) { [id = clip.id] string, formattings in
            editor.editText(of: id, string, formattings: formattings)
        } onEnd: { [id = clip.id] in
            editor.endEditingText(of: id)
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.55)))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
        }
        .rotationEffect(.radians(angle))
        .position(mapping.viewPoint(fromRender: layer.center))
        .accessibilityLabel(Text("Inspector.Text.Words"))
    }
}

/// How the words being typed look: the text's style at the playhead, in
/// the view's points.
struct TextDisplay: Equatable {
    var fontFamily: String
    var fontSize: Double
    var weight: FontWeight
    var isItalic: Bool
    var color: RGBAColor
    var alignment: MontageEngine.TextAlignment
    var letterSpacing: Double
    var lineSpacing: Double

    init(style: TextStyle, at time: CMTime, points: Double) {
        fontFamily = style.fontFamily
        fontSize = max(1, style.fontSize.value(at: time) * points)
        weight = style.weight
        isItalic = style.isItalic
        // Text with no fill shows its outline; either way it has to show.
        color = style.fill.style == .none ? (style.outline.isEnabled ? style.outline.color.value(at: time) : .white)
            : style.fill.color.value(at: time)
        alignment = style.alignment
        letterSpacing = style.letterSpacing.value(at: time) * points
        lineSpacing = style.lineSpacing.value(at: time) * points
    }

    /// What a piece formatted so is typed in.
    func attributes(for formatting: TextRun.Formatting, tag: Int) -> [NSAttributedString.Key: Any] {
        let font = FontResolver.font(
            family: fontFamily, size: fontSize, weight: formatting.weight ?? weight, isItalic: formatting.isItalic ?? isItalic
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        if lineSpacing >= 0 {
            paragraph.lineSpacing = lineSpacing
        } else {
            // Lines drawn closer than the font's own spacing, as the
            // renderer's spacing adjustment draws them; a paragraph's
            // spacing can't go below nothing, so the lines' height comes in.
            let height = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
            paragraph.minimumLineHeight = max(1, height + lineSpacing)
            paragraph.maximumLineHeight = max(1, height + lineSpacing)
        }
        #if os(macOS)
        let platformFont = font as NSFont
        let platformColor = NSColor(cgColor: (formatting.color ?? color).cgColor) ?? .white
        #else
        let platformFont = font as UIFont
        let platformColor = UIColor(cgColor: (formatting.color ?? color).cgColor)
        #endif
        return [
            .font: platformFont, .foregroundColor: platformColor, .kern: letterSpacing, .paragraphStyle: paragraph,
            TextContent.formattingAttribute: tag,
        ]
    }

    /// Tagged words, in a text view's storage, made to look so where they
    /// are, so the selection and any word being composed stay.
    func restyle(_ storage: NSMutableAttributedString, formattings: [TextRun.Formatting]) {
        let whole = NSRange(location: 0, length: storage.length)
        var pieces: [(NSRange, Int)] = []
        storage.enumerateAttribute(TextContent.formattingAttribute, in: whole) { value, range, _ in
            pieces.append((range, (value as? Int).flatMap { formattings.indices.contains($0) ? $0 : nil } ?? 0))
        }
        storage.beginEditing()
        for (range, tag) in pieces { storage.setAttributes(attributes(for: formattings[tag], tag: tag), range: range) }
        storage.endEditing()
    }

    /// Tagged words, as `TextContent.tagged()` gives them, made to look so.
    func styled(_ string: NSAttributedString, formattings: [TextRun.Formatting]) -> NSAttributedString {
        let styled = NSMutableAttributedString(attributedString: string)
        let whole = NSRange(location: 0, length: styled.length)
        string.enumerateAttribute(TextContent.formattingAttribute, in: whole) { value, range, _ in
            let tag = (value as? Int).flatMap { formattings.indices.contains($0) ? $0 : nil } ?? 0
            styled.setAttributes(attributes(for: formattings[tag], tag: tag), range: range)
        }
        return styled
    }
}

#if os(macOS)
/// The words in an AppKit text view, which keeps each piece's attributes,
/// its formatting's tag among them, as it's typed around.
struct InPlaceTextView: NSViewRepresentable {
    var text: TextContent
    var display: TextDisplay
    var onChange: (NSAttributedString, [TextRun.Formatting]) -> Void
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = EditingTextView(frame: .zero)
        view.onEnd = { [weak coordinator = context.coordinator] in coordinator?.end() }
        view.drawsBackground = false
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.usesFontPanel = false
        view.insertionPointColor = .white
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        context.coordinator.load(into: view)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        context.coordinator.watchClicks(away: view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Left alone while a word is being composed, as with an input method,
        // which a reload would throw away; the next update catches up.
        guard !view.hasMarkedText() else { return }
        // Words or formatting changed from elsewhere, such as the inspector,
        // or only a new look, which is put on the words as they are.
        if coordinator.wordsChanged(text) {
            let selection = view.selectedRange()
            coordinator.load(into: view)
            let length = view.string.utf16.count
            view.setSelectedRange(NSRange(location: min(selection.location, length),
                                          length: min(selection.length, max(0, length - selection.location))))
        } else if display != coordinator.display, let storage = view.textStorage {
            coordinator.restyle(storage)
            view.typingAttributes = coordinator.restyled(view.typingAttributes)
        }
        coordinator.centre(view)
    }

    static func dismantleNSView(_ view: NSTextView, coordinator: Coordinator) {
        // Taken away in the middle of an update, as when the playhead moves
        // off the layer: what was typed is kept once the update's done.
        Task { @MainActor in coordinator.end() }
    }

    /// How tall the words are laid out at a width, at least a line.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InPlaceTextView
        private(set) var display: TextDisplay?
        private var formattings: [TextRun.Formatting] = []
        /// The words as the view last had them, to tell changes made
        /// elsewhere by.
        private var synced: [TextRun] = []
        private var hasEnded = false
        private var clickMonitor: Any?

        init(_ parent: InPlaceTextView) {
            self.parent = parent
        }

        /// Whether the words or their formatting are no longer what the view
        /// shows, as after formatting from the inspector.
        func wordsChanged(_ text: TextContent) -> Bool {
            text.runs != synced
        }

        /// Puts the new look on the words in place, keeping the selection.
        func restyle(_ storage: NSMutableAttributedString) {
            display = parent.display
            parent.display.restyle(storage, formattings: formattings)
        }

        /// Typing attributes in the new look, for the formatting they're
        /// tagged with.
        func restyled(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            let tag = (attributes[TextContent.formattingAttribute] as? Int).flatMap { formattings.indices.contains($0) ? $0 : nil } ?? 0
            return parent.display.attributes(for: formattings[tag], tag: tag)
        }

        private func sync(_ string: NSAttributedString) {
            var text = parent.text
            text.setWords(from: string, formattings: formattings)
            synced = text.runs
        }

        /// A click anywhere in the window but the words stops typing, even
        /// on something that doesn't take the keyboard from them.
        func watchClicks(away view: NSTextView) {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak view] event in
                // Local monitors are called on the main thread.
                MainActor.assumeIsolated {
                    guard let self, let view, event.window === view.window else { return }
                    let point = view.convert(event.locationInWindow, from: nil)
                    if !view.bounds.contains(point) {
                        Task { @MainActor in self.end() }
                    }
                }
                return event
            }
        }

        func load(into view: NSTextView) {
            let tagged = parent.text.tagged()
            synced = parent.text.runs
            formattings = tagged.formattings
            display = parent.display
            view.textStorage?.setAttributedString(parent.display.styled(tagged.string, formattings: formattings))
            view.typingAttributes = parent.display.attributes(for: formattings[0], tag: 0)
            if let last = view.textStorage, last.length > 0 {
                view.typingAttributes = last.attributes(at: last.length - 1, effectiveRange: nil)
            }
        }

        /// Puts the words in the middle of the box, top to bottom, as they
        /// are in the layer.
        func centre(_ view: NSTextView) {
            guard let container = view.textContainer, let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = max(layout.usedRect(for: container).height, parent.display.fontSize)
            let inset = max(0, (view.bounds.height - used) / 2)
            if abs(view.textContainerInset.height - inset) > 0.5 {
                view.textContainerInset = NSSize(width: 0, height: inset)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !hasEnded else { return }
            sync(view.attributedString())
            parent.onChange(view.attributedString(), formattings)
            centre(view)
        }

        func textDidEndEditing(_ notification: Notification) {
            end()
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    view.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    end()
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                view.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                end()
                return true
            default:
                return false
            }
        }

        func end() {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
            guard !hasEnded else { return }
            hasEnded = true
            parent.onEnd()
        }
    }

    /// Takes the keyboard as soon as it's in a window, and pastes plain
    /// text. Undo and redo stop typing first, so they take back or put back
    /// the whole of it, as the one step it is.
    final class EditingTextView: NSTextView {
        var onEnd: (() -> Void)?
        private var hasFocused = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !hasFocused, let window else { return }
            hasFocused = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                window.makeFirstResponder(self)
            }
        }

        /// Pasted words take on the formatting they're pasted into, rather
        /// than bringing their own fonts and colours.
        override func paste(_ sender: Any?) {
            pasteAsPlainText(sender)
        }

        @objc func undo(_ sender: Any?) {
            onEnd?()
            window?.makeFirstResponder(nil)
            NSApp.sendAction(#selector(undo(_:)), to: nil, from: sender)
        }

        @objc func redo(_ sender: Any?) {
            onEnd?()
            window?.makeFirstResponder(nil)
            NSApp.sendAction(#selector(redo(_:)), to: nil, from: sender)
        }
    }
}
#else
/// The words in a UIKit text view, which keeps each piece's attributes, its
/// formatting's tag among them, as it's typed around.
struct InPlaceTextView: UIViewRepresentable {
    var text: TextContent
    var display: TextDisplay
    var onChange: (NSAttributedString, [TextRun.Formatting]) -> Void
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = EditingTextView()
        view.onEscape = { [weak coordinator = context.coordinator] in coordinator?.end() }
        view.onNewLine = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.insertNewLine(in: view)
        }
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.allowsEditingTextAttributes = false
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.tintColor = .white
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = .zero
        view.returnKeyType = .done
        view.delegate = context.coordinator
        context.coordinator.load(into: view)
        let end = view.endOfDocument
        view.selectedTextRange = view.textRange(from: end, to: end)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard view.markedTextRange == nil else { return }
        if coordinator.wordsChanged(text) {
            let selection = view.selectedRange
            coordinator.load(into: view)
            let length = (view.text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length),
                                         length: min(selection.length, max(0, length - selection.location)))
        } else if display != coordinator.display {
            coordinator.restyle(view.textStorage)
            view.typingAttributes = coordinator.restyled(view.typingAttributes)
        }
        coordinator.centre(view)
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        // Taken away in the middle of an update, as when the playhead moves
        // off the layer: what was typed is kept once the update's done.
        Task { @MainActor in coordinator.end() }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InPlaceTextView
        private(set) var display: TextDisplay?
        private var formattings: [TextRun.Formatting] = []
        /// The words as the view last had them, to tell changes made
        /// elsewhere by.
        private var synced: [TextRun] = []
        private var hasEnded = false

        init(_ parent: InPlaceTextView) {
            self.parent = parent
        }

        /// Whether the words or their formatting are no longer what the view
        /// shows, as after formatting from the inspector.
        func wordsChanged(_ text: TextContent) -> Bool {
            text.runs != synced
        }

        /// Puts the new look on the words in place, keeping the selection.
        func restyle(_ storage: NSMutableAttributedString) {
            display = parent.display
            parent.display.restyle(storage, formattings: formattings)
        }

        /// Typing attributes in the new look, for the formatting they're
        /// tagged with.
        func restyled(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            let tag = (attributes[TextContent.formattingAttribute] as? Int).flatMap { formattings.indices.contains($0) ? $0 : nil } ?? 0
            return parent.display.attributes(for: formattings[tag], tag: tag)
        }

        private func sync(_ string: NSAttributedString) {
            var text = parent.text
            text.setWords(from: string, formattings: formattings)
            synced = text.runs
        }

        func load(into view: UITextView) {
            let tagged = parent.text.tagged()
            synced = parent.text.runs
            formattings = tagged.formattings
            display = parent.display
            let styled = parent.display.styled(tagged.string, formattings: formattings)
            view.attributedText = styled
            view.typingAttributes = styled.length > 0 ? styled.attributes(at: styled.length - 1, effectiveRange: nil)
                : parent.display.attributes(for: formattings[0], tag: 0)
        }

        func centre(_ view: UITextView) {
            let used = max(InPlaceTextLayout.height(of: view.attributedText, width: view.bounds.width), parent.display.fontSize)
            let inset = max(0, (view.bounds.height - used) / 2)
            if abs(view.textContainerInset.top - inset) > 0.5 {
                view.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
            }
        }

        func textViewDidChange(_ view: UITextView) {
            guard !hasEnded else { return }
            // With no words left, typing starts again in the first formatting.
            if view.attributedText.length == 0, let display {
                view.typingAttributes = display.attributes(for: formattings[0], tag: 0)
            }
            sync(view.attributedText)
            parent.onChange(view.attributedText, formattings)
            centre(view)
        }

        /// Whether a new line is being put in on purpose, with Shift-Return,
        /// rather than Return ending the typing.
        private var isInsertingNewLine = false

        func insertNewLine(in view: UITextView) {
            isInsertingNewLine = true
            view.insertText("\n")
            isInsertingNewLine = false
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", !isInsertingNewLine else { return true }
            end()
            return false
        }

        func textViewDidEndEditing(_ view: UITextView) {
            end()
        }

        func end() {
            guard !hasEnded else { return }
            hasEnded = true
            parent.onEnd()
        }
    }

    /// Escape on a hardware keyboard stops typing, and Shift-Return starts
    /// a new line.
    final class EditingTextView: UITextView {
        var onEscape: (() -> Void)?
        var onNewLine: (() -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
            escape.wantsPriorityOverSystemBehavior = true
            let newLine = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(newLine))
            newLine.wantsPriorityOverSystemBehavior = true
            return [escape, newLine] + (super.keyCommands ?? [])
        }

        @objc private func escape() {
            onEscape?()
        }

        @objc private func newLine() {
            onNewLine?()
        }
    }
}
#endif

/// Measuring the words being typed.
enum InPlaceTextLayout {
    /// Room past the words' own width, so the text view doesn't wrap a line
    /// the renderer keeps whole.
    private static let slack = 4.0

    /// The size of the words laid out no wider than `wrapWidth`, in the
    /// view's points: at least a letter wide and a line tall, so there's
    /// somewhere to type with no words.
    static func size(of text: TextContent, display: TextDisplay, wrapWidth: Double) -> CGSize {
        let tagged = text.tagged()
        let styled = display.styled(tagged.string.length > 0 ? tagged.string : NSAttributedString(string: " "),
                                    formattings: tagged.formattings)
        let rect = styled.boundingRect(with: CGSize(width: max(1, wrapWidth), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let width = min(max(ceil(rect.width) + slack, display.fontSize * 0.6), max(1, wrapWidth) + slack)
        return CGSize(width: width, height: max(ceil(rect.height), display.fontSize * 1.2))
    }

    static func height(of string: NSAttributedString, width: Double) -> Double {
        let measured = string.length > 0 ? string : NSAttributedString(string: " ")
        let rect = measured.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(rect.height)
    }
}
