#!/usr/bin/env python3
"""Validate GitHub manuals and generated guides; detect unreviewed app changes.

Uses only the Python standard library. Run --record only after reviewing the
source changes and updating/visually checking the guides, captures, HTML and PDF.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
from html.parser import HTMLParser
from pathlib import Path
import sys

from user_guide_provenance import META_NAME, file_hash, guide_source_hash, load_figures
from user_guide_markdown import render_figure, render_index, render_markdown


LANGUAGES = ("ko", "en", "ja", "zh-Hans", "fr", "es", "vi")
FIGURES = ("home", "viewer", "overview", "compare", "tags", "tag-editor", "map",
           "editing", "settings", "shortcuts", "batch", "watermark", "video", "animation", "ai-upscaling")
META_KEYS = {"title", "subtitle", "intro", "uiLanguageNote"}
CHAPTER_KEYS = {"id", "title", "summary", "steps", "details", "tips", "figure"}
SOURCE_PATTERNS = (
    "Sources/ImageViewer/**/*.swift",
    "Sources/ImageViewer/Resources/*.lproj/*.strings",
    "Packaging/Info.plist",
)
MANIFEST_VERSION = 1


class GuideError(Exception):
    pass


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise GuideError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError, GuideError) as error:
        raise GuideError(f"{path.name}: {error}") from error


def object_keys(value: object, expected: set[str], location: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise GuideError(f"{location}: expected fields {', '.join(sorted(expected))}")


def nonempty_text(value: object, location: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise GuideError(f"{location}: expected nonempty text")


def text_list(value: object, location: str) -> None:
    if not isinstance(value, list):
        raise GuideError(f"{location}: expected an array")
    for index, item in enumerate(value):
        nonempty_text(item, f"{location}[{index}]")


def document_signature(document: object, language: str) -> tuple:
    """Validate required fields and return the translation-independent shape."""
    object_keys(document, {"meta", "chapters", "shortcuts"}, language)
    object_keys(document["meta"], META_KEYS, f"{language}.meta")
    for key, text in document["meta"].items():
        nonempty_text(text, f"{language}.meta.{key}")

    chapters = document["chapters"]
    if not isinstance(chapters, list) or not chapters:
        raise GuideError(f"{language}.chapters: expected a nonempty array")
    identifiers = set()
    chapter_shapes = []
    used_figures = set()
    for index, chapter in enumerate(chapters):
        where = f"{language}.chapters[{index}]"
        object_keys(chapter, CHAPTER_KEYS, where)
        for key in ("id", "title", "summary"):
            nonempty_text(chapter[key], f"{where}.{key}")
        identifier = chapter["id"]
        if identifier in identifiers:
            raise GuideError(f"{where}: repeated chapter id {identifier}")
        identifiers.add(identifier)
        for key in ("steps", "tips"):
            text_list(chapter[key], f"{where}.{key}")
        details = chapter["details"]
        if not isinstance(details, list):
            raise GuideError(f"{where}.details: expected an array")
        for detail_index, detail in enumerate(details):
            detail_where = f"{where}.details[{detail_index}]"
            object_keys(detail, {"title", "body"}, detail_where)
            for key in ("title", "body"):
                nonempty_text(detail[key], f"{detail_where}.{key}")

        figure = chapter["figure"]
        figure_shape = None
        if figure is not None:
            object_keys(figure, {"id", "caption", "callouts"}, f"{where}.figure")
            if figure["id"] not in FIGURES:
                raise GuideError(f"{where}.figure: unknown figure id {figure['id']!r}")
            used_figures.add(figure["id"])
            nonempty_text(figure["caption"], f"{where}.figure.caption")
            callouts = figure["callouts"]
            if not isinstance(callouts, list) or not callouts:
                raise GuideError(f"{where}.figure.callouts: expected a nonempty array")
            numbers = []
            for callout_index, callout in enumerate(callouts):
                callout_where = f"{where}.figure.callouts[{callout_index}]"
                object_keys(callout, {"number", "title", "body"}, callout_where)
                number = callout["number"]
                if type(number) is not int or number < 1 or number in numbers:
                    raise GuideError(f"{callout_where}.number: expected a unique positive integer")
                numbers.append(number)
                for key in ("title", "body"):
                    nonempty_text(callout[key], f"{callout_where}.{key}")
            figure_shape = (figure["id"], tuple(numbers))
        chapter_shapes.append((identifier, len(chapter["steps"]), len(details),
                               len(chapter["tips"]), figure_shape))
    if used_figures != set(FIGURES):
        raise GuideError(f"{language}: missing figures {', '.join(sorted(set(FIGURES) - used_figures))}")

    shortcuts = document["shortcuts"]
    if not isinstance(shortcuts, list) or not shortcuts:
        raise GuideError(f"{language}.shortcuts: expected a nonempty array")
    shortcut_keys = []
    for index, shortcut in enumerate(shortcuts):
        where = f"{language}.shortcuts[{index}]"
        object_keys(shortcut, {"keys", "action", "context"}, where)
        for key in ("keys", "action", "context"):
            nonempty_text(shortcut[key], f"{where}.{key}")
        shortcut_keys.append(shortcut["keys"])
    return tuple(chapter_shapes), tuple(shortcut_keys)


class ResourceReferences(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.images: set[str] = set()
        self.remote_dependencies: set[str] = set()
        self.has_html = False
        self.in_head = False
        self.source_hashes: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "html":
            self.has_html = True
        if tag == "head":
            self.in_head = True
        if tag == "meta" and self.in_head and attributes.get("name") == META_NAME:
            self.source_hashes.append(attributes.get("content", "") or "")
        if tag == "img" and attributes.get("src"):
            self.images.add(attributes["src"])
        if tag in ("img", "script", "iframe", "source", "video", "audio"):
            reference = attributes.get("src", "") or ""
        elif tag == "link" and "stylesheet" in (attributes.get("rel", "") or ""):
            reference = attributes.get("href", "") or ""
        else:
            reference = ""
        if reference.startswith(("http://", "https://", "//")):
            self.remote_dependencies.add(reference)

    def handle_endtag(self, tag: str) -> None:
        if tag == "head":
            self.in_head = False


def validate_figure_exports(root: Path, figures: dict, errors: list[str]) -> None:
    """Check exported PNGs and provenance without Node, sharp, or image decoding."""
    directory = root / "docs/user-guide/figures"
    renderer_path = "scripts/render-user-guide-figures.cjs"
    try:
        manifest = read_json(directory / "render-manifest.json")
        object_keys(manifest, {"version", "renderer", "figures"}, "figure render manifest")
        if manifest["version"] != 1:
            raise GuideError("figure render manifest: unsupported version")
        renderer = manifest["renderer"]
        object_keys(renderer, {"file", "sha256", "sharp", "vips"}, "figure renderer")
        if renderer["file"] != renderer_path or renderer["sha256"] != file_hash(root / renderer_path):
            raise GuideError("Figure PNG renderer changed; regenerate the figure exports")
        for field in ("sharp", "vips"):
            nonempty_text(renderer[field], f"figure renderer.{field}")
        entries = manifest["figures"]
        object_keys(entries, set(figures), "figure render manifest.figures")
    except (OSError, GuideError) as error:
        errors.append(str(error))
        return
    for identifier, figure in figures.items():
        try:
            entry = entries[identifier]
            object_keys(entry, {"svg", "svgSHA256", "png", "pngSHA256", "width", "height"},
                        f"figure export {identifier}")
            svg, png = f"{identifier}.svg", f"{identifier}.png"
            if entry["svg"] != svg or entry["png"] != png:
                raise GuideError(f"Figure {identifier}: incorrect export filenames")
            if entry["svgSHA256"] != file_hash(directory / svg):
                raise GuideError(f"Figure {identifier}: SVG changed after PNG export")
            if entry["pngSHA256"] != file_hash(directory / png):
                raise GuideError(f"Figure {identifier}: missing or stale PNG fingerprint")
            with (directory / png).open("rb") as image:
                header = image.read(24)
            if (len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n"
                    or header[8:16] != b"\x00\x00\x00\rIHDR"):
                raise GuideError(f"Figure {identifier}: invalid PNG signature/IHDR")
            size = (int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big"))
            if (type(entry["width"]) is not int or type(entry["height"]) is not int
                    or size != (entry["width"], entry["height"])
                    or size != (figure["width"], figure["height"])):
                raise GuideError(f"Figure {identifier}: PNG dimensions differ from the source document")
        except (OSError, GuideError) as error:
            errors.append(str(error))


def validate_resources(root: Path, errors: list[str], *, require_output: bool = False,
                       require_pdfs: bool = False) -> None:
    """GitHub files are required; local HTML/PDF publication checks are explicit.

    No full manual assets are loaded from or copied into the application bundle.
    SVG figures retain byte-identical JPEG screenshots as data images; comparing
    the complete SVG also detects accidental annotation or source-image edits.
    """
    guide = root / "docs/user-guide"
    output = root / "output/user-guide"
    try:
        figures = load_figures(root)
        if set(figures) != set(FIGURES):
            raise ValueError("figures.json figure ids do not match the guide")
        edition = read_json(guide / "edition.json")
        version, date = edition["appVersion"], edition["reviewedOn"]
        app_version = plistlib.loads((root / "Packaging/Info.plist").read_bytes())["CFBundleShortVersionString"]
        if version != app_version:
            errors.append("edition.json: appVersion differs from Packaging/Info.plist")
        documents = {language: read_json(guide / "content" / f"{language}.json") for language in LANGUAGES}
    except (ValueError, OSError, KeyError, GuideError) as error:
        errors.append(str(error))
        return

    def expect_text(path: Path, expected: str) -> None:
        try:
            if path.read_text(encoding="utf-8") != expected:
                errors.append(f"{path.relative_to(root)}: stale or edited generated content; rebuild the guides")
        except (OSError, UnicodeError) as error:
            errors.append(f"{path.relative_to(root)}: {error}")

    expect_text(guide / "README.md", render_index(documents, version, date))
    for identifier, figure in figures.items():
        try:
            source = (guide / "screenshots" / figure["file"]).read_bytes()
            expect_text(guide / "figures" / f"{identifier}.svg", render_figure(identifier, figure, source))
        except (OSError, ValueError) as error:
            errors.append(f"Figure {identifier}: {error}")
    validate_figure_exports(root, figures, errors)
    hashes = {}
    for language, document in documents.items():
        try:
            hashes[language] = guide_source_hash(root, language)
            expect_text(guide / f"{language}.md", render_markdown(
                document, language, version, date, hashes[language]))
        except (OSError, ValueError, KeyError, TypeError) as error:
            errors.append(f"Markdown {language}: {error}")

    # A checkout with only reader-ready docs does not need local build products.
    # When any HTML output exists, validate the entire seven-language edition.
    validate_html = require_output or require_pdfs or any(output.glob("UserGuide-*.html"))
    if validate_html:
        from user_guide_html import render_html
        expected_images = {f"UserGuide-{figure}.jpg" for figure in FIGURES}
        for identifier, figure in figures.items():
            try:
                if file_hash(guide / "screenshots" / figure["file"]) != file_hash(output / f"UserGuide-{identifier}.jpg"):
                    errors.append(f"UserGuide-{identifier}.jpg differs from its source screenshot")
            except OSError as error:
                errors.append(f"HTML screenshot {identifier}: {error}")
        for language, document in documents.items():
            path = output / f"UserGuide-{language}.html"
            try:
                content = path.read_text(encoding="utf-8")
                parser = ResourceReferences()
                parser.feed(content)
                expected_hash = hashes[language]
                if not parser.has_html or parser.source_hashes != [expected_hash]:
                    errors.append(f"{path.name}: missing HTML document or stale source hash")
                if parser.images != expected_images:
                    errors.append(f"{path.name}: incorrect local screenshot references")
                if parser.remote_dependencies:
                    errors.append(f"{path.name}: offline guide has remote dependencies")
                expected = render_html(document, language, figures, version, date).replace(
                    "</head>", f'<meta name="{META_NAME}" content="{expected_hash}">\n</head>', 1)
                expect_text(path, expected)
            except (OSError, UnicodeError, ValueError, KeyError) as error:
                errors.append(f"{path.name}: {error}")

    if require_pdfs:
        try:
            build_info = read_json(output / "build-info.json")
            if (build_info.get("generation") != "html-and-pdf"
                    or set(build_info.get("languages", [])) != set(LANGUAGES)
                    or build_info.get("sourceHashes") != hashes
                    or build_info.get("appVersion") != version
                    or build_info.get("reviewedOn") != date):
                raise GuideError("build-info.json: rebuild the complete seven-language PDF edition")
            pdf_hashes = build_info.get("pdfs", {})
            for language in LANGUAGES:
                name = f"AlmaengRe-User-Guide-{language}.pdf"
                repo_pdf, local_pdf = guide / "pdf" / name, root / "output/pdf" / name
                for path in (repo_pdf, local_pdf):
                    with path.open("rb") as pdf:
                        if pdf.read(5) != b"%PDF-":
                            errors.append(f"{path.relative_to(root)}: missing PDF signature")
                    if pdf_hashes.get(path.relative_to(root).as_posix()) != file_hash(path):
                        errors.append(f"{path.relative_to(root)}: missing or stale PDF fingerprint")
                if file_hash(repo_pdf) != file_hash(local_pdf):
                    errors.append(f"{name}: GitHub and local PDFs differ")
        except (OSError, GuideError) as error:
            errors.append(str(error))


def source_hashes(root: Path) -> dict[str, str]:
    files: set[Path] = set()
    for pattern in SOURCE_PATTERNS:
        matched = {path for path in root.glob(pattern) if path.is_file()}
        if not matched:
            raise GuideError(f"No tracked sources matched {pattern}")
        files.update(matched)
    return {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(files)}


def validate_manifest(manifest_path: Path, current: dict[str, str], errors: list[str]) -> None:
    try:
        manifest = read_json(manifest_path)
        object_keys(manifest, {"version", "patterns", "sources"}, "source-manifest.json")
        if manifest["version"] != MANIFEST_VERSION or manifest["patterns"] != list(SOURCE_PATTERNS):
            raise GuideError("source-manifest.json: unsupported version or tracking patterns")
        previous = manifest["sources"]
        if not isinstance(previous, dict) or not all(
                isinstance(key, str) and isinstance(value, str) and len(value) == 64
                for key, value in previous.items()):
            raise GuideError("source-manifest.json: invalid SHA256 source map")
        for key in sorted(current.keys() - previous.keys()):
            errors.append(f"Unreviewed source added: {key}")
        for key in sorted(previous.keys() - current.keys()):
            errors.append(f"Reviewed source removed: {key}")
        for key in sorted(current.keys() & previous.keys()):
            if current[key] != previous[key]:
                errors.append(f"Unreviewed source change: {key}")
    except GuideError as error:
        errors.append(str(error))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true",
                        help="record reviewed source fingerprints after updating and checking all guides")
    parser.add_argument("--require-output", action="store_true",
                        help="require and validate the complete local HTML edition")
    parser.add_argument("--require-pdfs", action="store_true",
                        help="require all GitHub/local PDFs and their current build provenance")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="repository root (defaults to this script's parent repository)")
    args = parser.parse_args()
    root = args.root.resolve()
    guide_directory = root / "docs/user-guide"
    errors: list[str] = []
    signatures = {}
    for language in LANGUAGES:
        try:
            signatures[language] = document_signature(
                read_json(guide_directory / "content" / f"{language}.json"), language)
        except GuideError as error:
            errors.append(str(error))
    if "en" in signatures:
        for language, signature in signatures.items():
            if signature != signatures["en"]:
                errors.append(f"{language}: chapter structure, ids, figures, callouts, or shortcut keys differ from en")
    if len(signatures) == len(LANGUAGES):
        validate_resources(root, errors, require_output=args.require_output, require_pdfs=args.require_pdfs)
    try:
        current = source_hashes(root)
    except (GuideError, OSError) as error:
        errors.append(str(error))
        current = {}
    manifest_path = guide_directory / "source-manifest.json"
    if not args.record:
        validate_manifest(manifest_path, current, errors)
    if errors:
        print("User guide check failed:", file=sys.stderr)
        for error in errors[:40]:
            print(f"  - {error}", file=sys.stderr)
        if len(errors) > 40:
            print(f"  ... and {len(errors) - 40} more", file=sys.stderr)
        print("Review the changes, update and visually verify the guides, then use --record. "
              "See docs/user-guide/MAINTENANCE.md.", file=sys.stderr)
        return 1
    if args.record:
        manifest = {"version": MANIFEST_VERSION, "patterns": list(SOURCE_PATTERNS), "sources": current}
        temporary = manifest_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temporary.replace(manifest_path)
        print(f"Recorded {len(current)} reviewed source fingerprints. Commit the updated guides and manifest together.")
    else:
        print(f"User guide check passed: {len(LANGUAGES)} languages, {len(FIGURES)} figures, "
              f"{len(current)} reviewed sources.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
