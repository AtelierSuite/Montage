import AVFoundation
import CoreImage
import Metal
import Synchronization

/// Draws every frame of a built composition, for preview and export alike.
///
/// AVFoundation makes one per player item or reader and hands it a request
/// for each frame, carrying a `CompositorInstruction`. For each, the
/// compositor reads the layers' clips from the instruction's snapshot,
/// evaluates their keyframes at the frame's time, has `FrameComposer` put
/// the frame together, and renders it into a buffer from the render
/// context's pool.
///
/// Frames are rendered one at a time on a queue of the compositor's own,
/// with Core Image contexts shared by every compositor, made once: making
/// one is slow, and each holds on to caches and GPU resources.
final class VideoCompositor: NSObject, AVVideoCompositing {
    /// Shared by every compositor; a context is safe to render with from
    /// several threads at once.
    private static let gpuContext = makeContext(usingGPU: true)
    /// For exports that mustn't use the GPU.
    private static let cpuContext = makeContext(usingGPU: false)

    /// Colours pass through as they're stored: frames are blended
    /// gamma-encoded, as AVFoundation's own compositor and most editors do,
    /// and come out the way they went in where nothing changes them.
    private static func makeContext(usingGPU: Bool) -> CIContext {
        var options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
            .name: usingGPU ? "Montage compositor" : "Montage compositor (CPU)",
        ]
        if usingGPU, let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        options[.useSoftwareRenderer] = true
        return CIContext(options: options)
    }

    private static let pixelFormat: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = VideoCompositor.pixelFormat
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = VideoCompositor.pixelFormat

    private let queue = DispatchQueue(label: "Montage.VideoCompositor", qos: .userInitiated)
    /// Raised by each cancellation; a request made before it was raised is
    /// finished as cancelled rather than drawn.
    private let generation = Mutex(0)

    /// Each request brings its own render context, so there's nothing to keep.
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let started = generation.withLock { $0 }
        queue.async { [self] in
            guard generation.withLock({ $0 }) == started else {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                render(request)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        generation.withLock { $0 += 1 }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CompositorInstruction else {
            request.finish(with: CompositorError.unexpectedInstruction)
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: CompositorError.noBuffer)
            return
        }
        let outputSize = CGSize(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))

        // The clips as they are now; one that's gone since the build is drawn
        // as it was until the rebuild that drops it is swapped in.
        let layers = instruction.layers
        let clips = instruction.snapshot.read { project in
            layers.map { project.clip(id: $0.clip.id)?.clip }
        }
        let frameLayers = zip(layers, clips).compactMap { layer, clip -> FrameComposer.Layer? in
            let image: CIImage? = if let still = layer.still {
                still.picture(for: instruction.renderSize)
            } else {
                request.sourceFrame(byTrackID: layer.trackID).map { CIImage(cvPixelBuffer: $0) }
            }
            guard let image else { return nil }
            return FrameComposer.Layer(image: image, layer: layer, clip: clip ?? layer.clip)
        }
        let image = FrameComposer.compose(
            frameLayers, at: request.compositionTime, renderSize: instruction.renderSize, outputSize: outputSize
        )
        let context = instruction.usesGPU ? Self.gpuContext : Self.cpuContext
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: nil)
        request.finish(withComposedVideoFrame: output)
    }
}

enum CompositorError: Error {
    /// The request's instruction isn't one the compositor made.
    case unexpectedInstruction
    /// The render context had no buffer to draw into.
    case noBuffer
}
