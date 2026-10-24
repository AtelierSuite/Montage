import Synchronization

/// The project as it is right now, readable from any thread.
///
/// Rendering doesn't happen on the main actor: the video compositor draws
/// frames on AVFoundation's queues and audio taps run on the audio thread. They
/// read clip parameters from here, so an edit that only changes a parameter
/// (an effect's value, a keyframe) shows on the next frame without the
/// composition being built again. The playback controller puts each edit in
/// as soon as it's made.
///
/// The project is a value, so what a reader gets is a consistent copy that
/// later edits can't change; the lock is only held to copy it.
public final class ProjectSnapshot: Sendable {
    private let current: Mutex<Project>

    public init(_ project: Project) {
        current = Mutex(project)
    }

    /// The project as of the latest edit.
    public var project: Project {
        current.withLock { $0 }
    }

    /// Reads part of the project without copying the rest, such as one clip's
    /// parameters. Keep `body` short: writers wait while it runs.
    public func read<Result: Sendable>(_ body: (borrowing Project) -> Result) -> Result {
        current.withLock { body($0) }
    }

    /// Like `read`, but gives up rather than waits while an edit is being put
    /// in, returning nil: for the audio thread, which mustn't wait on a lock.
    public func readIfAvailable<Result: Sendable>(_ body: (borrowing Project) -> Result) -> Result? {
        current.withLockIfAvailable { body($0) }
    }

    public func update(_ project: Project) {
        current.withLock { $0 = project }
    }
}
