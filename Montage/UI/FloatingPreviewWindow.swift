import SwiftUI
import UIKit

/// Shows the floating preview in a window of its own, over the app's window
/// in the same scene, so it floats over everything in the app: the editor's
/// navigation bar included, which nothing inside the editor can draw over.
///
/// The window covers the screen, but only takes touches on the preview;
/// everywhere else they go through to the app underneath. Put this in the
/// editor while the preview floats, and the window goes when it does.
struct FloatingPreviewWindow: UIViewRepresentable {
    let preview: FloatingPreview

    func makeUIView(context: Context) -> HostView {
        HostView(preview: preview)
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.update(preview)
    }

    static func dismantleUIView(_ view: HostView, coordinator: ()) {
        view.closeWindow()
    }

    /// Nothing to see itself; it opens the window once it's in a scene.
    final class HostView: UIView {
        private var preview: FloatingPreview
        private var window_: PassthroughWindow?
        private var hosting: UIHostingController<FloatingPreview>?

        init(preview: FloatingPreview) {
            self.preview = preview
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene {
                openWindow(in: scene)
            } else {
                closeWindow()
            }
        }

        func update(_ preview: FloatingPreview) {
            self.preview = preview
            hosting?.rootView = wired(preview)
        }

        private func openWindow(in scene: UIWindowScene) {
            guard window_ == nil else { return }
            let window = PassthroughWindow(windowScene: scene)
            let hosting = UIHostingController(rootView: wired(preview))
            hosting.view.backgroundColor = .clear
            window.rootViewController = hosting
            window.backgroundColor = .clear
            // Over the app's window, under alerts.
            window.windowLevel = .normal + 1
            // Shown without becoming key, so the editor keeps the keyboard
            // and its shortcuts.
            window.isHidden = false
            window_ = window
            self.hosting = hosting
        }

        func closeWindow() {
            window_?.isHidden = true
            window_ = nil
            hosting = nil
        }

        /// The preview, telling the window where it is.
        private func wired(_ preview: FloatingPreview) -> FloatingPreview {
            var preview = preview
            preview.onFrameChange = { [weak self] frame in self?.window_?.touchableFrame = frame }
            return preview
        }
    }
}

/// A window that takes touches only within one frame, and lets the rest
/// through to the windows under it.
private final class PassthroughWindow: UIWindow {
    var touchableFrame = CGRect.zero

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard touchableFrame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }

    // Leaves the status bar to the app's own window.
    override var canBecomeKey: Bool { false }
}
