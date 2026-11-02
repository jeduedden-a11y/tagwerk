#!/bin/bash
# Boots a simulator, installs the demo build and captures every tab in light and dark mode.
set -euo pipefail
APP="$1"
OUT="${2:-shots}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
UDID="$(python3 scripts/pick-simulator.py)"
mkdir -p "$OUT"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true
xcrun simctl install "$UDID" "$APP"
# Right after boot the simulator is busy with its own setup and a launch can miss the wait.
sleep 20

# A launch that has not drawn its first frame yet leaves the plain launch screen (about 75 KB);
# real screens are several hundred KB. Wait and capture again in that case.
capture() {
  local file="$1"
  for _ in 1 2 3 4; do
    xcrun simctl io "$UDID" screenshot "$file" >/dev/null
    [ "$(stat -f%z "$file")" -gt 150000 ] && return 0
    sleep 5
  done
  echo "warning: $file still looks empty"
}
for appearance in light dark; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  for tab in heute aufgaben termine verlauf einstellungen; do
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -TWDemo YES -TWTab "$tab" -AppleLanguages "(de)" -AppleLocale de_DE >/dev/null
    sleep 7
    capture "$OUT/$appearance-$tab.png"
    echo "captured $appearance-$tab"
  done
  for page in ernaehrung laufen gewicht; do
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -TWDemo YES -TWTab fitness -TWFitness "$page" -AppleLanguages "(de)" -AppleLocale de_DE >/dev/null
    sleep 11
    capture "$OUT/$appearance-fitness-$page.png"
    echo "captured $appearance-fitness-$page"
  done
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -TWDemo YES -TWTab heute -TWScroll unten -AppleLanguages "(de)" -AppleLocale de_DE >/dev/null
  sleep 7
  capture "$OUT/$appearance-heute-unten.png"
done
# First launch without demo data: what a new installation shows.
xcrun simctl ui "$UDID" appearance light
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID" -AppleLanguages "(de)" -AppleLocale de_DE >/dev/null
sleep 7
capture "$OUT/light-erststart.png"
