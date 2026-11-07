#!/usr/bin/env bash
#
# 编译 POC4 的 dylib。需要 Xcode（iOS SDK）。
#
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="poc4.dylib"

# arm64e 在部分 clang 上不可用，失败时自动退回 arm64
if ! clang -dynamiclib -fobjc-arc -arch arm64e -arch arm64 \
    -isysroot "$SDK" -mios-version-min=15.0 \
    -framework Foundation -framework UIKit \
    -o "$OUT" Tweak.m 2>/dev/null; then
  echo "arm64e 编译失败，改用 arm64"
  clang -dynamiclib -fobjc-arc -arch arm64 \
    -isysroot "$SDK" -mios-version-min=15.0 \
    -framework Foundation -framework UIKit \
    -o "$OUT" Tweak.m
fi

echo "✅ 生成 $PWD/$OUT"
file "$OUT"
