import SwiftUI

/// A divider that can be dragged to share room between the views either side
/// of it: a hairline, with a grip just inside the leading or top view's edge
/// to show where to take hold of it.
///
/// It takes a hairline's room in the layout, but catches touches across a
/// thumb's width: its touch area overhangs the views either side, mostly the
/// one with the grip, by as much as each can spare without losing touches of
/// its own, and it sits above them so the overhang wins there.
///
/// Reports how far it has been dragged since the drag began; the owner works
/// out the sizes, and keeps them within bounds.
struct ResizeHandle: View {
    /// Which way the views sit: `.horizontal` for views side by side, so the
    /// handle runs top to bottom and drags sideways.
    let axis: Axis
    /// The drag's distance along the axis so far, as it moves.
    let onDrag: (Double) -> Void
    var onEnd: () -> Void = {}
    /// Moves the divider a step for assistive technologies: positive towards
    /// the trailing or bottom view.
    var onStep: (Double) -> Void = { _ in }
    /// How far the touch area reaches over the leading or top view, and over
    /// the trailing or bottom one: a thumb's width between them.
    fileprivate var overhang: (before: Double, after: Double) = (22, 22)
    /// Whether the grip is drawn over something dark, such as the black
    /// around the preview, and so drawn light.
    fileprivate var isGripOverDark = false

    /// How far into the leading or top view the grip's middle sits.
    private let gripInset = 8.0

    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
            .overlay {
                Capsule()
                    .fill(gripStyle)
                    .frame(width: axis == .horizontal ? 5 : 36, height: axis == .horizontal ? 36 : 5)
                    .offset(x: axis == .horizontal ? -gripInset : 0, y: axis == .vertical ? -gripInset : 0)
            }
            .contentShape(TouchArea(axis: axis, before: overhang.before, after: overhang.after))
            .zIndex(1)
            #if os(macOS)
            .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
            #endif
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        isDragging = true
                        onDrag(axis == .horizontal ? value.translation.width : value.translation.height)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEnd()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Editor.Divider"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onStep(24)
                case .decrement: onStep(-24)
                @unknown default: break
                }
            }
    }

    private var gripStyle: AnyShapeStyle {
        if isDragging { return AnyShapeStyle(Color.accentColor) }
        return isGripOverDark ? AnyShapeStyle(Color.white.opacity(0.4)) : AnyShapeStyle(.tertiary)
    }
}

extension ResizeHandle {
    /// Sets how far the touch area reaches over the views either side.
    func overhang(before: Double, after: Double) -> ResizeHandle {
        var handle = self
        handle.overhang = (before, after)
        return handle
    }

    /// Draws the grip light, for a dark view.
    func gripOverDark() -> ResizeHandle {
        var handle = self
        handle.isGripOverDark = true
        return handle
    }
}

/// The handle's bounds, reaching further along the drag on either side.
private struct TouchArea: Shape {
    let axis: Axis
    let before: Double
    let after: Double

    func path(in rect: CGRect) -> Path {
        Path(axis == .horizontal
            ? CGRect(x: rect.minX - before, y: rect.minY, width: rect.width + before + after, height: rect.height)
            : CGRect(x: rect.minX, y: rect.minY - before, width: rect.width, height: rect.height + before + after))
    }
}
