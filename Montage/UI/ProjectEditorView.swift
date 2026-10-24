import SwiftUI

/// A project open for editing. Laid out for iPhone first: the editor takes
/// the whole screen with its controls in a bar floating over the bottom, and
/// the library and inspector come up over it. With the room of an iPad, the
/// library stays beside the editor as a sidebar and the inspector as a
/// column on the other side.
struct ProjectEditorView: View {
    @Binding var document: MontageDocument
    /// Where the document is: set once it's first saved, and changed when
    /// it's renamed or moved.
    var fileURL: URL?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.undoManager) private var undoManager
    @State private var editor: ProjectEditor
    @State private var importer: MediaImporter
    @State private var history = ProjectHistory()
    @State private var isShowingLibrary = false
    @State private var isShowingInspector = false
    @State private var isShowingFullscreen = false
    /// Whether the preview floats over the editor, picture in picture,
    /// rather than having its place in the layout.
    @State private var isPreviewFloating = false
    /// Whether the floating preview is on its way back into the editor,
    /// whose preview has its place again, waiting for it.
    @State private var isDockingPreview = false
    /// Where the preview's picture is on screen, for the floating preview to
    /// move out of and back into.
    @State private var previewFrame = CGRect.zero
    @State private var floatingLaunchFrame: CGRect?
    /// Where the full-screen player zooms out of.
    @Namespace private var previewTransition
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all
    @State private var isShowingExport = false
    @State private var isShowingExports = false
    @State private var isImportingProject = false
    @State private var isExportingFCPXML = false
    /// The document's location while it's being read from, for media in it.
    @State private var accessedURL: URL?

    init(document: Binding<MontageDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        let media = document.wrappedValue.media
        media.packageURL = fileURL
        document.wrappedValue.cache.packageURL = fileURL
        let editor = ProjectEditor(
            project: document.wrappedValue.project, mediaResolver: media.resolver, cache: document.wrappedValue.cache
        )
        _editor = State(initialValue: editor)
        _importer = State(initialValue: MediaImporter(store: media, editor: editor))
    }

    var body: some View {
        layout
            .environment(editor)
            .environment(importer)
            .onAppear {
                attach(to: undoManager)
                // Every edit goes back into the document, which marks it
                // as changed so it's saved.
                editor.onChange = { [$document] project in $document.wrappedValue.project = project }
                editor.takeRefreshedBookmarks = { [media = document.media] in media.bookmarks.takeRefreshedBookmarks() }
                locateMedia(at: fileURL)
            }
            .onChange(of: undoManager) { _, undoManager in attach(to: undoManager) }
            // Closing the document; the player goes with the editor.
            .onDisappear { editor.playback.pause() }
            // Reverting, or another device's changes arriving, replace the
            // document from outside the editor.
            .onChange(of: document.project) { _, project in editor.replace(with: project) }
            // Media is found in the package wherever it's moved to.
            .onChange(of: fileURL) { _, fileURL in locateMedia(at: fileURL) }
            .onChange(of: ObjectIdentifier(document.media)) { _, _ in locateMedia(at: fileURL) }
            .onDisappear {
                // Only the access is given up: the package is still where it is.
                accessedURL?.stopAccessingSecurityScopedResource()
                accessedURL = nil
            }
    }

    /// Tells the document's media where the package is, keeping access to a
    /// package from another app's storage for as long as it's open here.
    private func locateMedia(at url: URL?) {
        if accessedURL != url {
            accessedURL?.stopAccessingSecurityScopedResource()
            accessedURL = url?.startAccessingSecurityScopedResource() == true ? url : nil
        }
        document.media.packageURL = url
        document.cache.packageURL = url
        editor.mediaResolver = document.media.resolver
        importer.store = document.media
    }

    private func attach(to undoManager: UndoManager?) {
        editor.undoManager = undoManager
        history.attach(to: undoManager)
    }

    @ViewBuilder
    private var layout: some View {
        if horizontalSizeClass == .compact {
            editorArea
                .sheet(isPresented: $isShowingLibrary) {
                    NavigationStack {
                        LibraryView()
                            .navigationTitle("Library.Title")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .presentationDetents([.medium, .large])
                }
        } else {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                LibraryView()
                    .navigationTitle("Library.Title")
            } detail: {
                editorArea
            }
        }
    }

    private var editorArea: some View {
        Group {
            if verticalSizeClass == .compact {
                // An iPhone held sideways: the preview and its controls in a
                // column, beside a timeline with the whole height.
                EditorView(showsPreview: !isPreviewFloating || isDockingPreview) {
                    EditorActionPanel(showLibrary: showLibrary, isShowingInspector: $isShowingInspector)
                }
                .background { floatingPreview }
            } else {
                EditorView(showsControlBar: false, showsPreview: !isPreviewFloating || isDockingPreview)
                    .background { floatingPreview }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        EditorActionBar(showLibrary: showLibrary, isShowingInspector: $isShowingInspector)
                            .padding(.bottom, 8)
                    }
            }
        }
        // The preview's playback controls are over it, with buttons to show it
        // full screen and to float it.
        .environment(\.expandPreview, PreviewAction { isShowingFullscreen = true })
        .environment(\.floatPreview, PreviewAction { setPreviewFloating(true) })
        .environment(\.previewFrameReporter, PreviewFrameReporter { previewFrame = $0 })
        .environment(\.hidesPreviewPicture, isDockingPreview)
        .environment(\.showsPlaybackOverlay, true)
        .environment(\.previewTransition, PreviewTransition(id: "preview", namespace: previewTransition))
        .fullScreenCover(isPresented: $isShowingFullscreen) {
            FullscreenPlayerView(playback: editor.playback)
                .navigationTransition(.zoom(sourceID: "preview", in: previewTransition))
        }
        .inspector(isPresented: $isShowingInspector) {
            InspectorView()
                .presentationDetents([.medium, .large])
        }
        .toolbar { editorToolbar }
        .sheet(isPresented: $isShowingExport) {
            ExportSheet(editor: editor, title: projectTitle) { isShowingExports = true }
        }
        .sheet(isPresented: $isShowingExports) {
            ExportsSheet(queue: ExportCenter.queue)
                .presentationDetents([.medium, .large])
        }
        .projectInterchange(
            editor: editor, importer: importer, title: projectTitle,
            isImporting: $isImportingProject, isExporting: $isExportingFCPXML
        )
    }

    /// The floating preview, in a window over the whole app, while it
    /// floats. It goes full screen in its own window.
    @ViewBuilder
    private var floatingPreview: some View {
        if isPreviewFloating && editor.playback.hasContent {
            FloatingPreviewWindow(preview: FloatingPreview(
                playback: editor.playback, aspectRatio: previewAspectRatio,
                onDock: { setPreviewFloating(false) },
                // Clear of the bar along the bottom, where there is one.
                reservedBottom: verticalSizeClass == .compact ? 0 : 76,
                launchFrame: floatingLaunchFrame,
                dockFrame: isDockingPreview && previewFrame != .zero ? previewFrame : nil,
                // Sideways, the preview keeps to a rounded frame.
                dockedCornerRadius: verticalSizeClass == .compact ? 10 : 0,
                onDocked: {
                    isPreviewFloating = false
                    isDockingPreview = false
                }
            ))
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }

    /// Floats the preview out of the editor, from where it is, or sends it
    /// back: the editor makes room for it, and it moves in.
    private func setPreviewFloating(_ floating: Bool) {
        if floating {
            floatingLaunchFrame = previewFrame == .zero ? nil : previewFrame
            withAnimation(.spring(duration: 0.45, bounce: 0.12)) { isPreviewFloating = true }
        } else {
            previewFrame = .zero
            withAnimation(.spring(duration: 0.45, bounce: 0.12)) { isDockingPreview = true }
        }
    }

    /// The project's frame shape, or 16:9 if its settings have none.
    private var previewAspectRatio: Double {
        let size = editor.project.settings.renderSize
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9
    }

    /// Opens the library, where it's not already beside the editor in an
    /// iPad's sidebar.
    private var showLibrary: (() -> Void)? {
        horizontalSizeClass == .compact ? { isShowingLibrary = true } : nil
    }

    /// The project's name, for the files exported from it.
    private var projectTitle: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Export.Untitled")
    }

    // MARK: - Toolbar

    /// Undo and Redo, then the "…" menu, on the trailing edge of the bar.
    /// Everything else lives in the bar along the bottom.
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        // Pinned to the trailing edge: as primary actions the bar would fold
        // Redo into its own overflow menu once it ran short of room.
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Toolbar.Undo", systemImage: "arrow.uturn.backward") { history.undo() }
                .disabled(!history.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("undo")
            Button("Toolbar.Redo", systemImage: "arrow.uturn.forward") { history.redo() }
                .disabled(!history.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .accessibilityIdentifier("redo")
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) { moreMenu }
    }

    /// The "…" menu. A menu of its own rather than secondary actions, which an
    /// iPad's document bar lays out across the middle instead of folding away.
    private var moreMenu: some View {
        Menu("Toolbar.More", systemImage: "ellipsis") {
            Section {
                // Nothing to export until there's a timeline to render.
                Button("Toolbar.Export", systemImage: "square.and.arrow.up") { isShowingExport = true }
                    .disabled(!editor.canExport)
                    .keyboardShortcut("e", modifiers: .command)
                if !ExportCenter.queue.jobs.isEmpty {
                    Button("Toolbar.Exports", systemImage: "list.bullet") { isShowingExports = true }
                }
            }
            Section {
                Button("Toolbar.ImportProject", systemImage: "square.and.arrow.down") { isImportingProject = true }
                Button("Toolbar.ExportFCPXML", systemImage: "film.stack") { isExportingFCPXML = true }
                    .disabled(!editor.canExport)
            }
        }
        .accessibilityIdentifier("more")
    }
}
