import SwiftUI

/// Colours for the document picker's background, drawn from the app icon's red.
enum DocumentLaunch {
    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(
            red: Double(hex >> 16 & 0xFF) / 255,
            green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// The background behind the document picker: warm light leaks in light
/// mode, and a spotlight falling onto the browser in dark mode. Decoration
/// only, so hidden from VoiceOver.
struct DocumentLaunchBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                SpotlightBackground()
            } else {
                LightLeaksBackground()
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Spotlight

/// Dark mode: a soft beam falling from the top of the screen all the way
/// down, so the browser below sits in its light, with dust drifting through.
struct SpotlightBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Mote {
        var x: Double, y: Double, radius: Double, opacity: Double, speed: Double
    }

    private let motes: [Mote] = {
        var generator = SeededGenerator(seed: 7)
        return (0..<110).map { _ in
            Mote(x: .random(in: -1...1, using: &generator), y: .random(in: 0...1, using: &generator),
                 radius: .random(in: 0.6...2.0, using: &generator), opacity: .random(in: 0.2...0.8, using: &generator),
                 speed: .random(in: 0.003...0.009, using: &generator))
        }
    }()

    /// Half the beam's width at the top and at the bottom, as fractions of the screen's width.
    private let topSpread = 0.09
    private let bottomSpread = 0.85

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                DocumentLaunch.rgb(0x0D0405)

                // The beam, widening all the way down.
                Path { path in
                    path.move(to: CGPoint(x: size.width * (0.5 - topSpread), y: -20))
                    path.addLine(to: CGPoint(x: size.width * (0.5 + topSpread), y: -20))
                    path.addLine(to: CGPoint(x: size.width * (0.5 + bottomSpread), y: size.height))
                    path.addLine(to: CGPoint(x: size.width * (0.5 - bottomSpread), y: size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(
                    stops: [
                        .init(color: DocumentLaunch.rgb(0xFFE3E6, 0.55), location: 0),
                        .init(color: DocumentLaunch.rgb(0xF4A3AD, 0.3), location: 0.4),
                        .init(color: DocumentLaunch.rgb(0xE3344C, 0.22), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .blur(radius: 24)

                // The light pooling on the browser.
                Ellipse()
                    .fill(RadialGradient(
                        colors: [DocumentLaunch.rgb(0xFF5068, 0.36), DocumentLaunch.rgb(0xA8182C, 0.15), .clear],
                        center: .center, startRadius: 0, endRadius: size.width * 0.75
                    ))
                    .frame(width: size.width * 1.5, height: size.height * 0.45)
                    .position(x: size.width / 2, y: size.height * 0.72)

                // The lamp's glare.
                Ellipse()
                    .fill(DocumentLaunch.rgb(0xFFF1F2, 0.7))
                    .frame(width: size.width * 0.5, height: 60)
                    .blur(radius: 30)
                    .position(x: size.width / 2, y: 0)

                SwiftUI.TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        for mote in motes {
                            let y = (mote.y - time * mote.speed).truncatingRemainder(dividingBy: 1)
                            let depth = y < 0 ? y + 1 : y
                            let spread = topSpread + (bottomSpread - topSpread) * depth
                            let x = size.width * (0.5 + mote.x * spread * 0.8 + sin(time * 0.3 + mote.y * 9) * 0.01)
                            let rect = CGRect(x: x - mote.radius, y: depth * size.height - mote.radius,
                                              width: mote.radius * 2, height: mote.radius * 2)
                            // Motes catch less light further from the lamp.
                            let opacity = mote.opacity * (1 - depth * 0.5)
                            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Light leaks

/// Light mode: blurred warm light drifting at the edges, with a little film
/// grain.
struct LightLeaksBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Leak {
        var hex: UInt32, x: Double, y: Double, radius: Double, opacity: Double, phase: Double
    }

    private let leaks: [Leak] = [
        Leak(hex: 0xFF6A3D, x: 0.0, y: 0.08, radius: 0.55, opacity: 0.44, phase: 0),
        Leak(hex: 0xE0204A, x: 1.0, y: 0.26, radius: 0.5, opacity: 0.41, phase: 2),
        Leak(hex: 0xFFC07A, x: 0.45, y: -0.04, radius: 0.35, opacity: 0.36, phase: 4),
        Leak(hex: 0x8A1030, x: 0.75, y: 0.55, radius: 0.45, opacity: 0.36, phase: 1),
    ]

    var body: some View {
        ZStack {
            DocumentLaunch.rgb(0xFFF6F2)
            SwiftUI.TimelineView(.animation(paused: reduceMotion)) { timeline in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    context.addFilter(.blur(radius: size.width * 0.18))
                    for leak in leaks {
                        let drift = CGSize(width: sin(time * 0.17 + leak.phase) * size.width * 0.06,
                                           height: cos(time * 0.13 + leak.phase) * size.width * 0.05)
                        let radius = size.width * leak.radius
                        let center = CGPoint(x: size.width * leak.x + drift.width, y: size.height * leak.y + drift.height)
                        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(DocumentLaunch.rgb(leak.hex, leak.opacity)))
                    }
                }
            }
            FilmGrain()
                .opacity(0.06)
                .blendMode(.multiply)
        }
    }
}

/// Static speckle, drawn once.
private struct FilmGrain: View {
    var body: some View {
        Canvas { context, size in
            var generator = SeededGenerator(seed: 3)
            var specks = Path()
            let count = Int(size.width * size.height / 30)
            for _ in 0..<count {
                specks.addRect(CGRect(x: .random(in: 0..<size.width, using: &generator),
                                      y: .random(in: 0..<size.height, using: &generator),
                                      width: 1, height: 1))
            }
            context.fill(specks, with: .color(.black))
        }
        .drawingGroup()
    }
}

/// A small deterministic generator, so decoration lays out the same every launch.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
