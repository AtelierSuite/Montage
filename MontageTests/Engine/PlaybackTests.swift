import AVFoundation
import CoreMedia
@testable import MontageEngine
import Testing

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

struct ProjectSnapshotTests {
    @Test func readersSeeTheLatestProject() async {
        let snapshot = ProjectSnapshot(Project())
        var project = Project()
        project.settings.frameDuration = CMTime(value: 1, timescale: 60)
        snapshot.update(project)
        let duration = await Task.detached { snapshot.read { $0.settings.frameDuration } }.value
        #expect(duration == CMTime(value: 1, timescale: 60))
    }
}

struct RebuildTests {
    @Test func onlyChangesThatCanChangeTheCompositionRebuild() {
        let media = MediaItem(name: "A.mov", kind: .video, location: .package(path: "A.mov"), metadata: MediaMetadata())
        let clip = Clip(mediaID: media.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(2)))
        let project = Project(media: [media], tracks: [Track(kind: .video, clips: [clip])])
        #expect(!PlaybackController.needsRebuild(from: project, to: project))

        var effected = project
        effected.tracks[0].update(clip.id) { $0.effects = [Effect(.mosaic(Mosaic()))] }
        #expect(!PlaybackController.needsRebuild(from: project, to: effected))

        var moved = project
        moved.tracks[0].update(clip.id) { $0.timelineStart = seconds(1) }
        #expect(PlaybackController.needsRebuild(from: project, to: moved))

        var restyled = project
        restyled.tracks[0].update(clip.id) {
            $0.opacity = Animatable(0.5)
            $0.transform.scale = Animatable(0.5)
            $0.blendMode = .screen
        }
        #expect(!PlaybackController.needsRebuild(from: project, to: restyled))

        var quieter = project
        quieter.tracks[0].update(clip.id) { $0.volume = Animatable(0.5) }
        #expect(PlaybackController.needsRebuild(from: project, to: quieter))
    }
}

@MainActor
@Suite(.enabled(if: Samples.isAvailable, "Needs the sample media"))
struct PlaybackControllerTests {
    private let media = MediaItem(
        name: "IMG_3311.mp4", kind: .video, location: .package(path: "IMG_3311.mp4"),
        metadata: MediaMetadata(duration: CMTime(value: 11250, timescale: 1000), naturalSize: CGSize(width: 1920, height: 1080))
    )
    private let resolver = MediaResolver { item in
        guard case .package(let path) = item.location else { return nil }
        return Samples.url(path)
    }

    private func project(clipStart: CMTime = .zero) -> Project {
        let clip = Clip(mediaID: media.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(4)), timelineStart: clipStart)
        return Project(media: [media], tracks: [Track(kind: .video, clips: [clip])])
    }

    /// Waits for a condition, giving up after a few seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(condition())
    }

    @Test func buildsTheProjectToPlay() async throws {
        let controller = PlaybackController(project: project(), mediaResolver: resolver, rebuildDelay: .milliseconds(10))
        defer { controller.invalidate() }
        try await waitUntil { controller.composition != nil }
        #expect(controller.composition?.duration == seconds(4))
        #expect(controller.duration == seconds(4))
        #expect(controller.player.currentItem != nil)
        #expect(controller.hasContent)
    }

    @Test func aTailRingsOnWithoutMovingTheEnd() async throws {
        var project = project()
        project.tracks[0].update(project.tracks[0].clips[0].id) { $0.effects = [Effect(.delay(Delay()))] }
        let controller = PlaybackController(project: project, mediaResolver: resolver, rebuildDelay: .milliseconds(10))
        defer { controller.invalidate() }
        try await waitUntil { controller.composition != nil }
        // The composition runs on for the echoes; the timeline doesn't.
        #expect(controller.composition?.duration == seconds(5.5))
        #expect(controller.duration == seconds(4))
        controller.seek(to: seconds(5))
        #expect(controller.currentTime == seconds(4))

        // Playing into the tail, then shuttling back: from the end at once.
        controller.seek(to: seconds(3.9))
        controller.play()
        try await waitUntil { controller.player.currentTime() > seconds(5.2) }
        #expect(controller.currentTime == seconds(4))
        controller.shuttle(at: -1)
        // Left in the tail, the player would take over 1.4 seconds to get
        // back to 3.8; from the end, it takes 0.2 and a seek.
        let start = ContinuousClock.now
        try await waitUntil { controller.currentTime < seconds(3.8) }
        #expect(ContinuousClock.now - start < .milliseconds(1300))
        controller.pause()
    }

    @Test func steppingMovesAFrameAtATime() async throws {
        let controller = PlaybackController(project: project(), mediaResolver: resolver, rebuildDelay: .milliseconds(10))
        defer { controller.invalidate() }
        try await waitUntil { controller.composition != nil }
        let frame = CMTime(value: 1, timescale: 30)

        controller.seek(to: seconds(2))
        controller.step(by: 1)
        #expect(controller.currentTime == seconds(2) + frame)
        controller.step(by: -2)
        #expect(controller.currentTime == seconds(2) - frame)
        // Between frames, a step back lands on the frame showing.
        controller.seek(to: CMTime(value: 61, timescale: 60))
        controller.step(by: -1)
        #expect(controller.currentTime == seconds(1))

        controller.goToEnd()
        #expect(controller.currentTime == seconds(4))
        controller.step(by: 1)
        #expect(controller.currentTime == seconds(4))
        controller.goToStart()
        #expect(controller.currentTime == .zero)
        controller.step(by: -1)
        #expect(controller.currentTime == .zero)
    }

    @Test func scrubbingEndsOnTheExactTime() async throws {
        let controller = PlaybackController(project: project(), mediaResolver: resolver, rebuildDelay: .milliseconds(10))
        defer { controller.invalidate() }
        try await waitUntil { controller.composition != nil }

        controller.beginScrubbing()
        for step in 1...20 {
            controller.scrub(to: seconds(Double(step) * 0.1))
        }
        controller.endScrubbing()
        #expect(controller.currentTime == seconds(2))
        try await waitUntil { controller.player.currentTime() == seconds(2) }
    }

    @Test func shuttlingPlaysFasterOrBackwards() async throws {
        let controller = PlaybackController(project: project(), mediaResolver: resolver, rebuildDelay: .milliseconds(10))
        defer { controller.invalidate() }
        try await waitUntil { controller.composition != nil }

        controller.shuttle(at: 2)
        #expect(controller.isPlaying)
        #expect(controller.rate == 2)
        try await waitUntil { controller.currentTime > seconds(0.5) }
        controller.shuttle(at: 0)
        #expect(!controller.isPlaying)

        // Backwards from the start there's nowhere to go.
        controller.goToStart()
        controller.shuttle(at: -1)
        #expect(!controller.isPlaying)
        controller.seek(to: seconds(1))
        try await waitUntil { controller.player.currentTime() == seconds(1) }
        controller.shuttle(at: -1)
        #expect(controller.isPlaying)
        try await waitUntil { controller.currentTime < seconds(0.8) }
        controller.play()
        #expect(controller.rate == 1)
        controller.pause()
    }

    @Test func aRebuildKeepsThePlayheadWhereItWas() async throws {
        let controller = PlaybackController(project: project(), mediaResolver: resolver, rebuildDelay: .milliseconds(10))
        defer { controller.invalidate() }
        try await waitUntil { controller.composition != nil }
        controller.seek(to: seconds(3))
        let firstItem = controller.player.currentItem

        let moved = project(clipStart: seconds(1))
        controller.update(project: moved, mediaResolver: resolver)
        #expect(controller.snapshot.project == moved)
        try await waitUntil { controller.composition?.project == moved }
        #expect(controller.player.currentItem !== firstItem)
        #expect(controller.duration == seconds(5))
        #expect(controller.currentTime == seconds(3))
        try await waitUntil { controller.player.currentTime() == seconds(3) }
    }

    @Test func aParameterEditKeepsTheItemAndReachesTheCompositor() async throws {
        let controller = PlaybackController(project: project(), mediaResolver: resolver, rebuildDelay: .milliseconds(10))
        defer { controller.invalidate() }
        try await waitUntil { controller.composition != nil }
        controller.seek(to: seconds(2))
        let item = controller.player.currentItem

        var faded = controller.project
        faded.tracks[0].update(faded.tracks[0].clips[0].id) { $0.opacity = Animatable(0.25) }
        controller.update(project: faded, mediaResolver: resolver)
        #expect(!controller.isBuilding)
        #expect(controller.player.currentItem === item)
        // The compositor's instructions read the controller's snapshot.
        let instruction = try #require(controller.composition?.videoComposition?.instructions.first as? CompositorInstruction)
        #expect(instruction.snapshot === controller.snapshot)
        #expect(controller.currentTime == seconds(2))
    }

    @Test func aPausedParameterEditRedrawsTheFrame() async throws {
        let controller = PlaybackController(project: project(), mediaResolver: resolver, rebuildDelay: .milliseconds(10))
        defer { controller.invalidate() }
        try await waitUntil { controller.composition != nil }
        let item = try #require(controller.player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        try await waitUntil { item.status == .readyToPlay }
        controller.seek(to: seconds(2))
        try await waitUntil { output.hasNewPixelBuffer(forItemTime: seconds(2)) }
        #expect(try #require(centreBrightness(output, at: seconds(2))) > 0.1)

        var faded = controller.project
        faded.tracks[0].update(faded.tracks[0].clips[0].id) { $0.opacity = Animatable(0) }
        controller.update(project: faded, mediaResolver: resolver)
        #expect(controller.player.currentItem === item)
        try await waitUntil { output.hasNewPixelBuffer(forItemTime: seconds(2)) }
        #expect(try #require(centreBrightness(output, at: seconds(2))) < 0.02)
    }

    /// How bright the middle of the frame an output has for a time is.
    private func centreBrightness(_ output: AVPlayerItemVideoOutput, at time: CMTime) -> Double? {
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let pixel = base.advanced(by: CVPixelBufferGetHeight(buffer) / 2 * row + CVPixelBufferGetWidth(buffer) / 2 * 4)
            .assumingMemoryBound(to: UInt8.self)
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }

    @Test func editsCloseTogetherRebuildOnce() async throws {
        let controller = PlaybackController(project: project(), mediaResolver: resolver, rebuildDelay: .milliseconds(200))
        try await waitUntil { controller.composition != nil }
        defer { controller.invalidate() }
        let first = controller.composition?.composition

        for step in 1...5 {
            controller.update(project: project(clipStart: seconds(Double(step) * 0.1)), mediaResolver: resolver)
        }
        #expect(controller.isBuilding)
        #expect(controller.composition?.composition === first)
        try await waitUntil { !controller.isBuilding }
        #expect(controller.composition?.project.tracks.first?.clips.first?.timelineStart == seconds(0.5))
    }
}
