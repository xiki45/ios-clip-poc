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
    -install_name "@rpath/WeTypeInject.dylib" \
    -o WeTypeInject.dylib \
    WeTypeInject.m

echo "---- 产物 ----"
lipo -info WeTypeInject.dylib
otool -L WeTypeInject.dylib | head -6
codesign --force --sign - --timestamp=none WeTypeInject.dylib
codesign -dv WeTypeInject.dylib 2>&1 | head -4
ls -lh WeTypeInject.dylib
