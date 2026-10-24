import AppKit

/// A project's window.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        window.minSize = NSSize(width: 720, height: 480)
        window.tabbingMode = .preferred
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.center()
        windowFrameAutosaveName = "Project"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
