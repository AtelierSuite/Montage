import MontageEngine
import SwiftUI

/// The preview in a small window floating over the editor, picture in
/// picture, so the timeline can have the preview's room while the picture
/// stays in sight.
///
/// It can be dragged anywhere, and settles into the nearest corner when let
/// go. Thrown or dragged past the side of the screen, it tucks away there,
/// leaving a tab to bring it back. Tapping it shows the preview full screen;
/// its button puts it back in the editor.
struct FloatingPreview: View {
    let playback: PlaybackController
    /// The project's frame shape, width over height.
    let aspectRatio: Double
    let onExpand: () -> Void
    let onDock: () -> Void

    private enum Corner {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isTop: Bool { self == .topLeading || self == .topTrailing }
    }

    @State private var corner = Corner.bottomTrailing
    /// Whether it's tucked away at its corner's side of the screen.
    @State private var isStashed = false
    /// How far it's been dragged from where it rests.
    @State private var drag = CGSize.zero

    /// Room between the window and the edges it rests against.
    private let margin = 12.0
    /// How much of a tucked-away window stays on screen, to take hold of.
    private let tabWidth = 28.0

    var body: some View {
        GeometryReader { geometry in
            let size = windowSize(in: geometry.size)
            let center = restingCenter(size: size, in: geometry.size)
            window(size: size)
                .position(x: center.x + drag.width, y: center.y + drag.height)
                .gesture(dragging(size: size, in: geometry.size))
        }
    }

    // MARK: - Window

    private func window(size: CGSize) -> some View {
        PlayerView(player: playback.player)
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                if isStashed {
                    stashTab
                }
            }
            .overlay(alignment: .topTrailing) {
                if !isStashed {
                    Button("Preview.Dock", systemImage: "pip.exit", action: onDock)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .padding(6)
                        .contentShape(.rect)
                        .buttonStyle(.plain)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .contentShape(.rect(cornerRadius: 12))
            .onTapGesture {
                if isStashed {
                    setStashed(false)
                } else {
                    onExpand()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Preview.Title"))
            .accessibilityAction(named: Text("Preview.Dock"), onDock)
            .accessibilityAction(named: Text(isStashed ? "Preview.Unstash" : "Preview.Stash")) {
                setStashed(!isStashed)
            }
    }

    /// Covers a tucked-away window, with a chevron on the strip still on
    /// screen pointing the way it comes back.
    private var stashTab: some View {
        ZStack(alignment: corner.isLeading ? .trailing : .leading) {
            Rectangle()
                .fill(.ultraThinMaterial)
            Image(systemName: corner.isLeading ? "chevron.compact.right" : "chevron.compact.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: tabWidth)
        }
    }

    // MARK: - Placing

    /// About a third of the room across, smaller when the room is wide, in
    /// the project's frame shape.
    private func windowSize(in room: CGSize) -> CGSize {
        let share = room.width > room.height ? 0.28 : 0.42
        let width = min(room.width * share, 280)
        return CGSize(width: width, height: width / max(aspectRatio, 0.1))
    }

    private func restingCenter(size: CGSize, in room: CGSize) -> CGPoint {
        let x: Double = if isStashed {
            corner.isLeading ? tabWidth - size.width / 2 : room.width - tabWidth + size.width / 2
        } else {
            corner.isLeading ? margin + size.width / 2 : room.width - margin - size.width / 2
        }
        let y = corner.isTop ? margin + size.height / 2 : room.height - margin - size.height / 2
        return CGPoint(x: x, y: y)
    }

    /// Follows the finger, then settles where the drag was heading: tucked
    /// away if it was going off the side, or else in the nearest corner.
    private func dragging(size: CGSize, in room: CGSize) -> some Gesture {
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
                    let isLeading = x < room.width / 2
                    let isTop = y < room.height / 2
                    corner = switch (isTop, isLeading) {
                    case (true, true): .topLeading
                    case (true, false): .topTrailing
                    case (false, true): .bottomLeading
                    case (false, false): .bottomTrailing
                    }
                    isStashed = x < 0 || x > room.width
                    drag = .zero
                }
            }
    }

    private func setStashed(_ stashed: Bool) {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { isStashed = stashed }
    }
}
