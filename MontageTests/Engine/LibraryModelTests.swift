import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct LibraryModelTests {
    static func item(_ name: String, _ kind: MediaItem.Kind, seconds: Int64 = 0, bin: MediaBin.ID? = nil) -> MediaItem {
        MediaItem(name: name, kind: kind, location: .package(path: "Media/\(name)"),
                  metadata: MediaMetadata(duration: CMTime(value: seconds, timescale: 1)), binID: bin)
    }

    static func seconds(_ value: Int64) -> CMTime { CMTime(value: value, timescale: 1) }

    @Test func tellsUsedMediaFromUnused() {
        let used = Self.item("A.mov", .video, seconds: 4)
        let unused = Self.item("B.mov", .video, seconds: 4)
        let music = Self.item("C.m4a", .audio, seconds: 10)
        var project = Project(media: [used, unused, music])
        project.appendClip(of: used.id)
        project.appendClip(of: used.id)
        project.appendClip(of: music.id)

        #expect(project.usedMediaIDs == [used.id, music.id])
        #expect(project.clipCounts == [used.id: 2, music.id: 1])
        #expect(project.unusedMedia.map(\.id) == [unused.id])

        #expect(project.removeUnusedMedia() == [unused.id])
        #expect(project.media.map(\.id) == [used.id, music.id])
        #expect(project.tracks.flatMap(\.clips).count == 3)
    }

    @Test func filesMediaInBins() throws {
        let item = Self.item("A.mov", .video, seconds: 4)
        var project = Project(media: [item])
        let bin = project.addBin(named: "B-roll")
        project.moveMedia([item.id], toBin: bin)
        #expect(project.media[0].binID == bin)

        // A bin that isn't there files nothing.
        project.moveMedia([item.id], toBin: UUID())
        #expect(project.media[0].binID == bin)

        project.renameBin(bin, to: "Interviews")
        #expect(project.bins.map(\.name) == ["Interviews"])
        project.removeBin(bin)
        #expect(project.bins.isEmpty)
        #expect(project.media[0].binID == nil)
    }

    @Test func keepsBinsWhenSavedAndReadBack() throws {
        var project = Project(media: [Self.item("A.mov", .video, seconds: 4)])
        let bin = project.addBin(named: "B-roll")
        project.moveMedia([project.media[0].id], toBin: bin)
        let read = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(read == project)
    }

    @Test func searchesSortsAndFilters() {
        let bin = UUID()
        let media = [
            Self.item("Beach Sunset.mov", .video, seconds: 30, bin: bin),
            Self.item("theme.m4a", .audio, seconds: 120),
            Self.item("Café.jpg", .image),
            Self.item("beach walk.mov", .video, seconds: 60),
        ]
        var project = Project(media: media)
        project.bins = [MediaBin(id: bin, name: "Beach")]
        project.appendClip(of: media[1].id)
        let names = { (query: LibraryQuery) in query.items(in: project).map(\.name) }

        #expect(names(LibraryQuery()) == media.map(\.name))
        #expect(names(LibraryQuery(search: "BEACH")) == ["Beach Sunset.mov", "beach walk.mov"])
        #expect(names(LibraryQuery(search: "beach walk")) == ["beach walk.mov"])
        #expect(names(LibraryQuery(search: "cafe")) == ["Café.jpg"])
        #expect(names(LibraryQuery(kinds: [.audio, .image])) == ["theme.m4a", "Café.jpg"])
        #expect(names(LibraryQuery(scope: .bin(bin))) == ["Beach Sunset.mov"])
        #expect(names(LibraryQuery(scope: .unfiled, order: .name))
                == ["beach walk.mov", "Café.jpg", "theme.m4a"])
        #expect(names(LibraryQuery(order: .duration)).prefix(2) == ["theme.m4a", "beach walk.mov"])
        #expect(names(LibraryQuery(order: .kind))
                == ["Beach Sunset.mov", "beach walk.mov", "theme.m4a", "Café.jpg"])
        #expect(!names(LibraryQuery(unusedOnly: true)).contains("theme.m4a"))
    }

    @Test func dropsMediaAtATimeWithoutCoveringClips() throws {
        let a = Self.item("A.mov", .video, seconds: 4)
        let b = Self.item("B.mov", .video, seconds: 2)
        let music = Self.item("C.m4a", .audio, seconds: 10)
        var project = Project(media: [a, b, music])
        project.appendClip(of: a.id)
        let videoTrack = project.tracks[0].id

        // Over the clip that's there: onto a new video track instead.
        project.insertClips(of: [b.id], at: Self.seconds(1), onTrack: videoTrack)
        #expect(project.tracks.map(\.kind) == [.video, .video])
        #expect(project.tracks[1].clips[0].timelineStart == Self.seconds(1))

        // After it, on the track asked for; audio goes on an audio track,
        // after the video tracks, one after another from the time.
        let added = project.insertClips(of: [b.id, music.id], at: Self.seconds(4), onTrack: videoTrack)
        #expect(added.count == 2)
        #expect(project.tracks[0].clips.map(\.timelineStart) == [.zero, Self.seconds(4)])
        #expect(project.tracks.map(\.kind) == [.video, .video, .audio])
        #expect(project.tracks[2].clips[0].timelineStart == Self.seconds(6))
    }

    @Test func placesADropWithoutMakingIt() throws {
        let a = Self.item("A.mov", .video, seconds: 4)
        let b = Self.item("B.mov", .video, seconds: 2)
        let music = Self.item("C.m4a", .audio, seconds: 10)
        var project = Project(media: [a, b, music])
        project.appendClip(of: a.id)
        let videoTrack = project.tracks[0].id
        let before = project

        let placements = project.placements(ofClipsOf: [b.id, music.id], at: Self.seconds(1), onTrack: videoTrack)
        #expect(project == before)
        #expect(placements.map(\.mediaID) == [b.id, music.id])
        // Over A, so on a new video track; the music follows it on a new
        // audio track.
        #expect(placements.map(\.kind) == [.video, .audio])
        #expect(placements.map(\.isNewTrack) == [true, true])
        #expect(placements[0].range == CMTimeRange(start: Self.seconds(1), duration: Self.seconds(2)))
        #expect(placements[1].range.start == Self.seconds(3))

        // After A, it fits on A's track.
        let after = project.placements(ofClipsOf: [b.id], at: Self.seconds(4), onTrack: videoTrack)
        #expect(after.map(\.trackID) == [videoTrack])
        #expect(after.map(\.isNewTrack) == [false])

        // The same as the drop makes.
        project.insertClips(of: [b.id], at: Self.seconds(4), onTrack: videoTrack)
        #expect(project.tracks[0].clips.last?.timelineRange == after[0].range)
    }
}
