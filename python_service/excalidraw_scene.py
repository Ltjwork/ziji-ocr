# -*- coding: utf-8 -*-
"""Excalidraw 场景组装（从 excalidraw_export 拆出）：settings 归一化、
区域识别与场景构建、元素/文字工厂、背景图与过程图。excalidraw_export.py
仍为门面，外部 import 面不变。"""
from __future__ import annotations
import base64
import math
import random
import time
import uuid
from collections import OrderedDict, deque
from typing import Any
import cv2
import numpy as np
from segmenter import _imread
from excalidraw_graphics import (_detect_graphics,
    _stroke_colors, _text_records, _ink_coverage, _region_ink_mask)
from excalidraw_ink import _clamp, _log





# ── 设置 ──

_DEFAULT_SETTINGS: dict[str, Any] = {
    # 图形检测
    "detect_rects": True,
    "detect_ellipses": True,
    "detect_lines": True,
    "detect_curves": True,
    "detect_arrows": True,
    "min_shape_size": 10,       # 独立图形最小边 px
    "line_min_len": 24,         # 直线最短长度 px（格线/中心线/合并后的虚线）
    "curve_simplify": 2.0,      # 曲线抽稀容差 px
    "snap_tolerance": 8,        # 线段端点向交叉线吸附 px（0=关）
    "merge_double_lines": True, # 平行双线合并（古籍双栏线 → 单线加粗）
    # 文字
    "min_char_conf": 0.0,       # 字置信度阈值（低于则不出文字元素）
    # 样式
    "scale": 1.0,
    "roughness": 0,             # 0=architect 简洁 / 1=sketch 手绘 / 2=粗糙
    "stroke_width": 0,          # 0=按实测笔画厚度
    "color_mode": "original",   # original | mono | custom
    "custom_color": "#1e1e1e",
    "font_family": 3,           # 3=Normal（CJK 稳定）/ 1=Virgil 手写
    # 输出
    "embed_image": False,       # 嵌入扫描底图（锁定底层）
    "embed_opacity": 100,
    "group_elements": True,     # groupIds 按类型分组（图形/文字）
}



_BOOL_FLAGS = (
    "detect_rects", "detect_ellipses", "detect_lines", "detect_curves",
    "detect_arrows", "merge_double_lines", "embed_image", "group_elements",
)




def normalize_settings(raw: dict[str, Any] | None) -> dict[str, Any]:
    """合并默认值 + 越界钳制。None 值跳过（保持默认）。"""
    s = dict(_DEFAULT_SETTINGS)
    for k, v in (raw or {}).items():
        if k in s and v is not None:
            s[k] = v
    s["scale"] = max(0.05, min(float(s["scale"]), 8.0))
    s["roughness"] = int(max(0, min(int(s["roughness"]), 2)))
    s["stroke_width"] = int(max(0, min(int(s["stroke_width"]), 8)))
    s["min_shape_size"] = int(max(4, min(int(s["min_shape_size"]), 120)))
    s["line_min_len"] = int(max(8, min(int(s["line_min_len"]), 400)))
    s["curve_simplify"] = max(0.5, min(float(s["curve_simplify"]), 12.0))
    s["snap_tolerance"] = int(max(0, min(int(s["snap_tolerance"]), 32)))
    s["min_char_conf"] = max(0.0, min(float(s["min_char_conf"]), 0.99))
    s["embed_opacity"] = int(max(10, min(int(s["embed_opacity"]), 100)))
    fam = int(s["font_family"])
    s["font_family"] = fam if fam in (1, 2, 3) else 3
    if s["color_mode"] not in ("original", "mono", "custom"):
        s["color_mode"] = "original"
    color = s.get("custom_color")
    if not (isinstance(color, str) and len(color) == 7 and color.startswith("#")
            and _is_hex(color[1:])):
        s["custom_color"] = "#1e1e1e"
    for flag in _BOOL_FLAGS:
        s[flag] = bool(s[flag])
    return s




def _is_hex(text: str) -> bool:
    try:
        int(text, 16)
        return True
    except ValueError:
        return False




# ── 区域识别（带 LRU 缓存） ──

_OCR_CACHE: OrderedDict[tuple, list] = OrderedDict()


_OCR_CACHE_MAX = 8




def _recognize_region(
    image_path: str,
    region: tuple[int, int, int, int],
    orientation: str,
    horizontal_dir: str,
    vertical_dir: str,
    layout_mode: str,
) -> list[dict[str, Any]]:
    key = (
        str(image_path), tuple(region), orientation,
        horizontal_dir, vertical_dir, layout_mode,
    )
    cached = _OCR_CACHE.get(key)
    if cached is not None:
        _OCR_CACHE.move_to_end(key)
        _log(f"区域识别缓存命中：{len(cached)} 行")
        return cached
    from kraken_bridge import apply_kraken_recognition
    from segmenter import make_kraken_char_splitter, segment_lines_in_region

    result = segment_lines_in_region(
        image_path, region,
        layout_mode=layout_mode, orientation=orientation,
        horizontal_dir=horizontal_dir, vertical_dir=vertical_dir,
    )
    result = apply_kraken_recognition(
        result, image_path, orientation, horizontal_dir,
        char_splitter=make_kraken_char_splitter(
            image_path, orientation, horizontal_dir
        ),
    )
    lines = list(result.get("lines") or [])
    _OCR_CACHE[key] = lines
    while len(_OCR_CACHE) > _OCR_CACHE_MAX:
        _OCR_CACHE.popitem(last=False)
    return lines




def region_to_excalidraw(
    image_path: str,
    region: tuple[int, int, int, int],
    orientation: str = "vertical",
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
    layout_mode: str = "all_text",
    settings: dict[str, Any] | None = None,
    ocr_lines: list[dict[str, Any]] | None = None,
    text_boxes: list[dict[str, Any]] | None = None,
    debug_images: bool = False,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """区域 → (场景 JSON, 统计)。w/h 为 0 时取整页。

    ocr_lines：注入的编辑器校对数据（不重跑识别）；None 则区域重识别
    （带缓存）。settings 见 _DEFAULT_SETTINGS。

    text_boxes：工作台手画的"文字识别框"（{x,y,w,h} 全图坐标）——框内
    墨迹按文字处理：已有识别字覆盖则直接用，否则对该框单独跑识别（带
    缓存）；其墨迹同时从图形掩膜抠除（格内注释、旋转文字等编辑器行
    数据没盖住的文字不再被当成图形曲线）。debug_images：附带管线过程
    图（stats["debug_images"]）。"""
    region = _normalize_region(image_path, region)
    s = normalize_settings(settings)
    if ocr_lines is None:
        ocr_lines = _recognize_region(
            image_path, region, orientation, horizontal_dir,
            vertical_dir, layout_mode,
        )
    else:
        ocr_lines = list(ocr_lines)
    ocr_lines = ocr_lines + _text_box_lines(
        image_path, region, text_boxes, ocr_lines,
        orientation, horizontal_dir, vertical_dir, layout_mode,
    )
    return build_excalidraw_scene(
        image_path, region, ocr_lines, settings=s,
        text_boxes=text_boxes, debug_images=debug_images,
    )




def _text_box_lines(
    image_path: str,
    region: tuple[int, int, int, int],
    text_boxes: list[dict[str, Any]] | None,
    existing_lines: list[dict[str, Any]],
    orientation: str,
    horizontal_dir: str,
    vertical_dir: str,
    layout_mode: str,
) -> list[dict[str, Any]]:
    """手画文字框 → 追加识别行：框内已有字直接沿用，空框单独识别。

    坐标为全图坐标（与 ocr_lines 一致），先与选区求交。"""
    if not text_boxes:
        return []
    rx, ry, rw, rh = region
    out: list[dict[str, Any]] = []
    for tb in text_boxes[:40]:
        try:
            bx, by = int(tb["x"]), int(tb["y"])
            bw, bh = int(tb["w"]), int(tb["h"])
        except (KeyError, TypeError, ValueError):
            continue
        x1, y1 = max(bx, rx), max(by, ry)
        x2, y2 = min(bx + bw, rx + rw), min(by + bh, ry + rh)
        if x2 - x1 < 4 or y2 - y1 < 4:
            continue
        if _chars_in_rect(existing_lines, x1, y1, x2, y2):
            _log(
                f"文字框 ({x1},{y1},{x2 - x1},{y2 - y1}) 已被既有识别字"
                f"覆盖，直接沿用"
            )
            continue
        lines = _recognize_region(
            image_path, (x1, y1, x2 - x1, y2 - y1),
            orientation, horizontal_dir, vertical_dir, layout_mode,
        )
        kept = _clip_lines_to_rect(lines, x1, y1, x2, y2)
        n_chars = sum(len(l.get("chars") or []) for l in kept)
        _log(
            f"文字框 ({x1},{y1},{x2 - x1},{y2 - y1}) 单独识别出 "
            f"{len(kept)} 行 / {n_chars} 字"
        )
        out.extend(kept)
    return out




def _chars_in_rect(
    lines: list[dict[str, Any]],
    x1: int, y1: int, x2: int, y2: int,
) -> bool:
    """任一字的中心落在矩形内。"""
    for line in lines:
        for c in line.get("chars") or []:
            try:
                cx = int(c["x"]) + int(c["w"]) / 2
                cy = int(c["y"]) + int(c["h"]) / 2
            except (KeyError, TypeError, ValueError):
                continue
            if x1 <= cx <= x2 and y1 <= cy <= y2:
                return True
    return False




def _clip_lines_to_rect(
    lines: list[dict[str, Any]],
    x1: int, y1: int, x2: int, y2: int,
) -> list[dict[str, Any]]:
    """行的字按"字心在矩形内"裁剪，裁后无字的行丢弃。"""
    out: list[dict[str, Any]] = []
    for line in lines:
        chars = []
        for c in line.get("chars") or []:
            try:
                cx = int(c["x"]) + int(c["w"]) / 2
                cy = int(c["y"]) + int(c["h"]) / 2
            except (KeyError, TypeError, ValueError):
                continue
            if x1 <= cx <= x2 and y1 <= cy <= y2:
                chars.append(c)
        if chars:
            clipped = dict(line)
            clipped["chars"] = chars
            out.append(clipped)
    return out




def _normalize_region(
    image_path: str, region: tuple[int, int, int, int]
) -> tuple[int, int, int, int]:
    img = _imread(image_path)
    if img is None:
        raise ValueError(f"Cannot read image: {image_path}")
    ih, iw = img.shape[:2]
    rx, ry, rw, rh = (int(v) for v in region)
    if rw <= 0 or rh <= 0:
        rx, ry, rw, rh = 0, 0, iw, ih
    rx = max(0, min(rx, iw - 1))
    ry = max(0, min(ry, ih - 1))
    rw = max(1, min(rw, iw - rx))
    rh = max(1, min(rh, ih - ry))
    return rx, ry, rw, rh




# ── 场景构建 ──


def build_excalidraw_scene(
    image_path: str,
    region: tuple[int, int, int, int],
    ocr_lines: list[dict[str, Any]],
    settings: dict[str, Any] | None = None,
    text_boxes: list[dict[str, Any]] | None = None,
    debug_images: bool = False,
) -> tuple[dict[str, Any], dict[str, Any]]:
    rx, ry, rw, rh = region
    s = normalize_settings(settings)
    scale = s["scale"]

    mask, color_crop, ink_total = _region_ink_mask(
        image_path, region, ocr_lines, s, text_boxes=text_boxes
    )
    det = _detect_graphics(mask, s)
    text_records = _text_records(ocr_lines, (rx, ry), s)

    shape_boxes = (
        [(r["x"], r["y"], r["w"], r["h"]) for r in det["rects"]]
        + [(e["x"], e["y"], e["w"], e["h"]) for e in det["ellipses"]]
        + [_record_bbox(l) for l in det["lines"]]
        + [(c["x"], c["y"], c["w"], c["h"]) for c in det["curves"]]
    )
    shape_colors = _stroke_colors(color_crop, mask, shape_boxes, s)
    text_boxes_geom = [
        (t["x"], t["y"], t["w"], t["h"]) for t in text_records
    ]
    text_colors = _stroke_colors(color_crop, ink_total, text_boxes_geom, s)

    width = s["stroke_width"] or det["auto_width"]
    groups = s["group_elements"]
    elements: list[dict[str, Any]] = []
    colored = 0

    files: dict[str, Any] = {}
    if s["embed_image"]:
        image_el, files = _background_image_element(
            color_crop, rw, rh, scale, s["embed_opacity"]
        )
        elements.append(image_el)

    def next_color() -> str:
        nonlocal colored
        c = shape_colors.pop(0) if shape_colors else "#1e1e1e"
        if c != "#1e1e1e":
            colored += 1
        return c

    for r in det["rects"]:
        c = next_color()
        elements.append(_element(
            "rectangle", r["x"] * scale, r["y"] * scale,
            r["w"] * scale, r["h"] * scale, s["roughness"],
            stroke_color=c, stroke_width=width,
            group_ids=["graph"] if groups else [],
            background_color=c if r.get("filled") else "transparent",
        ))
    for e in det["ellipses"]:
        elements.append(_element(
            "ellipse", e["x"] * scale, e["y"] * scale,
            e["w"] * scale, e["h"] * scale, s["roughness"],
            stroke_color=next_color(), stroke_width=width,
            group_ids=["graph"] if groups else [],
            roundness={"type": 2},
        ))
    for l in det["lines"]:
        elements.append(_line_element(
            [(l["x1"], l["y1"]), (l["x2"], l["y2"])], scale, s["roughness"],
            stroke_color=next_color(), stroke_width=width,
            group_ids=["graph"] if groups else [],
            dashed=l.get("dashed", False),
            start_arrow=l.get("arrow_start"), end_arrow=l.get("arrow_end"),
        ))
    for c in det["curves"]:
        elements.append(_line_element(
            c["points"], scale, s["roughness"],
            stroke_color=next_color(), stroke_width=width,
            group_ids=["graph"] if groups else [],
            start_arrow=c.get("arrow_start"), end_arrow=c.get("arrow_end"),
        ))
    for t, color in zip(text_records, text_colors):
        if color != "#1e1e1e":
            colored += 1
        elements.append(_text_element(
            t["x"] * scale, t["y"] * scale, t["text"], t["fs"] * scale,
            font_family=s["font_family"], stroke_color=color,
            group_ids=["text"] if groups else [],
        ))

    ink_coverage = _ink_coverage(
        det, text_records, mask.shape, width, ocr_lines, (rx, ry), ink_total
    )
    char_count = sum(t["n"] for t in text_records)
    stats = {
        "rectangles": len(det["rects"]),
        "ellipses": len(det["ellipses"]),
        "lines": len(det["lines"]),
        "curves": len(det["curves"]),
        "arrows": sum(
            1 for l in det["lines"] + det["curves"]
            if l.get("arrow_start") or l.get("arrow_end")
        ),
        "dashed": sum(
            1 for l in det["lines"] if l.get("dashed")
        ),
        "text_elements": len(text_records),
        "chars": char_count,
        "colored": colored,
        "ink_coverage": round(ink_coverage, 4),
        "total": len(elements),
        # 逐文字元素元数据（与场景 text 元素同序）：校对面板显示用
        "text_meta": [
            {
                "kind": t["kind"],
                "conf": t.get("conf"),
                "n": t["n"],
            }
            for t in text_records
        ],
    }
    if debug_images:
        stats["debug_images"] = _pipeline_images(
            color_crop, mask, ocr_lines, (rx, ry), det, text_records,
            text_boxes or [],
        )
    scene = {
        "type": "excalidraw",
        "version": 2,
        "source": "mingji-ocr",
        "elements": elements,
        "appState": {"viewBackgroundColor": "#ffffff", "gridSize": None},
        "files": files,
    }
    _log(
        f"region=({rx},{ry},{rw},{rh}) 矩形={stats['rectangles']} "
        f"椭圆={stats['ellipses']} 直线={stats['lines']} "
        f"曲线={stats['curves']} 箭头={stats['arrows']} "
        f"文字元素={stats['text_elements']}（{char_count} 字） "
        f"彩色={colored} 墨迹覆盖={stats['ink_coverage']:.0%} "
        f"scale={scale}"
    )
    return scene, stats




def _record_bbox(l: dict[str, Any]) -> tuple[float, float, float, float]:
    x = min(l["x1"], l["x2"])
    y = min(l["y1"], l["y2"])
    return x, y, abs(l["x2"] - l["x1"]), abs(l["y2"] - l["y1"])




# ── 元素工厂 ──


def _element(
    etype: str,
    x: float,
    y: float,
    w: float,
    h: float,
    roughness: int,
    stroke_color: str = "#1e1e1e",
    stroke_width: int = 1,
    group_ids: list[str] | None = None,
    background_color: str = "transparent",
    roundness: dict[str, Any] | None = None,
    opacity: int = 100,
    locked: bool = False,
    **extra: Any,
) -> dict[str, Any]:
    element: dict[str, Any] = {
        "id": uuid.uuid4().hex,
        "type": etype,
        "x": round(x, 2),
        "y": round(y, 2),
        "width": round(max(0.0, w), 2),
        "height": round(max(0.0, h), 2),
        "angle": 0,
        "strokeColor": stroke_color,
        "backgroundColor": background_color,
        "fillStyle": "solid",
        "strokeWidth": max(1, int(stroke_width)),
        "strokeStyle": "solid",
        "roughness": int(roughness),
        "opacity": int(opacity),
        "groupIds": group_ids or [],
        "frameId": None,
        "roundness": roundness,
        "seed": random.randint(1, 2**31 - 1),
        "version": 1,
        "versionNonce": random.randint(1, 2**31 - 1),
        "isDeleted": False,
        "boundElements": None,
        "updated": int(time.time() * 1000),
        "link": None,
        "locked": locked,
    }
    element.update(extra)
    return element




def _line_element(
    points: list[tuple[float, float]],
    scale: float,
    roughness: int,
    stroke_color: str = "#1e1e1e",
    stroke_width: int = 1,
    group_ids: list[str] | None = None,
    dashed: bool = False,
    start_arrow: str | None = None,
    end_arrow: str | None = None,
) -> dict[str, Any]:
    scaled = [(x * scale, y * scale) for x, y in points]
    x0, y0 = scaled[0]
    xs = [p[0] for p in scaled]
    ys = [p[1] for p in scaled]
    rel = [[round(x - x0, 2), round(y - y0, 2)] for x, y in scaled]
    element = _element(
        "line", x0, y0, max(xs) - min(xs), max(ys) - min(ys), roughness,
        stroke_color=stroke_color, stroke_width=stroke_width,
        group_ids=group_ids,
        roundness={"type": 2},
        points=rel,
        lastCommittedPoint=None,
        startBinding=None,
        endBinding=None,
        startArrowhead=start_arrow,
        endArrowhead=end_arrow,
    )
    if dashed:
        element["strokeStyle"] = "dashed"
    return element




def _text_element(
    x: float,
    y: float,
    text: str,
    font_size: float,
    font_family: int = 3,
    stroke_color: str = "#1e1e1e",
    group_ids: list[str] | None = None,
) -> dict[str, Any]:
    fs = round(max(1.0, font_size), 2)
    return _element(
        "text", x, y, fs * _visual_width(text), fs * 1.25, 1,
        stroke_color=stroke_color, group_ids=group_ids,
        text=text,
        originalText=text,
        fontSize=fs,
        fontFamily=font_family,
        textAlign="left",
        verticalAlign="top",
        containerId=None,
        lineHeight=1.25,
        baseline=round(fs * 1.1),
    )




def _background_image_element(
    crop: np.ndarray,
    rw: int,
    rh: int,
    scale: float,
    opacity: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    ok, buf = cv2.imencode(".png", crop)
    if not ok:
        raise RuntimeError("底图 PNG 编码失败")
    data_url = "data:image/png;base64," + base64.b64encode(buf.tobytes()).decode("ascii")
    file_id = uuid.uuid4().hex
    element = _element(
        "image", 0.0, 0.0, rw * scale, rh * scale, 0,
        opacity=opacity, locked=True,
        fileId=file_id,
        status="saved",
        scale=[1, 1],
    )
    files = {
        file_id: {
            "id": file_id,
            "mimeType": "image/png",
            "dataURL": data_url,
            "created": int(time.time() * 1000),
        }
    }
    return element, files




def _visual_width(text: str) -> float:
    """CJK 字符宽 ≈ 1×字号，ASCII ≈ 0.6×（Excalidraw 自量度前的近似宽度，
    打开编辑后会按实际字体重算，只影响初始框宽）。"""
    units = sum(1.0 if ord(ch) > 0x2E7F else 0.6 for ch in text)
    return round(units, 2)




# ── 识别过程图（工作台"识别过程"面板） ──


def _png_data_url(img: np.ndarray) -> str:
    ok, buf = cv2.imencode(".png", img)
    if not ok:
        raise RuntimeError("过程图 PNG 编码失败")
    return "data:image/png;base64," + base64.b64encode(buf.tobytes()).decode("ascii")




def _pipeline_images(
    color_crop: np.ndarray,
    mask: np.ndarray,
    ocr_lines: list[dict[str, Any]],
    region_origin: tuple[int, int],
    det: dict[str, Any],
    text_records: list[dict[str, Any]],
    text_boxes: list[dict[str, Any]],
) -> list[dict[str, str]]:
    """管线四阶段可视化：墨迹掩膜 → 直线层/格面 → 全部图形 → 叠加文字。

    大区域（>2000px）输出减半采样，控制 base64 体积。"""
    rx, ry = region_origin
    base = color_crop.copy()
    h, w = base.shape[:2]
    shrink = 1.0
    if max(h, w) > 2000:
        shrink = 0.5

    def _rect(img, x, y, rw_, rh_, color, thick=2):
        cv2.rectangle(img, (int(x), int(y)), (int(x + rw_), int(y + rh_)),
                      color, thick)

    # ① 墨迹掩膜与文字抠除
    img1 = base.copy()
    overlay = img1.copy()
    overlay[mask] = (0, 0, 255)
    cv2.addWeighted(overlay, 0.35, img1, 0.65, 0, dst=img1)
    for line in ocr_lines or []:
        for c in line.get("chars") or []:
            try:
                _rect(img1, int(c["x"]) - rx, int(c["y"]) - ry,
                      int(c["w"]), int(c["h"]), (0, 200, 0), 1)
            except (KeyError, TypeError, ValueError):
                continue
    for tb in text_boxes:
        try:
            _rect(img1, int(tb["x"]) - rx, int(tb["y"]) - ry,
                  int(tb["w"]), int(tb["h"]), (255, 220, 0), 2)
        except (KeyError, TypeError, ValueError):
            continue

    # ② 直线层与格面
    img2 = base.copy()
    for r in det["rects"]:
        if r.get("kind") == "face":
            _rect(img2, r["x"], r["y"], r["w"], r["h"], (0, 200, 0), 2)
        elif r.get("kind") == "solid":
            _rect(img2, r["x"], r["y"], r["w"], r["h"], (120, 120, 120), 1)
    for l in det["lines"]:
        if l.get("kind") == "lattice":
            cv2.line(img2, (int(l["x1"]), int(l["y1"])),
                     (int(l["x2"]), int(l["y2"])), (255, 160, 0), 2)

    # ③ 全部图形元素（含中心线/霍夫/曲线/椭圆）
    img3 = base.copy()
    for r in det["rects"]:
        _rect(img3, r["x"], r["y"], r["w"], r["h"], (255, 0, 0), 2)
    for e in det["ellipses"]:
        cv2.ellipse(
            img3,
            (int(e["x"] + e["w"] / 2), int(e["y"] + e["h"] / 2)),
            (int(e["w"] / 2), int(e["h"] / 2)), 0, 0, 360, (0, 200, 0), 2,
        )
    for l in det["lines"]:
        color = (0, 140, 255) if l.get("kind") != "lattice" else (255, 160, 0)
        cv2.line(img3, (int(l["x1"]), int(l["y1"])),
                 (int(l["x2"]), int(l["y2"])), color, 2)
    for c in det["curves"]:
        pts = np.array([[int(px), int(py)] for px, py in c["points"]],
                       dtype=np.int32)
        cv2.polylines(img3, [pts], False, (255, 0, 255), 2)

    # ④ 图形 + 文字元素框
    img4 = img3.copy()
    for t in text_records:
        _rect(img4, t["x"], t["y"], t["w"], t["h"], (0, 230, 230), 1)

    names = (
        ("① 墨迹掩膜（红）与文字抠除（绿=字框，青=手画文字框）", img1),
        ("② 直线层（蓝=格线）与格面还原（绿=宫格矩形）", img2),
        ("③ 全部图形元素（蓝=矩形框线，橙=格线，绿=圆，紫=曲线）", img3),
        ("④ 最终叠加：③ + 文字元素（青框）", img4),
    )
    out: list[dict[str, str]] = []
    for name, img in names:
        if shrink != 1.0:
            img = cv2.resize(img, None, fx=shrink, fy=shrink,
                             interpolation=cv2.INTER_AREA)
        out.append({"name": name, "data_url": _png_data_url(img)})
    return out
