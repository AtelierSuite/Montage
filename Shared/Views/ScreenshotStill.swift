import AVFoundation
import MontageEngine
import SwiftUI

/// A still of the project in place of a picture the player can't show, for
/// the App Store screenshots taken in the iOS Simulator, which turns down
/// every video composition and so can't play a project at all.
///
/// Only in debug builds, and only when launched with `-ScreenshotStill YES`
/// (see `Assets/App Store/capture.sh`): it stands in over the preview once
/// playback has failed, rendering the frame at the playhead from the same
/// composition the player was given. `-ScreenshotTime <seconds>` moves the
/// playhead there first. Anywhere else it draws nothing.
struct ScreenshotStill: View {
    let playback: PlaybackController

    var body: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ScreenshotStill"), playback.playbackError != nil {
            Still(playback: playback)
        }
        #endif
    }
}

#if DEBUG
private struct Still: View {
    let playback: PlaybackController
    @State private var image: CGImage?

    var body: some View {
        Color.black
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                }
            }
            .allowsHitTesting(false)
            // Named once the still is in, for the screenshot test to wait on.
            .accessibilityElement()
            .accessibilityIdentifier(image == nil ? "" : "screenshotStill")
            .onAppear {
                let seconds = UserDefaults.standard.double(forKey: "ScreenshotTime")
                if seconds > 0 { playback.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
            }
            .task(id: frame) { await render() }
    }

    /// What the still shows: rendered again when the playhead moves, and once
    /// the composition is in, if it wasn't at first.
    private struct Frame: Hashable {
        var time: CMTime
        var composition: ObjectIdentifier?
    }

    private var frame: Frame {
        Frame(time: playback.currentTime, composition: playback.composition.map { ObjectIdentifier($0.composition) })
    }

    private func render() async {
        guard let built = playback.composition else { return }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // A simulator busy starting up now and then fails a render, so it's
        // given a few goes.
        for _ in 0..<10 {
            if let frame = try? await generator.image(at: playback.currentTime).image {
                image = frame
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
    }
}
#endif
