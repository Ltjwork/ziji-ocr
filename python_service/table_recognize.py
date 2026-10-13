# -*- coding: utf-8 -*-
"""表格单元格文字识别编排（+83 表格识别）。

table_grid 出网格几何，本模块往每格里填文字：格内连通域切字（去栏线
墨迹 mask 上直接取连通域——make_kraken_char_splitter 是为"单列行"
设计的，把整格当一条行会按格高估字尺寸、膨胀粘字，不适合多行/多列
的格子）+ Kraken 逐字读（复用 _recognize_char_boxes，与编辑器单字框
补读同一条路径）。全表字框合成一批一次 daemon 请求（逐字读同批统一
放大倍数，40 格的表一次往返）。

格内阅读方向自动判定：瘦高格竖排、扁格横排、方形格跟随页面方向
（古籍表格的表头/备注格常与正文方向不同，横竖版书页都会出现表格，
判定只看格子几何，与页面方向无关地对称）。
"""
from __future__ import annotations

from statistics import median
from typing import Any

import cv2
import numpy as np

from kraken_bridge import _recognize_char_boxes
from seg_imaging import _text_mask_for_refinement
from table_grid import detect_table_grid

# 方形格（宽高比在 [1/1.5, 1.5] 内）跟随页面方向，更扁/更高才反转。
_SQUARE_RATIO = 1.5
# 碎块过滤：面积 < 同格中位字框面积 6% 的连通域（断线残墨、格线毛刺）
# 不参与识别。
_FRAG_AREA_FRACTION = 0.06
# 极端细长的连通域（去栏线后残余的断线段）不是字。
_THIN_RATIO = 6.0


def cell_orientation(
    cell: dict[str, Any], page_orientation: str
) -> str:
    """格内文字方向：几何优先，方形格跟随页面。"""
    w, h = float(cell["w"]), float(cell["h"])
    if w > h * _SQUARE_RATIO:
        return "horizontal"
    if h > w * _SQUARE_RATIO:
        return "vertical"
    return page_orientation


def _order_rects(
    rects: list[tuple[int, int, int, int]],
    orientation: str,
    horizontal_dir: str,
    vertical_dir: str,
) -> list[tuple[int, int, int, int]]:
    """格内字框排阅读序。竖排：先列后字（列序 = horizontal_dir）；横排：
    先行后字（行内序 = horizontal_dir，行序 = vertical_dir）。列/行划分
    用中位字宽做容差——同列字的 x 抖动小于半个字宽。"""
    if not rects:
        return []

    def center(a: tuple[int, int, int, int], i: int) -> float:
        return a[i] + a[i + 2] / 2

    if orientation == "vertical":
        span = median(r[2] for r in rects)
        cols: list[list[tuple[int, int, int, int]]] = []
        col_center: list[float] = []
        for r in sorted(rects, key=lambda r: center(r, 0)):
            c = center(r, 0)
            if cols and abs(c - col_center[-1]) <= max(4.0, span * 0.6):
                cols[-1].append(r)
                col_center[-1] = (col_center[-1] + c) / 2
            else:
                cols.append([r])
                col_center.append(c)
        if horizontal_dir == "rtl":
            cols.reverse()
        out: list[tuple[int, int, int, int]] = []
        for col in cols:
            out.extend(sorted(col, key=lambda r: -r[1] if vertical_dir == "btt" else r[1]))
        return out
    span = median(r[3] for r in rects)
    rows: list[list[tuple[int, int, int, int]]] = []
    row_center: list[float] = []
    for r in sorted(rects, key=lambda r: center(r, 1)):
        c = center(r, 1)
        if rows and abs(c - row_center[-1]) <= max(4.0, span * 0.6):
            rows[-1].append(r)
            row_center[-1] = (row_center[-1] + c) / 2
        else:
            rows.append([r])
            row_center.append(c)
    if vertical_dir == "btt":
        rows.reverse()
    out = []
    for row in rows:
        out.extend(sorted(row, key=lambda r: -r[0] if horizontal_dir == "rtl" else r[0]))
    return out


def _cell_char_rects(
    mask: np.ndarray,
    cell: dict[str, Any],
) -> list[tuple[int, int, int, int]]:
    """格内字框：去栏线 mask 的连通域 → 中心入格 → 碎块/细长线过滤。

    窗口向格外放 3px：贴格线的字（格线剔除处略缺墨）完整入框，靠
    中心入格过滤兜住越界部分。
    """
    pad = 3
    cx0 = max(0, cell["x"] - pad)
    cy0 = max(0, cell["y"] - pad)
    cx1 = min(mask.shape[1], cell["x"] + cell["w"] + pad)
    cy1 = min(mask.shape[0], cell["y"] + cell["h"] + pad)
    if cx1 - cx0 < 4 or cy1 - cy0 < 4:
        return []
    sub = (mask[cy0:cy1, cx0:cx1] > 0).astype(np.uint8)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(sub)
    comps = [
        (int(sx), int(sy), int(sw), int(sh))
        for i in range(1, n)
        for sx, sy, sw, sh, area in (stats[i],)
        if area >= 4
    ]
    # 绝对坐标 + 中心入格
    abs_rects = [(cx0 + r[0], cy0 + r[1], r[2], r[3]) for r in comps]
    gx0, gy0 = cell["x"], cell["y"]
    gx1, gy1 = cell["x"] + cell["w"], cell["y"] + cell["h"]
    inside = [
        r for r in abs_rects
        if gx0 <= r[0] + r[2] / 2 <= gx1 and gy0 <= r[1] + r[3] / 2 <= gy1
    ]
    if not inside:
        return []
    # 细长线残余丢弃（长宽比 > _THIN_RATIO）
    inside = [
        r for r in inside
        if max(r[2], r[3]) <= min(r[2], r[3]) * _THIN_RATIO
    ]
    if not inside:
        return []
    med_area = median(r[2] * r[3] for r in inside)
    return [r for r in inside if r[2] * r[3] >= med_area * _FRAG_AREA_FRACTION]


def recognize_table(
    image_path: str,
    x: int,
    y: int,
    w: int,
    h: int,
    orientation: str = "vertical",
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
) -> dict[str, Any]:
    """表格识别入口：网格 + 每格文字（含字框与逐字置信度）。

    坐标均为全图绝对像素。格线不足时透传 detect_table_grid 的
    ok=False + reason；Kraken daemon 不可用等识别异常同样落到
    ok=False（网格几何仍返回，文字留空由前端提示重试）。
    """
    grid = detect_table_grid(image_path, x, y, w, h)
    if not grid.get("ok"):
        return grid
    cells: list[dict[str, Any]] = grid["cells"]
    try:
        mask = _text_mask_for_refinement(image_path)
        if mask is None:
            for cell in cells:
                cell["orientation"] = cell_orientation(cell, orientation)
                cell["text"], cell["chars"] = "", []
            grid["reason"] = "无法生成页面墨迹 mask"
            grid["ocr"] = "unavailable"
            return grid
        # 先全表收集字框（mask 内部有缓存，只算一次），再合成一批逐字读。
        per_cell: list[list[tuple[int, int, int, int]]] = []
        for cell in cells:
            cell["orientation"] = cell_orientation(cell, orientation)
            rects = _cell_char_rects(mask, cell)
            per_cell.append(_order_rects(
                rects, cell["orientation"], horizontal_dir, vertical_dir
            ))
        flat = [r for rects in per_cell for r in rects]
        recs = (
            _recognize_char_boxes(
                image_path, flat, orientation, horizontal_dir, pad=True
            )
            if flat
            else []
        )
    except Exception as exc:  # noqa: BLE001 —— daemon 池/切分异常不吞几何
        grid["reason"] = f"单元格识别失败：{exc}"
        grid["ocr"] = "unavailable"
        for cell in cells:
            cell["orientation"] = cell_orientation(cell, orientation)
            cell["text"], cell["chars"] = "", []
        return grid
    pos = 0
    for cell, rects in zip(cells, per_cell):
        chunk = recs[pos: pos + len(rects)]
        pos += len(rects)
        cell["text"] = "".join((c.get("text") or "").strip() for c in chunk)
        cell["chars"] = [
            {
                "x": int(r[0]), "y": int(r[1]), "w": int(r[2]), "h": int(r[3]),
                "text": (c.get("text") or "").strip(),
                "conf": float(c.get("conf") or 0.0),
            }
            for r, c in zip(rects, chunk)
        ]
    grid["ocr"] = "kraken+chat_rec"
    return grid
