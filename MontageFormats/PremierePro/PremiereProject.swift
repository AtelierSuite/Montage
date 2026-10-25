import CoreMedia
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A Premiere Pro project: gzipped XML, with the `.prproj` extension.
    public static let premiereProject = UTType(importedAs: "com.adobe.premiere.prproj", conformingTo: .data)
}

/// What's common to reading Premiere Pro projects.
enum PremiereProject {
    /// Premiere counts time in ticks, this many to the second.
    static let ticksPerSecond: Int64 = 254_016_000_000

    /// The project versions (the `Version` of the file's `Project` object)
    /// the importer has read real projects of. Newer ones are refused,
    /// pointing to Final Cut Pro XML instead, until projects saved by them
    /// have been tried. Among those read: 18 was written by Premiere Pro 2.0
    /// (2006), 19 by CS3, 22 by CC 2014, 23 by CC 2015, 37 by 13.1, 38 by
    /// 14.0, 42 by 24.4, 43 by 25.1 and 25.2, and 45 by 26.3. The structure
    /// the importer reads hasn't changed across them.
    static let supportedVersions = 18...45

    /// The kinds of file a Premiere project is offered as: Montage's own
    /// declaration, and Premiere's, where Premiere is installed and has
    /// declared `.prproj` under a type of its own.
    static var types: [UTType] {
        let declared = UTType(filenameExtension: "prproj", conformingTo: .data)
        if let declared, declared != .premiereProject, declared.isDeclared { return [.premiereProject, declared] }
        return [.premiereProject]
    }

    /// Ticks as a time, exactly where the value allows.
    static func time(_ ticks: Int64) -> CMTime {
        InterchangeTime.time(ticks, over: ticksPerSecond)
    }

    /// The length of a frame, from ticks per frame. A sequence made to
    /// match a phone's variable-rate clip can be a hair off a standard rate,
    /// such as 30.005 fps; within 0.03% of one, which no two standard rates
    /// are, it's taken as that rate.
    static func frameDuration(ticksPerFrame: Int64) -> CMTime {
        let exact = time(ticksPerFrame)
        let rate = Double(ticksPerSecond) / Double(ticksPerFrame)
        let standard: [(frames: Int64, seconds: Int64)] = [
            (24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1), (48, 1), (50, 1), (60000, 1001), (60, 1),
            (100, 1), (120000, 1001), (120, 1),
        ]
        for candidate in standard where abs(rate / (Double(candidate.frames) / Double(candidate.seconds)) - 1) < 0.0003 {
            return InterchangeTime.time(candidate.seconds, over: candidate.frames)
        }
        return exact
    }

    /// A count of ticks as written, nil if it isn't one.
    static func ticks(_ text: String?) -> Int64? {
        text.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// A number as Premiere writes one, which may end in a bare point, as
    /// "100." does.
    static func number(_ text: some StringProtocol) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(".") { text.removeLast() }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }
}

/// Why a Premiere Pro project couldn't be read.
public enum PremiereProjectError: LocalizedError, Equatable {
    /// Saved by a version of Premiere the importer wasn't written against,
    /// or with no version to tell.
    case unsupportedVersion
    /// The file's compressed data is damaged or cut short.
    case damaged

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            String(localized: "PremiereProject.Error.UnsupportedVersion", bundle: #bundle)
        case .damaged:
            String(localized: "PremiereProject.Error.Damaged", bundle: #bundle)
        }
    }

    public var recoverySuggestion: String? {
        String(localized: "PremiereProject.Error.UseFinalCutXML", bundle: #bundle)
    }
}
