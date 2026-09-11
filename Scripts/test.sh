#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Build"
TEST_BINARY="$BUILD_DIR/HabitBlockerCoreTests"

mkdir -p "$BUILD_DIR"

# 핵심 로직 파일만 컴파일한다. HabitBlockerApp.swift는 @main이 중복되고 UI 파일은 SwiftUI가 필요해 제외.

swiftc \
  -parse-as-library \
  -o "$TEST_BINARY" \
  "$ROOT_DIR/Sources/HabitBlocker/Models.swift" \
  "$ROOT_DIR/Sources/HabitBlocker/AdminShell.swift" \
  "$ROOT_DIR/Sources/HabitBlocker/ProxyBlockService.swift" \
  "$ROOT_DIR/Sources/HabitBlocker/HostFileService.swift" \
  "$ROOT_DIR/Tests/HabitBlockerCoreTests.swift"

"$TEST_BINARY"
