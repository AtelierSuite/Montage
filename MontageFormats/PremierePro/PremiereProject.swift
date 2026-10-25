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
    /// whose structure the importer was written against. Older and newer
    /// projects are refused, pointing to Final Cut Pro XML instead: 37 was
    /// written by Premiere Pro 2020 (14.0), and 44 by Premiere Pro 25.6.
    static let supportedVersions = 37...44

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
