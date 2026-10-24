import CoreMedia
import MontageEngine
import SwiftUI

/// The inspector for a clip: its video effects in the order they apply,
/// each with its parameters at the playhead, and a menu to add more, then
/// its sound and audio effects.
struct ClipInspector: View {
    @Environment(ProjectEditor.self) private var editor
    let track: Track
    let clip: Clip

    var body: some View {
        let effects = clip.effects.filter(\.kind.isVideo)
        Form {
            Section {
                Text(verbatim: editor.project.mediaItem(id: clip.mediaID)?.name ?? "")
                    .font(.headline)
            }
            if track.kind == .video {
                ForEach(effects) { effect in
                    EffectSection(
                        editing: EffectEditing(editor: editor, clip: clip, effect: effect),
                        canMoveUp: effect.id != effects.first?.id, canMoveDown: effect.id != effects.last?.id
                    )
                }
                Section {
                    addMenu
                } footer: {
                    if effects.isEmpty {
                        Text("Inspector.Effects.None")
                    }
                }
            } else {
                Section {
                    Text("Inspector.Effects.AudioClip")
                        .foregroundStyle(.secondary)
                }
            }
            AudioEffectsSection(clipID: clip.id)
        }
        .formStyle(.grouped)
    }

    private var addMenu: some View {
        Menu {
            Button("Effect.ColorCorrection", systemImage: "camera.filters") {
                editor.addEffect(.colorCorrection(ColorCorrection()), toClip: clip.id)
            }
            Button("Effect.Mosaic", systemImage: "square.grid.3x3.fill") {
                editor.addEffect(.mosaic(Mosaic()), toClip: clip.id)
            }
        } label: {
            Label("Inspector.AddEffect", systemImage: "plus")
        }
    }
}

/// One effect on a clip, as the inspector edits it: its parameters, read
/// and set at the playhead.
@MainActor
struct EffectEditing {
    let editor: ProjectEditor
    let clip: Clip
    let effect: Effect

    var time: CMTime { editor.clipTime(in: clip) }

    /// Edits one of the effect's parameters.
    func parameter<Value>(_ keyPath: WritableKeyPath<Effect, MontageEngine.Animatable<Value>>) -> ParameterEditing<Value> {
        let editor = editor
        let clipID = clip.id
        let effectID = effect.id
        return ParameterEditing(
            parameter: effect[keyPath: keyPath], time: time, canKeyframe: editor.isPlayheadOn(clip),
            change: { parameter, continuously in
                editor.changeEffect(effectID, ofClip: clipID, continuously: continuously) { $0[keyPath: keyPath] = parameter }
            },
            endChange: { editor.endEffectChange() }
        )
    }

    /// A binding to part of the effect that isn't keyframed, such as its
    /// style, each change an undo step.
    func binding<Value>(_ keyPath: WritableKeyPath<Effect, Value>) -> Binding<Value> {
        let editor = editor
        let clipID = clip.id
        let effectID = effect.id
        return Binding {
            effect[keyPath: keyPath]
        } set: { value in
            editor.changeEffect(effectID, ofClip: clipID) { $0[keyPath: keyPath] = value }
        }
    }

    func change(_ change: (inout Effect) -> Void) {
        editor.changeEffect(effect.id, ofClip: clip.id, change)
    }
}

/// An effect's section: its name, a switch to turn it off, its parameters
/// and its mask, and a menu to reorder or remove it.
private struct EffectSection: View {
    @Environment(ProjectEditor.self) private var editor
    let editing: EffectEditing
    let canMoveUp: Bool
    let canMoveDown: Bool

    var body: some View {
        let effect = editing.effect
        Section {
            switch effect.kind {
            case .colorCorrection:
                ColorCorrectionControls(editing: editing)
            case .mosaic:
                MosaicControls(editing: editing)
            case .gain, .pan, .equalizer, .delay, .reverb:
                EmptyView()
            case .unsupported:
                Text("Inspector.Effect.Unsupported")
                    .foregroundStyle(.secondary)
            }
            if !effect.kind.isUnsupported {
                MaskControls(editing: editing)
            }
        } header: {
            HStack {
                Toggle(isOn: editing.binding(\.isEnabled)) {
                    Text(effect.kind.title)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                // Turned on, it would do nothing.
                .disabled(effect.kind.isUnsupported)
                Spacer()
                Menu {
                    Button("Inspector.Effect.MoveUp", systemImage: "arrow.up") {
                        editor.moveEffect(effect.id, ofClip: editing.clip.id, by: -1)
                    }
                    .disabled(!canMoveUp)
                    Button("Inspector.Effect.MoveDown", systemImage: "arrow.down") {
                        editor.moveEffect(effect.id, ofClip: editing.clip.id, by: 1)
                    }
                    .disabled(!canMoveDown)
                    Divider()
                    Button("Inspector.Effect.Remove", systemImage: "trash", role: .destructive) {
                        editor.removeEffect(effect.id, fromClip: editing.clip.id)
                    }
                } label: {
                    Label("Inspector.Effect.Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

extension Effect.Kind {
    /// The effect's name, as the inspector heads it.
    var title: LocalizedStringKey {
        switch self {
        case .colorCorrection: "Effect.ColorCorrection"
        case .mosaic: "Effect.Mosaic"
        // Not shown with the video effects; their own inspector names them.
        case .gain, .pan, .equalizer, .delay, .reverb: "Effect.Audio"
        case .unsupported(let effect): "Effect.Unsupported \(effect.name)"
        }
    }

    /// Whether the effect came from another app and can't run here, so it's
    /// only kept, to go back out with the project.
    var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }
}

/// Each kind of video effect's parameters, reached by key path, so a
/// control can edit one of them without unpacking the kind.
extension Effect {
    var colorCorrection: ColorCorrection {
        get {
            if case .colorCorrection(let correction) = kind { return correction }
            return ColorCorrection()
        }
        set { kind = .colorCorrection(newValue) }
    }

    var mosaic: Mosaic {
        get {
            if case .mosaic(let mosaic) = kind { return mosaic }
            return Mosaic()
        }
        set { kind = .mosaic(newValue) }
    }

    /// The mask, or a new one for a control to show while there's none.
    var maskOrDefault: Mask {
        get { mask ?? Mask(.rectangle) }
        set { mask = newValue }
    }
}
