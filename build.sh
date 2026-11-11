#!/bin/zsh
# 重新編譯並安裝「Rakazo 自架.app」
#   ./build.sh                                           編譯並安裝到 /Applications（本機用）
#   APP_DIR=dist UNIVERSAL=1 VERSION=1.0.0 ./build.sh    只打包到 dist/（GitHub Actions 用）
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-2.0}"
OUT_DIR="${APP_DIR:-/Applications}"
if [[ "$UNIVERSAL" == "1" ]]; then
  swiftc -parse-as-library -O -target arm64-apple-macos14 Settings.swift Server.swift -o RakazoServer-arm64
  swiftc -parse-as-library -O -target x86_64-apple-macos14 Settings.swift Server.swift -o RakazoServer-x86_64
  lipo -create RakazoServer-arm64 RakazoServer-x86_64 -output RakazoServer
  rm -f RakazoServer-arm64 RakazoServer-x86_64
else
  swiftc -parse-as-library -O Settings.swift Server.swift -o RakazoServer
fi
mkdir -p "$OUT_DIR"
APP="$OUT_DIR/Rakazo 自架.app"
rm -rf "$APP.tmp"; mkdir -p "$APP.tmp/Contents/MacOS" "$APP.tmp/Contents/Resources"
cp RakazoServer "$APP.tmp/Contents/MacOS/RakazoServer"
cp icon/AppIcon.icns "$APP.tmp/Contents/Resources/AppIcon.icns"
cat > "$APP.tmp/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Rakazo 自架</string>
<key>CFBundleExecutable</key><string>RakazoServer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>local.rakazo.server</string>
<key>CFBundleName</key><string>Rakazo 自架</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --deep -s - "$APP.tmp" >/dev/null 2>&1 || true
if [[ -z "$APP_DIR" ]]; then pkill -x RakazoServer 2>/dev/null || true; fi
rm -rf "$APP"; mv "$APP.tmp" "$APP"
echo "已完成：$APP"
