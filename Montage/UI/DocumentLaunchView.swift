import SwiftUI

/// The pieces of the document picker's top area: a wash of the app icon's
/// red, with faint rows of clips behind the actions, like a timeline.
enum DocumentLaunch {
    /// Kept quiet: near white in light mode, near black in dark, so the
    /// system's buttons and browser read over it and the colour stays a
    /// backdrop rather than the whole page.
    static let topColor = adaptive(
        light: UIColor(red: 0.97, green: 0.88, blue: 0.89, alpha: 1),
        dark: UIColor(red: 0.22, green: 0.05, blue: 0.08, alpha: 1)
    )
    static let bottomColor = adaptive(
        light: UIColor(red: 0.99, green: 0.96, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.09, green: 0.03, blue: 0.04, alpha: 1)
    )
    /// The colour the clips are drawn in.
    static let ink = adaptive(
        light: UIColor(red: 0.66, green: 0.09, blue: 0.17, alpha: 1),
        dark: UIColor(red: 0.95, green: 0.62, blue: 0.67, alpha: 1)
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// The red wash, with rows of clips that fade out towards the browser so the
/// page reads as a timeline without the clips competing with text.
/// Decoration only, so hidden from VoiceOver.
struct DocumentLaunchBackground: View {
    private let trackHeight = 26.0
    private let trackSpacing = 14.0
    private let clipSpacing = 3.0
    /// Clip lengths along a track, in points, with gaps as negatives. Each
    /// track starts further along the pattern so neighbours differ.
    private let pattern: [Double] = [120, 76, -40, 168, 92, -64, 58, 140, -24, 104]
    /// Where the playhead stands, across the width.
    private let playhead = 0.62

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DocumentLaunch.topColor, DocumentLaunch.bottomColor],
                startPoint: .top,
                endPoint: .bottom
            )
            Canvas { context, size in
                var clips = Path()
                var y = trackSpacing
                var track = 0
                while y < size.height {
                    var x = -Double(track * 53 % 90)
                    var index = track * 3
                    while x < size.width {
                        let length = pattern[index % pattern.count]
                        if length > 0 {
                            let rect = CGRect(x: x, y: y, width: length - clipSpacing, height: trackHeight)
                            clips.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
                        }
                        x += abs(length)
                        index += 1
                    }
                    y += trackHeight + trackSpacing
                    track += 1
                }
                context.fill(clips, with: .color(DocumentLaunch.ink.opacity(0.09)))

                let x = (size.width * playhead).rounded()
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(DocumentLaunch.ink.opacity(0.25)), lineWidth: 1.5)
            }
            .mask {
                LinearGradient(
                    colors: [.white, .white.opacity(0.35), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
