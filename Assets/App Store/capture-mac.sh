#!/bin/zsh
# Captures raw Mac App Store screenshots into Raw/Mac/<language>/.
# Usage: ./capture-mac.sh [languages...]   (defaults to en ja)
#
# Opens the sample projects from samples.py in a debug build of Montage for
# Mac, which stages each shot itself when launched with -ScreenshotStage, then
# captures its window. Needs a Retina display: windows are 1440 × 900 points,
# so 2880 × 1800 pixels. Run compose.swift afterwards to frame them.
#
# The export shot's save panel is a sheet, a window of its own, so it is
# captured beside the project's as <shot>-sheet.png, with where it sits on the
# project's window in <shot>-sheet.txt, for compose.swift to put back.
set -e

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
DERIVED_DATA=${DERIVED_DATA:-/tmp/montage-mac-screenshots-dd}
LANGUAGES=($@)
(( $# )) || LANGUAGES=(en ja)
WORK=$(mktemp -d /tmp/montage-mac-screenshots.XXXXXX)
pid="" samples=""
# On the way out, however it goes: the app this started, and the samples.
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; [[ -n $samples ]] && rm -rf "$samples"; rm -rf $WORK' EXIT

# Each shot: name, then the sample it opens, by language.
typeset -A EN_PROJECTS=(01-aquarium "Aquarium Day" 02-farm "Farm Visit" 03-export "Aquarium Day")
typeset -A JA_PROJECTS=(01-aquarium "水族館の一日" 02-farm "牧場さんぽ" 03-export "水族館の一日")
SHOTS=(01-aquarium 02-farm 03-export)

# MARK: - Build

# Signed to run locally only; the sandbox is left out, as an ad-hoc signed
# sandboxed app can't start outside /Applications.
xcodebuild build -project "$PROJECT_DIR/Montage.xcodeproj" -scheme "Montage for Mac" -configuration Debug \
  -destination "platform=macOS" -derivedDataPath $DERIVED_DATA \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= -quiet
APP=$DERIVED_DATA/Build/Products/Debug/Montage.app
swiftc -O "$SCRIPT_DIR/windows.swift" -o $WORK/windows

# MARK: - Capture

for language in $LANGUAGES; do
  raw_dir="$SCRIPT_DIR/Raw/Mac/$language"
  mkdir -p "$raw_dir"
  samples="$(python3 "$SCRIPT_DIR/samples.py" Mac $language)"
  locale=$([[ $language == ja ]] && echo ja_JP || echo en_US)

  for shot in $SHOTS; do
    project=$([[ $language == ja ]] && echo $JA_PROJECTS[$shot] || echo $EN_PROJECTS[$shot])
    # A fresh copy each time, so nothing one shot does reaches the next.
    copy="$WORK/$shot/$project.montage"
    mkdir -p "$WORK/$shot"
    cp -Rc "$samples/$project.montage" "$copy"
    touch -t 202610240915 "$copy"

    # The save panel starts collapsed, in the shot's own folder, so it shows
    # none of the files on this Mac.
    $APP/Contents/MacOS/Montage "$copy" -ScreenshotStage $shot \
      -AppleLanguages "($language)" -AppleLocale $locale \
      -NSNavPanelExpandedStateForSaveMode NO -NSNavLastRootDirectory "$WORK/$shot" \
      -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO >/dev/null 2>&1 &
    pid=$!
    # Long enough to open, build the composition, stage and show the panel.
    sleep 8

    # The window is known by the size the stage gives it: titles only come
    # through with Screen Recording access, and then say "<project>.montage"
    # where Finder shows extensions.
    window="" sheet=""
    while IFS=$'\t' read -r id x y width height title; do
      if [[ -z $window && $width == 1440 && $height == 900 ]]; then
        window=$id window_x=$x window_y=$y
      elif [[ -z $sheet ]]; then
        sheet=$id sheet_x=$x sheet_y=$y
      fi
    done < <($WORK/windows $pid)
    if [[ -z $window ]]; then
      echo "no window for $shot ($language)" >&2
      kill $pid 2>/dev/null || true
      exit 1
    fi
    # Without the system's shadow: compose.swift draws its own.
    screencapture -o -l $window "$raw_dir/$shot.png"
    rm -f "$raw_dir/$shot-sheet.png" "$raw_dir/$shot-sheet.txt"
    if [[ -n $sheet && $shot == 03-export ]]; then
      screencapture -o -l $sheet "$raw_dir/$shot-sheet.png"
      # In points from the window's top-left corner.
      echo "$(( sheet_x - window_x )) $(( sheet_y - window_y ))" > "$raw_dir/$shot-sheet.txt"
    fi
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    pid=""
    echo "captured Mac/$language/$shot"
  done
  rm -r "$samples"
  samples=""
done
