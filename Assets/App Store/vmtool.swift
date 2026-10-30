// What capture-mac-vm.sh needs done inside the VM, built on the host and
// copied in, as the VM has no developer tools.
// Usage: vmtool display                 the main display's size in points
//        vmtool windows <pid>           the process's on-screen windows, front
//                                       to back: id, then x y width height in points
//        vmtool covered <pid>           other apps' windows in front of the
//                                       process's, which would be in its capture
//        vmtool park-pointer            moves the pointer to the middle of the
//                                       screen's right edge, out of the shots,
//                                       and off the bottom, which shows the Dock
import CoreGraphics
import Foundation

func onScreen() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
}

func frame(_ window: [String: Any]) -> CGRect {
    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
}

func owner(_ window: [String: Any]) -> Int32 { window[kCGWindowOwnerPID as String] as? Int32 ?? 0 }
func layer(_ window: [String: Any]) -> Int { window[kCGWindowLayer as String] as? Int ?? 0 }

let arguments = CommandLine.arguments
let pid = arguments.count > 2 ? Int32(arguments[2]) ?? 0 : 0
let display = CGDisplayBounds(CGMainDisplayID())

switch arguments.count > 1 ? arguments[1] : "" {
case "display":
    print("\(Int(display.width)) \(Int(display.height))")
case "windows":
    for window in onScreen() where owner(window) == pid && layer(window) == 0 {
        let f = frame(window)
        print("\(window[kCGWindowNumber as String] ?? 0)\t\(Int(f.minX))\t\(Int(f.minY))\t\(Int(f.width))\t\(Int(f.height))")
    }
case "covered":
    // Front to back, so whatever comes before the process's first window and
    // overlaps one of them is over it. The menu bar and Dock levels are left
    // out: the windows sit below the menu bar, and the Dock is hidden or clear.
    let windows = onScreen()
    let ours = windows.filter { owner($0) == pid && layer($0) == 0 }.map(frame)
    for window in windows {
        if owner(window) == pid { break }
        guard (0..<20).contains(layer(window)), ours.contains(where: { $0.intersects(frame(window)) }) else { continue }
        print("\(window[kCGWindowOwnerName as String] ?? "?")\t\(frame(window))")
    }
case "park-pointer":
    CGWarpMouseCursorPosition(CGPoint(x: display.maxX - 1, y: display.midY))
default:
    print("usage: vmtool display | windows <pid> | covered <pid> | park-pointer")
    exit(2)
}
