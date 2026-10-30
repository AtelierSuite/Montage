import XCTest

/// Stages and captures the App Store screenshots.
///
/// Driven by `Assets/App Store/capture.sh`, which seeds the projects these
/// open and says where to write through `SCREENSHOT_DIR` and which language to
/// use through `SCREENSHOT_LANGUAGE`. Without them the tests skip, so they stay
/// out of the way of an ordinary test run.
@MainActor
final class AppStoreScreenshots: XCTestCase {
    private enum Stage {
        /// The editor as it opens.
        case editor
        /// The library, over the editor where it isn't beside it.
        case library
        /// The preview floating over the editor, picture in picture.
        case floatingPreview
        /// The export options.
        case export
    }

    private struct Shot {
        let name: String
        /// The project's name, keyed by language.
        let project: [String: String]
        var stage = Stage.editor
        var isLandscape = false
        /// Where the playhead is put, in seconds.
        var time = 0.0
    }

    private static let aquarium = ["en": "Aquarium Day", "ja": "水族館の一日"]
    private static let farm = ["en": "Farm Visit", "ja": "牧場さんぽ"]
    private static let reel = ["en": "Dolphin Reel", "ja": "イルカのリール"]

    private static let iPhoneShots = [
        Shot(name: "01-timeline", project: aquarium, time: 3),
        Shot(name: "02-library", project: farm, stage: .library),
        Shot(name: "03-landscape", project: aquarium, isLandscape: true, time: 3),
        Shot(name: "04-float", project: farm, stage: .floatingPreview, time: 3),
        Shot(name: "05-export", project: aquarium, stage: .export),
    ]

    private static let iPadShots = [
        Shot(name: "01-timeline", project: aquarium, time: 3),
        Shot(name: "02-farm", project: farm, time: 6),
        Shot(name: "03-float", project: aquarium, stage: .floatingPreview),
        Shot(name: "04-export", project: farm, stage: .export),
        Shot(name: "05-portrait", project: reel, time: 2),
    ]

    private var directory: URL!
    private var language = "en"
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("run through Assets/App Store/capture.sh")
        }
        directory = URL(fileURLWithPath: path)
        language = environment["SCREENSHOT_LANGUAGE"] ?? "en"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testScreens() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let shots = UIDevice.current.userInterfaceIdiom == .pad ? Self.iPadShots : Self.iPhoneShots
        for shot in shots {
            XCUIDevice.shared.orientation = shot.isLandscape ? .landscapeLeft : .portrait
            launch(at: shot.time)
            open(try XCTUnwrap(shot.project[language]))
            stage(shot.stage)
            // The still standing in for the preview, where it isn't covered.
            _ = app.otherElements["screenshotStill"].waitForExistence(timeout: 20)
            // Let sheets, thumbnails and the floating preview settle.
            Thread.sleep(forTimeInterval: 3)
            let file = directory.appendingPathComponent("\(shot.name).png")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
            if ProcessInfo.processInfo.environment["SCREENSHOT_HIERARCHY"] != nil {
                try app.debugDescription.write(
                    to: directory.appendingPathComponent("\(shot.name).txt"), atomically: true, encoding: .utf8
                )
            }
        }
    }

    // MARK: - Steps

    /// The simulator can't play a project, so the preview shows a still of
    /// it instead (see `ScreenshotStill`), at the time asked for.
    private func launch(at time: Double) {
        app = XCUIApplication()
        let locale = language == "ja" ? "ja_JP" : "en_US"
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launchArguments += ["-ScreenshotStill", "YES", "-ScreenshotTime", "\(time)"]
        app.launch()
    }

    /// Opens a project from the app's folder in the document browser.
    private func open(_ name: String) {
        let browse = app.buttons[language == "ja" ? "ブラウズ" : "Browse"].firstMatch
        if browse.waitForExistence(timeout: 15), !browse.isSelected {
            browse.tap()
        }

        // The cell, not its name: a tap on the name label does not open the file.
        let file = app.collectionViews.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "\(name) is not in the browser")
        // On iPhone the browser starts as a sheet that only shows its first row.
        if !file.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        file.tap()

        XCTAssertTrue(app.buttons["more"].waitForExistence(timeout: 20), "\(name) never opened")
        // The library's thumbnails and the timeline come in after the editor.
        Thread.sleep(forTimeInterval: 2)
    }

    private func stage(_ stage: Stage) {
        switch stage {
        case .editor:
            break
        case .library:
            tap(app.buttons[localized("Library", "ライブラリ")])
        case .floatingPreview:
            tap(app.buttons[localized("Float Preview", "プレビューをフローティング表示")])
        case .export:
            tap(app.buttons["more"])
            tap(app.buttons[localized("Export", "書き出す")])
            // With the formats open: MP4 and AVI.
            let format = localized("Format", "フォーマット")
            tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", format)))
        }
    }

    /// A label as the app shows it in the language being captured.
    private func localized(_ english: String, _ japanese: String) -> String {
        language == "ja" ? japanese : english
    }

    private func tap(_ query: XCUIElementQuery) {
        tap(query.firstMatch)
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "missing \(element)")
        element.tap()
    }
}
