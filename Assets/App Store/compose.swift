#!/usr/bin/env swift

import AppKit

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let languages = ["en", "ja"]
/// The devices named on the command line (`./compose.swift Mac`), or all of them.
let requestedDevices = Set(CommandLine.arguments.dropFirst())

/// Captures live in `Raw/<device>/<lang>/` and are written to `<device>/<lang>/`.
enum Device: String {
    case iPhone
    case iPad
    case mac = "Mac"

    /// 6.5" iPhone, 13" iPad, and the Mac's 16:10.
    var canvasSize: NSSize {
        switch self {
        case .iPhone: NSSize(width: 1242, height: 2688)
        case .iPad: NSSize(width: 2064, height: 2752)
        case .mac: NSSize(width: 2880, height: 1800)
        }
    }

    var isRequested: Bool { requestedDevices.isEmpty || requestedDevices.contains(rawValue) }

    /// Text and margins are laid out for the iPhone canvas and scaled up by width.
    var scale: CGFloat { canvasSize.width / Device.iPhone.canvasSize.width }

    func rawDir(_ language: String) -> URL {
        scriptDir.appendingPathComponent("Raw").appendingPathComponent(rawValue)
            .appendingPathComponent(language)
    }

    func outDir(_ language: String) -> URL {
        scriptDir.appendingPathComponent(rawValue).appendingPathComponent(language)
    }
}

struct Copy {
    let header: String
    let caption: String
}

struct Screenshot {
    let name: String
    /// Keyed by language code. A language without copy is skipped.
    let copy: [String: Copy]
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

// The app's accent red, deepening toward the bottom.
let accent = color(0xA8182C)
let gradientTop = accent
let gradientBottom = accent.blended(withFraction: 0.35, of: .black)!

let timelineCopy = [
    "en": Copy(header: "Edit on every track", caption: "Layer video and audio on a multi-track timeline"),
    "ja": Copy(header: "トラックを重ねて編集", caption: "映像も音声も、マルチトラックのタイムラインで"),
]
let floatCopy = [
    "en": Copy(header: "Picture-in-picture preview", caption: "Float the preview and give the timeline the room"),
    "ja": Copy(header: "ピクチャ・イン・ピクチャ", caption: "プレビューを浮かせて、タイムラインを広く"),
]
let exportCopy = [
    "en": Copy(header: "Export to MP4 or AVI", caption: "Pick the codec, size, frame rate and quality"),
    "ja": Copy(header: "MP4にもAVIにも書き出し", caption: "コーデック・解像度・フレームレート・画質を選んで"),
]
let darkCopy = [
    "en": Copy(header: "Made for Dark Mode", caption: "An editor that stays easy on the eyes"),
    "ja": Copy(header: "ダークモードに対応", caption: "暗い場所でも目にやさしい編集画面"),
]

let iPhoneScreenshots = [
    Screenshot(name: "01-timeline", copy: timelineCopy),
    Screenshot(
        name: "02-library",
        copy: [
            "en": Copy(header: "Your clips, at a glance", caption: "Every clip in the library, with its length"),
            "ja": Copy(header: "素材をひと目で", caption: "読み込んだクリップを、長さと一緒に一覧"),
        ]
    ),
    Screenshot(
        name: "03-landscape",
        copy: [
            "en": Copy(header: "Turn sideways for more", caption: "Library, preview and timeline side by side"),
            "ja": Copy(header: "横向きで、広々と", caption: "ライブラリもプレビューもタイムラインも並べて"),
        ]
    ),
    Screenshot(name: "04-float", copy: floatCopy),
    Screenshot(name: "05-export", copy: exportCopy),
    Screenshot(name: "06-dark", copy: darkCopy),
]

let iPadScreenshots = [
    Screenshot(
        name: "01-timeline",
        copy: [
            "en": Copy(header: "A big screen for big edits", caption: "Library, preview and timeline, all at once"),
            "ja": Copy(header: "大きな画面で、思いきり編集", caption: "ライブラリ・プレビュー・タイムラインをひと目で"),
        ]
    ),
    Screenshot(
        name: "02-farm",
        copy: [
            "en": Copy(header: "Picture over picture", caption: "Stack clips on tracks to layer one over another"),
            "ja": Copy(header: "映像に映像を重ねて", caption: "トラックを重ねて、クリップを上に配置"),
        ]
    ),
    Screenshot(name: "03-float", copy: floatCopy),
    Screenshot(name: "04-export", copy: exportCopy),
    Screenshot(
        name: "05-portrait",
        copy: [
            "en": Copy(header: "Wide or tall", caption: "Vertical videos for sharing, as easily as wide ones"),
            "ja": Copy(header: "横長も、縦長も", caption: "シェア用の縦長動画も、横長と同じように"),
        ]
    ),
    Screenshot(name: "06-dark", copy: darkCopy),
]

let macScreenshots = [
    Screenshot(
        name: "01-aquarium",
        copy: [
            "en": Copy(header: "Video editing, made for the Mac", caption: "Library, preview and timeline in one window"),
            "ja": Copy(header: "Macのための動画編集", caption: "ライブラリ・プレビュー・タイムラインをひとつのウインドウに"),
        ]
    ),
    Screenshot(
        name: "02-farm",
        copy: [
            "en": Copy(header: "Layer by layer", caption: "Picture over picture, with sound on tracks of its own"),
            "ja": Copy(header: "レイヤーを重ねて", caption: "映像に映像を、音声は専用のトラックに"),
        ]
    ),
    Screenshot(
        name: "03-export",
        copy: [
            "en": Copy(header: "Export to MP4 or AVI", caption: "H.264, HEVC or Motion JPEG, at the size and quality you choose"),
            "ja": Copy(header: "MP4にもAVIにも書き出し", caption: "H.264・HEVC・Motion JPEGを、好きなサイズと画質で"),
        ]
    ),
]

// MARK: - Text

/// SF Pro Rounded, with its Japanese in Tsukushi A Round Gothic, which unlike
/// Hiragino Maru Gothic comes in a bold to match the header. That's set on the
/// Japanese runs itself rather than left to a cascade list: a font reached through
/// one sets its kana proportionally but leaves 、 and 。 full width, with a gap
/// after them. Full-width kana look spaced out too.
func styled(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
    let system = NSFont.systemFont(ofSize: size, weight: weight)
    let rounded = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
    let japanese = NSFont(
        descriptor: NSFontDescriptor(
            name: weight >= .semibold ? "TsukuARdGothic-Bold" : "TsukuARdGothic-Regular", size: size
        ).addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kTextSpacingType,
            .selectorIdentifier: kAltProportionalTextSelector,
        ]]]),
        size: size
    ) ?? rounded
    let string = NSMutableAttributedString(string: text, attributes: [.font: rounded, .foregroundColor: color])
    for (offset, character) in text.utf16.enumerated() where isJapanese(character) {
        string.addAttribute(.font, value: japanese, range: NSRange(location: offset, length: 1))
    }
    return string
}

/// Kana, kanji, and the punctuation and full-width forms set with them.
func isJapanese(_ unit: UTF16.CodeUnit) -> Bool {
    switch unit {
    case 0x3000...0x30FF, 0x3400...0x9FFF, 0xFF00...0xFFEF: true
    default: false
    }
}

/// One line of text at the largest size up to `size` that fits `maxWidth`.
struct Line {
    let string: NSAttributedString
    let size: NSSize

    init(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, maxWidth: CGFloat) {
        var fontSize = size
        var string = styled(text, size: fontSize, weight: weight, color: color)
        while string.size().width > maxWidth, fontSize > 10 {
            fontSize -= 2
            string = styled(text, size: fontSize, weight: weight, color: color)
        }
        self.string = string
        self.size = string.size()
        (inkTop, inkBottom) = Line.inkInsets(of: string, size: self.size)
    }

    /// How far below the top of the line box the glyphs actually start and end.
    let inkTop: CGFloat
    let inkBottom: CGFloat

    /// Centering by font metrics leaves the text looking off, since the line box carries
    /// space above the capitals and below the baseline. So the line is rendered once and
    /// the rows its glyphs cover are measured.
    private static func inkInsets(of string: NSAttributedString, size: NSSize) -> (CGFloat, CGFloat) {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0, let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return (0, size.height) }
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let opaque = NSMutableAttributedString(attributedString: string)
        opaque.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: opaque.length))
        opaque.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()

        // Bitmap rows run top to bottom.
        let inked = (0..<height).filter { y in
            (0..<width).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
        }
        guard let first = inked.first, let last = inked.last else { return (0, size.height) }
        return (CGFloat(first), CGFloat(last + 1))
    }

    /// Draws the line centered across `canvasWidth`, with the top of its line box at `top`.
    func draw(top: CGFloat, canvasWidth: CGFloat) {
        string.draw(at: NSPoint(x: (canvasWidth - size.width) / 2, y: top - size.height))
    }
}

/// The header over the caption, both one line, shrunk to fit `width`.
struct TextBlock {
    let header: Line
    let caption: Line
    let gap: CGFloat

    init(_ copy: Copy, headerSize: CGFloat, captionSize: CGFloat, gap: CGFloat, width: CGFloat) {
        header = Line(copy.header, size: headerSize, weight: .bold, color: .white, maxWidth: width)
        caption = Line(
            copy.caption, size: captionSize, weight: .medium,
            color: NSColor.white.withAlphaComponent(0.92), maxWidth: width
        )
        self.gap = gap
    }

    /// From the top of the header's ink to the bottom of the caption's.
    var inkHeight: CGFloat { header.size.height + gap + caption.inkBottom - header.inkTop }

    /// Draws the block with its ink centred between `top` and `bottom`.
    func draw(between top: CGFloat, and bottom: CGFloat, canvasWidth: CGFloat) {
        let inkTop = (top + bottom + inkHeight) / 2
        let headerTop = (inkTop + header.inkTop).rounded()
        header.draw(top: headerTop, canvasWidth: canvasWidth)
        caption.draw(top: headerTop - header.size.height - gap, canvasWidth: canvasWidth)
    }
}

// MARK: - Device frames

func cgImage(of image: NSImage) -> CGImage {
    image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

/// Draws `raw` aspect-filled into `rect`.
func drawFilled(_ raw: CGImage, in rect: CGRect, context: CGContext) {
    let rawSize = CGSize(width: raw.width, height: raw.height)
    let scale = max(rect.width / rawSize.width, rect.height / rawSize.height)
    let drawSize = CGSize(width: rawSize.width * scale, height: rawSize.height * scale)
    context.draw(raw, in: CGRect(
        x: rect.midX - drawSize.width / 2,
        y: rect.midY - drawSize.height / 2,
        width: drawSize.width,
        height: drawSize.height
    ))
}

/// The image turned a quarter clockwise, from landscape to portrait.
func turnedClockwise(_ image: CGImage) -> CGImage {
    let width = image.height, height = image.width
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(height))
    context.rotate(by: -.pi / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()!
}

let hardwareImage = NSImage(contentsOf: scriptDir.appendingPathComponent("Hardware@2x.png"))!
let displayImage = NSImage(contentsOf: scriptDir.appendingPathComponent("Display@2x.png"))!
let hardwareCG = cgImage(of: hardwareImage)
let displayCG = cgImage(of: displayImage)
let hardwarePixel = NSSize(width: hardwareCG.width, height: hardwareCG.height)
let displayPixel = NSSize(width: displayCG.width, height: displayCG.height)
// The display mask sits centered within the hardware frame.
let displayOrigin = NSPoint(
    x: (hardwarePixel.width - displayPixel.width) / 2,
    y: (hardwarePixel.height - displayPixel.height) / 2
)

/// The iPhone in its frame, upright, with the capture clipped by the display mask.
func framediPhone(raw: CGImage) -> NSImage {
    let image = NSImage(size: hardwarePixel)
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    hardwareImage.draw(in: NSRect(origin: .zero, size: hardwarePixel))
    let displayRect = CGRect(origin: displayOrigin, size: displayPixel)
    ctx.saveGState()
    ctx.clip(to: displayRect, mask: displayCG)
    drawFilled(raw, in: displayRect, context: ctx)
    ctx.restoreGState()
    image.unlockFocus()
    return image
}

/// The shadow under a device or window, as it would fall in front of the page.
func withShadow(radius: CGFloat, offset: CGFloat, opacity: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
    shadow.shadowBlurRadius = radius
    shadow.shadowOffset = NSSize(width: 0, height: -offset)
    shadow.set()
    draw()
    NSGraphicsContext.current?.restoreGraphicsState()
}

/// The iPad bezel, as a fraction of the device's width.
let iPadBezel: CGFloat = 0.03
let iPadCornerRadius: CGFloat = 0.05
/// 13" iPad Pro screen, width over height.
let iPadScreenAspect: CGFloat = 2064 / 2752

/// A plain iPad Pro in black, drawn rather than imaged, with the capture on its screen.
func drawiPad(raw: NSImage, in rect: NSRect) {
    let ctx = NSGraphicsContext.current!.cgContext
    let bezel = rect.width * iPadBezel
    let outerRadius = rect.width * iPadCornerRadius

    withShadow(radius: 60, offset: 24, opacity: 0.35) {
        color(0x1C1C1E).setFill()
        NSBezierPath(roundedRect: rect, xRadius: outerRadius, yRadius: outerRadius).fill()
    }

    // A lighter edge, as the aluminium band catches the light.
    let rim = NSBezierPath(
        roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: outerRadius - 2, yRadius: outerRadius - 2
    )
    rim.lineWidth = 4
    color(0x5A5A5E).setStroke()
    rim.stroke()

    let screenRect = rect.insetBy(dx: bezel, dy: bezel)
    let screenRadius = max(outerRadius - bezel * 0.8, 0)
    ctx.saveGState()
    NSBezierPath(roundedRect: screenRect, xRadius: screenRadius, yRadius: screenRadius).addClip()
    drawFilled(cgImage(of: raw), in: screenRect, context: ctx)
    ctx.restoreGState()
}

// MARK: - Layouts

/// An iPhone held upright fills what is left below a band that holds the
/// text. One held sideways is turned across the canvas, under the text.
func drawiPhone(copy: Copy, raw: NSImage, canvasSize: NSSize) {
    let s = Device.iPhone.scale
    let text = TextBlock(copy, headerSize: 84 * s, captionSize: 44 * s, gap: 4 * s, width: canvasSize.width - 96 * s)
    let textPadding = 88 * s
    let rawCG = cgImage(of: raw)
    let isLandscape = rawCG.width > rawCG.height
    let device = framediPhone(raw: isLandscape ? turnedClockwise(rawCG) : rawCG)
    let aspect = hardwarePixel.width / hardwarePixel.height

    if isLandscape {
        // Turned, the device is as wide as the margins allow, under the text.
        let deviceWidth = canvasSize.width - 80 * s
        let deviceHeight = deviceWidth * aspect
        let textBottom = canvasSize.height - text.inkHeight - 2 * textPadding
        text.draw(between: canvasSize.height, and: textBottom, canvasWidth: canvasSize.width)
        let rect = NSRect(
            x: ((canvasSize.width - deviceWidth) / 2).rounded(),
            y: (textBottom - 60 * s - deviceHeight).rounded(),
            width: deviceWidth, height: deviceHeight
        )
        withShadow(radius: 60, offset: 24, opacity: 0.35) {
            let transform = NSAffineTransform()
            // About the device's centre, a quarter anticlockwise, which
            // undoes the turn the capture was given to fit the frame.
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: 90)
            transform.concat()
            device.draw(in: NSRect(x: -rect.height / 2, y: -rect.width / 2, width: rect.height, height: rect.width))
        }
        return
    }

    let deviceTop = canvasSize.height - text.inkHeight - 2 * textPadding
    var deviceSize = NSSize(width: (deviceTop - 88 * s) * aspect, height: deviceTop - 88 * s)
    if deviceSize.width > canvasSize.width - 120 * s {
        deviceSize.width = canvasSize.width - 120 * s
        deviceSize.height = deviceSize.width / aspect
    }
    text.draw(between: canvasSize.height, and: deviceTop, canvasWidth: canvasSize.width)
    let rect = NSRect(
        x: ((canvasSize.width - deviceSize.width) / 2).rounded(), y: (deviceTop - deviceSize.height).rounded(),
        width: deviceSize.width, height: deviceSize.height
    )
    withShadow(radius: 60, offset: 24, opacity: 0.35) { device.draw(in: rect) }
}

/// The iPad is drawn as wide as the margins allow and runs off the bottom of
/// the canvas, leaving a band above it for the text.
func drawiPadShot(copy: Copy, raw: NSImage, canvasSize: NSSize) {
    let s = Device.iPad.scale
    let text = TextBlock(copy, headerSize: 84 * s, captionSize: 44 * s, gap: 4 * s, width: canvasSize.width - 96 * s)
    let screenHeight = (1 - 2 * iPadBezel) / iPadScreenAspect
    let aspect = 1 / (screenHeight + 2 * iPadBezel)
    let deviceWidth = canvasSize.width - 140 * s
    let deviceTop = canvasSize.height - 300 * s
    let deviceHeight = deviceWidth / aspect
    text.draw(between: canvasSize.height, and: deviceTop, canvasWidth: canvasSize.width)
    drawiPad(raw: raw, in: NSRect(
        x: ((canvasSize.width - deviceWidth) / 2).rounded(), y: (deviceTop - deviceHeight).rounded(),
        width: deviceWidth, height: deviceHeight
    ))
}

/// A sheet captured apart from its window, and where it sits on it: its
/// top-left corner, in points from the window's.
struct Sheet {
    let image: NSImage
    let offset: NSPoint

    init?(shot: String, in directory: URL) {
        guard let image = NSImage(contentsOf: directory.appendingPathComponent("\(shot)-sheet.png")),
              let text = try? String(contentsOf: directory.appendingPathComponent("\(shot)-sheet.txt"), encoding: .utf8)
        else { return nil }
        let numbers = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard numbers.count == 2 else { return nil }
        self.image = image
        offset = NSPoint(x: numbers[0], y: numbers[1])
    }
}

/// The header and caption across the top, and the window below them, with
/// the shadow macOS gives a window in front, and its sheet, if it has one.
func drawMac(copy: Copy, raw: NSImage, sheet: Sheet?, canvasSize: NSSize) {
    let text = TextBlock(copy, headerSize: 120, captionSize: 60, gap: 8, width: canvasSize.width - 240)
    let textBand = text.inkHeight + 2 * 90
    let bottomMargin: CGFloat = 100

    // Captures are 2880 × 1800, a window of 1440 × 900 points at 2x.
    let windowHeight = canvasSize.height - textBand - bottomMargin
    let scale = windowHeight / raw.size.height
    let windowSize = NSSize(width: raw.size.width * scale, height: windowHeight)
    let windowRect = NSRect(
        x: ((canvasSize.width - windowSize.width) / 2).rounded(), y: bottomMargin,
        width: windowSize.width, height: windowSize.height
    )
    text.draw(between: canvasSize.height, and: windowRect.maxY, canvasWidth: canvasSize.width)
    withShadow(radius: 70, offset: 30, opacity: 0.4) { raw.draw(in: windowRect) }

    if let sheet {
        // Sized by pixels, as the captures are both 2x, and placed by points,
        // of which the window is 1440 across.
        let pixelScale = windowRect.width / CGFloat(cgImage(of: raw).width)
        let pointScale = windowRect.width / 1440
        let sheetCG = cgImage(of: sheet.image)
        let size = NSSize(width: CGFloat(sheetCG.width) * pixelScale, height: CGFloat(sheetCG.height) * pixelScale)
        let rect = NSRect(
            x: windowRect.minX + sheet.offset.x * pointScale,
            y: windowRect.maxY - sheet.offset.y * pointScale - size.height,
            width: size.width, height: size.height
        )
        withShadow(radius: 40, offset: 16, opacity: 0.35) { sheet.image.draw(in: rect) }
    }
}

// MARK: - Composition

func compose(_ shot: Screenshot, language: String, device: Device) -> Bool {
    guard let copy = shot.copy[language] else { return true }
    let rawURL = device.rawDir(language).appendingPathComponent("\(shot.name).png")
    guard let raw = NSImage(contentsOf: rawURL) else {
        print("missing raw capture: \(rawURL.path)")
        return false
    }

    let canvasSize = device.canvasSize
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    NSGradient(starting: gradientTop, ending: gradientBottom)?
        .draw(in: NSRect(origin: .zero, size: canvasSize), angle: -90)
    switch device {
    case .iPhone: drawiPhone(copy: copy, raw: raw, canvasSize: canvasSize)
    case .iPad: drawiPadShot(copy: copy, raw: raw, canvasSize: canvasSize)
    case .mac:
        let sheet = Sheet(shot: shot.name, in: device.rawDir(language))
        drawMac(copy: copy, raw: raw, sheet: sheet, canvasSize: canvasSize)
    }
    image.unlockFocus()
    return write(image, canvasSize: canvasSize, shot: shot, language: language, device: device)
}

/// Rasterizes at exactly the canvas size in pixels and writes it out.
func write(_ image: NSImage, canvasSize: NSSize, shot: Screenshot, language: String, device: Device) -> Bool {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasSize.width), pixelsHigh: Int(canvasSize.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return false }
    bitmap.size = canvasSize
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(origin: .zero, size: canvasSize))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    let outDir = device.outDir(language)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let outURL = outDir.appendingPathComponent("\(shot.name).png")
    do {
        try png.write(to: outURL)
        print("wrote \(outURL.path.replacingOccurrences(of: scriptDir.path + "/", with: ""))")
        return true
    } catch {
        print("failed to write \(outURL.path): \(error)")
        return false
    }
}

var allOK = true
let sets: [(Device, [Screenshot])] = [(.iPhone, iPhoneScreenshots), (.iPad, iPadScreenshots), (.mac, macScreenshots)]
for language in languages {
    for (device, shots) in sets where device.isRequested {
        for shot in shots {
            allOK = compose(shot, language: language, device: device) && allOK
        }
    }
}
exit(allOK ? 0 : 1)
