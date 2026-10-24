import AppKit
import SwiftUI

/// A project's window: the library in the sidebar, the editor beside it,
/// and the inspector on the other side.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let splitViewController = NSSplitViewController()

    private static let exportItem = NSToolbarItem.Identifier("Export")

    private let editor: ProjectEditor
    private let importer: MediaImporter

    init(editor: ProjectEditor, importer: MediaImporter) {
        self.editor = editor
        self.importer = importer
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        window.minSize = NSSize(width: 720, height: 480)
        window.tabbingMode = .preferred
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self

        let library = NSSplitViewItem(sidebarWithViewController: hosting(LibraryView()))
        library.minimumThickness = 200
        library.maximumThickness = 320
        let center = NSSplitViewItem(viewController: hosting(EditorView()))
        center.minimumThickness = 480
        let inspector = NSSplitViewItem(inspectorWithViewController: hosting(InspectorView()))
        inspector.minimumThickness = 240
        inspector.maximumThickness = 360
        splitViewController.splitViewItems = [library, center, inspector]
        splitViewController.splitView.autosaveName = "ProjectWindow"
        window.contentViewController = splitViewController

        let toolbar = NSToolbar(identifier: "Project")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        windowFrameAutosaveName = "Project"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A SwiftUI view as a pane of the window, sized by the split view
    /// rather than sizing the window to itself.
    private func hosting(_ view: some View) -> NSViewController {
        let controller = NSHostingController(rootView: view.environment(editor).environment(importer))
        controller.sizingOptions = []
        return controller
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.exportItem,
         .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.exportItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "Toolbar.Export")
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: item.label)
            // Nothing to export until there's a timeline to render.
            item.autovalidates = false
            item.isEnabled = false
            return item
        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }
}
