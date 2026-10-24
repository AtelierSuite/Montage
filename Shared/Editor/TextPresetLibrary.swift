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
    private(set) var presets: [TextPreset]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presets = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([TextPreset].self, from: $0) } ?? []
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
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.key) }
    }
}
