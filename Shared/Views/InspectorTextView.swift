#if os(macOS)
import AppKit
import SwiftUI

/// The inspector's box for a text clip's words, on the Mac: an AppKit text
/// view that leaves undo to the project. SwiftUI's `TextEditor` lets its
/// text view put its own typing steps in the document's undo manager, beside
/// the project's, so Undo while typing took back keystrokes the project's
/// steps knew nothing of.
struct InspectorTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: TextSelection?
    /// Called when typing stops: the box loses the keyboard, or Undo or Redo
    /// is chosen in it.
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let view = scrollView.documentView as? NSTextView else { return scrollView }
        let editing = WordsTextView(frame: view.frame, textContainer: view.textContainer)
        editing.autoresizingMask = view.autoresizingMask
        editing.minSize = view.minSize
        editing.maxSize = view.maxSize
        editing.isVerticallyResizable = true
        editing.isHorizontallyResizable = false
        editing.onEnd = { [weak coordinator = context.coordinator] in coordinator?.parent.onEnd() }
        editing.drawsBackground = false
        editing.isRichText = false
        editing.importsGraphics = false
        editing.allowsUndo = false
        editing.isAutomaticQuoteSubstitutionEnabled = false
        editing.font = .preferredFont(forTextStyle: .body)
        editing.textContainerInset = NSSize(width: 0, height: 4)
        editing.string = text
        editing.delegate = context.coordinator
        scrollView.documentView = editing
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scrollView.documentView as? NSTextView else { return }
        // Left alone while a word is being composed, as with an input method,
        // which a reload would throw away.
        guard view.string != text, !view.hasMarkedText() else { return }
        let selected = view.selectedRange()
        context.coordinator.isLoading = true
        defer { context.coordinator.isLoading = false }
        view.string = text
        let length = view.string.utf16.count
        view.setSelectedRange(NSRange(location: min(selected.location, length),
                                      length: min(selected.length, max(0, length - selected.location))))
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? NSTextView)?.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InspectorTextView
        /// Whether the words are being put in from the project, which isn't
        /// typing, so isn't sent back.
        var isLoading = false

        init(_ parent: InspectorTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !isLoading else { return }
            parent.text = view.string
            // Again, now the words it was made in are the project's.
            select(in: view)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !isLoading else { return }
            select(in: view)
        }

        private func select(in view: NSTextView) {
            let string = view.string
            let range = Range(view.selectedRange(), in: string) ?? string.endIndex..<string.endIndex
            parent.selection = TextSelection(range: range)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEnd()
        }
    }

    /// Undo and redo stop typing first, so they take back or put back the
    /// whole of it, as the one step it is.
    final class WordsTextView: NSTextView {
        var onEnd: (() -> Void)?

        @objc func undo(_ sender: Any?) {
            onEnd?()
            nextResponder?.tryToPerform(#selector(undo(_:)), with: sender)
        }

        @objc func redo(_ sender: Any?) {
            onEnd?()
            nextResponder?.tryToPerform(#selector(redo(_:)), with: sender)
        }

        override func validateMenuItem(_ item: NSMenuItem) -> Bool {
            switch item.action {
            case #selector(undo(_:)), #selector(redo(_:)):
                // As the window would, so the menu names the project's steps.
                return window?.validateMenuItem(item) ?? false
            default:
                return super.validateMenuItem(item)
            }
        }
    }
}
#endif
