"""Render GitHub-readable manuals and lossless screenshot annotation wrappers."""
from __future__ import annotations

import base64
import html
import math
import re

from user_guide_html import LANGUAGES, _UI
from user_guide_provenance import META_NAME


def _text(value: object) -> str:
    """Canonical content is plain text, not executable Markdown or HTML."""
    return re.sub(r"([\\`*_\[\]<>|])", r"\\\1", str(value)).replace("\n", " ")


def _anchor(identifier: str) -> str:
    if not re.fullmatch(r"[a-z][a-z0-9-]*", identifier):
        raise ValueError(f"Invalid chapter anchor: {identifier}")
    return f'<a name="{identifier}"></a>'


def render_markdown(data: dict, language: str, version: object, date: object,
                    source_hash: str) -> str:
    labels = _UI[language]
    meta = data["meta"]
    lines = [f"<!-- {META_NAME}: {source_hash} -->", "", _anchor("top"), "",
             f'# {_text(meta["title"])}', "",
             " · ".join(f'[{name}]({code}.md)' for code, name in LANGUAGES.items()), "",
             f'[← 알맹Re](../../README.md) · [PDF](pdf/AlmaengRe-User-Guide-{language}.pdf)', "",
             f'**{_text(meta["subtitle"])}**', "", _text(meta["intro"]), "",
             f'{labels["version"]} {version} · {labels["updated"]} {date}', "",
             f'> {_text(meta["uiLanguageNote"])}', "", f'## {labels["contents"]}', ""]
    lines.extend(f'- [{_text(chapter["title"])}](#{chapter["id"]})' for chapter in data["chapters"])
    lines.extend([f'- [{labels["shortcuts"]}](#shortcut-reference)', ""])
    figure_index = 0
    for chapter in data["chapters"]:
        lines.extend(["---", "", _anchor(chapter["id"]), "",
                      f'## {_text(chapter["title"])}', "", _text(chapter["summary"]), ""])
        figure = chapter["figure"]
        if figure:
            figure_index += 1
            lines.extend([f'![{_text(figure["caption"])}](figures/{figure["id"]}.png)', "",
                          f'**{labels["figure"]} {figure_index:02d}.** {_text(figure["caption"])}', ""])
            for callout in figure["callouts"]:
                lines.append(f'{callout["number"]}. **{_text(callout["title"])}** — {_text(callout["body"])}')
            lines.append("")
        lines.extend([f'### {labels["steps"]}', ""])
        lines.extend(f'{index}. {_text(step)}' for index, step in enumerate(chapter["steps"], 1))
        lines.append("")
        for detail in chapter["details"]:
            lines.extend([f'### {_text(detail["title"])}', "", _text(detail["body"]), ""])
        if chapter["tips"]:
            lines.extend([f'### {labels["tips"]}', ""])
            lines.extend(f'- {_text(tip)}' for tip in chapter["tips"])
            lines.append("")
        lines.extend([f'[{labels["top"]}](#top)', ""])
    lines.extend(["---", "", _anchor("shortcut-reference"), "",
                  f'## {labels["shortcuts"]}', "",
                  f'| {labels["keys"]} | {labels["action"]} | {labels["context"]} |',
                  "| --- | --- | --- |"])
    for shortcut in data["shortcuts"]:
        lines.append("| " + " | ".join(_text(shortcut[key]) for key in ("keys", "action", "context")) + " |")
    lines.extend(["", f'[{labels["top"]}](#top)', ""])
    return "\n".join(lines)


def render_index(documents: dict[str, dict], version: object, date: object) -> str:
    lines = ["# 알맹Re 사용 설명서 · User guides", "",
             "이미지 열기부터 비교, 분류, 지도, 편집까지 다루는 자세한 설명서입니다. 앱의 도움말에는 기본 사용법이 있습니다.", "",
             "Detailed guides to opening, comparing, tagging, mapping, and editing images. The app’s Help menu contains a short getting-started guide.", "",
             f"개발판 / Development version {version} · 기준일 / Reviewed {date}", "",
             f"이 문서는 {_text(version)} 개발판을 기준으로 합니다. 현재 공개된 이전 버전에는 일부 기능이나 메뉴가 없을 수 있습니다.", "",
             f"These manuals describe the {_text(version)} development version. Some features and menus may differ from an earlier published version.", "",
             "| 언어 / Language | 설명서 / Guide | PDF |", "| --- | --- | --- |"]
    for code, name in LANGUAGES.items():
        title = _text(documents[code]["meta"]["title"])
        lines.append(f"| {name} | [{title}]({code}.md) | [PDF](pdf/AlmaengRe-User-Guide-{code}.pdf) |")
    lines.extend(["", "각 설명서는 같은 실제 앱 화면과 번호 주석을 사용합니다. 화면은 한국어이며 설명과 번호 안내는 선택한 언어로 제공됩니다.", "",
                  "The guides share the same real app screenshots and numbered annotations. Screenshots use the Korean interface; explanations are provided in each guide’s language.", "",
                  "[← 알맹Re](../../README.md)", ""])
    return "\n".join(lines)


def render_figure(identifier: str, figure: dict, screenshot: bytes) -> str:
    """Embed the original JPEG bytes, with independent SVG annotation objects."""
    width, height = figure["width"], figure["height"]
    scale = width / 1000
    badge_margin = min(min(item["badge"][0] * width, (1 - item["badge"][0]) * width,
                           item["badge"][1] * height, (1 - item["badge"][1]) * height)
                       for item in figure["annotations"])
    radius, stroke = min(21 * scale, badge_margin - 2 * scale), 2.8 * scale
    if radius < 8 * scale:
        raise ValueError(f"Annotation badge too close to screenshot edge: {identifier}")
    badge_scale = radius / 21
    image = base64.b64encode(screenshot).decode("ascii")
    title = html.escape(f"알맹Re — {identifier}")
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title">',
             f'<title id="title">{title}</title>',
             f'<image width="{width}" height="{height}" href="data:image/jpeg;base64,{image}"/>',
             '<g fill="none" stroke-linecap="round" stroke-linejoin="round">']
    badges = []
    for item in figure["annotations"]:
        x, y, w, h = item["rect"]
        x, y, w, h = x * width, y * height, w * width, h * height
        rect = f'x="{x:.3f}" y="{y:.3f}" width="{w:.3f}" height="{h:.3f}" rx="{5 * scale:.3f}"'
        lines.extend([f'<rect {rect} stroke="#fff" stroke-width="{stroke + 3 * scale:.3f}"/>',
                      f'<rect {rect} stroke="#F4A340" stroke-width="{stroke:.3f}"/>'])
        bx, by = item["badge"][0] * width, item["badge"][1] * height
        tx, ty = item["target"][0] * width, item["target"][1] * height
        distance = math.hypot(tx - bx, ty - by)
        if distance > radius:
            ux, uy = (tx - bx) / distance, (ty - by) / distance
            sx, sy = bx + ux * radius, by + uy * radius
            line = f'x1="{sx:.3f}" y1="{sy:.3f}" x2="{tx:.3f}" y2="{ty:.3f}"'
            lines.extend([f'<line {line} stroke="#fff" stroke-width="{stroke + 2 * scale:.3f}"/>',
                          f'<line {line} stroke="#F4A340" stroke-width="{stroke:.3f}"/>'])
            length, half_width = min(13 * scale, distance / 3), 5 * scale
            ax, ay = tx - ux * length, ty - uy * length
            points = f'{tx:.3f},{ty:.3f} {ax - uy * half_width:.3f},{ay + ux * half_width:.3f} {ax + uy * half_width:.3f},{ay - ux * half_width:.3f}'
            lines.append(f'<polygon points="{points}" fill="#F4A340" stroke="none"/>')
        badges.extend([f'<circle cx="{bx:.3f}" cy="{by:.3f}" r="{radius:.3f}" fill="#F4A340" stroke="#fff" stroke-width="{3 * scale:.3f}"/>',
                       f'<text x="{bx:.3f}" y="{by + 7.5 * badge_scale:.3f}" text-anchor="middle" fill="#201A12" font-family="Arial,Helvetica,sans-serif" font-size="{23 * badge_scale:.3f}" font-weight="700">{item["number"]}</text>'])
    lines.extend(["</g>", *badges, "</svg>", ""])
    return "\n".join(lines)
