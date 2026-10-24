import AppKit

/// The Mac app: an AppKit document app, one window per project.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The application holds its delegate weakly.
    private static let shared = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = shared
        application.run()
    }
}
