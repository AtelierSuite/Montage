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
    let reveal: DocumentLaunchReveal

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                SpotlightBackground(isRevealed: reveal.isRevealed)
            } else {
                LightLeaksBackground(isRevealed: reveal.isRevealed)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// How long the background takes to come in once the picker is on screen.
private let revealDuration = 1.6

/// Whether the picker has come on screen, shared between the background and
/// the accessory that watches for it.
@Observable
final class DocumentLaunchReveal {
    var isRevealed = false
}

/// Sits in the picker's background accessory, which the system fades in with
/// the actions and browser once they have loaded, unlike the background, and
/// reveals the background then.
struct DocumentLaunchRevealTrigger: View {
    let reveal: DocumentLaunchReveal

    var body: some View {
        DocumentLaunchVisibilityWatcher { reveal.isRevealed = true }
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Spotlight

/// Dark mode: a soft beam falling from the top of the screen all the way
/// down, so the browser below sits in its light, with dust drifting through.
/// Once the picker is on screen the beam opens and the dust drifts a little,
/// easing to a stop.
struct SpotlightBackground: View {
    let isRevealed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Half the beam's width at the top and at the bottom, as fractions of the screen's width.
    private let topSpread = 0.09
    private let bottomSpread = 0.85

    var body: some View {
        // With Reduce Motion the beam and dust only fade in.
        let opening = isRevealed || reduceMotion ? 1 : 0.12

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
                .scaleEffect(x: opening, y: 1, anchor: .top)
                .opacity(isRevealed ? 1 : 0.3)

                // The light pooling on the browser.
                Ellipse()
                    .fill(RadialGradient(
                        colors: [DocumentLaunch.rgb(0xFF5068, 0.36), DocumentLaunch.rgb(0xA8182C, 0.15), .clear],
                        center: .center, startRadius: 0, endRadius: size.width * 0.75
                    ))
                    .frame(width: size.width * 1.5, height: size.height * 0.45)
                    .position(x: size.width / 2, y: size.height * 0.72)
                    .scaleEffect(x: opening, y: 1)
                    .opacity(isRevealed ? 1 : 0)

                // The lamp's glare.
                Ellipse()
                    .fill(DocumentLaunch.rgb(0xFFF1F2, 0.7))
                    .frame(width: size.width * 0.5, height: 60)
                    .blur(radius: 30)
                    .position(x: size.width / 2, y: 0)

                Dust(
                    drift: isRevealed && !reduceMotion ? 1 : 0,
                    topSpread: topSpread * opening,
                    bottomSpread: bottomSpread * opening
                )
                .opacity(isRevealed ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: revealDuration), value: isRevealed)
    }
}

/// The dust in the beam. Animatable, so it drifts and widens with the beam
/// while the background comes in, and is still after.
private struct Dust: View, Animatable {
    /// How far the dust has drifted, from 0 to 1.
    var drift: Double
    var topSpread: Double
    var bottomSpread: Double

    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(drift, AnimatablePair(topSpread, bottomSpread)) }
        set {
            drift = newValue.first
            topSpread = newValue.second.first
            bottomSpread = newValue.second.second
        }
    }

    private struct Mote {
        var x: Double, y: Double, radius: Double, opacity: Double, speed: Double
    }

    private static let motes: [Mote] = {
        var generator = SeededGenerator(seed: 7)
        return (0..<110).map { _ in
            Mote(x: .random(in: -1...1, using: &generator), y: .random(in: 0...1, using: &generator),
                 radius: .random(in: 0.6...2.0, using: &generator), opacity: .random(in: 0.2...0.8, using: &generator),
                 speed: .random(in: 0.003...0.009, using: &generator))
        }
    }()

    /// How far the dust drifts while coming in, in seconds of its speed.
    private let travel = 5.0

    var body: some View {
        Canvas { context, size in
            let time = travel * drift
            for mote in Self.motes {
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

// MARK: - Light leaks

/// Light mode: blurred warm light at the edges that fades in once the picker
/// is on screen, with a little film grain.
struct LightLeaksBackground: View {
    let isRevealed: Bool

    private struct Leak {
        var hex: UInt32, x: Double, y: Double, radius: Double, opacity: Double
    }

    private let leaks: [Leak] = [
        Leak(hex: 0xFF6A3D, x: 0.0, y: 0.08, radius: 0.55, opacity: 0.44),
        Leak(hex: 0xE0204A, x: 1.0, y: 0.26, radius: 0.5, opacity: 0.41),
        Leak(hex: 0xFFC07A, x: 0.45, y: -0.04, radius: 0.35, opacity: 0.36),
        Leak(hex: 0x8A1030, x: 0.75, y: 0.55, radius: 0.45, opacity: 0.36),
    ]

    var body: some View {
        ZStack {
            DocumentLaunch.rgb(0xFFF6F2)
            Canvas { context, size in
                context.addFilter(.blur(radius: size.width * 0.18))
                for leak in leaks {
                    let radius = size.width * leak.radius
                    let center = CGPoint(x: size.width * leak.x, y: size.height * leak.y)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(DocumentLaunch.rgb(leak.hex, leak.opacity)))
                }
            }
            .opacity(isRevealed ? 1 : 0)
            .animation(.easeOut(duration: revealDuration), value: isRevealed)
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

/// Calls back once, the first time the view it sits behind is fully on
/// screen: in a window, with nothing above it hidden or faded.
private struct DocumentLaunchVisibilityWatcher: UIViewRepresentable {
    var onVisible: () -> Void

    func makeUIView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onVisible = onVisible
        return view
    }

    func updateUIView(_ uiView: WatcherView, context: Context) {
        // Once called back, the watcher has nothing more to do.
        if uiView.hasCalledBack { return }
        uiView.onVisible = onVisible
    }

    final class WatcherView: UIView {
        var onVisible: (() -> Void)?
        private(set) var hasCalledBack = false
        private var displayLink: CADisplayLink?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            guard window != nil, !hasCalledBack else { return }
            // Checked every frame, since the system fades the picker in by
            // animating a view above it rather than telling it anything.
            let link = CADisplayLink(target: self, selector: #selector(check))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func check() {
            var view: UIView? = self
            while let current = view {
                let opacity = current.layer.presentation()?.opacity ?? current.layer.opacity
                if current.isHidden || opacity < 0.99 { return }
                view = current.superview
            }
            displayLink?.invalidate()
            displayLink = nil
            hasCalledBack = true
            let onVisible = onVisible
            self.onVisible = nil
            onVisible?()
        }
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
