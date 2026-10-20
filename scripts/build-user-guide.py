#!/usr/bin/env python3
"""Build GitHub manuals, annotated SVGs, offline HTML, and printable PDFs."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
from user_guide_provenance import META_NAME, file_hash, guide_source_hash, load_figures

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("ko", "en", "ja", "zh-Hans", "fr", "es", "vi")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--languages", nargs="+", choices=LANGUAGES, default=list(LANGUAGES))
    parser.add_argument("--html-only", action="store_true", help="Build Markdown, SVG/PNG figures, and HTML; skip PDFs")
    args = parser.parse_args()
    source = ROOT / "docs/user-guide"
    figures = load_figures(ROOT)
    release = json.loads((source / "edition.json").read_text())
    version = plistlib.loads((ROOT / "Packaging/Info.plist").read_bytes())["CFBundleShortVersionString"]
    if version != release["appVersion"]:
        parser.error("Review the guide for this app version and update edition.json before rebuilding.")
    date = release["reviewedOn"]
    html_dir = ROOT / "output/user-guide"
    pdf_dir = ROOT / "output/pdf"
    figure_dir = source / "figures"
    repository_pdf_dir = source / "pdf"
    for directory in (html_dir, pdf_dir, figure_dir, repository_pdf_dir):
        directory.mkdir(parents=True, exist_ok=True)

    from user_guide_markdown import render_figure, render_index, render_markdown
    hashes = {}
    generated = {}
    for identifier, figure in figures.items():
        screenshot = source / "screenshots" / figure["file"]
        hashes[screenshot.relative_to(ROOT).as_posix()] = hashlib.sha256(screenshot.read_bytes()).hexdigest()
        shutil.copyfile(screenshot, html_dir / f"UserGuide-{identifier}.jpg")
        svg_path = figure_dir / f"{identifier}.svg"
        svg_path.write_text(render_figure(identifier, figure, screenshot.read_bytes()), encoding="utf-8")
        generated[svg_path.relative_to(ROOT).as_posix()] = file_hash(svg_path)

    # Node and sharp are generation-time dependencies only. The checker verifies
    # the recorded SVG/PNG hashes using Python without launching this renderer.
    node = os.environ.get("USER_GUIDE_NODE", "node")
    try:
        subprocess.run([node, str(ROOT / "scripts/render-user-guide-figures.cjs"),
                        str(figure_dir), *figures], check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        parser.error(f"Figure export failed. Put node on PATH (or set USER_GUIDE_NODE), "
                     f"and install sharp locally or set NODE_PATH. {error}")
    for path in [*(figure_dir / f"{identifier}.png" for identifier in figures),
                 figure_dir / "render-manifest.json"]:
        generated[path.relative_to(ROOT).as_posix()] = file_hash(path)

    from user_guide_html import render_html
    if not args.html_only:
        from user_guide_pdf import render_pdf
    source_hashes = {}
    pdf_hashes = {}
    documents = {language: json.loads((source / "content" / f"{language}.json").read_text())
                 for language in LANGUAGES}
    index_path = source / "README.md"
    index_path.write_text(render_index(documents, version, date), encoding="utf-8")
    generated[index_path.relative_to(ROOT).as_posix()] = file_hash(index_path)
    for language in args.languages:
        content_file = source / "content" / f"{language}.json"
        data = documents[language]
        if {chapter["figure"]["id"] for chapter in data["chapters"] if chapter["figure"]} != set(figures):
            raise ValueError(f"Figure/content mismatch: {language}")
        html = render_html(data, language, figures, version, date)
        source_hash = guide_source_hash(ROOT, language)
        source_hashes[language] = source_hash
        if "</head>" not in html:
            raise ValueError(f"Missing HTML head: {language}")
        html = html.replace("</head>",
            f'<meta name="{META_NAME}" content="{source_hash}">\n</head>', 1)
        html_path = html_dir / f"UserGuide-{language}.html"
        html_path.write_text(html, encoding="utf-8")
        generated[html_path.relative_to(ROOT).as_posix()] = file_hash(html_path)
        markdown_path = source / f"{language}.md"
        markdown_path.write_text(render_markdown(data, language, version, date, source_hash), encoding="utf-8")
        generated[markdown_path.relative_to(ROOT).as_posix()] = file_hash(markdown_path)
        hashes[content_file.relative_to(ROOT).as_posix()] = hashlib.sha256(content_file.read_bytes()).hexdigest()
        if not args.html_only:
            output = pdf_dir / f"AlmaengRe-User-Guide-{language}.pdf"
            render_pdf(data, language, figures, version, date, output, source / "screenshots")
            pdf_hashes[output.relative_to(ROOT).as_posix()] = file_hash(output)
            repository_pdf = repository_pdf_dir / output.name
            shutil.copyfile(output, repository_pdf)
            pdf_hashes[repository_pdf.relative_to(ROOT).as_posix()] = file_hash(repository_pdf)
        print(f"Built {language}: Markdown + SVG/PNG + HTML" + (" + PDF" if not args.html_only else ""))
    # This is build provenance only. It never marks application changes as reviewed.
    (html_dir / "build-info.json").write_text(json.dumps({
        "appVersion": version, "reviewedOn": date, "languages": args.languages,
        "inputs": hashes, "sourceHashes": source_hashes, "pdfs": pdf_hashes, "outputs": generated,
        "generation": "html-only" if args.html_only else "html-and-pdf",
    }, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
