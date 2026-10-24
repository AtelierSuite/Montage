import CoreGraphics
import CoreMedia
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
/// Shift-Return or Option-Return starts a new line on a Mac.
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
        let width = max(text.style.wrapWidth * mapping.renderSize.width, layer.pictureRect.width) * points
        let measured = InPlaceTextView.height(of: text, display: display, width: width)
        let height = max(layer.pictureRect.height * points, measured)

        InPlaceTextView(text: text, display: display) { string, formattings in
            editor.editText(string, formattings: formattings)
        } onEnd: {
            editor.endEditingText()
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
        paragraph.lineSpacing = max(0, lineSpacing)
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
        // Words changed from elsewhere, such as the inspector, or a new look.
        if view.string != text.string || display != coordinator.display {
            let selection = view.selectedRange()
            coordinator.load(into: view)
            let length = view.string.utf16.count
            view.setSelectedRange(NSRange(location: min(selection.location, length),
                                          length: min(selection.length, max(0, length - selection.location))))
        }
        coordinator.centre(view)
    }

    static func dismantleNSView(_ view: NSTextView, coordinator: Coordinator) {
        coordinator.end()
    }

    /// How tall the words are laid out at a width, at least a line.
    static func height(of text: TextContent, display: TextDisplay, width: Double) -> Double {
        InPlaceTextLayout.height(of: text, display: display, width: width)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InPlaceTextView
        private(set) var display: TextDisplay?
        private var formattings: [TextRun.Formatting] = []
        private var hasEnded = false
        private var clickMonitor: Any?

        init(_ parent: InPlaceTextView) {
            self.parent = parent
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

    /// Takes the keyboard as soon as it's in a window. Undo and redo stop
    /// typing first, so they take back or put back the whole of it, as the
    /// one step it is.
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
        if view.text != text.string || display != coordinator.display {
            let selection = view.selectedRange
            coordinator.load(into: view)
            let length = (view.text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length),
                                         length: min(selection.length, max(0, length - selection.location)))
        }
        coordinator.centre(view)
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.end()
    }

    static func height(of text: TextContent, display: TextDisplay, width: Double) -> Double {
        InPlaceTextLayout.height(of: text, display: display, width: width)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InPlaceTextView
        private(set) var display: TextDisplay?
        private var formattings: [TextRun.Formatting] = []
        private var hasEnded = false

        init(_ parent: InPlaceTextView) {
            self.parent = parent
        }

        func load(into view: UITextView) {
            let tagged = parent.text.tagged()
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
            parent.onChange(view.attributedText, formattings)
            centre(view)
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
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

    /// Escape on a hardware keyboard stops typing.
    final class EditingTextView: UITextView {
        var onEscape: (() -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
            escape.wantsPriorityOverSystemBehavior = true
            return [escape] + (super.keyCommands ?? [])
        }

        @objc private func escape() {
            onEscape?()
        }
    }
}
#endif

/// Measuring the words being typed.
enum InPlaceTextLayout {
    static func height(of text: TextContent, display: TextDisplay, width: Double) -> Double {
        let tagged = text.tagged()
        let styled = display.styled(tagged.string.length > 0 ? tagged.string : NSAttributedString(string: " "),
                                    formattings: tagged.formattings)
        return max(height(of: styled, width: width), display.fontSize * 1.2)
    }

    static func height(of string: NSAttributedString, width: Double) -> Double {
        let measured = string.length > 0 ? string : NSAttributedString(string: " ")
        let rect = measured.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(rect.height)
    }
}
