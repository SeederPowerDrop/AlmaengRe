"""Shared standard-library input validation and guide provenance."""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path


META_NAME = "almeng-guide-source-sha256"
RENDER_SOURCES = (
    "scripts/build-user-guide.py",
    "scripts/user_guide_html.py",
    "scripts/user_guide_markdown.py",
    "scripts/render-user-guide-figures.cjs",
    "scripts/user_guide_pdf.py",
    "scripts/user_guide_provenance.py",
)


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def screenshot_sources(root: Path) -> dict[str, Path]:
    directory = root / "docs/user-guide"
    figures = json.loads((directory / "figures.json").read_text(encoding="utf-8"))
    if not isinstance(figures, dict) or not figures:
        raise ValueError("figures.json must contain the named figures")
    result = {}
    for identifier, figure in figures.items():
        filename = figure.get("file") if isinstance(figure, dict) else None
        if (not isinstance(filename, str) or Path(filename).suffix.lower() not in (".jpg", ".jpeg")
                or Path(filename).name != filename):
            raise ValueError(f"figures.json: {identifier} needs a local JPEG filename")
        result[identifier] = directory / "screenshots" / filename
    return result


def jpeg_dimensions(path: Path) -> tuple[int, int]:
    """Read JPEG SOF dimensions without decoding, resaving, or requiring Pillow."""
    data = path.read_bytes()
    if data[:2] != b"\xff\xd8":
        raise ValueError(f"Not a JPEG screenshot: {path}")
    offset = 2
    sof_markers = {0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
                   0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf}
    while offset < len(data):
        if data[offset] != 0xff:
            break
        while offset < len(data) and data[offset] == 0xff:
            offset += 1
        if offset >= len(data):
            break
        marker = data[offset]
        offset += 1
        if marker in (0xd9, 0xda):
            break
        if marker == 0x01 or 0xd0 <= marker <= 0xd7:
            continue
        length = int.from_bytes(data[offset:offset + 2], "big")
        if length < 2 or offset + length > len(data):
            break
        if marker in sof_markers and length >= 8:
            height = int.from_bytes(data[offset + 3:offset + 5], "big")
            width = int.from_bytes(data[offset + 5:offset + 7], "big")
            if width and height:
                return width, height
            break
        offset += length
    raise ValueError(f"Invalid JPEG dimensions: {path}")


def load_figures(root: Path) -> dict:
    """Validate normalized annotations and add actual screenshot dimensions."""
    directory = root / "docs/user-guide"
    figures = json.loads((directory / "figures.json").read_text(encoding="utf-8"))
    screenshots = screenshot_sources(root)
    for identifier, figure in figures.items():
        width, height = jpeg_dimensions(screenshots[identifier])
        figure.update(width=width, height=height)
        annotations = figure.get("annotations")
        if (not isinstance(annotations, list) or not all(isinstance(item, dict) for item in annotations)
                or [item.get("number") for item in annotations] != [1, 2, 3]):
            raise ValueError(f"Expected three numbered annotations for {identifier}")
        for item in annotations:
            for field, count in (("rect", 4), ("badge", 2), ("target", 2)):
                values = item.get(field)
                if (not isinstance(values, list) or len(values) != count
                        or not all(type(value) in (int, float) and math.isfinite(value)
                                   and 0 <= value <= 1 for value in values)):
                    raise ValueError(f"Invalid normalized coordinates: {identifier}/{field}")
            x, y, w, h = item["rect"]
            if w <= 0 or h <= 0 or x + w > 1.000001 or y + h > 1.000001:
                raise ValueError(f"Rectangle outside screenshot: {identifier}")
    return figures


def guide_source_inputs(root: Path, language: str) -> dict[str, str]:
    """Hash raw input bytes individually before combining paths and digests.

    Screenshot bytes are included because a changed image size also affects the
    generated layout. SVG wrappers and HTML images must match these source bytes.
    """
    paths = [root / f"docs/user-guide/content/{language}.json",
             root / "docs/user-guide/figures.json",
             root / "docs/user-guide/edition.json"]
    paths.extend(root / relative for relative in RENDER_SOURCES)
    paths.extend(screenshot_sources(root).values())
    return {path.relative_to(root).as_posix(): file_hash(path) for path in sorted(paths)}


def guide_source_hash(root: Path, language: str) -> str:
    # Canonical JSON includes every path and its fixed-width digest; unlike raw
    # concatenation, different file boundaries cannot yield the same payload.
    payload = json.dumps(guide_source_inputs(root, language), sort_keys=True,
                         ensure_ascii=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()
