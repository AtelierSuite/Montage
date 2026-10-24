import MontageEngine
import SwiftUI

/// How loud a clip is playing, after its effects: a bar for each side, from
/// -60 dB to full scale, falling back gently after each peak. Still while
/// playback is stopped.
struct AudioLevelMeter: View {
    @Environment(ProjectEditor.self) private var editor
    let clipID: Clip.ID

    @State private var display = Display()

    /// How far the meter shows below full scale, in decibels.
    nonisolated private static let floor = -60.0
    /// How fast the bars fall back, in decibels a second.
    nonisolated private static let fallRate = 24.0

    var body: some View {
        let playback = editor.playback
        let levels = playback.composition?.audioLevels
        SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30, paused: !playback.isPlaying)) { context in
            Canvas { canvas, size in
                if !playback.isPlaying { display.reset() }
                let peak = playback.isPlaying ? levels?.takePeak(of: clipID) : nil
                let (left, right) = display.advance(to: peak, at: context.date)
                let height = (size.height - 2) / 2
                for (index, level) in [left, right].enumerated() {
                    let y = Double(index) * (height + 2)
                    canvas.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: height), cornerRadius: 2), with: .color(.secondary.opacity(0.2)))
                    let fraction = max(0, min(1, (level - Self.floor) / -Self.floor))
                    let bar = CGRect(x: 0, y: y, width: size.width * fraction, height: height)
                    canvas.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(level > -3 ? .red : level > -12 ? .yellow : .green))
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    /// The levels the bars show, in decibels, kept between frames. Changed
    /// while drawing, so it isn't observed.
    private final class Display {
        var left = AudioLevelMeter.floor
        var right = AudioLevelMeter.floor
        var time: Date?

        func reset() {
            left = AudioLevelMeter.floor
            right = AudioLevelMeter.floor
            time = nil
        }

        func advance(to peak: (left: Float, right: Float)?, at date: Date) -> (Double, Double) {
            let elapsed = time.map { date.timeIntervalSince($0) } ?? 0
            time = date
            let fall = AudioLevelMeter.fallRate * max(0, elapsed)
            left = max(decibels(peak?.left), left - fall)
            right = max(decibels(peak?.right), right - fall)
            return (left, right)
        }

        private func decibels(_ peak: Float?) -> Double {
            guard let peak, peak > 0 else { return AudioLevelMeter.floor }
            return max(AudioLevelMeter.floor, 20 * log10(Double(peak)))
        }
    }
}
