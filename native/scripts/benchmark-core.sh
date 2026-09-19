#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCHMARK_DIR="$NATIVE_DIR/.build/core-benchmark"
BENCHMARK_SOURCE="$SCRIPT_DIR/benchmark-core.swift"
BENCHMARK_ARGS=()
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: native/scripts/benchmark-core.sh [--environment | --map <blacksite|nebelwacht|sundkai|kessel9|sirocco> [--spray on|off] [--water on|off] [--enemies 9] [--seed 1745] [--seconds 60] [--samples 5] [--grenades]]\n'
    exit 0
fi
if [[ "${1:-}" == --environment ]]; then
    BENCHMARK_SOURCE="$SCRIPT_DIR/benchmark-environment.swift"
    BENCHMARK_DIR="$NATIVE_DIR/.build/environment-benchmark"
    if [[ $# -ne 1 ]]; then printf '%s\n' '--environment takes no extra arguments.' >&2; exit 2; fi
elif [[ "${1:-}" == --map ]]; then
    BENCHMARK_SOURCE="$SCRIPT_DIR/benchmark-map.swift"
    BENCHMARK_DIR="$NATIVE_DIR/.build/map-benchmark"
    BENCHMARK_ARGS=("$@")
elif [[ $# -gt 0 ]]; then
    printf 'Use --help for benchmark modes and options.\n' >&2
    exit 2
fi

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
    "$BENCHMARK_SOURCE" \
    -o "$BENCHMARK_DIR/blacksite-core-benchmark"
"$BENCHMARK_DIR/blacksite-core-benchmark" "${BENCHMARK_ARGS[@]}"
