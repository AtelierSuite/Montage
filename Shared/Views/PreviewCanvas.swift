import CoreGraphics
import CoreMedia
import MontageEngine
import SwiftUI

/// Handles over the preview's picture for the selected layer: its outline,
/// dragged inside to move it, its corners to scale it and a handle off its
/// top to turn it. With one of its effects' masks chosen to edit, the mask's
/// box gets handles instead: to move, size, turn and soften it, and to move
/// a path mask's points.
///
/// Each drag is one undo step. Values are set at the playhead: a parameter
/// that has keyframes gets one there, and one that hasn't changes
/// throughout. The handles go while playing.
///
/// Laid over the picture, the frame's shape or not: the frame is fitted in
/// as the player fits it. `catchesTaps` puts a tap area under the handles to
/// pick the layer under the pointer; without it, the view around the
/// preview hands taps on the picture to `onTapPicture`.
struct PreviewCanvas: View {
    @Environment(ProjectEditor.self) private var editor
    var catchesTaps = true
    /// A tap on the selected layer, in this view's points, for the view
    /// around the preview to pick a layer or do what else a tap there does.
    var onTapPicture: ((CGPoint) -> Void)?

    /// The drag under way, if any.
    @State private var drag: Drag?
    /// Goes back to false however a drag stops, including when the system
    /// cancels it without ending it, so the drag never outlives it.
    @GestureState private var isDragging = false

    private static let space = "PreviewCanvas"

    #if os(macOS)
    private let handleSize = 9.0
    private let hitSize = 16.0
    #else
    private let handleSize = 12.0
    private let hitSize = 36.0
    #endif
    /// How far, in points, the rotate handle stands off the top edge, and a
    /// mask's feather handle past its soft edge.
    private let rotateReach = 26.0
    private let handleReach = 22.0

    /// A distance in the view's points, in the frame's pixels.
    private static func maskReach(_ points: Double, mapping: PreviewMapping) -> Double {
        points / max(mapping.scale, 1e-6)
    }

    /// What a drag holds on to: what it's moving, and how things were when it
    /// began, so each step makes the whole change from there.
    private struct Drag {
        enum Target {
            case transform(TransformHandle)
            case mask(Effect.ID, MaskHandle, LayerPlacement)
        }

        var clipID: Clip.ID
        var target: Target
        /// The time in the clip the drag sets values at.
        var time: CMTime
        /// Between the view and the frame, as the drag began.
        var mapping: PreviewMapping
    }

    var body: some View {
        GeometryReader { geometry in
            let mapping = PreviewMapping(renderSize: editor.project.settings.renderSize, viewSize: geometry.size)
            ZStack(alignment: .topLeading) {
                if catchesTaps {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture(coordinateSpace: .named(Self.space)) { location in
                            editor.selectLayer(at: mapping.renderPoint(fromView: location))
                        }
                }
                if let (clip, layer) = selectedLayer {
                    if let effect = editedMask(of: clip), let mask = effect.mask {
                        maskHandles(clip: clip, effect: effect, placement: MaskPlacement(mask, in: layer, at: clipTime(clip)),
                                    mapping: mapping)
                    } else {
                        transformHandles(clip: clip, layer: layer, mapping: mapping)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(.named(Self.space))
        }
        .onChange(of: isDragging) { _, isDragging in
            if !isDragging { endDrag() }
        }
    }

    // MARK: - What's selected

    /// The selected clip and where it shows, while it's showing at the
    /// playhead and playback is paused.
    private var selectedLayer: (Clip, LayerPlacement)? {
        guard !editor.playback.isPlaying, let clip = editor.selectedClip,
              let layer = editor.layerPlacements.last(where: { $0.clipID == clip.id }) else { return nil }
        return (clip, layer)
    }

    /// The effect whose mask is being edited, if it's on this clip and has
    /// one.
    private func editedMask(of clip: Clip) -> Effect? {
        guard let id = editor.timeline.editedMaskEffectID else { return nil }
        return clip.effects.first { $0.id == id && $0.mask != nil }
    }

    private func clipTime(_ clip: Clip) -> CMTime {
        editor.clipTime(in: clip)
    }

    // MARK: - The layer's handles

    @ViewBuilder
    private func transformHandles(clip: Clip, layer: LayerPlacement, mapping: PreviewMapping) -> some View {
        let corners = layer.corners.map(mapping.viewPoint(fromRender:))
        let outline = Path { path in path.addLines(corners); path.closeSubpath() }
        let top = midpoint(corners[0], corners[1])
        let rotateHandle = offset(top, awayFrom: mapping.viewPoint(fromRender: layer.center), by: rotateReach)

        outline
            .fill(.clear)
            .contentShape(outline)
            .gesture(dragging(.transform(.move), clip: clip, mapping: mapping, minimumDistance: 2))
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(Self.space)).onEnded { value in
                tapped(at: value.location, mapping: mapping)
            })
            #if os(macOS)
            .pointerStyle(.grabIdle)
            #endif
        outline
            .stroke(.white, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .allowsHitTesting(false)
        Path { path in path.move(to: top); path.addLine(to: rotateHandle) }
            .stroke(.white, lineWidth: 1)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .allowsHitTesting(false)
        ForEach(corners.indices, id: \.self) { index in
            handle(at: corners[index], shape: .square)
                .gesture(dragging(.transform(.scale), clip: clip, mapping: mapping))
                .accessibilityHidden(true)
        }
        handle(at: rotateHandle, shape: .circle)
            .gesture(dragging(.transform(.rotate), clip: clip, mapping: mapping))
            .accessibilityHidden(true)
    }

    // MARK: - A mask's handles

    @ViewBuilder
    private func maskHandles(clip: Clip, effect: Effect, placement: MaskPlacement, mapping: PreviewMapping) -> some View {
        let layer = placement.layer
        let toView = boxToView(placement, mapping: mapping)
        let box = Path { path in
            path.addLines(placement.corners.map(mapping.viewPoint(fromRender:)))
            path.closeSubpath()
        }
        let shape: Path = switch effect.mask?.shape {
        case .ellipse: Path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 1, height: 1), transform: [toView]))
        case .path: Path(placement.path.cgPath(transform: toView))
        default: box
        }
        let reach = Self.maskReach(handleReach, mapping: mapping)
        let view = { (handle: MaskHandle) in
            mapping.viewPoint(fromRender: placement.point(of: handle, reach: reach))
        }
        let top = view(.resize(x: 0, y: -1))
        let right = view(.resize(x: 1, y: 0))

        box
            .fill(.clear)
            .contentShape(box)
            .gesture(dragging(.mask(effect.id, .move, layer), clip: clip, mapping: mapping, minimumDistance: 2))
            #if os(macOS)
            .pointerStyle(.grabIdle)
            #endif
        if effect.mask?.shape != .rectangle {
            box
                .stroke(.yellow.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
        }
        shape
            .stroke(.yellow, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .allowsHitTesting(false)
        Path { path in
            path.move(to: top)
            path.addLine(to: view(.rotate))
            path.move(to: right)
            path.addLine(to: view(.feather))
        }
        .stroke(.yellow, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        .allowsHitTesting(false)
        ForEach(Self.resizeHandles, id: \.self) { handle in
            self.handle(at: view(handle), shape: .square, color: .yellow)
                .gesture(dragging(.mask(effect.id, handle, layer), clip: clip, mapping: mapping))
                .accessibilityHidden(true)
        }
        handle(at: view(.rotate), shape: .circle, color: .yellow)
            .gesture(dragging(.mask(effect.id, .rotate, layer), clip: clip, mapping: mapping))
            .accessibilityHidden(true)
        handle(at: view(.feather), shape: .diamond, color: .yellow)
            .gesture(dragging(.mask(effect.id, .feather, layer), clip: clip, mapping: mapping))
            .accessibilityHidden(true)
        if effect.mask?.shape == .path {
            ForEach(placement.path.vertices.indices, id: \.self) { index in
                handle(at: view(.vertex(index)), shape: .circle, color: .white)
                    .gesture(dragging(.mask(effect.id, .vertex(index), layer), clip: clip, mapping: mapping))
                    .accessibilityHidden(true)
            }
        }
    }

    /// The box's corners and the middles of its sides.
    private static let resizeHandles: [MaskHandle] = [
        .resize(x: -1, y: -1), .resize(x: 0, y: -1), .resize(x: 1, y: -1), .resize(x: 1, y: 0),
        .resize(x: 1, y: 1), .resize(x: 0, y: 1), .resize(x: -1, y: 1), .resize(x: -1, y: 0),
    ]

    /// The box's own coordinates, (0, 0) at its top-left corner and (1, 1)
    /// at its bottom-right, onto this view's points: one affine transform,
    /// since every step there is one.
    private func boxToView(_ placement: MaskPlacement, mapping: PreviewMapping) -> CGAffineTransform {
        let origin = mapping.viewPoint(fromRender: placement.point(inBox: .zero))
        let across = mapping.viewPoint(fromRender: placement.point(inBox: CGPoint(x: 1, y: 0)))
        let down = mapping.viewPoint(fromRender: placement.point(inBox: CGPoint(x: 0, y: 1)))
        return CGAffineTransform(
            a: across.x - origin.x, b: across.y - origin.y, c: down.x - origin.x, d: down.y - origin.y,
            tx: origin.x, ty: origin.y
        )
    }

    // MARK: - Handles

    private enum HandleShape {
        case square, circle, diamond
    }

    /// A handle drawn at a point, with room around it to take hold of.
    private func handle(at point: CGPoint, shape: HandleShape, color: Color = .white) -> some View {
        ZStack {
            switch shape {
            case .square:
                Rectangle().fill(color).frame(width: handleSize, height: handleSize)
                    .overlay(Rectangle().stroke(.black.opacity(0.5), lineWidth: 0.5))
            case .circle:
                Circle().fill(color).frame(width: handleSize, height: handleSize)
                    .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 0.5))
            case .diamond:
                Rectangle().fill(color).frame(width: handleSize * 0.8, height: handleSize * 0.8)
                    .overlay(Rectangle().stroke(.black.opacity(0.5), lineWidth: 0.5))
                    .rotationEffect(.degrees(45))
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 1)
        .frame(width: hitSize, height: hitSize)
        .contentShape(.rect)
        .position(point)
    }

    // MARK: - Dragging

    private func dragging(
        _ target: Drag.Target, clip: Clip, mapping: PreviewMapping, minimumDistance: Double = 0
    ) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .named(Self.space))
            .updating($isDragging) { _, isDragging, _ in isDragging = true }
            .onChanged { value in
                dragChanged(target, clip: clip, mapping: mapping, from: value.startLocation, to: value.location)
            }
            .onEnded { _ in endDrag() }
    }

    private func dragChanged(
        _ target: Drag.Target, clip: Clip, mapping: PreviewMapping, from start: CGPoint, to end: CGPoint
    ) {
        if drag == nil {
            drag = Drag(clipID: clip.id, target: target, time: clipTime(clip), mapping: mapping)
            editor.beginGesture(Self.actionName(for: target))
        }
        guard let drag else { return }
        let from = drag.mapping.renderPoint(fromView: start)
        let to = drag.mapping.renderPoint(fromView: end)
        let renderSize = editor.project.settings.renderSize
        editor.updateGesture { project in
            project.updateClip(drag.clipID) { clip in
                switch drag.target {
                case .transform(let handle):
                    clip.transform.drag(handle, from: from, to: to, renderSize: renderSize, at: drag.time)
                case .mask(let effectID, let handle, let layer):
                    guard let index = clip.effects.firstIndex(where: { $0.id == effectID }) else { return }
                    clip.effects[index].mask?.drag(
                        handle, from: from, to: to, in: layer, at: drag.time,
                        reach: Self.maskReach(handleReach, mapping: drag.mapping)
                    )
                }
            }
        }
    }

    private func endDrag() {
        guard drag != nil else { return }
        drag = nil
        editor.endGesture()
    }

    private static func actionName(for target: Drag.Target) -> String {
        switch target {
        case .transform(.move): String(localized: "Canvas.Action.Move")
        case .transform(.scale): String(localized: "Canvas.Action.Scale")
        case .transform(.rotate): String(localized: "Canvas.Action.Rotate")
        case .mask: String(localized: "Canvas.Action.EditMask")
        }
    }

    // MARK: - Tapping

    private func tapped(at location: CGPoint, mapping: PreviewMapping) {
        if let onTapPicture {
            onTapPicture(location)
        } else {
            editor.selectLayer(at: mapping.renderPoint(fromView: location))
        }
    }

    // MARK: - Geometry

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// A point moved further from another, by a distance.
    private func offset(_ point: CGPoint, awayFrom center: CGPoint, by distance: Double) -> CGPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let length = hypot(dx, dy)
        guard length > 1e-6 else { return CGPoint(x: point.x, y: point.y - distance) }
        return CGPoint(x: point.x + dx / length * distance, y: point.y + dy / length * distance)
    }
}
