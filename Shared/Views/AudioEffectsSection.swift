import CoreMedia
import MontageEngine
import SwiftUI

/// A clip's sound in the inspector: how loud it's playing, and its audio
/// effects in the order they run, each with its settings, a switch to turn it
/// off and a button to remove it.
///
/// Settings are shown, and changed, at the playhead: a keyframed one gets a
/// keyframe there. While a slider is dragged, the change is played straight
/// away and made one undo step when it's let go.
struct AudioEffectsSection: View {
    @Environment(ProjectEditor.self) private var editor
    let clipID: Clip.ID

    var body: some View {
        if let (track, clip) = editor.project.clip(id: clipID), Self.hasSound(clip, on: track, in: editor.project) {
            Section {
                AudioLevelMeter(clipID: clipID)
                addMenu
            } header: {
                Text("Inspector.Audio")
            }
            ForEach(clip.effects.filter { !$0.kind.isVideo }) { effect in
                Section {
                    // The playhead only matters, and is only followed, for
                    // settings that change over time.
                    let time = effect.kind.isKeyframed ? localTime(in: clip) : .zero
                    AudioEffectEditor(effect: effect, time: time, keyframeTime: keyframeTime(in: clip)) { kind, isFinal in
                        change(effect.id, isFinal: isFinal) { $0.kind = kind }
                    }
                    .disabled(!effect.isEnabled)
                } header: {
                    header(for: effect)
                }
            }
        }
    }

    /// Whether the clip plays any sound: an audio clip, or a video clip whose
    /// sound hasn't been split off, of media that has some.
    static func hasSound(_ clip: Clip, on track: Track, in project: Project) -> Bool {
        guard track.kind == .audio || !clip.isAudioDetached else { return false }
        guard let item = project.mediaItem(id: clip.mediaID) else { return false }
        return item.kind != .image && (item.metadata.hasAudio || item.metadata.duration == .zero)
    }

    /// Where a diamond sets or takes away a keyframe: the playhead's time
    /// in the clip, read when it's pressed, or nil while it's off the clip.
    private func keyframeTime(in clip: Clip) -> () -> CMTime? {
        let editor = editor
        return { editor.isPlayheadOn(clip) ? editor.clipTime(in: clip) : nil }
    }

    /// The playhead's time from the clip's start, kept within the clip.
    private func localTime(in clip: Clip) -> CMTime {
        min(max(clip.localTime(editor.playback.currentTime), .zero), clip.duration)
    }

    private var addMenu: some View {
        Menu("Inspector.Audio.AddEffect") {
            Button("AudioEffect.Gain") { add(.gain(Gain())) }
            Button("AudioEffect.Pan") { add(.pan(Pan())) }
            Button("AudioEffect.Equalizer") { add(.equalizer(Equalizer())) }
            Button("AudioEffect.Delay") { add(.delay(Delay())) }
            Button("AudioEffect.Reverb") { add(.reverb(Reverb())) }
        }
    }

    private func header(for effect: Effect) -> some View {
        HStack {
            Text(AudioEffectEditor.name(of: effect.kind))
            Spacer()
            Toggle("Inspector.Effect.Enabled", isOn: Binding {
                effect.isEnabled
            } set: { isOn in
                change(effect.id, isFinal: true) { $0.isEnabled = isOn }
            })
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            // Turned on, it would do nothing.
            .disabled(effect.kind.isUnsupported)
            Button("Inspector.Effect.Remove", systemImage: "minus.circle") { remove(effect.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    // MARK: - Editing

    private func add(_ kind: Effect.Kind) {
        editor.perform(String(localized: "Action.AddEffect")) { project in
            update(&project) { $0.effects.append(Effect(kind)) }
        }
    }

    private func remove(_ effectID: Effect.ID) {
        editor.perform(String(localized: "Action.RemoveEffect")) { project in
            update(&project) { $0.effects.removeAll { $0.id == effectID } }
        }
    }

    /// Changes one of the clip's effects: played at once, and, once it's
    /// final, made an undo step.
    private func change(_ effectID: Effect.ID, isFinal: Bool, _ body: @escaping (inout Effect) -> Void) {
        let apply: (inout Project) -> Void = { project in
            update(&project) { clip in
                guard let index = clip.effects.firstIndex(where: { $0.id == effectID }) else { return }
                body(&clip.effects[index])
            }
        }
        let actionName = String(localized: "Action.ChangeEffect")
        if editor.gestureBaseline == nil, isFinal {
            editor.perform(actionName, apply)
            return
        }
        if editor.gestureBaseline == nil { editor.beginGesture(actionName) }
        editor.updateGesture(apply)
        if isFinal { editor.endGesture() }
    }

    private func update(_ project: inout Project, _ body: (inout Clip) -> Void) {
        guard let (track, _) = project.clip(id: clipID), let index = project.trackIndex(id: track.id) else { return }
        project.tracks[index].update(clipID, body)
    }
}

/// One audio effect's settings.
struct AudioEffectEditor: View {
    let effect: Effect
    /// The time from the clip's start that the settings are shown at.
    let time: CMTime
    /// Where a diamond sets or takes away a keyframe, read when it's
    /// pressed; nil while the playhead's off the clip.
    var keyframeTime: () -> CMTime? = { nil }
    /// Hands back the effect with a setting changed, and whether the change
    /// is final or a step of a drag.
    let onChange: (Effect.Kind, Bool) -> Void

    static func name(of kind: Effect.Kind) -> String {
        switch kind {
        case .gain: String(localized: "AudioEffect.Gain")
        case .pan: String(localized: "AudioEffect.Pan")
        case .equalizer: String(localized: "AudioEffect.Equalizer")
        case .delay: String(localized: "AudioEffect.Delay")
        case .reverb: String(localized: "AudioEffect.Reverb")
        case .colorCorrection, .mosaic: ""
        case .unsupported(let effect): String(format: String(localized: "Effect.Unsupported"), effect.name)
        }
    }

    private static let rooms: [Reverb.Room] = [.smallRoom, .mediumRoom, .largeHall, .cathedral, .plate]

    var body: some View {
        switch effect.kind {
        case .gain(let gain):
            slider("AudioEffect.Gain.Level", gain, \.decibels, range: -24...24, format: Self.decibels, wrap: Effect.Kind.gain)
        case .pan(let pan):
            slider("AudioEffect.Pan.Position", pan, \.position, range: -1...1, format: Self.pan, wrap: Effect.Kind.pan)
        case .equalizer(let equalizer):
            ForEach(equalizer.bands.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    Text(verbatim: String(format: String(localized: "AudioEffect.Equalizer.Band"), (index + 1).formatted()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    slider("AudioEffect.Equalizer.Frequency", equalizer, \.bands[index].frequency, range: 20...20_000,
                           scale: .logarithmic, format: Self.hertz, wrap: Effect.Kind.equalizer)
                    slider("AudioEffect.Equalizer.Gain", equalizer, \.bands[index].gain, range: -24...24,
                           format: Self.decibels, wrap: Effect.Kind.equalizer)
                    slider("AudioEffect.Equalizer.Bandwidth", equalizer, \.bands[index].bandwidth, range: 0.05...5,
                           format: Self.octaves, wrap: Effect.Kind.equalizer)
                }
            }
        case .delay(let delay):
            slider("AudioEffect.Delay.Time", delay, \.time, range: 0.01...2, format: Self.seconds, wrap: Effect.Kind.delay)
            slider("AudioEffect.Delay.Feedback", delay, \.feedback, range: 0...0.95, format: Self.percent, wrap: Effect.Kind.delay)
            slider("AudioEffect.Mix", delay, \.mix, range: 0...1, format: Self.percent, wrap: Effect.Kind.delay)
        case .reverb(let reverb):
            Picker("AudioEffect.Reverb.Room", selection: Binding {
                reverb.room
            } set: { room in
                var reverb = reverb
                reverb.room = room
                onChange(.reverb(reverb), true)
            }) {
                ForEach(Self.rooms, id: \.self) { room in
                    Text(Self.name(of: room)).tag(room)
                }
            }
            slider("AudioEffect.Mix", reverb, \.mix, range: 0...1, format: Self.percent, wrap: Effect.Kind.reverb)
        case .colorCorrection, .mosaic:
            EmptyView()
        case .unsupported:
            Text("Inspector.Effect.Unsupported")
                .foregroundStyle(.secondary)
        }
    }

    /// A slider for one of the effect's parameters, at `time`.
    private func slider<Parameters>(
        _ title: LocalizedStringKey, _ parameters: Parameters, _ path: WritableKeyPath<Parameters, MontageEngine.Animatable<Double>>,
        range: ClosedRange<Double>, scale: AudioParameterSlider.Scale = .linear, format: @escaping (Double) -> String,
        wrap: @escaping (Parameters) -> Effect.Kind
    ) -> some View {
        let time = self.time
        let onChange = self.onChange
        func changed(_ value: Double, isFinal: Bool) {
            var parameters = parameters
            parameters[keyPath: path] = parameters[keyPath: path].setting(value, at: time)
            onChange(wrap(parameters), isFinal)
        }
        let keyframeTime = self.keyframeTime
        let parameter = parameters[keyPath: path]
        return AudioParameterSlider(
            title: title, value: parameter.value(at: time), range: range, scale: scale, format: format,
            onPreview: { changed($0, isFinal: false) }, onCommit: { changed($0, isFinal: true) },
            keyframe: AudioParameterSlider.Keyframing(
                isOnKeyframe: parameter.hasKeyframe(at: time), isAnimated: parameter.isAnimated,
                // Not read from the playhead here, which would redraw the
                // settings every frame while playing.
                isEnabled: true,
                toggle: {
                    guard let time = keyframeTime() else { return }
                    var parameters = parameters
                    parameters[keyPath: path].toggleKeyframe(at: time)
                    onChange(wrap(parameters), true)
                }
            )
        )
    }

    private static func name(of room: Reverb.Room) -> LocalizedStringKey {
        switch room {
        case .smallRoom: "AudioEffect.Reverb.Room.SmallRoom"
        case .mediumRoom: "AudioEffect.Reverb.Room.MediumRoom"
        case .largeHall: "AudioEffect.Reverb.Room.LargeHall"
        case .cathedral: "AudioEffect.Reverb.Room.Cathedral"
        case .plate: "AudioEffect.Reverb.Room.Plate"
        }
    }

    // MARK: - Formatting

    private static func decibels(_ value: Double) -> String {
        String(format: String(localized: "AudioEffect.Decibels"), value.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false))))
    }

    private static func pan(_ value: Double) -> String {
        if abs(value) < 0.005 { return String(localized: "AudioEffect.Pan.Centre") }
        let amount = Int((abs(value) * 100).rounded())
        return String(format: String(localized: value < 0 ? "AudioEffect.Pan.Left" : "AudioEffect.Pan.Right"), amount.formatted())
    }

    private static func hertz(_ value: Double) -> String {
        Measurement(value: value, unit: UnitFrequency.hertz)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    private static func octaves(_ value: Double) -> String {
        String(format: String(localized: "AudioEffect.Equalizer.Octaves"), value.formatted(.number.precision(.fractionLength(2))))
    }

    private static func seconds(_ value: Double) -> String {
        Measurement(value: value * 1000, unit: UnitDuration.milliseconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

private extension Effect.Kind {
    /// Whether any of the effect's settings has keyframes.
    var isKeyframed: Bool {
        switch self {
        case .gain(let gain): gain.decibels.isAnimated
        case .pan(let pan): pan.position.isAnimated
        case .equalizer(let equalizer):
            equalizer.bands.contains { $0.frequency.isAnimated || $0.gain.isAnimated || $0.bandwidth.isAnimated }
        case .delay(let delay): delay.time.isAnimated || delay.feedback.isAnimated || delay.mix.isAnimated
        case .reverb(let reverb): reverb.mix.isAnimated
        case .colorCorrection, .mosaic, .unsupported: false
        }
    }
}

private extension MontageEngine.Animatable<Double> {
    /// The parameter set to a value at a time from the clip's start: the
    /// value throughout if it has no keyframes, or else a keyframe at the
    /// time, so a keyframed parameter keeps moving.
    func setting(_ newValue: Double, at time: CMTime) -> Self {
        var parameter = self
        if parameter.isAnimated {
            let interpolation = keyframes.last { $0.time <= time }?.interpolation ?? .linear
            parameter.setKeyframe(Keyframe(time: time, value: newValue, interpolation: interpolation))
        } else {
            parameter.value = newValue
        }
        return parameter
    }
}

