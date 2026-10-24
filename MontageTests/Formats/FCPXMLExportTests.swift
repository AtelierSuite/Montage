import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

struct FCPXMLExportTests {
    private static let dtd = URL(fileURLWithPath:
        "/Applications/Final Cut Pro Creator Studio.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_11.dtd")
    private static let alternateDTD = URL(fileURLWithPath:
        "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_11.dtd")
    private static let xmllint = URL(fileURLWithPath: "/usr/bin/xmllint")

    /// Final Cut's DTD, where Final Cut is installed to read it from.
    private static var installedDTD: URL? {
        [dtd, alternateDTD].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var canValidate: Bool {
        installedDTD != nil && FileManager.default.isExecutableFile(atPath: xmllint.path)
    }

    private func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
        CMTime(value: value, timescale: timescale)
    }

    private func video(_ name: String) -> MediaItem {
        MediaItem(name: name, kind: .video, location: .package(path: "Media/\(name)"), metadata: MediaMetadata(
            duration: seconds(20), naturalSize: CGSize(width: 1920, height: 1080), nominalFrameRate: 30,
            audioChannelCount: 2, audioSampleRate: 48000
        ))
    }

    /// Something of everything the export writes, on frames of the project.
    private func sampleProject() -> Project {
        let opening = video("IMG_1805.MOV"), second = video("IMG_1813.MOV"), sound = video("IMG_1841.MOV")
        let tree = MediaItem(name: "Tree.png", kind: .image, location: .package(path: "Media/Tree.png"),
                             metadata: MediaMetadata(naturalSize: CGSize(width: 1024, height: 768)))

        var first = Clip(mediaID: opening.id, sourceRange: CMTimeRange(start: seconds(1), duration: seconds(3)))
        first.volume = Animatable(0.5, keyframes: [Keyframe(time: .zero, value: 0), Keyframe(time: seconds(1), value: 0.5)])
        first.opacity = Animatable(0.9)
        first.transform.position = Animatable(CGPoint(x: 0.75, y: 0.25))
        first.transform.scale = Animatable(0.8, keyframes: [
            Keyframe(time: .zero, value: 0.8, interpolation: .easeInOut), Keyframe(time: seconds(2), value: 1.2),
        ])
        first.transform.rotation = Animatable(10)
        var blur = Mosaic()
        blur.style = .blur
        blur.scale = Animatable(0.01)
        var correction = ColorCorrection()
        correction.exposure = Animatable(0.5, keyframes: [Keyframe(time: seconds(1), value: 0.5), Keyframe(time: seconds(2), value: 1)])
        first.effects = [
            Effect(.mosaic(blur)), Effect(isEnabled: false, .colorCorrection(correction)),
            Effect(isEnabled: false, .unsupported(UnsupportedEffect(
                format: "fcpxml", identifier: "com.example.fxplug.glow", name: "Glow", isVideo: true,
                parameters: [.init(name: "Radius", key: "1", value: "12")],
                original: #"<filter-video ref="e2" name="Glow"><param name="Radius" key="1" value="12"/></filter-video>"#
            ))),
        ]
        var later = Clip(mediaID: second.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(2)), timelineStart: seconds(5))
        later.isAudioDetached = true

        var still = Clip(mediaID: tree.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(2)), timelineStart: seconds(1))
        still.opacity = Animatable(1, keyframes: [Keyframe(time: .zero, value: 0), Keyframe(time: seconds(1, 2), value: 1)])

        var music = Clip(mediaID: sound.id, sourceRange: CMTimeRange(start: seconds(2), duration: seconds(4)), timelineStart: seconds(1, 2))
        var pan = Pan()
        pan.position = Animatable(-0.25)
        music.effects = [Effect(.pan(pan))]
        let echo = Clip(mediaID: opening.id, sourceRange: CMTimeRange(start: seconds(8), duration: seconds(1)), timelineStart: seconds(6))

        return Project(
            settings: ProjectSettings(renderSize: CGSize(width: 1920, height: 1080), frameDuration: seconds(1, 30)),
            media: [opening, second, sound, tree],
            tracks: [
                Track(kind: .video, clips: [first, later]), Track(kind: .video, clips: [still]),
                Track(kind: .audio, clips: [music]), Track(kind: .audio, clips: [echo]),
            ]
        )
    }

    private let resolver = MediaResolver { URL(fileURLWithPath: "/Volumes/Media").appending(path: $0.name) }

    private func export(_ project: Project) -> Data {
        ProjectInterchange.fcpxml(for: project, named: "Round Trip", mediaResolver: resolver)
    }

    @Test func roundTripsThroughFCPXML() throws {
        let project = sampleProject()
        let imported = try ProjectInterchange.read(export(project))
        #expect(imported.name == "Round Trip")
        #expect(imported.project.settings == project.settings)
        #expect(imported.project.tracks.map(\.kind) == project.tracks.map(\.kind))
        let byName = { (media: [MediaItem]) in media.sorted { $0.name < $1.name } }
        #expect(byName(imported.project.media).map(\.name) == byName(project.media).map(\.name))
        for (original, back) in zip(byName(project.media), byName(imported.project.media)) {
            #expect(back.kind == original.kind)
            #expect(back.metadata == original.metadata)
        }

        for (track, back) in zip(project.tracks, imported.project.tracks) {
            #expect(back.clips.count == track.clips.count)
            for (clip, copy) in zip(track.clips, back.clips) {
                let name = project.mediaItem(id: clip.mediaID)?.name
                #expect(imported.project.mediaItem(id: copy.mediaID)?.name == name)
                #expect(copy.sourceRange == clip.sourceRange)
                #expect(copy.timelineStart == clip.timelineStart)
                #expect(copy.isAudioDetached == clip.isAudioDetached)
                expectClose(copy.volume, clip.volume)
                expectClose(copy.opacity, clip.opacity)
                expectClose(copy.transform.scale, clip.transform.scale)
                expectClose(copy.transform.rotation, clip.transform.rotation)
                #expect(abs(copy.transform.position.value.x - clip.transform.position.value.x) < 0.00001)
                #expect(abs(copy.transform.position.value.y - clip.transform.position.value.y) < 0.00001)
                #expect(copy.effects.count == clip.effects.count)
                for (effect, copied) in zip(clip.effects, copy.effects) {
                    #expect(copied.isEnabled == effect.isEnabled)
                    switch (effect.kind, copied.kind) {
                    case (.mosaic(let a), .mosaic(let b)):
                        #expect(a.style == b.style)
                        expectClose(a.scale, b.scale)
                    case (.colorCorrection, .colorCorrection), (.pan, .pan):
                        #expect(copied.kind == effect.kind)
                    case (.unsupported(let a), .unsupported(let b)):
                        #expect(a.identifier == b.identifier && a.name == b.name && a.parameters == b.parameters)
                    default:
                        Issue.record("\(effect.kind) came back as \(copied.kind)")
                    }
                }
            }
        }
        // Nothing went missing on the way, other than the Glow it never had.
        #expect(imported.report.items.map(\.issue) == [.unsupportedEffect(name: "Glow")])
    }

    private func expectClose(_ a: Animatable<Double>, _ b: Animatable<Double>, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(a.value - b.value) < 0.00001, sourceLocation: sourceLocation)
        #expect(a.keyframes.map(\.time) == b.keyframes.map(\.time), sourceLocation: sourceLocation)
        #expect(zip(a.keyframes, b.keyframes).allSatisfy { abs($0.value - $1.value) < 0.00001 && $0.interpolation == $1.interpolation },
                sourceLocation: sourceLocation)
    }

    @Test func writesAStorylineWithConnectedClips() throws {
        let root = try MarkupElement.parse(export(sampleProject()))
        #expect(root["version"] == "1.11")
        let spine = try #require(root.allDescendants.first { $0.name == "spine" })
        // The first clip, a gap to the second, the second, and a gap to the end.
        #expect(spine.children.map(\.name) == ["asset-clip", "gap", "asset-clip"])
        #expect(spine.children[1]["duration"] == "2s")
        let connected = spine.children[0].children.filter { $0["lane"] != nil }
        #expect(connected.map { $0["lane"] } == ["1", "-1"])
        #expect(connected.map(\.name) == ["video", "asset-clip"])
        // In the first clip's own time, which starts at 1s.
        #expect(connected.map { $0["offset"] } == ["2s", "3/2s"])
        #expect(connected[1]["srcEnable"] == "audio")
        #expect(spine.children[2]["srcEnable"] == "video")
        let echo = try #require(spine.children[2].children.first { $0["lane"] == "-2" })
        #expect(echo["offset"] == "1s")
        let source = try #require(root.allDescendants.first { $0.name == "media-rep" })
        #expect(source["src"] == "file:///Volumes/Media/IMG_1805.MOV")
    }

    @Test func foldsGainIntoTheVolume() throws {
        var project = sampleProject()
        project.tracks[3].update(project.tracks[3].clips[0].id) { clip in
            var gain = Gain()
            gain.decibels = Animatable(6)
            clip.effects = [Effect(.gain(gain))]
        }
        let root = try MarkupElement.parse(export(project))
        let volumes = root.allDescendants.filter { $0.name == "adjust-volume" }.compactMap { $0["amount"] }
        #expect(volumes.contains("6dB"))
    }

    @Test func connectsClipsToAStillInItsOwnTime() throws {
        var project = sampleProject()
        let tree = project.media[3], opening = project.media[0]
        // A still trimmed from its start, as an import's cut at a transition leaves it.
        project.tracks = [
            Track(kind: .video, clips: [Clip(mediaID: tree.id, sourceRange: CMTimeRange(start: seconds(2), duration: seconds(4)))]),
            Track(kind: .video, clips: [Clip(mediaID: opening.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(1)),
                                             timelineStart: seconds(1))]),
        ]
        let spine = try #require(try MarkupElement.parse(export(project)).allDescendants.first { $0.name == "spine" })
        #expect(spine.children[0].name == "video")
        #expect(spine.children[0]["start"] == "0s")
        #expect(spine.children[0].children.first { $0["lane"] == "1" }?["offset"] == "1s")
    }

    @Test func putsCutsOnTheProjectsFrames() throws {
        var project = sampleProject()
        project.tracks = [Track(kind: .video, clips: [
            Clip(mediaID: project.media[0].id, sourceRange: CMTimeRange(start: seconds(1, 100), duration: seconds(99, 100))),
        ])]
        let clip = try #require(try MarkupElement.parse(export(project)).allDescendants.first { $0.name == "asset-clip" })
        #expect(clip["start"] == "0s")
        #expect(clip["duration"] == "1s")
    }

    @Test(.enabled(if: canValidate))
    func validatesAgainstFinalCutsDTD() throws {
        let folder = URL.temporaryDirectory.appending(path: "FCPXML-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Copied out of the app: xmllint takes no spaces in the path.
        let dtd = folder.appending(path: "FCPXMLv1_11.dtd")
        try FileManager.default.copyItem(at: try #require(Self.installedDTD), to: dtd)
        let file = folder.appending(path: "Export.fcpxml")
        try export(sampleProject()).write(to: file)
        let fixture = InterchangeFixtures.directory.appending(path: "Storylines.fcpxml")

        for document in [file, fixture] {
            let process = Process()
            process.executableURL = Self.xmllint
            process.arguments = ["--noout", "--dtdvalid", dtd.path, document.path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(process.terminationStatus == 0, "\(document.lastPathComponent): \(output)")
        }
    }
}

struct InterchangeMediaTests {
    @Test(.enabled(if: Samples.isAvailable))
    func copiesInTheMediaItFinds() async throws {
        let imported = try InterchangeFixtures.read("Storylines.fcpxml", baseURL: Samples.directory)
        let store = PackageMediaStore()
        let gathered = await ProjectInterchange.gatherMedia(for: imported, into: store)
        #expect(gathered.issues(.missingMedia).isEmpty)
        for item in gathered.project.media {
            #expect(store.resolver.url(for: item) != nil, "\(item.name)")
        }
        // Read again from the file itself, rather than taken from the project.
        let opening = try #require(gathered.project.media.first { $0.name == "IMG_1805.MOV" })
        #expect(abs(opening.metadata.nominalFrameRate - 30000.0 / 1001) < 0.0001)
        #expect(opening.id == imported.project.media.first { $0.name == "IMG_1805.MOV" }?.id)
    }

    @Test func leavesMediaItCantFindReadyToRelink() async throws {
        let empty = URL.temporaryDirectory.appending(path: "Nothing \(UUID().uuidString)", directoryHint: .isDirectory)
        let imported = try InterchangeFixtures.read("Premiere.xml", baseURL: empty)
        let store = PackageMediaStore()
        let gathered = await ProjectInterchange.gatherMedia(
            for: imported, into: store, takenPaths: ["Media/IMG_1805.MOV"], searchFolders: [empty]
        )
        let missing = gathered.issues(.missingMedia)
        #expect(missing.count == gathered.project.media.count)
        #expect(missing.contains(.missingMedia(file: "/Volumes/Footage/IMG_1805.MOV")))
        for item in gathered.project.media {
            #expect(store.resolver.url(for: item) == nil)
        }
        // Each keeps a place of its own in the package, clear of the project's.
        let paths = gathered.project.packageMediaPaths
        #expect(paths.count == gathered.project.media.count)
        #expect(!paths.contains("Media/IMG_1805.MOV"))
    }
}
