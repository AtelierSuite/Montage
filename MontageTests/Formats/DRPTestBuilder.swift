import Foundation
@testable import MontageFormats

/// Builds `.drp` archives at test time, laid out as the open-source readers
/// of Resolve's exports describe them: `project.xml`, the media pool's bins
/// and a sequence container per timeline. No real Resolve export is used.
struct DRPTestBuilder {
    var appVersion: String? = "19.1.4.0011"
    var projectVersion: String? = "14"
    /// Extra entries, by path, or replacements for the usual ones.
    var overrides: [String: String] = [:]
    var leaveOut: Set<String> = []

    static let fps = 24.0

    private func header() -> String {
        var header = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        if let appVersion, let projectVersion {
            header += #"<!--DbAppVer="\#(appVersion)" DbPrjVer="\#(projectVersion)"-->"# + "\n"
        }
        return header
    }

    private func hex(_ data: Data) -> String { ResolveBlobWriter.hex(data) }

    // MARK: - Pieces

    private func sequence(id: String, start: Double) -> String {
        """
        <Sm2Sequence DbId="\(id)"><FieldsBlob/><UniqueSequenceId>\(id)</UniqueSequenceId>\
        <MediaExtents>\(hex(ResolveBlobWriter.extents(start: start, duration: 10)))</MediaExtents>\
        <FrameRate>\(hex(ResolveBlobWriter.frameRate(Self.fps)))</FrameRate>\
        <Resolution>\(hex(ResolveBlobWriter.resolution(width: 1920, height: 1080)))</Resolution></Sm2Sequence>
        """
    }

    private func timelineClip(id: String, timeline: String, sequence sequenceID: String, name: String) -> String {
        """
        <Element><Sm2MpTimelineClip DbId="\(id)"><Name>\(name)</Name><MpFolder>bin-master</MpFolder>\
        <TimelineSharedHandle><Sm2Timeline DbId="\(timeline)"><Name>\(name)</Name>\
        <Sequence>\(sequence(id: sequenceID, start: 3600))</Sequence></Sm2Timeline></TimelineSharedHandle>\
        </Sm2MpTimelineClip></Element>
        """
    }

    private func videoInfo(folder: String, file: String, frames: Int32, width: Int, height: Int) -> String {
        let time = ResolveBlobWriter.keyedDictionary([
            ("NumFrames", .int32(frames)), ("StartFrame", .int32(0)), ("FrameRate", .bytes(ResolveBlobWriter.frameRate(Self.fps))),
        ])
        let geometry = ResolveBlobWriter.keyedDictionary([("Resolution", .bytes(ResolveBlobWriter.resolution(width: width, height: height)))])
        return """
            <BtVideoInfo><Clip>\(hex(ResolveBlobWriter.clip(folder: folder, name: file)))</Clip>\
            <Time>\(hex(time))</Time><Geometry>\(hex(geometry))</Geometry></BtVideoInfo>
            """
    }

    private func audioInfo(folder: String? = nil, file: String? = nil) -> String {
        let clip = folder.map { "<Clip>\(hex(ResolveBlobWriter.clip(folder: $0, name: file ?? "")))</Clip>" } ?? "<Clip/>"
        return "<BtAudioInfo>\(clip)</BtAudioInfo>"
    }

    private var masterBin: String {
        header() + """
            <Sm2MpFolder DbId="bin-master"><Name>Master</Name><MpFolder/><MediaVec>
            <Element><Sm2MpVideoClip DbId="media-a001"><Name>A001.mov</Name><MpFolder>bin-master</MpFolder>\
            <Video>\(videoInfo(folder: "/Volumes/Media", file: "A001.mov", frames: 480, width: 3840, height: 2160))</Video>\
            <EmbeddedAudioVec><Element>\(audioInfo())</Element></EmbeddedAudioVec></Sm2MpVideoClip></Element>
            <Element><Sm2MpStillClip DbId="media-logo"><Name>Logo.png</Name><MpFolder>bin-master</MpFolder></Sm2MpStillClip></Element>
            <Element><Sm2MpCompoundClip DbId="media-compound"><Name>Compound Clip 1</Name><MpFolder>bin-master</MpFolder>\
            <Sequence>\(sequence(id: "seq-compound", start: 0))</Sequence></Sm2MpCompoundClip></Element>
            \(timelineClip(id: "media-edit", timeline: "timeline-edit", sequence: "seq-edit", name: "Edit"))
            \(timelineClip(id: "media-alt", timeline: "timeline-alt", sequence: "seq-alt", name: "Alternate"))
            </MediaVec></Sm2MpFolder>
            """
    }

    private var footageBin: String {
        header() + """
            <Sm2MpFolder DbId="bin-footage"><Name>Footage</Name><MpFolder>bin-master</MpFolder><MediaVec>
            <Element><Sm2MpAudioClip DbId="media-music"><Name>Music.wav</Name><MpFolder>bin-footage</MpFolder>\
            \(audioInfo(folder: "/Volumes/Media/Audio", file: "Music.wav"))</Sm2MpAudioClip></Element>
            </MediaVec></Sm2MpFolder>
            """
    }

    static func item(
        _ tag: String, id: String, start: Int, duration: Int, inPoint: String? = nil, media: String? = nil,
        name: String = "", extra: String = ""
    ) -> String {
        let inElement = inPoint.map { $0.isEmpty ? "<In/>" : "<In>\($0)</In>" } ?? ""
        let mediaElement = media.map { "<MediaRef>\($0)</MediaRef>" } ?? ""
        return """
            <Element><\(tag) DbId="\(id)"><FieldsBlob/><Name>\(name)</Name><Start>\(start)</Start>\
            <Duration>\(duration)</Duration>\(inElement)\(mediaElement)\(extra)</\(tag)></Element>
            """
    }

    static func track(_ type: Int, sequence: String, items: [String]) -> String {
        """
        <Element><Sm2TiTrack DbId="track-\(UUID().uuidString)"><FieldsBlob/><Type>\(type)</Type><SubType>0</SubType>\
        <Flags>0</Flags><Sequence>\(sequence)</Sequence><Items>\(items.joined())</Items></Sm2TiTrack></Element>
        """
    }

    static func container(id: String, video: [String], audio: [String] = [], subtitle: [String] = []) -> String {
        #"<?xml version="1.0" encoding="UTF-8"?>"# + """
            <Sm2SequenceContainer DbId="\(id)"><FieldsBlob/><VideoTrackVec>\(video.joined())</VideoTrackVec>\
            <AudioTrackVec>\(audio.joined())</AudioTrackVec><SubtitleTrackVec>\(subtitle.joined())</SubtitleTrackVec>\
            </Sm2SequenceContainer>
            """
    }

    private var editContainer: String {
        let halfFrame = hex(withUnsafeBytes(of: (0.5).bitPattern.littleEndian) { Data($0) })
        let retimed = hex(ResolveBlobWriter.keyedDictionary([("DbType", .string("Sm2TimeMap")), ("XMax", .double(1))]))
        let identity = hex(Data([0x02]) + withUnsafeBytes(of: (20.0).bitPattern.bigEndian) { Data($0) })
        let graded = "<pLmVerTable><ListMgt::LmVersionTable><Element><ListMgt::LmVersion DbId=\"v1\"><HasCorrection>true</HasCorrection>"
            + "<Body>8000</Body></ListMgt::LmVersion></Element></ListMgt::LmVersionTable></pLmVerTable>"
        return Self.container(id: "container-edit", video: [
            Self.track(0, sequence: "seq-edit", items: [
                Self.item("Sm2TiVideoClip", id: "item-a001", start: 86400, duration: 48, inPoint: "24", media: "media-a001",
                          name: "A001.mov", extra: "<MediaFilePath>/Old/A001.mov</MediaFilePath><MediaTimemapBA>\(identity)</MediaTimemapBA>\(graded)"),
                Self.item("Sm2TiTransition", id: "item-dissolve", start: 86436, duration: 24,
                          extra: "<PrettyType>Cross Dissolve</PrettyType><AlignmentType>2</AlignmentType><Position>0</Position>"),
                Self.item("Sm2TiVideoClip", id: "item-compound", start: 86448, duration: 24, inPoint: "0", media: "media-compound",
                          name: "Compound Clip 1"),
                Self.item("Sm2TiVideoClip", id: "item-retimed", start: 86472, duration: 24, inPoint: "100|\(halfFrame)",
                          media: "media-a001", name: "A001.mov", extra: "<MediaTimemapBA>\(retimed)</MediaTimemapBA>"),
            ]),
            Self.track(0, sequence: "seq-edit", items: [
                // Real exports give a still an in point at its timeline
                // start, and the long time map a retimed clip has.
                Self.item("Sm2TiVideoClip", id: "item-logo", start: 86412, duration: 24, inPoint: "86412", media: "media-logo",
                          name: "Logo.png", extra: "<MediaFilePath>/Users/editor/Logo.png</MediaFilePath><MediaTimemapBA>\(retimed)</MediaTimemapBA>"),
                Self.item("Sm2TiGenerator", id: "item-solid", start: 86448, duration: 12, extra: "<PrettyType>Solid Color</PrettyType>"),
                Self.item("Sm2TiVideoClip", id: "item-title", start: 86472, duration: 24, name: "Text+",
                          extra: "<PrettyType>Fusion Title</PrettyType>"),
            ]),
        ], audio: [
            Self.track(1, sequence: "seq-edit", items: [
                Self.item("Sm2TiAudioClip", id: "item-a001-sound", start: 86400, duration: 48, inPoint: "", media: "media-a001",
                          name: "A001.mov"),
            ]),
            Self.track(1, sequence: "seq-edit", items: [
                Self.item("Sm2TiAudioClip", id: "item-music", start: 86400, duration: 96, inPoint: "", media: "media-music",
                          name: "Music.wav", extra: "<EffectFiltersBA>0011</EffectFiltersBA>"),
            ]),
        ], subtitle: [
            Self.track(2, sequence: "seq-edit", items: [Self.item("Sm2TiSubtitle", id: "item-sub", start: 86400, duration: 24)]),
        ])
    }

    private var compoundContainer: String {
        Self.container(id: "container-compound", video: [
            Self.track(0, sequence: "seq-compound", items: [
                Self.item("Sm2TiVideoClip", id: "item-inner", start: 0, duration: 48, inPoint: "10", media: "media-a001", name: "A001.mov"),
            ]),
        ])
    }

    private var alternateContainer: String {
        Self.container(id: "container-alt", video: [
            Self.track(0, sequence: "seq-alt", items: [
                Self.item("Sm2TiVideoClip", id: "item-alt", start: 86400, duration: 24, inPoint: "0", media: "media-a001"),
            ]),
        ])
    }

    private var project: String {
        let timelineMarkers = ResolveBlobWriter.markers([(frame: 24, name: "Cue", note: "Music in"), (frame: 60, name: "", note: "Note only")])
        let clipMarkers = ResolveBlobWriter.markers([(frame: 5, name: "Focus", note: "")])
        return header() + """
            <SM_Project DbId="project-1"><FieldsBlob>0000</FieldsBlob><ProjectName>Synthetic</ProjectName>\
            <TimelineHandleVec><Element>timeline-edit</Element><Element>timeline-alt</Element></TimelineHandleVec>\
            <CurrentTimelineIndex>0</CurrentTimelineIndex>\
            <LocableBlobSet><Element><Sm2SequenceLockableBlob DbId="blob-1"><BlobOwner>seq-edit</BlobOwner>\
            <FieldsBlob>\(hex(timelineMarkers))</FieldsBlob></Sm2SequenceLockableBlob></Element>\
            <Element><Sm2TiItemLockableBlob DbId="blob-2"><BlobOwner>item-a001</BlobOwner>\
            <FieldsBlob>\(hex(clipMarkers))</FieldsBlob></Sm2TiItemLockableBlob></Element>\
            <Element><Sm2SequenceLockableBlob DbId="blob-3"><BlobOwner>seq-alt</BlobOwner><FieldsBlob/></Sm2SequenceLockableBlob></Element>\
            <Element><Sm2MpItemLockableBlob DbId="blob-4"><BlobOwner>item-alt</BlobOwner>\
            <FieldsBlob>\(hex(ResolveBlobWriter.keyedDictionary([("Other", .int32(1))])))</FieldsBlob></Sm2MpItemLockableBlob></Element>\
            </LocableBlobSet></SM_Project>
            """
    }

    // MARK: - Archive

    var entries: [String: String] {
        var entries = [
            "project.xml": project,
            "Gallery.xml": header() + "<Gallery::GyGallery DbId=\"gallery\"/>",
            "MediaPool/Master/MpFolder.xml": masterBin,
            "MediaPool/Master/Footage/MpFolder.xml": footageBin,
            "SeqContainer/0b6f0e2c-edit.xml": editContainer,
            "SeqContainer/5d1c2a90-compound.xml": compoundContainer,
            "SeqContainer/9e7d3b41-alt.xml": alternateContainer,
        ]
        entries.merge(overrides) { $1 }
        for name in leaveOut { entries[name] = nil }
        return entries
    }

    func archive() -> Data {
        var writer = ZIPTestWriter()
        for (name, contents) in entries.sorted(by: { $0.key < $1.key }) {
            writer.add(name, contents)
        }
        return writer.archive()
    }
}
