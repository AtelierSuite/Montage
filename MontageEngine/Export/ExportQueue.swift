import Foundation
import Observation
import Synchronization

/// One export, from waiting its turn to its file being delivered.
@MainActor
@Observable
public final class ExportJob: Identifiable {
    public enum State: Equatable {
        /// Waiting for the exports ahead of it.
        case queued
        /// Building the project's composition and rendering it.
        case rendering
        /// Rendered; handing the file to where it goes, such as Photos.
        case delivering
        /// Rendered, with the file waiting for the user to save it somewhere
        /// (such as through the Files exporter on iOS). `discardFile` cleans
        /// it up once they have.
        case readyToSave(URL)
        case finished
        case failed(String)
        case cancelled

        /// Whether the export is still going, or yet to.
        public var isActive: Bool {
            switch self {
            case .queued, .rendering, .delivering: true
            case .readyToSave, .finished, .failed, .cancelled: false
            }
        }
    }

    /// What happens to the file once it's rendered.
    public enum Delivery {
        /// Hand it on (move it to where the user chose, add it to Photos),
        /// then delete what's left of it.
        case deliver(@MainActor (URL) async throws -> Void)
        /// Keep it until `discardFile` is called.
        case hold
    }

    public let id = UUID()
    /// What the job is called in progress lists and notifications: the
    /// project's name.
    public let title: String
    public let settings: ExportSettings
    /// The name the file is given, with its extension.
    public let fileName: String
    public private(set) var state: State = .queued
    /// How much of the render is done, from 0 to 1.
    public private(set) var progress: Double = 0
    /// How long the rest should take, once there's enough to go on.
    public private(set) var estimatedTimeRemaining: TimeInterval?
    /// The conditions the render runs in, set by the app before it starts:
    /// on iOS, whether the GPU stays available in the background.
    public var renderContext = RenderContext()

    @ObservationIgnored let makeSource: @Sendable (RenderContext) async throws -> RenderSource
    @ObservationIgnored let delivery: Delivery
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private var renderStart: Date?
    @ObservationIgnored private var directory: URL?

    init(
        title: String, settings: ExportSettings, delivery: Delivery,
        makeSource: @escaping @Sendable (RenderContext) async throws -> RenderSource
    ) {
        self.title = title
        self.settings = settings
        self.delivery = delivery
        self.makeSource = makeSource
        let base = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        fileName = "\(base.isEmpty ? "Export" : base).\(settings.format.fileExtension)"
    }

    /// Where the job renders to: a folder of its own in the temporary
    /// directory, deleted when the job is done with it.
    func makeOutputURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Exports", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        return directory.appending(path: fileName)
    }

    /// Deletes the job's temporary files: once the file is delivered, or
    /// once the user has saved a file that was held for them.
    public func discardFile() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        if case .readyToSave = state { state = .finished }
    }

    func update(state: State) {
        self.state = state
        switch state {
        case .rendering: renderStart = Date()
        case .delivering, .readyToSave, .finished: progress = 1
        case .queued, .failed, .cancelled: break
        }
        if !state.isActive { estimatedTimeRemaining = nil }
    }

    func update(progress: Double) {
        guard state == .rendering else { return }
        self.progress = progress
        guard let renderStart, progress > 0.02 else { return }
        let elapsed = Date().timeIntervalSince(renderStart)
        estimatedTimeRemaining = max(elapsed / progress * (1 - progress), 0)
    }
}

/// Hears about each export as it goes: the app uses it to keep exports
/// running in the background and to say when they're done.
@MainActor
public protocol ExportQueueObserver: AnyObject {
    /// Just before the job renders; can set its `renderContext`.
    func exportWillStart(_ job: ExportJob)
    func exportDidProgress(_ job: ExportJob)
    /// The job finished, failed or was cancelled.
    func exportDidEnd(_ job: ExportJob)
}

/// Exports one at a time, in the order they were asked for, for the whole
/// app: a job carries on whether or not the window it came from is still
/// open.
@MainActor
@Observable
public final class ExportQueue {
    public private(set) var jobs: [ExportJob] = []
    public let exporter: Exporter
    @ObservationIgnored public var observers: [any ExportQueueObserver] = []
    @ObservationIgnored private var runner: Task<Void, Never>?

    public init(exporter: Exporter) {
        self.exporter = exporter
    }

    /// Whether any export is rendering or waiting to.
    public var hasActiveJobs: Bool { jobs.contains { $0.state.isActive } }

    /// Queues an export.
    ///
    /// - Parameter makeSource: Makes what to render, when the job's turn
    ///   comes: for a project, its built composition (`RenderSource(_:)`).
    @discardableResult
    public func enqueue(
        title: String, settings: ExportSettings, delivery: ExportJob.Delivery,
        makeSource: @escaping @Sendable (RenderContext) async throws -> RenderSource
    ) -> ExportJob {
        let job = ExportJob(title: title, settings: settings, delivery: delivery, makeSource: makeSource)
        jobs.append(job)
        startRunning()
        return job
    }

    /// Stops a job, whether it's rendering or still waiting.
    public func cancel(_ job: ExportJob) {
        switch job.state {
        case .queued:
            job.update(state: .cancelled)
            notifyEnd(job)
        case .rendering, .delivering:
            job.task?.cancel()
        case .readyToSave:
            job.discardFile()
        case .finished, .failed, .cancelled:
            break
        }
    }

    public func cancelAll() {
        jobs.forEach(cancel)
    }

    /// Takes jobs that are done off the list, discarding any files still held.
    public func clearFinished() {
        for job in jobs where !job.state.isActive { job.discardFile() }
        jobs.removeAll { !$0.state.isActive }
    }

    private func startRunning() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, let job = self.jobs.first(where: { $0.state == .queued }) {
                await self.run(job)
            }
            self?.runner = nil
        }
    }

    private func run(_ job: ExportJob) async {
        for observer in observers { observer.exportWillStart(job) }
        job.update(state: .rendering)
        let exporter = self.exporter
        let context = job.renderContext
        let progress = ProgressRelay(job: job, queue: self)
        let task = Task { @MainActor in
            do {
                let url = try job.makeOutputURL()
                let source = try await job.makeSource(context)
                try await exporter.export(source, settings: job.settings, to: url) { progress.report($0) }
                try Task.checkCancellation()
                switch job.delivery {
                case .hold:
                    job.update(state: .readyToSave(url))
                case .deliver(let deliver):
                    job.update(state: .delivering)
                    try await deliver(url)
                    job.discardFile()
                    job.update(state: .finished)
                }
            } catch is CancellationError {
                job.discardFile()
                job.update(state: .cancelled)
            } catch {
                job.discardFile()
                job.update(state: Task.isCancelled ? .cancelled : .failed(Self.message(for: error)))
            }
        }
        job.task = task
        await task.value
        job.task = nil
        notifyEnd(job)
    }

    private func notifyEnd(_ job: ExportJob) {
        for observer in observers { observer.exportDidEnd(job) }
    }

    fileprivate func didProgress(_ job: ExportJob) {
        for observer in observers { observer.exportDidProgress(job) }
    }

    private static func message(for error: any Error) -> String {
        let error = error as NSError
        return [error.localizedDescription, error.localizedFailureReason].compactMap(\.self).joined(separator: " ")
    }
}

/// Brings progress from the export's thread to the main actor, a hundred
/// steps at most, so the UI isn't flooded with updates.
private final class ProgressRelay: Sendable {
    private let lastStep = Mutex(-1)
    private let job: ExportJob
    private weak let queue: ExportQueue?

    init(job: ExportJob, queue: ExportQueue) {
        self.job = job
        self.queue = queue
    }

    func report(_ value: Double) {
        let step = Int(value * 100)
        let isNewStep = lastStep.withLock { last in
            guard step > last else { return false }
            last = step
            return true
        }
        guard isNewStep else { return }
        Task { @MainActor in
            job.update(progress: value)
            queue?.didProgress(job)
        }
    }
}
