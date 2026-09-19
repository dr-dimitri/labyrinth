#!/usr/bin/env python3
"""Fetch the native app's pinned CC0 texture files, or verify them offline.

Default: restore files from the existing manifest, verifying its SHA-256 locks.
--refresh: query official Poly Haven metadata and intentionally update the lock.
--verify: check every local file without network access or writes.
Requires only Python 3 and curl; image bytes are never resized or recompressed.
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


NATIVE_DIR = Path(__file__).resolve().parent.parent
ASSET_DIR = NATIVE_DIR / "Assets"
MANIFEST_PATH = ASSET_DIR / "texture-sources.json"
EXTRA_MANIFEST_PATHS = [
    NATIVE_DIR.parent / "docs" / "native-sky-sources.json",
    NATIVE_DIR.parent / "docs" / "native-foliage-sources.json",
    NATIVE_DIR.parent / "docs" / "native-weapon-material-sources.json",
]
MATERIALS = {
    "forest-earth": "brown_mud_03",
    "floor": "concrete_floor_worn_02",
    "forest-rock": "rock_face",
    "forest-bark": "bark_brown_01",
    "forest-ground": "forrest_ground_03",
    "asphalt": "asphalt_01",
}
MAPS = {
    "color": ("Diffuse", "4k", 4096, "sRGB"),
    "normal": ("nor_gl", "2k", 2048, "linear"),
    "roughness": ("Rough", "1k", 1024, "linear"),
}
AGENT = "Nachtgang-native-local-asset-fetch/1.0 (CC0 game material sets)"


def download(url, destination):
    if not url.startswith(("https://api.polyhaven.com/", "https://dl.polyhaven.org/")):
        raise ValueError(f"Unexpected asset host: {url}")
    subprocess.run([
        "curl", "--fail", "--silent", "--show-error", "--location",
        "--retry", "2", "--connect-timeout", "20", "--max-time", "180",
        "--user-agent", AGENT, "--output", str(destination), url,
    ], check=True)


def metadata(url):
    with tempfile.TemporaryDirectory(prefix="blacksite-metadata-") as directory:
        path = Path(directory) / "response.json"
        download(url, path)
        return json.loads(path.read_text())


def jpeg_dimensions(data):
    if data[:2] != b"\xff\xd8":
        raise ValueError("Expected a JPEG file")
    offset = 2
    frame_markers = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                     0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
    while offset + 3 < len(data):
        if data[offset] != 0xFF:
            raise ValueError("Invalid JPEG marker")
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        marker = data[offset]
        offset += 1
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            continue
        length = struct.unpack_from(">H", data, offset)[0]
        if length < 2 or offset + length > len(data):
            raise ValueError("Truncated JPEG segment")
        if marker in frame_markers:
            height, width = struct.unpack_from(">HH", data, offset + 3)
            return [width, height]
        if marker == 0xDA:
            break
        offset += length
    raise ValueError("JPEG dimensions were not found")


def verify(path, record, require_sha=True):
    data = path.read_bytes()
    if len(data) != record["bytes"]:
        raise ValueError(f"Wrong file size: {path}")
    if record.get("sourceMD5") and hashlib.md5(data).hexdigest() != record["sourceMD5"]:
        raise ValueError(f"Official Poly Haven MD5 differs: {path}")
    if jpeg_dimensions(data) != record["resolution"]:
        raise ValueError(f"Wrong pixel dimensions: {path}")
    digest = hashlib.sha256(data).hexdigest()
    if require_sha and digest != record["sha256"]:
        raise ValueError(f"Pinned SHA-256 differs: {path}")
    return digest


def new_manifest():
    result = {
        "schemaVersion": 1,
        "license": "CC0-1.0",
        "licenseURL": "https://polyhaven.com/license",
        "apiCredit": "Powered by Poly Haven",
        "retrievedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "processing": "Original JPEG bytes; no upscaling, resizing or recompression.",
        "resolutionPolicy": "4096x4096 color; 2048x2048 OpenGL normal; 1024x1024 roughness.",
        "materials": {},
    }
    for folder, asset_id in MATERIALS.items():
        info_url = f"https://api.polyhaven.com/info/{asset_id}"
        files_url = f"https://api.polyhaven.com/files/{asset_id}"
        info, files = metadata(info_url), metadata(files_url)
        material = {
            "assetID": asset_id, "name": info["name"],
            "pageURL": f"https://polyhaven.com/a/{asset_id}",
            "metadataURL": info_url, "fileManifestURL": files_url,
            "authors": info["authors"], "license": "CC0-1.0",
            "sizeMeters": [round(value / 1000, 6) for value in info["dimensions"][:2]],
            "sourceMaximumResolution": info["max_resolution"], "files": {},
        }
        for name, (channel, resolution, pixels, color_space) in MAPS.items():
            source = files[channel][resolution]["jpg"]
            record = {
                "path": f"textures/{folder}/{name}.jpg",
                "downloadedURL": source["url"],
                "sourceChannel": channel, "sourceResolution": resolution,
                "resolution": [pixels, pixels], "colorSpace": color_space,
                "bytes": source["size"], "sourceMD5": source["md5"],
            }
            if name == "normal":
                record["normalConvention"] = "OpenGL (+Y)"
            material["files"][name] = record
        result["materials"][folder] = material
        print(f"Metadata verified: {folder} — {info['name']}", flush=True)
    return result


def materialize(record, refresh):
    path = ASSET_DIR / record["path"]
    if not path.resolve().is_relative_to(ASSET_DIR.resolve()):
        raise ValueError(f"Asset path escapes native/Assets: {path}")
    if path.exists():
        try:
            record["sha256"] = verify(path, record, require_sha=not refresh)
            return f"Verified {record['path']}"
        except ValueError:
            pass
    path.parent.mkdir(parents=True, exist_ok=True)
    # Four existing 2K normal maps are byte-identical. Reuse only after checking
    # upstream size/MD5 and actual dimensions; the original assets stay untouched.
    local_source = NATIVE_DIR.parent / "public" / "assets" / record["path"]
    with tempfile.NamedTemporaryFile(prefix=".fetch-", suffix=".jpg", dir=path.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        reuse = False
        if local_source.exists():
            try:
                verify(local_source, record, require_sha=not refresh)
                reuse = True
            except ValueError:
                pass
        if reuse:
            shutil.copyfile(local_source, temporary_path)
        else:
            download(record["downloadedURL"], temporary_path)
        record["sha256"] = verify(temporary_path, record, require_sha=not refresh)
        temporary_path.replace(path)
    finally:
        temporary_path.unlink(missing_ok=True)
    return f"{'Reused' if reuse else 'Downloaded'} {record['path']} ({record['resolution'][0]} px)"


def write_manifest(manifest):
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    temporary = MANIFEST_PATH.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(MANIFEST_PATH)
    lines = [
        "NACHTGANG — BLACKSITE NATIVE TEXTURE CREDITS", "",
        "Six photographic material sets from Poly Haven, licensed CC0 1.0 Universal:",
        "https://creativecommons.org/publicdomain/zero/1.0/",
        "https://polyhaven.com/license", "",
    ]
    for folder, material in manifest["materials"].items():
        authors = "; ".join(f"{name} ({role.strip()})" for name, role in material["authors"].items())
        lines.extend([f"{material['name']} [{folder}] — {authors}", material["pageURL"], ""])
    lines.extend([
        "Included per material: original 4096x4096 color, 2048x2048 OpenGL normal",
        "and 1024x1024 roughness JPEG maps. Images have not been upscaled or recompressed.",
        "texture-sources.json records official metadata/download URLs, pixel sizes,",
        "upstream MD5 and verified SHA-256 checksums. Source image bytes are unchanged.",
        "The project's code and original procedural geometry use its separate MIT license.", "",
    ])
    (ASSET_DIR / "CREDITS.txt").write_text("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--refresh", action="store_true", help="Refresh official metadata and intentionally replace checksum locks")
    mode.add_argument("--verify", action="store_true", help="Verify pinned files offline without modifying anything")
    args = parser.parse_args()
    if not args.refresh and not MANIFEST_PATH.exists():
        parser.error("No pinned manifest exists. Initialize explicitly with --refresh.")
    manifest = new_manifest() if args.refresh else json.loads(MANIFEST_PATH.read_text())
    records = [record for material in manifest["materials"].values() for record in material["files"].values()]
    pinned_extras = []
    for source_manifest in EXTRA_MANIFEST_PATHS:
        if not source_manifest.exists():
            raise FileNotFoundError(f"Required native asset manifest is missing: {source_manifest}")
        source_files = json.loads(source_manifest.read_text())["files"]
        manifest_records = []
        for source in source_files.values() if isinstance(source_files, dict) else source_files:
            record = dict(source)
            record["path"] = str((NATIVE_DIR.parent / source["path"]).resolve().relative_to(ASSET_DIR.resolve()))
            if "source_url" in source:
                record["downloadedURL"] = source["source_url"]
            if "resolution" not in record:
                record["resolution"] = [source["width"], source["height"]]
            if "sourceMD5" not in record:
                record["sourceMD5"] = source.get("upstream_md5")
            manifest_records.append(record)
        if source_manifest.name == "native-weapon-material-sources.json":
            expected = {f"textures/{folder}/{channel}.jpg"
                        for folder in ("weapon-metal", "weapon-fabric")
                        for channel in ("color", "normal", "roughness")}
            if len(manifest_records) != 6 or {record["path"] for record in manifest_records} != expected:
                raise ValueError("Weapon material manifest must pin all six color, normal and roughness JPEGs")
            if any(not record.get("sourceMD5") or not record.get("sha256") for record in manifest_records):
                raise ValueError("Weapon materials require official source MD5 and pinned SHA-256 checksums")
        pinned_extras.extend(manifest_records)
    if args.verify:
        for record in records + pinned_extras:
            verify(ASSET_DIR / record["path"], record)
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(materialize, record, args.refresh) for record in records]
            futures.extend(pool.submit(materialize, record, False) for record in pinned_extras)
            for future in concurrent.futures.as_completed(futures):
                print(future.result(), flush=True)
        if args.refresh:
            write_manifest(manifest)
    size = sum(record["bytes"] for record in records + pinned_extras)
    print(f"Verified {len(records)} landscape material maps and {len(pinned_extras)} sky/foliage/weapon images, "
          f"{size / 1_000_000:.2f} MB, all dimensions and hashes match.")


if __name__ == "__main__":
    main()
