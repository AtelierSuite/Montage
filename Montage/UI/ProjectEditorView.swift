import SwiftUI

/// A project open for editing. Laid out for iPhone first: the editor takes
/// the whole screen with its controls in a bar floating over the bottom, and
/// the library and inspector come up over it. With the room of an iPad, the
/// library stays beside the editor as a sidebar and the inspector as a
/// column on the other side.
struct ProjectEditorView: View {
    @Binding var document: MontageDocument

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isShowingLibrary = false
    @State private var isShowingInspector = false
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all

    var body: some View {
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                    } label: {
                        Label("Toolbar.Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(true)
                }
            }
    }
}
