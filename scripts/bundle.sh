#!/bin/zsh
# Builds NBAGlass and packages it as build/NBAGlass.app (ad-hoc signed).
# Optional: APP_GROUP=group.your.id ./scripts/bundle.sh  to enable the shared App Group cache.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)/NBAGlass
APP=build/NBAGlass.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NBAGlass"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>NBAGlass</string>
  <key>CFBundleIdentifier</key><string>com.nbaglass.app</string>
  <key>CFBundleName</key><string>NBAGlass</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.nbaglass.app</string>
    <key>CFBundleURLSchemes</key><array><string>nbaglass</string></array>
  </dict></array>
  <key>NBAGlassAppGroup</key><string>${APP_GROUP:-}</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
