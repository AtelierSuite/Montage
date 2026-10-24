import AppKit
import SwiftUI

/// A project's window: the library in the sidebar, the editor beside it,
/// and the inspector on the other side.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSToolbarItemValidation {
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

    // MARK: - Importing

    /// File > Import, and the library's Import button: chooses files to
    /// copy into the project.
    @objc func importMedia(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaImporter.importableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Library.Import")
        panel.accessoryView = Self.referenceOption()
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { [importer] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { importer.importFiles(panel.urls) }
        }
    }

    /// The open panel's choice to leave files where they are, kept for next
    /// time, and for files dragged in from the Finder.
    private static func referenceOption() -> NSView {
        let checkbox = NSButton(checkboxWithTitle: String(localized: "Mac.Import.ReferenceInPlace"), target: nil, action: nil)
        checkbox.bind(.value, to: NSUserDefaultsController.shared,
                      withKeyPath: "values.\(MediaImporter.referencesFilesInPlaceKey)", options: nil)
        checkbox.toolTip = String(localized: "Mac.Import.ReferenceInPlace.Help")
        checkbox.sizeToFit()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: checkbox.frame.width + 40, height: checkbox.frame.height + 20))
        checkbox.setFrameOrigin(NSPoint(x: 20, y: 10))
        container.addSubview(checkbox)
        return container
    }

    // MARK: - Exporting

    /// File > Export, and the toolbar's Export button.
    @objc func exportMovie(_ sender: Any?) {
        guard let window, editor.canExport else { return }
        let title = (document as? NSDocument)?.displayName ?? String(localized: "Toolbar.Export")
        ExportSavePanel.begin(for: window, editor: editor, title: title)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportMovie(_:)) { return editor.canExport }
        return true
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.action == #selector(exportMovie(_:)) { return editor.canExport }
        return true
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
            // Enabled once there's a timeline to render.
            item.target = self
            item.action = #selector(exportMovie(_:))
            return item
        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }
}
