#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: native/scripts/run.sh [--debug] [--no-sign] [--smoke-test]\n'
    printf 'Builds the native macOS application, then opens release/Blacksite.app.\n'
    exit 0
fi

"$SCRIPT_DIR/build-app.sh" "$@"
open "$REPO_DIR/release/Blacksite.app"
