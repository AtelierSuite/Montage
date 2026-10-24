import Foundation

/// Changes to the effects on a clip.
extension Project {
    /// Adds an effect after the clip's others. Returns false if there's no
    /// such clip.
    @discardableResult
    public mutating func addEffect(_ effect: Effect, toClip clipID: Clip.ID) -> Bool {
        changeEffects(ofClip: clipID) { $0.append(effect) }
    }

    public mutating func removeEffect(_ effectID: Effect.ID, fromClip clipID: Clip.ID) {
        changeEffects(ofClip: clipID) { $0.removeAll { $0.id == effectID } }
    }

    /// Changes one of a clip's effects in place.
    public mutating func updateEffect(_ effectID: Effect.ID, ofClip clipID: Clip.ID, _ change: (inout Effect) -> Void) {
        changeEffects(ofClip: clipID) { effects in
            guard let index = effects.firstIndex(where: { $0.id == effectID }) else { return }
            change(&effects[index])
        }
    }

    /// Moves an effect earlier (negative) or later (positive) in the order
    /// the clip applies them, stopping at either end.
    public mutating func moveEffect(_ effectID: Effect.ID, ofClip clipID: Clip.ID, by offset: Int) {
        changeEffects(ofClip: clipID) { effects in
            guard let index = effects.firstIndex(where: { $0.id == effectID }) else { return }
            let destination = min(max(index + offset, 0), effects.count - 1)
            effects.insert(effects.remove(at: index), at: destination)
        }
    }

    @discardableResult
    private mutating func changeEffects(ofClip clipID: Clip.ID, _ change: (inout [Effect]) -> Void) -> Bool {
        guard let trackIndex = tracks.firstIndex(where: { $0.clip(id: clipID) != nil }) else { return false }
        tracks[trackIndex].update(clipID) { change(&$0.effects) }
        return true
    }
}
