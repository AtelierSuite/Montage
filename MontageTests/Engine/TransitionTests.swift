import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

/// Seconds.
private func s(_ seconds: Int64, _ timescale: Int32 = 1) -> CMTime {
    CMTime(value: seconds, timescale: timescale)
}

private func range(_ start: CMTime, _ end: CMTime) -> CMTimeRange {
    CMTimeRange(start: start, end: end)
}

struct TransitionTests {
    /// Three clips meeting at 3 and 6, then one after a gap at 10.
    private func fixture() -> TimelineFixture {
        TimelineFixture([(0, 1, 3), (3, 4, 3), (6, 7, 3), (10, 0, 2)])
    }

    @Test func playsCentredOnTheCut() throws {
        var fixture = fixture()
        let idResult = fixture.project.addTransition(from: fixture.id(0), to: fixture.id(1), duration: s(1))
        let id = try #require(idResult)
        let placed = fixture.project.placedTransitions(on: fixture.project.tracks[0])
        #expect(placed.map(\.id) == [id])
        #expect(placed.first?.timelineRange == range(s(5, 2), s(7, 2)))
        #expect(placed.first?.progress(at: s(3)) == 0.5)
        #expect(placed.first?.outgoing.id == fixture.id(0))
        #expect(placed.first?.incoming.id == fixture.id(1))
    }

    @Test func onlyClipsThatMeetCanHaveOne() {
        var fixture = fixture()
        #expect(fixture.project.addTransition(from: fixture.id(2), to: fixture.id(3), duration: s(1)) == nil)
        #expect(fixture.project.addTransition(from: fixture.id(1), to: fixture.id(0), duration: s(1)) == nil)
        #expect(fixture.project.transitions.isEmpty)
    }

    @Test func aNewOneAtACutReplacesTheOld() throws {
        var fixture = fixture()
        fixture.project.addTransition(from: fixture.id(0), to: fixture.id(1), duration: s(1))
        let secondResult = fixture.project.addTransition(from: fixture.id(0), to: fixture.id(1), duration: s(2))
        let second = try #require(secondResult)
        #expect(fixture.project.transitions.map(\.id) == [second])
    }

    @Test func isKeptToTheClipsLengths() throws {
        var fixture = fixture()
        // Longer than either clip: all of the middle clip goes to the first.
        fixture.project.addTransition(from: fixture.id(0), to: fixture.id(1), duration: s(8))
        fixture.project.addTransition(from: fixture.id(1), to: fixture.id(2), duration: s(2))
        let placed = fixture.project.placedTransitions(on: fixture.project.tracks[0])
        #expect(placed.map(\.beforeCut) == [s(3), .zero])
        #expect(placed.map(\.afterCut) == [s(3), s(1)])
        // None overlap.
        #expect(placed[0].timelineRange.end <= placed[1].timelineRange.start)
    }

    @Test func movesWithItsClipsAndLapsesWhenTheyPart() throws {
        var fixture = fixture()
        let (first, second) = (fixture.id(0), fixture.id(1))
        fixture.project.addTransition(from: first, to: second, duration: s(1))
        fixture.project.moveClips([first, second], by: s(20))
        #expect(fixture.project.placedTransitions().first?.transition.beforeCut == s(1, 2))
        #expect(fixture.project.placedTransitions().first?.transition.outgoing.id == first)

        fixture.project.moveClips([second], by: s(1))
        #expect(fixture.project.placedTransitions().isEmpty)
        fixture.project.removeStaleTransitions()
        #expect(fixture.project.transitions.isEmpty)
    }

    @Test func goesWithThePartAfterASplit() throws {
        var fixture = fixture()
        fixture.project.addTransition(from: fixture.id(0), to: fixture.id(1), duration: s(1))
        let afterResult = fixture.project.splitClip(fixture.id(0), at: s(1))
        let after = try #require(afterResult)
        #expect(fixture.project.transitions.first?.outgoingClipID == after)
        #expect(fixture.project.placedTransitions().count == 1)
        fixture.project.removeStaleTransitions()
        #expect(fixture.project.transitions.count == 1)
    }

    @Test func goesWhenAClipIsDeleted() {
        var fixture = fixture()
        fixture.project.addTransition(from: fixture.id(0), to: fixture.id(1), duration: s(1))
        fixture.project.removeClips([fixture.id(1)])
        fixture.project.removeStaleTransitions()
        #expect(fixture.project.transitions.isEmpty)
    }

    @Test func changesLengthKeepingTheCutInProportion() throws {
        var fixture = fixture()
        let idResult = fixture.project.addTransition(from: fixture.id(0), to: fixture.id(1), duration: s(1))
        let id = try #require(idResult)
        fixture.project.setDuration(ofTransition: id, to: s(2))
        #expect(fixture.project.transition(id: id)?.beforeCut == s(1))
        #expect(fixture.project.transition(id: id)?.afterCut == s(1))

        fixture.project.transitions[0].beforeCut = s(1, 2)
        fixture.project.transitions[0].afterCut = s(3, 2)
        fixture.project.setDuration(ofTransition: id, to: s(4))
        #expect(fixture.project.transition(id: id)?.beforeCut == s(1))
        #expect(fixture.project.transition(id: id)?.afterCut == s(3))
    }

    @Test func findsTheCutNearATime() {
        let fixture = fixture()
        #expect(fixture.project.cut(near: s(31, 10), onTrackAt: 0, within: s(1, 2))?.incoming.id == fixture.id(1))
        #expect(fixture.project.cut(near: s(58, 10), onTrackAt: 0, within: s(1, 2))?.incoming.id == fixture.id(2))
        #expect(fixture.project.cut(near: s(45, 10), onTrackAt: 0, within: s(1, 2)) == nil)
        // The gap before the last clip isn't a cut.
        #expect(fixture.project.cut(near: s(10), onTrackAt: 0, within: s(1, 2)) == nil)
    }

    @Test func isSavedWithTheProject() throws {
        var fixture = fixture()
        fixture.project.addTransition(from: fixture.id(0), to: fixture.id(1), duration: CMTime(value: 1001, timescale: 30000))
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(fixture.project))
        #expect(decoded.transitions == fixture.project.transitions)
        let old = try JSONDecoder().decode(Project.self, from: Data(#"{"formatVersion": 1}"#.utf8))
        #expect(old.transitions.isEmpty)
    }

    @Test func aChangeToOneRebuilds() throws {
        var fixture = fixture()
        let before = fixture.project
        let idResult = fixture.project.addTransition(from: fixture.id(0), to: fixture.id(1), duration: s(1))
        let id = try #require(idResult)
        #expect(PlaybackController.needsRebuild(from: before, to: fixture.project))
        let added = fixture.project
        fixture.project.setDuration(ofTransition: id, to: s(2))
        #expect(PlaybackController.needsRebuild(from: added, to: fixture.project))
    }
}
