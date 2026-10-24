import CoreMedia
import MontageEngine
import SwiftUI

/// A clip, as the inspector edits its own settings (where it sits, and how
/// its text or shape looks), read and set at the playhead.
@MainActor
struct ClipEditing {
    let editor: ProjectEditor
    let clip: Clip

    var time: CMTime { editor.clipTime(in: clip) }

    /// Edits one of the clip's keyframeable parameters.
    func parameter<Value>(_ keyPath: WritableKeyPath<Clip, MontageEngine.Animatable<Value>>) -> ParameterEditing<Value> {
        let editor = editor
        let clipID = clip.id
        return ParameterEditing(
            parameter: clip[keyPath: keyPath], time: time, canKeyframe: editor.isPlayheadOn(clip),
            change: { parameter, continuously in
                editor.changeClip(clipID, continuously: continuously) { $0[keyPath: keyPath] = parameter }
            },
            endChange: { editor.endClipChange() }
        )
    }

    /// A binding to a setting that isn't keyframed, each change an undo step.
    func binding<Value>(_ keyPath: WritableKeyPath<Clip, Value>) -> Binding<Value> {
        let editor = editor
        let clip = clip
        return Binding {
            clip[keyPath: keyPath]
        } set: { value in
            editor.changeClip(clip.id) { $0[keyPath: keyPath] = value }
        }
    }

    func change(_ change: (inout Clip) -> Void) {
        editor.changeClip(clip.id, change)
    }
}
