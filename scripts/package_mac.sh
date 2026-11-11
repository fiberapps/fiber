#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export USER="${USER:-$(id -un)}"
python3 scripts/prepare_music_token.py
python3 scripts/prepare_spotify_config.py
xcodegen generate >/dev/null
xcodebuild -project Fiber.xcodeproj -scheme Fiber -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -derivedDataPath .build/mac -jobs 4 CODE_SIGNING_ALLOWED=NO build
mkdir -p .build/delivery
ditto .build/mac/Build/Products/Release-maccatalyst/Fiber.app .build/delivery/Fiber.app
codesign --force --deep --sign - .build/delivery/Fiber.app
ditto -c -k --keepParent .build/delivery/Fiber.app .build/delivery/Fiber-Mac.zip
