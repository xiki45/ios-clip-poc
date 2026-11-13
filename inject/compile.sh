#!/bin/bash
# 在装了 Xcode 的 macOS 上编译注入用 dylib（本地没有 iOS SDK，所以走 CI）
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "SDK: $SDK"
xcrun --sdk iphoneos --show-sdk-version

xcrun --sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=15.0 \
    -fobjc-arc \
    -dynamiclib \
    -isysroot "$SDK" \
    -framework UIKit \
    -framework Foundation \
    -framework CoreGraphics \
    -install_name "@rpath/WeTypeInject.dylib" \
    -o WeTypeInject.dylib \
    WeTypeInject.m \
    WTClipEngine.m \
    WTPanelView.m

echo "==> 编译隐私守卫 WTGuard.dylib"
xcrun --sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=15.0 \
    -fobjc-arc \
    -dynamiclib \
    -isysroot "$SDK" \
    -framework UIKit \
    -framework Foundation \
    -framework CoreGraphics \
    -framework QuartzCore \
    -install_name "@rpath/WTGuard.dylib" \
    -o WTGuard.dylib \
    WTGuard.m

echo "---- 产物 ----"
for d in WeTypeInject.dylib WTGuard.dylib; do
  echo "== $d"
  lipo -info "$d"
  otool -L "$d" | head -6
  codesign --force --sign - --timestamp=none "$d"
  codesign -dv "$d" 2>&1 | head -4
  ls -lh "$d"
done
