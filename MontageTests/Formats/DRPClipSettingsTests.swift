import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Clip settings in the shape Blackmagic's training projects have them
/// (issue #61), built at test time. No real export is read here.
struct DRPClipSettingsTests {
    private typealias Writer = ResolveBlobWriter

    private func frames(_ count: Int64) -> CMTime {
        CMTime(value: count, timescale: 24)
    }

    private func filters(_ filters: [Data], zstd: Bool = true) throws -> [ResolveBlobs.Filter] {
        try ResolveBlobs.filters(Writer.effectFilters(filters, zstd: zstd))
    }

    private func clip(duration: Int64 = 48) -> Clip {
        Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: frames(24), duration: frames(duration)))
    }

    private func apply(
        _ list: [Data], to clip: inout Clip, isVideo: Bool = true, inPoint: Int64 = 24
    ) throws -> [ResolveClipSettings.Note] {
        ResolveClipSettings.apply(
            try filters(list), to: &clip, isVideo: isVideo, inPoint: inPoint, frameDuration: frames(1)
        )
    }

    // MARK: - The blob

    @Test func readsFiltersTheirParametersAndKeyframes() throws {
        let read = try filters([
            Writer.filter(4, [
                Writer.parameter(42, .double(1.5)), nil, nil,
                Writer.parameter(40, .double(0.1), keyframes: [
                    .init(frame: -2, value: 0.25), .init(frame: 40, value: -0.5, curved: true), .init(frame: 70, value: 0),
                ]),
            ]),
            Writer.filter(2, [Writer.parameter(0, .enumeration(6)), nil]),
            Writer.openFX("com.blackmagicdesign.resolvefx.dropshadow"),
        ], zstd: false)
        #expect(read.map(\.type) == [4, 2, 50])
        #expect(read[0].parameters[42] == .init(value: .double(1.5), keyframes: []))
        #expect(read[0].parameters[40]?.keyframes == [
            .init(frame: -2, value: 0.25), .init(frame: 40, value: -0.5), .init(frame: 70, value: 0),
        ])
        #expect(read[0].parameters.count == 2)
        #expect(read[1].parameters[0]?.number == 6)
        #expect(read[1].parameters.count == 1)
        #expect(read[2].plugin == "com.blackmagicdesign.resolvefx.dropshadow")
    }

    @Test func refusesKeyframesWhoseLengthIsWrong() throws {
        var list = Writer.keyframeList([.init(frame: 0, value: 1)])
        #expect(try ResolveBlobs.keyframes(list).count == 1)
        list.append(0)
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.keyframes(list) }
        // A curved keyframe whose handles are missing.
        var curved = Writer.keyframeList([.init(frame: 0, value: 1, curved: true)])
        curved.removeLast(48)
        curved.replaceSubrange(0..<4, with: [0xFF, 0xFF, 0xFF, 0xF0])
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.keyframes(curved) }
    }

    // MARK: - What they come to

    /// The groups Resolve lists on a clip with nothing changed, as in a
    /// real project: Transform, Cropping, Composite and Retime and Scaling
    /// with every parameter empty.
    @Test func leavesAClipWithDefaultGroupsAsItIs() throws {
        var clip = clip()
        let notes = try apply([
            Writer.filter(4, Array(repeating: nil, count: 12)), Writer.filter(6, Array(repeating: nil, count: 6)),
            Writer.filter(2, [nil, nil]), Writer.filter(44, Array(repeating: nil, count: 5)),
        ], to: &clip)
        #expect(notes.isEmpty)
        #expect(clip.transform == ClipTransform() && clip.opacity == Animatable(1) && clip.volume == Animatable(1))
        #expect(clip.blendMode == .normal && clip.effects.isEmpty)
    }

    @Test func readsZoomAndPosition() throws {
        var clip = clip()
        let notes = try apply([
            Writer.filter(4, [
                Writer.parameter(42, .double(0.3)), Writer.parameter(43, .double(0.3)), nil, nil,
                Writer.parameter(41, .double(-0.285)),
            ]),
        ], to: &clip)
        #expect(notes.isEmpty)
        #expect(clip.transform.scale == Animatable(0.3))
        let position = clip.transform.position.value
        #expect(abs(position.x - 0.5) < 1e-9 && abs(position.y - 0.785) < 1e-9)
    }

    /// Keyframes count frames of the source, as the clip's in point does,
    /// and X and Y have keyframes of their own.
    @Test func keyframesPositionFromTheClipsInPoint() throws {
        var clip = clip()
        _ = try apply([
            Writer.filter(4, [
                nil, nil, nil,
                Writer.parameter(40, .double(0.25), keyframes: [.init(frame: 26, value: 0.25), .init(frame: 50, value: -0.25)]),
                Writer.parameter(41, keyframes: [.init(frame: 26, value: 0.5), .init(frame: 38, value: 0, curved: true)]),
            ]),
        ], to: &clip)
        let keyframes = clip.transform.position.keyframes
        #expect(keyframes.map(\.time) == [frames(2), frames(14), frames(26)])
        #expect(keyframes.map(\.value) == [CGPoint(x: 0.75, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.25, y: 0.5)])
        #expect(clip.transform.position.value == CGPoint(x: 0.75, y: 0))
    }

    @Test func reportsUnevenZoomAndOtherTransformSettings() throws {
        var clip = clip()
        let notes = try apply([
            Writer.filter(4, [
                Writer.parameter(42, .double(2)), Writer.parameter(43, .double(1)), nil, nil, nil, nil,
                Writer.parameter(48, .pair(0.1, -0.5)),
            ]),
        ], to: &clip)
        #expect(clip.transform.scale == Animatable(2))
        #expect(notes == [.uneven("Zoom"), .setting("Rotation, anchor point, pitch, yaw or flip")])
    }

    @Test func readsOpacityAndCompositeMode() throws {
        var clip = clip()
        let notes = try apply([Writer.filter(2, [Writer.parameter(0, .enumeration(6)), Writer.parameter(1, .double(60))])], to: &clip)
        #expect(notes.isEmpty)
        #expect(clip.opacity == Animatable(0.6))
        #expect(clip.blendMode == .overlay)

        var keyed = self.clip()
        let others = try apply([
            Writer.filter(2, [
                Writer.parameter(0, .enumeration(27)),
                Writer.parameter(1, .double(100), keyframes: [.init(frame: 24, value: 100), .init(frame: 48, value: 25)]),
            ]),
        ], to: &keyed)
        #expect(keyed.opacity.keyframes.map(\.value) == [1, 0.25])
        #expect(keyed.blendMode == .normal)
        #expect(others == [.setting("Composite mode")])
        #expect(ResolveClipSettings.blendModes[4] == .multiply && ResolveClipSettings.blendModes[5] == .screen)
    }

    @Test func fadesThePictureInAndOut() throws {
        var clip = clip()
        let notes = try apply([Writer.filter(72, [Writer.parameter(137, .double(12)), Writer.parameter(138, .double(24))])], to: &clip)
        #expect(notes.isEmpty)
        #expect(clip.opacity.keyframes.map(\.time) == [.zero, frames(12), frames(24), frames(48)])
        #expect(clip.opacity.keyframes.map(\.value) == [0, 1, 1, 0])

        // Opacity keyframed already: the fade is reported instead.
        var keyed = self.clip()
        let keyedNotes = try apply([
            Writer.filter(2, [nil, Writer.parameter(1, keyframes: [.init(frame: 24, value: 100), .init(frame: 30, value: 50)])]),
            Writer.filter(72, [Writer.parameter(137, .double(12)), nil]),
        ], to: &keyed)
        #expect(keyed.opacity.keyframes.count == 2)
        #expect(keyedNotes == [.setting("Fade")])
    }

    @Test func readsVolumeInDecibelsWithFades() throws {
        var clip = clip()
        let notes = try apply([
            Writer.filter(124, [
                Writer.parameter(95, .double(-6), keyframes: [.init(frame: 30, value: -6), .init(frame: 40, value: -100)]),
                nil, nil, nil, nil,
            ]),
        ], to: &clip, isVideo: false)
        #expect(notes.isEmpty)
        #expect(abs(clip.volume.value - 0.501187) < 1e-6)
        #expect(clip.volume.keyframes.map(\.time) == [frames(6), frames(16)])
        #expect(clip.volume.keyframes.last?.value == 0)

        var faded = self.clip()
        let fadeNotes = try apply([
            Writer.filter(124, [
                Writer.parameter(95, .double(6)), Writer.parameter(97, .double(10)), nil, Writer.parameter(99, .pair(44, -32)),
                Writer.parameter(100, .pair(63, -32)),
            ]),
        ], to: &faded, isVideo: false)
        #expect(faded.volume.keyframes.map(\.time) == [.zero, frames(10)])
        #expect(abs((faded.volume.keyframes.last?.value ?? 0) - 1.995262) < 1e-6)
        #expect(fadeNotes == [.setting("Fade curve")])
    }

    @Test func reportsWhatHasNoCounterpart() throws {
        var clip = clip()
        let notes = try apply([
            Writer.filter(6, [Writer.parameter(54, .double(0.1)), nil, nil, nil, nil, nil]),
            Writer.filter(44, [nil, nil, Writer.parameter(92, .enumeration(2)), nil, nil]),
            Writer.filter(44, [nil, nil, Writer.parameter(92, .enumeration(3)), nil, nil]),
            Writer.filter(118, [Writer.parameter(59, .enumeration(2)), nil, nil]),
            Writer.openFX("com.blackmagicdesign.resolvefx.videocollage"),
            Writer.filter(126, [Writer.parameter(102, .double(1000))]),
        ], to: &clip)
        #expect(notes == [
            .setting("Crop"), .setting("Retime and scaling"), .setting("Dynamic zoom"),
            .effect(identifier: "com.blackmagicdesign.resolvefx.videocollage", name: "videocollage"),
            .effect(identifier: "EffectFiltersBA", name: "Resolve effects"),
        ])
    }

    // MARK: - Through the importer

    @Test func importsSettingsWithLinkedSoundAndReportsACompoundClipsOwn() throws {
        let transform = Writer.hex(Writer.effectFilters([
            Writer.filter(4, [Writer.parameter(42, .double(1.5)), Writer.parameter(43, .double(1.5)), nil, Writer.parameter(40, .double(0.25))]),
            Writer.filter(2, [nil, Writer.parameter(1, .double(50))]),
        ]))
        let volume = Writer.hex(Writer.effectFilters([Writer.filter(124, [Writer.parameter(95, .double(-6)), nil, nil, nil, nil])]))
        let defaults = Writer.hex(Writer.effectFilters([Writer.filter(4, [nil, nil]), Writer.filter(2, [nil, nil])]))
        let compound = Writer.hex(Writer.effectFilters([Writer.filter(4, [Writer.parameter(42, .double(0.5))])]))
        var builder = DRPTestBuilder()
        builder.overrides["SeqContainer/0b6f0e2c-edit.xml"] = DRPTestBuilder.container(id: "container-edit", video: [
            DRPTestBuilder.track(0, sequence: "seq-edit", items: [
                DRPTestBuilder.item("Sm2TiVideoClip", id: "item-a001", start: 86400, duration: 48, inPoint: "24",
                                    media: "media-a001", name: "A001.mov", extra: "<EffectFiltersBA>\(transform)</EffectFiltersBA>"),
                DRPTestBuilder.item("Sm2TiVideoClip", id: "item-compound", start: 86448, duration: 24, inPoint: "0",
                                    media: "media-compound", name: "Compound Clip 1",
                                    extra: "<EffectFiltersBA>\(compound)</EffectFiltersBA>"),
                DRPTestBuilder.item("Sm2TiVideoClip", id: "item-plain", start: 86472, duration: 24, inPoint: "0",
                                    media: "media-a001", name: "A001.mov", extra: "<EffectFiltersBA>\(defaults)</EffectFiltersBA>"),
            ]),
        ], audio: [
            DRPTestBuilder.track(1, sequence: "seq-edit", items: [
                DRPTestBuilder.item("Sm2TiAudioClip", id: "item-a001-sound", start: 86400, duration: 48, inPoint: "24",
                                    media: "media-a001", name: "A001.mov", extra: "<EffectFiltersBA>\(volume)</EffectFiltersBA>"),
            ]),
        ])
        let imported = try DRPImporter.read(builder.archive(), baseURL: nil)
        let clips = imported.project.tracks.filter { $0.kind == .video }.flatMap(\.clips)
        let opening = try #require(clips.first { $0.timelineStart == .zero })
        #expect(opening.transform.scale == Animatable(1.5))
        #expect(opening.transform.position.value == CGPoint(x: 0.75, y: 0.5))
        #expect(opening.opacity == Animatable(0.5))
        #expect(abs(opening.volume.value - 0.501187) < 1e-6)
        #expect(opening.effects.isEmpty)
        #expect(imported.project.tracks.filter { $0.kind == .audio }.flatMap(\.clips).isEmpty)

        let inner = try #require(clips.first { $0.timelineStart == frames(48) })
        #expect(inner.transform.scale == Animatable(1))
        let issues = imported.report.items
        #expect(issues.contains { $0.issue == .nestedSettings && $0.clipName == "Compound Clip 1" })
        #expect(!issues.contains {
            switch $0.issue {
            case .setting, .uneven, .unsupportedEffect: true
            default: false
            }
        })
        let plain = try #require(clips.first { $0.timelineStart == frames(72) })
        #expect(plain.effects.isEmpty && plain.opacity == Animatable(1))
    }
}

/// Multicam clips on a timeline, in the shape the Editor's Guide's
/// multicam lessons have them, built at test time.
struct DRPMulticamTests {
    private typealias Writer = ResolveBlobWriter

    private func frames(_ count: Int64) -> CMTime {
        CMTime(value: count, timescale: 24)
    }

    /// A multicam clip's `FieldsBlob`, naming the angle it shows.
    private func showing(_ angle: String) -> Data {
        Writer.envelope(Writer.protobuf([.bytes(1, Writer.protobuf([.text(3, angle), .varint(4, 1)]))]), version: 2)
    }

    private func imported() throws -> ImportedProject {
        var builder = DRPTestBuilder()
        builder.overrides["MediaPool/Master/Multicam/MpFolder.xml"] = #"<?xml version="1.0" encoding="UTF-8"?>"# + """
            <Sm2MpFolder DbId="bin-multicam"><Name>Multicam</Name><MpFolder>bin-master</MpFolder><MediaVec>\
            <Element><Sm2MpMulticamClip DbId="media-multicam"><Name>Interview</Name><MpFolder>bin-multicam</MpFolder>\
            <Sequence>\(builder.sequence(id: "seq-multicam", start: 3600))</Sequence></Sm2MpMulticamClip></Element>\
            </MediaVec></Sm2MpFolder>
            """
        // Angle tracks in the order Resolve keeps them, which needn't be
        // the order of their IDs.
        builder.overrides["SeqContainer/7c01b1d9-multicam.xml"] = DRPTestBuilder.container(id: "container-multicam", video: [
            DRPTestBuilder.track(0, sequence: "seq-multicam", items: [
                DRPTestBuilder.item("Sm2TiVideoClip", id: "angle-2", start: 86410, duration: 400, inPoint: "100", media: "media-a001"),
            ], angle: "Camera 2"),
            DRPTestBuilder.track(0, sequence: "seq-multicam", items: [
                DRPTestBuilder.item("Sm2TiVideoClip", id: "angle-1", start: 86400, duration: 400, inPoint: "", media: "media-a001"),
            ], angle: "Camera 1"),
        ], audio: [
            DRPTestBuilder.track(1, sequence: "seq-multicam", items: [
                DRPTestBuilder.item("Sm2TiAudioClip", id: "angle-1-sound", start: 86400, duration: 400, inPoint: "", media: "media-a001"),
            ], angle: "Camera 1"),
            DRPTestBuilder.track(1, sequence: "seq-multicam", items: [
                DRPTestBuilder.item("Sm2TiAudioClip", id: "angle-2-sound", start: 86400, duration: 400, inPoint: "", media: "media-music"),
            ], angle: "Camera 2"),
        ])
        builder.overrides["SeqContainer/0b6f0e2c-edit.xml"] = DRPTestBuilder.container(id: "container-edit", video: [
            DRPTestBuilder.track(0, sequence: "seq-edit", items: [
                DRPTestBuilder.item("Sm2TiVideoClip", id: "cut-1", start: 86400, duration: 24, inPoint: "30",
                                    media: "media-multicam", name: "Interview", fieldsBlob: showing("Camera 2")),
                DRPTestBuilder.item("Sm2TiVideoClip", id: "cut-2", start: 86424, duration: 24, inPoint: "54",
                                    media: "media-multicam", name: "Interview", fieldsBlob: showing("Camera 1")),
                DRPTestBuilder.item("Sm2TiVideoClip", id: "cut-3", start: 86448, duration: 24, inPoint: "78",
                                    media: "media-multicam", name: "Interview", fieldsBlob: showing("Camera 9")),
            ]),
        ], audio: [
            DRPTestBuilder.track(1, sequence: "seq-edit", items: [
                DRPTestBuilder.item("Sm2TiAudioClip", id: "cut-sound", start: 86400, duration: 48, inPoint: "30",
                                    media: "media-multicam", name: "Interview", fieldsBlob: showing("Camera 2")),
            ]),
        ])
        return try DRPImporter.read(builder.archive(), baseURL: nil)
    }

    @Test func playsEachClipsAngleFromItsTrackInTheMulticamClip() throws {
        let imported = try imported()
        let video = imported.project.tracks.filter { $0.kind == .video }.flatMap(\.clips).sorted { $0.timelineStart < $1.timelineStart }
        #expect(video.map(\.timelineStart) == [.zero, frames(24)])
        // Angle 2 starts 10 frames into the multicam clip at frame 100 of
        // its media; the cut starts 30 frames in.
        #expect(video.map(\.sourceRange) == [
            CMTimeRange(start: frames(120), duration: frames(24)), CMTimeRange(start: frames(54), duration: frames(24)),
        ])
        // The picture's sound is an angle of its own.
        #expect(video.allSatisfy { $0.isAudioDetached })
        let sound = try #require(imported.project.tracks.filter { $0.kind == .audio }.flatMap(\.clips).first)
        #expect(imported.project.media.first { $0.id == sound.mediaID }?.name == "Music.wav")
        #expect(sound.sourceRange == CMTimeRange(start: frames(30), duration: frames(48)))
    }

    @Test func reportsMulticamClipsOnceAndAnAngleThatIsntThere() throws {
        let issues = try imported().report.items
        #expect(issues.filter { $0.issue == .setting(name: "Multicam angles other than the one each clip shows") }.count == 1)
        let unknown = issues.filter { $0.issue == .setting(name: "Multicam clip") }
        #expect(unknown.count == 1 && unknown.first?.time == frames(48))
    }
}
