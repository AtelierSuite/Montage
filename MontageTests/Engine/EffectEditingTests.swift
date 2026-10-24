import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct EffectEditingTests {
    private let oneSecond = CMTime(value: 1, timescale: 1)

    private func project() -> (Project, Clip.ID) {
        let clip = Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: .zero, duration: CMTime(value: 5, timescale: 1)))
        var track = Track(kind: .video)
        track.append(clip)
        return (Project(tracks: [track]), clip.id)
    }

    @Test func addsChangesMovesAndRemovesEffects() throws {
        var (project, clipID) = project()
        let correction = Effect(.colorCorrection(ColorCorrection()))
        let mosaic = Effect(.mosaic(Mosaic()))
        let added = project.addEffect(correction, toClip: clipID)
        #expect(added)
        project.addEffect(mosaic, toClip: clipID)
        let addedToNothing = project.addEffect(mosaic, toClip: UUID())
        #expect(!addedToNothing)

        project.updateEffect(mosaic.id, ofClip: clipID) { $0.mask = Mask(.ellipse) }
        project.moveEffect(mosaic.id, ofClip: clipID, by: -5)
        var effects = try #require(project.clip(id: clipID)).clip.effects
        #expect(effects.map(\.id) == [mosaic.id, correction.id])
        #expect(effects.first?.mask == Mask(.ellipse))

        project.removeEffect(mosaic.id, fromClip: clipID)
        effects = try #require(project.clip(id: clipID)).clip.effects
        #expect(effects.map(\.id) == [correction.id])
    }

    @Test func setsAValueThroughoutUntilKeyframed() {
        var value = Animatable(0.0)
        value.set(2, at: oneSecond)
        #expect(value.value == 2 && !value.isAnimated)

        value.toggleKeyframe(at: .zero)
        #expect(value.hasKeyframe(at: .zero))
        value.set(4, at: CMTime(value: 2, timescale: 1))
        #expect(value.keyframes.map(\.value) == [2, 4])
        #expect(value.value(at: oneSecond) == 3)

        value.toggleKeyframe(at: CMTime(value: 2, timescale: 1))
        value.toggleKeyframe(at: .zero)
        // The last one gone, the value it had stays.
        #expect(!value.isAnimated)
        #expect(value.value == 2)
    }
}
