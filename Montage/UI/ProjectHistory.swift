import SwiftUI

/// Undo and redo for a document, as the toolbar shows them.
///
/// Follows the document's undo manager, so the buttons are enabled whenever
/// it has a step to take, whatever registered it.
@MainActor
@Observable
final class ProjectHistory {
    private(set) var canUndo = false
    private(set) var canRedo = false

    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func attach(to undoManager: UndoManager?) {
        guard undoManager !== self.undoManager else { return }
        self.undoManager = undoManager
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let undoManager else { return refresh() }
        // Any change to the stacks is a reason to look again.
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func undo() {
        undoManager?.undo()
        refresh()
    }

    func redo() {
        undoManager?.redo()
        refresh()
    }

    private func refresh() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }
}
