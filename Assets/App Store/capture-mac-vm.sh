#!/bin/zsh
# Captures raw Mac App Store screenshots in a Parallels macOS VM, into
# Raw/Mac/<language>/, as capture-mac.sh does on the Mac at hand.
# Usage: ./capture-mac-vm.sh [languages...]   (defaults to en ja)
#        VM=…                                 (the VM's name; "macOS")
#
# The VM needs a Retina display at least 1460 × 951 points, to fit the
# 1440 × 900 window below its menu bar, and a logged-in user. It needs no
# developer tools: the app and a helper, vmtool, are built here and copied in.
# It needs no Screen Recording access either, which `screencapture` doesn't
# get through prlctl exec: the whole screen is captured from the host with
# `prlctl capture`, and crop.swift cuts the window out. The export sheet is
# drawn over its window in that capture, so it comes with it.
#
# Everything goes in a megabyte to a prlctl exec, as large piped copies can
# jam the channel for everyone using the VM. If anything else is on the VM's
# screen, the script waits for it to move off the window before capturing.
set -e

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
DERIVED_DATA=${DERIVED_DATA:-/tmp/montage-mac-screenshots-dd}
VM=${VM:-macOS}
LANGUAGES=($@)
(( $# )) || LANGUAGES=(en ja)
WORK=$(mktemp -d /tmp/montage-mac-vm-screenshots.XXXXXX)
# The VM's own copy of everything, under its user's home; expanded there.
REMOTE='$HOME/MontageScreenshots'
APP_PROCESS=MontageScreenshots/Montage.app/Contents/MacOS/Montage

# Each shot: name, then the sample it opens, by language.
typeset -A EN_PROJECTS=(01-aquarium "Aquarium Day" 02-farm "Farm Visit" 03-export "Aquarium Day")
typeset -A JA_PROJECTS=(01-aquarium "水族館の一日" 02-farm "牧場さんぽ" 03-export "水族館の一日")
SHOTS=(01-aquarium 02-farm 03-export)

# MARK: - The VM

# Runs a command in the VM and prints what it printed. The channel now and then
# fails a call before it runs ("Invalid argument"), which is tried again; a
# command's own failure is passed on.
vm() {
  local out try
  for try in 1 2 3 4 5; do
    out=$(prlctl exec $VM --current-user "$1; echo __status=\$?" 2>&1) || true
    if [[ $out == *__status=* ]]; then
      print -rn -- "${out%%__status=*}"
      return ${${out##*__status=}%%[^0-9]*}
    fi
    sleep 2
  done
  echo "$VM isn't answering" >&2
  return 1
}

# Copies a file into the VM a megabyte at a time, then checks it arrived whole.
# Usage: send <file> <path under $REMOTE>
send() {
  local pieces=$(mktemp -d $WORK/pieces.XXXXXX) piece index=0 try
  split -b 1m "$1" "$pieces/"
  vm "mkdir -p \"\$(dirname \"$REMOTE/$2\")\" && : > \"$REMOTE/$2\""
  for piece in $pieces/*(N); do
    for try in 1 2 3 4 5 6; do
      prlctl exec $VM --current-user "cat >> \"$REMOTE/$2\" && echo __sent" < $piece 2>/dev/null \
        | grep -q __sent && break
      (( try < 6 )) || { echo "couldn't send $1" >&2; return 1; }
      sleep 2
      # Back to where this piece starts, should some of it have got there.
      vm "truncate -s $(( index * 1048576 )) \"$REMOTE/$2\""
    done
    (( index += 1 ))
  done
  rm -r $pieces
  if [[ $(vm "shasum -a 256 \"$REMOTE/$2\"" | cut -d' ' -f1) != $(shasum -a 256 "$1" | cut -d' ' -f1) ]]; then
    echo "$1 arrived damaged" >&2
    return 1
  fi
}

pid=""
# On the way out, however it goes: the app this started, and everything sent.
trap '[[ -n $pid ]] && vm "kill $pid" >/dev/null 2>&1; vm "rm -rf $REMOTE" >/dev/null 2>&1; rm -rf $WORK' EXIT

# MARK: - Build

# As capture-mac.sh: signed to run locally only, without the sandbox.
xcodebuild build -project "$PROJECT_DIR/Montage.xcodeproj" -scheme "Montage for Mac" -configuration Debug \
  -destination "platform=macOS" -derivedDataPath $DERIVED_DATA \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= -quiet
APP=$DERIVED_DATA/Build/Products/Debug/Montage.app
tar -C ${APP:h} -czf $WORK/app.tgz Montage.app
swiftc -O "$SCRIPT_DIR/vmtool.swift" -o $WORK/vmtool

vm "rm -rf $REMOTE && mkdir -p $REMOTE"
send $WORK/app.tgz app.tgz
send $WORK/vmtool vmtool
vm "cd $REMOTE && tar xzf app.tgz && rm app.tgz && chmod +x vmtool"

read display_width display_height <<< "$(vm "$REMOTE/vmtool display")"
if (( display_width < 1460 || display_height < 951 )); then
  echo "$VM's display is $display_width × $display_height points; the window needs 1460 × 951" >&2
  exit 1
fi

# MARK: - Capture

typeset -A sent_media
for language in $LANGUAGES; do
  raw_dir="$SCRIPT_DIR/Raw/Mac/$language"
  mkdir -p "$raw_dir"
  samples="$(python3 "$SCRIPT_DIR/samples.py" Mac $language)"
  locale=$([[ $language == ja ]] && echo ja_JP || echo en_US)

  for shot in $SHOTS; do
    project=$([[ $language == ja ]] && echo $JA_PROJECTS[$shot] || echo $EN_PROJECTS[$shot])
    package="$samples/$project.montage"

    # The media goes in once, shared by every project and language; each shot
    # gets a fresh package of its own, so nothing one shot does reaches the next.
    media=(${(f)"$(ls "$package/Media")"})
    for file in $media; do
      [[ -n $sent_media[$file] ]] && continue
      send "$package/Media/$file" "media/$file"
      sent_media[$file]=1
    done
    copy="$REMOTE/work/$shot/$project.montage"
    send "$package/project.json" "work/$shot/$project.montage/project.json"
    vm "mkdir -p \"$copy/Media\" \"$copy/Cache\" && cd $REMOTE/media && cp -c ${(j: :)${(q)media}} \"$copy/Media/\" \
      && touch -t 202610240915 \"$copy\""

    # Opened through LaunchServices, so the app belongs to the logged-in session
    # rather than to prlctl exec's, which ends as soon as the call does.
    vm "$REMOTE/vmtool park-pointer; open -n -a \"$REMOTE/Montage.app\" \"$copy\" --args -ScreenshotStage $shot \
      -AppleLanguages \"($language)\" -AppleLocale $locale \
      -NSNavPanelExpandedStateForSaveMode NO -NSNavLastRootDirectory \"$REMOTE/work/$shot\" \
      -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO"

    # The stage makes the window 1440 × 900 once the project is open; the
    # export shot also waits for its sheet. Window titles aren't to be had
    # without Screen Recording access, so the window is known by its size.
    window="" sheet=""
    for second in {1..60}; do
      sleep 1
      [[ -n $pid ]] || pid=$(vm "pgrep -n -f $APP_PROCESS" || true)
      [[ -n $pid ]] || continue
      windows=$(vm "$REMOTE/vmtool windows $pid" || true)
      window=$(print -r -- $windows | awk '$4 == 1440 && $5 == 900' | head -1)
      sheet=$(print -r -- $windows | awk 'NF && !($4 == 1440 && $5 == 900)' | head -1)
      [[ -n $window && ( $shot != 03-export || -n $sheet ) ]] && break
    done
    if [[ -z $window ]]; then
      echo "no window for $shot ($language)" >&2
      exit 1
    fi
    # Then long enough for the preview's frame and the library's thumbnails.
    sleep 4

    # Nothing of anyone else's over the window.
    for second in {1..120}; do
      covered=$(vm "$REMOTE/vmtool covered $pid" || true)
      [[ -z $covered ]] && break
      (( second == 1 )) && echo "waiting for this to move off the window: $covered" >&2
      sleep 5
    done
    if [[ -n $covered ]]; then
      echo "the window for $shot ($language) stayed covered" >&2
      exit 1
    fi

    prlctl capture $VM --file $WORK/screen.png >/dev/null
    scale=$(( $(sips -g pixelWidth $WORK/screen.png | awk '/pixelWidth/ { print $2 }') / display_width ))
    read -r _ x y width height <<< "$window"
    "$SCRIPT_DIR/crop.swift" $WORK/screen.png $x $y $width $height $scale "$raw_dir/$shot.png"
    # The sheet is in the window's capture, so there's none apart from it.
    rm -f "$raw_dir/$shot-sheet.png" "$raw_dir/$shot-sheet.txt"

    # Gone before the next shot looks for its own.
    vm "kill $pid; while kill -0 $pid 2>/dev/null; do sleep 0.2; done; rm -rf $REMOTE/work"
    pid=""
    echo "captured Mac/$language/$shot"
  done
  rm -r "$samples"
done
