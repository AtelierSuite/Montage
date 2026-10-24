import CoreMedia
import MontageEngine
import SwiftUI

/// The choices for an export, with how big the file should come out. Rows
/// for a form: the iOS export sheet puts them in a section, the Mac save
/// panel's accessory in a form of its own.
struct ExportOptionsForm: View {
    @Binding var settings: ExportSettings
    /// The formats to offer: AVI isn't, for Photos.
    var formats: [ExportFormat] = ExportFormat.allCases
    let projectSettings: ProjectSettings
    let duration: CMTime

    var body: some View {
        Picker("Export.Format", selection: $settings.format) {
            ForEach(formats, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        Picker("Export.Codec", selection: $settings.codec) {
            ForEach(settings.format.videoCodecs, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        Picker("Export.Resolution", selection: $settings.resolution) {
            ForEach(ExportResolution.options(for: projectSettings.renderSize), id: \.self) {
                Text(verbatim: $0.title(for: projectSettings.renderSize)).tag($0)
            }
        }
        Picker("Export.FrameRate", selection: $settings.frameRate) {
            ForEach(ExportFrameRate.standard, id: \.self) {
                Text(verbatim: $0.title(projectFrameDuration: projectSettings.frameDuration)).tag($0)
            }
        }
        Picker("Export.Quality", selection: $settings.quality) {
            ForEach(ExportQuality.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        LabeledContent("Export.EstimatedSize") {
            Text(verbatim: estimate)
                .monospacedDigit()
        }
    }

    private var estimate: String {
        let bytes = settings.estimatedFileSize(
            duration: duration, renderSize: projectSettings.renderSize, frameDuration: projectSettings.frameDuration
        )
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(format: String(localized: "Export.EstimatedSize.Value"), size)
    }
}
