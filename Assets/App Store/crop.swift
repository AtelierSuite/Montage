#!/usr/bin/env swift
// Cuts a window out of a capture of the whole screen, with its corners
// rounded off as macOS draws them, for when the window can't be captured on
// its own (see capture-mac-vm.sh).
// Usage: crop.swift <screen.png> <x> <y> <width> <height> <scale> <out.png>
// The frame is in points from the screen's top-left; scale is pixels per point.
import AppKit
import ImageIO
import SwiftUI

let arguments = CommandLine.arguments
let numbers = arguments.count == 8 ? arguments[2...6].compactMap { Double($0) } : []
guard numbers.count == 5,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let screen = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: crop.swift <screen.png> <x> <y> <width> <height> <scale> <out.png>")
    exit(2)
}
let scale = numbers[4]
let rect = CGRect(x: numbers[0] * scale, y: numbers[1] * scale, width: numbers[2] * scale, height: numbers[3] * scale)
guard let window = screen.cropping(to: rect) else {
    print("the frame isn't on the screen")
    exit(1)
}

let width = window.width, height = window.height
let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// A window's corners are continuous, 16 points across, measured against a
// capture of one on macOS 27. The mask is a pixel in from the edge, leaving out
// the edge's antialiasing, which is blended with whatever was behind it.
let bounds = CGRect(x: 0, y: 0, width: width, height: height)
let mask = bounds.insetBy(dx: 1, dy: 1)
context.addPath(RoundedRectangle(cornerRadius: 16 * scale - 1, style: .continuous).path(in: mask).cgPath)
context.clip()
context.draw(window, in: bounds)

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[7]))
