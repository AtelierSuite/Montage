import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing
import UniformTypeIdentifiers

private typealias F = AAFTestFile

private func frames(_ count: Int64, _ rate: Int32 = 25) -> CMTime {
    CMTime(value: count, timescale: rate)
}

private let picture = AAFDefinition.picture
private let sound = AAFDefinition.sound

private let alphaMaster = F.mobID(1), alphaFile = F.mobID(2)
private let bravoMaster = F.mobID(3), bravoFile = F.mobID(4)
private let timelineID = F.mobID(9)

/// Alpha and Bravo, picture and sound files, each with a master mob.
private func standardMedia() -> [AAFTestObject] {
    F.media(master: alphaMaster, file: alphaFile, name: "Alpha", url: "file:///Volumes/Media/Alpha.mov", length: 500)
        + F.media(master: bravoMaster, file: bravoFile, name: "Bravo", url: "file:///Volumes/Media/Bravo.mov", length: 500)
}

private func timeline(_ slots: [AAFTestObject], name: String = "Cut", id: MobID = timelineID, topLevel: Bool = true)
    -> AAFTestObject {
    let mob = F.mob(AAFClass.compositionMob, id: id, name: name, slots: slots)
    if topLevel { mob.set(AAFProperty.ID.usageCode, auid: AAFDefinition.topLevelUsage) }
    return mob
}

private func read(_ file: AAFTestFile, sectorSize: Int = 4096) throws -> ImportedProject {
    try AAFImporter.read(file.data(sectorSize: sectorSize), baseURL: nil)
}

struct AAFImportTests {
    @Test(arguments: [512, 4096])
    func readsClipsGapsAndMedia(sectorSize: Int) throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [
                F.sourceClip(picture, length: 50, start: 10, mob: alphaMaster, slot: 1),
                F.filler(picture, length: 25),
                F.sourceClip(picture, length: 40, start: 100, mob: bravoMaster, slot: 1),
            ])),
            F.timelineSlot(2, F.sequence(sound, [
                F.sourceClip(sound, length: 50, start: 10, mob: alphaMaster, slot: 2),
            ])),
        ])]
        let imported = try read(file, sectorSize: sectorSize)
        #expect(imported.name == "Cut")
        #expect(imported.project.settings.frameDuration == frames(1))
        #expect(imported.project.settings.renderSize == CGSize(width: 1920, height: 1080))
        #expect(imported.project.tracks.map(\.kind) == [.video])

        let alpha = try #require(imported.clip("Alpha.mov", on: .video)?.clip)
        #expect(alpha.timelineStart == .zero)
        #expect(alpha.sourceRange == CMTimeRange(start: frames(10), duration: frames(50)))
        // Its sound, in step, plays with it.
        #expect(!alpha.isAudioDetached)
        let bravo = try #require(imported.clip("Bravo.mov", on: .video)?.clip)
        #expect(bravo.timelineStart == frames(75))
        #expect(bravo.sourceRange == CMTimeRange(start: frames(100), duration: frames(40)))
        #expect(bravo.isAudioDetached)

        let alphaItem = try #require(imported.project.media.first { $0.name == "Alpha.mov" })
        #expect(alphaItem.kind == .video)
        #expect(alphaItem.metadata.duration == frames(500))
        #expect(alphaItem.metadata.hasAudio)
        #expect(imported.mediaSources[alphaItem.id] == URL(fileURLWithPath: "/Volumes/Media/Alpha.mov"))
        #expect(imported.report.isEmpty)
    }

    @Test func keepsSoundOutOfStepOnItsOwnTrack() throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [F.sourceClip(picture, length: 50, start: 10, mob: alphaMaster)])),
            F.timelineSlot(2, F.sequence(sound, [
                F.filler(sound, length: 5),
                F.sourceClip(sound, length: 50, start: 10, mob: alphaMaster, slot: 2),
            ])),
            // The other channel, the same file: one clip plays them both.
            F.timelineSlot(3, F.sequence(sound, [
                F.filler(sound, length: 5),
                F.sourceClip(sound, length: 50, start: 10, mob: alphaMaster, slot: 2),
            ])),
        ])]
        let imported = try read(file)
        #expect(imported.project.tracks.map(\.kind) == [.video, .audio])
        #expect(imported.clip("Alpha.mov", on: .video)?.clip.isAudioDetached == true)
        let audio = try #require(imported.clip("Alpha.mov", on: .audio)?.clip)
        #expect(audio.timelineStart == frames(5))
        #expect(imported.clips(of: "Alpha.mov").count == 2)
    }

    @Test func cutsTransitionsHalfwayThrough() throws {
        var file = F()
        file.operationDefinitions = [F.definition(AUID("0d010101-0101-1c00-060e-2b3402060101"),
                                                  id: AAFDefinition.videoDissolve, name: "Cross Dissolve")]
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [
                F.sourceClip(picture, length: 50, start: 10, mob: alphaMaster),
                F.transition(picture, length: 10, cutPoint: 5),
                F.sourceClip(picture, length: 40, start: 100, mob: bravoMaster),
            ])),
        ])]
        let imported = try read(file)
        #expect(imported.project.tracks.count == 1)
        let clips = imported.project.tracks[0].clips
        #expect(clips.count == 2)
        #expect(clips[0].timelineRange == CMTimeRange(start: .zero, duration: frames(45)))
        #expect(clips[1].timelineStart == frames(45))
        #expect(clips[1].sourceRange == CMTimeRange(start: frames(105), duration: frames(35)))
        #expect(imported.issues(.changed) == [.transition(name: "Cross Dissolve")])
    }

    @Test func playsSpeedChangesAtNormalSpeed() throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [
                F.operationGroup(picture, length: 40, operation: AAFDefinition.videoSpeedControl,
                                 inputs: [F.sourceClip(picture, length: 20, start: 0, mob: alphaMaster)],
                                 parameters: [F.constant(AAFDefinition.speedRatio, rational: 1, 2)]),
                // At its own speed, it's left as it is.
                F.operationGroup(picture, length: 10, operation: AAFDefinition.videoSpeedControl,
                                 inputs: [F.sourceClip(picture, length: 10, start: 0, mob: bravoMaster)],
                                 parameters: [F.constant(AAFDefinition.speedRatio, rational: 1, 1)]),
            ])),
        ])]
        let imported = try read(file)
        let alpha = try #require(imported.clip("Alpha.mov")?.clip)
        #expect(alpha.sourceRange == CMTimeRange(start: .zero, duration: frames(40)))
        #expect(imported.clip("Bravo.mov")?.clip.timelineStart == frames(40))
        #expect(imported.report.items.map(\.issue) == [.speedChange])
        #expect(imported.report.items.first?.clipName == "Alpha")
    }

    @Test func readsVolumeAndPan() throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(sound, [
                F.operationGroup(sound, length: 40, operation: AAFDefinition.monoAudioGain,
                                 inputs: [F.sourceClip(sound, length: 40, mob: alphaMaster, slot: 2)],
                                 parameters: [F.constant(AAFDefinition.amplitude, rational: 1, 2)]),
                F.operationGroup(sound, length: 40, operation: AAFDefinition.monoAudioPan,
                                 inputs: [F.sourceClip(sound, length: 40, mob: bravoMaster, slot: 2)],
                                 parameters: [F.constant(AAFDefinition.pan, rational: 1, 1)]),
            ])),
        ])]
        let imported = try read(file)
        #expect(imported.clip("Alpha.mov", on: .audio)?.clip.volume.value == 0.5)
        let bravo = try #require(imported.clip("Bravo.mov", on: .audio)?.clip)
        guard case .pan(let pan)? = bravo.effects.first?.kind else {
            Issue.record("Expected a pan")
            return
        }
        #expect(pan.position.value == 1)
        #expect(imported.report.isEmpty)
    }

    @Test func keepsOtherEffectsTurnedOff() throws {
        let blur = AUID("11111111-2222-3333-4444-555555555555")
        var file = F()
        file.operationDefinitions = [F.definition(AUID("0d010101-0101-1c00-060e-2b3402060101"), id: blur, name: "Blur")]
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [
                F.operationGroup(picture, length: 40, operation: blur,
                                 inputs: [F.sourceClip(picture, length: 40, mob: alphaMaster)]),
                // An effect with nothing in it makes its own picture.
                F.operationGroup(picture, length: 10, operation: blur, inputs: []),
            ])),
        ])]
        let imported = try read(file)
        let alpha = try #require(imported.clip("Alpha.mov")?.clip)
        #expect(alpha.effects.count == 1)
        #expect(alpha.effects.first?.isEnabled == false)
        guard case .unsupported(let effect)? = alpha.effects.first?.kind else {
            Issue.record("Expected an unsupported effect")
            return
        }
        #expect(effect.format == "aaf")
        #expect(effect.name == "Blur")
        #expect(imported.issues(.unsupportedEffect) == [.unsupportedEffect(name: "Blur")])
        #expect(imported.issues(.notImported) == [.generator(name: "Blur")])
    }

    @Test func readsMarkers() throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [F.sourceClip(picture, length: 100, mob: alphaMaster)])),
            F.eventSlot(1000, F.sequence(AUID("01030201-1000-0000-060e-2b3404010101"), [
                F.marker(at: 50, comment: nil, descriptive: false),
                F.marker(at: 30, comment: "Check focus"),
            ])),
        ])]
        let imported = try read(file)
        #expect(imported.project.markers.map(\.time) == [frames(30), frames(50)])
        #expect(imported.project.markers.map(\.name) == ["Check focus", ""])
    }

    @Test func leavesMediaWithoutALocatorToBeRelinked() throws {
        var file = F()
        file.mobs = F.media(master: alphaMaster, file: alphaFile, name: "Interview", url: nil, length: 300) + [timeline([
            F.timelineSlot(1, F.sequence(picture, [F.sourceClip(picture, length: 30, start: 5, mob: alphaMaster)])),
        ])]
        let imported = try read(file)
        let clip = try #require(imported.clip("Interview")?.clip)
        #expect(clip.sourceRange.start == frames(5))
        #expect(imported.mediaSources.isEmpty)
    }

    @Test func convertsBetweenEditRates() throws {
        var file = F()
        // Sound counted in samples, cut on an NTSC timeline.
        file.mobs = F.media(master: alphaMaster, file: alphaFile, name: "Sound", url: "file:///Media/sound.wav",
                            length: 480_000, rate: (48000, 1), picture: false)
            + [timeline([
                F.timelineSlot(1, rate: (30000, 1001), F.sequence(sound, [
                    F.filler(sound, length: 30),
                    F.sourceClip(sound, length: 60, start: 30, mob: alphaMaster, slot: 1),
                ])),
            ])]
        let imported = try read(file)
        let clip = try #require(imported.clip("sound.wav", on: .audio)?.clip)
        #expect(clip.timelineStart == CMTime(value: 1001, timescale: 1000))
        #expect(clip.sourceRange == CMTimeRange(start: CMTime(value: 1001, timescale: 1000),
                                                duration: CMTime(value: 2002, timescale: 1000)))
        let item = try #require(imported.project.media.first)
        #expect(item.kind == .audio)
        #expect(item.metadata.duration == CMTime(value: 10, timescale: 1))
    }

    @Test func followsOriginsAndSourceMobChains() throws {
        // Master → file mob without a locator → import source with one,
        // whose slot starts an hour in, at its timecode.
        let importMob = F.mobID(5)
        let descriptor = AAFTestObject(AAFClass.importDescriptor).vector(AAFProperty.ID.locators, [
            AAFTestObject(AAFClass.networkLocator).set(AAFProperty.ID.urlString, string: "file:///Media/Original.mov"),
        ])
        let original = F.mob(AAFClass.sourceMob, id: importMob, name: "Original", slots: [
            F.timelineSlot(1, origin: 90_000, F.sourceClip(picture, length: 100_000, mob: nil, slot: 0)),
        ]).strong(AAFProperty.ID.essenceDescription, descriptor)
        let fileMob = F.mob(AAFClass.sourceMob, id: alphaFile, name: "Transcode", slots: [
            F.timelineSlot(1, F.sequence(picture, [F.sourceClip(picture, length: 500, start: 0, mob: importMob)])),
        ]).strong(AAFProperty.ID.essenceDescription, AAFTestObject(AAFClass.cdciDescriptor))
        let master = F.mob(AAFClass.masterMob, id: alphaMaster, name: "Shot", slots: [
            F.timelineSlot(1, F.sequence(picture, [
                F.filler(picture, length: 100),
                F.sourceClip(picture, length: 500, start: 0, mob: alphaFile),
            ])),
        ])
        var file = F()
        file.mobs = [master, fileMob, original, timeline([
            F.timelineSlot(1, F.sequence(picture, [F.sourceClip(picture, length: 20, start: 110, mob: alphaMaster)])),
        ])]
        let imported = try read(file)
        let clip = try #require(imported.clip("Original.mov")?.clip)
        // 110 into the master is 10 into the file, 90,010 into the original.
        #expect(clip.sourceRange.start == frames(90_010))
        let item = try #require(imported.project.media.first)
        #expect(imported.mediaSources[item.id]?.path == "/Media/Original.mov")
    }

    @Test func readsNestedCompositions() throws {
        let nestedID = F.mobID(10)
        var file = F()
        file.mobs = standardMedia() + [
            // Neither is marked top-level: the one nothing uses is.
            timeline([
                F.timelineSlot(1, F.sequence(picture, [
                    F.sourceClip(picture, length: 50, start: 0, mob: alphaMaster),
                    F.sourceClip(picture, length: 100, start: 0, mob: bravoMaster),
                ])),
            ], name: "Nest", id: nestedID, topLevel: false),
            timeline([
                F.timelineSlot(1, F.sequence(picture, [
                    F.filler(picture, length: 10),
                    F.sourceClip(picture, length: 30, start: 40, mob: nestedID, slot: 1),
                ])),
            ], name: "Main", topLevel: false),
        ]
        let imported = try read(file)
        #expect(imported.name == "Main")
        let alpha = try #require(imported.clip("Alpha.mov")?.clip)
        #expect(alpha.timelineRange == CMTimeRange(start: frames(10), duration: frames(10)))
        #expect(alpha.sourceRange.start == frames(40))
        let bravo = try #require(imported.clip("Bravo.mov")?.clip)
        #expect(bravo.timelineRange == CMTimeRange(start: frames(20), duration: frames(20)))
        #expect(bravo.sourceRange.start == .zero)
        #expect(imported.report.isEmpty)
    }

    @Test func importsTheFirstOfSeveralTimelines() throws {
        var file = F()
        file.mobs = standardMedia() + [
            timeline([F.timelineSlot(1, F.sequence(picture, [F.sourceClip(picture, length: 5, mob: alphaMaster)]))],
                     name: "First"),
            timeline([F.timelineSlot(1, F.sequence(picture, [F.sourceClip(picture, length: 5, mob: bravoMaster)]))],
                     name: "Second", id: F.mobID(11)),
        ]
        let imported = try read(file)
        #expect(imported.name == "First")
        #expect(imported.issues(.notImported) == [.otherTimelines(count: 1)])
    }

    @Test func readsApplicationsOwnSubclasses() throws {
        let customClip = AUID("a0000000-0000-0000-0000-000000000001")
        let clip = F.sourceClip(picture, length: 30, mob: alphaMaster)
        clip.classID = customClip
        var file = F()
        file.classDefinitions = [(customClip, AAFClass.sourceClip)]
        file.mobs = standardMedia() + [timeline([F.timelineSlot(1, F.sequence(picture, [clip]))])]
        #expect(try read(file).clip("Alpha.mov") != nil)
    }

    @Test func refusesFilesWithoutATimeline() throws {
        #expect(throws: InterchangeError.noTimeline) { try read(F()) }
    }

    // MARK: - As real applications write them

    /// Clips exported from a bin, with no sequence, as Media Composer does.
    @Test func readsMasterMobsOneAfterAnother() throws {
        var file = F()
        file.mobs = F.media(master: alphaMaster, file: alphaFile, name: "Alpha", url: nil, length: 50)
            + F.media(master: bravoMaster, file: bravoFile, name: "Bravo", url: nil, length: 30)
        let imported = try read(file)
        #expect(imported.name == "Alpha")
        let alpha = try #require(imported.clip("Alpha", on: .video)?.clip)
        #expect(alpha.timelineRange == CMTimeRange(start: .zero, duration: frames(50)))
        #expect(!alpha.isAudioDetached)
        let bravo = try #require(imported.clip("Bravo", on: .video)?.clip)
        #expect(bravo.timelineRange == CMTimeRange(start: frames(50), duration: frames(30)))
        #expect(imported.report.isEmpty)
    }

    /// Media Composer's video tracks, as layers of a nested scope, where
    /// each shows those under it by scope references.
    @Test func readsNestedScopesAsLayers() throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.nestedScope(picture, length: 50, [
                F.sequence(picture, [F.sourceClip(picture, length: 50, mob: alphaMaster)]),
                F.sequence(picture, [
                    F.scopeReference(picture, length: 10),
                    F.sourceClip(picture, length: 20, start: 5, mob: bravoMaster),
                    F.scopeReference(picture, length: 20),
                ]),
            ])),
        ])]
        let imported = try read(file)
        #expect(imported.project.tracks.map { $0.clips.count } == [1, 1])
        #expect(imported.clip("Alpha.mov")?.track == 0)
        let bravo = try #require(imported.clip("Bravo.mov"))
        #expect(bravo.track == 1)
        #expect(bravo.clip.timelineRange == CMTimeRange(start: frames(10), duration: frames(20)))
        #expect(imported.report.isEmpty)
    }

    /// Media Composer mutes a clip by selecting the scope under it instead.
    @Test func leavesOutMutedClips() throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [
                F.selector(picture, length: 40, selected: F.scopeReference(picture, length: 40),
                           alternates: [F.sourceClip(picture, length: 40, mob: alphaMaster)]),
                F.sourceClip(picture, length: 10, mob: bravoMaster),
            ])),
        ])]
        let imported = try read(file)
        #expect(imported.clip("Alpha.mov") == nil)
        #expect(imported.clip("Bravo.mov")?.clip.timelineStart == frames(40))
        #expect(imported.report.items.map(\.issue) == [.disabledClip])
        #expect(imported.report.items.first?.clipName == "Alpha")
    }

    /// Keys and titles take what's under them as their first input.
    @Test func readsTheForegroundOfKeys() throws {
        let title = AUID("22222222-2222-3333-4444-555555555555")
        var file = F()
        file.operationDefinitions = [F.definition(AUID("0d010101-0101-1c00-060e-2b3402060101"), id: title, name: "Title_2")]
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [
                F.operationGroup(picture, length: 30, operation: title, inputs: [
                    F.sequence(picture, [F.scopeReference(picture, length: 30)]),
                    F.sourceClip(picture, length: 30, mob: alphaMaster),
                ]),
            ])),
        ])]
        let imported = try read(file)
        let alpha = try #require(imported.clip("Alpha.mov")?.clip)
        #expect(alpha.effects.first?.isEnabled == false)
        #expect(imported.issues(.unsupportedEffect) == [.unsupportedEffect(name: "Title_2")])
        #expect(imported.report.items.first?.clipName == "Alpha")
    }

    /// Media Composer writes a track's volume and pan as keyframed values
    /// over the whole track, mostly at their defaults.
    @Test func readsKeyframedVolumeAndPan() throws {
        let gain = AUID("33333333-2222-3333-4444-555555555555")
        let pan = AUID("44444444-2222-3333-4444-555555555555")
        let clipRatio = AUID("47c00f7d-fb55-11d3-9ff7-0004ac969f50")
        var file = F()
        let definitionClass = AUID("0d010101-0101-1c00-060e-2b3402060101")
        file.operationDefinitions = [F.definition(definitionClass, id: gain, name: "Audio Gain"),
                                     F.definition(definitionClass, id: pan, name: "Audio Pan")]
        file.mobs = standardMedia() + [timeline([
            // Rising from silence to full over the clip, centred.
            F.timelineSlot(1, F.operationGroup(sound, length: 40, operation: pan, inputs: [
                F.operationGroup(sound, length: 40, operation: gain,
                                 inputs: [F.sequence(sound, [F.sourceClip(sound, length: 40, mob: alphaMaster, slot: 2)])],
                                 parameters: [F.varying(AAFDefinition.amplitude, points: [(0, 0), (1000, 1000)])]),
            ], parameters: [F.varying(AAFDefinition.pan, points: [(0, 500), (500, 500), (1000, 500)])])),
            // Avid's own gain, with no level AAF defines.
            F.timelineSlot(2, F.operationGroup(sound, length: 40, operation: gain,
                                               inputs: [F.sourceClip(sound, length: 40, mob: bravoMaster, slot: 2)],
                                               parameters: [F.varying(clipRatio, points: [(500, 75)])])),
        ])]
        let imported = try read(file)
        let alpha = try #require(imported.clip("Alpha.mov", on: .audio)?.clip)
        #expect(alpha.effects.isEmpty)
        #expect(alpha.volume.isAnimated)
        #expect(alpha.volume.value(at: .zero) == 0)
        #expect(abs(alpha.volume.value(at: frames(20)) - 0.5) < 0.001)
        #expect(alpha.volume.value(at: frames(40)) == 1)
        #expect(imported.clip("Bravo.mov", on: .audio)?.clip.volume == Animatable(1))
        #expect(imported.report.items.map(\.issue) == [.setting(name: "Audio Gain")])
    }

    /// Premiere names its parameters "Amplitude multiplier" and "Pan
    /// value", and combines a file's channels in an effect of their own.
    @Test func readsPremieresChannelsVolumeAndPan() throws {
        let combiner = AUID("55555555-2222-3333-4444-555555555555")
        let amplitude = AUID("66666666-2222-3333-4444-555555555555")
        var file = F()
        let definitionClass = AUID("0d010101-0101-1c00-060e-2b3402060101")
        file.operationDefinitions = [F.definition(definitionClass, id: combiner, name: "Audio Channel Combiner")]
        file.parameterDefinitions = [F.definition(AUID("0d010101-0101-1d00-060e-2b3402060101"), id: amplitude,
                                                  name: "Amplitude multiplier")]
        let stereo = F.media(master: alphaMaster, file: alphaFile, name: "Stereo", url: "file:///Media/stereo.wav",
                             length: 100, picture: false)
        // Both channels: a second sound slot on the master and the file.
        stereo[0].properties[stereo[0].properties.firstIndex { $0.pid == AAFProperty.ID.slots }!].objects.append(
            F.timelineSlot(2, F.sequence(sound, [F.sourceClip(sound, length: 100, mob: alphaFile, slot: 1)])))
        file.mobs = stereo + [timeline([
            F.timelineSlot(1, F.sequence(sound, [
                F.operationGroup(sound, length: 40, operation: AAFDefinition.monoAudioGain, inputs: [
                    F.operationGroup(sound, length: 40, operation: combiner, inputs: [
                        F.sourceClip(sound, length: 40, mob: alphaMaster, slot: 1),
                        F.sourceClip(sound, length: 40, mob: alphaMaster, slot: 2),
                    ]),
                ], parameters: [F.constant(amplitude, rational: 1, 4)]),
            ])),
        ])]
        let imported = try read(file)
        #expect(imported.clips(of: "stereo.wav").count == 1)
        #expect(imported.clip("stereo.wav")?.clip.volume.value == 0.25)
        #expect(imported.report.isEmpty)
    }

    // MARK: - Where the timeline starts

    /// A timeline with a sound clip after `gap` edit units, a marker on its
    /// first frame, and its timecode.
    private func session(rate: (Int32, Int32), gap: Int64, timecode: AAFTestObject?) -> AAFTestFile {
        var file = F()
        var slots = [F.timelineSlot(1, rate: rate, F.sequence(sound, [
            F.filler(sound, length: gap),
            F.sourceClip(sound, length: 30, mob: alphaMaster, slot: 2),
        ]))]
        if let timecode { slots.append(F.timelineSlot(2, rate: rate, timecode)) }
        slots.append(F.eventSlot(1000, rate: rate, F.sequence(AUID("01030201-1000-0000-060e-2b3404010101"), [
            F.marker(at: gap, comment: "Start"),
        ])))
        file.mobs = standardMedia() + [timeline(slots)]
        return file
    }

    /// Premiere Pro counts a 29.97 timeline from 00:00:00;00 and puts a
    /// session starting at 01:00:00;00 an hour of drop-frame timecode in.
    @Test func countsPremieresTimelinesFromTheHour() throws {
        let ntsc: (Int32, Int32) = (30000, 1001)
        let imported = try read(session(rate: ntsc, gap: 107_892, timecode: F.timecode(length: 107_922, fps: 30)))
        #expect(imported.clip("Alpha.mov", on: .audio)?.clip.timelineStart == .zero)
        #expect(imported.project.markers.map(\.time) == [.zero])
    }

    /// Pro Tools does the same at whole frame rates.
    @Test func countsProToolsTimelinesFromTheHour() throws {
        let imported = try read(session(rate: (30, 1), gap: 108_000 + 300, timecode: F.timecode(length: 2_592_000, fps: 30)))
        #expect(imported.clip("Alpha.mov", on: .audio)?.clip.timelineStart == CMTime(value: 10, timescale: 1))
    }

    /// Media Composer and Resolve start their timelines at their first
    /// frame, and a timeline starting well into its hour keeps its place:
    /// at its start, 30 seconds in, and 1:11:00 in, at 25 fps.
    @Test(arguments: [0, 750, 106_500] as [Int64])
    func keepsTimelinesThatDontStartAnHourIn(gap: Int64) throws {
        let imported = try read(session(rate: (25, 1), gap: gap, timecode: F.timecode(length: 100, start: 90_000, fps: 25)))
        #expect(imported.clip("Alpha.mov", on: .audio)?.clip.timelineStart == frames(gap))
        #expect(imported.project.markers.map(\.time) == [frames(gap)])
    }

    /// Only the top-level composition is counted from its hour: a nested
    /// one, and the source mobs, keep their own times.
    @Test func countsOnlyTheTopLevelTimelineFromTheHour() throws {
        let nestedID = F.mobID(10)
        var file = F()
        file.mobs = standardMedia() + [
            timeline([F.timelineSlot(1, F.sequence(picture, [
                F.filler(picture, length: 90_000),
                F.sourceClip(picture, length: 50, start: 20, mob: alphaMaster),
            ]))], name: "Nest", id: nestedID, topLevel: false),
            timeline([F.timelineSlot(1, F.sequence(picture, [
                F.filler(picture, length: 90_000 + 25),
                F.sourceClip(picture, length: 30, start: 90_000 + 10, mob: nestedID, slot: 1),
            ]))], name: "Main"),
        ]
        let imported = try read(file)
        let alpha = try #require(imported.clip("Alpha.mov")?.clip)
        #expect(alpha.timelineStart == frames(25))
        #expect(alpha.sourceRange.start == frames(30))
    }

    // MARK: - Damaged files

    @Test func stopsAtCompositionsAndChainsThatLoop() throws {
        let loopID = F.mobID(12)
        var file = F()
        file.mobs = [
            // A master mob and a source mob that refer to each other.
            F.mob(AAFClass.masterMob, id: alphaMaster, name: "Loop", slots: [
                F.timelineSlot(1, F.sourceClip(picture, length: 10, mob: alphaFile)),
            ]),
            F.mob(AAFClass.sourceMob, id: alphaFile, name: "Back", slots: [
                F.timelineSlot(1, F.sourceClip(picture, length: 10, mob: alphaMaster)),
            ]),
            // A composition that uses itself.
            timeline([F.timelineSlot(1, F.sequence(picture, [
                F.sourceClip(picture, length: 10, mob: alphaMaster),
                F.sourceClip(picture, length: 10, mob: loopID),
            ]))], name: "Loop", id: loopID),
        ]
        let imported = try read(file)
        #expect(imported.project.tracks.flatMap(\.clips).count == 1)
    }

    @Test func survivesHugeNumbers() throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, rate: (1, Int32.max), F.sequence(picture, [
                F.sourceClip(picture, length: .max, start: .max, mob: alphaMaster),
                F.filler(picture, length: .max),
                F.transition(picture, length: .max, cutPoint: .min),
                F.sourceClip(picture, length: .max, start: .min, mob: bravoMaster),
            ])),
            F.timelineSlot(2, rate: (0, 0), F.sequence(picture, [F.sourceClip(picture, length: 10, mob: alphaMaster)])),
            F.timelineSlot(3, rate: (-25, 1), F.sequence(sound, [F.sourceClip(sound, length: -10, mob: alphaMaster)])),
        ])]
        _ = try read(file)
    }

    @Test func survivesHugeLengthsInSourceMobs() throws {
        let hugeMaster = F.mob(AAFClass.masterMob, id: alphaMaster, name: "Huge", slots: [
            F.timelineSlot(1, F.sequence(picture, [
                F.filler(picture, length: .max),
                F.sourceClip(picture, length: .max, mob: alphaFile),
                F.transition(picture, length: .max, cutPoint: 0),
                F.transition(picture, length: .max, cutPoint: 0),
                F.transition(picture, length: .max, cutPoint: 0),
            ])),
        ])
        var file = F()
        file.mobs = [hugeMaster, timeline([
            F.timelineSlot(1, F.sequence(picture, [F.sourceClip(picture, length: 10, start: 10, mob: alphaMaster)])),
        ])]
        _ = try read(file)
    }

    @Test func survivesTransitionsLongerThanTheirSequence() throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [
                F.transition(picture, length: .max, cutPoint: 0),
                F.transition(picture, length: .max, cutPoint: 0),
                F.sourceClip(picture, length: 10, mob: alphaMaster),
            ])),
        ])]
        _ = try read(file)
    }

    @Test func refusesCompoundFilesThatArentAAF() {
        var writer = CompoundFileTestWriter()
        writer.root.add(.init(stream: "WordDocument", contents: Data(repeating: 1, count: 100)))
        #expect(throws: InterchangeError.unsupportedFormat) { try AAFImporter.read(writer.data(), baseURL: nil) }
    }

    @Test func survivesDamagedFiles() throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [
                F.sourceClip(picture, length: 50, start: 10, mob: alphaMaster),
                F.transition(picture, length: 10, cutPoint: 5),
                F.sourceClip(picture, length: 40, start: 100, mob: bravoMaster),
            ])),
        ])]
        let data = file.data(sectorSize: 512)
        for length in stride(from: 0, to: data.count, by: 211) {
            _ = try? AAFImporter.read(data.prefix(length), baseURL: nil)
        }
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<300 {
            var damaged = data
            for _ in 0..<8 {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            do {
                _ = try AAFImporter.read(damaged, baseURL: nil)
            } catch {
                #expect(error is InterchangeError)
            }
        }
    }
}

struct AAFRegistrationTests {
    @Test func readsAAFThroughProjectInterchange() throws {
        var file = F()
        file.mobs = standardMedia() + [timeline([
            F.timelineSlot(1, F.sequence(picture, [F.sourceClip(picture, length: 50, mob: alphaMaster)])),
        ])]
        let imported = try ProjectInterchange.read(file.data())
        #expect(imported.report.format == .aaf)
        #expect(imported.clip("Alpha.mov") != nil)
    }

    @Test func offersAAFFilesForImport() throws {
        #expect(ProjectInterchange.importableTypes.contains(.aaf))
        let type = try #require(UTType(filenameExtension: "aaf"))
        #expect(type.conforms(to: .aaf))
    }
}
