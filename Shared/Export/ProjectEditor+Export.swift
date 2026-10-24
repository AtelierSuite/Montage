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
        let project = project, resolver = mediaResolver, derivedMedia = derivedMedia
        return { context in
            // Mono media that's panned plays from a stereo copy, made now if
            // it hasn't been yet.
            await derivedMedia.makeAll(.stereoAudio, neededIn: project, resolver: resolver)
            try Task.checkCancellation()
            var builder = CompositionBuilder(project: project, mediaResolver: resolver.findingDerivedMedia(in: derivedMedia.store))
            // On the CPU when the GPU may go, such as an iOS export kept going
            // in the background.
            builder.usesGPU = context.allowsGPU
            let built = try await builder.build()
            guard !built.isEmpty else { throw ExportError.nothingToExport }
            return RenderSource(built)
        }
    }
}
