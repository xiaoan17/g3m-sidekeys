#!/bin/bash
# 构建 G3MSidekeys.app (无需 Xcode, 仅需 Command Line Tools)
#
#   ./build.sh            构建 App
#   ./build.sh test       只跑单元测试
#   ./build.sh all        测试 + 构建
#   ./build.sh clean      清理
#
set -euo pipefail
cd "$(dirname "$0")"

APP="G3MSidekeys.app"
BUILD=".build"
VERSION_FILE="VERSION"
BUNDLE_ID="com.anbc.g3msidekeys"
# 优先使用本地稳定证书; 找不到时回退到 ad-hoc 签名
SIGN_IDENTITY="G3MSidekeys Local Codesign"

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# 部署目标: 必须与 Info.plist 里的 LSMinimumSystemVersion 一致。
#
# 重要: 不能依赖 swiftc 的默认部署目标 —— 它会跟着工具链/SDK 走。
# 本机 CLT 的默认目标曾是 macOS 28.0, 而系统只有 27.0, 结果 App 双击就打不开
# (LaunchServices 报 -10825 kLSAppDoesNotClaimTypeErr)。
# 显式指定 -target 才是可复现的做法。
DEPLOY_TARGET="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist 2>/dev/null || echo 13.0)"
HOST_ARCH="$(uname -m)"

say()  { printf '\033[0;36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m✅\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m⚠️ \033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m❌\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 单元测试

run_tests() {
  say "编译单元测试..."
  mkdir -p "$BUILD/test"
  # swiftc 要求含顶层代码的文件名为 main.swift
  cp Tests/run_tests.swift "$BUILD/test/main.swift"
  swiftc -O -target "${HOST_ARCH}-apple-macos${DEPLOY_TARGET}" \
      -o "$BUILD/test/runner" \
      Sources/Core/*.swift \
      Sources/Diagnostics/Logger.swift \
      "$BUILD/test/main.swift"
  say "运行单元测试..."
  "$BUILD/test/runner"
}

# ---------------------------------------------------------------- 构建

# 校验产物的最小系统版本确实等于我们声明的部署目标
verify_deployment_target() {
  local bin="$1"
  local minos
  minos="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  if [ "$minos" != "$DEPLOY_TARGET" ]; then
    die "部署目标不符: 二进制 minos=$minos, 期望 $DEPLOY_TARGET —— 该 App 会在旧系统上无法启动"
  fi
  ok "部署目标校验通过 (minos $minos)"
}

build_app() {
  say "清理旧产物"
  rm -rf "$APP" "$BUILD/app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  say "编译 (版本 $VERSION / build $BUILD_NUMBER / 目标 macOS $DEPLOY_TARGET)"

  if [ "${UNIVERSAL:-0}" = "1" ]; then
    # 通用二进制: 同时覆盖 Apple Silicon 与 Intel
    for arch in arm64 x86_64; do
      swiftc -O -target "${arch}-apple-macos${DEPLOY_TARGET}" \
          -o "$BUILD/app/G3MSidekeys-$arch" \
          Sources/main.swift \
          Sources/Core/*.swift \
          Sources/Capture/*.swift \
          Sources/Diagnostics/*.swift \
          Sources/App/*.swift
    done
    lipo -create "$BUILD/app/G3MSidekeys-arm64" "$BUILD/app/G3MSidekeys-x86_64" \
         -output "$APP/Contents/MacOS/G3MSidekeys"
    rm -f "$BUILD/app/G3MSidekeys-arm64" "$BUILD/app/G3MSidekeys-x86_64"
  else
    swiftc -O -target "${HOST_ARCH}-apple-macos${DEPLOY_TARGET}" \
        -o "$APP/Contents/MacOS/G3MSidekeys" \
        Sources/main.swift \
        Sources/Core/*.swift \
        Sources/Capture/*.swift \
        Sources/Diagnostics/*.swift \
        Sources/App/*.swift
  fi

  verify_deployment_target "$APP/Contents/MacOS/G3MSidekeys"

  cp Resources/Info.plist "$APP/Contents/Info.plist"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

  # 版本号注入 (以 VERSION 文件为准, 避免手改 plist 漏改)
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER"      "$APP/Contents/Info.plist"

  say "签名"
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    # --options runtime 开启 Hardened Runtime, Developer ID 分发时必需
    codesign --force --options runtime --timestamp=none \
             --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    ok "已使用稳定证书签名: $SIGN_IDENTITY"
  else
    warn "找不到签名身份 \"$SIGN_IDENTITY\", 回退到 ad-hoc 签名"
    warn "  ad-hoc 签名的 App 每次重建都会变成新的身份, 系统权限需要重新授予"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  fi

  codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/   /'
  ok "构建完成: $APP"
}

# ---------------------------------------------------------------- 打包

make_zip() {
  local zip="G3MSidekeys-v${VERSION}.zip"
  say "打包 $zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$APP" "$zip"
  ok "已生成 $zip"
}

# ---------------------------------------------------------------- 入口

case "${1:-build}" in
  test)
    run_tests
    ;;
  build)
    build_app
    ;;
  all)
    run_tests
    echo
    build_app
    make_zip
    ;;
  zip)
    make_zip
    ;;
  clean)
    rm -rf "$APP" "$BUILD"
    ok "已清理"
    ;;
  *)
    die "未知参数: $1 (可用: build | test | all | zip | clean)"
    ;;
esac
