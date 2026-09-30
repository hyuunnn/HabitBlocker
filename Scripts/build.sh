#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Build"
APP_DIR="$BUILD_DIR/HabitBlocker.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SLICES_DIR="$BUILD_DIR/slices"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"

# 최소 지원 OS는 Info.plist 한 곳에서 관리한다.
# -target을 주지 않으면 빌드한 Mac의 OS 버전이 최소 버전이 되어 그보다 낮은 macOS에서 실행되지 않는다.
DEPLOYMENT_TARGET="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
ARCHS=(arm64 x86_64)

rm -rf "$APP_DIR" "$SLICES_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$SLICES_DIR"

# Apple silicon과 Intel Mac 모두에서 실행되도록 아키텍처별로 빌드한 뒤 하나로 합친다.
for arch in "${ARCHS[@]}"; do
  swiftc \
    -parse-as-library \
    -O \
    -target "$arch-apple-macos$DEPLOYMENT_TARGET" \
    -framework SwiftUI \
    -framework ServiceManagement \
    -o "$SLICES_DIR/HabitBlocker-$arch" \
    "$ROOT_DIR"/Sources/HabitBlocker/*.swift
done
lipo -create -output "$MACOS_DIR/HabitBlocker" "$SLICES_DIR"/HabitBlocker-*
rm -rf "$SLICES_DIR"

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "생성 완료: $APP_DIR (macOS $DEPLOYMENT_TARGET 이상, ${ARCHS[*]})"
echo "실행: open \"$APP_DIR\""
