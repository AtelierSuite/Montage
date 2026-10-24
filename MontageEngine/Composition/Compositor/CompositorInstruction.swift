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
        /// A still image, read when the composition was built.
        case still(StillPicture)
        /// Text or a shape, drawn from the clip as it is at each frame.
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

    /// The composition track carrying the clip's picture, if it's video.
    var trackID: CMPersistentTrackID? {
        if case .track(let id) = source { return id }
        return nil
    }
}
