import CoreMedia
import Foundation

/// Everything an import couldn't bring across exactly, so nothing is
/// dropped without the user being told: effects kept turned off, media that
/// wasn't found, and parts of the timeline Montage has no place for yet.
public struct ImportReport: Equatable, Sendable {
    /// One thing that didn't come across as it was.
    public struct Item: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public var issue: Issue
        /// The clip it was on, by the name the other app gave it.
        public var clipName: String?
        /// Where on the timeline, if it has a place there.
        public var time: CMTime?

        public init(_ issue: Issue, clipName: String? = nil, time: CMTime? = nil) {
            self.issue = issue
            self.clipName = clipName
            self.time = time
        }

        public static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.issue == rhs.issue && lhs.clipName == rhs.clipName && lhs.time == rhs.time
        }
    }

    public enum Category: String, Sendable, CaseIterable {
        /// Effects kept on their clips, turned off.
        case unsupportedEffect
        /// Media whose file wasn't found, to be relinked.
        case missingMedia
        /// Parts of the timeline left out, with nowhere in the project to go.
        case notImported
        /// Parts brought in, but not exactly as they were.
        case changed
    }

    public enum Issue: Equatable, Sendable {
        /// Kept on its clip, turned off.
        case unsupportedEffect(name: String)
        /// The file the media came from, by name or path.
        case missingMedia(file: String)
        /// A title with no words to bring in.
        case title
        /// A title brought in as plain text, without the rest of the look
        /// its template, by name, gives it.
        case titleTemplate(name: String)
        /// A generated picture, such as a solid color or a placeholder.
        case generator(name: String)
        case marker(name: String)
        case caption
        /// A clip turned off in the other app.
        case disabledClip
        /// A clip with its speed changed, brought in at normal speed.
        case speedChange
        /// The picks of an audition other than the one in use.
        case auditionAlternatives(count: Int)
        /// Only one of the file's timelines is imported.
        case otherTimelines(count: Int)
        /// A clip setting with no counterpart, by the setting's name.
        case setting(name: String)
        /// A transition, cut in the middle instead.
        case transition(name: String)
        /// A clip that overlapped another on its track, moved to a track
        /// of its own.
        case movedToNewTrack
        /// A picture scaled differently across and down, scaled evenly.
        case uneven(name: String)
        /// A compound or multicam clip's own settings, where its clips have
        /// settings of their own that they keep instead.
        case nestedSettings

        public var category: Category {
            switch self {
            case .unsupportedEffect: .unsupportedEffect
            case .missingMedia: .missingMedia
            case .transition, .movedToNewTrack, .uneven, .nestedSettings, .speedChange, .titleTemplate: .changed
            default: .notImported
            }
        }

        /// What happened, in a sentence.
        public var message: String {
            switch self {
            case .unsupportedEffect(let name):
                String(format: String(localized: "Interchange.Issue.UnsupportedEffect", bundle: #bundle), name)
            case .missingMedia(let file):
                String(format: String(localized: "Interchange.Issue.MissingMedia", bundle: #bundle), file)
            case .title:
                String(localized: "Interchange.Issue.Title", bundle: #bundle)
            case .titleTemplate(let name):
                String(format: String(localized: "Interchange.Issue.TitleTemplate", bundle: #bundle), name)
            case .generator(let name):
                String(format: String(localized: "Interchange.Issue.Generator", bundle: #bundle), name)
            case .marker(let name):
                name.isEmpty ? String(localized: "Interchange.Issue.Marker", bundle: #bundle)
                    : String(format: String(localized: "Interchange.Issue.MarkerNamed", bundle: #bundle), name)
            case .caption:
                String(localized: "Interchange.Issue.Caption", bundle: #bundle)
            case .disabledClip:
                String(localized: "Interchange.Issue.DisabledClip", bundle: #bundle)
            case .speedChange:
                String(localized: "Interchange.Issue.SpeedChange", bundle: #bundle)
            case .auditionAlternatives(let count):
                String(format: String(localized: "Interchange.Issue.AuditionAlternatives", bundle: #bundle), count)
            case .otherTimelines(let count):
                String(format: String(localized: "Interchange.Issue.OtherTimelines", bundle: #bundle), count)
            case .setting(let name):
                String(format: String(localized: "Interchange.Issue.Setting", bundle: #bundle), name)
            case .transition(let name):
                String(format: String(localized: "Interchange.Issue.Transition", bundle: #bundle), name)
            case .movedToNewTrack:
                String(localized: "Interchange.Issue.MovedToNewTrack", bundle: #bundle)
            case .uneven(let name):
                String(format: String(localized: "Interchange.Issue.Uneven", bundle: #bundle), name)
            case .nestedSettings:
                String(localized: "Interchange.Issue.NestedSettings", bundle: #bundle)
            }
        }
    }

    /// The format the project was read from.
    public var format: InterchangeFormat
    public var items: [Item]

    public init(format: InterchangeFormat, items: [Item] = []) {
        self.format = format
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }

    public func items(in category: Category) -> [Item] {
        items.filter { $0.issue.category == category }
    }

    mutating func add(_ issue: Issue, clipName: String? = nil, time: CMTime? = nil) {
        items.append(Item(issue, clipName: clipName, time: time))
    }
}

/// The interchange formats Montage reads.
public enum InterchangeFormat: String, Sendable {
    /// Final Cut Pro X's FCPXML, also written by LumaFusion and others.
    case fcpxml
    /// Final Cut Pro 7's XML, also written by Premiere Pro and Resolve.
    case xmeml
    /// LumaFusion's own project file, inside its project packages.
    case lumaFusion

    /// The format's name, for the report.
    public var displayName: String {
        switch self {
        case .fcpxml: String(localized: "Interchange.Format.FCPXML", bundle: #bundle)
        case .xmeml: String(localized: "Interchange.Format.XMEML", bundle: #bundle)
        case .lumaFusion: String(localized: "Interchange.Format.LumaFusion", bundle: #bundle)
        }
    }
}
