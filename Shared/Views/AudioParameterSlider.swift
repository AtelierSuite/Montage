import CoreMedia
import MontageEngine
import SwiftUI

/// A slider for one of an audio effect's `Animatable` parameters, with its value
/// beside it.
///
/// While it's dragged, each step goes to `onPreview`, so it's heard (or seen)
/// at once; the step that ends the drag goes to `onCommit`, which makes the
/// one undo step. A change made without a drag, such as with the arrow keys,
/// is committed straight away.
struct AudioParameterSlider: View {
    enum Scale {
        case linear
        /// For frequencies: equal steps along the slider multiply the value.
        case logarithmic
    }

    let title: LocalizedStringKey
    let value: Double
    let range: ClosedRange<Double>
    var scale = Scale.linear
    let format: (Double) -> String
    let onPreview: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var draft: Double?
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: format(draft ?? value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: position, in: positionRange) { editing in
                isEditing = editing
                if !editing, let draft {
                    onCommit(draft)
                    self.draft = nil
                }
            }
            .labelsHidden()
        }
    }

    /// The slider's own position, which is the value itself unless the
    /// scale is logarithmic.
    private var position: Binding<Double> {
        Binding {
            toPosition(min(max(draft ?? value, range.lowerBound), range.upperBound))
        } set: { position in
            let value = fromPosition(position)
            if isEditing {
                draft = value
                onPreview(value)
            } else {
                onCommit(value)
            }
        }
    }

    private var positionRange: ClosedRange<Double> {
        toPosition(range.lowerBound)...toPosition(range.upperBound)
    }

    private func toPosition(_ value: Double) -> Double {
        scale == .logarithmic ? log10(value) : value
    }

    private func fromPosition(_ position: Double) -> Double {
        scale == .logarithmic ? pow(10, position) : position
    }
}
