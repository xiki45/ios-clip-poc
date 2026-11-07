#!/usr/bin/env bash
#
# 构建未签名 IPA，并按 POC 需要写入 entitlements。
#
# 前置：macOS + Xcode（含 iOS SDK）。本机仅有 Command Line Tools 时无法编译。
# 用法：./build-ipa.sh [Release|Debug]
#
set -euo pipefail
cd "$(dirname "$0")"

CONF="${1:-Release}"
PROJ="PocApp.xcodeproj"
BUILD_DIR="$PWD/build"
APP_ENT="$PWD/PocApp/PocApp.entitlements"
EXT_ENT="$PWD/ClipKeyboard/ClipKeyboard.entitlements"

echo "==> 检查工具链"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ 未检测到 Xcode（xcodebuild 不可用）。请先安装 Xcode 并执行："
  echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo "✗ 未找到 iOS SDK。请在 Xcode → Settings → Platforms 安装 iOS 平台。"
  exit 1
fi

echo "==> 清理旧产物"
rm -rf "$BUILD_DIR" Payload PocApp.ipa

echo "==> 编译（$CONF，未签名）"
xcodebuild \
  -project "$PROJ" \
  -target PocApp \
  -configuration "$CONF" \
  -sdk iphoneos \
  SYMROOT="$BUILD_DIR" \
  OBJROOT="$BUILD_DIR/obj" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="$BUILD_DIR/$CONF-iphoneos/PocApp.app"
EXT="$APP/PlugIns/ClipKeyboard.appex"

if [[ ! -d "$APP" ]]; then
  echo "✗ 未找到构建产物：$APP"
  exit 1
fi
if [[ ! -d "$EXT" ]]; then
  echo "✗ 扩展没有被嵌入：$EXT"
  echo "  检查 target 的 “Embed App Extensions” 阶段是否包含 ClipKeyboard.appex"
  exit 1
fi

echo "==> 写入 entitlements"
if command -v ldid >/dev/null 2>&1; then
  echo "    使用 ldid（推荐，TrollStore 可识别）"
  ldid -S"$EXT_ENT" "$EXT/ClipKeyboard"
  ldid -S"$APP_ENT" "$APP/PocApp"
  ldid -e "$EXT/ClipKeyboard" > "$BUILD_DIR/check-ext-entitlements.plist" || true
  ldid -e "$APP/PocApp"       > "$BUILD_DIR/check-app-entitlements.plist" || true
else
  echo "    ⚠ 未找到 ldid，退回 ad-hoc codesign"
  echo "      （TrollStore 安装多数情况仍可，但 App Group 可能不生效）"
  codesign --force --sign - --entitlements "$EXT_ENT" "$EXT"
  codesign --force --sign - --entitlements "$APP_ENT" "$APP"
  codesign -d --entitlements :- "$EXT" > "$BUILD_DIR/check-ext-entitlements.plist" 2>/dev/null || true
  codesign -d --entitlements :- "$APP" > "$BUILD_DIR/check-app-entitlements.plist" 2>/dev/null || true
fi

echo "==> 打包 IPA"
mkdir -p Payload
cp -R "$APP" Payload/
zip -qry PocApp.ipa Payload
rm -rf Payload

echo
echo "✅ 完成：$PWD/PocApp.ipa"
echo "   entitlements 回读：$BUILD_DIR/check-*-entitlements.plist"
echo
echo "下一步："
echo "  1) TrollStore 打开该 IPA 安装（或用你自己的签名方式）"
echo "  2) 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → ClipKeyboard，并打开「允许完全访问」"
echo "  3) 打开 PocApp，按 docs/POC-CHECKLIST.md 逐条验证"
