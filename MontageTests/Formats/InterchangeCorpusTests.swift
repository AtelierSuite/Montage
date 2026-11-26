import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Real project files from other editors and the tools around them, kept
/// outside the repository in `Samples/Interchange/<format>/`. Each is read as
/// a user's would be, and what comes in is checked against
/// `expectations.json` there. Run with `TEST_RUNNER_MONTAGE_RECORD_INTERCHANGE=1`
/// to write what's read now into that file instead, keeping its notes.
@Suite(.enabled(if: Samples.isInterchangeAvailable, "Needs the interchange corpus"))
struct InterchangeCorpusTests {
    struct Summary: Codable, Equatable {
        var error: String?
        var name: String?
        var size: String?
        var frame: String?
        var media: Int?
        var video: [Int]?
        var audio: [Int]?
        var duration: Double?
        var markers: Int?
        var report: [String: Int]?
        var note: String?

        func matches(_ other: Summary) -> Bool {
            var lhs = self, rhs = other
            lhs.note = nil
            rhs.note = nil
            return lhs == rhs
        }
    }

    static let expectationsURL = Samples.interchange.appending(path: "expectations.json")
    static let fileExtensions: Set<String> = ["fcpxml", "fcpxmld", "xml", "otio", "edl", "aaf", "drp", "drt", "prproj"]
    static var isRecording: Bool { ProcessInfo.processInfo.environment["MONTAGE_RECORD_INTERCHANGE"] == "1" }

    /// Every sample's path inside the corpus, as `<format>/<file>`.
    static let samples: [String] = {
        let manager = FileManager.default
        let formats = (try? manager.contentsOfDirectory(atPath: Samples.interchange.path)) ?? []
        return formats.filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }.sorted().flatMap { format in
            let files = (try? manager.contentsOfDirectory(atPath: Samples.interchange.appending(path: format).path)) ?? []
            return files.filter { fileExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted().map { "\(format)/\($0)" }
        }
    }()

    static func expectations() throws -> [String: Summary] {
        guard let data = try? Data(contentsOf: expectationsURL) else { return [:] }
        return try JSONDecoder().decode([String: Summary].self, from: data)
    }

    static func summary(of sample: String) -> (summary: Summary, problems: [String]) {
        let imported: ImportedProject
        do {
            imported = try ProjectInterchange.read(contentsOf: Samples.interchange.appending(path: sample))
        } catch {
            return (Summary(error: String(describing: error)), [])
        }
        let project = imported.project
        var problems: [String] = []
        for (index, track) in project.tracks.enumerated() {
            var end = CMTime.zero
            for clip in track.clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                let label = "track \(index) clip at \(clip.timelineStart.seconds)"
                if !(clip.duration > .zero) { problems.append("\(label) has no duration") }
                if clip.timelineStart < .zero { problems.append("\(label) starts before the timeline") }
                if !clip.sourceRange.start.isNumeric || !clip.duration.isNumeric { problems.append("\(label) has a time that isn't a number") }
                if clip.timelineStart < end { problems.append("\(label) overlaps the clip before it") }
                end = max(end, clip.timelineRange.end)
                if let id = clip.mediaID, project.mediaItem(id: id) == nil { problems.append("\(label) has no media item") }
            }
        }
        let duration = project.duration
        if !duration.isNumeric { problems.append("the project's duration isn't a number") }
        let counts = Dictionary(grouping: imported.report.items, by: { $0.issue.category.rawValue }).mapValues(\.count)
        let frame = project.settings.frameDuration
        let summary = Summary(
            name: imported.name,
            size: "\(Int(project.settings.renderSize.width))x\(Int(project.settings.renderSize.height))",
            frame: "\(frame.value)/\(frame.timescale)",
            media: project.media.count,
            video: project.tracks.filter { $0.kind == .video }.map(\.clips.count),
            audio: project.tracks.filter { $0.kind == .audio }.map(\.clips.count),
            duration: duration.isNumeric ? (duration.seconds * 1000).rounded() / 1000 : nil,
            markers: project.markers.count,
            report: counts.isEmpty ? nil : counts
        )
        return (summary, problems)
    }

    @Test(arguments: samples)
    func importsAsExpected(_ sample: String) throws {
        let (summary, problems) = Self.summary(of: sample)
        #expect(problems.isEmpty, "\(sample): \(problems.joined(separator: "; "))")
        guard !Self.isRecording else { return }
        let expected = try #require(try Self.expectations()[sample], "\(sample) has no expectations; record them")
        #expect(summary.matches(expected), "\(sample)\n  read:     \(summary)\n  expected: \(expected)")
    }

    @Test(.enabled(if: InterchangeCorpusTests.isRecording))
    func recordsExpectations() throws {
        var expectations = try Self.expectations()
        for sample in Self.samples {
            var summary = Self.summary(of: sample).summary
            summary.note = expectations[sample]?.note
            expectations[sample] = summary
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(expectations.filter { Self.samples.contains($0.key) }).write(to: Self.expectationsURL)
    }
}
