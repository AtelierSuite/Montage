import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// LumaFusion project files made at test time, laid out as LumaFusion for
/// Android 2.6 writes them, or, with `iOS`, as LumaFusion for iOS 5.5 does:
/// the in point in `sourceRange` and the speed as a setting. Names, IDs and
/// times are made up.
enum LumaFusionFixture {
    static func time(_ value: Int64, _ timescale: Int64 = 600) -> [String: Any] {
        ["epoch": 0, "flags": 1, "timescale": timescale, "value": value]
    }

    static func setting(_ value: Any, type: Int = 2, keyframed: Bool = false) -> [String: Any] {
        [
            "conversionType": 0, "identityValue": NSNull(),
            "keyframes": keyframed ? [["time": time(0), "value": value]] : [],
            "value": ["type": type, "value": value],
        ]
    }

    struct Clip {
        var file: String
        var start: Int64
        var duration: Int64
        /// The timescale of `start`; the others are in 1/600 s.
        var startTimescale: Int64 = 600
        var sourceStart: Int64 = 0
        /// 0 a video or sound file, 2 a photo, 4 a title.
        var assetType = 0
        var video = true
        var audio = true
        var blank = false
        var reversed = false
        var transition = 0
        var speed = 1.0
        var volume = 1.0
        var volumeKeyframed = false
        var pan = 0.0
        var alpha = 1.0
        var scale = [1.0, 1.0]
        var translation = [0.0, 0.0]
        var rotation = 0.0
        var crop: [[Double]] = [[0, 0], [1, 1]]
        var effects: [String] = []
        var originalFilename: String?
    }

    static func assetID(_ file: String) -> String { "x-coredata://STORE/SpryAsset/\(file)" }

    static func clip(_ clip: Clip, iOS: Bool) -> [String: Any] {
        func attributes(video: Bool) -> [String: Any] {
            var attributes: [String: Any] = [
                "speed": setting(clip.speed),
                "audioVolume": setting(clip.volume, keyframed: clip.volumeKeyframed),
                "audioPan": setting(clip.pan),
                "audioDuck": setting(0, type: 1),
                "audioFill": setting(0, type: 1),
            ]
            if video {
                attributes = [
                    "speed": setting(clip.speed),
                    "videoAlpha": setting(clip.alpha),
                    // Android writes the anchor as a string, iOS as a point.
                    "videoAnchor": iOS ? setting(["point": [0, 0]], type: 13) : setting("[0.0 0.0]", type: 6),
                    "videoBlendMode": setting(0, type: 1),
                    "videoCrop": setting(clip.crop, type: 9),
                    "videoCropCorner": setting(0.0),
                    "videoCropInverted": setting(false, type: 0),
                    "videoCropSoftness": setting(0.0),
                    "videoFitMode": setting(iOS ? 1 : 0, type: 1),
                    "videoFlipH": setting(false, type: 0),
                    "videoFlipV": setting(false, type: 0),
                    "videoOrientation": setting(0.0),
                    "videoRotation": setting(clip.rotation),
                    "videoScale": setting(clip.scale, type: 14),
                    "videoTransformRotation": setting(0.0),
                    "videoTranslation": setting([
                        "path": [["interpolation": 0, "type": 0, "value": [0, 0]]], "point": clip.translation,
                    ], type: 13),
                ]
            }
            if !iOS { attributes["speed"] = nil }
            return attributes
        }
        func stream(mediaType: Int, trackID: Int) -> [String: Any] {
            var stream: [String: Any] = [
                "assetTrackID": trackID, "mediaType": mediaType,
                "effects": mediaType == 1 ? [] : clip.effects.map { ["displayName": $0, "effectID": "fx.\($0)", "effectName": "BuiltIn"] },
                "sourceStart": time(clip.sourceStart),
                "streamAttributes": attributes(video: mediaType != 1),
            ]
            if iOS {
                stream["sourceRange"] = ["start": time(clip.sourceStart), "duration": time(clip.duration)]
            } else {
                stream["originalStepTime"] = time(24)
                stream["sourceSpeed"] = clip.speed
            }
            return stream
        }
        var streams: [[String: Any]] = []
        if clip.video { streams.append(stream(mediaType: clip.assetType == 2 ? 2 : 0, trackID: 0)) }
        if clip.audio { streams.append(stream(mediaType: 1, trackID: 1)) }
        var object: [String: Any] = [
            "anchorFromClipIDs": [], "assetIsBlank": clip.blank, "assetType": clip.assetType,
            "assetMaxDuration": time(60_000),
            "assetURL": "file://~DOC~/LibraryMedia/PhotoLibrary/\(clip.file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clip.file)",
            "attributes": [
                "assetID": assetID(clip.file), "originalFilename": clip.originalFilename ?? clip.file, "title": clip.file,
                "naturalSize": [1920, 1080], "audioSamplerate": 48000,
            ] as [String: Any],
            "clipID": "x-coredata://STORE/SpryClip/\(clip.file)-\(clip.start)",
            "reversed": clip.reversed, "title": clip.file, "transitionType": clip.transition,
            "trackStart": time(clip.start, clip.startTimescale), "trackDuration": time(clip.duration),
            "useVideoTrackID": 0, "useAudioTrackID": 1,
            "streams": streams,
        ]
        if clip.assetType == 4 { object["runtimeTitle"] = ["layers": [["text": ["string": "Hello"]]]] }
        return object
    }

    static func track(type: Int, offset: Int, anchor: Bool = false, volume: Double = 1, hidden: Bool = false,
                      _ clips: [Clip], iOS: Bool = false) -> [String: Any] {
        [
            "clips": clips.map { clip($0, iOS: iOS) }, "hidden": hidden, "isAnchorTrack": anchor, "locked": false,
            "title": "", "trackOffset": offset, "trackType": type, "trackVolume": volume,
            "trackID": "x-coredata://STORE/SpryTrack/\(type)\(offset)", "visualIndex": 0, "editType": anchor ? 0 : 1,
        ]
    }

    static func project(
        _ tracks: [[String: Any]], title: String = "Holiday", version: String = "2.6.0",
        mediaMap: [String: String] = [:], markers: [[String: Any]] = [],
        resolution: [Int] = [3840, 2160], step: [String: Any] = time(1001, 24000)
    ) throws -> Data {
        let root: [String: Any] = [
            "attributes": [
                "appVersion": version, "compositionMarkers": markers, "trackMarkers": [String: Any](),
                "assetMarkers": [String: Any](), "notes": "", "mediaMap": mediaMap,
            ] as [String: Any],
            "backgroundColor": "0.0 0.0 0.0 1.0", "primaryVolume": 1, "resolution": resolution, "stepTime": step,
            "title": title, "videoColorspace": 0, "needsCloudMedia": false, "tracks": tracks,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

struct LumaFusionTimelineTests {
    private typealias Fixture = LumaFusionFixture

    private static func read(_ data: Data) throws -> ImportedProject {
        try LumaFusionTimelineReader.read(data, appVersion: "2.6.0")
    }

    private static func seconds(_ value: Int64, _ timescale: Int32 = 600) -> CMTime {
        CMTime(value: value, timescale: timescale)
    }

    /// The layout of a picture-in-picture edit: the main track, an overlay
    /// above it placed in the corner, and music below, on a muted track.
    private static func pictureInPicture(iOS: Bool = false) throws -> Data {
        try Fixture.project([
            Fixture.track(type: 0, offset: 2, [], iOS: iOS),
            Fixture.track(type: 0, offset: 1, [
                .init(file: "Dub.mp4", start: 600, duration: 3000, sourceStart: 1200, volume: 0.5, pan: -0.25,
                      alpha: 0.75, scale: [0.5, 0.5], translation: [0.5, 0]),
            ], iOS: iOS),
            Fixture.track(type: 0, offset: 0, anchor: true, volume: -1, [
                .init(file: "Main.mkv", start: 0, duration: 6000),
                .init(file: "Main.mkv", start: 6000, duration: 1200, sourceStart: 9000),
            ], iOS: iOS),
            Fixture.track(type: 1, offset: -1, [
                .init(file: "Music.m4a", start: 1200, duration: 2400, sourceStart: 600, video: false),
            ], iOS: iOS),
        ], mediaMap: ["Main.mkv": Fixture.assetID("Main.mkv"), "Dub.mp4": Fixture.assetID("Dub.mp4")])
    }

    @Test func readsTracksClipsAndInOutPoints() throws {
        let imported = try Self.read(try Self.pictureInPicture())
        #expect(imported.name == "Holiday")
        #expect(imported.report.format == .lumaFusion)
        #expect(imported.project.settings.renderSize == CGSize(width: 3840, height: 2160))
        #expect(imported.project.settings.frameDuration == CMTime(value: 1001, timescale: 24000))

        // Video bottom first, then audio; the empty top track is dropped.
        #expect(imported.project.tracks.map(\.kind) == [.video, .video, .audio])
        #expect(imported.project.media.map(\.name).sorted() == ["Dub.mp4", "Main.mkv", "Music.m4a"])
        #expect(imported.project.media.first { $0.name == "Music.m4a" }?.kind == .audio)

        let main = imported.project.tracks[0]
        #expect(main.isMuted)
        #expect(main.clips.allSatisfy { $0.volume == Animatable(1.0) })
        #expect(main.clips.map(\.timelineStart) == [.zero, Self.seconds(6000)])
        #expect(main.clips.map(\.sourceRange) == [
            CMTimeRange(start: .zero, duration: Self.seconds(6000)),
            CMTimeRange(start: Self.seconds(9000), duration: Self.seconds(1200)),
        ])
        #expect(Set(main.clips.map(\.mediaID)).count == 1)

        let overlay = try #require(imported.project.tracks[1].clips.first)
        #expect(!imported.project.tracks[1].isMuted)
        #expect(imported.project.mediaItem(id: overlay.mediaID)?.name == "Dub.mp4")
        #expect(overlay.timelineStart == Self.seconds(600))
        #expect(overlay.sourceRange == CMTimeRange(start: Self.seconds(1200), duration: Self.seconds(3000)))
        #expect(overlay.volume == Animatable(0.5))
        #expect(overlay.opacity == Animatable(0.75))
        #expect(overlay.transform.scale == Animatable(0.5))
        #expect(overlay.transform.position == Animatable(CGPoint(x: 0.75, y: 0.5)))
        #expect(overlay.effects.count == 1)
        guard case .pan(let pan) = overlay.effects.first?.kind else { Issue.record("No pan"); return }
        #expect(pan.position == Animatable(-0.25))

        let music = try #require(imported.project.tracks[2].clips.first)
        #expect(music.sourceRange == CMTimeRange(start: Self.seconds(600), duration: Self.seconds(2400)))
        #expect(music.timelineStart == Self.seconds(1200))

        // Nothing here that Montage can't carry.
        #expect(imported.report.isEmpty)
    }

    @Test func readsTheIOSLayout() throws {
        let android = try Self.read(try Self.pictureInPicture())
        let iOS = try Self.read(try Self.pictureInPicture(iOS: true))
        func summary(_ imported: ImportedProject) -> [String] {
            imported.project.tracks.flatMap { track in
                track.clips.map { clip in
                    "\(track.kind) \(imported.project.mediaItem(id: clip.mediaID)?.name ?? "") "
                        + "\(clip.timelineStart.seconds) \(clip.sourceRange.start.seconds) \(clip.duration.seconds)"
                }
            }
        }
        #expect(summary(iOS) == summary(android))
        #expect(iOS.report.isEmpty)
    }

    @Test func takesMediaNamesFromThePackageThenTheClip() throws {
        let imported = try Self.read(try Fixture.project([
            Fixture.track(type: 0, offset: 0, anchor: true, [
                // Stored in the package under another name.
                .init(file: "IMG_0001.MOV", start: 0, duration: 600),
                // Where the file was on the device that made the project.
                .init(file: "Trip.mov", start: 600, duration: 600, originalFilename: "/Volumes/Card/DCIM/Trip.mov"),
                // A placeholder for a name.
                .init(file: "Photo.heic", start: 1200, duration: 600, assetType: 2, audio: false,
                      originalFilename: "sioProviderRelink"),
            ]),
        ], mediaMap: ["Holiday 1.mov": Fixture.assetID("IMG_0001.MOV")]))
        #expect(imported.project.media.map(\.name) == ["Holiday 1.mov", "Trip.mov", "Photo.heic"])
        #expect(imported.project.media.map(\.kind) == [.video, .video, .image])
        let trip = try #require(imported.project.media.first { $0.name == "Trip.mov" })
        #expect(imported.mediaSources[trip.id] == URL(fileURLWithPath: "/Volumes/Card/DCIM/Trip.mov"))
        let photo = try #require(imported.clip("Photo.heic"))
        #expect(photo.clip.sourceRange == CMTimeRange(start: .zero, duration: Self.seconds(600)))
    }

    @Test func reportsWhatItCantBringAcross() throws {
        let imported = try Self.read(try Fixture.project([
            Fixture.track(type: 0, offset: 0, anchor: true, [
                .init(file: "A.mov", start: 0, duration: 1200, effects: ["Blur"]),
                // Crossfades in from A: the two overlap under the transition.
                .init(file: "B.mov", start: 900, duration: 1200, sourceStart: 600, transition: 1, speed: 2,
                      crop: [[0.1, 0], [0.9, 1]]),
                .init(file: "Gap", start: 2100, duration: 600, blank: true),
                .init(file: "Hello", start: 2700, duration: 600, assetType: 4, audio: false),
                .init(file: "C.mov", start: 3300, duration: 600, reversed: true, volumeKeyframed: true, rotation: 0.5),
            ]),
        ], markers: [["title": "Chorus", "time": Fixture.time(1200)]]))

        let main = imported.project.tracks[0]
        // A and B are cut in the middle of their overlap; the gap and the
        // title leave nothing.
        #expect(main.clips.map(\.timelineStart) == [.zero, Self.seconds(1050), Self.seconds(3300)])
        #expect(main.clips[0].duration == Self.seconds(1050))
        #expect(main.clips[1].sourceRange.start == Self.seconds(750))
        #expect(imported.project.tracks.count == 1)
        guard case .unsupported(let effect) = main.clips[0].effects.first?.kind else { Issue.record("No effect"); return }
        #expect(effect.name == "Blur")
        #expect(effect.format == "lumaFusion")
        #expect(main.clips[0].effects.first?.isEnabled == false)

        let issues = imported.report.items.map(\.issue)
        #expect(issues.contains(.unsupportedEffect(name: "Blur")))
        #expect(issues.contains(.transition(name: "Transition")))
        #expect(issues.contains(.speedChange))
        #expect(issues.contains(.setting(name: "Crop")))
        #expect(issues.contains(.title))
        #expect(issues.contains(.setting(name: "Reverse")))
        #expect(issues.contains(.setting(name: "Volume keyframes")))
        #expect(issues.contains(.setting(name: "Rotation")))
        #expect(issues.contains(.marker(name: "Chorus")))
        #expect(!issues.contains(.movedToNewTrack))
    }

    @Test func movesOverlappingClipsToATrackOfTheirOwn() throws {
        let imported = try Self.read(try Fixture.project([
            Fixture.track(type: 0, offset: 0, anchor: true, hidden: true, [
                .init(file: "A.mov", start: 0, duration: 1200),
                .init(file: "B.mov", start: 600, duration: 1200),
            ]),
        ]))
        #expect(imported.project.tracks.count == 2)
        #expect(imported.project.tracks.allSatisfy { $0.isHidden })
        #expect(imported.issues(.changed) == [.movedToNewTrack])
    }

    @Test func closesOverlapsOfLessThanAFrame() throws {
        let imported = try Self.read(try Fixture.project([
            Fixture.track(type: 0, offset: 0, anchor: true, [
                .init(file: "A.mov", start: 0, duration: 600),
                // A three-thousandth of a second before A ends.
                .init(file: "B.mov", start: 23992, duration: 600, startTimescale: 24000),
            ]),
        ]))
        #expect(imported.project.tracks.count == 1)
        let clips = imported.project.tracks[0].clips
        #expect(clips.map(\.timelineStart) == [.zero, Self.seconds(600)])
        #expect(clips[1].timelineRange.end == CMTime(value: 23992 + 24000, timescale: 24000))
        #expect(imported.report.isEmpty)
    }

    @Test func detachesSoundAClipDoesntPlay() throws {
        let imported = try Self.read(try Fixture.project([
            Fixture.track(type: 0, offset: 0, anchor: true, [.init(file: "A.mov", start: 0, duration: 600, audio: false)]),
            Fixture.track(type: 1, offset: -1, [.init(file: "A.mov", start: 0, duration: 600, video: false)]),
        ]))
        #expect(imported.project.media.count == 1)
        #expect(imported.project.tracks.map(\.kind) == [.video, .audio])
        #expect(imported.project.tracks[0].clips.first?.isAudioDetached == true)
        #expect(imported.project.tracks[1].clips.first?.isAudioDetached == false)
    }

    @Test func refusesProjectsLaidOutOtherwise() throws {
        let data = Data(#"{"title":"Holiday","attributes":{"appVersion":"9.0"},"timeline":{}}"#.utf8)
        #expect(throws: LumaFusionError.unsupportedVersion("9.0")) {
            try LumaFusionTimelineReader.read(data, appVersion: "9.0")
        }
        #expect(throws: LumaFusionError.damaged) { try LumaFusionTimelineReader.read(Data("[]".utf8), appVersion: nil) }
    }

    @Test func readsTimesOnlyWhereValid() {
        #expect(LumaFusionTimelineReader.time(Fixture.time(1001, 24000)) == CMTime(value: 1001, timescale: 24000))
        #expect(LumaFusionTimelineReader.time(["value": 1, "timescale": 0, "flags": 1]) == nil)
        #expect(LumaFusionTimelineReader.time(["value": 1, "timescale": 600, "flags": 0]) == nil)
        // Positive infinity.
        #expect(LumaFusionTimelineReader.time(["value": 0, "timescale": 600, "flags": 5]) == nil)
        #expect(LumaFusionTimelineReader.time("1/600") == nil)
        #expect(LumaFusionTimelineReader.numbers("[0.5 -1.0]") == [0.5, -1])
        #expect(LumaFusionTimelineReader.numbers(["point": [0.25, 0.5]]) == [0.25, 0.5])
    }
}
