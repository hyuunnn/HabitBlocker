#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Build"
APP_DIR="$BUILD_DIR/HabitBlocker.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework ServiceManagement \
  -o "$MACOS_DIR/HabitBlocker" \
  "$ROOT_DIR/Sources/HabitBlocker/HabitBlockerApp.swift"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "생성 완료: $APP_DIR"
echo "실행: open \"$APP_DIR\""
