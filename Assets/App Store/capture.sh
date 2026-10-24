#!/bin/zsh
# Captures raw App Store screenshots into Raw/<device>/<language>/.
# Usage: ./capture.sh [languages...]   (defaults to en ja)
#        DEVICES=iPad ./capture.sh    (defaults to both iPhone and iPad)
#        SIMULATOR_PREFIX=…          (names the simulators; "Montage Screenshots")
#
# Each run seeds the app with the projects from samples.py, then the
# AppStoreScreenshots UI test opens them and writes the captures. Run
# compose.swift afterwards to frame them.
set -e

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
BUNDLE_ID=com.tsubuzaki.Montage
DERIVED_DATA=${DERIVED_DATA:-/tmp/montage-screenshots-dd}
SIMULATOR_PREFIX=${SIMULATOR_PREFIX:-Montage Screenshots}
LANGUAGES=($@)
(( $# )) || LANGUAGES=(en ja)
typeset -A DEVICE_TYPES=(
  iPhone com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max
  iPad com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
)
RUNTIME=${RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}

# MARK: - Simulators

simulator() {
  local name="$SIMULATOR_PREFIX $1" udid
  udid=$(xcrun simctl list devices available | grep -F "$name (" | head -1 | grep -oE '[0-9A-F-]{36}' || true)
  if [[ -z $udid ]]; then
    udid=$(xcrun simctl create "$name" $DEVICE_TYPES[$1] $RUNTIME)
  fi
  echo $udid
}

# The document browser runs out of process and follows the system language, not
# the app's, so the whole simulator is switched and restarted for each language.
# The preferences are edited while it is shut down: a `defaults write` through
# simctl spawn does not survive the restart. Light and dark are only taken up
# on a restart too, so they are set before it.
# Usage: boot <udid> <language> <light|dark>
boot() {
  local locale=$([[ $2 == ja ]] && echo ja_JP || echo en_US)
  local preferences=~/Library/Developer/CoreSimulator/Devices/$1/data/Library/Preferences/.GlobalPreferences.plist
  # The first boot is what creates the preferences.
  xcrun simctl boot $1 2>/dev/null || true
  xcrun simctl bootstatus $1 -b >/dev/null
  xcrun simctl ui $1 appearance $3
  xcrun simctl shutdown $1
  plutil -replace AppleLanguages -json "[\"$2\"]" "$preferences"
  plutil -replace AppleLocale -string $locale "$preferences"
  xcrun simctl boot $1
  xcrun simctl bootstatus $1 -b >/dev/null
  xcrun simctl status_bar $1 override --time 9:41 \
    --batteryState discharging --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName ""
}

# MARK: - Build

xcodebuild build-for-testing -project "$PROJECT_DIR/Montage.xcodeproj" -scheme Montage \
  -destination "generic/platform=iOS Simulator" -derivedDataPath $DERIVED_DATA -quiet
APP=$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Montage.app
XCTESTRUN=$(ls $DERIVED_DATA/Build/Products/*.xctestrun | head -1)

# UI tests on a freshly booted simulator now and then miss a tap, so a failed run
# is given one more go.
# Usage: run_test <udid> <language> <directory> <light|dark>
run_test() {
  run_test_once "$@" || run_test_once "$@"
}

# Prints only the assertion that failed, if any; -quiet would hide it.
run_test_once() {
  local log=$(mktemp) test_status=0
  TEST_RUNNER_SCREENSHOT_DIR=$3 TEST_RUNNER_SCREENSHOT_LANGUAGE=$2 TEST_RUNNER_SCREENSHOT_APPEARANCE=$4 \
    xcodebuild test-without-building -xctestrun $XCTESTRUN -destination "id=$1" \
    -only-testing:MontageUITests/AppStoreScreenshots/testScreens \
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance 900 >$log 2>&1 || test_status=$?
  grep -E "error: -\[|error: .*AppStoreScreenshots" $log || true
  rm -f $log
  return $test_status
}

# MARK: - Capture

# One language and appearance at a time on one device; the iPhone and iPad run
# side by side.
capture() {
  local device=$1 udid=$(simulator $1) language appearance
  for language in $LANGUAGES; do
    raw_dir="$SCRIPT_DIR/Raw/$device/$language"
    mkdir -p "$raw_dir"
    for appearance in light dark; do
      boot $udid $language $appearance

      # A fresh install, so the browser has no recents and no project to restore.
      xcrun simctl terminate $udid $BUNDLE_ID 2>/dev/null || true
      xcrun simctl uninstall $udid $BUNDLE_ID 2>/dev/null || true
      xcrun simctl install $udid $APP

      samples="$(python3 "$SCRIPT_DIR/samples.py" $device $language)"
      documents="$(xcrun simctl get_app_container $udid $BUNDLE_ID data)/Documents"
      mkdir -p "$documents"
      cp -R "$samples/"* "$documents/"
      rm -r "$samples"
      # Match the file times in the browser to the 9:41 status bar.
      touch -t 202610240915 "$documents/"*

      run_test $udid $language "$raw_dir" $appearance
    done
    echo "captured $device/$language"
  done
  # Leaves the simulator light and off.
  xcrun simctl ui $udid appearance light
  xcrun simctl shutdown $udid 2>/dev/null || true
}

# Each device's run is waited on by itself: a bare `wait` would succeed even
# when one of them failed.
pids=()
for device in ${=DEVICES:-iPhone iPad}; do
  capture $device &
  pids+=($!)
done
failed=0
for pid in $pids; do
  wait $pid || failed=1
done
exit $failed
