import AppKit
import MontageEngine

/// The menu bar, built in code so every item is in one place alongside the
/// action it sends. Items send their actions up the responder chain.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu(appMenu()))
        menu.addItem(submenu(fileMenu()))
        menu.addItem(submenu(editMenu()))
        menu.addItem(submenu(insertMenu()))
        menu.addItem(submenu(viewMenu()))
        let window = windowMenu()
        menu.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: String(localized: "Mac.Menu.Help"))
        menu.addItem(submenu(help))
        NSApp.helpMenu = help
        return menu
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item(String(format: String(localized: "Mac.Menu.About"), name),
                          #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Mac.Menu.Services"))
        NSApp.servicesMenu = services
        menu.addItem(submenu(services))
        menu.addItem(.separator())
        menu.addItem(item(String(format: String(localized: "Mac.Menu.Hide"), name),
                          #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(String(localized: "Mac.Menu.HideOthers"),
                          #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(String(localized: "Mac.Menu.ShowAll"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(format: String(localized: "Mac.Menu.Quit"), name),
                          #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.File"))
        menu.addItem(item(String(localized: "Mac.Menu.New"), #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item(String(localized: "Mac.Menu.Open"), #selector(NSDocumentController.openDocument(_:)), "o"))
        // The document controller fills in whichever menu holds Clear Menu.
        let recent = NSMenu(title: String(localized: "Mac.Menu.OpenRecent"))
        recent.addItem(item(String(localized: "Mac.Menu.ClearRecent"),
                            #selector(NSDocumentController.clearRecentDocuments(_:))))
        menu.addItem(submenu(recent))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.Close"), #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item(String(localized: "Mac.Menu.Save"), #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item(String(localized: "Mac.Menu.Duplicate"), #selector(NSDocument.duplicate(_:)),
                          "s", [.command, .shift]))
        menu.addItem(item(String(localized: "Mac.Menu.Rename"), #selector(NSDocument.rename(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.MoveTo"), #selector(NSDocument.move(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.RevertTo"), #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.Import"), #selector(ProjectWindowController.importMedia(_:)),
                          "i", [.command, .shift]))
        menu.addItem(item(String(localized: "Mac.Menu.ImportProject"), #selector(ProjectWindowController.importProject(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.Export"), #selector(ProjectWindowController.exportMovie(_:)), "e"))
        menu.addItem(item(String(localized: "Mac.Menu.ExportFCPXML"), #selector(ProjectWindowController.exportFCPXML(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.ExportEDL"), #selector(ProjectWindowController.exportEDL(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.ExportOTIO"), #selector(ProjectWindowController.exportOTIO(_:))))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Edit"))
        menu.addItem(item(String(localized: "Mac.Menu.Undo"), Selector(("undo:")), "z"))
        menu.addItem(item(String(localized: "Mac.Menu.Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.Cut"), #selector(NSText.cut(_:)), "x"))
        menu.addItem(item(String(localized: "Mac.Menu.Copy"), #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(String(localized: "Mac.Menu.Paste"), #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Mac.Menu.Delete"), #selector(NSText.delete(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.SelectAll"), #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Edit.Split"), #selector(ProjectWindowController.splitClips(_:)), "b"))
        menu.addItem(item(String(localized: "Edit.DetachAudio"), #selector(ProjectWindowController.detachAudio(_:)),
                          "s", [.command, .control, .shift]))
        menu.addItem(item(String(localized: "Edit.RippleDelete"), #selector(ProjectWindowController.rippleDelete(_:))))
        menu.addItem(item(String(localized: "Edit.AddMarker"), #selector(ProjectWindowController.addMarker(_:))))
        menu.addItem(item(String(localized: "Inspector.Keyframes.Previous"),
                          #selector(ProjectWindowController.goToPreviousKeyframe(_:)), "[", [.option]))
        menu.addItem(item(String(localized: "Inspector.Keyframes.Next"),
                          #selector(ProjectWindowController.goToNextKeyframe(_:)), "]", [.option]))
        menu.addItem(item(String(localized: "Timeline.Snapping"), #selector(ProjectWindowController.toggleSnapping(_:))))
        return menu
    }

    /// Layers added at the playhead, over the video there.
    private static func insertMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Insert"))
        menu.addItem(item(String(localized: "Add.Text"), #selector(ProjectWindowController.insertTextLayer(_:)), "t", [.command, .control]))
        let shapes = NSMenu(title: String(localized: "Add.Shape"))
        for (index, kind) in ShapeContent.Kind.allCases.enumerated() {
            let shape = item(kind.title, #selector(ProjectWindowController.insertShapeLayer(_:)))
            shape.tag = index
            shape.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
            shapes.addItem(shape)
        }
        menu.addItem(submenu(shapes))
        menu.addItem(item(String(localized: "Mac.Menu.InsertImage"), #selector(ProjectWindowController.insertImageLayer(_:))))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.View"))
        menu.addItem(item(String(localized: "Mac.Menu.ShowLibrary"), #selector(NSSplitViewController.toggleSidebar(_:)),
                          "s", [.command, .control]))
        menu.addItem(item(String(localized: "Mac.Menu.ShowInspector"), #selector(NSSplitViewController.toggleInspector(_:)),
                          "i", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Timeline.ZoomIn"), #selector(ProjectWindowController.zoomInTimeline(_:)), "="))
        menu.addItem(item(String(localized: "Timeline.ZoomOut"), #selector(ProjectWindowController.zoomOutTimeline(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Preview.UseProxies"), #selector(ProjectWindowController.toggleProxies(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.ShowToolbar"), #selector(NSWindow.toggleToolbarShown(_:)),
                          "t", [.command, .option]))
        menu.addItem(item(String(localized: "Mac.Menu.CustomizeToolbar"),
                          #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.EnterFullScreen"), #selector(NSWindow.toggleFullScreen(_:)),
                          "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Window"))
        menu.addItem(item(String(localized: "Mac.Menu.Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Mac.Menu.Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.Exports"), #selector(AppDelegate.showExports(_:)),
                          "e", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.BringAllToFront"),
                          #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    // MARK: - Items

    static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func item(
        _ title: String, _ action: Selector?, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }
}
