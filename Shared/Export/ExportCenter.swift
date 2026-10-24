import MontageEngine
import MontageFormats

/// The app's one export queue, shared by every open project, so an export
/// carries on after the project it came from is closed.
@MainActor
enum ExportCenter {
    static let queue: ExportQueue = {
        let queue = ExportQueue(exporter: Exporter(aviSinkFactory: AVIWriter.encodedFrameSinkFactory))
        queue.observers.append(ExportNotifier())
        return queue
    }()
}
