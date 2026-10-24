import CoreMedia
import MontageEngine
import SwiftUI

/// The ruler and the lanes, with every clip, drawn in one canvas rather than
/// a view for each, so long projects stay smooth to zoom and scroll. Only a
/// window of the timeline about the part in sight is drawn: the canvas sits
/// at `origin` along the lanes, and is redrawn as they scroll.
///
/// The playhead is drawn over it separately, since it moves every frame
/// while playing and nothing here needs to.
struct TimelineCanvas: View {
    let layout: TimelineLayout
    /// Where the canvas's leading edge is, along the lanes.
    let origin: Double
    let media: [MediaItem.ID: MediaItem]
    let frames: FrameTime
    var selected: Set<Clip.ID> = []
    var hovered: Clip.ID?
    var markers: [Marker] = []
    var markedIn: CMTime?
    var markedOut: CMTime?
    /// Where a drag has snapped to, to show the line it's snapped to.
    var snapTime: CMTime?
    var thumbnails: [MediaItem.ID: CGImage] = [:]
    var waveforms: [MediaItem.ID: WaveformPeaks] = [:]
    /// Whether the first lane says how to fill the timeline.
    var showsEmptyMessage = false
    /// How wide the part of the lanes in sight is, for the empty lanes'
    /// outlines.
    var viewportWidth: Double = 0

    @Environment(\.displayScale) private var displayScale

    #if os(macOS)
    static let handleWidth = 8.0
    #else
    static let handleWidth = 14.0
    #endif

    var body: some View {
        Canvas { context, size in
            context.translateBy(x: -origin, y: 0)
            let visible = origin...(origin + size.width)
            drawLanes(in: &context, visible: visible)
            drawRuler(in: &context, visible: visible)
            drawMarks(in: &context, visible: visible)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Lanes

    private func drawLanes(in context: inout GraphicsContext, visible: ClosedRange<Double>) {
        for (index, row) in layout.rows.enumerated() {
            let top = layout.rowTop(index)
            var separator = Path()
            separator.move(to: CGPoint(x: visible.lowerBound, y: top + TimelineLayout.trackHeight - 0.5))
            separator.addLine(to: CGPoint(x: visible.upperBound, y: top + TimelineLayout.trackHeight - 0.5))
            context.stroke(separator, with: .style(.separator), lineWidth: 0.5)

            guard let track = row.track, !track.clips.isEmpty else {
                drawEmptyLane(index, in: &context, isFirst: index == 0)
                continue
            }
            // A hidden or muted track's clips are left out of playback.
            let isOff = track.kind == .video && track.isHidden || track.kind == .audio && track.isMuted
            for clip in track.clips
            where layout.x(clip.timelineRange.end) >= visible.lowerBound && layout.x(clip.timelineStart) <= visible.upperBound {
                var clipContext = context
                if isOff { clipContext.opacity = 0.4 }
                drawClip(clip, on: track, row: index, in: &clipContext, visible: visible)
            }
        }
    }

    private func drawEmptyLane(_ index: Int, in context: inout GraphicsContext, isFirst: Bool) {
        let rect = CGRect(
            x: 0, y: layout.rowTop(index) + TimelineLayout.laneInset + 2,
            width: max(0, viewportWidth - 6), height: TimelineLayout.trackHeight - TimelineLayout.laneInset * 2 - 4
        )
        let outline = RoundedRectangle(cornerRadius: 6).path(in: rect)
        context.stroke(outline, with: .style(.tertiary), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        if isFirst && showsEmptyMessage {
            let text = Text("Timeline.Empty").font(.caption).foregroundStyle(.secondary)
            context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    private func color(for clip: Clip, on track: Track) -> Color {
        if track.kind == .audio { return .green }
        return media[clip.mediaID]?.kind == .image ? .indigo : .blue
    }

    private func drawClip(_ clip: Clip, on track: Track, row: Int, in context: inout GraphicsContext, visible: ClosedRange<Double>) {
        let rect = layout.rect(of: clip, inRow: row)
        let shape = RoundedRectangle(cornerRadius: 5).path(in: rect)
        let color = color(for: clip, on: track)
        let item = media[clip.mediaID]
        context.fill(shape, with: .color(color.opacity(0.75)))

        context.drawLayer { layer in
            layer.clip(to: shape)
            if track.kind == .video, let image = thumbnails[clip.mediaID] {
                drawThumbnails(image, in: rect, context: &layer, visible: visible)
            }
            if let peaks = waveforms[clip.mediaID], track.kind == .audio || !clip.isAudioDetached {
                drawWaveform(peaks, of: clip, in: rect, context: &layer, visible: visible, onPicture: track.kind == .video)
            }
            if clip.id == hovered {
                layer.fill(shape, with: .color(.white.opacity(0.15)))
            }
            // Kept in sight at the leading edge when the clip's start is
            // scrolled away.
            var labelX = max(rect.minX, visible.lowerBound) + 6
            // Clear of a selected clip's start handle.
            if selected.contains(clip.id) { labelX = max(labelX, rect.minX + min(Self.handleWidth, rect.width / 3) + 4) }
            layer.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5))
            // A video whose sound has been detached says so.
            if clip.isAudioDetached {
                let symbol = layer.resolve(Text(Image(systemName: "speaker.slash.fill")).font(.caption2).foregroundStyle(.white))
                layer.draw(symbol, at: CGPoint(x: labelX, y: rect.minY + 3), anchor: .topLeading)
                labelX += symbol.measure(in: rect.size).width + 4
            }
            let label = Text(verbatim: item?.name ?? "").font(.caption2.weight(.medium)).foregroundStyle(.white)
            layer.draw(label, at: CGPoint(x: labelX, y: rect.minY + 3), anchor: .topLeading)
        }

        context.stroke(shape, with: .color(color), lineWidth: 1)
        if selected.contains(clip.id) {
            drawSelection(rect, in: &context)
        }
    }

    /// The clip's media's picture, again and again along it.
    private func drawThumbnails(_ image: CGImage, in rect: CGRect, context: inout GraphicsContext, visible: ClosedRange<Double>) {
        guard image.height > 0 else { return }
        let height = rect.height
        let width = height * Double(image.width) / Double(image.height)
        guard width > 1 else { return }
        let resolved = context.resolve(Image(decorative: image, scale: displayScale))
        // From the first tile in sight, not from the clip's start.
        let first = max(0, ((visible.lowerBound - rect.minX) / width).rounded(.down))
        var x = rect.minX + first * width
        let end = min(rect.maxX, visible.upperBound)
        context.opacity = 0.85
        while x < end {
            context.draw(resolved, in: CGRect(x: x, y: rect.minY, width: width, height: height))
            x += width
        }
        context.opacity = 1
        // A shade under the name, so it can be read over any picture.
        let shade = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 18)
        context.fill(Path(shade), with: .linearGradient(
            Gradient(colors: [.black.opacity(0.45), .clear]),
            startPoint: CGPoint(x: 0, y: shade.minY), endPoint: CGPoint(x: 0, y: shade.maxY)
        ))
    }

    /// The clip's sound, as a bar for each point across it: over the whole
    /// clip on an audio track, or along the bottom of a video's picture.
    private func drawWaveform(
        _ peaks: WaveformPeaks, of clip: Clip, in rect: CGRect, context: inout GraphicsContext,
        visible: ClosedRange<Double>, onPicture: Bool
    ) {
        let band = onPicture ? CGRect(x: rect.minX, y: rect.maxY - 14, width: rect.width, height: 14) : rect.insetBy(dx: 0, dy: 3)
        let start = max(rect.minX, visible.lowerBound)
        let end = min(rect.maxX, visible.upperBound)
        guard end > start else { return }
        // A bar for each point in sight, each the loudest of the media it
        // covers, so nothing is lost however far out the timeline is zoomed.
        let first = start.rounded(.down)
        let count = Int((end - first).rounded(.up))
        let source = CMTimeRange(
            start: clip.sourceRange.start + CMTime(seconds: layout.seconds(atX: first - rect.minX), preferredTimescale: 6000),
            duration: CMTime(seconds: layout.seconds(atX: Double(count)), preferredTimescale: 6000)
        )
        var bars = Path()
        for (index, peak) in peaks.peaks(in: source, count: count).enumerated() {
            let height = Double(peak) * band.height
            let x = first + Double(index)
            bars.addRect(CGRect(x: x, y: onPicture ? band.maxY - height : band.midY - height / 2, width: 1, height: max(height, 0.5)))
        }
        context.fill(bars, with: .color(.white.opacity(onPicture ? 0.6 : 0.75)))
    }

    /// A bright frame round a selected clip, with a handle at each end to
    /// trim it by.
    private func drawSelection(_ rect: CGRect, in context: inout GraphicsContext) {
        let frame = RoundedRectangle(cornerRadius: 5).path(in: rect.insetBy(dx: 1, dy: 1))
        context.stroke(frame, with: .color(.yellow), lineWidth: 2.5)
        let width = min(Self.handleWidth, rect.width / 3)
        guard width >= 3 else { return }
        for edge in [rect.minX, rect.maxX - width] {
            let handle = CGRect(x: edge, y: rect.minY, width: width, height: rect.height)
            let corners = edge == rect.minX
                ? RectangleCornerRadii(topLeading: 5, bottomLeading: 5)
                : RectangleCornerRadii(bottomTrailing: 5, topTrailing: 5)
            context.fill(UnevenRoundedRectangle(cornerRadii: corners).path(in: handle), with: .color(.yellow))
            var grip = Path()
            grip.move(to: CGPoint(x: handle.midX, y: handle.midY - 7))
            grip.addLine(to: CGPoint(x: handle.midX, y: handle.midY + 7))
            context.stroke(grip, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    // MARK: - Ruler

    /// The gaps between the ruler's labelled marks it can choose from, in
    /// frames below a second and seconds above.
    private static let frameSteps: [Int64] = [1, 2, 5, 10]
    private static let secondSteps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
    private static let minimumLabelSpacing = 64.0

    /// The gap between labelled marks: the least that keeps their labels
    /// apart at this zoom.
    private var rulerStep: Double {
        let frame = frames.frameDuration.seconds
        let steps = Self.frameSteps.map { Double($0) * frame } + Self.secondSteps
        return steps.first { $0 * layout.pointsPerSecond >= Self.minimumLabelSpacing } ?? Self.secondSteps.last!
    }

    private func drawRuler(in context: inout GraphicsContext, visible: ClosedRange<Double>) {
        let height = TimelineLayout.rulerHeight
        let background = CGRect(x: visible.lowerBound, y: 0, width: visible.upperBound - visible.lowerBound, height: height)
        context.fill(Path(background), with: .style(.background.secondary))

        let step = rulerStep
        let spacing = step * layout.pointsPerSecond
        // Minor marks between the labelled ones, if there's room for them.
        let divisions = spacing >= 120 ? 5.0 : 2.0
        var ticks = Path()
        var index = (layout.seconds(atX: visible.lowerBound) / step).rounded(.down)
        while index * spacing <= visible.upperBound {
            let x = index * spacing
            ticks.move(to: CGPoint(x: x, y: height))
            ticks.addLine(to: CGPoint(x: x, y: height * 0.4))
            for minor in 1..<Int(divisions) {
                let minorX = x + spacing * Double(minor) / divisions
                ticks.move(to: CGPoint(x: minorX, y: height))
                ticks.addLine(to: CGPoint(x: minorX, y: height * 0.75))
            }
            let label = Text(verbatim: rulerLabel(seconds: index * step, step: step))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
            index += 1
        }
        context.stroke(ticks, with: .style(.secondary), lineWidth: 0.5)
        var bottom = Path()
        bottom.move(to: CGPoint(x: visible.lowerBound, y: height - 0.25))
        bottom.addLine(to: CGPoint(x: visible.upperBound, y: height - 0.25))
        context.stroke(bottom, with: .style(.separator), lineWidth: 0.5)
    }

    /// `m:ss`, or `h:mm:ss` past an hour, with the frame as `:ff` when the
    /// marks are closer than a second.
    private func rulerLabel(seconds: Double, step: Double) -> String {
        let time = CMTime(seconds: seconds, preferredTimescale: 6000)
        let frame = frames.frame(at: time + CMTime(value: 1, timescale: 6000))
        let rate = frames.timecodeRate
        let whole = frame / rate
        let base = whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
        return step < 1 ? base + String(format: ":%02d", frame % rate) : base
    }

    // MARK: - Marks

    /// Markers, the range marked in and out, and the line a drag has snapped
    /// to.
    private func drawMarks(in context: inout GraphicsContext, visible: ClosedRange<Double>) {
        let ruler = TimelineLayout.rulerHeight
        let bottom = layout.height

        if markedIn != nil || markedOut != nil {
            let start = markedIn.map(layout.x) ?? visible.lowerBound
            let end = markedOut.map(layout.x) ?? visible.upperBound
            if end > start {
                context.fill(Path(CGRect(x: start, y: 0, width: end - start, height: ruler)),
                             with: .color(.accentColor.opacity(0.22)))
            }
            for (x, isIn) in [(markedIn.map(layout.x), true), (markedOut.map(layout.x), false)] {
                guard let x else { continue }
                var bracket = Path()
                let tick = isIn ? 5.0 : -5.0
                bracket.move(to: CGPoint(x: x + tick, y: 1))
                bracket.addLine(to: CGPoint(x: x, y: 1))
                bracket.addLine(to: CGPoint(x: x, y: ruler - 1))
                bracket.addLine(to: CGPoint(x: x + tick, y: ruler - 1))
                context.stroke(bracket, with: .color(.accentColor), lineWidth: 1.5)
            }
        }

        for marker in markers {
            let x = layout.x(marker.time)
            guard visible.contains(x) else { continue }
            var line = Path()
            line.move(to: CGPoint(x: x, y: ruler))
            line.addLine(to: CGPoint(x: x, y: bottom))
            context.stroke(line, with: .color(.orange.opacity(0.35)), lineWidth: 1)
            var pin = Path()
            pin.move(to: CGPoint(x: x - 5, y: ruler - 10))
            pin.addLine(to: CGPoint(x: x + 5, y: ruler - 10))
            pin.addLine(to: CGPoint(x: x, y: ruler - 2))
            pin.closeSubpath()
            context.fill(pin, with: .color(.orange))
        }

        if let snapTime {
            let x = layout.x(snapTime)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: bottom))
            context.stroke(line, with: .color(.yellow), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
    }
}
