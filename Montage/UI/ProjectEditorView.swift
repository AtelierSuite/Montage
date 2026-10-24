import SwiftUI

/// A project open for editing. Laid out for iPhone first: the editor takes
/// the whole screen, and the library and inspector come up over it. With the
/// room of an iPad, the library stays beside the editor as a sidebar and the
/// inspector as a column on the other side.
struct ProjectEditorView: View {
    @Binding var document: MontageDocument

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isShowingLibrary = false
    @State private var isShowingInspector = false
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        if horizontalSizeClass == .compact {
            editor
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isShowingLibrary = true
                        } label: {
                            Label("Toolbar.Library", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                }
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
        EditorView()
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingInspector.toggle()
                    } label: {
                        Label("Toolbar.Inspector", systemImage: "slider.horizontal.3")
                    }
                }
            }
    }
}
