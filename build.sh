#!/bin/zsh
# 重新編譯並安裝「Rakazo 自架.app」
set -e
cd "$(dirname "$0")"
swiftc -parse-as-library -O Settings.swift Server.swift -o RakazoServer
APP="/Applications/Rakazo 自架.app"
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
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --deep -s - "$APP.tmp" >/dev/null 2>&1 || true
pkill -x RakazoServer 2>/dev/null || true
rm -rf "$APP"; mv "$APP.tmp" "$APP"
echo "已安裝：$APP"
