import Foundation
import Photos

/// Saves exports to the user's photo library, asking only to add to it.
enum PhotoLibrary {
    enum SaveError: LocalizedError {
        case notAllowed

        var errorDescription: String? {
            String(localized: "Export.Photos.NotAllowed")
        }
    }

    /// Asks to add to the library, if it hasn't been asked yet. Whether it may.
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Adds the video to the library, moving the file in rather than copying it.
    static func saveVideo(at url: URL) async throws {
        guard await requestAccess() else { throw SaveError.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }
}
