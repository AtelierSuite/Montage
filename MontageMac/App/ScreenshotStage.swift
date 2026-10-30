#if DEBUG
import AppKit
import CoreMedia

/// Sets the scene for an App Store screenshot, driven by
/// `Assets/App Store/capture-mac.sh`, which opens a sample project with
/// `-ScreenshotStage <name>` and captures the windows once it is ready.
///
/// Debug builds only: everything here is for the screenshots, and is never
/// meant to run for anyone else.
@MainActor
enum ScreenshotStage {
    static var requested: String? { UserDefaults.standard.string(forKey: "ScreenshotStage") }

    /// The window size a 2880 × 1800 capture needs on a Retina display.
    private static let windowSize = NSSize(width: 1440, height: 900)

    static func stage(_ name: String) {
        guard let document = NSApp.orderedDocuments.first as? ProjectDocument,
              let windowController = document.windowControllers.first as? ProjectWindowController,
              let window = windowController.window else {
            // The project is still opening.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { stage(name) }
            return
        }

        // On the Retina display, where the window is drawn at twice its size.
        let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            window.setFrame(NSRect(origin: NSPoint(x: visible.minX + 20, y: visible.maxY - windowSize.height - 20),
                                   size: windowSize), display: true)
        }
        NSApp.appearance = NSAppearance(named: name == "02-farm" ? .darkAqua : .aqua)

        // Where the playhead stands: over the inset in each project.
        let playback = document.editor.playback
        switch name {
        case "01-aquarium": playback.seek(to: CMTime(value: 3, timescale: 1))
        case "02-farm": playback.seek(to: CMTime(value: 6, timescale: 1))
        default: break
        }
        // The inset selected, so the inspector shows its settings rather
        // than standing empty. It is the one clip on the second track.
        let tracks = document.editor.project.tracks
        if tracks.count > 1, let inset = tracks[1].clips.first {
            document.editor.select(inset.id)
        }

        // In front, so the window is drawn active, once the media has loaded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            // Out of the library's search field, which takes focus on opening.
            window.makeFirstResponder(nil)
            // Titled as on a Mac that hides extensions, which is how most are
            // set, whatever this one's Finder shows. Named on the document,
            // as the window's title is set from its name again later.
            if let url = document.fileURL {
                document.displayName = url.deletingPathExtension().lastPathComponent
            }
            if name == "03-export" {
                windowController.exportMovie(nil)
            }
        }
    }
}
#endif
