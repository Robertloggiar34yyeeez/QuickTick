#!/usr/bin/env bash
# Build the pinned Mirage/Metal XCFramework with sd.cpp's real LoRA array wired
# through the C bridge. macOS/Xcode required; output stays in the local package.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$PROJECT_ROOT/ios-starter/MirageRuntime/Frameworks/sdcpp.xcframework"
MIRAGE_COMMIT="6103eb843d7dd66ed5fe43cb6957f422d3243c9d"

if [ -d "$TARGET" ]; then
    echo "Using existing custom Mirage XCFramework: $TARGET"
    exit 0
fi

command -v xcodebuild >/dev/null
command -v cmake >/dev/null
command -v ninja >/dev/null

BUILD_WORK="$(mktemp -d)"
trap 'rm -rf "$BUILD_WORK"' EXIT

git clone https://github.com/haplollc/Mirage.git "$BUILD_WORK/Mirage"
git -C "$BUILD_WORK/Mirage" checkout "$MIRAGE_COMMIT"
git -C "$BUILD_WORK/Mirage" submodule update --init Sources/CMirage/vendor/sd-cpp
git -C "$BUILD_WORK/Mirage/Sources/CMirage/vendor/sd-cpp" submodule update --init ggml

git -C "$BUILD_WORK/Mirage" apply --check "$PROJECT_ROOT/scripts/mirage-lora-native.patch"
git -C "$BUILD_WORK/Mirage" apply "$PROJECT_ROOT/scripts/mirage-lora-native.patch"

bash "$BUILD_WORK/Mirage/Scripts/build-xcframework.sh" ios

mkdir -p "$(dirname "$TARGET")"
cp -R "$BUILD_WORK/Mirage/Frameworks/sdcpp.xcframework" "$TARGET"
test -f "$TARGET/Info.plist"
grep -R -q 'lora_count' "$TARGET"
echo "Custom Mirage LoRA XCFramework ready: $TARGET"
