import AVFoundation
import CoreGraphics
import CoreMedia

/// One stretch of the timeline for `VideoCompositor`: the layers showing
/// through it, bottom first, and where to read their clips' parameters.
///
/// The builder makes one for each stretch between the points where a clip
/// starts or ends. What's placed where is fixed when the composition is
/// built; how each layer looks (its transform, opacity, blend mode and
/// effects) is read from `snapshot` every frame, so an edit to those shows on
/// the next frame without a rebuild.
final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    /// The clips showing through the stretch, bottom layer first.
    let layers: [CompositorLayer]
    /// The project as of its latest edit, where the clips' parameters are read.
    let snapshot: ProjectSnapshot
    /// The project's frame size: the space clip transforms and effects work in,
    /// whatever size the render context draws at.
    let renderSize: CGSize
    /// Whether to render with the GPU. Off for an export that may carry on in
    /// the background, where iOS can take the GPU away.
    let usesGPU: Bool

    // Every frame is drawn, even with one layer, since its parameters can
    // change from one frame to the next.
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    var requiredSourceTrackIDs: [NSValue]? { layers.compactMap { $0.trackID.map { NSNumber(value: $0) } } }

    init(timeRange: CMTimeRange, layers: [CompositorLayer], snapshot: ProjectSnapshot, renderSize: CGSize, usesGPU: Bool) {
        self.timeRange = timeRange
        self.layers = layers
        self.snapshot = snapshot
        self.renderSize = renderSize
        self.usesGPU = usesGPU
    }
}

/// A clip as one layer of a frame: where its picture comes from, and how to
/// turn that picture upright.
struct CompositorLayer: Sendable {
    enum Source: Sendable {
        /// A frame of the composition track carrying the clip's video.
        case track(CMPersistentTrackID)
        /// A still image, drawn in place of the frames of the filler its
        /// clip is placed with.
        case still(StillImage)
        /// Text or a shape, drawn from the clip as it is at each frame, in
        /// place of the filler's frames.
        case drawn
    }

    let source: Source
    /// The clip as it was when the composition was built: where it starts,
    /// which its keyframes are timed from, and its parameters should it be
    /// gone from the snapshot before the rebuild that drops it.
    let clip: Clip
    /// The size of the media's frames as stored.
    let naturalSize: CGSize
    /// How the media's frames are turned to show upright.
    let preferredTransform: CGAffineTransform
    /// The transition the clip is in, through the stretch, if it's in one:
    /// set on both its clips' layers, which come one after the other.
    var transition: CompositorTransition?

    init(
        source: Source, clip: Clip, naturalSize: CGSize, preferredTransform: CGAffineTransform,
        transition: CompositorTransition? = nil
    ) {
        self.source = source
        self.clip = clip
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.transition = transition
    }

    /// The composition track carrying the clip's picture, if it's video.
    var trackID: CMPersistentTrackID? {
        if case .track(let id) = source { return id }
        return nil
    }
}

/// A transition as the compositor draws it: the two clips' layers mixed into
/// one, from the outgoing clip's picture to the incoming one's.
struct CompositorTransition: Equatable, Sendable {
    let id: Transition.ID
    let kind: Transition.Kind
    /// The clip it goes to; the other layer is the clip it comes from.
    let incomingClipID: Clip.ID
    /// Where it plays on the timeline.
    let timelineRange: CMTimeRange

    init(_ placed: PlacedTransition) {
        id = placed.id
        kind = placed.kind
        incomingClipID = placed.incoming.id
        timelineRange = placed.timelineRange
    }

    /// How far through it a time is, from 0 to 1.
    func progress(at time: CMTime) -> Double {
        guard timelineRange.duration > .zero else { return 1 }
        return min(max((time - timelineRange.start).seconds / timelineRange.duration.seconds, 0), 1)
    }
}
