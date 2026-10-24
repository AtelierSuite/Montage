import CoreMedia
import MontageEngine
import SwiftUI

/// Laid over the timeline's clips: a diamond for each time the selected
/// clip has keyframes, and a warning on clips the composition had to leave
/// out of the picture for showing too many layers at once.
///
/// Tapping a diamond moves the playhead to it; dragging it along retimes
/// every keyframe there, frame by frame, as one undo step; its context menu
/// picks how they travel on, or takes them away.
struct TimelineKeyframes: View {
    @Environment(ProjectEditor.self) private var editor
    let layout: TimelineLayout
    /// The lanes' coordinate space, that drags are measured in.
    let space: String

    /// The keyframe time being dragged, as it was when the drag began, and
    /// where it's been dragged to.
    @State private var drag: (clipID: Clip.ID, index: Int, from: CMTime, to: CMTime)?
    @GestureState private var isDragging = false

    #if os(macOS)
    private let diamondSize = 9.0
    private let hitSize = 14.0
    #else
    private let diamondSize = 11.0
    private let hitSize = 30.0
    #endif

    var body: some View {
        ZStack(alignment: .topLeading) {
            badges
            if let clip = editor.selectedClip, let row = layout.rowIndex(of: editor.project.clip(id: clip.id)?.track.id ?? UUID()) {
                markers(for: clip, inRow: row)
            }
        }
        .onChange(of: isDragging) { _, isDragging in
            if !isDragging { endDrag() }
        }
    }

    // MARK: - Keyframes

    @ViewBuilder
    private func markers(for clip: Clip, inRow row: Int) -> some View {
        // While a drag goes on, the times as they were when it began, so
        // the diamond under the pointer stays the same one.
        let shown = drag.flatMap { editor.clipAtGestureStart($0.clipID) } ?? clip
        let times = shown.keyframeTimes
        let rect = layout.rect(of: shown, inRow: row)
        let atPlayhead = editor.keyframeTimeAtPlayhead(in: clip)
        ForEach(times.indices, id: \.self) { index in
            let time = drag?.index == index ? drag!.to : times[index]
            diamond(isCurrent: time == atPlayhead)
                .position(x: rect.minX + layout.x(time), y: rect.maxY - diamondSize / 2 - 3)
                .gesture(retiming(clip: shown, index: index, from: times[index]))
                .simultaneousGesture(TapGesture().onEnded {
                    editor.playback.seek(to: shown.timelineStart + times[index])
                })
                .contextMenu { menu(for: shown, at: times[index]) }
                .accessibilityElement()
                .accessibilityLabel(Text("Timeline.Keyframe"))
                .accessibilityValue(Text(verbatim: editor.playback.frames.timecode(shown.timelineStart + times[index])))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { editor.playback.seek(to: shown.timelineStart + times[index]) }
        }
    }

    private func diamond(isCurrent: Bool) -> some View {
        Rectangle()
            .fill(isCurrent ? Color.accentColor : .white)
            .frame(width: diamondSize * 0.72, height: diamondSize * 0.72)
            .overlay(Rectangle().stroke(.black.opacity(0.6), lineWidth: 0.75))
            .rotationEffect(.degrees(45))
            .frame(width: hitSize, height: hitSize)
            .contentShape(.rect)
    }

    @ViewBuilder
    private func menu(for clip: Clip, at time: CMTime) -> some View {
        let current = clip.keyframeInterpolation(at: time)
        Picker("Inspector.Keyframes.Easing", selection: Binding {
            current.map(EasingChoice.init)
        } set: { choice in
            if let choice {
                editor.setKeyframeInterpolation(choice.interpolation(keeping: current), at: time, ofClip: clip.id)
            }
        }) {
            ForEach(EasingChoice.allCases, id: \.self) { choice in
                Text(choice.title).tag(EasingChoice?.some(choice))
            }
        }
        Button("Inspector.Keyframes.Remove", systemImage: "trash", role: .destructive) {
            editor.removeKeyframes(at: time, ofClip: clip.id)
        }
    }

    private func retiming(clip: Clip, index: Int, from time: CMTime) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
            .updating($isDragging) { _, isDragging, _ in isDragging = true }
            .onChanged { value in
                let offset = editor.playback.frames.rounded(seconds: layout.seconds(atX: value.translation.width))
                let target = min(max(time + offset, .zero), clip.duration)
                drag = (clip.id, index, time, target)
                editor.moveKeyframes(ofClip: clip.id, from: time, to: target)
            }
            .onEnded { _ in endDrag() }
    }

    private func endDrag() {
        guard drag != nil else { return }
        drag = nil
        editor.endGesture()
    }

    // MARK: - Left out

    /// A warning at the top right of each clip left out of the picture for
    /// showing too many layers at once.
    private var badges: some View {
        let skipped = Set((editor.playback.composition?.skippedClips ?? []).filter { $0.reason == .tooManyLayers }.map(\.clipID))
        let clips = layout.rows.enumerated().flatMap { index, row in
            (row.track?.clips ?? []).filter { skipped.contains($0.id) }.map { ($0, index) }
        }
        return ForEach(clips, id: \.0.id) { clip, row in
            let rect = layout.rect(of: clip, inRow: row)
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 11))
                .padding(2)
                .background(.black.opacity(0.5), in: .rect(cornerRadius: 3))
                .position(x: max(rect.minX + 10, rect.maxX - 12), y: rect.minY + 11)
                .help(Text("Inspector.Layer.TooManyLayers"))
                .accessibilityLabel(Text("Inspector.Layer.TooManyLayers"))
        }
    }
}
