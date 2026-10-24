import MontageEngine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Adds a layer at the playhead, over the video there: text, a shape, or a
/// still image imported for it.
struct AddLayerMenu<Label: View>: View {
    @Environment(ProjectEditor.self) private var editor
    @Environment(MediaImporter.self) private var importer
    @ViewBuilder let label: Label

    #if os(iOS)
    @State private var isShowingPhotos = false
    @State private var isShowingFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    #endif

    var body: some View {
        Menu {
            Button("Add.Text", systemImage: "textformat") { editor.addText() }
            Menu {
                ForEach(ShapeContent.Kind.allCases, id: \.self) { kind in
                    Button(kind.title, systemImage: kind.symbol) { editor.addShape(kind) }
                }
            } label: {
                SwiftUI.Label("Add.Shape", systemImage: "square.on.circle")
            }
            #if os(iOS)
            Button("Add.ImageFromPhotos", systemImage: "photo.on.rectangle") { isShowingPhotos = true }
            Button("Add.ImageFromFiles", systemImage: "folder") { isShowingFiles = true }
            #else
            Button("Add.Image", systemImage: "photo") {
                NSApp.sendAction(Selector(("insertImageLayer:")), to: nil, from: nil)
            }
            #endif
        } label: {
            label
        }
        #if os(iOS)
        .photosPicker(isPresented: $isShowingPhotos, selection: $pickedPhotos, matching: .images, preferredItemEncoding: .current)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            importer.importPhotos(items, placingAt: editor.insertionTime)
            pickedPhotos = []
        }
        .fileImporter(isPresented: $isShowingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importer.importFiles(urls, placingAt: editor.insertionTime) }
        }
        #endif
    }
}
