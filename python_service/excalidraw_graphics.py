# -*- coding: utf-8 -*-
"""Excalidraw 图形检测编排（从 excalidraw_export 拆出）：墨迹记录（颜色/文字）、
_detect_graphics 总编排与连通域路径。excalidraw_export.py 仍为门面。"""
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
from excalidraw_ink import (_log, _clamp, _region_ink_mask,
    _drop_specks, _interior_solid, _point_off_records, _point_segment_dist,
    _median, _rect_iou, _box_close, _angular_coverage, _thin_quad_centerline,
    _thin, _longest_path, _simplify_path, _ink_coverage)
from excalidraw_lines import (_morph_segments, _cluster_straight,
    _append_run, _merge_parallel, _snap_endpoints, _lattice_faces,
    _intervals_cover, _lattice_line_record, _segment_dashed,
    _match_arrow_endpoint, _hough_lines, _merge_collinear, _dedupe_lines)





def _text_records(
    ocr_lines: list[dict[str, Any]],
    region_origin: tuple[int, int],
    s: dict[str, Any],
) -> list[dict[str, Any]]:
    """识别文本 → 文字记录：竖排行逐字（字框位置原样），横排行整行。

    conf < min_char_conf 的字跳过（乱码/低置信字不出元素）。记录附带
    conf（横排 = 字置信度均值，无 conf 字段则为 None）供校对面板显示。"""
    rx, ry = region_origin
    out: list[dict[str, Any]] = []
    for line in ocr_lines or []:
        chars = []
        for c in line.get("chars") or []:
            text = str(c.get("text") or "").strip()
            if not text:
                continue
            conf = c.get("conf")
            if conf is not None:
                try:
                    if float(conf) < s["min_char_conf"]:
                        continue
                except (TypeError, ValueError):
                    pass
            chars.append(c)
        if not chars:
            continue
        confs = [
            float(c["conf"]) for c in chars
            if c.get("conf") is not None
        ]
        if line.get("orientation") == "horizontal":
            joined = "".join(str(c["text"]).strip()[:1] for c in chars)
            heights = sorted(int(c["h"]) for c in chars)
            median_h = heights[len(heights) // 2]
            fs = _clamp(int(round(median_h * 1.0)), 6, 400)
            x1 = min(int(c["x"]) for c in chars)
            y1 = min(int(c["y"]) for c in chars)
            w = max(int(c["x"]) + int(c["w"]) for c in chars) - x1
            out.append({
                "kind": "line", "x": x1 - rx, "y": y1 - ry,
                "w": w, "h": median_h, "text": joined, "fs": fs,
                "n": len(chars),
                "conf": round(sum(confs) / len(confs), 3) if confs else None,
            })
            continue
        for c in chars:
            fs = _clamp(
                int(round(min(int(c["w"]), int(c["h"])) * 0.95)), 6, 400
            )
            conf = c.get("conf")
            try:
                conf_v = round(float(conf), 3) if conf is not None else None
            except (TypeError, ValueError):
                conf_v = None
            out.append({
                "kind": "char",
                "x": int(c["x"]) - rx, "y": int(c["y"]) - ry,
                "w": int(c["w"]), "h": int(c["h"]),
                "text": str(c["text"]).strip()[:1], "fs": fs, "n": 1,
                "conf": conf_v,
            })
    return out




# ── 取色 ──

# Excalidraw 标准调色板（stroke palette 常用色）
_PALETTE: list[tuple[str, tuple[int, int, int]]] = [
    ("#1e1e1e", (30, 30, 30)),
    ("#e03131", (224, 49, 49)),
    ("#2f9e44", (47, 158, 68)),
    ("#1971c2", (25, 113, 194)),
    ("#9c36b5", (156, 54, 181)),
    ("#e8590c", (232, 89, 12)),
    ("#0c8599", (12, 133, 153)),
    ("#c2255c", (194, 37, 92)),
    ("#868e96", (134, 142, 150)),
]




def _stroke_colors(
    color_crop: np.ndarray,
    ink_mask: np.ndarray,
    boxes: list[tuple[float, float, float, float]],
    s: dict[str, Any],
) -> list[str]:
    """逐 bbox 取墨迹主色：彩墨占比 ≥30% 时映射调色板最近色，否则黑。

    color_mode: original=按检测 / mono=纯黑 / custom=自定义。"""
    if s["color_mode"] == "mono":
        return ["#1e1e1e"] * len(boxes)
    if s["color_mode"] == "custom":
        return [s["custom_color"]] * len(boxes)
    h_img, w_img = ink_mask.shape[:2]
    hsv = cv2.cvtColor(color_crop, cv2.COLOR_BGR2HSV)
    out: list[str] = []
    for x, y, w, h in boxes:
        x1, y1 = max(0, int(x)), max(0, int(y))
        x2, y2 = min(w_img, int(x + w)), min(h_img, int(y + h))
        color = "#1e1e1e"
        if x2 > x1 and y2 > y1:
            ink = ink_mask[y1:y2, x1:x2]
            if ink.any():
                sat = hsv[y1:y2, x1:x2, 1][ink]
                val = hsv[y1:y2, x1:x2, 2][ink]
                colored = (sat > 60) & (val > 60)
                if colored.sum() >= 8 and colored.mean() >= 0.30:
                    pixels = color_crop[y1:y2, x1:x2][ink][colored]
                    b, g, r = pixels.mean(axis=0)
                    color = min(
                        _PALETTE,
                        key=lambda p: (
                            (p[1][0] - r) ** 2
                            + (p[1][1] - g) ** 2
                            + (p[1][2] - b) ** 2
                        ),
                    )[0]
        out.append(color)
    return out




# ── 图形检测 ──


def _detect_graphics(mask: np.ndarray, s: dict[str, Any]) -> dict[str, Any]:
    """图形掩膜 → {rects, ellipses, lines, curves, auto_width}（区域坐标）。

    分层：实心块预检（箭头候选/填充矩形）→ 直线层（长核形态学 + 曲率
    校验，圆弧碎片不会混入）→ 格面还原 → 剩余墨迹（中心线/椭圆/细化
    曲线）→ 霍夫兜底（短横竖合并可成虚线）→ 箭头匹配。"""
    h, w = mask.shape[:2]
    m = mask.astype(np.uint8) * 255
    min_dim = max(8, min(h, w))
    min_area = max(120.0, min_dim * min_dim * 0.0008)
    k = max(31, min_dim // 12)

    rects: list[dict[str, Any]] = []
    lines: list[dict[str, Any]] = []
    ellipses: list[dict[str, Any]] = []
    curves: list[dict[str, Any]] = []
    arrow_candidates: list[dict[str, Any]] = []

    # 1) 实心块预检：墨迹填满轮廓内部（区别于方框的"洞"）才是实心
    solids = np.zeros_like(m)
    contours0, _ = cv2.findContours(m, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    for cnt in contours0:
        bx, by, bw, bh = cv2.boundingRect(cnt)
        area = cv2.contourArea(cnt)
        if area < 20 or bw < 3 or bh < 3:
            continue
        fill = area / float(max(1, bw * bh))
        if fill < 0.4 or not _interior_solid(m, cnt):
            continue
        if (
            s["detect_arrows"] and area <= 1200
            and max(bw, bh) <= 34 and min(bw, bh) >= 3
        ):
            arrow_candidates.append({
                "cx": bx + bw / 2.0, "cy": by + bh / 2.0,
                "r": math.hypot(bw, bh) / 2.0, "contour": cnt,
                "bx": bx, "by": by, "bw": bw, "bh": bh,
            })
            continue  # 候选不消耗，匹配失败留给后续/丢弃
        # 实心块须有起码的"块厚度"（≥6px）；3-5px 的细实条是笔画，
        # 留给直线层/中心线
        if (s["detect_rects"] and min(bw, bh) >= 6 and max(bw, bh) >= 16):
            rects.append({
                "x": bx, "y": by, "w": bw, "h": bh,
                "filled": True, "kind": "solid",
            })
            cv2.drawContours(solids, [cnt], -1, 255, -1)
    m1 = cv2.bitwise_and(m, cv2.bitwise_not(solids))
    _log(
        f"实心块预检：填充矩形 {sum(1 for r in rects if r.get('kind') == 'solid')}"
        f" 个，箭头候选 {len(arrow_candidates)} 个"
    )

    # 2) 直线层：长核形态学开运算（曲率校验拒绝圆弧碎片）
    hk = cv2.getStructuringElement(cv2.MORPH_RECT, (k, 1))
    vk = cv2.getStructuringElement(cv2.MORPH_RECT, (1, k))
    h_segs = _morph_segments(cv2.morphologyEx(m1, cv2.MORPH_OPEN, hk), axis="x")
    v_segs = _morph_segments(cv2.morphologyEx(m1, cv2.MORPH_OPEN, vk), axis="y")
    if s["merge_double_lines"]:
        h_segs = _merge_parallel(h_segs)
        v_segs = _merge_parallel(v_segs)
    if s["snap_tolerance"] > 0:
        _snap_endpoints(h_segs, v_segs, s["snap_tolerance"])
    min_len = max(k, s["line_min_len"])
    h_segs = [g for g in h_segs if g["hi"] - g["lo"] >= min_len]
    v_segs = [g for g in v_segs if g["hi"] - g["lo"] >= min_len]

    thicknesses = [g["thick"] for g in h_segs + v_segs]
    auto_width = _clamp(int(round(_median(thicknesses) if thicknesses else 1.0)), 1, 4)
    _log(
        f"直线层：横 {len(h_segs)} 段 / 竖 {len(v_segs)} 段"
        f"（形态学核 k={k}，最短 {min_len}px，自动线宽 {auto_width}）"
    )

    # 3) 格面还原（V 对 × 相邻共同 H 围成的空格 → 矩形）
    used_h: set[int] = set()
    used_v: set[int] = set()
    if s["detect_rects"]:
        lattice_rects, used_h, used_v = _lattice_faces(h_segs, v_segs, s)
        rects.extend(lattice_rects)
        _log(
            f"格面还原：{len(lattice_rects)} 个矩形，"
            f"墙消耗 横 {len(used_h)}/{len(h_segs)}、"
            f"竖 {len(used_v)}/{len(v_segs)}"
        )

    if s["detect_lines"]:
        for i, g in enumerate(h_segs):
            if i not in used_h:
                lines.append(_lattice_line_record(g, axis="x", mask=mask))
        for i, g in enumerate(v_segs):
            if i not in used_v:
                lines.append(_lattice_line_record(g, axis="y", mask=mask))

    # 4) 剩余墨迹：只扣掉"已接受线段"本身（曲率被拒的圆弧碎片留下，
    #    交叉圆轮廓保持完整 → 椭圆可检）
    straight = np.zeros_like(m)
    for g in h_segs:
        cv2.line(straight, (int(g["lo"]), int(g["fixed"])),
                 (int(g["hi"]), int(g["fixed"])), 255,
                 int(max(2, g["thick"] + 2)))
    for g in v_segs:
        cv2.line(straight, (int(g["fixed"]), int(g["lo"])),
                 (int(g["fixed"]), int(g["hi"])), 255,
                 int(max(2, g["thick"] + 2)))
    rest = cv2.bitwise_and(m1, cv2.bitwise_not(straight))

    contours, _ = cv2.findContours(rest, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    contours = [c for c in contours if cv2.contourArea(c) >= min_area]
    contours.sort(key=cv2.contourArea, reverse=True)
    consumed = np.zeros_like(m)
    # 箭头候选的轮廓不再进中心线/椭圆/曲线分支（避免形成"自匹配"曲线）
    candidate_ids = {id(c["contour"]) for c in arrow_candidates}

    for cnt in contours[:800]:
        if id(cnt) in candidate_ids:
            continue
        peri = cv2.arcLength(cnt, True)
        if peri <= 0:
            continue
        approx = cv2.approxPolyDP(cnt, 0.02 * peri, True)
        pts = approx.reshape(-1, 2)
        bx, by, bw, bh = cv2.boundingRect(approx)
        area = cv2.contourArea(cnt)

        # 细长四边形（斜笔画）→ 中心线
        if len(pts) == 4 and min(bw, bh) <= 5 and max(bw, bh) >= 12:
            seg = _thin_quad_centerline(pts)
            if seg is not None and math.hypot(seg[2] - seg[0], seg[3] - seg[1]) >= 16:
                lines.append({
                    "x1": seg[0], "y1": seg[1], "x2": seg[2], "y2": seg[3],
                    "dashed": False, "arrow_start": None, "arrow_end": None,
                    "kind": "centerline",
                })
                cv2.drawContours(consumed, [cnt], -1, 255, 5)
                continue

        # ≥6 边且椭圆拟合残差小 → 椭圆（张角覆盖拒绝开口弧）
        if (
            s["detect_ellipses"] and len(pts) >= 6 and len(cnt) >= 5
            and bw > 10 and bh > 10
        ):
            (ecx, ecy), (ema, emb), _ang = cv2.fitEllipse(cnt)
            ea, eb = ema / 2.0, emb / 2.0
            if (
                ea >= 5 and eb >= 5
                and area / (math.pi * ea * eb) > 0.72
                and _angular_coverage(cnt, ecx, ecy) >= math.pi * 1.5
            ):
                candidate = {
                    "x": ecx - ea, "y": ecy - eb,
                    "w": 2 * ea, "h": 2 * eb,
                }
                cv2.drawContours(consumed, [cnt], -1, 255, 5)
                if any(_box_close(candidate, e2, 6, 10) for e2 in ellipses):
                    continue  # 内外缘近重复：消耗但不重复出元素
                ellipses.append(candidate)
                continue

        # 其余较大连通域 → 细化 + 最长路径 → 折线（两点直的归直线）
        if s["detect_curves"] and len(curves) < 200 and area >= min_area * 2:
            pts_path = _component_path(rest, cnt)
            if pts_path and len(pts_path) >= 2:
                simplified = _simplify_path(pts_path, s["curve_simplify"])
                if len(simplified) >= 2:
                    if len(simplified) == 2:
                        (ax, ay), (bx2, by2) = simplified
                        lines.append({
                            "x1": ax, "y1": ay, "x2": bx2, "y2": by2,
                            "dashed": False,
                            "arrow_start": None, "arrow_end": None,
                            "kind": "centerline",
                        })
                    else:
                        curves.append({
                            "points": simplified,
                            "x": min(p[0] for p in simplified),
                            "y": min(p[1] for p in simplified),
                            "w": max(p[0] for p in simplified)
                            - min(p[0] for p in simplified),
                            "h": max(p[1] for p in simplified)
                            - min(p[1] for p in simplified),
                            "arrow_start": None, "arrow_end": None,
                        })
                    cv2.drawContours(consumed, [cnt], -1, 255, 5)

    # 5) 霍夫兜底：短横竖（可合并成虚线）+ 对角线
    rest2 = cv2.bitwise_and(rest, cv2.bitwise_not(consumed))
    if s["detect_lines"]:
        before = len(lines)
        lines.extend(_hough_lines(rest2, min_dim, s))
        lines = _dedupe_lines(lines)[:400]
        _log(
            f"剩余墨迹分类：中心线 {sum(1 for l in lines if l.get('kind') == 'centerline')}"
            f" / 椭圆 {len(ellipses)} / 曲线 {len(curves)}"
            f" / 霍夫兜底 +{max(0, len(lines) - before)}"
        )

    # 6) 箭头匹配（贴直线/曲线端点外侧的实心块 → 箭头）
    arrows_attached = 0
    if arrow_candidates:
        pool = lines + curves
        for cand in arrow_candidates:
            target = _match_arrow_endpoint(pool, cand)
            if target is not None:
                target_key = "arrow_start" if target[1] == 0 else "arrow_end"
                target[0][target_key] = "arrow"
                arrows_attached += 1
            elif (
                s["detect_rects"]
                and min(cand["bw"], cand["bh"]) >= 6
                and max(cand["bw"], cand["bh"]) >= 16
                and _point_off_records(cand["cx"], cand["cy"], pool) > 12
            ):
                # 真正孤立的实心小块才回退为填充矩形（虚线短划贴在
                # 合并线段上，不回退）
                rects.append({
                    "x": cand["bx"], "y": cand["by"],
                    "w": cand["bw"], "h": cand["bh"],
                    "filled": True, "kind": "solid",
                })
    if arrow_candidates:
        _log(
            f"箭头匹配：{arrows_attached}/{len(arrow_candidates)} 个候选"
            f"贴上线端"
        )

    rects = rects[:300]
    ellipses = ellipses[:300]
    return {
        "rects": rects,
        "ellipses": ellipses,
        "lines": lines,
        "curves": curves,
        "auto_width": auto_width,
    }




# ── 曲线：细化 + 最长路径 ──


def _component_path(
    rest: np.ndarray, cnt: np.ndarray
) -> list[tuple[float, float]] | None:
    """连通域（按轮廓 bbox 裁剪）→ Zhang-Suen 细化 → 最长路径点列。"""
    x, y, w, h = cv2.boundingRect(cnt)
    pad = 2
    y1, y2 = max(0, y - pad), min(rest.shape[0], y + h + pad)
    x1, x2 = max(0, x - pad), min(rest.shape[1], x + w + pad)
    comp = np.zeros((y2 - y1, x2 - x1), dtype=np.uint8)
    shifted = cnt - np.array([[[x1, y1]]], dtype=cnt.dtype)
    cv2.drawContours(comp, [shifted], -1, 255, -1)
    cv2.drawContours(comp, [shifted], -1, 255, 3)
    # 只取该轮廓内部/边缘的剩余墨迹（同 bbox 内可能有别的组件碎片）
    region_rest = rest[y1:y2, x1:x2]
    comp = cv2.bitwise_and(comp, region_rest)
    if comp.max() == 0:
        return None
    downscale = 1.0
    if comp.size > 1_500_000:
        comp = cv2.resize(comp, None, fx=0.5, fy=0.5,
                          interpolation=cv2.INTER_NEAREST)
        downscale = 2.0
    skel = _thin(comp > 0)
    pts = _longest_path(skel)
    if not pts:
        return None
    return [
        ((px + 0.5) * downscale + x1, (py + 0.5) * downscale + y1)
        for py, px in pts
    ]
