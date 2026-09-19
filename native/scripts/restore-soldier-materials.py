#!/usr/bin/env python3
"""Restore SWAT's lost GLB head material groups from its original FBX polygons.

No network access occurs. Supply the original FBX explicitly with --fbx.
Both input hashes are pinned; no colour, normal, or geometric-region guessing.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

FBX_SHA = "151909674043fc470bfab60d1355a1c15deff5bd2386f5a5edbae6cb94b264ac"
GLB_SHA = "6357e45589b83a61a57a2772443d59b7a0d78c53cffacb4947e223e0fbfe0cbf"
FBX_URL = "https://raw.githubusercontent.com/baponkar/Third-Person-Shooter-With-Shooter-AI/main/Assets/baponkar/_baponkar_TPS_V_2.2/Model_Meshes/swat@T-Pose.fbx"
ASSET_DIR = Path(__file__).resolve().parents[1] / "Assets/characters/soldier"


class FBXNode:
    def __init__(self, name, properties, children):
        self.name, self.properties, self.children = name, properties, children

    def child(self, name):
        matches = [node for node in self.children if node.name == name]
        if not matches:
            raise ValueError(f"Missing FBX node {name}")
        return matches[0]

    def array(self, name):
        return self.child(name).properties[0]


def read_fbx(data):
    if not data.startswith(b"Kaydara FBX Binary  \x00\x1a\x00"):
        raise ValueError("Expected binary FBX")
    version = struct.unpack_from("<I", data, 23)[0]
    wide = version >= 7500
    header = 25 if wide else 13

    def property_at(offset):
        kind = chr(data[offset])
        offset += 1
        scalar = {"Y": "h", "C": "?", "I": "i", "F": "f", "D": "d", "L": "q"}
        if kind in scalar:
            fmt = "<" + scalar[kind]
            return struct.unpack_from(fmt, data, offset)[0], offset + struct.calcsize(fmt)
        if kind in "SR":
            length = struct.unpack_from("<I", data, offset)[0]
            offset += 4
            value = data[offset:offset + length]
            if len(value) != length:
                raise ValueError("Truncated FBX string/raw property")
            return value.decode("utf-8", errors="replace") if kind == "S" else None, offset + length
        if kind in "fdilbc":
            count, encoding, length = struct.unpack_from("<III", data, offset)
            offset += 12
            packed = data[offset:offset + length]
            if len(packed) != length or encoding not in (0, 1):
                raise ValueError("Invalid FBX array")
            packed = zlib.decompress(packed) if encoding else packed
            fmt = "<" + {"f": "f", "d": "d", "i": "i", "l": "q", "b": "?", "c": "b"}[kind] * count
            return list(struct.unpack(fmt, packed)), offset + length
        raise ValueError(f"Unsupported FBX property {kind}")

    def node_at(offset):
        end, count, _, name_length = struct.unpack_from("<QQQB" if wide else "<IIIB", data, offset)
        if not end:
            return None, offset + header
        if end > len(data) or end <= offset:
            raise ValueError("Invalid FBX node bounds")
        offset += header
        name = data[offset:offset + name_length].decode("utf-8")
        offset += name_length
        properties, children = [], []
        for _ in range(count):
            value, offset = property_at(offset)
            properties.append(value)
        while offset < end - header:
            child, offset = node_at(offset)
            if child is None:
                break
            children.append(child)
        return FBXNode(name, properties, children), end

    result, offset = [], 27
    while offset < len(data):
        node, offset = node_at(offset)
        if node is None:
            break
        result.append(node)
    return result


def verified_bytes(path, expected):
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise ValueError(f"Source SHA256 mismatch: {path}; expected {expected}, got {actual}")
    return data


def recover(fbx_data, glb_data):
    roots = read_fbx(fbx_data)
    objects = next(node for node in roots if node.name == "Objects")
    head = next(node for node in objects.children if node.name == "Geometry" and node.properties[1].startswith("Soldier_head\x00") and node.properties[2] == "Mesh")
    vertices, polygon_indices = head.array("Vertices"), head.array("PolygonVertexIndex")
    uv_layer, material_layer = head.child("LayerElementUV"), head.child("LayerElementMaterial")
    if uv_layer.array("MappingInformationType") != "ByPolygonVertex" or uv_layer.array("ReferenceInformationType") != "IndexToDirect":
        raise ValueError("Unexpected original FBX UV mapping")
    if material_layer.array("MappingInformationType") != "ByPolygon" or material_layer.array("ReferenceInformationType") != "IndexToDirect":
        raise ValueError("Unexpected original FBX material mapping")
    uvs, uv_indices, materials = uv_layer.array("UV"), uv_layer.array("UVIndex"), material_layer.array("Materials")
    polygons, polygon = [], []
    for corner, vertex in enumerate(polygon_indices):
        polygon.append((-vertex - 1 if vertex < 0 else vertex, uv_indices[corner]))
        if vertex < 0:
            polygons.append(polygon)
            polygon = []
    if polygon or len(polygons) != len(materials):
        raise ValueError("Incomplete FBX polygons/material groups")

    json_length = struct.unpack_from("<I", glb_data, 12)[0]
    document = json.loads(glb_data[20:20 + json_length])
    binary = glb_data[28 + json_length:]
    primitives = document["meshes"][0]["primitives"]
    if len(primitives) != 2 or primitives[0]["attributes"] != primitives[1]["attributes"]:
        raise ValueError("Expected original duplicated GLB head streams")

    def accessor(index, width):
        item = document["accessors"][index]
        view = document["bufferViews"][item["bufferView"]]
        if item["componentType"] != 5126:
            raise ValueError("Expected float32 GLB position/UV accessor")
        offset = view.get("byteOffset", 0) + item.get("byteOffset", 0)
        stride = view.get("byteStride", width * 4)
        return [struct.unpack_from("<" + "f" * width, binary, offset + i * stride) for i in range(item["count"])]

    attributes = primitives[0]["attributes"]
    positions, texcoords = accessor(attributes["POSITION"], 3), accessor(attributes["TEXCOORD_0"], 2)

    def float32(value):
        return struct.unpack("<f", struct.pack("<f", value))[0]

    def key(position, texcoord):
        # Original double FBX coordinates are converted to float32 by GLTFExporter.
        # Only 12 corners differ further, by <=9.32e-10 centimetres in X. UVs match
        # float32 exactly. Canonicalize at 1e-6 cm; no spatial/colour classification.
        return tuple(round(float32(value), 6) for value in position) + tuple(float32(value) for value in texcoord)

    lookup = defaultdict(set)
    for polygon_index, polygon in enumerate(polygons):
        for vertex, uv in polygon:
            lookup[key(vertices[vertex * 3:vertex * 3 + 3], uvs[uv * 2:uv * 2 + 2])].add(polygon_index)
    keys = [key(position, uv) for position, uv in zip(positions, texcoords)]
    if len(keys) != 24768 or any(item not in lookup for item in keys):
        raise ValueError("Not every GLB head corner matches an original FBX position/UV corner")
    result, coverage = [], Counter()
    for index in range(0, len(keys), 3):
        matches = set.intersection(*(lookup[item] for item in keys[index:index + 3]))
        if len(matches) != 1:
            raise ValueError(f"GLB triangle {index // 3} has {len(matches)} source polygon matches")
        polygon = next(iter(matches))
        coverage[polygon] += 1
        result.append(materials[polygon])
    if any(coverage[index] != len(polygon) - 2 for index, polygon in enumerate(polygons)):
        raise ValueError("FBX polygon triangulation coverage is incomplete")
    if Counter(result) != Counter({0: 1820, 1: 6436}):
        raise ValueError("Unexpected material triangle totals")
    return {
        "version": 1, "positionAccessor": attributes["POSITION"], "triangleMaterials": result,
        "source": "Original FBX ByPolygon material indices, matched using all three GLB position/UV corners; every source polygon has exactly n-2 output triangles.",
        "sourceFBXURL": FBX_URL, "sourceFBXSHA256": FBX_SHA, "targetGLBSHA256": GLB_SHA,
        "headTriangleCount": len(result), "materialTriangleCounts": {"0": 1820, "1": 6436},
        "matchedCornerCount": len(keys), "matchedSourcePolygonCount": len(polygons),
        "ambiguousTriangleCount": 0, "missingTriangleCount": 0,
        "positionCanonicalizationCentimetres": 0.000001, "uvMatching": "exact float32"
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fbx", type=Path, required=True, help="Local original swat@T-Pose.fbx (see SOURCE.json for its public URL)")
    parser.add_argument("--glb", type=Path, default=ASSET_DIR / "soldier.glb")
    parser.add_argument("--output", type=Path, default=ASSET_DIR / "head-materials.json")
    parser.add_argument("--check", action="store_true", help="Verify the existing output byte-for-byte without writing it")
    args = parser.parse_args()
    result = recover(verified_bytes(args.fbx, FBX_SHA), verified_bytes(args.glb, GLB_SHA))
    encoded = (json.dumps(result, separators=(",", ":")) + "\n").encode()
    if args.check:
        if args.output.read_bytes() != encoded:
            raise ValueError(f"Material sidecar differs: {args.output}")
    else:
        args.output.write_bytes(encoded)
    print(f"{'Verified' if args.check else 'Restored'} {args.output}: 8256 head triangles, 1820 equipment + 6436 skin; all 4338 source polygons accounted for.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, StopIteration, struct.error, zlib.error) as error:
        print(f"SWAT material restoration failed: {error}", file=sys.stderr)
        sys.exit(1)
