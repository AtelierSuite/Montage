import CoreMedia
import Foundation
import MontageEngine

/// The selected clip's keyframes, taken together: moving the playhead from
/// one to the next, retiming them and changing how they travel.
extension ProjectEditor {
    /// Half a frame: how near the playhead has to be to a keyframe to be on
    /// it, since a playing player's time falls between frames.
    private var keyframeTolerance: CMTime {
        CMTimeMultiplyByRatio(project.settings.frameDuration, multiplier: 1, divisor: 2)
    }

    /// Where the selected clip's last keyframe before the playhead is, on
    /// the timeline.
    var previousKeyframeTime: CMTime? {
        guard let clip = selectedClip else { return nil }
        return clip.keyframeTime(before: clip.localTime(playback.currentTime), tolerance: keyframeTolerance)
            .map { $0 + clip.timelineStart }
    }

    /// Where the selected clip's first keyframe after the playhead is, on
    /// the timeline.
    var nextKeyframeTime: CMTime? {
        guard let clip = selectedClip else { return nil }
        return clip.keyframeTime(after: clip.localTime(playback.currentTime), tolerance: keyframeTolerance)
            .map { $0 + clip.timelineStart }
    }

    func goToPreviousKeyframe() {
        if let time = previousKeyframeTime { playback.seek(to: time) }
    }

    func goToNextKeyframe() {
        if let time = nextKeyframeTime { playback.seek(to: time) }
    }

    /// The keyframe time, from the clip's start, that the playhead is on.
    func keyframeTimeAtPlayhead(in clip: Clip) -> CMTime? {
        let time = clip.localTime(playback.currentTime)
        let tolerance = keyframeTolerance
        return clip.keyframeTimes.first { $0 >= time - tolerance && $0 <= time + tolerance }
    }

    /// Changes how every parameter's keyframe at a time in a clip travels on.
    func setKeyframeInterpolation(
        _ interpolation: Interpolation, at time: CMTime, ofClip clipID: Clip.ID, continuously: Bool = false
    ) {
        changeClip(clipID, String(localized: "Action.ChangeEasing"), continuously: continuously) {
            $0.setKeyframeInterpolation(interpolation, at: time)
        }
    }

    /// Takes away every parameter's keyframe at a time in a clip.
    func removeKeyframes(at time: CMTime, ofClip clipID: Clip.ID) {
        changeClip(clipID, String(localized: "Action.RemoveKeyframes")) { $0.removeKeyframes(at: time) }
    }

    /// Moves a clip's keyframes at one time to another, as a drag goes; the
    /// drag is one undo step, ended by `endGesture`.
    func moveKeyframes(ofClip clipID: Clip.ID, from time: CMTime, to newTime: CMTime) {
        let frameDuration = project.settings.frameDuration
        changeClip(clipID, String(localized: "Action.MoveKeyframe"), continuously: true) {
            $0.moveKeyframes(from: time, to: newTime, frameDuration: frameDuration)
        }
    }
}
