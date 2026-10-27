import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import MontageEngine
@testable import MontageFormats
import Testing

/// Effects as Resolve and Kdenlive write them, cut down to what matters.
struct OTIOEffectTests {
    private func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
        CMTime(value: value, timescale: timescale)
    }

    private func time(_ frames: Double) -> [String: Any] {
        ["OTIO_SCHEMA": "RationalTime.1", "rate": 30.0, "value": frames]
    }

    /// A timeline of one three-second clip on a video track, with effects
    /// on the clip and on the timeline's stack.
    private func read(
        clipEffects: [[String: Any]], stackEffects: [[String: Any]] = [], name: String = "",
        target: String = "file:///Volumes/Footage/Shot.mov", metadata: [String: Any] = [:]
    ) throws -> ImportedProject {
        let clip: [String: Any] = [
            "OTIO_SCHEMA": "Clip.2", "name": "Shot",
            "source_range": ["OTIO_SCHEMA": "TimeRange.1", "start_time": time(0), "duration": time(90)],
            "effects": clipEffects,
            "media_references": ["DEFAULT_MEDIA": [
                "OTIO_SCHEMA": "ExternalReference.1", "target_url": target,
            ]],
            "active_media_reference_key": "DEFAULT_MEDIA",
        ]
        let timeline: [String: Any] = [
            "OTIO_SCHEMA": "Timeline.1", "name": name, "global_start_time": time(0), "metadata": metadata,
            "tracks": [
                "OTIO_SCHEMA": "Stack.1", "effects": stackEffects,
                "children": [["OTIO_SCHEMA": "Track.1", "kind": "Video", "children": [clip]]],
            ],
        ]
        return try ProjectInterchange.read(JSONSerialization.data(withJSONObject: timeline))
    }

    private func resolve(_ name: String, enabled: Bool = true, _ parameters: [[String: Any]] = []) -> [String: Any] {
        ["OTIO_SCHEMA": "Effect.1", "name": "", "effect_name": "Resolve Effect", "metadata": ["Resolve_OTIO": [
            "Effect Name": name, "Name": name, "Enabled": enabled, "Type": 2, "Parameters": parameters,
        ]]]
    }

    private func parameter(_ id: String, _ value: Any, default fallback: Any, keyframes: [String: Any]? = nil) -> [String: Any] {
        var parameter: [String: Any] = ["Parameter ID": id, "Parameter Value": value, "Default Parameter Value": fallback]
        if let keyframes { parameter["Key Frames"] = keyframes }
        return parameter
    }

    /// The imported project once its media has been found and probed.
    private func gathered(_ imported: ImportedProject) async -> ImportedProject {
        await ProjectInterchange.gatherMedia(for: imported, into: PackageMediaStore())
    }

    private func clip(_ imported: ImportedProject) throws -> Clip {
        try #require(imported.project.tracks.first?.clips.first)
    }

    @Test func leavesResolvesUntouchedSettingsOut() throws {
        let imported = try read(clipEffects: [
            resolve("Transform"), resolve("Cropping"), resolve("Composite"),
            resolve("Fairlight Equaliser Band", [parameter("eq band index", 0, default: 0)]),
            // Turned off, whatever its keyframes say.
            resolve("Dynamic Zoom", enabled: false, [parameter("dynamicZoomScale", 1.0, default: 1.0, keyframes: [
                "0": ["Value": 0.8], "1000": ["Value": 1.0],
            ])]),
        ], stackEffects: [resolve("Transform")])
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        #expect(try clip(imported).effects.isEmpty)
    }

    @Test func bringsInResolvesZoomOpacityAndVolume() throws {
        let imported = try read(clipEffects: [
            resolve("Transform", [parameter("transformationZoomX", 1.5, default: 1.0), parameter("transformationZoomY", 1.5, default: 1.0)]),
            resolve("Composite", [parameter("opacity", 50.0, default: 100.0)]),
            resolve("Fairlight Clip Volume and Fades", [parameter("volume", -6.0, default: 0.0)]),
        ])
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        let shot = try clip(imported)
        #expect(shot.transform.scale.value == 1.5)
        #expect(shot.opacity.value == 0.5)
        #expect(abs(shot.volume.value - 0.501) < 0.001)
    }

    /// Composite's opacity of 1 is 1%, whether or not there's a default to
    /// tell its scale by.
    @Test func takesCompositesOpacityAsAPercentage() throws {
        let imported = try read(clipEffects: [
            resolve("Composite", [["Parameter ID": "opacity", "Parameter Value": 1.0]]),
        ])
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        #expect(abs(try clip(imported).opacity.value - 0.01) < 1e-9)
    }

    /// As Resolve 19 writes a rotated clip: every Transform parameter, the
    /// changed ones beside their defaults, with no keyframes.
    @Test func turnsResolvesRotationTheOtherWay() throws {
        let imported = try read(clipEffects: [
            resolve("Transform", [
                parameter("transformationPan", 0.0, default: 0.0, keyframes: [:]),
                parameter("transformationZoomX", 0.5, default: 1.0, keyframes: [:]),
                parameter("transformationZoomY", 0.5, default: 1.0, keyframes: [:]),
                parameter("transformationRotationAngle", 52.21, default: 0.0, keyframes: [:]),
            ]),
        ])
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        let shot = try clip(imported)
        #expect(shot.transform.rotation.value == -52.21)
        #expect(shot.transform.scale.value == 0.5)
    }

    @Test func reportsAZoomChangedOneWayOnly() throws {
        let imported = try read(clipEffects: [
            resolve("Transform", [
                parameter("transformationZoomX", 1.0, default: 1.0), parameter("transformationZoomY", 1.185, default: 1.0),
            ]),
        ])
        #expect(imported.report.items.map(\.issue) == [.uneven(name: "Zoom")])
        #expect(try clip(imported).transform.scale.value == 1.0)
    }

    /// A picture of the frame's shape, as one whose file isn't there is
    /// taken to be, moves by fractions of the frame: right, and up.
    @Test func movesAClipByResolvesPanAndTilt() throws {
        let imported = try read(clipEffects: [resolve("Transform", [
            parameter("transformationPan", 0.1, default: 0.0, keyframes: [:]),
            parameter("transformationTilt", 0.05, default: 0.0, keyframes: [:]),
        ])])
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        let position = try clip(imported).transform.position.value
        #expect(abs(position.x - 0.6) < 1e-9 && abs(position.y - 0.45) < 1e-9)
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// As in a real Resolve export (OTIO's `effects.otio`), where a bar
    /// still has a tilt of -241/146: the bar, fitted across the frame, is
    /// 146 pixels tall and was moved 241 pixels down.
    @Test func movesAStillByFractionsOfItsFittedPicture() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bar = folder.appendingPathComponent("_bar.png")
        try Self.writePNG(width: 960, height: 73, to: bar)
        let imported = await gathered(try read(clipEffects: [resolve("Transform", [
            parameter("transformationPan", 0.0, default: 0.0, keyframes: [:]),
            parameter("transformationTilt", -1.6506849527359009, default: 0.0, keyframes: [:]),
        ])], target: bar.absoluteString))
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        let position = try clip(imported).transform.position.value
        #expect(abs(position.x - 0.5) < 1e-9)
        #expect(abs(position.y * 1080 - (540 + 241)) < 0.001)
    }

    /// In a portrait project, whose size Montage wrote into the timeline,
    /// a landscape still fitted into the frame spans its width but not its
    /// height, so pan moves it by the frame's width and tilt by less than
    /// the frame's height.
    @Test func movesAClipByFractionsOfThePictureFittedIntoTheProjectsFrame() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let still = folder.appendingPathComponent("Wide.png")
        try Self.writePNG(width: 192, height: 108, to: still)
        let imported = await gathered(try read(clipEffects: [resolve("Transform", [
            parameter("transformationPan", 0.25, default: 0.0, keyframes: [:]),
            parameter("transformationTilt", 0.5, default: 0.0, keyframes: [:]),
        ])], target: still.absoluteString, metadata: ["Montage": ["width": 1080.0, "height": 1920.0]]))
        #expect(imported.project.settings.renderSize == CGSize(width: 1080, height: 1920))
        // Fitted, it's 1080 by 607.5.
        let position = try clip(imported).transform.position.value
        #expect(abs(position.x * 1080 - (540 + 0.25 * 1080)) < 0.001)
        #expect(abs(position.y * 1920 - (960 - 0.5 * 607.5)) < 0.001)
    }

    /// A portrait movie fitted into a landscape frame is narrower than the
    /// frame, so a pan moves it less across; a tilt moves it as far as the
    /// frame is tall.
    @Test func movesAPortraitMovieByFractionsOfItsFittedPicture() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("Phone.mov")
        try await TestMovie.write(to: movie, width: 1280, height: 720, quarterTurn: true)
        let imported = await gathered(try read(clipEffects: [resolve("Transform", [
            parameter("transformationPan", -0.5, default: 0.0, keyframes: [:]),
            parameter("transformationTilt", 0.25, default: 0.0, keyframes: [:]),
        ])], target: movie.absoluteString))
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        // Fitted, it's 607.5 by 1080.
        let position = try clip(imported).transform.position.value
        #expect(abs(position.x * 1920 - (960 - 0.5 * 607.5)) < 0.001)
        #expect(abs(position.y * 1080 - (540 - 0.25 * 1080)) < 0.001)
    }

    private func key(_ value: Double, in back: [Double]? = nil, out: [Double]? = nil) -> [String: Any] {
        var key: [String: Any] = ["Value": value, "Variant Type": "Double"]
        if let back { key["InBez"] = ["InBez": back, "Variant Type": "POINTF"] }
        if let out { key["OutBez"] = ["OutBez": out, "Variant Type": "POINTF"] }
        return key
    }

    private func frames(_ count: Int64) -> CMTime { CMTime(value: count, timescale: 30) }

    /// As the last still of OTIO's `effects.otio` pushes in: keyframes at
    /// the clip's frames 0 and 67, zoom from 1 to 1.18, and the still,
    /// 1920 by 626 fitted, moved 45 pixels left and 27 down. Its Parameter
    /// Values are those at neither keyframe.
    @Test func bringsInResolvesTransformKeyframes() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let still = folder.appendingPathComponent("Picchu.png")
        try Self.writePNG(width: 960, height: 313, to: still)
        let push = ["0": key(1.0), "67": key(1.179999828338623)]
        let imported = await gathered(try read(clipEffects: [resolve("Transform", [
            parameter("transformationZoomX", 1.0, default: 1.0, keyframes: push),
            parameter("transformationZoomY", 1.0, default: 1.0, keyframes: push),
            parameter("transformationPan", 0.0, default: 0.0, keyframes: ["0": key(0), "67": key(-0.0234375)]),
            parameter("transformationTilt", 0.0, default: 0.0, keyframes: ["0": key(0), "67": key(-0.043130990117788315)]),
            parameter("transformationRotationAngle", 0.0, default: 0.0, keyframes: [:]),
        ])], target: still.absoluteString))
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        let shot = try clip(imported)
        #expect(shot.transform.scale.keyframes.map(\.time) == [.zero, frames(67)])
        #expect(shot.transform.scale.keyframes.map(\.value) == [1.0, 1.179999828338623])
        let position = shot.transform.position.keyframes
        #expect(position.map(\.time) == [.zero, frames(67)])
        #expect(position.map(\.interpolation) == [.linear, .linear])
        #expect(position.first?.value == CGPoint(x: 0.5, y: 0.5))
        let end = try #require(position.last?.value)
        #expect(abs(end.x * 1920 - (960 - 45)) < 0.001)
        #expect(abs(end.y * 1080 - (540 + 27)) < 0.001)
        #expect(!shot.transform.rotation.isAnimated)
    }

    /// Resolve's Bézier handles, in frames and value from their keyframe,
    /// become the curve to the next keyframe; a fade of opacity in
    /// percent becomes one from 0 to 1.
    @Test func shapesResolvesKeyframesByTheirHandles() throws {
        let imported = try read(clipEffects: [
            resolve("Transform", [parameter("transformationRotationAngle", 0.0, default: 0.0, keyframes: [
                "10": key(0, out: [10, 0]), "40": key(90, in: [-10, 0]), "60": key(90),
            ])]),
            resolve("Composite", [parameter("opacity", 0.0, default: 100.0, keyframes: ["0": key(0), "15": key(100)])]),
        ])
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        let shot = try clip(imported)
        #expect(shot.transform.rotation.keyframes.map(\.time) == [frames(10), frames(40), frames(60)])
        #expect(shot.transform.rotation.keyframes.map(\.value) == [0, -90, -90])
        let shapes = shot.transform.rotation.keyframes.map(\.interpolation)
        #expect(shapes.dropFirst() == [.linear, .linear])
        guard case .bezier(let curve) = shapes.first else {
            Issue.record("Expected a Bézier curve, got \(String(describing: shapes.first))")
            return
        }
        #expect(abs(curve.x1 - 1.0 / 3) < 1e-9 && curve.y1 == 0 && abs(curve.x2 - 2.0 / 3) < 1e-9 && curve.y2 == 1)
        #expect(shot.opacity.keyframes.map(\.value) == [0, 1])
        #expect(shot.opacity.keyframes.map(\.time) == [.zero, frames(15)])
    }

    /// Pan keyed alone, with tilt left where it is, still keys the whole
    /// position.
    @Test func keysThePositionWhenOnlyPanIsKeyed() throws {
        let imported = try read(clipEffects: [resolve("Transform", [
            parameter("transformationPan", 0.0, default: 0.0, keyframes: ["0": key(0), "30": key(0.1)]),
            parameter("transformationTilt", 0.05, default: 0.0, keyframes: [:]),
        ])])
        let position = try clip(imported).transform.position.keyframes
        #expect(position.map(\.time) == [.zero, frames(30)])
        #expect(position.map { abs($0.value.y - 0.45) < 1e-9 } == [true, true])
        #expect(position.map { $0.value.x } == [0.5, 0.6])
    }

    /// A zoom keyed across but not down is uneven, so it's reported.
    @Test func reportsZoomKeyframesThatDifferAcrossAndDown() throws {
        let imported = try read(clipEffects: [resolve("Transform", [
            parameter("transformationZoomX", 1.0, default: 1.0, keyframes: ["0": key(1), "30": key(2)]),
            parameter("transformationZoomY", 1.0, default: 1.0, keyframes: [:]),
        ])])
        #expect(imported.report.items.map(\.issue) == [.uneven(name: "Zoom")])
        #expect(try clip(imported).transform.scale.keyframes.map(\.value) == [1, 2])
    }

    /// Montage has no cropping, nor keyframes of a clip's volume from
    /// Resolve, whose timing isn't known.
    @Test func reportsResolvesCroppingAndVolumeKeyframes() throws {
        let imported = try read(clipEffects: [
            resolve("Cropping", [parameter("cropLeft", 0.1, default: 0.0, keyframes: ["0": key(0), "30": key(0.1)])]),
            resolve("Fairlight Clip Volume and Fades", [
                parameter("volume", 0.0, default: 0.0, keyframes: ["0": key(0), "30": key(-6)]),
            ]),
        ])
        #expect(imported.issues(.unsupportedEffect) == [
            .unsupportedEffect(name: "Cropping"), .unsupportedEffect(name: "Fairlight Clip Volume and Fades"),
        ])
        #expect(try !clip(imported).volume.isAnimated)
    }

    @Test func reportsResolveSettingsByTheirOwnNames() throws {
        let imported = try read(clipEffects: [
            resolve("Cropping", [parameter("cropLeft", 10.0, default: 0.0)]),
            resolve("Dynamic Zoom", [parameter("dynamicZoomScale", 1.0, default: 1.0, keyframes: ["0": ["Value": 0.8]])]),
        ])
        #expect(imported.issues(.unsupportedEffect) == [.unsupportedEffect(name: "Cropping"), .unsupportedEffect(name: "Dynamic Zoom")])
        #expect(!imported.issues(.unsupportedEffect).contains(.unsupportedEffect(name: "Resolve Effect")))
    }

    @Test func makesKdenlivesFadesKeyframes() throws {
        func fade(_ name: String, frames: Double) -> [String: Any] {
            ["OTIO_SCHEMA": "Effect.1", "name": "", "effect_name": name, "metadata": ["duration": time(frames)]]
        }
        // Kdenlive writes fractions of a frame; they're put on the frame.
        let imported = try read(clipEffects: [
            fade("fadein", frames: 14.993), fade("fadeout", frames: 30), fade("fade_from_black", frames: 15),
        ])
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        let shot = try clip(imported)
        #expect(shot.volume.keyframes.map(\.time) == [.zero, seconds(1, 2), seconds(2), seconds(3)])
        #expect(shot.volume.keyframes.map(\.value) == [0, 1, 1, 0])
        #expect(shot.opacity.keyframes.map(\.time) == [.zero, seconds(1, 2)])
        #expect(shot.opacity.keyframes.map(\.value) == [0, 1])
    }

    @Test func reportsAResolveRetimeAsASpeedChange() throws {
        let retime: [String: Any] = ["OTIO_SCHEMA": "TimeEffect.1", "name": "", "effect_name": "",
                                     "metadata": ["Resolve_OTIO": ["Speed Ratio": 0.33]]]
        let imported = try read(clipEffects: [retime])
        #expect(imported.report.items.map(\.issue) == [.speedChange])
    }

    // MARK: - Picture sizes

    static func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
