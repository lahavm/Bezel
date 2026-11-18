#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Bezel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/Bezel" "$APP/Contents/MacOS/Bezel"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Vendor/platform-tools/adb" "$APP/Contents/Resources/adb"
cp "Vendor/scrcpy-server-v5.0.1" "$APP/Contents/Resources/scrcpy-server.jar"

if [ -d "Vendor/licenses" ]; then
    cp Vendor/licenses/* "$APP/Contents/Resources/" 2>/dev/null || true
fi

chmod +x "$APP/Contents/MacOS/Bezel" "$APP/Contents/Resources/adb"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "Built $APP"
