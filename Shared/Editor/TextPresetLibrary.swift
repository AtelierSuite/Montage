import Foundation
import MontageEngine
import Observation

/// Text styles saved to use again, kept for the app rather than the project,
/// so every project can use them.
@MainActor
@Observable
final class TextPresetLibrary {
    static let shared = TextPresetLibrary()

    private static let key = "TextPresets"

    private let defaults: UserDefaults
    /// In the order they were saved.
    private(set) var presets: [TextPreset] = []
    /// Saved presets this build can't read, such as ones a newer build
    /// wrote, kept as they were so saving doesn't lose them.
    private var unreadable: [Any] = []
    /// Whether what's stored couldn't be read at all, so it's left alone.
    private var isUnreadable = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key) else { return }
        guard let elements = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            isUnreadable = true
            return
        }
        // Each read on its own, so one that can't be read doesn't lose the rest.
        for element in elements {
            if let elementData = try? JSONSerialization.data(withJSONObject: element),
               let preset = try? JSONDecoder().decode(TextPreset.self, from: elementData) {
                presets.append(preset)
            } else {
                unreadable.append(element)
            }
        }
    }

    func save(_ preset: TextPreset) {
        presets.append(preset)
        store()
    }

    func remove(_ id: TextPreset.ID) {
        presets.removeAll { $0.id == id }
        store()
    }

    private func store() {
        guard !isUnreadable,
              let data = try? JSONEncoder().encode(presets),
              let readable = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let combined = try? JSONSerialization.data(withJSONObject: readable + unreadable)
        else { return }
        defaults.set(combined, forKey: Self.key)
    }
}
