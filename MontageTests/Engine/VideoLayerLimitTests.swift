import CoreMedia
@testable import MontageEngine
import Testing

struct VideoLayerLimitTests {
    private func clip(_ start: Double, _ length: Double) -> Clip {
        Clip(mediaID: UUID(), sourceRange: range(0, length), timelineStart: seconds(start))
    }

    @Test func layersPastTheLimitAreHeldBackFromTheTop() {
        let first = clip(0, 4), second = clip(1, 2), third = clip(2, 2), later = clip(5, 2)
        let project = Project(tracks: [
            Track(kind: .video, clips: [first]),
            Track(kind: .video, clips: [second]),
            Track(kind: .video, clips: [third, later]),
        ])
        #expect(VideoLayerLimit.clipsOverLimit(in: project, limit: 3).isEmpty)
        // Two layers at most: the third shows while both under it do, but the
        // clip after it on the same track shows on its own.
        #expect(VideoLayerLimit.clipsOverLimit(in: project, limit: 2) == [third.id])
        #expect(VideoLayerLimit.clipsOverLimit(in: project, limit: 1) == [second.id, third.id])
    }

    @Test func hiddenTracksAndClipsThatOnlyTouchDontCount() {
        let first = clip(0, 2), touching = clip(2, 2), hidden = clip(0, 4)
        let project = Project(tracks: [
            Track(kind: .video, clips: [first]),
            Track(kind: .video, clips: [hidden], isHidden: true),
            Track(kind: .video, clips: [touching]),
        ])
        #expect(VideoLayerLimit.clipsOverLimit(in: project, limit: 1).isEmpty)
    }
}

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
    CMTimeRange(start: seconds(start), duration: seconds(duration))
}
