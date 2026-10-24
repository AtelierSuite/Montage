import AppKit
import SwiftUI

/// Window > Exports: every export the app has going, from any project,
/// shown when an export starts.
@MainActor
final class ExportsWindowController: NSWindowController {
    static let shared = ExportsWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: true
        )
        window.title = String(localized: "Export.Progress.Title")
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ExportProgressView(queue: ExportCenter.queue))
        window.setContentSize(NSSize(width: 420, height: 320))
        window.center()
        super.init(window: window)
        windowFrameAutosaveName = "Exports"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
