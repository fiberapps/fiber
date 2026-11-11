#!/bin/zsh
# Builds Fiber, runs it on one simulator and saves a screenshot.
#   scripts/snap.sh <name> [launch arguments…]
#   scripts/snap.sh home -tab home
#   WAIT=6 scripts/snap.sh lyrics -autoplay 1 -player lyrics -seek 12
# Uses a single simulator and shuts only that one down afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
export USER="${USER:-$(id -un)}"
NAME="${1:?usage: snap.sh <name> [launch arguments]}"; shift
DEVICE="${FIBER_SIM:-iPhone 17 Pro Max}"
RUNTIME="${FIBER_RUNTIME:-26.5}"
OUT=".build/shots"; mkdir -p "$OUT"

UDID=$(xcrun simctl list devices available -j | python3 -I -c "
import json,sys
d=json.load(sys.stdin)['devices']
for rt,devs in d.items():
    if rt.endswith('iOS-${RUNTIME//./-}'):
        for x in devs:
            if x['name']=='$DEVICE': print(x['udid']); sys.exit()
")
[[ -n "$UDID" ]] || { echo "No simulator named $DEVICE on iOS $RUNTIME"; exit 1; }

if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  xcodebuild -project Fiber.xcodeproj -scheme Fiber -destination "id=$UDID" -derivedDataPath .build/dd -jobs 4 \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error|warning: [^M]|BUILD (SUCCEEDED|FAILED)" | grep -v "^ " | sort -u
fi
APP=".build/dd/Build/Products/Debug-iphonesimulator/Fiber.app"
[[ -d "$APP" ]] || { echo "Build product missing"; exit 1; }

xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" fun.staraep.fiber >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" fun.staraep.fiber "$@" >/dev/null
sleep "${WAIT:-4}"
xcrun simctl io "$UDID" screenshot "$OUT/$NAME.png" >/dev/null 2>&1
sips -s format jpeg -s formatOptions 80 -Z 1500 "$OUT/$NAME.png" --out "$OUT/$NAME.jpg" >/dev/null
echo "$OUT/$NAME.jpg"
if [[ "${KEEP_SIM:-0}" != 1 ]]; then xcrun simctl shutdown "$UDID"; fi
