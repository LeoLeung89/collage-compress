#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="build/拼图与压缩.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache build/architectures
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
for architecture in arm64 x86_64; do
    xcrun swiftc -warnings-as-errors -O \
        -sdk "$SDK_PATH" \
        -target "${architecture}-apple-macos11.0" \
        -module-cache-path build/module-cache \
        Sources/main.swift -o "build/architectures/ImageCompress-${architecture}"
done
xcrun lipo -create build/architectures/ImageCompress-arm64 build/architectures/ImageCompress-x86_64 \
    -output "$APP/Contents/MacOS/ImageCompress"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Local integrity signature. Public distribution may require Developer ID signing and notarization.
xattr -cr "$APP"
codesign --force --sign - "$APP"
printf '已构建 macOS 11+ 通用应用：%s\n' "$APP"
