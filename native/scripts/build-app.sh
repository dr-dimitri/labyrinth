#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$NATIVE_DIR/.." && pwd)"
BUILD_DIR="$NATIVE_DIR/.build"
RELEASE_DIR="$REPO_DIR/release"
CONFIGURATION=release
SIGN_APP=1
SMOKE_TEST=0

usage() {
    cat <<'EOF'
Usage: native/scripts/build-app.sh [--debug] [--no-sign] [--smoke-test]

Builds release/Blacksite.app with Swift and Metal, without Node or Electron.
  --debug       Build with Swift debug checks instead of release optimizations.
  --no-sign     Skip sealing the application bundle with an ad-hoc signature.
  --smoke-test  Run the application's Metal smoke test and save its screenshot
                to release/native-smoke.png. Requires a graphical Mac session.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) CONFIGURATION=debug ;;
        --no-sign) SIGN_APP=0 ;;
        --smoke-test) SMOKE_TEST=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'This application must be built on macOS with the Apple SDK.\n' >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    printf 'Swift is missing. Install the Xcode Command Line Tools first: xcode-select --install\n' >&2
    exit 1
fi

SOLDIER_DIR="$NATIVE_DIR/Assets/characters/soldier"
for resource in soldier.glb SOURCE.json CREDITS.txt body-color.png body-normal.png head-color.png head-normal.png head-materials.json; do
    [[ -s "$SOLDIER_DIR/$resource" ]] || {
        printf 'Missing integrated soldier resource: %s\n' "$SOLDIER_DIR/$resource" >&2
        printf 'Restore the SWAT model, four original textures, head material map and provenance files in native/Assets/characters/soldier. See docs/ASSETS.md for sources and Mixamo usage terms.\n' >&2
        exit 1
    }
done
SOLDIER_SHA="$(plutil -extract sha256 raw -o - "$SOLDIER_DIR/SOURCE.json")"
SOLDIER_ACTUAL_SHA="$(shasum -a 256 "$SOLDIER_DIR/soldier.glb" | awk '{print $1}')"
if [[ "$SOLDIER_ACTUAL_SHA" != "$SOLDIER_SHA" ]]; then
    printf 'The integrated SWAT model does not match SOURCE.json. Restore the verified original soldier.glb.\n' >&2
    exit 1
fi
MATERIAL_MAP_SHA="$(plutil -extract material_repair.sha256 raw -o - "$SOLDIER_DIR/SOURCE.json")"
MATERIAL_MAP_ACTUAL_SHA="$(shasum -a 256 "$SOLDIER_DIR/head-materials.json" | awk '{print $1}')"
if [[ "$MATERIAL_MAP_ACTUAL_SHA" != "$MATERIAL_MAP_SHA" ]]; then
    printf 'The SWAT head material map does not match SOURCE.json. Restore head-materials.json or regenerate it with native/scripts/restore-soldier-materials.py and the original FBX.\n' >&2
    exit 1
fi
for index in 0 1 2 3; do
    TEXTURE_FILE="$(plutil -extract "external_textures.$index.file" raw -o - "$SOLDIER_DIR/SOURCE.json")"
    TEXTURE_SHA="$(plutil -extract "external_textures.$index.sha256" raw -o - "$SOLDIER_DIR/SOURCE.json")"
    TEXTURE_ACTUAL_SHA="$(shasum -a 256 "$SOLDIER_DIR/$TEXTURE_FILE" | awk '{print $1}')"
    if [[ "$TEXTURE_ACTUAL_SHA" != "$TEXTURE_SHA" ]]; then
        printf 'The SWAT texture does not match SOURCE.json: %s. Restore the unchanged original PNG.\n' "$TEXTURE_FILE" >&2
        exit 1
    fi
done

# Keep every compiler/package cache inside this checkout, including sandboxed runs.
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$BUILD_DIR/cache" "$BUILD_DIR/config" \
    "$BUILD_DIR/security" "$RELEASE_DIR"
SWIFT_OPTIONS=(
    # The package contains only trusted local targets. Nested sandbox-exec is
    # unavailable in restricted build hosts; cache paths stay inside the repo.
    --disable-sandbox
    --package-path "$NATIVE_DIR"
    --scratch-path "$BUILD_DIR"
    --cache-path "$BUILD_DIR/cache"
    --config-path "$BUILD_DIR/config"
    --security-path "$BUILD_DIR/security"
    --configuration "$CONFIGURATION"
)

printf 'Building native macOS application (%s, %s)…\n' "$CONFIGURATION" "$(uname -m)"
swift build "${SWIFT_OPTIONS[@]}" --product BlacksiteMac
BIN_DIR="$(swift build "${SWIFT_OPTIONS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/BlacksiteMac"
SHADER="$NATIVE_DIR/Sources/BlacksiteMac/Resources/Shaders.metal"
[[ -x "$EXECUTABLE" ]] || { printf 'Missing executable: %s\n' "$EXECUTABLE" >&2; exit 1; }
[[ -f "$SHADER" ]] || { printf 'Missing shader: %s\n' "$SHADER" >&2; exit 1; }

# Assemble and verify a new bundle before replacing the previous successful build.
STAGING_DIR="$(mktemp -d "$RELEASE_DIR/.blacksite-staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/Blacksite.app"
CONTENTS="$STAGED_APP/Contents"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES"
cp "$EXECUTABLE" "$CONTENTS/MacOS/BlacksiteMac"
chmod 755 "$CONTENTS/MacOS/BlacksiteMac"
cp "$NATIVE_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$SHADER" "$RESOURCES/Shaders.metal"
cp "$REPO_DIR/LICENSE" "$RESOURCES/LICENSE.txt"
cp "$REPO_DIR/docs/ASSETS.md" "$RESOURCES/ASSETS.md"

for material in floor forest-earth forest-rock forest-bark forest-ground asphalt; do
    for map in color normal roughness; do
        SOURCE="$NATIVE_DIR/Assets/textures/$material/$map.jpg"
        [[ -f "$SOURCE" ]] || { printf 'Missing texture: %s\n' "$SOURCE" >&2; exit 1; }
    done
done
for map in color alpha normal roughness; do
    SOURCE="$NATIVE_DIR/Assets/textures/pine/$map.jpg"
    [[ -f "$SOURCE" ]] || { printf 'Missing foliage texture: %s\n' "$SOURCE" >&2; exit 1; }
done
[[ -f "$NATIVE_DIR/Assets/environment/sunrise.jpg" ]] || {
    printf 'Missing photographic sky. Restore native assets with native/scripts/fetch-assets.py.\n' >&2
    exit 1
}
# Include the native assets with their individual source and license records.
cp -R "$NATIVE_DIR/Assets" "$RESOURCES/Assets"
cp "$NATIVE_DIR/Assets/CREDITS.txt" "$RESOURCES/ASSET-CREDITS.txt"
printf '\n' >> "$RESOURCES/ASSET-CREDITS.txt"
cat "$SOLDIER_DIR/CREDITS.txt" >> "$RESOURCES/ASSET-CREDITS.txt"
cp "$REPO_DIR/docs/native-sky-sources.json" "$RESOURCES/native-sky-sources.json"
cp "$REPO_DIR/docs/native-foliage-sources.json" "$RESOURCES/native-foliage-sources.json"
cat >> "$RESOURCES/ASSET-CREDITS.txt" <<'EOF'

PHOTOGRAPHIC SKY
Kloppenheim 06 (Pure Sky) — Greg Zaal (Original), Jarod Guest (Sky edits) / Poly Haven
https://polyhaven.com/a/kloppenheim_06_puresky
CC0 1.0 Universal, https://polyhaven.com/license
Original 8192x4096 tonemapped sRGB JPEG; image bytes unchanged.
Used as a sky background. Source and checksum: native-sky-sources.json.

PHOTOGRAPHIC PINE FOLIAGE
Pine Tree 01 — Rob Tuytel (Photography), Rico Cilliers (Modeling) / Poly Haven
https://polyhaven.com/a/pine_tree_01
CC0 1.0 Universal, https://polyhaven.com/license
Original 4096x4096 twig color/alpha, 2048x2048 OpenGL normal/roughness JPEG maps.
Image bytes unchanged. Sources, checksums and atlas usage: native-foliage-sources.json.
EOF

if [[ -f "$REPO_DIR/build/icons/nachtgang.icns" ]]; then
    cp "$REPO_DIR/build/icons/nachtgang.icns" "$RESOURCES/Blacksite.icns"
else
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$CONTENTS/Info.plist"
fi

plutil -lint "$CONTENTS/Info.plist"
[[ -s "$RESOURCES/Shaders.metal" && -x "$CONTENTS/MacOS/BlacksiteMac" ]]
if [[ "$SIGN_APP" == 1 ]]; then
    codesign --force --sign - --timestamp=none "$STAGED_APP"
    codesign --verify --strict --verbose=2 "$STAGED_APP"
fi

APP_PATH="$RELEASE_DIR/Blacksite.app"
if [[ -e "$APP_PATH" ]]; then
    mv "$APP_PATH" "$STAGING_DIR/previous-Blacksite.app"
fi
if ! mv "$STAGED_APP" "$APP_PATH"; then
    if [[ -e "$STAGING_DIR/previous-Blacksite.app" ]]; then
        mv "$STAGING_DIR/previous-Blacksite.app" "$APP_PATH"
    fi
    exit 1
fi

printf '\nNative application ready: %s\n' "$APP_PATH"
file "$APP_PATH/Contents/MacOS/BlacksiteMac"
du -sh "$APP_PATH"

if [[ "$SMOKE_TEST" == 1 ]]; then
    "$APP_PATH/Contents/MacOS/BlacksiteMac" \
        --smoke-test --output "$RELEASE_DIR/native-smoke.png"
    [[ -s "$RELEASE_DIR/native-smoke.png" ]] || {
        printf 'The smoke test did not produce its screenshot.\n' >&2
        exit 1
    }
    printf 'Metal smoke-test image: %s\n' "$RELEASE_DIR/native-smoke.png"
fi
