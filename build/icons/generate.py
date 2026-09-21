"""Generate desktop icons from public/favicon.svg (requires Pillow and macOS iconutil)."""

from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw


HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[1] / "public" / "favicon.svg"
OUTPUT_SIZE = 1024
SUPERSAMPLE = 4
SCALE = OUTPUT_SIZE * SUPERSAMPLE / 64


def path_points(data):
    """Read the orthogonal M/H/V paths used by the shared maze mark."""
    tokens = re.findall(r"[A-Za-z]|-?\d+(?:\.\d+)?", data)
    points = []
    x = y = 0.0
    cursor = 0
    while cursor < len(tokens):
        command = tokens[cursor]
        cursor += 1
        if command == "M":
            x, y = float(tokens[cursor]), float(tokens[cursor + 1])
            cursor += 2
        elif command == "H":
            x = float(tokens[cursor])
            cursor += 1
        elif command == "V":
            y = float(tokens[cursor])
            cursor += 1
        elif command == "h":
            x += float(tokens[cursor])
            cursor += 1
        elif command == "v":
            y += float(tokens[cursor])
            cursor += 1
        else:
            raise ValueError(f"Unsupported SVG command: {command}")
        points.append((x * SCALE, y * SCALE))
    return points


def render_mark():
    root = ET.parse(SOURCE).getroot()
    canvas = Image.new("RGBA", (OUTPUT_SIZE * SUPERSAMPLE,) * 2)
    draw = ImageDraw.Draw(canvas)
    for element in root:
        tag = element.tag.rsplit("}", 1)[-1]
        if tag == "rect":
            width = float(element.attrib["width"]) * SCALE
            height = float(element.attrib["height"]) * SCALE
            radius = float(element.attrib["rx"]) * SCALE
            draw.rounded_rectangle((0, 0, width, height), radius, fill=element.attrib["fill"])
        elif tag == "path":
            points = path_points(element.attrib["d"])
            half = float(element.attrib["stroke-width"]) * SCALE / 2
            color = element.attrib["stroke"]
            for (x1, y1), (x2, y2) in zip(points, points[1:]):
                if x1 == x2:
                    bounds = (x1 - half, min(y1, y2), x1 + half, max(y1, y2))
                elif y1 == y2:
                    bounds = (min(x1, x2), y1 - half, max(x1, x2), y1 + half)
                else:
                    raise ValueError("The shared maze mark must use orthogonal segments")
                draw.rectangle(bounds, fill=color)
            # SVG's default miter joins preserve the maze's square corners.
            for x, y in points[1:-1]:
                draw.rectangle((x - half, y - half, x + half, y + half), fill=color)
    return canvas.resize((OUTPUT_SIZE, OUTPUT_SIZE), Image.Resampling.LANCZOS)


icon = render_mark()
icon.save(HERE / "nachtgang.png")
icon.save(HERE / "nachtgang.ico", sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)])
iconset = HERE / "nachtgang.iconset"
iconset.mkdir(exist_ok=True)
for size in (16, 32, 128, 256, 512):
    for multiplier in (1, 2):
        pixels = size * multiplier
        suffix = "@2x" if multiplier == 2 else ""
        icon.resize((pixels, pixels), Image.Resampling.LANCZOS).save(
            iconset / f"icon_{size}x{size}{suffix}.png"
        )
subprocess.run(
    ["iconutil", "-c", "icns", str(iconset), "-o", str(HERE / "nachtgang.icns")],
    check=True,
)
print(f"Generated PNG, ICO and ICNS icons from {SOURCE}")
