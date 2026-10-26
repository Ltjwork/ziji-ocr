# -*- coding: utf-8 -*-
"""卦图识别编排（易经卦图电子化）。

hexagram_chart 出几何（爻条阴阳 + 左右干支字框），本模块往字框里填
字并做规则校验——与 table_recognize 同一哲学：

- 引擎逐字读：全部字框合成一批一次 daemon 请求（adapter.read_char_boxes
  与编辑器单字框补读同一条路径，kraken / paddle 同接口）。干支是封闭
  字表（22 字），引擎读错会被领域校验兜住。
- 两路互证（hexagram_domain）：卦体阴阳是几何判定（稳），标注字是引
  擎读法（可能错）——卦体查京房纳甲定表与标注地支比对，干支配对/字
  表校验，疑点交人工对照切片。
- 证据与呈现：区域裁片 + 逐字缩略图（base64 PNG，/char_thumbnails
  同款 letterbox）+ 仿古 SVG 重绘——切片↔重绘对照校对。只读，落盘
  与确认由插件/前端负责（proposed 哲学，与表格识别一致）。
"""
from __future__ import annotations

import base64
import time
from typing import Any

import cv2
import numpy as np

from hexagram_chart import analyze_hexagram_region
from hexagram_domain import (
    hexagram_info,
    najia_for_bits,
    render_svg,
    validate_record,
)
from seg_imaging import _imread
from seg_trace import _log

# 逐字缩略图边长（插件校对改字用；/char_thumbnails 同款白底 letterbox）。
_THUMB_SIZE = 48
# 区域裁片最长边（切片↔重绘对照的上限，超出等比缩小）。
_CROP_MAX_SIDE = 640


def _engine_adapter(engine: str, paddle_model: str | None):
    """卦图识别的引擎触点：与整页/表格识别同一套适配器。"""
    if engine == "paddle":
        from paddle_bridge import PaddleEngineAdapter

        return PaddleEngineAdapter(paddle_model)
    from kraken_bridge import _KRAKEN_ADAPTER

    return _KRAKEN_ADAPTER


def _letterbox_png(img: np.ndarray, box: dict[str, int], size: int) -> str | None:
    """box（绝对坐标）→ 白底 letterbox 正方形 base64 PNG。"""
    ih, iw = img.shape[:2]
    x1, y1 = max(0, box["x"]), max(0, box["y"])
    x2 = min(iw, box["x"] + box["w"])
    y2 = min(ih, box["y"] + box["h"])
    if x2 - x1 < 2 or y2 - y1 < 2:
        return None
    crop = img[y1:y2, x1:x2]
    side = max(crop.shape[0], crop.shape[1])
    shape = (side, side, 3) if crop.ndim == 3 else (side, side)
    square = np.full(shape, 255, dtype=np.uint8)
    oy = (side - crop.shape[0]) // 2
    ox = (side - crop.shape[1]) // 2
    square[oy:oy + crop.shape[0], ox:ox + crop.shape[1]] = crop
    thumb = cv2.resize(square, (size, size), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".png", thumb)
    return base64.b64encode(buf).decode("ascii") if ok else None


def _crop_png(img: np.ndarray, box: dict[str, int]) -> str | None:
    """box（绝对坐标）→ 等比缩放的裁片 base64 PNG（对照校对的证据层）。"""
    ih, iw = img.shape[:2]
    x1, y1 = max(0, box["x"]), max(0, box["y"])
    x2 = min(iw, box["x"] + box["w"])
    y2 = min(ih, box["y"] + box["h"])
    if x2 - x1 < 2 or y2 - y1 < 2:
        return None
    crop = img[y1:y2, x1:x2]
    longest = max(crop.shape[0], crop.shape[1])
    if longest > _CROP_MAX_SIDE:
        scale = _CROP_MAX_SIDE / longest
        crop = cv2.resize(
            crop,
            (max(1, int(crop.shape[1] * scale)),
             max(1, int(crop.shape[0] * scale))),
            interpolation=cv2.INTER_AREA,
        )
    ok, buf = cv2.imencode(".png", crop)
    return base64.b64encode(buf).decode("ascii") if ok else None


def recognize_hexagram(
    image_path: str,
    x: int,
    y: int,
    w: int,
    h: int,
    engine: str = "kraken",
    paddle_model: str | None = None,
) -> dict[str, Any]:
    """区域卦图识别入口：几何阴阳 + 干支逐字读 + 领域校验 + 证据产物。

    返回含 hexagram（卦体信息）/ najia（自下而上定表干支）/ lines
    （每爻左右标注字 + 缩略图）/ validation / svg / crop / log。
    几何失败透传 analyze 的 ok=False + reason。
    """
    t_start = time.time()
    chart = analyze_hexagram_region(image_path, x, y, w, h)
    if not chart.get("ok"):
        return chart
    lines: list[dict[str, Any]] = chart["lines"]
    bits = [1 if ln["yang"] else 0 for ln in lines]
    hexa = hexagram_info(bits)
    najia = najia_for_bits(bits)
    diag: list[str] = [
        f"几何：爻距 {chart['pitch']}px 条宽 {chart['bar_w']}px "
        f"六爻「{hexa['bits']}」（自下而上）→ "
        f"{hexa['full_name']} {hexa['unicode']}",
        f"纳甲定表：{' / '.join(najia)}（自下而上）",
    ]
    for ln, expect in zip(lines, najia):
        ln["najia"] = expect

    # 标注字框汇总（pos 升序，每爻先左后右，侧内自上而下）一批逐字读。
    flat: list[tuple[int, int, int, int]] = []
    slots: list[tuple[int, str, int]] = []
    for li, ln in enumerate(lines):
        for side in ("left", "right"):
            for ci, c in enumerate(ln[side]):
                flat.append((c["x"], c["y"], c["w"], c["h"]))
                slots.append((li, side, ci))
    adapter = _engine_adapter(engine, paddle_model)
    recs: list[dict] = []
    if flat:
        diag.append(f"引擎={adapter.ocr_tag} 逐字读：{len(flat)} 框一批一次请求")
        try:
            recs = adapter.read_char_boxes(
                image_path, flat, "vertical", "ltr", pad=True
            )
        except Exception as exc:  # noqa: BLE001 —— 引擎失败不吞几何
            recs = []
            diag.append(f"逐字读失败：{exc} → 标注字留空，人工对照切片补字")
    for (li, side, ci), rec in zip(slots, recs):
        c = lines[li][side][ci]
        c["text"] = str(rec.get("text") or "").strip()[:1]
        c["conf"] = float(rec.get("conf") or 0.0)
    for ln in lines:
        for side in ("left", "right"):
            for c in ln[side]:
                c.setdefault("text", "")
                c.setdefault("conf", 0.0)

    # 证据产物：区域裁片 + 逐字缩略图（同一次读图）。
    img = None
    try:
        img = _imread(image_path)
    except OSError:
        img = None
    if img is not None:
        chart["crop"] = _crop_png(img, {
            "x": chart["x"], "y": chart["y"],
            "w": chart["w"], "h": chart["h"],
        })
        for ln in lines:
            for side in ("left", "right"):
                for c in ln[side]:
                    c["thumb"] = _letterbox_png(img, c, _THUMB_SIZE)

    validation = validate_record(lines)
    chart["svg"] = render_svg(lines, hexa)
    chart["hexagram"] = hexa
    chart["najia"] = najia
    chart["validation"] = validation
    chart["engine"] = adapter.ocr_tag
    marks_text = "、".join(
        f"{'左' if side == 'left' else '右'}{ln['pos']}爻"
        + "".join(c.get("text") or "□" for c in ln[side])
        for ln in lines
        for side in ("left", "right")
        if ln[side]
    )
    diag.append(f"标注：「{marks_text or '（无）'}」")
    diag.append(
        f"校验：硬错误 {len(validation['errors'])} 条 / "
        f"提示 {len(validation['warnings'])} 条 / "
        f"纳甲 {validation['najia']['verdict']}"
    )
    diag.append(f"完成：共 {time.time() - t_start:.1f}s")
    chart["log"] = diag
    _log("[hexagram] " + " | ".join(diag))
    return chart
