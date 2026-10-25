import MontageEngine
import SwiftUI

/// Along the top of the library: the bins to look in, and a menu to show
/// the media as a grid or a list, filter by kind and use, sort, and clear
/// out unused media. On the Mac, the search
/// field is here too; iOS searches from the navigation bar.
struct LibraryFilterBar: View {
    @Binding var query: LibraryQuery
    @Binding var layout: LibraryLayout
    @Environment(ProjectEditor.self) private var editor
    @Binding var renamingBin: MediaBin?
    var onNewBin: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            #if os(macOS)
            searchField
            #endif
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        chip(for: .all, title: Text("Library.Bin.All"))
                        ForEach(editor.project.bins) { bin in
                            chip(for: .bin(bin.id), title: Text(bin.name))
                                .contextMenu {
                                    Button("Library.Bin.Rename", systemImage: "pencil") { renamingBin = bin }
                                    Button("Library.Bin.Delete", systemImage: "trash", role: .destructive) {
                                        if query.scope == .bin(bin.id) { query.scope = .all }
                                        editor.removeBin(bin.id)
                                    }
                                }
                        }
                        if !editor.project.bins.isEmpty {
                            chip(for: .unfiled, title: Text("Library.Bin.Unfiled"))
                        }
                        Button("Library.Bin.New", systemImage: "plus", action: onNewBin)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help(Text("Library.Bin.New"))
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.never)
                filterMenu
            }
        }
    }

    #if os(macOS)
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Library.Search", text: $query.search)
                .textFieldStyle(.plain)
            if !query.search.isEmpty {
                Button("Library.Search.Clear", systemImage: "xmark.circle.fill") { query.search = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.fill.tertiary, in: .rect(cornerRadius: 6))
    }
    #endif

    /// A bin to look in; media dropped on it is filed there.
    private func chip(for scope: LibraryQuery.Scope, title: Text) -> some View {
        let isSelected = query.scope == scope
        return Button {
            query.scope = scope
        } label: {
            title
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .dropDestination(for: MediaDragPayload.self) { payloads, _ in
            let ids = Set(payloads.flatMap(\.mediaIDs))
            switch scope {
            case .all: return false
            case .bin(let id): editor.moveMedia(ids, toBin: id)
            case .unfiled: editor.moveMedia(ids, toBin: nil)
            }
            return true
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Library.ViewAs", selection: $layout) {
                Label("Library.ViewAs.Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                Label("Library.ViewAs.List", systemImage: "list.bullet").tag(LibraryLayout.list)
            }
            .pickerStyle(.inline)
            Section("Library.Filter.Show") {
                kindToggle(.video, "Library.Filter.Video")
                kindToggle(.audio, "Library.Filter.Audio")
                kindToggle(.image, "Library.Filter.Images")
                Toggle("Library.Filter.UnusedOnly", isOn: $query.unusedOnly)
            }
            Picker("Library.Sort", selection: $query.order) {
                Text("Library.Sort.Imported").tag(LibraryQuery.Order.imported)
                Text("Library.Sort.Name").tag(LibraryQuery.Order.name)
                Text("Library.Sort.Duration").tag(LibraryQuery.Order.duration)
                Text("Library.Sort.Kind").tag(LibraryQuery.Order.kind)
            }
            .pickerStyle(.menu)
            Divider()
            Button("Library.RemoveUnused", systemImage: "trash", role: .destructive) { editor.removeUnusedMedia() }
                .disabled(editor.project.unusedMedia.isEmpty)
        } label: {
            Label("Library.Filter", systemImage: query.isFiltering
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.borderless)
        .help(Text("Library.Filter"))
    }

    /// Shows or hides a kind. With every kind shown, none is asked for, and
    /// the last kind shown can't be hidden.
    private func kindToggle(_ kind: MediaItem.Kind, _ title: LocalizedStringKey) -> some View {
        Toggle(title, isOn: Binding {
            query.kinds.isEmpty || query.kinds.contains(kind)
        } set: { isOn in
            var kinds = query.kinds.isEmpty ? Set([MediaItem.Kind.video, .audio, .image]) : query.kinds
            if isOn { kinds.insert(kind) } else { kinds.remove(kind) }
            // At least one kind stays shown.
            guard !kinds.isEmpty else { return }
            query.kinds = kinds.count == 3 ? [] : kinds
        })
    }
}
