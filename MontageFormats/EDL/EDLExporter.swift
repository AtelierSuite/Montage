import CoreMedia
import Foundation
import MontageEngine

/// Writes a project as a CMX 3600 edit decision list.
///
/// An EDL has one video track and, strictly, two audio channels, so only
/// the first video track goes out, with the sound of its clips that play
/// it on the first channel ("B" events), and the first audio track on the
/// second. With no sound on the video track, the first two audio tracks
/// take both channels. Everything else is left out, as are text and
/// shapes, which have no file to point to: `clipsLeftOut` lists them.
///
/// Each event's file is named in `* FROM CLIP NAME:` and `* SOURCE FILE:`
/// comments, as Premiere Pro and Resolve write them, under the reel "AX".
/// Record timecode starts at 01:00:00:00, and source timecode is the
/// media's own: the time into it, after the timecode it starts at, if it
/// has one. Markers go out as `* LOC:` comments.
struct EDLExporter {
    let project: Project
    let name: String
    let mediaResolver: MediaResolver

    private var rate: EDLRate { EDLRate(frameDuration: project.settings.frameDuration) }
    private var isDropFrame: Bool { rate.canDropFrames }

    /// An event line and the comments under it.
    private struct Event {
        var recordIn: Int
        var recordOut: Int
        var sourceIn: Int
        var track: String
        var isVideo: Bool
        var clipName: String
        var sourceFile: String
        var locators: [String] = []
    }

    /// Where each track goes: the video track, with whether its sound goes
    /// out with it, and each audio track's channel.
    private struct Layout {
        var video: Track?
        var videoHasSound: Bool
        var audio: [(track: Track, channel: Int)]
    }

    private static func layout(of project: Project) -> Layout {
        let video = project.tracks.first { $0.kind == .video }
        let videoHasSound = video?.clips.contains { clip in
            guard case .media(let id) = clip.content, let item = project.mediaItem(id: id) else { return false }
            return item.kind != .image && item.metadata.hasAudio && !clip.isAudioDetached
        } ?? false
        let channels = videoHasSound ? [2] : [1, 2]
        let audio = zip(project.tracks.filter { $0.kind == .audio }, channels).map { (track: $0, channel: $1) }
        return Layout(video: video, videoHasSound: videoHasSound, audio: audio)
    }

    /// The clips an EDL can't carry: those on tracks past what it holds,
    /// and text and shapes.
    static func clipsLeftOut(in project: Project) -> [Clip.ID] {
        let layout = layout(of: project)
        let kept = Set(([layout.video].compactMap { $0 } + layout.audio.map(\.track)).map(\.id))
        return project.tracks.flatMap { track in
            track.clips.filter { !kept.contains(track.id) || $0.mediaID == nil }.map(\.id)
        }
    }

    func document() -> Data {
        let layout = Self.layout(of: project)
        let hour = EDLTimecode(hours: 1, minutes: 0, seconds: 0, frames: 0).frameCount(at: rate, dropFrame: isDropFrame)
        var events: [Event] = []
        if let video = layout.video {
            for clip in video.clips {
                guard let item = project.mediaItem(id: clip.mediaID) else { continue }
                let playsSound = layout.videoHasSound && item.kind != .image && item.metadata.hasAudio && !clip.isAudioDetached
                if let event = event(for: clip, item: item, track: playsSound ? "B" : "V", isVideo: true, hour: hour) {
                    events.append(event)
                }
            }
        }
        for (track, channel) in layout.audio {
            for clip in track.clips {
                guard let item = project.mediaItem(id: clip.mediaID), item.kind != .image,
                      let event = event(for: clip, item: item, track: channel == 1 ? "A" : "A\(channel)", isVideo: false, hour: hour)
                else { continue }
                events.append(event)
            }
        }
        events.sort { ($0.recordIn, $0.isVideo ? 0 : 1) < ($1.recordIn, $1.isVideo ? 0 : 1) }
        placeMarkers(in: &events, hour: hour)

        var lines = ["TITLE: \(Self.oneLine(name))", "FCM: \(isDropFrame ? "DROP FRAME" : "NON-DROP FRAME")", ""]
        let width = max(3, String(events.count).count)
        for (index, event) in events.enumerated() {
            let number = String(index + 1)
            let fields = [
                String(repeating: "0", count: width - number.count) + number, "",
                Self.padded("AX", 8), Self.padded(event.track, 5), Self.padded("C", 4), "   ",
                timecode(event.sourceIn), timecode(event.sourceIn + event.recordOut - event.recordIn),
                timecode(event.recordIn), timecode(event.recordOut),
            ]
            lines.append(fields.joined(separator: " "))
            lines.append("* FROM CLIP NAME: \(event.clipName)")
            lines.append("* SOURCE FILE: \(event.sourceFile)")
            lines += event.locators
            lines.append("")
        }
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func event(for clip: Clip, item: MediaItem, track: String, isVideo: Bool, hour: Int) -> Event? {
        let recordIn = rate.frames(clip.timelineStart)
        let recordOut = rate.frames(clip.timelineRange.end)
        guard recordOut > recordIn else { return nil }
        let sourceIn = clip.content.hasSourceTime ? max(0, rate.frames(clip.sourceRange.start)) + sourceStart(of: item) : 0
        return Event(
            recordIn: hour + recordIn, recordOut: hour + recordOut, sourceIn: sourceIn, track: track, isVideo: isVideo,
            clipName: Self.oneLine(item.name), sourceFile: Self.oneLine(sourceFile(for: item))
        )
    }

    /// The timecode the media starts at, in frames, as its source points
    /// are counted from it.
    private func sourceStart(of item: MediaItem) -> Int {
        // Clips still in timecode, of a file not yet found, are counted from it already.
        guard item.sourceTimecode == nil, let timecode = item.metadata.timecode else { return 0 }
        return timecode.frameCount(at: rate, dropFrame: isDropFrame)
    }

    /// Where the media's file is, for the editor reading the list to find
    /// it: its path, or its name where it has none.
    private func sourceFile(for item: MediaItem) -> String {
        guard let url = mediaResolver.url(for: item) else { return item.name }
        return url.isFileURL ? url.path : url.absoluteString
    }

    /// Each marker, under the event it falls in, the video's first; one
    /// before every event goes under the first.
    private func placeMarkers(in events: inout [Event], hour: Int) {
        guard !events.isEmpty else { return }
        for marker in project.markers {
            let frame = hour + rate.frames(marker.time)
            let index = events.firstIndex { $0.isVideo && $0.recordIn <= frame && frame < $0.recordOut }
                ?? events.firstIndex { $0.recordIn <= frame && frame < $0.recordOut }
                ?? events.lastIndex { $0.recordIn <= frame }
                ?? 0
            let name = Self.oneLine(marker.name)
            events[index].locators.append("* LOC: \(timecode(frame)) RED     \(name)".trimmingCharacters(in: .whitespaces))
        }
    }

    private func timecode(_ frames: Int) -> String {
        EDLTimecode(frameCount: frames, rate: rate, dropFrame: isDropFrame).string(dropFrame: isDropFrame)
    }

    private static func padded(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
    }

    /// Text on one line, as each of an EDL's has to be.
    private static func oneLine(_ string: String) -> String {
        string.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
