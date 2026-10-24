import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine

// How export options are named in the export sheet and the save panel.

extension ExportFormat {
    var title: String {
        switch self {
        case .mp4: "MP4"
        case .avi: "AVI"
        }
    }
}

extension ExportVideoCodec {
    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .motionJPEG: "Motion JPEG"
        }
    }
}

extension ExportResolution {
    func title(for renderSize: CGSize) -> String {
        let size = self.size(for: renderSize)
        let dimensions = "\(Int(size.width)) × \(Int(size.height))"
        switch self {
        case .project:
            return String(format: String(localized: "Export.Resolution.Project"), dimensions)
        case .shortSide(let side):
            return "\(side)p (\(dimensions))"
        }
    }
}

extension ExportFrameRate {
    func title(projectFrameDuration: CMTime) -> String {
        switch self {
        case .project:
            let rate = 1 / frameDuration(project: projectFrameDuration).seconds
            return String(format: String(localized: "Export.FrameRate.Project"), rate.formatted(.number.precision(.fractionLength(0...2))))
        case .fps(let rate):
            return String(format: String(localized: "Export.FrameRate.FPS"), rate)
        }
    }
}

extension ExportQuality {
    var title: String {
        switch self {
        case .low: String(localized: "Export.Quality.Low")
        case .medium: String(localized: "Export.Quality.Medium")
        case .high: String(localized: "Export.Quality.High")
        case .maximum: String(localized: "Export.Quality.Maximum")
        }
    }
}
