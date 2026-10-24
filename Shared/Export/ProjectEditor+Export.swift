import MontageEngine

extension ProjectEditor {
    /// Whether there's anything to export: a timeline with clips on it.
    var canExport: Bool {
        !project.tracks.allSatisfy { $0.clips.isEmpty }
    }

    /// What an export of the project as it is now renders: the composition
    /// preview plays, built from a snapshot of the project, so edits made
    /// while it waits or renders don't change it.
    func makeRenderSource() -> @Sendable (RenderContext) async throws -> RenderSource {
        let builder = CompositionBuilder(project: project, mediaResolver: mediaResolver)
        return { context in
            // TODO: (#8) once the custom compositor exists, have it render on
            // the CPU when `context.allowsGPU` is false (an iOS export kept
            // going in the background without the GPU).
            _ = context
            let built = try await builder.build()
            guard !built.isEmpty else { throw ExportError.nothingToExport }
            return RenderSource(built)
        }
    }
}
