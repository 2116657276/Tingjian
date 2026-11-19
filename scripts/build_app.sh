#!/bin/bash
# 构建并打包「听笺.app」(ad-hoc 签名,仅本机使用)。无需 Xcode。
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/env.sh
FINAL="${1:-$(pwd)/dist/听笺.app}"
mkdir -p "$(dirname "$FINAL")"
OUT=/tmp/tingjian-stage/听笺.app   # 在 /tmp 组装并签名,避免云盘目录给包加扩展属性
BUILD=/tmp/tingjian-build-release

swift build -c release -Xswiftc -gnone --disable-sandbox --scratch-path "$BUILD" --product Tingjian
BIN="$BUILD/release/Tingjian"

if [ -e /tmp/tingjian-stage ]; then trash /tmp/tingjian-stage; fi
mkdir -p /tmp/tingjian-stage
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Tingjian"

# 图标:用 Swift 脚本绘制 PNG,再转 icns
ICONSET=/tmp/tingjian-icon.iconset
if [ -e "$ICONSET" ]; then trash "$ICONSET"; fi
mkdir -p "$ICONSET"
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" -o /tmp/tingjian-icongen scripts/icon.swift
/tmp/tingjian-icongen "$ICONSET"
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleName</key><string>听笺</string>
 <key>CFBundleDisplayName</key><string>听笺</string>
 <key>CFBundleIdentifier</key><string>com.local.tingjian</string>
 <key>CFBundleExecutable</key><string>Tingjian</string>
 <key>CFBundleIconFile</key><string>AppIcon</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>1.0.1</string>
 <key>CFBundleVersion</key><string>2</string>
 <key>LSMinimumSystemVersion</key><string>26.0</string>
 <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
 <key>NSHighResolutionCapable</key><true/>
 <key>NSMicrophoneUsageDescription</key><string>听笺需要使用麦克风录制课堂讲话并实时转写。仅在你点击开始或继续时才会采集音频。</string>
</dict></plist>
PLIST

cat > /tmp/tingjian.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
ENT

# 清除扩展属性,否则签名会失败;ad-hoc 签名固定标识符
xattr -cr "$OUT"
codesign --force --sign - --identifier com.local.tingjian \
  --requirements '=designated => identifier "com.local.tingjian"' \
  --entitlements /tmp/tingjian.entitlements "$OUT"
codesign --verify --strict --verbose=1 "$OUT"

# 复制到交付目录(不带扩展属性),再校验一次
if [ -e "$FINAL" ]; then trash "$FINAL"; fi
ditto --norsrc --noextattr --noqtn "$OUT" "$FINAL"
codesign --verify --strict --verbose=1 "$FINAL"
if [ "$OUT" != "$FINAL" ]; then trash "$OUT"; fi
echo "已生成:$FINAL"
