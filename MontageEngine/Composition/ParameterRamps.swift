import CoreMedia

/// A parameter going from one value to another over a stretch of the
/// timeline, in the shape AVFoundation's opacity and volume ramps take.
struct ParameterRamp: Equatable {
    var timeRange: CMTimeRange
    var start: Double
    var end: Double
}

extension Animatable<Double> {
    /// How many straight pieces an eased stretch between two keyframes is cut
    /// into, since AVFoundation's ramps only go in straight lines.
    static var easedPieces: Int { 8 }

    /// The parameter over part of a clip as straight ramps, in timeline time.
    /// `range` is the part of the timeline, and `clipStart` where the clip
    /// starts, since keyframes are timed from there.
    ///
    /// A parameter without keyframes is one value throughout, and has no
    /// ramps. A keyframed one is cut at its keyframes, eased stretches into
    /// several pieces; held stretches keep their value to the next keyframe.
    func ramps(over range: CMTimeRange, clipStart: CMTime) -> [ParameterRamp] {
        guard isAnimated, range.duration > .zero else { return [] }
        let start = range.start - clipStart
        let end = range.end - clipStart
        var cuts = [start]
        cuts += keyframes.map(\.time).filter { $0 > start && $0 < end }
        cuts.append(end)

        var ramps: [ParameterRamp] = []
        for (from, to) in zip(cuts, cuts.dropFirst()) {
            // The keyframe the stretch starts from says how it travels; before
            // the first keyframe and after the last, the value holds.
            let interpolation = keyframes.last { $0.time <= from }.flatMap { keyframe in
                keyframe.time < keyframes.last!.time ? keyframe.interpolation : nil
            }
            let pieces: Int
            switch interpolation {
            case nil, .hold:
                let held = value(at: from)
                ramps.append(ParameterRamp(timeRange: CMTimeRange(start: from + clipStart, end: to + clipStart), start: held, end: held))
                continue
            case .linear: pieces = 1
            case .easeIn, .easeOut, .easeInOut, .bezier: pieces = Self.easedPieces
            }
            let span = to - from
            for piece in 0..<pieces {
                let pieceStart = from + CMTimeMultiplyByRatio(span, multiplier: Int32(piece), divisor: Int32(pieces))
                let pieceEnd = piece == pieces - 1
                    ? to : from + CMTimeMultiplyByRatio(span, multiplier: Int32(piece + 1), divisor: Int32(pieces))
                ramps.append(ParameterRamp(
                    timeRange: CMTimeRange(start: pieceStart + clipStart, end: pieceEnd + clipStart),
                    start: value(at: pieceStart), end: value(at: pieceEnd)
                ))
            }
        }
        return ramps
    }
}
