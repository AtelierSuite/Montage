import BackgroundTasks
import MontageEngine
import os

/// Keeps each export going when the user leaves the app, as a continued
/// processing task: the system shows its progress and a button to stop it.
///
/// The export runs in the app's queue either way; the task only keeps the app
/// running while it does. Each export submits a task of its own, under an
/// identifier made from the permitted `<bundle ID>.export.*`, registering
/// its handler just before (continued processing tasks may be registered
/// after launch, but a wildcard identifier can't have one handler for all).
/// Where the system won't take the task, the export carries on in the
/// foreground only.
@MainActor
final class BackgroundExports: ExportQueueObserver {
    private let queue: ExportQueue
    private var tasks: [ExportJob.ID: BGContinuedProcessingTask] = [:]
    private static let progressUnits: Int64 = 1000
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Montage", category: "Export")

    init(queue: ExportQueue) {
        self.queue = queue
    }

    func exportWillStart(_ job: ExportJob) {
        let identifier = "\(Bundle.main.bundleIdentifier ?? "com.tsubuzaki.Montage").export.\(job.id.uuidString)"
        // Rendering in the background keeps the GPU only on devices that
        // support it, and with the background GPU entitlement. Without it,
        // the export must be able to render without the GPU.
        let keepsGPU = BGTaskScheduler.supportedResources.contains(.gpu)
        job.renderContext.allowsGPU = keepsGPU

        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.attach(task, to: job)
            }
        }
        guard registered else {
            Self.log.error("Couldn't register the background task \(identifier, privacy: .public)")
            job.renderContext.allowsGPU = true
            return
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: job.fileName, subtitle: String(localized: "Export.Background.Subtitle")
        )
        // Start now or not at all: the export is starting either way.
        request.strategy = .fail
        if keepsGPU { request.requiredResources = .gpu }
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.log.error("Couldn't submit the background task: \(error.localizedDescription, privacy: .public)")
            // In the foreground only, the GPU is there throughout.
            job.renderContext.allowsGPU = true
        }
    }

    func exportDidProgress(_ job: ExportJob) {
        guard let task = tasks[job.id] else { return }
        task.progress.completedUnitCount = Int64(job.progress * Double(Self.progressUnits))
    }

    func exportDidEnd(_ job: ExportJob) {
        guard let task = tasks.removeValue(forKey: job.id) else { return }
        finish(task, for: job)
    }

    private func attach(_ task: BGContinuedProcessingTask, to job: ExportJob) {
        task.progress.totalUnitCount = Self.progressUnits
        task.progress.completedUnitCount = Int64(job.progress * Double(Self.progressUnits))
        // The job may have ended before the system started the task.
        guard job.state.isActive else {
            finish(task, for: job)
            return
        }
        tasks[job.id] = task
        // The system stopping the task, or the user stopping it from its
        // progress UI, stops the export; it then completes, unsuccessfully.
        task.expirationHandler = { [weak queue] in
            Task { @MainActor in queue?.cancel(job) }
        }
    }

    private func finish(_ task: BGContinuedProcessingTask, for job: ExportJob) {
        switch job.state {
        case .finished, .readyToSave:
            task.progress.completedUnitCount = Self.progressUnits
            task.setTaskCompleted(success: true)
        default:
            task.setTaskCompleted(success: false)
        }
    }
}
