import SwiftUI

/// A project open for editing. Laid out for iPhone first: the editor takes
/// the whole screen with its controls in a bar floating over the bottom, and
/// the library and inspector come up over it. With the room of an iPad, the
/// library stays beside the editor as a sidebar and the inspector as a
/// column on the other side.
struct ProjectEditorView: View {
    @Binding var document: MontageDocument

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.undoManager) private var undoManager
    @State private var history = ProjectHistory()
    @State private var isShowingLibrary = false
    @State private var isShowingInspector = false
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        layout
            .onAppear { history.attach(to: undoManager) }
            .onChange(of: undoManager) { _, undoManager in history.attach(to: undoManager) }
    }

    @ViewBuilder
    private var layout: some View {
        if horizontalSizeClass == .compact {
            editor
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
                editor
            }
        }
    }

    private var editor: some View {
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
