# -*- coding: utf-8 -*-
"""图像与 mask 基元（从 segmenter 拆出）：中文路径读图、游程合并、界栏
剔除、mask 极性与缓存、钳回。segmenter.py 仍为门面。"""
import os
import platform
import sys
import threading
import traceback
from contextvars import ContextVar
import cv2
import numpy as np
from typing import Any
from imaging import imread_unicode
from metadata import enrich_result
from model_registry import resolve_model_path
from seg_trace import _log





def _imread(path: str):
    """cv2.imread 不支持中文路径，用 numpy 绕过。"""
    return imread_unicode(path)




def _runs(active: np.ndarray, min_len: int) -> list[tuple[int, int]]:
    runs = []
    start = None
    for i, value in enumerate(active):
        if value and start is None:
            start = i
        elif not value and start is not None:
            if i - start >= min_len:
                runs.append((start, i))
            start = None
    if start is not None and len(active) - start >= min_len:
        runs.append((start, len(active)))
    return runs




def _merge_close_runs(runs: list[tuple[int, int]], max_gap: int) -> list[tuple[int, int]]:
    if not runs:
        return []
    merged = [runs[0]]
    for start, end in runs[1:]:
        prev_start, prev_end = merged[-1]
        if start - prev_end <= max_gap:
            merged[-1] = (prev_start, end)
        else:
            merged.append((start, end))
    return merged




def _merge_fragmentary_strips(
    runs: list[tuple[int, int]],
    work_w: int,
    work_h: int,
) -> list[tuple[int, int]]:
    """合并同一字列被投影断开的窄碎片。

    木刻大字的横画、撇捺经常让同一列在阈值投影中出现一个很窄的
    邻接段。把它当成新列会生成额外行框；后续再把字框裁到该窄段，
    又会切掉真实字形。这里只合并“窄、紧邻”的片段，保持真正的窄
    夹注列（与相邻列有明显留白）独立。
    """
    if len(runs) < 2:
        return runs
    ordered = sorted((int(a), int(b)) for a, b in runs if b > a)
    widths = [b - a for a, b in ordered]
    median_w = float(np.median(widths)) if widths else 0.0
    # 碎片通常不到正文列中位宽的一半；距离使用绝对像素上限，避免
    # 分辨率提高后把相邻真实夹注列错误合并。
    narrow_limit = max(18.0, min(median_w * 0.48, work_w * 0.045))
    out: list[tuple[int, int]] = [ordered[0]]
    for start, end in ordered[1:]:
        ps, pe = out[-1]
        gap = start - pe
        pw, cw = pe - ps, end - start
        narrow = min(pw, cw) <= narrow_limit
        # 6px 对第 84 页的 15px 碎片足够，同时不会吞掉一般夹注列
        # 之间 10px 以上的印刷留白。
        near = gap <= max(6, int(round(min(pw, cw) * 0.25)))
        if gap >= 0 and narrow and near:
            out[-1] = (ps, end)
        else:
            out.append((start, end))
    return out




def _is_edge_ruling_fragment(
    rect: tuple[int, int, int, int],
    mask: np.ndarray,
    line_bounds: tuple[int, int],
    orientation: str,
) -> bool:
    """Return whether a tiny piece is the page/column ruling line.

    The punctuation post-pass can split a tall cuts box at a continuous page
    edge.  Those pieces are long, very narrow, and sit just outside the real
    ink column.  Treating them as characters creates an apparent extra column
    and shifts the rest of the line.  A real punctuation mark is sparse in
    the reading axis, so the high row/column occupancy check keeps it.
    """
    if mask is None or mask.ndim != 2:
        return False
    x, y, w, h = (int(v) for v in rect)
    cross_start, cross_end = line_bounds
    if orientation == "horizontal":
        cross_span, axis_span = h, w
        near_edge = y <= cross_start + 2 or y + h >= cross_end - 2
        x1, x2 = max(0, x), min(mask.shape[1], x + w)
        y1, y2 = max(0, y), min(mask.shape[0], y + h)
        roi = mask[y1:y2, x1:x2]
        occupancy = float((roi.any(axis=1)).mean()) if roi.size else 0.0
        widths = (roi > 0).sum(axis=1) if roi.size else np.array([], dtype=np.int32)
    else:
        cross_span, axis_span = w, h
        near_edge = x <= cross_start + 2 or x + w >= cross_end - 2
        x1, x2 = max(0, x), min(mask.shape[1], x + w)
        y1, y2 = max(0, y), min(mask.shape[0], y + h)
        roi = mask[y1:y2, x1:x2]
        occupancy = float((roi.any(axis=0)).mean()) if roi.size else 0.0
        widths = (roi > 0).sum(axis=0) if roi.size else np.array([], dtype=np.int32)
    if not near_edge or axis_span < 12:
        return False
    # A ruling fragment is narrow relative to the line and inked through most
    # of its axis.  Keep a minimum absolute width so ordinary small notes are
    # never classified by this rule.
    if cross_span > max(10, int((cross_end - cross_start) * 0.10)):
        return False
    positive = widths[widths > 0]
    # The mask is uint8 (usually 0/255), so ``widths`` must count positive
    # pixels rather than sum byte values.  A ruling can be broken by stains or
    # a faint scan, therefore use a lower occupancy floor than the old 0.68
    # test, while keeping the narrow/low-density signature strict.
    density = float(np.count_nonzero(roi)) / float(roi.size) if roi.size else 0.0
    return (
        occupancy >= 0.35
        and density <= 0.35
        and bool(positive.size)
        and float(np.median(positive)) <= 5.0
    )


def _is_cross_column_band(
    rect: tuple[int, int, int, int],
    mask: np.ndarray | None,
    line_cross: tuple[int, int],
    orientation: str,
    max_axis_span: int,
) -> bool:
    """Return whether a piece is a flat ink band crossing the whole column.

    残缺版框横线/页缘黑带横穿页面上所有列；行框扩展把它捞进本列贴在
    行尾，像素/连通域/标点拆分再把它单独成框，就成了"一个点"伪字框
    （实测 (1061,2122,96,9)：9px 高却占满列宽）。与 _is_edge_ruling_
    fragment（贴列侧、跨轴窄条）互补，这里抓跨轴占满、阅读轴极扁的
    横带。三个条件同时满足才判带：

    1. 沿阅读轴极扁（axis_span ≤ max_axis_span）；
    2. 原始墨迹（非膨胀/带 pad 的框）横向跨度 ≥ 0.85 × 列宽；
    3. 墨迹越过列界延伸进列间纸白缝——两侧 3px 边条墨密度 ≥ 0.3
       （版框横穿缝隙密度接近 1；正常字形再宽也停在列界内，飞白蹭
       进缝里只是零星几点，密度到不了 0.3）。

    字内横画与一/乙类横画字不满足条件 3，不受影响。
    """
    if mask is None or mask.ndim != 2:
        return False
    x, y, w, h = (int(v) for v in rect)
    cross_start, cross_end = (int(v) for v in line_cross)
    cross_w = cross_end - cross_start
    if cross_w <= 0:
        return False
    if orientation == "horizontal":
        if w > max_axis_span:
            return False
        x1, x2 = max(0, x), min(mask.shape[1], x + w)
        band = mask[max(0, cross_start):cross_end, x1:x2] > 0
        inked = np.nonzero(band.any(axis=1))[0]
        strips = (
            mask[max(0, cross_start - 3):cross_start, x1:x2] > 0,
            mask[cross_end:min(mask.shape[0], cross_end + 3), x1:x2] > 0,
        )
    else:
        if h > max_axis_span:
            return False
        y1, y2 = max(0, y), min(mask.shape[0], y + h)
        band = mask[y1:y2, cross_start:cross_end] > 0
        inked = np.nonzero(band.any(axis=0))[0]
        strips = (
            mask[y1:y2, max(0, cross_start - 3):cross_start] > 0,
            mask[y1:y2, cross_end:min(mask.shape[1], cross_end + 3)] > 0,
        )
    if inked.size == 0:
        return False
    if int(inked[-1] - inked[0] + 1) < 0.85 * cross_w:
        return False
    ink_cells = sum(int(strip.sum()) for strip in strips)
    total_cells = sum(int(strip.size) for strip in strips)
    return total_cells > 0 and ink_cells / total_cells >= 0.3




def _remove_ruling_lines(binary: np.ndarray) -> np.ndarray:
    h, w = binary.shape[:2]
    horizontal_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (max(60, w // 4), 1))
    vertical_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (1, max(60, h // 4)))
    horizontal_lines = cv2.morphologyEx(binary, cv2.MORPH_OPEN, horizontal_kernel)
    vertical_lines = cv2.morphologyEx(binary, cv2.MORPH_OPEN, vertical_kernel)
    lines = cv2.bitwise_or(horizontal_lines, vertical_lines)
    return cv2.subtract(binary, lines)




def _tight_rect(mask: np.ndarray, x1: int, x2: int, y1: int, y2: int, pad: int, w: int, h: int):
    roi = mask[y1:y2, x1:x2]
    points = cv2.findNonZero(roi)
    if points is None:
        return None
    rx, ry, rw, rh = cv2.boundingRect(points)
    tx = max(0, x1 + rx - pad)
    ty = max(0, y1 + ry - pad)
    tr = min(w, x1 + rx + rw + pad)
    tb = min(h, y1 + ry + rh + pad)
    if tr - tx < 6 or tb - ty < 10:
        return None
    return tx, ty, tr - tx, tb - ty




def _to_block(
    block_id: int,
    rect: tuple[int, int, int, int],
    source: str,
    col: int = 0,
    order: int = 0,
    text: str = "",
    line_id: str = "",
) -> dict[str, Any]:
    x, y, w, h = rect
    return {
        "id": f"p_b{block_id:04d}",
        "x": int(x),
        "y": int(y),
        "w": int(w),
        "h": int(h),
        "col": int(col),
        "order": int(order),
        "type": "main_text",
        "confirmed": False,
        "text": text,
        "source": source,
        "line_id": line_id,
    }




_TEXT_MASK_CACHE: dict[tuple[str, float], "np.ndarray | None"] = {}


# 各页墨迹 mask 的极性诊断（flipped=已翻转/白字黑底），随 mask 一起更新
_MASK_POLARITY_INFO: dict[str, dict[str, Any]] = {}




def mask_polarity_info(image_path: str) -> dict[str, Any]:
    """最近一次生成该页墨迹 mask 的极性诊断，供诊断界面展示。"""
    try:
        info = _MASK_POLARITY_INFO.get(os.path.abspath(image_path))
    except Exception:
        info = None
    return dict(info) if info else {}




def _zero_edge_filler_bands(gray: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """把四边连续的纯黑填充带从 mask 里清零（就地修改并返回）。

    校对摆正/跨页拆分产出的书页图，裁切范围内可能含原图外的纯黑填
    充（实测矫正图四边暗像素占比 12%~100%）。OTSU 会把纯黑填充当成
    墨迹，行条带/行框因此伸进裁切掉的区域。自每边向内走，"该行/列
    暗像素占比 ≥0.85"的连续段视为填充带清零；暗背景页（整页暗占比
    ≥0.5，阴文/夜间模式）不走此逻辑（由极性翻转负责）。"""
    H, W = gray.shape[:2]
    dark = gray < 100
    if float(dark.mean()) >= 0.5:
        return mask
    row_frac = dark.mean(axis=1)
    col_frac = dark.mean(axis=0)
    thresh = 0.85
    limit_h, limit_w = max(1, int(H * 0.25)), max(1, int(W * 0.25))
    y = 0
    while y < min(limit_h, H) and row_frac[y] >= thresh:
        mask[y, :] = 0
        y += 1
    y = H - 1
    while y >= max(H - limit_h, 0) and row_frac[y] >= thresh:
        mask[y, :] = 0
        y -= 1
    x = 0
    while x < min(limit_w, W) and col_frac[x] >= thresh:
        mask[:, x] = 0
        x += 1
    x = W - 1
    while x >= max(W - limit_w, 0) and col_frac[x] >= thresh:
        mask[:, x] = 0
        x -= 1
    return mask




def _clamp_rect_to_image(
    x: int, y: int, w: int, h: int, image_w: int, image_h: int
) -> tuple[int, int, int, int]:
    """把矩形钳回图片范围（识别框不得超出书页图片本身）。"""
    x1 = max(0, min(int(x), image_w))
    y1 = max(0, min(int(y), image_h))
    x2 = max(0, min(int(x) + int(w), image_w))
    y2 = max(0, min(int(y) + int(h), image_h))
    return x1, y1, max(0, x2 - x1), max(0, y2 - y1)




def _clamp_result_to_image(
    result: dict[str, Any], image_w: int, image_h: int
) -> dict[str, Any]:
    """整页识别结果收口：行框、字框、正文区框、段落框一律钳回图片
    范围（识别框不得超出书页图片本身；区域检测模型可能预测出图外）。
    图片尺寸随响应带给前端（inferHierarchy 主区推断也要钳上界）。"""
    result["image_width"] = image_w
    result["image_height"] = image_h
    blocks: list[dict[str, Any]] = []
    for ln in result.get("lines") or []:
        if not isinstance(ln, dict):
            continue
        ln["x"], ln["y"], ln["w"], ln["h"] = _clamp_rect_to_image(
            ln.get("x", 0), ln.get("y", 0), ln.get("w", 0), ln.get("h", 0),
            image_w, image_h,
        )
        chars = ln.get("chars") or []
        for c in chars:
            if isinstance(c, dict):
                c["x"], c["y"], c["w"], c["h"] = _clamp_rect_to_image(
                    c.get("x", 0), c.get("y", 0), c.get("w", 0), c.get("h", 0),
                    image_w, image_h,
                )
        blocks.extend(c for c in chars if isinstance(c, dict))
    if blocks:
        result["blocks"] = blocks
    for r in result.get("main_regions") or []:
        if isinstance(r, dict):
            r["x"], r["y"], r["w"], r["h"] = _clamp_rect_to_image(
                r.get("x", 0), r.get("y", 0), r.get("w", 0), r.get("h", 0),
                image_w, image_h,
            )
    for pg in result.get("paragraphs") or []:
        if isinstance(pg, dict):
            pg["x"], pg["y"], pg["w"], pg["h"] = _clamp_rect_to_image(
                pg.get("x", 0), pg.get("y", 0), pg.get("w", 0), pg.get("h", 0),
                image_w, image_h,
            )
    return result




def _binarize_ink(img: np.ndarray, diag: dict | None = None) -> np.ndarray:
    """整图 OTSU 二值化墨迹 mask（0/255），带极性自检与退化兜底。

    正常文字页"墨"永远是少数（含栏线通常 <30%）。白字黑底（阴文页/
    暗底扫描）时 OTSU 会把"墨"切到纸面背景一侧，占比过半即翻转。
    极端不均衡双峰（黑底白线页，线占比 ~1%）会让 OTSU 阈值退化到端点
    ——翻转后墨占比仍过半，此时按亮度分位数重切（暗页取亮侧 1% 为墨，
    亮页取暗侧 1%）。行墨迹精修（去栏线）与表格格线检测（保留栏线）
    共用本入口；diag 传入 dict 时回填诊断。"""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    frac0 = float(np.count_nonzero(binary)) / float(binary.size)
    frac = frac0
    flipped = frac > 0.55
    if flipped:
        binary = cv2.bitwise_not(binary)
        frac = 1.0 - frac
    fallback = False
    # 翻转后仍过半、或翻转后几乎无墨（全页被切到一侧的极端退化），
    # 都说明 OTSU 阈值失效——按亮度分位数重切。阈值取分位值与极值的
    # 中点：兜底场景的内容占比常 <1%（如黑底白线页的格线），99 分位
    # 本身可能仍是背景灰度，中点保证切在两峰之间。
    if frac > 0.55 or (flipped and frac < 0.005):
        fallback = True
        dark_page = float(np.mean(gray)) < 128.0
        if dark_page:
            thr = (float(np.percentile(gray, 99)) + float(gray.max())) / 2.0
            binary = np.where(gray >= thr, 255, 0).astype(np.uint8)
        else:
            thr = (float(np.percentile(gray, 1)) + float(gray.min())) / 2.0
            binary = np.where(gray <= thr, 255, 0).astype(np.uint8)
        frac = float(np.count_nonzero(binary)) / float(binary.size)
    if diag is not None:
        diag["flipped"] = flipped
        diag["ink_fraction_before"] = round(frac0, 3)
        diag["percentile_fallback"] = fallback
    if flipped or fallback:
        _log(
            f"[diag:mask] ink fraction {frac:.2f} abnormal"
            f"{' flipped' if flipped else ''}{' percentile fallback' if fallback else ''}"
        )
    return binary


def _text_mask_for_refinement(image_path: str):
    """整页二值化墨迹 mask（去栏线），按 (路径, mtime) 缓存。

    行条带投影、字框像素切分、诊断可视化共用同一份 mask；无缓存时
    每次调用都要整页 OTSU + 形态学，一页识别里会被算 3-4 次。"""
    try:
        stat = os.stat(image_path)
        key = (os.path.abspath(image_path), stat.st_mtime)
    except OSError:
        key = None
    if key is not None and key in _TEXT_MASK_CACHE:
        return _TEXT_MASK_CACHE[key]
    img = _imread(image_path)
    if img is None:
        return None
    polarity: dict[str, Any] = {}
    binary = _binarize_ink(img, polarity)
    if key is not None:
        try:
            _MASK_POLARITY_INFO[key[0]] = {
                "flipped": polarity.get("flipped", False),
                "ink_fraction_before": polarity.get("ink_fraction_before"),
            }
            if len(_MASK_POLARITY_INFO) > 8:
                del _MASK_POLARITY_INFO[next(iter(_MASK_POLARITY_INFO))]
        except Exception:
            pass
    mask = _remove_ruling_lines(binary)
    mask = _zero_edge_filler_bands(
        cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), mask
    )
    if key is not None:
        if len(_TEXT_MASK_CACHE) > 4:
            _TEXT_MASK_CACHE.clear()
        _TEXT_MASK_CACHE[key] = mask
    return mask
