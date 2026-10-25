import MontageEngine
import SwiftUI

/// How the library lays out its media: thumbnails in a grid, or a list
/// with each item's details.
enum LibraryLayout: String, CaseIterable {
    case grid, list
}

/// A media item in the library's list: a small picture of it, its name, its
/// details and how much the timeline uses it.
struct LibraryRow: View {
    let item: MediaItem
    let isSelected: Bool
    /// How many clips on the timeline are made from it.
    let clipCount: Int
    /// Whether its file can't be found.
    let isMissing: Bool
    let detailsCache: LibraryDetailsCache
    @Environment(ProjectEditor.self) private var editor
    @State private var details: MediaFileDetails?

    var body: some View {
        HStack(spacing: 10) {
            LibraryThumbnail(item: item)
                .frame(width: 64, height: 36)
                .clipShape(.rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if let format = LibraryItemText.format(of: item) {
                        Text(format)
                    }
                    if let file = LibraryItemText.file(of: details) {
                        Text(file)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                usage
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
        .contentShape(.rect(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.name))
        .accessibilityValue(Text(LibraryItemText.accessibilityValue(of: item, clipCount: clipCount, isMissing: isMissing)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // Read again for a file that's been relinked.
        .task(id: item.location) { await loadDetails() }
    }

    /// Whether the file's missing, or else how many clips are made from it.
    @ViewBuilder
    private var usage: some View {
        let text = Text(LibraryItemText.usage(clipCount: clipCount, isMissing: isMissing))
        if isMissing {
            Label { text } icon: { Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor) }
                .foregroundStyle(.orange)
        } else if clipCount > 0 {
            Label { text } icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(.tint)
        } else {
            text.foregroundStyle(.tertiary)
        }
    }

    private func loadDetails() async {
        if let cached = detailsCache.details(for: item) {
            details = cached
            return
        }
        details = nil
        guard !isMissing, let url = editor.mediaResolver.url(for: item) else { return }
        let read = await detailsCache.load(for: item, at: url)
        guard !Task.isCancelled else { return }
        details = read
    }
}

/// The details read from each media file, kept while the library's open so
/// scrolling back to a row doesn't read its file again.
@MainActor
final class LibraryDetailsCache {
    private var entries: [MediaItem.ID: (location: MediaLocation, details: MediaFileDetails)] = [:]

    /// The item's details, if they've been read from the file it has now.
    func details(for item: MediaItem) -> MediaFileDetails? {
        guard let entry = entries[item.id], entry.location == item.location else { return nil }
        return entry.details
    }

    func load(for item: MediaItem, at url: URL) async -> MediaFileDetails {
        let details = await MediaFileDetails.read(at: url, kind: item.kind)
        entries[item.id] = (item.location, details)
        return details
    }
}

/// What the library says about a media item, in its cells and rows.
enum LibraryItemText {
    /// How long the media runs; nil for a still image.
    static func duration(of item: MediaItem) -> Duration? {
        guard item.kind != .image else { return nil }
        let seconds = item.metadata.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    /// The duration as a clock shows it: 0:12, or 1:02:03.
    static func formattedDuration(of item: MediaItem) -> String? {
        duration(of: item).map { $0.formatted(.time(pattern: $0 >= .seconds(3600) ? .hourMinuteSecond : .minuteSecond)) }
    }

    static func kindName(_ kind: MediaItem.Kind) -> String {
        switch kind {
        case .video: String(localized: "Library.Kind.Video")
        case .audio: String(localized: "Library.Kind.Audio")
        case .image: String(localized: "Library.Kind.Image")
        }
    }

    /// What the media is, from its metadata: its length, picture size and
    /// frame rate, or for audio alone, its channels and sample rate.
    static func format(of item: MediaItem) -> String? {
        let metadata = item.metadata
        var parts = [formattedDuration(of: item), metadata.formattedResolution].compactMap { $0 }
        if item.kind == .video, let rate = metadata.formattedFrameRate {
            parts.append(String(format: String(localized: "Library.Detail.FrameRate"), rate))
        }
        if item.kind == .audio {
            parts.append(contentsOf: [channels(metadata.audioChannelCount), sampleRate(metadata.audioSampleRate)].compactMap { $0 })
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How the file's encoded and how big it is.
    static func file(of details: MediaFileDetails?) -> String? {
        guard let details else { return nil }
        let parts = [details.codecs, details.byteCount.map { $0.formatted(.byteCount(style: .file)) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func channels(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: String(localized: "Library.Detail.Mono")
        case 2: String(localized: "Library.Detail.Stereo")
        default: String(format: String(localized: "Library.Detail.Channels"), count)
        }
    }

    private static func sampleRate(_ rate: Double) -> String? {
        guard rate > 0 else { return nil }
        let kilohertz = (rate / 1000).formatted(.number.precision(.fractionLength(0...1)))
        return String(format: String(localized: "Library.Detail.SampleRate"), kilohertz)
    }

    /// Whether the file's missing, or how many clips are made from it.
    static func usage(clipCount: Int, isMissing: Bool) -> String {
        if isMissing { return String(localized: "Library.Status.Missing") }
        guard clipCount > 0 else { return String(localized: "Library.Status.Unused") }
        return String(format: String(localized: "Library.Usage.Clips"), clipCount)
    }

    static func accessibilityValue(of item: MediaItem, clipCount: Int, isMissing: Bool) -> String {
        var parts = [kindName(item.kind)]
        if let duration = duration(of: item) {
            parts.append(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
        }
        if let resolution = item.metadata.formattedResolution { parts.append(resolution) }
        parts.append(usage(clipCount: clipCount, isMissing: isMissing))
        return parts.joined(separator: ", ")
    }
}
