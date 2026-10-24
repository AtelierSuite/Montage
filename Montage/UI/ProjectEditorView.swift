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
    @Environment(\.undoManager) private var undoManager
    @State private var editor: ProjectEditor
    @State private var importer: MediaImporter
    @State private var history = ProjectHistory()
    @State private var isShowingLibrary = false
    @State private var isShowingInspector = false
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all
    /// The document's location while it's being read from, for media in it.
    @State private var accessedURL: URL?

    init(document: Binding<MontageDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        let media = document.wrappedValue.media
        media.packageURL = fileURL
        let editor = ProjectEditor(project: document.wrappedValue.project, mediaResolver: media.resolver)
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
            }
            .onChange(of: undoManager) { _, undoManager in attach(to: undoManager) }
            // Reverting, or another device's changes arriving, replace the
            // document from outside the editor.
            .onChange(of: document.project) { _, project in editor.replace(with: project) }
            // Media is found in the package wherever it's moved to.
            .onChange(of: fileURL, initial: true) { _, fileURL in locateMedia(at: fileURL) }
            .onChange(of: ObjectIdentifier(document.media)) { _, _ in locateMedia(at: fileURL) }
            .onDisappear { locateMedia(at: nil) }
    }

    /// Tells the document's media where the package is, keeping access to a
    /// package from another app's storage for as long as it's open here.
    private func locateMedia(at url: URL?) {
        if accessedURL != url {
            accessedURL?.stopAccessingSecurityScopedResource()
            accessedURL = url?.startAccessingSecurityScopedResource() == true ? url : nil
        }
        document.media.packageURL = url
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
        EditorView(showsControlBar: false)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                EditorActionBar(
                    // An iPad has the library in its sidebar already.
                    showLibrary: horizontalSizeClass == .compact ? { isShowingLibrary = true } : nil,
                    isShowingInspector: $isShowingInspector
                )
                .padding(.bottom, 8)
            }
            .inspector(isPresented: $isShowingInspector) {
                InspectorView()
                    .presentationDetents([.medium, .large])
            }
            .toolbar { editorToolbar }
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
                Button("Toolbar.Export", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
            }
        }
        .accessibilityIdentifier("more")
    }
}
