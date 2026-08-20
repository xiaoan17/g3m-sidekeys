#!/bin/bash
# 构建 G3MSidekeys.app (无需 Xcode, 仅需 Command Line Tools)
set -euo pipefail
cd "$(dirname "$0")"

APP="G3MSidekeys.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/G3MSidekeys" Sources/main.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 用本地自签名证书签名 (身份稳定, 权限授予不会丢失;
# 对外正式分发建议改用 Developer ID + 公证)
codesign --force --sign "G3MSidekeys Local Codesign" --identifier com.anbc.g3msidekeys "$APP"

echo "✅ 构建完成: $APP"
