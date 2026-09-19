#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCHMARK_DIR="$NATIVE_DIR/.build/core-benchmark"

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'The native simulation benchmark requires macOS and the Apple Swift toolchain.\n' >&2
    exit 1
fi
mkdir -p "$BENCHMARK_DIR/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BENCHMARK_DIR/ModuleCache"
swiftc -O -whole-module-optimization -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$BENCHMARK_DIR/ModuleCache" \
    -module-name BlacksiteCoreBenchmark \
    "$NATIVE_DIR"/Sources/BlacksiteCore/*.swift \
    "$SCRIPT_DIR/benchmark-core.swift" \
    -o "$BENCHMARK_DIR/blacksite-core-benchmark"
"$BENCHMARK_DIR/blacksite-core-benchmark"
