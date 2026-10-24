import CoreTransferable
import Foundation
import MontageEngine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Media from a project's library, dragged within the app: which items,
    /// not their files.
    static let montageMediaReference = UTType(exportedAs: "com.tsubuzaki.Montage.media-reference")
}

/// What dragging from the library carries: the media items, in library
/// order. Drop targets in the editor, such as the timeline, take it with
/// `.dropDestination(for: MediaDragPayload.self)` and add the items through
/// `ProjectEditor.insertMedia(_:at:onTrack:)`.
struct MediaDragPayload: Codable, Transferable {
    var mediaIDs: [MediaItem.ID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .montageMediaReference)
    }
}

extension View {
    /// Takes media dragged from the library, adding it to the end of the
    /// timeline: a drop anywhere over the editor that nothing nearer takes,
    /// such as the timeline placing it where it's dropped.
    func libraryDropDestination(_ editor: ProjectEditor) -> some View {
        dropDestination(for: MediaDragPayload.self) { payloads, _ in
            let ids = payloads.flatMap(\.mediaIDs).filter { editor.project.mediaItem(id: $0) != nil }
            guard !ids.isEmpty else { return false }
            editor.addToTimeline(ids)
            return true
        }
    }
}
