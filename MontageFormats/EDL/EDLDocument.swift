import Foundation

/// A CMX 3600 edit decision list, as the lines say, before any timecode is
/// counted into time: the frame rate it's at isn't in the file.
///
/// Each event is a numbered line: the reel the material comes from, the
/// tracks it goes on, the kind of edit, and the source and record in and
/// out timecodes. A dissolve or wipe is two lines with one number, the
/// outgoing material then the incoming. Notes about an event follow it as
/// comments starting with `*`.
struct EDLDocument {
    struct Event {
        enum Edit: Equatable {
            case cut
            case dissolve
            /// A wipe, by its SMPTE pattern number.
            case wipe(String)
            /// A key: the background, or the foreground keyed over it.
            case key(background: Bool)
        }

        /// The event number, which the lines of a transition share.
        var number: String
        var reel: String
        var hasVideo: Bool
        /// The audio channels it goes on, from 1.
        var audioChannels: [Int]
        var edit: Edit
        /// A transition's length, in frames.
        var transitionFrames: Int
        var sourceIn: EDLTimecode
        var sourceOut: EDLTimecode
        var recordIn: EDLTimecode
        var recordOut: EDLTimecode
        /// Whether the timecodes are drop frame, as the last FCM line said.
        var isDropFrame: Bool
        var clipName: String?
        var sourceFile: String?
        var effectName: String?
        /// A constant speed from an M2 line, in frames a second, negative in
        /// reverse.
        var speed: Double?

        /// Black, or another generated source, rather than a file.
        var isBlack: Bool {
            ["BL", "BLK", "BLACK"].contains(reel.uppercased())
        }

        var isTransition: Bool {
            switch edit {
            case .dissolve, .wipe: true
            case .cut, .key: false
            }
        }
    }

    struct Locator {
        var time: EDLTimecode
        var isDropFrame: Bool
        var name: String
    }

    var title: String?
    var events: [Event] = []
    var locators: [Locator] = []
    /// Whether any event is in drop frame.
    var hasDropFrame = false
    /// Split edits, where the sound is cut apart from the picture, by the
    /// event they're on.
    var splitEdits: [String] = []

    /// Whether text reads as an EDL: a TITLE or FCM line, or an event line,
    /// before anything else.
    static func looksLikeEDL(_ text: String) -> Bool {
        for line in text.split(whereSeparator: \.isNewline).prefix(50) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let upper = trimmed.uppercased()
            if upper.hasPrefix("TITLE:") || upper.hasPrefix("FCM:") || eventLine(trimmed, isDropFrame: false) != nil {
                return true
            }
            if trimmed.hasPrefix("<") { return false }
        }
        return false
    }

    init(text: String) {
        var isDropFrame = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("TITLE:") {
                let title = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if self.title == nil, !title.isEmpty { self.title = title }
            } else if upper.hasPrefix("FCM:") {
                isDropFrame = upper.contains("DROP") && !upper.contains("NON")
                hasDropFrame = hasDropFrame || isDropFrame
            } else if line.hasPrefix("*") {
                readComment(String(line.dropFirst()).trimmingCharacters(in: .whitespaces), isDropFrame: isDropFrame)
            } else if upper.hasPrefix("M2 ") || upper.hasPrefix("M2\t") {
                readSpeed(line)
            } else if upper.hasPrefix("AUD ") || upper.hasPrefix("AUD\t") {
                // Avid's channels past the second: "AUD 3 4" after an event.
                let channels = line.split(whereSeparator: \.isWhitespace).dropFirst().compactMap { Int($0) }
                if !events.isEmpty { events[events.count - 1].audioChannels += channels }
            } else if upper.hasPrefix("SPLIT:") {
                if let number = events.last?.number { splitEdits.append(number) }
            } else if let event = Self.eventLine(line, isDropFrame: isDropFrame) {
                events.append(event)
            }
        }
    }

    /// An event line: "001  REEL  V  C  00:00:01:00 00:00:02:00 01:00:00:00 01:00:01:00",
    /// with a transition's length after its edit ("D 030", "W001 015").
    private static func eventLine(_ line: String, isDropFrame: Bool) -> Event? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 8, tokens[0].allSatisfy(\.isNumber) else { return nil }
        let times = tokens.suffix(4).compactMap { EDLTimecode($0) }
        guard times.count == 4 else { return nil }
        let middle = Array(tokens[1 ..< tokens.count - 4])
        guard middle.count >= 3, let tracks = Self.tracks(middle[1]) else { return nil }
        var rest = Array(middle.dropFirst(2))
        let type = rest.removeFirst().uppercased()
        let edit: Event.Edit
        switch type {
        case "C": edit = .cut
        case "D": edit = .dissolve
        case _ where type.hasPrefix("W"): edit = .wipe(String(type.dropFirst()))
        case _ where type.hasPrefix("K"):
            // "K B" is the background; "K", "KO" or "K O" the foreground.
            let isBackground = rest.first?.uppercased() == "B" || type == "KB"
            if rest.first.map({ ["B", "O"].contains($0.uppercased()) }) ?? false { rest.removeFirst() }
            edit = .key(background: isBackground)
        default: return nil
        }
        let transitionFrames = rest.last.flatMap { Int($0) } ?? 0
        return Event(
            number: tokens[0], reel: middle[0], hasVideo: tracks.video, audioChannels: tracks.audio, edit: edit,
            transitionFrames: edit == .cut ? 0 : max(0, transitionFrames), sourceIn: times[0], sourceOut: times[1],
            recordIn: times[2], recordOut: times[3], isDropFrame: isDropFrame
        )
    }

    /// The tracks an event goes on: "V", "A", "A2", "AA" (both audio
    /// channels), "B" (picture and the first channel), or a combination
    /// such as "AA/V". "NONE" is none.
    private static func tracks(_ field: String) -> (video: Bool, audio: [Int])? {
        var video = false
        var audio: [Int] = []
        for part in field.uppercased().split(separator: "/") {
            switch part {
            case "V": video = true
            case "B": video = true; audio.append(1)
            case "A": audio.append(1)
            case "AA": audio += [1, 2]
            case "NONE": break
            case _ where part.hasPrefix("A") && part.count > 1:
                // "A2", or Avid's "A1A2"-style pairs.
                let numbers = part.split(separator: "A").compactMap { Int($0) }
                guard !numbers.isEmpty else { return nil }
                audio += numbers
            default: return nil
            }
        }
        return (video, Array(Set(audio)).sorted())
    }

    /// The lines of the event being read: the last event's number.
    private var currentEventIndices: [Int] {
        guard let number = events.last?.number else { return [] }
        var indices: [Int] = []
        for index in events.indices.reversed() {
            guard events[index].number == number else { break }
            indices.insert(index, at: 0)
        }
        return indices
    }

    private mutating func readComment(_ comment: String, isDropFrame: Bool) {
        let upper = comment.uppercased()
        func value(after prefix: String) -> String? {
            guard upper.hasPrefix(prefix) else { return nil }
            let value = comment.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        let lines = currentEventIndices
        if let name = value(after: "FROM CLIP NAME:") {
            if let index = lines.first { events[index].clipName = name }
        } else if let name = value(after: "TO CLIP NAME:") {
            if let index = lines.last { events[index].clipName = name }
        } else if let path = value(after: "SOURCE FILE:") ?? value(after: "SOURCE FILE NAME:") {
            // A transition's files are given in order, outgoing first.
            if let index = lines.first(where: { !events[$0].isBlack && events[$0].sourceFile == nil }) {
                events[index].sourceFile = path
            }
        } else if let name = value(after: "EFFECT NAME:") {
            if let index = lines.last { events[index].effectName = name }
        } else if let locator = value(after: "LOC:") {
            readLocator(locator, isDropFrame: isDropFrame)
        }
    }

    /// "LOC: 01:00:02:12 RED     Name", the colour optional.
    private mutating func readLocator(_ text: String, isDropFrame: Bool) {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = tokens.first, let time = EDLTimecode(first) else { return }
        tokens.removeFirst()
        let colors: Set = ["RED", "GREEN", "BLUE", "CYAN", "MAGENTA", "YELLOW", "BLACK", "WHITE", "ORANGE", "PINK", "PURPLE"]
        if let color = tokens.first?.uppercased(), colors.contains(color) || color.hasPrefix("RESOLVECOLOR") {
            tokens.removeFirst()
        }
        locators.append(Locator(time: time, isDropFrame: isDropFrame, name: tokens.joined(separator: " ")))
    }

    /// "M2   REEL       050.0                00:00:04:00": the reel's material
    /// plays at 50 frames a second from its source timecode.
    private mutating func readSpeed(_ line: String) {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 4, let speed = Double(tokens[2]) else { return }
        let reel = tokens[1]
        let entry = EDLTimecode(tokens[3])
        let candidates = currentEventIndices.filter { events[$0].reel == reel }
        guard let index = candidates.first(where: { events[$0].sourceIn == entry }) ?? candidates.last else { return }
        events[index].speed = speed
    }
}
