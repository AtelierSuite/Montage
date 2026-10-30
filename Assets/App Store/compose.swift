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

    var textStyle: TextStyle {
        switch self {
        case .iPhone, .iPad:
            TextStyle(headerSize: 84 * scale, captionSize: 44 * scale, gap: 4 * scale, width: canvasSize.width - 96 * scale)
        case .mac: TextStyle(headerSize: 120, captionSize: 60, gap: 8, width: canvasSize.width - 240)
        }
    }

    /// The height of the band across the top that holds the text: the tallest
    /// of the languages' text, with room above and below it. It's the same for
    /// every shot, so the device sits in the same place in all of them. The
    /// iPad, which runs off the bottom of the canvas, leaves a band of its own.
    func textBand(_ sets: [TextSet]) -> CGFloat {
        let inkHeight = sets.map(\.inkHeight).max() ?? 0
        return switch self {
        case .iPhone: inkHeight + 2 * 88 * scale
        case .iPad: 300 * scale
        case .mac: inkHeight + 2 * 90
        }
    }

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

/// One line of text, centred across the canvas on a baseline.
struct Line {
    let line: CTLine
    let width: CGFloat
    /// How far the glyphs reach above and below the baseline. Measured from the
    /// glyphs themselves, as the line's ascent and descent leave space above
    /// the capitals and below the letters that sit on the baseline.
    let inkAbove: CGFloat
    let inkBelow: CGFloat

    init(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        line = CTLineCreateWithAttributedString(styled(text, size: size, weight: weight, color: color))
        width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        inkAbove = ink.maxY
        inkBelow = -ink.minY
    }

    /// The largest size up to `size`, in steps of 2, at which `text` fits `maxWidth`.
    static func fittingSize(_ text: String, size: CGFloat, weight: NSFont.Weight, maxWidth: CGFloat) -> CGFloat {
        var fontSize = size
        while fontSize > 10, Line(text, size: fontSize, weight: weight, color: .white).width > maxWidth {
            fontSize -= 2
        }
        return fontSize
    }

    func draw(baseline: CGFloat, canvasWidth: CGFloat) {
        let context = NSGraphicsContext.current!.cgContext
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: ((canvasWidth - width) / 2).rounded(), y: baseline)
        CTLineDraw(line, context)
    }
}

/// How a device's header and caption are set: their largest sizes, the space
/// between the header's line and the caption's, and the width they fit in.
struct TextStyle {
    let headerSize: CGFloat
    let captionSize: CGFloat
    let gap: CGFloat
    let width: CGFloat
}

/// The header over the caption, for every shot of a device in one language.
/// They're all set at the same sizes, the largest at which every one fits, and on
/// the same baselines, centred on the ink of all of them together, so the text
/// stays in place from one shot to the next.
struct TextSet {
    let headerSize: CGFloat
    let captionSize: CGFloat
    /// From the header's baseline down to the caption's.
    let baselineGap: CGFloat
    /// How far the ink of any header reaches above its baseline, and of any
    /// caption below its own.
    let inkAbove: CGFloat
    let inkBelow: CGFloat

    /// From the top of the highest header's ink to the bottom of the lowest caption's.
    var inkHeight: CGFloat { inkAbove + baselineGap + inkBelow }

    init(_ copies: [Copy], style: TextStyle) {
        headerSize = copies.map {
            Line.fittingSize($0.header, size: style.headerSize, weight: .bold, maxWidth: style.width)
        }.min() ?? style.headerSize
        captionSize = copies.map {
            Line.fittingSize($0.caption, size: style.captionSize, weight: .medium, maxWidth: style.width)
        }.min() ?? style.captionSize
        // The caption's line `gap` below the header's.
        let header = NSFont.systemFont(ofSize: headerSize, weight: .bold)
        let caption = NSFont.systemFont(ofSize: captionSize, weight: .medium)
        baselineGap = -header.descender + style.gap + caption.ascender
        let (headerSize, captionSize) = (headerSize, captionSize)
        inkAbove = copies.map { Line($0.header, size: headerSize, weight: .bold, color: .white).inkAbove }.max() ?? 0
        inkBelow = copies.map {
            Line($0.caption, size: captionSize, weight: .medium, color: .white).inkBelow
        }.max() ?? 0
    }

    /// Draws `copy` with the set's ink centred between `top` and `bottom`.
    func draw(_ copy: Copy, between top: CGFloat, and bottom: CGFloat, canvasWidth: CGFloat) {
        let headerBaseline = ((top + bottom + inkHeight) / 2 - inkAbove).rounded()
        Line(copy.header, size: headerSize, weight: .bold, color: .white)
            .draw(baseline: headerBaseline, canvasWidth: canvasWidth)
        Line(copy.caption, size: captionSize, weight: .medium, color: NSColor.white.withAlphaComponent(0.92))
            .draw(baseline: headerBaseline - baselineGap, canvasWidth: canvasWidth)
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

/// The iPhone fills what is left below a band that holds the text, upright.
/// A capture taken sideways is turned a quarter to fit it, as the phone would
/// be held, so it shows as large as an upright one.
func drawiPhone(copy: Copy, text: TextSet, band: CGFloat, raw: NSImage, canvasSize: NSSize) {
    let s = Device.iPhone.scale
    let rawCG = cgImage(of: raw)
    let device = framediPhone(raw: rawCG.width > rawCG.height ? turnedClockwise(rawCG) : rawCG)
    let aspect = hardwarePixel.width / hardwarePixel.height

    let deviceTop = canvasSize.height - band
    var deviceSize = NSSize(width: (deviceTop - 88 * s) * aspect, height: deviceTop - 88 * s)
    if deviceSize.width > canvasSize.width - 120 * s {
        deviceSize.width = canvasSize.width - 120 * s
        deviceSize.height = deviceSize.width / aspect
    }
    text.draw(copy, between: canvasSize.height, and: deviceTop, canvasWidth: canvasSize.width)
    let rect = NSRect(
        x: ((canvasSize.width - deviceSize.width) / 2).rounded(), y: (deviceTop - deviceSize.height).rounded(),
        width: deviceSize.width, height: deviceSize.height
    )
    withShadow(radius: 60, offset: 24, opacity: 0.35) { device.draw(in: rect) }
}

/// The iPad is drawn as wide as the margins allow and runs off the bottom of
/// the canvas, leaving a band above it for the text.
func drawiPadShot(copy: Copy, text: TextSet, band: CGFloat, raw: NSImage, canvasSize: NSSize) {
    let s = Device.iPad.scale
    let screenHeight = (1 - 2 * iPadBezel) / iPadScreenAspect
    let aspect = 1 / (screenHeight + 2 * iPadBezel)
    let deviceWidth = canvasSize.width - 140 * s
    let deviceTop = canvasSize.height - band
    let deviceHeight = deviceWidth / aspect
    text.draw(copy, between: canvasSize.height, and: deviceTop, canvasWidth: canvasSize.width)
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
func drawMac(copy: Copy, text: TextSet, band: CGFloat, raw: NSImage, sheet: Sheet?, canvasSize: NSSize) {
    let bottomMargin: CGFloat = 100

    // Captures are 2880 × 1800, a window of 1440 × 900 points at 2x.
    let windowHeight = canvasSize.height - band - bottomMargin
    let scale = windowHeight / raw.size.height
    let windowSize = NSSize(width: raw.size.width * scale, height: windowHeight)
    let windowRect = NSRect(
        x: ((canvasSize.width - windowSize.width) / 2).rounded(), y: bottomMargin,
        width: windowSize.width, height: windowSize.height
    )
    text.draw(copy, between: canvasSize.height, and: windowRect.maxY, canvasWidth: canvasSize.width)
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

func compose(_ shot: Screenshot, language: String, device: Device, text: TextSet, band: CGFloat) -> Bool {
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
    case .iPhone: drawiPhone(copy: copy, text: text, band: band, raw: raw, canvasSize: canvasSize)
    case .iPad: drawiPadShot(copy: copy, text: text, band: band, raw: raw, canvasSize: canvasSize)
    case .mac:
        let sheet = Sheet(shot: shot.name, in: device.rawDir(language))
        drawMac(copy: copy, text: text, band: band, raw: raw, sheet: sheet, canvasSize: canvasSize)
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
for (device, shots) in sets where device.isRequested {
    let textSets = languages.map { language in TextSet(shots.compactMap { $0.copy[language] }, style: device.textStyle) }
    let band = device.textBand(textSets)
    for (language, text) in zip(languages, textSets) {
        for shot in shots {
            allOK = compose(shot, language: language, device: device, text: text, band: band) && allOK
        }
    }
}
exit(allOK ? 0 : 1)
