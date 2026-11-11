#!/bin/zsh
# Builds a Release, device (arm64) build of Fiber and packages it as an
# UNSIGNED .ipa for a signing tool such as ksign.
#   scripts/package_ipa.sh   →   .build/delivery/Fiber-unsigned.ipa
set -euo pipefail
cd "$(dirname "$0")/.."
export USER="${USER:-$(id -un)}"
python3 scripts/prepare_music_token.py
python3 scripts/prepare_spotify_config.py
xcodegen generate >/dev/null
xcodebuild -project Fiber.xcodeproj -scheme Fiber -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/dd -jobs 4 CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error|warning: [^M]|BUILD (SUCCEEDED|FAILED)" | grep -v "^ " | sort -u
APP=".build/dd/Build/Products/Release-iphoneos/Fiber.app"
[[ -d "$APP" ]] || { echo "Build product missing"; exit 1; }
OUT=".build/delivery"; rm -rf "$OUT/Payload"; mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && rm -f Fiber-unsigned.ipa && zip -qry Fiber-unsigned.ipa Payload && rm -rf Payload)
shasum -a 256 "$OUT/Fiber-unsigned.ipa" | tee "$OUT/Fiber-unsigned.ipa.sha256"
ls -lh "$OUT/Fiber-unsigned.ipa"
