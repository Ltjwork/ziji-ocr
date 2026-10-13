# -*- coding: utf-8 -*-
"""Excalidraw 墨迹基元（从 excalidraw_export 拆出）：mask 提取与净化、
几何量测（中位/距离/IoU/角度覆盖）、骨架化与路径（细化/最长路/化简）。
excalidraw_export.py 仍为门面。"""
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





def _log(message: str) -> None:
    print(f"[excalidraw] {message}", flush=True)
    try:
        import segmenter

        segmenter.append_debug_trace(f"[excalidraw] {message}")
    except Exception:
        pass




def _clamp(v: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, v))




# ── 墨迹与文字 ──


def _region_ink_mask(
    image_path: str,
    region: tuple[int, int, int, int],
    ocr_lines: list[dict[str, Any]],
    s: dict[str, Any],
    text_boxes: list[dict[str, Any]] | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """区域墨迹二值掩膜（True=墨），文字字框外扩 2px 抠除。

    返回 (图形掩膜, 彩色 crop, 全量墨迹)。全量墨迹 = 去噪后未抠字框的
    掩膜（含文字墨迹，作为 ink_coverage 分母与文字取色采样源）。

    与像素切分的 _text_mask_for_refinement 不同：不去栏线（图形的边框
    /格线正是要检测的对象）。低置信字的墨迹同样抠掉——那仍是字形，
    留在图形层只会变成噪声曲线。手画文字框（text_boxes，全图坐标）的
    框内墨迹一并抠掉（编辑器行数据没盖住的格内注释等）。"""
    rx, ry, rw, rh = region
    img = _imread(image_path)
    if img is None:
        raise ValueError(f"Cannot read image: {image_path}")
    crop = img[ry:ry + rh, rx:rx + rw]
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(
        gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU
    )
    ink_fraction = float(np.count_nonzero(binary)) / float(binary.size)
    flipped = False
    if ink_fraction > 0.55:
        # 阴文页/暗底扫描：翻转运回"墨=深色"（与像素切分同款极性自检）
        binary = cv2.bitwise_not(binary)
        flipped = True

    ink_total = _drop_specks(binary > 0, s["min_shape_size"])
    mask = ink_total.copy()
    boxes_removed = 0
    for line in ocr_lines or []:
        for c in line.get("chars", []) or []:
            try:
                cx1 = max(0, int(c["x"]) - rx - 2)
                cy1 = max(0, int(c["y"]) - ry - 2)
                cx2 = min(rw, int(c["x"]) + int(c["w"]) - rx + 2)
                cy2 = min(rh, int(c["y"]) + int(c["h"]) - ry + 2)
            except (KeyError, TypeError, ValueError):
                continue
            if cx2 > cx1 and cy2 > cy1:
                mask[cy1:cy2, cx1:cx2] = False
                boxes_removed += 1
    zones_removed = 0
    for tb in text_boxes or []:
        try:
            zx1 = max(0, int(tb["x"]) - rx - 1)
            zy1 = max(0, int(tb["y"]) - ry - 1)
            zx2 = min(rw, int(tb["x"]) + int(tb["w"]) - rx + 1)
            zy2 = min(rh, int(tb["y"]) + int(tb["h"]) - ry + 1)
        except (KeyError, TypeError, ValueError):
            continue
        if zx2 > zx1 and zy2 > zy1:
            mask[zy1:zy2, zx1:zx2] = False
            zones_removed += 1
    _log(
        f"掩膜：墨迹占比 {ink_fraction:.0%}"
        f"{'（极性已翻转）' if flipped else ''}，"
        f"抠字框 {boxes_removed} 个、文字框 {zones_removed} 个，"
        f"图形墨迹 {int(np.count_nonzero(mask))} px"
    )
    return mask, crop, ink_total




def _drop_specks(mask: np.ndarray, min_shape_size: int) -> np.ndarray:
    """连通域小点过滤（纸斑/扫描噪点）。"""
    min_area = max(9.0, (min_shape_size * 0.6) ** 2)
    m8 = mask.astype(np.uint8)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(m8, 8)
    keep = np.zeros(n, dtype=bool)
    for i in range(1, n):
        keep[i] = stats[i, cv2.CC_STAT_AREA] >= min_area
    return keep[labels]




def _interior_solid(m: np.ndarray, cnt: np.ndarray) -> bool:
    """轮廓内部是否被墨迹填满（排除方框的"洞"轮廓：洞内是空白）。"""
    inside = np.zeros_like(m)
    cv2.drawContours(inside, [cnt], -1, 255, -1)
    ys, xs = np.nonzero(inside)
    if len(xs) == 0:
        return False
    return float(np.count_nonzero(m[ys, xs])) / float(len(xs)) > 0.8




def _point_off_records(
    px: float, py: float, pool: list[dict[str, Any]]
) -> float:
    """点到线/曲线记录的最近距离（判断块是否贴在既有线上）。"""
    best = float("inf")
    for rec in pool:
        if "points" in rec:
            pts = rec["points"]
        else:
            pts = [(rec["x1"], rec["y1"]), (rec["x2"], rec["y2"])]
        for i in range(len(pts) - 1):
            best = min(best, _point_segment_dist(
                px, py, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]
            ))
    return best




def _point_segment_dist(
    px: float, py: float, x1: float, y1: float, x2: float, y2: float
) -> float:
    dx, dy = x2 - x1, y2 - y1
    length2 = dx * dx + dy * dy
    if length2 < 1e-9:
        return math.hypot(px - x1, py - y1)
    t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / length2))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))




def _median(values: list[float]) -> float:
    if not values:
        return 0.0
    v = sorted(values)
    return v[len(v) // 2]




def _rect_iou(a: dict[str, Any], b: dict[str, Any]) -> float:
    ix = max(0.0, min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"]))
    iy = max(0.0, min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"]))
    inter = ix * iy
    union = a["w"] * a["h"] + b["w"] * b["h"] - inter
    return inter / union if union > 0 else 0.0




def _box_close(
    a: dict[str, Any], b: dict[str, Any], pos_tol: float, size_tol: float
) -> bool:
    return (
        abs(a["x"] - b["x"]) < pos_tol
        and abs(a["y"] - b["y"]) < pos_tol
        and abs(a["w"] - b["w"]) < size_tol
        and abs(a["h"] - b["h"]) < size_tol
    )




def _angular_coverage(cnt: np.ndarray, cx: float, cy: float) -> float:
    """轮廓点绕 (cx, cy) 的张角覆盖（2π - 最大角间隙）。开口弧覆盖明显
    不足，闭合圆/椭圆 ≈ 2π。"""
    pts = cnt.reshape(-1, 2).astype(np.float64)
    angles = np.sort(np.arctan2(pts[:, 1] - cy, pts[:, 0] - cx))
    gaps = np.diff(angles)
    wrap = angles[0] + 2 * math.pi - angles[-1]
    max_gap = float(max(gaps.max(), wrap)) if len(gaps) else 2 * math.pi
    return 2 * math.pi - min(max_gap, 2 * math.pi)




def _thin_quad_centerline(pts: np.ndarray):
    """细长四边形（斜笔画轮廓）→ 中心线段：两条短边中点的连线。"""
    n = len(pts)
    edges = [
        float(np.hypot(*(pts[(i + 1) % n] - pts[i])))
        for i in range(n)
    ]
    order = sorted(range(n), key=lambda i: edges[i])
    i1, i2 = order[0], order[1]
    # 两条短边须相对（不相邻）才是"笔画两端"
    if (i1 + 1) % n == i2 or (i2 + 1) % n == i1:
        return None
    m1 = (pts[i1] + pts[(i1 + 1) % n]) / 2.0
    m2 = (pts[i2] + pts[(i2 + 1) % n]) / 2.0
    if float(np.hypot(*(m2 - m1))) < 8:
        return None
    return (
        int(round(m1[0])), int(round(m1[1])),
        int(round(m2[0])), int(round(m2[1])),
    )




def _thin(mask: np.ndarray) -> np.ndarray:
    """Zhang-Suen 细化（opencv-python 无 contrib，纯 numpy 实现）。

    完整判据含 A(p)=1（邻域 0→1 游程数）：漏掉它会过度删除、把骨架
    蚀成孤立点。"""
    img = mask.astype(np.uint8)

    def transitions(p2, p3, p4, p5, p6, p7, p8, p9):
        seq = (p2, p3, p4, p5, p6, p7, p8, p9, p2)
        return sum((seq[i] == 0) & (seq[i + 1] == 1) for i in range(8))

    while True:
        removed = False
        for step in (1, 2):
            p = np.pad(img, 1)
            P2 = p[:-2, 1:-1]
            P3 = p[:-2, 2:]
            P4 = p[1:-1, 2:]
            P5 = p[2:, 2:]
            P6 = p[2:, 1:-1]
            P7 = p[2:, :-2]
            P8 = p[1:-1, :-2]
            P9 = p[:-2, :-2]
            B = P2 + P3 + P4 + P5 + P6 + P7 + P8 + P9
            A = transitions(P2, P3, P4, P5, P6, P7, P8, P9)
            base = (img == 1) & (B >= 2) & (B <= 6) & (A == 1)
            if step == 1:
                cond = base & (P2 * P4 * P6 == 0) & (P4 * P6 * P8 == 0)
            else:
                cond = base & (P2 * P4 * P8 == 0) & (P2 * P6 * P8 == 0)
            if cond.any():
                img[cond] = 0
                removed = True
        if not removed:
            break
    return img > 0




def _longest_path(skel: np.ndarray) -> list[tuple[int, int]] | None:
    """骨架像素图 → 最长路径（双 BFS）。返回 (y, x) 点列。"""
    ys, xs = np.nonzero(skel)
    if len(xs) < 2:
        return None
    pixels = set(zip(ys.tolist(), xs.tolist()))

    def neighbors(p: tuple[int, int]):
        y0, x0 = p
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == 0 and dx == 0:
                    continue
                q = (y0 + dy, x0 + dx)
                if q in pixels:
                    yield q

    endpoints = [p for p in pixels
                 if sum(1 for _ in neighbors(p)) == 1]
    if not endpoints:
        # 闭环：任取一点做最长环近似（贪心走一圈）
        endpoints = [next(iter(pixels))]

    def bfs(start: tuple[int, int]):
        prev: dict[tuple[int, int], tuple[int, int] | None] = {start: None}
        dq = deque([start])
        while dq:
            cur = dq.popleft()
            for nxt in neighbors(cur):
                if nxt not in prev:
                    prev[nxt] = cur
                    dq.append(nxt)
        far = max(prev, key=lambda p: math.hypot(p[1] - start[1], p[0] - start[0]))
        path = []
        node = far
        while node is not None:
            path.append(node)
            node = prev[node]
        return path

    first = bfs(endpoints[0])
    best = bfs(first[-1])
    return best if len(best) >= len(first) else first




def _simplify_path(
    pts: list[tuple[float, float]], epsilon: float
) -> list[tuple[float, float]]:
    """Douglas-Peucker 抽稀，点数上限 64（超限则逐步放大容差）。"""
    if len(pts) <= 2:
        return pts
    eps = max(1.0, epsilon)
    for _ in range(8):
        arr = np.array(pts, dtype=np.int32).reshape(-1, 1, 2)
        approx = cv2.approxPolyDP(arr, eps, False)
        out = [(int(p[0]), int(p[1])) for p in approx.reshape(-1, 2)]
        if len(out) <= 64:
            return out
        eps *= 1.5
    return out[:64]




# ── 墨迹覆盖率 ──


def _ink_coverage(
    det: dict[str, Any],
    text_records: list[dict[str, Any]],
    shape_hw: tuple[int, int],
    width: int,
    ocr_lines: list[dict[str, Any]],
    region_origin: tuple[int, int],
    ink_total: np.ndarray,
) -> float:
    """元素 ∪ 字框 覆盖的墨迹比例（导出保真度，0-1）。"""
    h, w = shape_hw
    cover = np.zeros((h, w), dtype=np.uint8)
    thick = max(3, width + 2)
    for r in det["rects"]:
        cv2.rectangle(
            cover, (int(r["x"]) - 2, int(r["y"]) - 2),
            (int(r["x"] + r["w"]) + 2, int(r["y"] + r["h"]) + 2), 1, thick,
        )
    for e in det["ellipses"]:
        cv2.ellipse(
            cover,
            (int(e["x"] + e["w"] / 2), int(e["y"] + e["h"] / 2)),
            (int(e["w"] / 2), int(e["h"] / 2)), 0, 0, 360, 1, thick,
        )
    for l in det["lines"]:
        cv2.polylines(
            cover,
            [np.array([[int(l["x1"]), int(l["y1"])],
                       [int(l["x2"]), int(l["y2"])]], dtype=np.int32)],
            False, 1, thick,
        )
    for c in det["curves"]:
        cv2.polylines(
            cover,
            [np.array([[int(px), int(py)] for px, py in c["points"]],
                      dtype=np.int32)],
            False, 1, thick,
        )
    rx, ry = region_origin
    for t in text_records:
        x1 = max(0, int(t["x"]) - 1)
        y1 = max(0, int(t["y"]) - 1)
        x2 = min(w, int(t["x"] + t["w"]) + 1)
        y2 = min(h, int(t["y"] + t["h"]) + 1)
        if x2 > x1 and y2 > y1:
            cover[y1:y2, x1:x2] = 1
    total = int(np.count_nonzero(ink_total))
    if total == 0:
        return 1.0
    covered = int(np.count_nonzero(ink_total & (cover > 0)))
    return covered / total
