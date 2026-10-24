# Agent guidelines

## Commits

- Commit as you go, not all at once. Each change gets its own commit as soon as it's done; do not save up a session's work for one commit at the end.
- Do not bundle unrelated changes together. If a piece of work touches several things, split it into one commit per change.
- Commit messages are a single line. No body, no bullet lists, no multiline descriptions.
- No attribution of any kind: no `Co-Authored-By` or other trailers, no "Generated with" lines.

## Project layout

- `Montage/`: the iOS and iPadOS app (SwiftUI, `DocumentGroup`).
- `MontageMac/`: the Mac app (AppKit, `NSDocument`), one window per project.
- `Shared/`: code and resources compiled into both apps, such as the editor's SwiftUI views, the app icon and strings.
- `MontageEngine/`: framework for the project model and the rendering engine (composition, playback, effects, export).
- `MontageFormats/`: framework for file support: reading and writing project packages, and interchange formats.
- `MontageTests/`: unit tests for both frameworks.

## Building

```sh
xcodebuild -project Montage.xcodeproj -scheme Montage -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Montage.xcodeproj -scheme 'Montage for Mac' -destination 'platform=macOS' build
```

## Testing

`MontageTests/` holds unit tests (Swift Testing) for the frameworks, run with the Mac scheme. Tests that need real media read it from `~/Developer/ClaudeDocs/Samples` through `Samples`, and skip where it's missing.

```sh
xcodebuild -project Montage.xcodeproj -scheme 'Montage for Mac' -destination 'platform=macOS,arch=arm64' test
```
