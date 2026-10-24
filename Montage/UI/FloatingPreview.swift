import MontageEngine
import SwiftUI

/// The preview in a small window floating over the editor, picture in
/// picture, so the timeline can have the preview's room while the picture
/// stays in sight.
///
/// It can be dragged anywhere, and settles into the nearest corner when let
/// go. Thrown or dragged past the side of the screen, it tucks away there,
/// leaving a tab at the very edge of the screen to bring it back, though not
/// on the side with the Dynamic Island or notch, where the tab would be under
/// it. It has the preview's playback controls over the picture, with buttons
/// to show it full screen and to put it back in the editor.
///
/// Full screen, the window itself grows to fill the screen, over a black
/// that fades in behind it, and shrinks back into its corner when it's
/// closed or swiped down.
///
/// It spreads into the safe area at the sides, to rest close to the edge of
/// the screen and tuck away right against it, except on the side with the
/// sensor housing, which it keeps clear of.
struct FloatingPreview: View {
    let playback: PlaybackController
    /// The project's frame shape, width over height.
    let aspectRatio: Double
    let onDock: () -> Void
    /// Room kept clear along the bottom, for the controls floating there.
    var reservedBottom = 0.0
    /// Hears where the window is on screen, as it moves, so whatever hosts
    /// it can let touches anywhere else through.
    var onFrameChange: (CGRect) -> Void = { _ in }

    private enum Corner {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isTop: Bool { self == .topLeading || self == .topTrailing }
    }

    @State private var corner = Corner.bottomTrailing
    /// Whether it's tucked away at its corner's side of the screen.
    @State private var isStashed = false
    /// Whether it fills the screen.
    @State private var isExpanded = false
    /// How far it's been dragged from where it rests.
    @State private var drag = CGSize.zero
    /// The side of the screen with the Dynamic Island or notch, when the
    /// phone is held sideways and has one.
    @State private var sensorHousing: HorizontalEdge?
    @State private var showsControls = true
    @State private var showsLargeControls = false
    /// Whether it's on its way to or from full screen, when it shows no
    /// controls.
    @State private var isMoving = false
    /// Where the window is on screen.
    @State private var windowFrame = CGRect.zero

    /// Room between the window and the edges it rests against.
    private let margin = 12.0
    /// How much of a tucked-away window stays on screen, to take hold of.
    private let tabWidth = 28.0
    private let cornerRadius = 12.0
    /// Rounder while tucked away, so what's left reads as a tab.
    private let tabCornerRadius = 16.0
    /// How far down a swipe has to pull the full-screen picture to close it.
    private let closingPull = 120.0
    private let expansion = Animation.spring(duration: 0.45, bounce: 0.12)

    var body: some View {
        // The safe area is read from inside it, where it's known, and the
        // window is laid out over the whole screen, outside it.
        GeometryReader { safeArea in
            room(insets: safeArea.safeAreaInsets)
                .ignoresSafeArea()
        }
        .background { SensorHousingReader { sensorHousing = $0 } }
        // Turned so its side has the sensor housing, it comes out again.
        .onChange(of: sensorHousing) { _, housing in
            if isStashed, housing == (corner.isLeading ? .leading : .trailing) { setStashed(false) }
        }
    }

    private func room(insets: EdgeInsets) -> some View {
        GeometryReader { geometry in
            let room = Room(size: geometry.size, insets: insets)
            // Full screen, the picture's own frame fitted to the screen, so it
            // only grows on the way there, keeping its shape.
            let size = isExpanded ? fittedSize(in: room.size) : windowSize(in: room)
            let center = isExpanded
                ? CGPoint(x: room.size.width / 2, y: room.size.height / 2)
                : restingCenter(size: size, in: room)
            ZStack {
                // Fades in behind the picture as it grows to fill the screen.
                Color.black
                    .opacity(isExpanded ? 1 - min(max(drag.height, 0) / 400, 0.6) : 0)
                    .allowsHitTesting(false)
                window(size: size)
                    .scaleEffect(isExpanded ? 1 - min(max(drag.height, 0) / 2000, 0.1) : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        windowFrame = frame
                        reportTouchableFrame(in: room)
                    }
                    .position(x: center.x + (isExpanded ? 0 : drag.width), y: center.y + drag.height)
                    .gesture(isExpanded ? nil : dragging(size: size, in: room))
                if isExpanded && showsLargeControls {
                    largeControls(insets: room.insets)
                }
            }
            .gesture(isExpanded ? closing : nil)
            .onChange(of: isExpanded) { reportTouchableFrame(in: room) }
        }
    }

    /// Full screen, the whole screen takes touches, for the controls around
    /// the picture; otherwise only the window does.
    private func reportTouchableFrame(in room: Room) {
        onFrameChange(isExpanded ? CGRect(origin: .zero, size: room.size) : windowFrame)
    }

    private func fittedSize(in size: CGSize) -> CGSize {
        let ratio = max(aspectRatio, 0.1)
        return size.width / size.height > ratio
            ? CGSize(width: size.height * ratio, height: size.height)
            : CGSize(width: size.width, height: size.width / ratio)
    }

    // MARK: - Window

    private func window(size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: isExpanded ? 0 : isStashed ? tabCornerRadius : cornerRadius)
        return PlayerView(player: playback.player)
            .frame(width: size.width, height: size.height)
            .overlay {
                if isStashed {
                    stashTab
                        .contentShape(.rect)
                        .onTapGesture { setStashed(false) }
                } else if !isExpanded && !isMoving {
                    PlaybackOverlay(playback: playback, isShown: $showsControls, size: .compact) {
                        HStack {
                            PlaybackOverlayButton("Preview.Expand", systemImage: "arrow.up.left.and.arrow.down.right") {
                                setExpanded(true)
                            }
                            Spacer(minLength: 0)
                            PlaybackOverlayButton("Preview.Dock", systemImage: "pip.exit", action: onDock)
                        }
                    }
                }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(isExpanded ? 0 : 0.3), radius: 10, y: 4)
            .contentShape(shape)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Preview.Title"))
            .accessibilityAction(named: Text("Preview.Dock"), onDock)
            .accessibilityAction(named: Text(isStashed ? "Preview.Unstash" : "Preview.Stash")) {
                if isStashed || canStash(on: corner.isLeading ? .leading : .trailing) { setStashed(!isStashed) }
            }
    }

    /// The full-screen controls, over the whole screen rather than only the
    /// picture, as in the full-screen player.
    private func largeControls(insets: EdgeInsets) -> some View {
        PlaybackOverlay(playback: playback, isShown: $showsControls, size: .large, contentInsets: insets) {
            HStack {
                PlaybackOverlayButton("Fullscreen.Close", systemImage: "xmark", isLarge: true) {
                    setExpanded(false)
                }
                Spacer()
            }
        } bottom: {
            PlaybackScrubber(playback: playback)
        }
    }

    /// Covers a tucked-away window, with a chevron on the strip still on
    /// screen pointing the way it comes back.
    private var stashTab: some View {
        ZStack(alignment: corner.isLeading ? .trailing : .leading) {
            Rectangle()
                .fill(.ultraThinMaterial)
            Image(systemName: corner.isLeading ? "chevron.compact.right" : "chevron.compact.left")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: tabWidth)
        }
    }

    /// Grows the window to fill the screen, or shrinks it back into its
    /// corner. The controls go while it moves, and the full-screen ones come
    /// once it's there.
    private func setExpanded(_ expanded: Bool) {
        showsLargeControls = false
        showsControls = true
        isMoving = true
        withAnimation(expansion) {
            isExpanded = expanded
            drag = .zero
        } completion: {
            isMoving = false
            showsLargeControls = isExpanded
        }
    }

    // MARK: - Placing

    /// The room the window moves in: the whole screen, with the safe area's
    /// insets around it.
    private struct Room {
        var size: CGSize
        var insets: EdgeInsets

        /// The width inside the safe area.
        var safeWidth: Double { size.width - insets.leading - insets.trailing }
    }

    /// About a third of the safe width across, smaller when the room is
    /// wide, in the project's frame shape.
    private func windowSize(in room: Room) -> CGSize {
        let share = room.safeWidth > room.size.height ? 0.28 : 0.42
        let width = min(room.safeWidth * share, 280)
        return CGSize(width: width, height: width / max(aspectRatio, 0.1))
    }

    /// How far in from a side of the screen the window rests: clear of the
    /// sensor housing on its side, or else just in from the edge.
    private func inset(on edge: HorizontalEdge, in room: Room) -> Double {
        let safeInset = edge == .leading ? room.insets.leading : room.insets.trailing
        return (sensorHousing == edge ? safeInset : 0) + margin
    }

    private func canStash(on edge: HorizontalEdge) -> Bool {
        sensorHousing != edge
    }

    private func restingCenter(size: CGSize, in room: Room) -> CGPoint {
        let x: Double = if isStashed {
            corner.isLeading ? tabWidth - size.width / 2 : room.size.width - tabWidth + size.width / 2
        } else {
            corner.isLeading
                ? inset(on: .leading, in: room) + size.width / 2
                : room.size.width - inset(on: .trailing, in: room) - size.width / 2
        }
        let y = corner.isTop
            ? room.insets.top + margin + size.height / 2
            : room.size.height - room.insets.bottom - reservedBottom - margin - size.height / 2
        return CGPoint(x: x, y: y)
    }

    /// Follows the finger, then settles where the drag was heading: tucked
    /// away if it was going off a side it can tuck away at, or else in the
    /// nearest corner.
    private func dragging(size: CGSize, in room: Room) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                drag = value.translation
            }
            .onEnded { value in
                // Where it was let go, carried on a little by how fast it was
                // going: a flick reaches the next corner, or off the side, but
                // a quick move to a corner doesn't overshoot it.
                let start = restingCenter(size: size, in: room)
                let carry = 0.3
                let x = start.x + value.translation.width
                    + (value.predictedEndTranslation.width - value.translation.width) * carry
                let y = start.y + value.translation.height
                    + (value.predictedEndTranslation.height - value.translation.height) * carry
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                    let isLeading = x < room.size.width / 2
                    let isTop = y < room.size.height / 2
                    corner = switch (isTop, isLeading) {
                    case (true, true): .topLeading
                    case (true, false): .topTrailing
                    case (false, true): .bottomLeading
                    case (false, false): .bottomTrailing
                    }
                    isStashed = x < 0 && canStash(on: .leading) || x > room.size.width && canStash(on: .trailing)
                    drag = .zero
                }
            }
    }

    /// Full screen, pulling the picture down shrinks it back into its corner
    /// once it's far enough; let go before, it springs back.
    private var closing: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                showsLargeControls = false
                drag = CGSize(width: 0, height: max(0, value.translation.height))
            }
            .onEnded { value in
                if value.translation.height > closingPull || value.predictedEndTranslation.height > closingPull * 2 {
                    setExpanded(false)
                } else {
                    withAnimation(.spring(duration: 0.3)) { drag = .zero } completion: { showsLargeControls = true }
                }
            }
    }

    private func setStashed(_ stashed: Bool) {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { isStashed = stashed }
    }
}

/// Finds which side of the screen has the Dynamic Island or notch: on an
/// iPhone held sideways that has one, the side the top of the phone is
/// turned to. There's no asking whether a phone has one, but held sideways,
/// one that does has a safe area at the sides, and one that doesn't has none.
private struct SensorHousingReader: UIViewRepresentable {
    let onChange: (HorizontalEdge?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: (HorizontalEdge?) -> Void = { _ in }
        private var reported: HorizontalEdge??

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            let edge = housingEdge()
            guard reported != .some(edge) else { return }
            reported = .some(edge)
            // Not in the middle of a layout pass.
            DispatchQueue.main.async { [onChange] in onChange(edge) }
        }

        private func housingEdge() -> HorizontalEdge? {
            guard let window, let scene = window.windowScene else { return nil }
            let insets = window.safeAreaInsets
            guard insets.left > 0 || insets.right > 0 else { return nil }
            // Held with the home side to the left, the top of the phone is to
            // the right, and the other way round.
            let isOnRight: Bool
            switch scene.effectiveGeometry.interfaceOrientation {
            case .landscapeLeft: isOnRight = true
            case .landscapeRight: isOnRight = false
            default: return nil
            }
            let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
            return isOnRight != isRightToLeft ? .trailing : .leading
        }
    }
}
