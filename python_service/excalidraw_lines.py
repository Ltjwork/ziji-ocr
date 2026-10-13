# -*- coding: utf-8 -*-
"""Excalidraw 直线与格网检测（从 excalidraw_export 拆出）：形态学线段、
平行合并、端点吸附、格网面、虚线判定、箭头端点匹配、hough 与共线合并。
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
from excalidraw_ink import (_clamp, _median, _point_segment_dist, _rect_iou)





def _morph_segments(
    opened: np.ndarray, axis: str, gap: int = 12, fixed_tol: int = 3
) -> list[dict[str, float]]:
    """开运算后的横/竖笔画掩膜 → 线段（共线聚类合并印刷断线 + 曲率校验）。

    axis='x'：横向笔画（fixed=y，lo..hi=x 区间）。thick = 聚类行数
    （笔画厚度，供自动线宽与双线合并）。曲率校验：聚类像素到最小二乘
    直线的最大垂距 > 2.5px 判为弧线碎片（圆被格线穿越后开运算拉出的
    平顶/平侧弧段），拒绝为线段——其墨迹留给椭圆/曲线检测。"""
    clusters: list[dict[str, Any]] = []
    if axis == "x":
        for y in range(opened.shape[0]):
            row = opened[y]
            if not row.any():
                continue
            xs = np.flatnonzero(row)
            splits = np.flatnonzero(np.diff(xs) > gap)
            start = 0
            ends = list(splits) + [len(xs) - 1]
            for end in ends:
                _append_run(clusters, y, int(xs[start]), int(xs[end]),
                            fixed_tol, gap)
                start = end + 1
    else:
        for x in range(opened.shape[1]):
            col = opened[:, x]
            if not col.any():
                continue
            ys = np.flatnonzero(col)
            splits = np.flatnonzero(np.diff(ys) > gap)
            start = 0
            ends = list(splits) + [len(ys) - 1]
            for end in ends:
                _append_run(clusters, x, int(ys[start]), int(ys[end]),
                            fixed_tol, gap)
                start = end + 1
    segs: list[dict[str, float]] = []
    for c in clusters:
        if not _cluster_straight(c["runs"], axis):
            continue
        segs.append({
            "fixed": float(c["mean"]),
            "lo": float(min(r[1] for r in c["runs"])),
            "hi": float(max(r[2] for r in c["runs"])),
            "thick": float(c["max_fixed"] - c["min_fixed"] + 1),
        })
    return segs




def _cluster_straight(runs: list[tuple[int, int, int]], axis: str,
                      max_residual: float = 2.5) -> bool:
    """聚类行程像素到最小二乘直线的最大垂距（曲率校验）。"""
    pts: list[tuple[float, float]] = []
    for fixed, lo, hi in runs:
        step = max(1, (hi - lo) // 24)
        for v in range(lo, hi + 1, step):
            pts.append((v, fixed) if axis == "x" else (fixed, v))
    if len(pts) < 3:
        return True
    arr = np.array(pts, dtype=np.float64)
    centered = arr - arr.mean(axis=0)
    try:
        _, _, vt = np.linalg.svd(centered, full_matrices=False)
    except np.linalg.LinAlgError:
        return True
    direction = vt[0]
    perp = np.array([-direction[1], direction[0]])
    return float(np.abs(centered @ perp).max()) <= max_residual




def _append_run(
    clusters: list[dict[str, Any]],
    fixed: int,
    lo: int,
    hi: int,
    fixed_tol: int,
    gap: int,
) -> None:
    run_len = hi - lo + 1
    for c in reversed(clusters):
        if abs(fixed - c["mean"]) <= fixed_tol and lo <= c["hi"] + gap and hi >= c["lo"] - gap:
            c["runs"].append((fixed, lo, hi))
            c["lo"] = min(c["lo"], lo)
            c["hi"] = max(c["hi"], hi)
            c["weighted"] += fixed * run_len
            c["weights"] += run_len
            c["max_fixed"] = max(c["max_fixed"], fixed)
            c["min_fixed"] = min(c["min_fixed"], fixed)
            c["mean"] = c["weighted"] / c["weights"]
            return
    clusters.append({
        "runs": [(fixed, lo, hi)], "lo": lo, "hi": hi,
        "weighted": fixed * run_len, "weights": run_len,
        "max_fixed": fixed, "min_fixed": fixed,
        "mean": float(fixed),
    })




def _merge_parallel(
    segs: list[dict[str, float]], max_gap: float = 6.0, min_overlap: float = 0.75
) -> list[dict[str, float]]:
    """平行双线合并：fixed 相距 ≤6px 且区间重叠 ≥75% → 合并加粗。"""
    merged: list[dict[str, Any]] = []
    for g in sorted(segs, key=lambda t: t["fixed"]):
        hit = False
        for c in reversed(merged):
            if abs(g["fixed"] - c["fixed"]) > max_gap:
                continue
            overlap = min(g["hi"], c["hi"]) - max(g["lo"], c["lo"])
            shorter = min(g["hi"] - g["lo"], c["hi"] - c["lo"])
            if shorter > 0 and overlap / shorter >= min_overlap:
                w1, w2 = g["hi"] - g["lo"], c["hi"] - c["lo"]
                c["fixed"] = (
                    g["fixed"] * w1 + c["fixed"] * w2
                ) / (w1 + w2)
                c["lo"] = min(c["lo"], g["lo"])
                c["hi"] = max(c["hi"], g["hi"])
                c["thick"] = c["thick"] + 1
                hit = True
                break
        if not hit:
            merged.append(dict(g))
    return merged




def _snap_endpoints(
    h_segs: list[dict[str, float]],
    v_segs: list[dict[str, float]],
    tol: int,
) -> None:
    """线段端点向交叉的垂直线段吸附（拐角对齐）。"""
    for g in h_segs:
        for side in ("lo", "hi"):
            for v in v_segs:
                if (
                    abs(v["fixed"] - g[side]) <= tol
                    and v["lo"] - 3 <= g["fixed"] <= v["hi"] + 3
                ):
                    g[side] = v["fixed"]
                    break
    for g in v_segs:
        for side in ("lo", "hi"):
            for h in h_segs:
                if (
                    abs(h["fixed"] - g[side]) <= tol
                    and h["lo"] - 3 <= g["fixed"] <= h["hi"] + 3
                ):
                    g[side] = h["fixed"]
                    break




def _lattice_faces(
    h_segs: list[dict[str, float]],
    v_segs: list[dict[str, float]],
    s: dict[str, Any],
) -> tuple[list[dict[str, Any]], set[int], set[int]]:
    """格面还原：V 对 × 相邻共同 H 围成的空腔 → 矩形。

    网格 → 宫格矩形；独立框 → 一个矩形；T 形交接处越出格面的墙保留
    为线段。墙的消耗按"被格面并集覆盖"判定：一条线段只有其全程都被
    若干格面的边覆盖时才不再单独出线（避免网格线与宫格边重复双绘）。"""
    def crosses(h: dict[str, float], v: dict[str, float], tol: float = 3.0) -> bool:
        return (
            h["lo"] - tol <= v["fixed"] <= h["hi"] + tol
            and v["lo"] - tol <= h["fixed"] <= v["hi"] + tol
        )

    min_side = max(12.0, float(s["min_shape_size"]))
    rects: list[dict[str, Any]] = []
    v_sorted = sorted(v_segs, key=lambda g: g["fixed"])
    for ai in range(len(v_sorted)):
        for bi in range(ai + 1, len(v_sorted)):
            va, vb = v_sorted[ai], v_sorted[bi]
            x1, x2 = va["fixed"], vb["fixed"]
            if x2 - x1 < min_side:
                continue
            common = [
                h for h in h_segs if crosses(h, va) and crosses(h, vb)
            ]
            if len(common) < 2:
                continue
            common.sort(key=lambda h: h["fixed"])
            for t in range(len(common) - 1):
                h1, h2 = common[t], common[t + 1]
                y1, y2 = h1["fixed"], h2["fixed"]
                if y2 - y1 < min_side:
                    continue
                # 空腔校验：内部不得有其他横/竖线穿越
                busy = any(
                    oh["fixed"] > y1 + 2 and oh["fixed"] < y2 - 2
                    and oh["lo"] < x2 - 2 and oh["hi"] > x1 + 2
                    for oh in h_segs if oh is not h1 and oh is not h2
                ) or any(
                    ov["fixed"] > x1 + 2 and ov["fixed"] < x2 - 2
                    and ov["lo"] < y2 - 2 and ov["hi"] > y1 + 2
                    for ov in v_segs if ov is not va and ov is not vb
                )
                if busy:
                    continue
                cand = {
                    "x": x1, "y": y1, "w": x2 - x1, "h": y2 - y1,
                    "filled": False, "kind": "face",
                }
                if any(_rect_iou(cand, r) > 0.85 for r in rects):
                    continue
                rects.append(cand)

    used_h = {
        i for i, g in enumerate(h_segs)
        if _intervals_cover(
            [(r["x"], r["x"] + r["w"]) for r in rects
             if abs(r["y"] - g["fixed"]) <= 2.5
             or abs(r["y"] + r["h"] - g["fixed"]) <= 2.5],
            g["lo"], g["hi"],
        )
    }
    used_v = {
        i for i, g in enumerate(v_segs)
        if _intervals_cover(
            [(r["y"], r["y"] + r["h"]) for r in rects
             if abs(r["x"] - g["fixed"]) <= 2.5
             or abs(r["x"] + r["w"] - g["fixed"]) <= 2.5],
            g["lo"], g["hi"],
        )
    }
    return rects, used_h, used_v




def _intervals_cover(
    ivs: list[tuple[float, float]], lo: float, hi: float, gap: float = 4.0
) -> bool:
    """区间并集（容差 gap）是否完整覆盖 [lo, hi]。"""
    if not ivs:
        return False
    merged: list[list[float]] = []
    for a, b in sorted(ivs):
        if merged and a <= merged[-1][1] + gap:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return merged[0][0] <= lo + gap and merged[-1][1] >= hi - gap




def _lattice_line_record(
    g: dict[str, float], axis: str, mask: np.ndarray
) -> dict[str, Any]:
    if axis == "x":
        x1, y1, x2, y2 = g["lo"], g["fixed"], g["hi"], g["fixed"]
    else:
        x1, y1, x2, y2 = g["fixed"], g["lo"], g["fixed"], g["hi"]
    return {
        "x1": x1, "y1": y1, "x2": x2, "y2": y2,
        "dashed": _segment_dashed(mask, x1, y1, x2, y2),
        "arrow_start": None, "arrow_end": None,
        "kind": "lattice",
    }




def _segment_dashed(
    mask: np.ndarray, x1: float, y1: float, x2: float, y2: float
) -> bool:
    """沿线采样墨迹间隙：≥2 个 ≥4px 的空档 → 虚线（覆盖率判据对粗
    短划过松，间隙结构更稳）。"""
    length = int(math.hypot(x2 - x1, y2 - y1))
    if length < 16:
        return False
    h, w = mask.shape[:2]
    hits = []
    for t in range(length + 1):
        px = int(round(x1 + (x2 - x1) * t / length))
        py = int(round(y1 + (y2 - y1) * t / length))
        y1c, y2c = max(0, py - 1), min(h, py + 2)
        x1c, x2c = max(0, px - 1), min(w, px + 2)
        hits.append(bool(mask[y1c:y2c, x1c:x2c].any()))
    gaps = 0
    run = 0
    for hit in hits:
        if hit:
            run = 0
        else:
            run += 1
            if run == 3:  # 空档达 3px 计一次（窗口 ±1 已吃掉 2px 边缘）
                gaps += 1
    return gaps >= 2




def _match_arrow_endpoint(
    pool: list[dict[str, Any]], cand: dict[str, Any]
) -> tuple[dict[str, Any], int] | None:
    """箭头候选 → 最近的线/曲线端点（返回 (record, 0|1)）。

    候选质心须落在线端点"外侧"（沿线延长方向），虚线自身的短划、
    线中段的墨块不会被误配。"""
    best: tuple[dict[str, Any], int] | None = None
    best_dist = 20.0 + cand["r"]
    for rec in pool:
        if rec.get("arrow_start") or rec.get("arrow_end"):
            continue
        if "points" in rec:
            pts = rec["points"]
            ends = [(pts[0], pts[1]), (pts[-1], pts[-2])]
        else:
            ends = [
                ((rec["x1"], rec["y1"]), (rec["x2"], rec["y2"])),
                ((rec["x2"], rec["y2"]), (rec["x1"], rec["y1"])),
            ]
        for idx, ((ex, ey), (ox, oy)) in enumerate(ends):
            away = (ex - ox, ey - oy)
            if math.hypot(*away) < 1e-6:
                continue
            beyond = (cand["cx"] - ex) * away[0] + (cand["cy"] - ey) * away[1]
            if beyond <= 0:
                continue  # 在线段内侧（如虚线自身的短划）
            d = math.hypot(ex - cand["cx"], ey - cand["cy"])
            if d < best_dist:
                best_dist = d
                best = (rec, idx)
    return best




def _hough_lines(
    rest: np.ndarray, min_dim: int, s: dict[str, Any]
) -> list[dict[str, Any]]:
    """剩余墨迹霍夫兜底：短横竖可合并成虚线；对角线段。"""
    small = max(10, min(s["line_min_len"] // 2, 16))
    found = cv2.HoughLinesP(
        rest, 1, np.pi / 180.0,
        threshold=max(10, small - 2),
        minLineLength=small, maxLineGap=2,
    )
    if found is None:
        return []
    horizontal: list[tuple[int, int, int, int]] = []
    vertical: list[tuple[int, int, int, int]] = []
    diagonal: list[tuple[int, int, int, int]] = []
    for x1, y1, x2, y2 in found[:, 0]:
        x1, y1, x2, y2 = int(x1), int(y1), int(x2), int(y2)
        dx, dy = abs(x2 - x1), abs(y2 - y1)
        # 按绝对位移分类：霍夫端点会在笔画厚度内抖动，按角度分会把
        # 短横竖误判成对角（虚线短划流失）
        if dy <= 4 and dx >= dy:
            horizontal.append((x1, y1, x2, y2))
        elif dx <= 4 and dy > dx:
            vertical.append((x1, y1, x2, y2))
        else:
            diagonal.append((x1, y1, x2, y2))

    out: list[dict[str, Any]] = []
    min_len = s["line_min_len"]
    for seg in _merge_collinear(horizontal, axis="x", gap=14) \
            + _merge_collinear(vertical, axis="y", gap=14):
        x1, y1, x2, y2 = seg
        if math.hypot(x2 - x1, y2 - y1) < min_len:
            continue  # 碎弧/噪点段，不够成线
        out.append({
            "x1": x1, "y1": y1, "x2": x2, "y2": y2,
            "dashed": _segment_dashed(rest, x1, y1, x2, y2),
            "arrow_start": None, "arrow_end": None,
            "kind": "hough",
        })
    diag_min = max(40, s["line_min_len"])
    for x1, y1, x2, y2 in diagonal:
        if math.hypot(x2 - x1, y2 - y1) >= diag_min:
            out.append({
                "x1": x1, "y1": y1, "x2": x2, "y2": y2,
                "dashed": False, "arrow_start": None, "arrow_end": None,
                "kind": "hough",
            })
    return out




def _merge_collinear(
    segs: list[tuple[int, int, int, int]], axis: str, gap: int = 14
) -> list[tuple[int, int, int, int]]:
    """共线线段合并（并查集）：fixed 相差 ≤3 且区间间隙 ≤gap 即同簇。

    霍夫端点会在笔画厚度内抖动（同一行短划散落到相邻 y），贪心聚类
    顺序依赖会碎裂，并查集一次性归并。"""
    if not segs:
        return []
    items = []
    for x1, y1, x2, y2 in segs:
        a, b = (x1, x2) if axis == "x" else (y1, y2)
        lo, hi = min(a, b), max(a, b)
        fixed = (y1 + y2) // 2 if axis == "x" else (x1 + x2) // 2
        items.append((fixed, lo, hi))
    n = len(items)
    parent = list(range(n))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(n):
        for j in range(i + 1, n):
            fi, li, hi_ = items[i]
            fj, lj, hj_ = items[j]
            if abs(fi - fj) <= 4 and li <= hj_ + gap and lj <= hi_ + gap:
                ri, rj = find(i), find(j)
                if ri != rj:
                    parent[ri] = rj

    groups: dict[int, list[tuple[int, int, int]]] = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(items[i])
    out: list[tuple[int, int, int, int]] = []
    for members in groups.values():
        total = sum(hi_ - lo for _, lo, hi_ in members) or 1
        fixed = round(sum(f * (hi_ - lo) for f, lo, hi_ in members) / total)
        lo = min(m[1] for m in members)
        hi = max(m[2] for m in members)
        if hi - lo < 8:
            continue
        if axis == "x":
            out.append((lo, fixed, hi, fixed))
        else:
            out.append((fixed, lo, fixed, hi))
    return out




def _dedupe_lines(segs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """近重复线段去重（端点对应相近即视为同一条，保留长者）。"""
    def norm(seg: dict[str, Any]):
        (x1, y1), (x2, y2) = sorted(
            [(seg["x1"], seg["y1"]), (seg["x2"], seg["y2"])]
        )
        return x1, y1, x2, y2

    def close(a: tuple, b: tuple) -> bool:
        return all(abs(p - q) <= 4 for p, q in zip(a, b))

    result: list[dict[str, Any]] = []
    for seg in sorted(
        segs, key=lambda s_: -math.hypot(s_["x2"] - s_["x1"], s_["y2"] - s_["y1"])
    ):
        n = norm(seg)
        if any(close(n, norm(k)) for k in result):
            continue
        result.append(seg)
    return result
