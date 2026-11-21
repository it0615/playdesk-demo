#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
work="$PWD/.build/playdesk"
app="$PWD/dist/AdFreeAndroidLauncher.app"
mkdir -p "$work/module-cache"
swiftc -O -parse-as-library -target arm64-apple-macosx13.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$work/module-cache" \
  Sources/AdFreeAndroidLauncher/*.swift -o "$work/AdFreeAndroidLauncher"
mkdir -p "$app/Contents/MacOS"
cp "$work/AdFreeAndroidLauncher" "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "$app"
