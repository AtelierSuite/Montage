import Foundation
import Observation

/// How preview plays, the same in every open project and kept for next
/// time: whether large video plays from proxies.
@MainActor
@Observable
final class PreviewSettings {
    static let shared = PreviewSettings()
    /// Posted when a setting changes, for every open project's editor.
    static let didChange = Notification.Name("PreviewSettings.DidChange")

    private static let usesProxiesKey = "Preview.UsesProxies"

    var usesProxies: Bool {
        didSet {
            guard usesProxies != oldValue else { return }
            UserDefaults.standard.set(usesProxies, forKey: Self.usesProxiesKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private init() {
        usesProxies = UserDefaults.standard.bool(forKey: Self.usesProxiesKey)
    }
}
