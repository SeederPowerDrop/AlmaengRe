"""Render the localized user guide as a bookmarked, printable PDF.

Screenshots are embedded unchanged. Highlights, arrows, and numbered badges
are PDF vector objects, independent of the shared screenshot pixels.
"""

from __future__ import annotations

from html import escape
import math
from pathlib import Path
from typing import Any

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate, Flowable, Frame, PageBreak, PageTemplate,
    Paragraph, Spacer, Table, TableStyle,
)
from reportlab.platypus.tableofcontents import TableOfContents


FONT_NAME = "AlmaengGuideUnicode"
FONT_PATH = Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
PAGE_WIDTH, PAGE_HEIGHT = A4
MARGIN = 48
TOP_MARGIN = 51
BOTTOM_MARGIN = 47
CONTENT_WIDTH = PAGE_WIDTH - MARGIN * 2
CONTENT_HEIGHT = PAGE_HEIGHT - TOP_MARGIN - BOTTOM_MARGIN
INK = colors.HexColor("#152C40")
BODY = colors.HexColor("#263D4F")
MUTED = colors.HexColor("#596D7C")
ACCENT = colors.HexColor("#086E8F")
ANNOTATION = colors.HexColor("#F4A340")
BADGE_TEXT = colors.HexColor("#201A12")
LIGHT = colors.HexColor("#EDF5F8")
RULE = colors.HexColor("#D9E3E9")

LABELS = {
    "ko": {"language": "한국어", "guide": "사용설명서", "toc": "목차", "steps": "시작하기", "tips": "알아두세요", "figure": "그림", "reference": "단축키 빠른 참조", "keys": "키", "action": "동작", "context": "사용 조건", "version": "버전", "updated": "기준일"},
    "en": {"language": "English", "guide": "User Guide", "toc": "Contents", "steps": "Get started", "tips": "Keep in mind", "figure": "Figure", "reference": "Shortcut reference", "keys": "Keys", "action": "Action", "context": "When it applies", "version": "Version", "updated": "Updated"},
    "ja": {"language": "日本語", "guide": "ユーザーガイド", "toc": "目次", "steps": "操作の手順", "tips": "覚えておくこと", "figure": "図", "reference": "ショートカット早見表", "keys": "キー", "action": "操作", "context": "使用条件", "version": "バージョン", "updated": "基準日"},
    "zh-Hans": {"language": "简体中文", "guide": "使用手册", "toc": "目录", "steps": "操作步骤", "tips": "使用提示", "figure": "图", "reference": "快捷键速查", "keys": "按键", "action": "操作", "context": "适用条件", "version": "版本", "updated": "更新日期"},
    "fr": {"language": "Français", "guide": "Guide d’utilisation", "toc": "Sommaire", "steps": "Pour commencer", "tips": "À retenir", "figure": "Figure", "reference": "Référence des raccourcis", "keys": "Touches", "action": "Action", "context": "Conditions d’utilisation", "version": "Version", "updated": "Mise à jour"},
    "es": {"language": "Español", "guide": "Guía de uso", "toc": "Contenido", "steps": "Primeros pasos", "tips": "Ten en cuenta", "figure": "Figura", "reference": "Referencia de atajos", "keys": "Teclas", "action": "Acción", "context": "Cuándo se aplica", "version": "Versión", "updated": "Actualización"},
    "vi": {"language": "Tiếng Việt", "guide": "Hướng dẫn sử dụng", "toc": "Mục lục", "steps": "Bắt đầu", "tips": "Lưu ý", "figure": "Hình", "reference": "Tra cứu phím tắt", "keys": "Phím", "action": "Thao tác", "context": "Điều kiện sử dụng", "version": "Phiên bản", "updated": "Ngày cập nhật"},
}


def _register_font() -> None:
    if FONT_NAME not in pdfmetrics.getRegisteredFontNames():
        if not FONT_PATH.is_file():
            raise FileNotFoundError(f"The guide font is missing: {FONT_PATH}")
        pdfmetrics.registerFont(TTFont(FONT_NAME, str(FONT_PATH)))
        pdfmetrics.registerFontFamily(
            FONT_NAME, normal=FONT_NAME, bold=FONT_NAME,
            italic=FONT_NAME, boldItalic=FONT_NAME,
        )


def _text(value: Any) -> str:
    # Keep the document's shortcuts and arrows verbatim. Normalize only the
    # uncommon nonbreaking hyphen, which otherwise has inconsistent rendering.
    return escape(str(value).replace("\u2011", "-"), quote=False).replace("\n", "<br/>")


def _styles(language: str) -> dict[str, ParagraphStyle]:
    base = dict(
        fontName=FONT_NAME, textColor=BODY, fontSize=10.5, leading=16,
        spaceAfter=7, allowWidows=0, allowOrphans=0, splitLongWords=1,
    )
    if language in {"ko", "ja", "zh-Hans"}:
        base["wordWrap"] = "CJK"
    normal = ParagraphStyle("GuideBody", **base)
    definitions = {
        "body": {},
        "step": {"leftIndent": 20, "bulletIndent": 0, "spaceAfter": 8},
        "title": {"fontSize": 21, "leading": 28, "textColor": INK, "spaceAfter": 12, "keepWithNext": True},
        "section": {"fontSize": 11.6, "leading": 16, "textColor": ACCENT, "spaceBefore": 8, "spaceAfter": 3, "keepWithNext": True},
        "summary": {"fontSize": 11.1, "leading": 17, "textColor": MUTED, "spaceAfter": 14},
        "caption": {"fontSize": 10.1, "leading": 15, "textColor": MUTED, "spaceAfter": 11},
        "callout": {"fontSize": 10, "leading": 15, "spaceAfter": 0},
        "tip": {"fontSize": 9.7, "leading": 14.5, "spaceAfter": 0},
        "eyebrow": {"fontSize": 9.2, "leading": 13, "textColor": ACCENT, "spaceAfter": 8},
        "coverTitle": {"fontSize": 34, "leading": 44, "textColor": INK, "spaceAfter": 18},
        "coverSubtitle": {"fontSize": 17, "leading": 26, "textColor": ACCENT, "spaceAfter": 27},
        "coverIntro": {"fontSize": 11.4, "leading": 18, "spaceAfter": 18},
        "table": {"fontSize": 9, "leading": 13, "spaceAfter": 0},
        "tableKeys": {"fontSize": 9.3, "leading": 13, "spaceAfter": 0, "textColor": ACCENT},
        "tableHeader": {"fontSize": 9.5, "leading": 14, "spaceAfter": 0, "textColor": colors.white},
    }
    return {name: ParagraphStyle("Guide" + name, parent=normal, **values)
            for name, values in definitions.items()}


class _Rule(Flowable):
    def __init__(self, width: float, color=ACCENT, thickness: float = 2):
        super().__init__()
        self.width = width
        self.height = thickness + 7
        self.color = color
        self.thickness = thickness

    def draw(self) -> None:
        self.canv.setStrokeColor(self.color)
        self.canv.setLineWidth(self.thickness)
        self.canv.line(0, self.height - self.thickness / 2,
                       self.width, self.height - self.thickness / 2)


class AnnotatedScreenshot(Flowable):
    """An original raster screenshot with normalized vector annotations.

    Rectangle, badge, and target coordinates use a top-left origin and 0..1
    proportions. No resizing or drawing is written back into the source JPEG.
    """

    def __init__(self, path: Path, figure: dict, max_width: float, max_height: float):
        super().__init__()
        self.path = path
        self.image = ImageReader(str(path))
        image_width, image_height = self.image.getSize()
        metadata_width = figure.get("width", image_width)
        metadata_height = figure.get("height", image_height)
        if metadata_width <= 0 or metadata_height <= 0:
            raise ValueError(f"Invalid screenshot dimensions: {path.name}")
        if abs(metadata_width / metadata_height - image_width / image_height) > 0.005:
            raise ValueError(f"Screenshot dimensions disagree with annotations: {path.name}")
        scale = min(max_width / image_width, max_height / image_height)
        self.width = image_width * scale
        self.height = image_height * scale
        self.hAlign = "CENTER"
        self.annotations = figure.get("annotations", [])
        for annotation in self.annotations:
            for name, count in (("rect", 4), ("badge", 2), ("target", 2)):
                values = annotation.get(name)
                if (not isinstance(values, (list, tuple)) or len(values) != count
                        or any(not math.isfinite(float(v)) or v < 0 or v > 1 for v in values)):
                    raise ValueError(f"Invalid normalized {name} in {path.name}")
            x, y, width, height = annotation["rect"]
            if x + width > 1.001 or y + height > 1.001:
                raise ValueError(f"Annotation rectangle exceeds {path.name}")

    def _point(self, pair: list[float]) -> tuple[float, float]:
        return pair[0] * self.width, (1 - pair[1]) * self.height

    def draw(self) -> None:
        c = self.canv
        c.saveState()
        c.drawImage(self.image, 0, 0, width=self.width, height=self.height, mask="auto")
        c.setStrokeColor(RULE)
        c.setLineWidth(0.5)
        c.rect(0, 0, self.width, self.height, stroke=1, fill=0)
        radius = 10
        for annotation in self.annotations:
            x, y, width, height = annotation["rect"]
            rect = (x * self.width, (1 - y - height) * self.height,
                    width * self.width, height * self.height)
            # White under-strokes keep highlights readable on both light and
            # dark UI without changing the underlying screenshot.
            for color, thickness in ((colors.white, 4), (ANNOTATION, 1.6)):
                c.setStrokeColor(color)
                c.setLineWidth(thickness)
                c.roundRect(*rect, radius=2.5, stroke=1, fill=0)
            bx, by = self._point(annotation["badge"])
            tx, ty = self._point(annotation["target"])
            distance = math.hypot(tx - bx, ty - by)
            if distance > radius + 5:
                ux, uy = (tx - bx) / distance, (ty - by) / distance
                sx, sy = bx + ux * (radius + 1), by + uy * (radius + 1)
                for color, thickness in ((colors.white, 4), (ANNOTATION, 1.7)):
                    c.setStrokeColor(color)
                    c.setLineWidth(thickness)
                    c.line(sx, sy, tx, ty)
                p = c.beginPath()
                p.moveTo(tx, ty)
                p.lineTo(tx - ux * 7 - uy * 3.5, ty - uy * 7 + ux * 3.5)
                p.lineTo(tx - ux * 7 + uy * 3.5, ty - uy * 7 - ux * 3.5)
                p.close()
                c.setFillColor(ANNOTATION)
                c.drawPath(p, stroke=0, fill=1)
            c.setStrokeColor(colors.white)
            c.setLineWidth(2)
            c.setFillColor(ANNOTATION)
            c.circle(bx, by, radius, fill=1, stroke=1)
            c.setFillColor(BADGE_TEXT)
            c.setFont(FONT_NAME, 11)
            c.drawCentredString(bx, by - 3.8, str(annotation["number"]))
        c.restoreState()


class _GuideDocument(BaseDocTemplate):
    def __init__(self, filename: Path, data: dict, language: str, version: str, date: str):
        super().__init__(
            str(filename), pagesize=A4, leftMargin=MARGIN, rightMargin=MARGIN,
            topMargin=TOP_MARGIN, bottomMargin=BOTTOM_MARGIN,
            title=data["meta"]["title"], author="알맹Re",
            subject=f"{version} | {date}", pageCompression=1,
            allowSplitting=1,
        )
        self.labels = LABELS[language]
        self.version = version
        self.date = date
        frame = Frame(MARGIN, BOTTOM_MARGIN, CONTENT_WIDTH, CONTENT_HEIGHT,
                      leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
        self.addPageTemplates(PageTemplate(id="Guide", frames=[frame], onPage=self._page))

    def _page(self, canvas, doc) -> None:
        canvas.saveState()
        canvas.setFont(FONT_NAME, 8)
        canvas.setFillColor(MUTED)
        if doc.page > 1:
            canvas.drawString(MARGIN, PAGE_HEIGHT - 30, "알맹Re  /  " + self.labels["guide"])
            canvas.setStrokeColor(RULE)
            canvas.setLineWidth(0.6)
            canvas.line(MARGIN, PAGE_HEIGHT - 38, PAGE_WIDTH - MARGIN, PAGE_HEIGHT - 38)
        canvas.setStrokeColor(RULE)
        canvas.setLineWidth(0.6)
        canvas.line(MARGIN, 35, PAGE_WIDTH - MARGIN, 35)
        canvas.drawString(MARGIN, 22, f"{self.labels['language']}  /  v{self.version}")
        canvas.drawCentredString(PAGE_WIDTH / 2, 22, self.date)
        canvas.drawRightString(PAGE_WIDTH - MARGIN, 22, str(doc.page))
        canvas.restoreState()

    def afterFlowable(self, flowable: Flowable) -> None:
        bookmark = getattr(flowable, "guide_bookmark", None)
        if bookmark is None:
            return
        title = flowable.getPlainText()
        self.canv.bookmarkPage(bookmark)
        level = getattr(flowable, "guide_outline_level", 0)
        self.canv.addOutlineEntry(title, bookmark, level=level, closed=False)
        if getattr(flowable, "guide_toc", True):
            self.notify("TOCEntry", (0, title, self.page, bookmark))


def _heading(text: str, style: ParagraphStyle, bookmark: str,
             *, level: int = 0, toc: bool = True) -> Paragraph:
    paragraph = Paragraph(_text(text), style)
    paragraph.guide_bookmark = bookmark
    paragraph.guide_outline_level = level
    paragraph.guide_toc = toc
    return paragraph


def _tip_box(tips: list[str], labels: dict, styles: dict) -> Table:
    text = f'<font color="#086E8F">{_text(labels["tips"])}</font><br/>'
    text += "<br/>".join(_text(tip) for tip in tips)
    table = Table([[Paragraph(text, styles["tip"])]], colWidths=[CONTENT_WIDTH])
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), LIGHT),
        ("LINEBEFORE", (0, 0), (0, -1), 2, ACCENT),
        ("LEFTPADDING", (0, 0), (-1, -1), 11),
        ("RIGHTPADDING", (0, 0), (-1, -1), 11),
        ("TOPPADDING", (0, 0), (-1, -1), 9),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 9),
    ]))
    table.spaceBefore = 8
    return table


def _callout_row(callout: dict, styles: dict) -> Table:
    number = Paragraph(f'<font color="#086E8F">{callout["number"]:02d}</font>', styles["section"])
    content = Paragraph(
        f'<font color="#086E8F">{_text(callout["title"])}</font><br/>{_text(callout["body"])}',
        styles["callout"],
    )
    row = Table([[number, content]], colWidths=[30, CONTENT_WIDTH - 30])
    row.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 0),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("LINEBELOW", (0, 0), (-1, -1), 0.5, RULE),
    ]))
    return row


def _figure_page(chapter: dict, metadata: dict, figure_number: int,
                 labels: dict, styles: dict, screenshot_dir: Path) -> list[Flowable]:
    figure = chapter["figure"]
    title = _heading(chapter["title"], styles["title"], "figure-" + figure["id"], level=1, toc=False)
    eyebrow = Paragraph(f'{_text(labels["figure"])} {figure_number:02d}', styles["eyebrow"])
    caption = Paragraph(_text(figure["caption"]), styles["caption"])
    callouts = [_callout_row(callout, styles) for callout in figure["callouts"]]
    surrounding = [eyebrow, title, caption, Spacer(1, 12), *callouts]
    reserved_height = sum(
        flowable.wrap(CONTENT_WIDTH, CONTENT_HEIGHT)[1]
        + flowable.getSpaceBefore() + flowable.getSpaceAfter()
        for flowable in surrounding
    )
    # Reserve all translated explanations before choosing the image size;
    # portrait settings screens and longer translations still fit together.
    image_height = max(180, min(500, CONTENT_HEIGHT - reserved_height - 12))
    image = AnnotatedScreenshot(
        screenshot_dir / metadata["file"], metadata,
        max_width=min(480, CONTENT_WIDTH), max_height=image_height,
    )
    return [eyebrow, title, caption, image, Spacer(1, 12), *callouts]


def _shortcut_table(shortcuts: list[dict], labels: dict, styles: dict) -> Table:
    rows = [[Paragraph(_text(labels[key]), styles["tableHeader"])
             for key in ("keys", "action", "context")]]
    for shortcut in shortcuts:
        rows.append([
            Paragraph(_text(shortcut["keys"]), styles["tableKeys"]),
            Paragraph(_text(shortcut["action"]), styles["table"]),
            Paragraph(_text(shortcut["context"]), styles["table"]),
        ])
    table = Table(rows, colWidths=[112, 140, CONTENT_WIDTH - 252], repeatRows=1,
                  hAlign="LEFT", splitByRow=1)
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), ACCENT),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, LIGHT]),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
        ("LINEBELOW", (0, 0), (-1, 0), 0.5, ACCENT),
        ("LINEBELOW", (0, 1), (-1, -1), 0.35, RULE),
    ]))
    return table


def render_pdf(data: dict, language: str, figures: dict, version: str,
               date: str, output_path: str | Path, screenshot_dir: str | Path) -> Path:
    """Write one localized A4 guide, returning its output path.

    ``figures`` maps figure IDs to ``file``, pixel ``width``/``height`` and
    normalized ``annotations``. The content's text, chapter order, figure
    IDs, callout numbers, and shortcut keys remain the source of truth.
    """
    if language not in LABELS:
        raise ValueError(f"Unsupported guide language: {language}")
    _register_font()
    output_path = Path(output_path)
    screenshot_dir = Path(screenshot_dir)
    for chapter in data["chapters"]:
        if chapter["figure"]:
            figure_id = chapter["figure"]["id"]
            if figure_id not in figures:
                raise ValueError(f"Missing figure metadata: {figure_id}")
            image_path = screenshot_dir / figures[figure_id]["file"]
            if not image_path.is_file():
                raise FileNotFoundError(image_path)
            expected = {c["number"] for c in chapter["figure"]["callouts"]}
            actual = {c["number"] for c in figures[figure_id]["annotations"]}
            if expected != actual:
                raise ValueError(f"Callout and annotation numbers differ: {figure_id}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    styles = _styles(language)
    labels = LABELS[language]
    date_text = date.isoformat() if hasattr(date, "isoformat") else str(date)
    doc = _GuideDocument(output_path, data, language, str(version), date_text)
    story: list[Flowable] = [
        Spacer(1, 54),
        Paragraph(f'알맹Re  /  {_text(labels["language"])}', styles["eyebrow"]),
        _Rule(65, thickness=3), Spacer(1, 24),
        Paragraph(_text(data["meta"]["title"]), styles["coverTitle"]),
        Paragraph(_text(data["meta"]["subtitle"]), styles["coverSubtitle"]),
        Paragraph(_text(data["meta"]["intro"]), styles["coverIntro"]),
        Paragraph(
            f'{_text(labels["version"])} {_text(version)}  /  {_text(labels["updated"])} {_text(date_text)}',
            styles["eyebrow"],
        ),
        Spacer(1, 25),
        _tip_box([data["meta"]["uiLanguageNote"]], labels, styles),
        PageBreak(),
        _heading(labels["toc"], styles["title"], "contents", toc=False),
    ]
    toc = TableOfContents()
    toc.levelStyles = [ParagraphStyle(
        "GuideTOC", parent=styles["body"], fontSize=11.2, leading=18,
        leftIndent=0, firstLineIndent=0, rightIndent=30,
        spaceBefore=5, spaceAfter=6, textColor=INK,
    )]
    toc.dotsMinLevel = 0
    story.extend([toc, PageBreak()])
    figure_number = 0
    for index, chapter in enumerate(data["chapters"]):
        if index:
            story.append(PageBreak())
        story.extend([
            _heading(chapter["title"], styles["title"], "chapter-" + chapter["id"]),
            Paragraph(_text(chapter["summary"]), styles["summary"]),
            Paragraph(_text(labels["steps"]), styles["section"]),
        ])
        for number, step in enumerate(chapter["steps"], 1):
            story.append(Paragraph(_text(step), styles["step"], bulletText=f"{number}."))
        for detail in chapter["details"]:
            story.extend([
                Paragraph(_text(detail["title"]), styles["section"]),
                Paragraph(_text(detail["body"]), styles["body"]),
            ])
        if chapter["tips"]:
            story.append(_tip_box(chapter["tips"], labels, styles))
        if chapter["figure"]:
            figure_number += 1
            story.append(PageBreak())
            story.extend(_figure_page(
                chapter, figures[chapter["figure"]["id"]], figure_number,
                labels, styles, screenshot_dir,
            ))
    story.extend([
        PageBreak(),
        _heading(labels["reference"], styles["title"], "shortcut-reference"),
        _shortcut_table(data["shortcuts"], labels, styles),
    ])
    # Multi-pass building resolves actual chapter pages and clickable TOC links
    # even when a longer translation needs an additional page.
    doc.multiBuild(story)
    return output_path
