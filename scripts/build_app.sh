#!/bin/bash
# 构建 Prompt Slash.app（只需 Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PromptSlash"

APP="build/Prompt Slash.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PromptSlash"

if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Prompt Slash</string>
  <key>CFBundleDisplayName</key><string>Prompt Slash</string>
  <key>CFBundleIdentifier</key><string>io.github.jarrycf.PromptSlash</string>
  <key>CFBundleExecutable</key><string>PromptSlash</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppSleepDisabled</key><true/>
</dict>
</plist>
PLIST

# 签名：优先使用本机的固定签名证书（重新打包后「辅助功能」授权不会失效），
# 没有这张证书时退回临时签名（ad-hoc），其他人从源码构建也能正常使用
SIGN_ID="Prompt Slash Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --deep --timestamp=none --sign "$SIGN_ID" "$APP"
  echo "签名：$SIGN_ID"
else
  codesign --force --deep --sign - "$APP"
  echo "签名：临时签名（ad-hoc）"
fi
echo "已生成：$APP"
