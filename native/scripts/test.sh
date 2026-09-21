#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$NATIVE_DIR/.build"

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: native/scripts/test.sh [additional swift test options]\n'
    printf 'Builds the complete native package and runs its Swift tests.\n'
    printf 'Example: native/scripts/test.sh --filter Grenade\n'
    exit 0
fi
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'The complete native package requires macOS and the Apple SDK.\n' >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    printf 'Blacksite requires Apple Silicon. Run this script in a native ARM64 macOS shell.\n' >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    printf 'Swift is missing. Install the Xcode Command Line Tools first: xcode-select --install\n' >&2
    exit 1
fi

export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$BUILD_DIR/cache" "$BUILD_DIR/config" "$BUILD_DIR/security"
SWIFT_OPTIONS=(
    --arch arm64
    --disable-sandbox
    --package-path "$NATIVE_DIR"
    --scratch-path "$BUILD_DIR"
    --cache-path "$BUILD_DIR/cache"
    --config-path "$BUILD_DIR/config"
    --security-path "$BUILD_DIR/security"
)

# Some Apple CLT releases ship Swift Testing's macros in a separate directory
# which is not searched automatically. Discover it from the active toolchain.
SWIFTC_PATH="$(xcrun --find swiftc 2>/dev/null || true)"
if [[ -n "$SWIFTC_PATH" ]]; then
    TOOLCHAIN_USR="$(cd "$(dirname "$SWIFTC_PATH")/.." && pwd)"
    TESTING_PLUGIN_DIR="$TOOLCHAIN_USR/lib/swift/host/plugins/testing"
    if [[ -f "$TESTING_PLUGIN_DIR/libTestingMacros.dylib" ]]; then
        SWIFT_OPTIONS+=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGIN_DIR")
    fi
fi

swift test "${SWIFT_OPTIONS[@]}" "$@"
