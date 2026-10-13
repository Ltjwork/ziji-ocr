# -*- coding: utf-8 -*-
"""表格格线检测与网格构建（+83 表格识别）。

两个入口：
- detect_table_grid(image_path, rect)：用户标记区域内的网格检测
  （行数/列数如实返回，哪怕 1×N / N×1——用户框了就是表格）。
- detect_tables_in_page(image_path)：整页表格候选查找，要求
  rows≥2 且 cols≥2——古籍正文界行（N 行横线 + 版框两竖线，cols=1）
  与纯版框（1×1）是最大的误报源，靠该门槛挡掉；候选只是 proposed，
  误报由人工在编辑器拒绝。

横竖线形态学对称，与页面阅读方向无关（横版/竖版书页同一路径）；
斜页不在此处理——版面摆正（/dewarp_page）后再做表格识别。
纯 OpenCV + 已有二值化入口，不引入模型依赖。
"""
from __future__ import annotations

from typing import Any

import cv2
import numpy as np

from seg_imaging import _binarize_ink, _imread

# 开运算核长：短于该长度的横/竖笔画（单字、标点）不视为格线。取页面
# 长边的 2%（2000px 扫描页 = 40px），夹在 [15, 80]——下限保护小图，
# 上限避免细线抗噪恶化（核越长，一处断裂丢的段越长）。
_KERNEL_FRACTION = 0.02
_KERNEL_MIN = 15
_KERNEL_MAX = 80
# 闭运算桥接印刷断线：断口 ≤8px 接上（木刻版格线常见细断口）。
_BRIDGE_GAP = 8
# 投影聚类：相邻墨迹行/列间隔 ≤4px 算同一条线。
_CLUSTER_GAP = 4
# 分割线覆盖门槛：窗口内某行的横线墨迹列数 ≥ 窗口宽 25% 才算候选行线
# （挡单元格内文字条带——整行文字的 OTSU 墨迹按行投影也可能很高，
# 但文字不会在某一行上连续覆盖 25% 宽）。
_COVER_FRACTION = 0.25
# 合并单元格判定：相邻单元的公共边界线段覆盖率 < 0.5 视为无线 → 合并。
# 表格线只在交点附近残留（如被墨迹/装订阴影打断）不会低于一半。
_BOUNDARY_COVER = 0.5
# 整页自动检测的线段最短长度（px）：小于它的开运算残渣不参与聚簇。
_SEG_MIN_LEN = 40


def _open_line_masks(ink: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """墨迹 mask → (横线 mask, 竖线 mask)：开运算提线 + 闭运算桥接断口。"""
    klen = int(min(_KERNEL_MAX, max(_KERNEL_MIN, max(ink.shape) * _KERNEL_FRACTION)))
    h_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (klen, 1))
    v_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (1, klen))
    h_mask = cv2.morphologyEx(ink, cv2.MORPH_OPEN, h_kernel)
    v_mask = cv2.morphologyEx(ink, cv2.MORPH_OPEN, v_kernel)
    # 桥接方向与线同向（横线断口在水平方向接）。
    bridge_h = cv2.getStructuringElement(cv2.MORPH_RECT, (_BRIDGE_GAP, 1))
    bridge_v = cv2.getStructuringElement(cv2.MORPH_RECT, (1, _BRIDGE_GAP))
    h_mask = cv2.morphologyEx(h_mask, cv2.MORPH_CLOSE, bridge_h)
    v_mask = cv2.morphologyEx(v_mask, cv2.MORPH_CLOSE, bridge_v)
    return h_mask, v_mask


def _axis_lines(
    mask: np.ndarray,
    x0: int,
    x1: int,
    y0: int,
    y1: int,
) -> list[dict[str, float]]:
    """窗口 [x0,x1)×[y0,y1) 内沿 y 投影聚类横线（竖线调用方转置语义）。

    返回 [{"center": y, "thick": 线厚}]，按 center 升序；center 为簇内
    墨迹行号的加权平均（取整）。只统计横线 mask；竖线 mask 的列投影
    与此对称，由调用方用 .T 复用本函数。
    """
    cover_min = max(1, int((x1 - x0) * _COVER_FRACTION))
    prof = np.count_nonzero(mask[y0:y1, x0:x1], axis=1)
    candidates = np.flatnonzero(prof >= cover_min) + y0
    lines: list[dict[str, float]] = []
    cluster: list[int] = []
    for y in candidates:
        if cluster and y - cluster[-1] > _CLUSTER_GAP:
            lines.append(_finish_line_cluster(cluster))
            cluster = []
        cluster.append(int(y))
    if cluster:
        lines.append(_finish_line_cluster(cluster))
    return [ln for ln in lines if ln]


def _finish_line_cluster(cluster: list[int]) -> dict[str, float] | None:
    """投影簇 → {center, thick}。厚到离谱（>12px）的是墨块/插图边缘，
    不是格线——丢弃，避免把图片黑边当表格线。"""
    thick = cluster[-1] - cluster[0] + 1
    if thick > 12:
        return None
    return {
        "center": float(sum(cluster) / len(cluster)),
        "thick": float(thick),
    }


class _UnionFind:
    def __init__(self, n: int) -> None:
        self.parent = list(range(n))

    def find(self, i: int) -> int:
        while self.parent[i] != i:
            self.parent[i] = self.parent[self.parent[i]]
            i = self.parent[i]
        return i

    def union(self, a: int, b: int) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[rb] = ra


def _boundary_has_line(
    mask: np.ndarray,
    fixed: float,
    lo: int,
    hi: int,
    tol: int,
    end_margin: int,
) -> bool:
    """mask（竖线 mask 查竖边界 / 横线 mask 查横边界）中，fixed±tol 的
    线在 [lo+end_margin, hi-end_margin] 区间内是否有 ≥ 一半长度被墨迹
    覆盖。端部留白避开除交点以外的墨迹扩散；tol 容忍线的轻微倾斜。"""
    lo2, hi2 = lo + end_margin, hi - end_margin
    if hi2 - lo2 < 2:
        return True  # 区间太窄（矮行/窄列），默认有边界（不合并微格）
    fc = int(round(fixed))
    band = mask[lo2:hi2, max(0, fc - tol):fc + tol + 1]
    if band.size == 0:
        return False
    per_col = np.count_nonzero(band, axis=0)
    return bool(per_col.max() >= (hi2 - lo2) * _BOUNDARY_COVER)


def _grid_from_masks(
    h_mask: np.ndarray,
    v_mask: np.ndarray,
    rect: tuple[int, int, int, int],
) -> dict[str, Any] | None:
    """窗口 rect 内从横/竖线 mask 构建网格。构不成网格（<2 横线或 <2
    竖线）返回 None。"""
    x0, y0, x1, y1 = rect
    h_lines = _axis_lines(h_mask, x0, x1, y0, y1)
    v_lines = _axis_lines(v_mask.T, y0, y1, x0, x1)
    if len(h_lines) < 2 or len(v_lines) < 2:
        return None
    rows, cols = len(h_lines) - 1, len(v_lines) - 1
    # 1×1（纯外框，无内部结构）不是表格——无线表格同样落在这一分支，
    # 由 reason 文案引导用户。
    if rows * cols < 2:
        return None
    avg_thick = int(round(
        (sum(ln["thick"] for ln in h_lines) + sum(ln["thick"] for ln in v_lines))
        / (len(h_lines) + len(v_lines))
    ))
    # 单元格内容矩形向内收缩：至少 2px，格线越粗收缩越多，避免格线
    # 墨迹混进单元格文字识别。
    inset = max(2, avg_thick // 2 + 1)
    # 边界线段存在性检查的参数：tol 容线宽，端部留白避交点。
    tol = max(1, avg_thick // 2)
    end_margin = avg_thick + 2

    # 合并单元格：相邻单元公共边界无线 → union。unit(r,c) 索引 r*cols+c。
    uf = _UnionFind(rows * cols)
    for r in range(rows):
        for c in range(cols - 1):
            vc = v_lines[c + 1]["center"]
            if not _boundary_has_line(
                v_mask, vc,
                int(h_lines[r]["center"]), int(h_lines[r + 1]["center"]),
                tol, end_margin,
            ):
                uf.union(r * cols + c, r * cols + c + 1)
    for r in range(rows - 1):
        for c in range(cols):
            hc = h_lines[r + 1]["center"]
            if not _boundary_has_line(
                h_mask.T, hc,
                int(v_lines[c]["center"]), int(v_lines[c + 1]["center"]),
                tol, end_margin,
            ):
                uf.union(r * cols + c, (r + 1) * cols + c)

    # 连通块 → 逻辑单元格（块的左上 unit 坐标 + span）。
    blocks: dict[int, dict[str, int]] = {}
    for r in range(rows):
        for c in range(cols):
            root = uf.find(r * cols + c)
            b = blocks.setdefault(
                root, {"r0": r, "r1": r, "c0": c, "c1": c}
            )
            b["r0"] = min(b["r0"], r)
            b["r1"] = max(b["r1"], r)
            b["c0"] = min(b["c0"], c)
            b["c1"] = max(b["c1"], c)

    gx0 = int(round(v_lines[0]["center"]))
    gy0 = int(round(h_lines[0]["center"]))
    gx1 = int(round(v_lines[-1]["center"]))
    gy1 = int(round(h_lines[-1]["center"]))
    cells: list[dict[str, int]] = []
    for b in sorted(blocks.values(), key=lambda b: (b["r0"], b["c0"])):
        cx0 = int(round(v_lines[b["c0"]]["center"])) + inset
        cy0 = int(round(h_lines[b["r0"]]["center"])) + inset
        cx1 = int(round(v_lines[b["c1"] + 1]["center"])) - inset
        cy1 = int(round(h_lines[b["r1"] + 1]["center"])) - inset
        if cx1 - cx0 < 1 or cy1 - cy0 < 1:
            # 极窄格收缩后为空：保留 1px 内容框，坐标仍要合法。
            cx1, cy1 = max(cx1, cx0 + 1), max(cy1, cy0 + 1)
        cells.append({
            "x": cx0, "y": cy0, "w": cx1 - cx0, "h": cy1 - cy0,
            "row": b["r0"], "col": b["c0"],
            "row_span": b["r1"] - b["r0"] + 1,
            "col_span": b["c1"] - b["c0"] + 1,
        })
    return {
        "ok": True,
        # 外框取边界线中心，钳回图像由调用方负责（mask 已是图像坐标系）。
        "x": gx0, "y": gy0, "w": gx1 - gx0, "h": gy1 - gy0,
        "rows": rows, "cols": cols,
        "h_lines": [int(round(ln["center"])) for ln in h_lines],
        "v_lines": [int(round(ln["center"])) for ln in v_lines],
        "line_width": avg_thick,
        "cells": cells,
    }


def _clamp_window(
    w: int, h: int, rect: tuple[int, int, int, int]
) -> tuple[int, int, int, int]:
    x, y, rw, rh = [int(v) for v in rect]
    x, y = max(0, x), max(0, y)
    return (x, y, min(w, x + max(1, rw)), min(h, y + max(1, rh)))


def detect_table_grid(
    image_path: str,
    x: int,
    y: int,
    w: int,
    h: int,
) -> dict[str, Any]:
    """用户标记区域内的表格网格检测。

    返回 ok=True 时含网格全量信息（坐标为全图绝对像素 x/y/w/h）；
    ok=False 时 reason 说明原因（图不存在 / 格线不足）。手动路径行数
    列数如实返回——用户框定即表格，不施加 rows≥2 且 cols≥2 的自动
    检测门槛（挡界行的门槛只用于整页自动预标注）。
    """
    img = None
    try:
        img = _imread(image_path)
    except OSError:
        return {"ok": False, "reason": "image not found"}
    if img is None:
        return {"ok": False, "reason": "image not found"}
    ih, iw = img.shape[:2]
    rect = _clamp_window(iw, ih, (x, y, w, h))
    if rect[2] - rect[0] < 8 or rect[3] - rect[1] < 8:
        return {"ok": False, "reason": "region too small"}
    ink = _binarize_ink(img)
    h_mask, v_mask = _open_line_masks(ink)
    grid = _grid_from_masks(h_mask, v_mask, rect)
    if grid is None:
        return {
            "ok": False,
            "reason": "未检测到表格格线（需要外框加至少一条内部横线或竖线；"
                      "无线表格暂不支持）",
        }
    return grid


def _mask_segments(
    mask: np.ndarray, min_len: int, axis: str
) -> list[tuple[int, int, int, int]]:
    """横/竖线 mask → 线段连通域，统一返回**原域 bbox** (x, y, w, h)：
    横线段 w=长度、h=线厚；竖线段（内部转置计算）w=线厚、h=长度。
    开运算后一条格线就是一个连通域（断裂已被闭运算桥接）。"""
    if axis == "v":
        mask = mask.T
    n, labels, stats, _ = cv2.connectedComponentsWithStats((mask > 0).astype(np.uint8))
    segs = []
    for i in range(1, n):
        sx, sy, sw, sh, area = stats[i]
        if sw >= min_len and sh <= 12:
            segs.append(
                (int(sx), int(sy), int(sw), int(sh))
                if axis == "h"
                else (int(sy), int(sx), int(sh), int(sw))
            )
    return segs


def _parallel_same_line(
    a: tuple[int, int, int, int],
    b: tuple[int, int, int, int],
    axis: str,
    gap: int = 12,
) -> bool:
    """两条平行线段属于同一结构（同线两半 / 双钩边框内外线）：位置轴
    相距 ≤5px，跨距轴区间重叠或断口 ≤gap。"""
    if axis == "h":
        pos_close = abs(a[1] - b[1]) <= 5
        lo = max(a[0], b[0]) - gap
        hi = min(a[0] + a[2], b[0] + b[2]) + gap
    else:
        pos_close = abs(a[0] - b[0]) <= 5
        lo = max(a[1], b[1]) - gap
        hi = min(a[1] + a[3], b[1] + b[3]) + gap
    return pos_close and hi > lo


def _bbox_intersect(
    a: tuple[int, int, int, int],
    b: tuple[int, int, int, int],
    tol: int = 4,
) -> bool:
    """两个 bbox 相交或贴近 tol——横线段与竖线段的交叉判定。"""
    return (a[0] - tol < b[0] + b[2] and a[0] + a[2] + tol > b[0]
            and a[1] - tol < b[1] + b[3] and a[1] + a[3] + tol > b[1])


def detect_tables_in_page(image_path: str) -> list[dict[str, Any]]:
    """整页查找表格候选：线段连通聚簇 → 每簇建网格验证 rows≥2 且 cols≥2。

    返回 [{"x","y","w","h","rows","cols"}]。门槛挡两类最大误报：正文
    界行结构（cols=1）与纯版框（1×1）。候选仅供预标注（proposed），
    由人工确认/拒绝。"""
    img = None
    try:
        img = _imread(image_path)
    except OSError:
        return []
    if img is None:
        return []
    ink = _binarize_ink(img)
    h_mask, v_mask = _open_line_masks(ink)
    min_len = max(_SEG_MIN_LEN, int(max(ink.shape) * _KERNEL_FRACTION))
    h_segs = _mask_segments(h_mask, min_len, "h")
    v_segs = _mask_segments(v_mask, min_len, "v")
    if len(h_segs) < 2 or len(v_segs) < 2:
        return []

    # 并查集聚簇：横-竖交叉连通；平行线段重叠/近断口也连通（同线两半、
    # 双钩外框）。簇内同时有 ≥2 横段与 ≥2 竖段才算表格骨架。
    total = len(h_segs) + len(v_segs)
    uf = _UnionFind(total)
    for i in range(len(h_segs)):
        for j in range(i + 1, len(h_segs)):
            if _parallel_same_line(h_segs[i], h_segs[j], "h"):
                uf.union(i, j)
    off = len(h_segs)
    for i in range(len(v_segs)):
        for j in range(i + 1, len(v_segs)):
            if _parallel_same_line(v_segs[i], v_segs[j], "v"):
                uf.union(off + i, off + j)
    for i, hseg in enumerate(h_segs):
        for j, vseg in enumerate(v_segs):
            if _bbox_intersect(hseg, vseg):
                uf.union(i, off + j)

    clusters: dict[int, list[int]] = {}
    for i in range(total):
        clusters.setdefault(uf.find(i), []).append(i)

    tables: list[dict[str, Any]] = []
    for members in clusters.values():
        h_idx = [i for i in members if i < off]
        v_idx = [i - off for i in members if i >= off]
        if len(h_idx) < 2 or len(v_idx) < 2:
            continue
        boxes = [h_segs[i] for i in h_idx] + [v_segs[i] for i in v_idx]
        rx0 = min(b[0] for b in boxes)
        ry0 = min(b[1] for b in boxes)
        rx1 = max(b[0] + b[2] for b in boxes)
        ry1 = max(b[1] + b[3] for b in boxes)
        rect = _clamp_window(img.shape[1], img.shape[0], (rx0, ry0, rx1 - rx0, ry1 - ry0))
        grid = _grid_from_masks(h_mask, v_mask, rect)
        if grid is None or grid["rows"] < 2 or grid["cols"] < 2:
            continue
        tables.append({
            "x": grid["x"], "y": grid["y"], "w": grid["w"], "h": grid["h"],
            "rows": grid["rows"], "cols": grid["cols"],
        })
    # 阅读序：先上后下、先左后右（列序方向是导出层的事，这里只排序稳定）。
    tables.sort(key=lambda t: (t["y"], t["x"]))
    return tables
