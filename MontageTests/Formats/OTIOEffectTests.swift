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
        target: String = "file:///Volumes/Footage/Shot.mov"
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
            "OTIO_SCHEMA": "Timeline.1", "name": name, "global_start_time": time(0),
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
    @Test func movesAStillByFractionsOfItsFittedPicture() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bar = folder.appendingPathComponent("_bar.png")
        try Self.writePNG(width: 960, height: 73, to: bar)
        let imported = try read(clipEffects: [resolve("Transform", [
            parameter("transformationPan", 0.0, default: 0.0, keyframes: [:]),
            parameter("transformationTilt", -1.6506849527359009, default: 0.0, keyframes: [:]),
        ])], target: bar.absoluteString)
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        let position = try clip(imported).transform.position.value
        #expect(abs(position.x - 0.5) < 1e-9)
        #expect(abs(position.y * 1080 - (540 + 241)) < 0.001)
    }

    /// A portrait movie fitted into a landscape frame is narrower than the
    /// frame, so a pan moves it less across; a tilt moves it as far as the
    /// frame is tall. Its turn is in its track header.
    @Test func movesAPortraitMovieByFractionsOfItsFittedPicture() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("Phone.mov")
        try Self.movieData(width: 1280, height: 720, quarterTurn: true).write(to: movie)
        let imported = try read(clipEffects: [resolve("Transform", [
            parameter("transformationPan", -0.5, default: 0.0, keyframes: [:]),
            parameter("transformationTilt", 0.25, default: 0.0, keyframes: [:]),
        ])], target: movie.absoluteString)
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
    @Test func bringsInResolvesTransformKeyframes() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let still = folder.appendingPathComponent("Picchu.png")
        try Self.writePNG(width: 960, height: 313, to: still)
        let push = ["0": key(1.0), "67": key(1.179999828338623)]
        let imported = try read(clipEffects: [resolve("Transform", [
            parameter("transformationZoomX", 1.0, default: 1.0, keyframes: push),
            parameter("transformationZoomY", 1.0, default: 1.0, keyframes: push),
            parameter("transformationPan", 0.0, default: 0.0, keyframes: ["0": key(0), "67": key(-0.0234375)]),
            parameter("transformationTilt", 0.0, default: 0.0, keyframes: ["0": key(0), "67": key(-0.043130990117788315)]),
            parameter("transformationRotationAngle", 0.0, default: 0.0, keyframes: [:]),
        ])], target: still.absoluteString)
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

    /// A movie with just enough of a movie box for its picture track's
    /// header: `ftyp`, then `moov` holding one `trak`.
    static func movieData(width: Int, height: Int, quarterTurn: Bool = false, version: UInt8 = 0) -> Data {
        func box(_ type: String, _ body: Data) -> Data {
            var data = Data()
            withUnsafeBytes(of: UInt32(body.count + 8).bigEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: Array(type.utf8))
            return data + body
        }
        func word(_ value: Int32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        var header = Data([version, 0, 0, 7])
        header += Data(count: version == 1 ? 32 : 20) + Data(count: 16)
        let one: Int32 = 0x10000
        let matrix: [Int32] = quarterTurn ? [0, one, 0, -one, 0, 0, 0, 0, 0x4000_0000] : [one, 0, 0, 0, one, 0, 0, 0, 0x4000_0000]
        header += matrix.reduce(Data()) { $0 + word($1) }
        header += word(Int32(width) << 16) + word(Int32(height) << 16)
        let handler = box("hdlr", Data(count: 8) + Data("vide".utf8) + Data(count: 13))
        let sound = box("trak", box("mdia", box("hdlr", Data(count: 8) + Data("soun".utf8) + Data(count: 13))))
        let picture = box("trak", box("tkhd", header) + box("mdia", handler))
        return box("ftyp", Data("isom".utf8) + Data(count: 4)) + box("mdat", Data(count: 32)) + box("moov", sound + picture)
    }

    static func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func readsAPicturesSizeFromItsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let still = folder.appendingPathComponent("Bar.png")
        try Self.writePNG(width: 192, height: 15, to: still)
        let movie = folder.appendingPathComponent("Phone.mov")
        try Self.movieData(width: 1920, height: 1080, quarterTurn: true).write(to: movie)
        let wide = folder.appendingPathComponent("Wide.mp4")
        try Self.movieData(width: 4096, height: 1716, version: 1).write(to: wide)

        #expect(OTIOPictureSize.read(at: still)?.size == CGSize(width: 192, height: 15))
        #expect(OTIOPictureSize.read(at: movie)?.size == CGSize(width: 1920, height: 1080))
        #expect(OTIOPictureSize.read(at: movie)?.rotation == 90)
        #expect(OTIOPictureSize.read(at: wide)?.size == CGSize(width: 4096, height: 1716))
        #expect(OTIOPictureSize.read(at: wide)?.rotation == 0)
        #expect(OTIOPictureSize.read(at: folder.appendingPathComponent("Gone.mov")) == nil)
        try Data("not a movie".utf8).write(to: folder.appendingPathComponent("Text.mov"))
        #expect(OTIOPictureSize.read(at: folder.appendingPathComponent("Text.mov")) == nil)
    }
}
