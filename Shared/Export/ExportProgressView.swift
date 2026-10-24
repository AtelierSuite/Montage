import MontageEngine
import SwiftUI

/// The app's exports: what's rendering, with how long it has left, what's
/// waiting, and what's done.
struct ExportProgressView: View {
    let queue: ExportQueue
    /// Saves a file that's waiting for the user to choose where it goes.
    var save: ((ExportJob, URL) -> Void)?

    var body: some View {
        Group {
            if queue.jobs.isEmpty {
                ContentUnavailableView("Export.Progress.Empty", systemImage: "square.and.arrow.up")
            } else {
                List {
                    ForEach(queue.jobs.reversed()) { job in
                        ExportJobRow(job: job, cancel: { queue.cancel(job) }, save: save)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Export.Progress.Clear") { queue.clearFinished() }
                    .disabled(!queue.jobs.contains { !$0.state.isActive })
            }
        }
    }
}

private struct ExportJobRow: View {
    let job: ExportJob
    let cancel: () -> Void
    let save: ((ExportJob, URL) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: job.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.state == .rendering || job.state == .delivering {
                    ProgressView(value: job.progress)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if case .readyToSave(let url) = job.state, let save {
                Button("Export.Progress.Save") { save(job, url) }
                    .buttonStyle(.borderedProminent)
            }
            if job.state.isActive {
                Button("Export.Progress.Cancel", systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var isFailure: Bool {
        if case .failed = job.state { true } else { false }
    }

    private var status: String {
        switch job.state {
        case .queued:
            return String(localized: "Export.Status.Queued")
        case .rendering:
            guard let remaining = job.estimatedTimeRemaining else {
                return String(localized: "Export.Status.Rendering")
            }
            let duration = Duration.seconds(remaining.rounded(.up))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
            return String(format: String(localized: "Export.Status.Remaining"), duration)
        case .delivering:
            return String(localized: "Export.Status.Saving")
        case .readyToSave:
            return String(localized: "Export.Status.ReadyToSave")
        case .finished:
            return String(localized: "Export.Status.Finished")
        case .failed(let message):
            return message
        case .cancelled:
            return String(localized: "Export.Status.Cancelled")
        }
    }
}
