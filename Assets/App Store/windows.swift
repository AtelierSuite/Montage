// Prints the on-screen windows of a process, front to back, one per line: id,
// the frame's origin and size in points, then the title.
// Usage: windows <pid>
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1]) ?? 0
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid
    && (window[kCGWindowLayer as String] as? Int) == 0 {
    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let frame = ["X", "Y", "Width", "Height"].map { "\(Int(bounds[$0] ?? 0))" }.joined(separator: "\t")
    print("\(window[kCGWindowNumber as String] ?? 0)\t\(frame)\t\(window[kCGWindowName as String] ?? "")")
}
