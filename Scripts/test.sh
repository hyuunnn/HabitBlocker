#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Build"
TEST_BINARY="$BUILD_DIR/HabitBlockerCoreTests"
STORE_TEST_BINARY="$BUILD_DIR/HabitBlockerStoreTests"

mkdir -p "$BUILD_DIR"

# 핵심 로직 파일만 컴파일한다. HabitBlockerApp.swift는 @main이 중복되고 UI 파일은 SwiftUI가 필요해 제외.

swiftc \
  -parse-as-library \
  -o "$TEST_BINARY" \
  "$ROOT_DIR/Sources/HabitBlocker/Models.swift" \
  "$ROOT_DIR/Sources/HabitBlocker/AdminShell.swift" \
  "$ROOT_DIR/Sources/HabitBlocker/ProxyBlockService.swift" \
  "$ROOT_DIR/Tests/HabitBlockerCoreTests.swift"

"$TEST_BINARY"

# 실제 Store를 테스트용 서비스·설정·알림 대역과 컴파일해 시스템 설정 변경 없이 실행 순서를 검증한다.
swiftc \
  -parse-as-library \
  -o "$STORE_TEST_BINARY" \
  "$ROOT_DIR/Sources/HabitBlocker/Models.swift" \
  "$ROOT_DIR/Sources/HabitBlocker/BlockerStore.swift" \
  "$ROOT_DIR/Tests/HabitBlockerStoreTests.swift"

"$STORE_TEST_BINARY"
