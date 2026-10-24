import CoreGraphics
import CoreVideo
import VideoToolbox

/// Scales rendered frames to the export's size, keeping their shape, through
/// VideoToolbox so it runs on the hardware scaler where there is one.
final class FrameScaler {
    private let session: VTPixelTransferSession
    private var pool: CVPixelBufferPool?
    let size: CGSize

    init(size: CGSize) throws {
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard status == noErr, let session else { throw ExportError.encoderFailed(status) }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        self.session = session
        self.size = size
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    /// The frame at the export's size; the frame itself where it's already
    /// that size.
    func scale(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = Int(size.width), height = Int(size.height)
        if CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height { return source }
        let pool = try self.pool ?? makePool(format: CVPixelBufferGetPixelFormatType(source), width: width, height: height)
        self.pool = pool
        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard let destination else { throw ExportError.encoderFailed(kCVReturnAllocationFailed) }
        // Keep the frame's colour tagging through the scale.
        CVBufferPropagateAttachments(source, destination)
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else { throw ExportError.encoderFailed(status) }
        return destination
    }

    private func makePool(format: OSType, width: Int, height: Int) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw ExportError.encoderFailed(status) }
        return pool
    }
}
