#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Build"
TEST_BINARY="$BUILD_DIR/HabitBlockerCoreTests"

mkdir -p "$BUILD_DIR"

swiftc \
  -parse-as-library \
  -o "$TEST_BINARY" \
  "$ROOT_DIR/Sources/HabitBlocker/Models.swift" \
  "$ROOT_DIR/Sources/HabitBlocker/HostFileService.swift" \
  "$ROOT_DIR/Tests/HabitBlockerCoreTests.swift"

"$TEST_BINARY"
