"""Render the self-contained, localized HTML edition of the user guide.

Images stay separate, unmodified JPEGs. All annotation coordinates are percentages
of the actual image box; SVG lines use that viewport directly, while CSS badges
keep their circular shape and readable size at every image aspect ratio.
"""
from __future__ import annotations

import html
import json
import math
from pathlib import PurePosixPath


LANGUAGES = {
    "ko": "한국어", "en": "English", "ja": "日本語", "zh-Hans": "简体中文",
    "fr": "Français", "es": "Español", "vi": "Tiếng Việt",
}

_UI = {
    "ko": {
        "guide": "사용 설명서", "contents": "목차", "language": "언어", "print": "인쇄",
        "search": "설명서 검색", "searchHint": "챕터와 단축키에서 검색", "clear": "지우기",
        "version": "버전", "updated": "기준일", "steps": "사용 순서", "tips": "알아두세요",
        "shortcuts": "단축키 한눈에 보기", "keys": "키", "action": "동작", "context": "사용 조건",
        "figure": "화면", "skip": "본문으로 건너뛰기", "top": "맨 위로",
        "noResults": "일치하는 내용이 없습니다. 다른 검색어를 입력하거나 검색을 지워주세요.",
        "results": "챕터 {chapters}개 · 단축키 {shortcuts}개", "offline": "인터넷 없이 읽을 수 있는 설명서입니다.",
    },
    "en": {
        "guide": "User guide", "contents": "Contents", "language": "Language", "print": "Print",
        "search": "Search this guide", "searchHint": "Search chapters and shortcuts", "clear": "Clear",
        "version": "Version", "updated": "As of", "steps": "How to", "tips": "Good to know",
        "shortcuts": "Shortcuts at a glance", "keys": "Keys", "action": "Action", "context": "When it applies",
        "figure": "Screen", "skip": "Skip to content", "top": "Back to top",
        "noResults": "No matching content. Try another search or clear the search field.",
        "results": "{chapters} chapters · {shortcuts} shortcuts", "offline": "This guide is available offline.",
    },
    "ja": {
        "guide": "ユーザーガイド", "contents": "目次", "language": "言語", "print": "印刷",
        "search": "ガイド内を検索", "searchHint": "章とショートカットを検索", "clear": "クリア",
        "version": "バージョン", "updated": "基準日", "steps": "操作手順", "tips": "知っておくと便利",
        "shortcuts": "ショートカット一覧", "keys": "キー", "action": "操作", "context": "使用条件",
        "figure": "画面", "skip": "本文へ移動", "top": "先頭に戻る",
        "noResults": "一致する内容がありません。別の語句で検索するか、検索をクリアしてください。",
        "results": "章 {chapters} 件 · ショートカット {shortcuts} 件", "offline": "このガイドはオフラインで読めます。",
    },
    "zh-Hans": {
        "guide": "用户指南", "contents": "目录", "language": "语言", "print": "打印",
        "search": "搜索本指南", "searchHint": "搜索章节和快捷键", "clear": "清除",
        "version": "版本", "updated": "截至日期", "steps": "操作步骤", "tips": "实用提示",
        "shortcuts": "快捷键一览", "keys": "按键", "action": "操作", "context": "适用条件",
        "figure": "界面", "skip": "跳到正文", "top": "返回顶部",
        "noResults": "没有找到匹配内容。请尝试其他关键词或清除搜索。",
        "results": "{chapters} 个章节 · {shortcuts} 个快捷键", "offline": "本指南可离线阅读。",
    },
    "fr": {
        "guide": "Guide d’utilisation", "contents": "Sommaire", "language": "Langue", "print": "Imprimer",
        "search": "Rechercher dans le guide", "searchHint": "Rechercher dans les chapitres et raccourcis", "clear": "Effacer",
        "version": "Version", "updated": "Au", "steps": "Marche à suivre", "tips": "Bon à savoir",
        "shortcuts": "Les raccourcis en un regard", "keys": "Touches", "action": "Action", "context": "Conditions d’utilisation",
        "figure": "Écran", "skip": "Aller au contenu", "top": "Retour en haut",
        "noResults": "Aucun contenu correspondant. Essayez un autre terme ou effacez la recherche.",
        "results": "{chapters} chapitres · {shortcuts} raccourcis", "offline": "Ce guide est consultable hors ligne.",
    },
    "es": {
        "guide": "Guía de usuario", "contents": "Contenido", "language": "Idioma", "print": "Imprimir",
        "search": "Buscar en la guía", "searchHint": "Buscar capítulos y atajos", "clear": "Borrar",
        "version": "Versión", "updated": "A fecha de", "steps": "Cómo hacerlo", "tips": "Conviene saber",
        "shortcuts": "Atajos de un vistazo", "keys": "Teclas", "action": "Acción", "context": "Cuándo se aplica",
        "figure": "Pantalla", "skip": "Ir al contenido", "top": "Volver arriba",
        "noResults": "No hay contenido coincidente. Prueba otra búsqueda o borra el campo.",
        "results": "{chapters} capítulos · {shortcuts} atajos", "offline": "Esta guía se puede consultar sin conexión.",
    },
    "vi": {
        "guide": "Hướng dẫn sử dụng", "contents": "Mục lục", "language": "Ngôn ngữ", "print": "In",
        "search": "Tìm trong hướng dẫn", "searchHint": "Tìm trong các chương và phím tắt", "clear": "Xóa",
        "version": "Phiên bản", "updated": "Tính đến", "steps": "Các bước thực hiện", "tips": "Điều cần biết",
        "shortcuts": "Bảng phím tắt", "keys": "Phím", "action": "Thao tác", "context": "Điều kiện sử dụng",
        "figure": "Màn hình", "skip": "Chuyển đến nội dung", "top": "Về đầu trang",
        "noResults": "Không tìm thấy nội dung phù hợp. Hãy thử từ khác hoặc xóa nội dung tìm kiếm.",
        "results": "{chapters} chương · {shortcuts} phím tắt", "offline": "Có thể đọc hướng dẫn này khi không có Internet.",
    },
}

_CSS = r"""
:root { color-scheme: light; --ink:#202d33; --muted:#5b6b71; --accent:#236b77; --line:#dce4e5; --paper:#fff; --wash:#f4f7f6; --mark:#F4A340; }
* { box-sizing:border-box; }
html { scroll-behavior:smooth; scroll-padding-top:6rem; }
body { margin:0; color:var(--ink); background:var(--wash); font:16px/1.75 -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans",Arial,sans-serif; overflow-wrap:anywhere; }
a { color:var(--accent); text-underline-offset:3px; }
a:hover { text-decoration-thickness:2px; }
button,input,summary { font:inherit; }
button,summary { cursor:pointer; }
button { border:1px solid var(--line); border-radius:9px; background:var(--paper); color:var(--ink); padding:.45rem .85rem; }
button:hover { border-color:var(--accent); }
button:disabled { opacity:.5; cursor:default; }
:focus-visible { outline:3px solid #efa645; outline-offset:4px; }
[hidden] { display:none !important; }
.skip-link { position:fixed; left:1rem; top:-6rem; z-index:20; padding:.5rem 1rem; background:white; border:2px solid var(--accent); }
.skip-link:focus { top:1rem; }
.topbar { position:sticky; top:0; z-index:10; border-bottom:1px solid var(--line); background:rgba(255,255,255,.96); }
.topbar-inner { max-width:1480px; margin:auto; min-height:68px; padding:12px 28px; display:flex; align-items:center; justify-content:space-between; gap:16px; }
.brand { display:flex; align-items:baseline; gap:12px; text-decoration:none; color:var(--ink); }
.brand strong { font-size:1.15rem; letter-spacing:-.02em; }
.brand span { font-size:.8rem; color:var(--muted); }
.top-actions { display:flex; gap:10px; align-items:center; }
.language-switch { position:relative; }
.language-switch summary { list-style:none; padding:.45rem .8rem; border:1px solid var(--line); border-radius:9px; background:white; }
.language-switch summary::-webkit-details-marker { display:none; }
.language-switch summary::after { content:'⌄'; margin-left:.7em; color:var(--muted); }
.language-menu { position:absolute; top:calc(100% + 8px); right:0; min-width:195px; padding:8px; background:white; border:1px solid var(--line); border-radius:12px; box-shadow:0 12px 35px #20313820; }
.language-menu a { display:block; padding:5px 12px; text-decoration:none; border-radius:6px; color:var(--ink); }
.language-menu a:hover,.language-menu a[aria-current] { background:#eaf3f3; color:var(--accent); }
.shell { max-width:1480px; margin:0 auto; padding:36px 28px 60px; display:grid; grid-template-columns:256px minmax(0,1fr); gap:40px; align-items:start; }
.sidebar { position:sticky; top:96px; max-height:calc(100vh - 116px); overflow:auto; padding:4px 12px 20px 0; scrollbar-width:thin; }
.sidebar h2 { margin:0 0 16px; font-size:.85rem; color:var(--muted); letter-spacing:.06em; }
.toc { list-style:none; padding:0; margin:0; font-size:.87rem; line-height:1.55; }
.toc li { margin:0 0 5px; }
.toc a { display:block; padding:6px 10px; border-radius:7px; text-decoration:none; color:#42565e; }
.toc a:hover { background:#e5eeec; color:var(--accent); }
.toc .reference-link { margin-top:14px; padding-top:14px; border-top:1px solid var(--line); }
.sidebar-note { color:var(--muted); font-size:.76rem; padding:18px 10px 0; }
main { min-width:0; }
.cover { padding:8px 0 32px; }
.eyebrow { color:var(--accent); font-size:.76rem; font-weight:700; letter-spacing:.09em; margin:0 0 14px; }
h1 { font-size:clamp(2.1rem,4.5vw,3.35rem); line-height:1.18; letter-spacing:-.045em; margin:0 0 18px; font-weight:730; }
.subtitle { font-size:1.14rem; color:#435e67; max-width:760px; line-height:1.6; margin:0 0 20px; }
.cover-intro { max-width:800px; margin:0 0 18px; }
.edition { display:flex; flex-wrap:wrap; gap:8px 22px; color:var(--muted); font-size:.8rem; margin:20px 0; }
.screenshot-note { border-left:3px solid #a0c2c4; padding:3px 0 3px 14px; max-width:800px; color:var(--muted); font-size:.83rem; }
.search-panel { margin:0 0 32px; padding:20px 24px; border:1px solid var(--line); border-radius:14px; background:#eaf1f0; }
.search-panel label { display:block; margin-bottom:7px; font-weight:650; font-size:.88rem; }
.search-row { display:flex; gap:9px; }
.search-row button { flex-shrink:0; white-space:nowrap; }
.search-row input { min-width:0; width:100%; border:1px solid #c5d2d4; border-radius:9px; padding:10px 12px; color:var(--ink); background:white; }
.search-status { margin:8px 0 0; color:var(--muted); font-size:.78rem; }
.no-results { padding:28px; background:white; border:1px solid var(--line); border-radius:14px; }
.chapter,.shortcut-reference { background:var(--paper); border:1px solid var(--line); border-radius:18px; margin:0 0 28px; padding:32px 36px; scroll-margin-top:96px; }
h2 { font-size:1.6rem; line-height:1.35; letter-spacing:-.025em; margin:0 0 14px; }
.chapter-summary { color:#4a616a; font-size:1.03rem; margin:0 0 25px; max-width:850px; }
h3 { font-size:1rem; line-height:1.5; margin:0 0 6px; }
p { margin:0 0 14px; }
figure { margin:0 0 26px; }
.screenshot { position:relative; line-height:0; border-radius:10px; border:1px solid #d1dcde; background:#25323a; isolation:isolate; }
.screenshot img { display:block; width:100%; height:auto; border-radius:9px; }
.annotation-lines { position:absolute; inset:0; width:100%; height:100%; pointer-events:none; overflow:visible; }
.annotation-line { stroke:#F4A340; stroke-width:2.5px; filter:drop-shadow(0 1px 1px #000b); }
.annotation-region { position:absolute; border:2px solid #F4A340; border-radius:5px; background:#fbc8700a; box-shadow:0 0 0 1px #fff,0 1px 3px #0008; pointer-events:none; }
.annotation-badge { position:absolute; display:grid; place-items:center; width:30px; height:30px; border:2px solid #fff4d5; border-radius:50%; transform:translate(-50%,-50%); background:var(--mark); color:#201A12; font:750 15px/1 -apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif; box-shadow:0 2px 6px #0008; pointer-events:none; }
figcaption { color:var(--muted); font-size:.8rem; line-height:1.55; margin-top:10px; }
.figure-label { font-weight:700; color:var(--accent); margin-right:.5em; }
.callouts { list-style:none; padding:0; margin:18px 0 0; display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:15px; }
.callouts li { display:flex; gap:9px; align-items:flex-start; font-size:.8rem; line-height:1.6; }
.callouts h3 { font-size:.86rem; margin-bottom:4px; }
.callouts p { margin:0; color:var(--muted); }
.callout-number { display:grid; place-items:center; width:24px; height:24px; flex:0 0 24px; border-radius:50%; color:#201A12; border:1px solid #edc998; background:#fff2dd; font-size:.75rem; font-weight:750; }
.steps { padding-left:1.45rem; margin:8px 0 26px; }
.steps li { padding-left:.35rem; margin:0 0 12px; }
.steps li::marker { color:var(--accent); font-weight:700; }
.details-grid { display:grid; grid-template-columns:1fr; gap:13px; margin-bottom:23px; }
.detail p { color:#43565e; margin:0; font-size:.94rem; }
.tips { background:#f0f6f5; border-left:3px solid #6fa2a7; padding:14px 18px; border-radius:0 9px 9px 0; font-size:.87rem; }
.tips h3 { color:var(--accent); font-size:.85rem; margin-bottom:6px; }
.tips ul { list-style:none; padding:0; margin:0; }
.tips li + li { margin-top:8px; }
.table-wrap { overflow-x:auto; border:1px solid var(--line); border-radius:10px; margin-top:18px; }
table { width:100%; border-collapse:collapse; text-align:left; font-size:.86rem; line-height:1.6; }
caption { text-align:left; padding:12px 16px; font-weight:650; background:#f2f6f6; }
th { text-align:left; background:#edf3f3; font-size:.78rem; color:#445f68; }
th,td { padding:12px 14px; border-bottom:1px solid #e2e9e9; vertical-align:top; }
tr:last-child td { border-bottom:0; }
th:first-child,td:first-child { width:21%; }
th:nth-child(2),td:nth-child(2) { width:30%; }
kbd { font-family:inherit; font-size:.83rem; font-weight:650; color:#344f59; white-space:normal; }
.footer { display:flex; justify-content:space-between; gap:20px; color:var(--muted); font-size:.8rem; padding:12px 0; }
@media (min-width:1350px) { .chapter,.shortcut-reference { padding:38px 44px; } }
@media (max-width:1100px) { .shell { grid-template-columns:214px minmax(0,1fr); gap:24px; } .chapter,.shortcut-reference { padding:28px; } .callouts { grid-template-columns:1fr; gap:11px; } }
@media (max-width:800px) { .topbar-inner { padding:11px 18px; } .brand span { display:none; } .shell { display:block; padding:24px 18px 35px; } .sidebar { position:static; max-height:none; padding:0; margin-bottom:28px; } .sidebar nav { max-height:225px; overflow:auto; border:1px solid var(--line); border-radius:12px; padding:14px; background:#fff; } .sidebar h2 { margin:0 0 8px; } .sidebar-note { display:none; } .toc { display:grid; grid-template-columns:1fr 1fr; gap:0 10px; } .toc .reference-link { margin:0; padding:0; border:0; } .chapter,.shortcut-reference { padding:23px; } .cover { padding-top:0; } h2 { font-size:1.42rem; } }
@media (max-width:480px) { body { font-size:15px; } .topbar-inner { gap:8px; } .top-actions { gap:6px; } .top-actions button,.language-switch summary { padding:.4rem .6rem; font-size:.8rem; } .brand strong { font-size:1.03rem; } .shell { padding:20px 12px 28px; } .toc { display:block; } .chapter,.shortcut-reference { padding:21px 17px; border-radius:13px; } .search-panel { padding:16px; } .search-row { gap:6px; } .search-row button { padding:.45rem .6rem; } .annotation-badge { width:24px; height:24px; font-size:12px; } .annotation-region { border-width:1.5px; } .annotation-line { stroke-width:2px; } .table-wrap { margin-left:-5px; margin-right:-5px; } th,td { padding:9px; } .footer { display:block; } }
@media (prefers-reduced-motion:reduce) { html { scroll-behavior:auto; } }
@page { size:A4; margin:16mm; }
@media print {
 html { scroll-behavior:auto; } body { background:white; font-size:10.5pt; line-height:1.6; color:#15252d; }
 .topbar,.sidebar,.search-panel,.no-results,.skip-link,.footer { display:none !important; }
 .shell { display:block; padding:0; max-width:none; } .cover { padding:0 0 10mm; } h1 { font-size:32pt; } .subtitle { font-size:13pt; }
 .chapter,.shortcut-reference { border:0; border-radius:0; padding:0; margin:0; break-before:page; }
 .chapter[hidden],.shortcut-reference[hidden] { display:block !important; } tr[hidden] { display:table-row !important; }
 .chapter h2,.shortcut-reference h2 { font-size:19pt; } h2,h3 { break-after:avoid; } .chapter-summary { font-size:11pt; }
 figure { break-inside:avoid; } img { max-width:100%; } .callouts { grid-template-columns:repeat(3,minmax(0,1fr)); }
 .detail,.tips,.steps li,tr { break-inside:avoid; } .table-wrap { overflow:visible; border:0; border-radius:0; }
 table { font-size:9pt; } thead { display:table-header-group; } th,td { padding:7px 9px; } kbd { font-size:9pt; }
 .screenshot,.annotation-region,.annotation-badge,.callout-number,th,.tips { -webkit-print-color-adjust:exact; print-color-adjust:exact; }
 a { color:inherit; text-decoration:none; } .edition { font-size:9pt; } .screenshot-note { font-size:9pt; }
}
"""

_SCRIPT = r"""
(() => {
  const input = document.getElementById('guide-search');
  const clear = document.getElementById('clear-search');
  const status = document.getElementById('search-status');
  const noResults = document.getElementById('no-results');
  const reference = document.getElementById('shortcut-reference');
  const normalize = value => value.normalize('NFKC').toLocaleLowerCase().replace(/\s+/g, ' ').trim();
  const chapters = [...document.querySelectorAll('.chapter')].map(element => ({
    element, text: normalize(element.textContent),
    toc: document.querySelector(`[data-chapter="${element.id}"]`)
  }));
  const rows = [...document.querySelectorAll('#shortcut-table tbody tr')].map(element => ({
    element, text: normalize(element.textContent)
  }));
  const applySearch = () => {
    const words = normalize(input.value).split(' ').filter(Boolean);
    const matches = text => words.every(word => text.includes(word));
    let chapterCount = 0, shortcutCount = 0;
    for (const item of chapters) {
      const show = matches(item.text);
      item.element.hidden = !show;
      if (item.toc) item.toc.hidden = !show;
      if (show) chapterCount++;
    }
    for (const item of rows) {
      const show = matches(item.text);
      item.element.hidden = !show;
      if (show) shortcutCount++;
    }
    reference.hidden = shortcutCount === 0;
    document.getElementById('reference-toc').hidden = shortcutCount === 0;
    noResults.hidden = chapterCount + shortcutCount > 0;
    clear.disabled = input.value.length === 0;
    status.textContent = resultTemplate.replace('{chapters}', chapterCount).replace('{shortcuts}', shortcutCount);
  };
  input.addEventListener('input', applySearch);
  clear.addEventListener('click', () => { input.value = ''; applySearch(); input.focus(); });
  const printButton = document.getElementById('print-guide');
  const prepareImages = () => [...document.images].map(image => {
    image.loading = 'eager';
    if (typeof image.decode === 'function') return image.decode().catch(() => {});
    if (image.complete) return Promise.resolve();
    return new Promise(resolve => {
      image.addEventListener('load', resolve, { once: true });
      image.addEventListener('error', resolve, { once: true });
    });
  });
  printButton.addEventListener('click', async () => {
    printButton.disabled = true;
    try { await Promise.all(prepareImages()); window.print(); }
    finally { printButton.disabled = false; }
  });
  window.addEventListener('beforeprint', () => { prepareImages(); });
  // Keep the same chapter when changing the guide language.
  document.querySelectorAll('.language-menu a').forEach(link => {
    link.addEventListener('click', () => {
      const file = link.getAttribute('href').split('#')[0];
      link.setAttribute('href', file + window.location.hash);
    });
  });
  // A direct chapter link must still work after a previous search.
  window.addEventListener('hashchange', () => {
    const target = document.getElementById(decodeURIComponent(window.location.hash.slice(1)));
    if (target?.hidden) { input.value = ''; applySearch(); target.scrollIntoView(); }
  });
  applySearch();
})();
"""


def _escape(value: object) -> str:
    return html.escape(str(value), quote=True)


def _coordinates(values: object, length: int, label: str) -> list[float]:
    if not isinstance(values, (list, tuple)) or len(values) != length:
        raise ValueError(f"{label} needs {length} normalized coordinates")
    numbers = [float(value) for value in values]
    if any(not math.isfinite(value) or not 0 <= value <= 1 for value in numbers):
        raise ValueError(f"{label} coordinates must lie between zero and one")
    if length == 4 and (numbers[0] + numbers[2] > 1.000001 or numbers[1] + numbers[3] > 1.000001):
        raise ValueError(f"{label} rectangle extends outside the image")
    return numbers


def _percent(value: float) -> str:
    return f"{value * 100:.4f}%"


def _figure_html(figure: dict, figures: dict, ui: dict, figure_number: int) -> str:
    figure_id = str(figure["id"])
    info = figures[figure_id]
    filename = PurePosixPath(str(info.get("file", f"{figure_id}.jpg"))).name
    source = filename if filename.startswith("UserGuide-") else f"UserGuide-{filename}"
    caption_id = f"caption-{figure_id}"
    regions, arrows, badges = [], [], []
    marker_id = f"arrow-{figure_id}"
    expected = {str(item["number"]) for item in figure["callouts"]}
    annotations = info.get("annotations", [])
    actual = [str(item["number"]) for item in annotations]
    if set(actual) != expected or len(actual) != len(expected):
        raise ValueError(f"{figure_id}: screenshot annotations do not match callout numbers")
    for annotation in annotations:
        number = _escape(annotation["number"])
        x, y, width, height = _coordinates(annotation["rect"], 4, figure_id)
        bx, by = _coordinates(annotation["badge"], 2, figure_id)
        tx, ty = _coordinates(annotation["target"], 2, figure_id)
        regions.append(f'<span class="annotation-region" style="left:{_percent(x)};top:{_percent(y)};width:{_percent(width)};height:{_percent(height)}" aria-hidden="true"></span>')
        arrows.append(f'<line class="annotation-line" x1="{_percent(bx)}" y1="{_percent(by)}" x2="{_percent(tx)}" y2="{_percent(ty)}" marker-end="url(#{_escape(marker_id)})"/>')
        badges.append(f'<span class="annotation-badge" style="left:{_percent(bx)};top:{_percent(by)}" aria-hidden="true">{number}</span>')
    dimensions = ""
    width, height = info.get("width"), info.get("height")
    if isinstance(width, (int, float)) and isinstance(height, (int, float)) and width > 0 and height > 0:
        dimensions = f' width="{int(width)}" height="{int(height)}"'
    callouts = "".join(
        f'<li value="{int(item["number"])}"><span class="callout-number" aria-hidden="true">{_escape(item["number"])}</span>'
        f'<div><h3>{_escape(item["title"])}</h3><p>{_escape(item["body"])}</p></div></li>'
        for item in figure["callouts"])
    return (
        f'<figure><div class="screenshot" role="group" aria-describedby="{_escape(caption_id)}">'
        f'<img src="{_escape(source)}" alt="{_escape(figure["caption"])}"{dimensions} loading="lazy" decoding="async">'
        + "".join(regions)
        + f'<svg class="annotation-lines" aria-hidden="true" focusable="false" xmlns="http://www.w3.org/2000/svg">'
          f'<defs><marker id="{_escape(marker_id)}" markerWidth="9" markerHeight="9" refX="8" refY="4.5" orient="auto" markerUnits="userSpaceOnUse">'
          '<path d="M 0 0 L 9 4.5 L 0 9 Z" fill="#F4A340"/></marker></defs>'
        + "".join(arrows) + '</svg>' + "".join(badges)
        + f'</div><figcaption id="{_escape(caption_id)}"><span class="figure-label">{_escape(ui["figure"])} {figure_number:02d}</span>{_escape(figure["caption"])}</figcaption>'
        + f'<ol class="callouts">{callouts}</ol></figure>')


def render_html(data: dict, language: str, figures: dict, version: object, date: object) -> str:
    """Return a complete offline guide using the shared content/figure schema.

    ``figures`` maps each figure ID to its JPEG filename and normalized annotations;
    optional native image width/height reserve layout space without constraining
    responsive sizing. JPEGs are referenced beside the HTML as ``UserGuide-*.jpg``.
    """
    if language not in LANGUAGES:
        raise ValueError(f"Unsupported guide language: {language}")
    ui = _UI[language]
    meta = data["meta"]
    toc = []
    chapters = []
    figure_number = 0
    for chapter in data["chapters"]:
        chapter_id = _escape(chapter["id"])
        title = _escape(chapter["title"])
        toc.append(f'<li data-chapter="{chapter_id}"><a href="#{chapter_id}">{title}</a></li>')
        screenshot = ""
        if chapter.get("figure"):
            figure_number += 1
            screenshot = _figure_html(chapter["figure"], figures, ui, figure_number)
        steps = ''.join(f'<li>{_escape(step)}</li>' for step in chapter["steps"])
        details = ''.join(f'<section class="detail"><h3>{_escape(item["title"])}</h3><p>{_escape(item["body"])}</p></section>' for item in chapter["details"])
        tips = ''.join(f'<li>{_escape(tip)}</li>' for tip in chapter["tips"])
        chapters.append(
            f'<article class="chapter" id="{chapter_id}" aria-labelledby="heading-{chapter_id}">'
            f'<h2 id="heading-{chapter_id}">{title}</h2><p class="chapter-summary">{_escape(chapter["summary"])}</p>'
            f'{screenshot}<section><h3>{_escape(ui["steps"])}</h3><ol class="steps">{steps}</ol></section>'
            f'<div class="details-grid">{details}</div><aside class="tips" role="note"><h3>{_escape(ui["tips"])}</h3><ul>{tips}</ul></aside></article>')
    languages = ''.join(
        f'<a href="UserGuide-{_escape(code)}.html" lang="{_escape(code)}" hreflang="{_escape(code)}"'
        + (' aria-current="page"' if code == language else '') + f'>{_escape(name)}</a>'
        for code, name in LANGUAGES.items())
    rows = ''.join(f'<tr><td><kbd>{_escape(row["keys"])}</kbd></td><td>{_escape(row["action"])}</td><td>{_escape(row["context"])}</td></tr>' for row in data["shortcuts"])
    template = json.dumps(ui["results"], ensure_ascii=False).replace("</", "<\\/")
    return f'''<!doctype html>
<html lang="{_escape(language)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="{_escape(meta['subtitle'])}">
<title>{_escape(meta['title'])}</title>
<style>{_CSS}</style>
</head>
<body id="top">
<a class="skip-link" href="#main-content">{_escape(ui['skip'])}</a>
<header class="topbar"><div class="topbar-inner">
<a class="brand" href="#top"><strong>알맹Re</strong><span>{_escape(ui['guide'])}</span></a>
<div class="top-actions"><details class="language-switch"><summary aria-label="{_escape(ui['language'])}: {_escape(LANGUAGES[language])}">{_escape(LANGUAGES[language])}</summary><nav class="language-menu" aria-label="{_escape(ui['language'])}">{languages}</nav></details><button id="print-guide" type="button">{_escape(ui['print'])}</button></div>
</div></header>
<div class="shell">
<aside class="sidebar"><nav aria-labelledby="toc-heading"><h2 id="toc-heading">{_escape(ui['contents'])}</h2><ol class="toc">{''.join(toc)}<li class="reference-link" id="reference-toc"><a href="#shortcut-reference">{_escape(ui['shortcuts'])}</a></li></ol></nav><p class="sidebar-note">{_escape(ui['offline'])}</p></aside>
<main id="main-content">
<header class="cover"><p class="eyebrow">알맹Re · {_escape(ui['guide'])}</p><h1>{_escape(meta['title'])}</h1><p class="subtitle">{_escape(meta['subtitle'])}</p><p class="cover-intro">{_escape(meta['intro'])}</p><div class="edition"><span>{_escape(ui['version'])} {_escape(version)}</span><span>{_escape(ui['updated'])} {_escape(date)}</span></div><p class="screenshot-note">{_escape(meta['uiLanguageNote'])}</p></header>
<section class="search-panel" aria-labelledby="search-label"><label id="search-label" for="guide-search">{_escape(ui['search'])}</label><div class="search-row"><input id="guide-search" type="search" placeholder="{_escape(ui['searchHint'])}" autocomplete="off" spellcheck="false" aria-describedby="search-status"><button id="clear-search" type="button" disabled>{_escape(ui['clear'])}</button></div><p class="search-status" id="search-status" role="status" aria-live="polite"></p></section>
<p class="no-results" id="no-results" hidden>{_escape(ui['noResults'])}</p>
{''.join(chapters)}
<section class="shortcut-reference" id="shortcut-reference" aria-labelledby="reference-heading"><h2 id="reference-heading">{_escape(ui['shortcuts'])}</h2><div class="table-wrap"><table id="shortcut-table"><thead><tr><th scope="col">{_escape(ui['keys'])}</th><th scope="col">{_escape(ui['action'])}</th><th scope="col">{_escape(ui['context'])}</th></tr></thead><tbody>{rows}</tbody></table></div></section>
<footer class="footer"><span>알맹Re · {_escape(version)} · {_escape(date)}</span><a href="#top">{_escape(ui['top'])} ↑</a></footer>
</main></div>
<script>const resultTemplate = {template};{_SCRIPT}</script>
</body></html>'''
