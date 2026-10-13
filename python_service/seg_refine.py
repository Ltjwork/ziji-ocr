# -*- coding: utf-8 -*-
"""墨迹精修与标点拆分（从 segmenter 拆出）：格数估计、标点扩张、
高框/巨框按墨迹再拆与碎片合并。segmenter.py 仍为门面。"""
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
from seg_imaging import (_imread, _runs, _merge_close_runs, _tight_rect, _to_block, _text_mask_for_refinement, _is_edge_ruling_fragment, _is_cross_column_band)





def _estimate_vertical_grid_count(region: tuple[int, int, int, int]) -> int:
    x, y, w, h = region
    if w <= 0 or h <= 0:
        return 0
    if h < w * 1.8:
        return 0

    char_pitch_candidates = [w * ratio for ratio in (0.75, 0.85, 0.95, 1.05, 1.15)]
    counts = [int(round(h / max(1.0, pitch))) for pitch in char_pitch_candidates]
    counts = [count for count in counts if count >= 2]
    if not counts:
        return 0

    # 用中位数作为几何估计，避免使用最小字距导致明显过切。
    counts.sort()
    return counts[len(counts) // 2]




def _choose_expected_count(
    region: tuple[int, int, int, int],
    ocr_expected_count: int = 0,
) -> tuple[int, str, int]:
    geometric_count = _estimate_vertical_grid_count(region)
    if geometric_count <= 1:
        return max(0, ocr_expected_count), "ocr", geometric_count
    if ocr_expected_count <= 1:
        return geometric_count, "layout-grid", geometric_count

    diff_ratio = abs(ocr_expected_count - geometric_count) / max(1, geometric_count)
    # 行级 OCR 的字符数通常比基于宽高比的粗略估计可靠；几何估计只做参考。
    # 旧逻辑在字距偏窄时会强制采用过大的几何字数，导致一个字被切成多个槽位。
    if diff_ratio > 0.35:
        return ocr_expected_count, "ocr-conflict", geometric_count
    return ocr_expected_count, "ocr-compatible", geometric_count




def _expand_rect_for_punctuation(
    rect: tuple[int, int, int, int],
    mask: np.ndarray | None,
    image_w: int,
    image_h: int,
    orientation: str = "vertical",
) -> tuple[int, int, int, int]:
    """把紧贴正文墨迹的行框向标点方向补高/补宽。

    古籍竖排的 ``，。；`` 等标点通常落在上一字的下方，检测/投影
    得到的行框容易只包住主体字而把标点留在框外。这里仅在框外紧邻区域发现
    小而稀疏的墨迹连通块时扩展行框；大块墨迹和远处噪声不会触发扩展。
    横排则按同样规则向右扩展。单字框仍保持原有紧框，避免改变字槽数量。
    """
    if mask is None or mask.ndim != 2:
        return rect
    x, y, rw, rh = (int(v) for v in rect)
    if rw <= 0 or rh <= 0:
        return rect
    # 方块字的参考尺寸：竖排取列宽，横排取行高。
    char_size = max(8, min(256, int(round(rw if orientation == "vertical" else rh))))
    pad = max(2, min(image_w, image_h) // 500)
    max_extension = max(8, int(round(char_size * 0.9)))

    if orientation == "vertical":
        x1, x2 = max(0, x - pad), min(image_w, x + rw + pad)
        y1, y2 = max(0, y + rh), min(image_h, y + rh + max_extension)
        if y2 <= y1:
            return rect
        roi = mask[y1:y2, x1:x2]
        axis_offset = y1
    else:
        x1, x2 = max(0, x + rw), min(image_w, x + rw + max_extension)
        y1, y2 = max(0, y - pad), min(image_h, y + rh + pad)
        if x2 <= x1:
            return rect
        roi = mask[y1:y2, x1:x2]
        axis_offset = x1

    if roi.size == 0 or not np.any(roi):
        return rect
    num_labels, _labels, stats, _centroids = cv2.connectedComponentsWithStats(
        (roi > 0).astype(np.uint8), connectivity=8,
    )
    # 只接受小型、稀疏、靠近边界的组件；主体字高度通常接近 char_size，
    # 标点高度明显更小。面积上限也可排除相邻整字或版心线。
    candidate: tuple[int, int] | None = None
    max_punct_h = max(4, int(round(char_size * 0.65)))
    max_punct_area = max(12, int(round(char_size * char_size * 0.45)))
    for idx in range(1, num_labels):
        cx = int(stats[idx, cv2.CC_STAT_LEFT])
        cy = int(stats[idx, cv2.CC_STAT_TOP])
        cw = int(stats[idx, cv2.CC_STAT_WIDTH])
        ch = int(stats[idx, cv2.CC_STAT_HEIGHT])
        area = int(stats[idx, cv2.CC_STAT_AREA])
        if area < 2 or area > max_punct_area or ch > max_punct_h:
            continue
        if orientation == "vertical":
            # 标点应与行框横向重叠，且不能离边界太远。
            overlap = max(0, min(x + rw, x1 + cx + cw) - max(x, x1 + cx))
            if overlap < max(2, int(round(rw * 0.2))):
                continue
            start, end = axis_offset + cy, axis_offset + cy + ch
        else:
            overlap = max(0, min(y + rh, y1 + cy + ch) - max(y, y1 + cy))
            if overlap < max(2, int(round(rh * 0.2))):
                continue
            start, end = axis_offset + cx, axis_offset + cx + cw
        # 取离原框最近的标点，防止把更远的噪声一并吞入。
        if candidate is None or start < candidate[0]:
            candidate = (start, end)

    if candidate is None:
        return rect
    _start, end = candidate
    extra = max(2, int(round(char_size * 0.08)))
    if orientation == "vertical":
        new_bottom = min(image_h, max(y + rh, end + extra))
        if new_bottom <= y + rh:
            return rect
        _log(
            f"[diag:punct] expand vertical rect={rect} -> "
            f"({x},{y},{rw},{new_bottom - y}) component_end={end}"
        )
        return x, y, rw, new_bottom - y
    new_right = min(image_w, max(x + rw, end + extra))
    if new_right <= x + rw:
        return rect
    _log(
        f"[diag:punct] expand horizontal rect={rect} -> "
        f"({x},{y},{new_right - x},{rh}) component_end={end}"
    )
    return x, y, new_right - x, rh




def expand_line_rect_to_neighbor_ink(
    rect: tuple[int, int, int, int],
    mask: np.ndarray | None,
    image_w: int,
    image_h: int,
    orientation: str = "vertical",
) -> tuple[int, int, int, int]:
    """把行框沿阅读轴扩到本行墨迹的连续段两端（返回扩后框，不改原值）。

    偏短的行框（人工画的行框、历史上切短的自动行框）常把行外的字整段
    留在框外，单行重识别时这些字既读不到也切不出，表现为"识别不全"
    （实测整列 1420px 连续墨迹、行框只盖住中段 581px）。扩展以行框的
    横向范围（竖排）为窗，沿阅读轴逐行向外找墨迹；遇到超过约 0.85 个
    字高的纯白区间就停——白色区间的高度是字距的直接量度：字与字之间
    只有小空隙，行末空白/段首缩进/缺字空位远大于它，扩展自然止于本行
    墨迹的连续段，不需要额外的高度上限（图像边缘是硬边界）。竖排行框
    横向不越列、横排行框纵向不越行，扩展不会吃进相邻行。

    跨轴窗口只统计原框范围内的自有墨迹（见下方 own_band）：邻列经
    pad 缝隙喂进来的边缘墨迹不算数，否则链条会顺着相邻正文列的连续
    墨迹把夹注小字段行框一路拉到整页高。"""
    if mask is None or mask.ndim != 2:
        return rect
    x, y, w, h = (int(v) for v in rect)
    if w <= 0 or h <= 0:
        return rect
    vertical = orientation != "horizontal"
    char_size = max(12, int(round(w if vertical else h)))
    gap_limit = max(6, int(round(char_size * 0.85)))

    # 外扩窗口收紧到原框自身的墨迹范围（去掉跨轴 pad）：邻列笔画不再
    # 经窗口边缘喂入链条。夹注小字列与正文列只隔一条窄缝，原框带 pad
    # 时正文列左缘 1~2px 墨迹在几乎每一行都够到尘点下限，链条顺着邻列
    # 连续墨迹一路扩到整页（实测 (885,198,67,183) 两字小注段被链成
    # (885,0,67,2131)，13 个字框全叠在两字段图上）。自有墨迹以原框范
    # 围内的实际墨迹为准——原框稍窄稍偏时仍覆盖整列笔画，只排除缝对
    # 面的邻列；原框内无墨迹时退回原框范围（不外扩的退化输入）。
    if vertical:
        band_y1, band_y2 = max(0, y), min(mask.shape[0], y + h)
        band_x1, band_x2 = max(0, x), min(mask.shape[1], x + w)
        own_band = mask[band_y1:band_y2, band_x1:band_x2]
        own_cols = np.nonzero(own_band.any(axis=0))[0]
        if own_cols.size:
            cross1, cross2 = band_x1 + int(own_cols[0]), band_x1 + int(own_cols[-1]) + 1
        else:
            cross1, cross2 = band_x1, band_x2
    else:
        band_y1, band_y2 = max(0, y), min(mask.shape[0], y + h)
        band_x1, band_x2 = max(0, x), min(mask.shape[1], x + w)
        own_band = mask[band_y1:band_y2, band_x1:band_x2]
        own_rows = np.nonzero(own_band.any(axis=1))[0]
        if own_rows.size:
            cross1, cross2 = band_y1 + int(own_rows[0]), band_y1 + int(own_rows[-1]) + 1
        else:
            cross1, cross2 = band_y1, band_y2

    def band_ink(pos: int) -> int:
        band = mask[pos:pos + 1, cross1:cross2] if vertical else mask[cross1:cross2, pos:pos + 1]
        return int(np.count_nonzero(band))

    # 灰尘下限：扫描噪声（纸面尘点/装订屑）在二值掩码上是每行 1~6px 的
    # 散点，真实文字行即使最细的笔画行也明显更高（实测中位 27px、p25
    # 19px 的行，其下方空白里 96% 的"墨迹行"只有 1~8px 尘点）。以行内
    # 墨迹行的中位数为基准取 20%（钳在 5..10px），尘点行不再算墨迹，扩
    # 展在空白处自然被 gap_limit 截停——此前"任一像素即墨迹"让尘点链把
    # 11 字行框一路拉到整页高（1009→2132px），空白尾区被下游切成一串
    # 碎框并全部叠在同一位置（用户实测"禄字叠了 18 层"）。
    axis1, axis2 = ((y, y + h) if vertical else (x, x + w))
    axis_limit = mask.shape[0] if vertical else mask.shape[1]
    own = np.array(
        [band_ink(p) for p in range(max(0, axis1), min(axis_limit, axis2))],
        dtype=np.int32,
    )
    own_inked = own[own > 0]
    ref = float(np.median(own_inked)) if own_inked.size else 0.0
    dust_floor = int(min(10, max(5, round(ref * 0.2))))

    def axis_has_ink(pos: int) -> bool:
        return band_ink(pos) >= dust_floor

    def expand_end(start: int, step: int, limit: int) -> int:
        reach = start  # 已确认属于本行的最远墨迹行
        probe = start  # 向外探测的行（每步前进，空白行也要走过去）
        gap = 0
        while 0 <= probe + step <= limit:
            probe += step
            if axis_has_ink(probe):
                reach = probe
                gap = 0
            else:
                gap += 1
                if gap >= gap_limit:
                    break
        return reach

    if vertical:
        top = expand_end(y, -1, image_h - 1)
        bottom = expand_end(y + h - 1, 1, image_h - 1)
        if top < y or bottom > y + h - 1:
            expanded = (x, top, w, max(h, bottom - top + 1))
            _log(
                f"[diag:line-expand] rect={rect} -> {expanded} "
                f"(gap_limit={gap_limit})"
            )
            return expanded
        return rect
    left = expand_end(x, -1, image_w - 1)
    right = expand_end(x + w - 1, 1, image_w - 1)
    if left < x or right > x + w - 1:
        expanded = (left, y, max(w, right - left + 1), h)
        _log(
            f"[diag:line-expand] rect={rect} -> {expanded} "
            f"(gap_limit={gap_limit})"
        )
        return expanded
    return rect




# ── "字+标点"同框的后检拆分 ──
# 检测/切分偶尔把紧贴字上方/下方的小标点（。，、等）画进同一个字框：
# 连通域切分的碎片合并、cuts 条带框收紧时的墨迹段归属都会触发。这样的
# 框沿阅读轴显著高于本行其余字，用本行中位字高做基线检出后，回看框内
# 墨迹分布确认再拆开。基线取中位数而非平均数：同框污染框本身会拉高
# 平均值，中位数对单个离群值免疫（这正是"按这行整体文字高度判断"的
# 可靠实现）。
_PUNCT_SPLIT_TALL_RATIO = 1.18   # 框高超过中位字高 1.18 倍即复查


_PUNCT_SPLIT_MIN_MARGIN = 5      # 且至少高出 5px（小字时压掉相对值噪声）


_PUNCT_SPLIT_GIANT_RATIO = 2.5   # 达到 2.5 倍即为巨框：按白色空隙逐段拆


_PUNCT_SPLIT_PUNCT_RATIO = 0.62  # 标点段高度上限（相对主字段——框里那个字本身）


_PUNCT_SPLIT_MAIN_LO = 0.6       # 主字段（字本身）高度下限（相对中位字高）


_PUNCT_SPLIT_MAIN_HI = 1.4       # 主字段高度上限


_PUNCT_SPLIT_GLYPH_SPAN = 1.5    # 两个"字宽"段合计高低于此×中位字高：单字部件留白


_PUNCT_SPLIT_GLYPH_RUN_MAX = 0.7  # …且每段都低于此×中位字高（半字高，非整字）

_PUNCT_SPLIT_GLYPH_GAP = 0.15    # 宽段窄缝判据：相邻段缝 ≤ 此×中位字高为字内
                                  # 留白（會/需类部件缝仅几 px；字与标点/角点
                                  # 的间隔约半个字高，实测 24~27px vs 4px）


_PUNCT_SPLIT_MAX_PASSES = 3      # 多轮拆分：拆掉一批后中位基线回落，再捞边缘案例




def _tight_piece(
    mask: np.ndarray,
    x1: int,
    x2: int,
    y1: int,
    y2: int,
    pad: int,
    image_w: int,
    image_h: int,
):
    """_tight_rect 的小件版：标点墨迹只有几像素高，不能套 6x10 下限。"""
    roi = mask[y1:y2, x1:x2]
    points = cv2.findNonZero(roi) if roi.size else None
    if points is None:
        return None
    rx, ry, rw, rh = cv2.boundingRect(points)
    tx = max(0, x1 + rx - pad)
    ty = max(0, y1 + ry - pad)
    tr = min(image_w, x1 + rx + rw + pad)
    tb = min(image_h, y1 + ry + rh + pad)
    if tr - tx < 2 or tb - ty < 2:
        return None
    return tx, ty, tr - tx, tb - ty




def _run_ink_width(
    roi: np.ndarray,
    run_start: int,
    run_end: int,
    vertical: bool,
) -> int:
    """一段墨迹沿跨阅读轴方向的墨迹宽度。

    横画类字（一/乙/二…）矮而宽（占满整列宽），标点（。，；）紧凑
    窄小——轴向高度分不出两者（都很矮），宽度才是关键判别信号。"""
    band = roi[run_start:run_end] if vertical else roi[:, run_start:run_end]
    # 竖排取每列是否有墨（沿行归约，axis=0）；横排取每行（axis=1）。
    cols = np.any(band, axis=0 if vertical else 1)
    idx = np.nonzero(cols)[0]
    return int(idx[-1] - idx[0] + 1) if idx.size else 0


_SOLID_BAND_UNIFORMITY = 0.65  # 每行墨迹延展宽度的最小/最大比达此值视为延展均匀
_SOLID_BAND_FILL = 0.6         # 延展均匀之外，每行墨量还需达最大延展的此比例


def _run_is_solid_band(
    roi: np.ndarray,
    run_start: int,
    run_end: int,
    vertical: bool,
) -> bool:
    """一段墨迹是否为"实心横带"（横画类字：一/乙/粗横）。

    两个条件同时满足：①每行墨迹延展宽度（首末墨列/行的跨度）均匀
    （min/max ≥ 0.65）——横画每一行都横贯近乎同一宽度，會的人字头上
    窄下宽（顶端两笔刚分开，行宽只有笔画零头）；②每行墨量达最大延
    展的一半以上——横画是整段实墨，日/田类部件虽行行有左右竖笔、
    延展均匀，行墨量却只有两笔竖画（内部留白），不是横带。字与紧贴
    的『一』（实测间隔仅 2~6px，与部件缝同量级）必须照常拆开，缝宽
    判据之外再加这一形状判据区分"独立横画字"与"单字部件"。"""
    band = roi[run_start:run_end] if vertical else roi[:, run_start:run_end]
    rows = band if vertical else band.T
    inked = rows.any(axis=1)
    if not inked.any():
        return False
    left = rows.argmax(axis=1)
    right = rows.shape[1] - 1 - rows[:, ::-1].argmax(axis=1)
    widths = (right - left + 1)[inked]
    counts = rows.sum(axis=1).astype(np.int32)[inked]
    if widths.size == 0:
        return False
    return (
        int(widths.min()) >= _SOLID_BAND_UNIFORMITY * int(widths.max())
        and int(counts.min()) >= _SOLID_BAND_FILL * int(widths.max())
    )




def _split_tall_box_by_ink_runs(
    rect: tuple[int, int, int, int],
    mask: np.ndarray,
    median_span: float,
    image_w: int,
    image_h: int,
    vertical: bool,
) -> list[tuple[int, int, int, int]] | None:
    """超高字框内的墨迹复查：主字段 + 贴着的小标点段才拆。

    沿阅读轴看框内墨迹分段：恰好一段"正常字高"的主墨迹 + 至多两段
    "标点高"的小墨迹才判定为标点入框，按段拆成独立字框（标点框贴
    标点墨迹）。小段的高度上限相对主字段本身判定（框里那个字高的一
    半多一点）——刻本标点再大也不到半个字，两个整字粘连则彼此相当，
    天然分开两类。主段不像正常字时返回 None，保持原框交回原有逻辑
    处理。返回的框沿阅读轴升序。每个放弃分支都写诊断日志（原因可
    追溯）。
    """
    x, y, w, h = (int(v) for v in rect)
    x1, x2 = max(0, x), min(image_w, x + w)
    y1, y2 = max(0, y), min(image_h, y + h)

    def fail(reason: str) -> None:
        _log(
            f"[diag:punct-split] 未拆 rect={rect} span={h if vertical else w} "
            f"ref={median_span:.0f} 原因={reason}"
        )

    if x2 - x1 < 2 or y2 - y1 < 2:
        fail("框越界退化")
        return None
    roi = mask[y1:y2, x1:x2] > 0
    axis_ink = roi.sum(axis=1 if vertical else 0).astype(np.int32)

    runs = _runs(axis_ink > 0, min_len=1)
    if len(runs) == 1:
        # 标点与主字墨迹相连（无空档）时找"细腰"：墨迹量骤减到主字
        # 行墨迹中位数 35% 以下的窄行作为分界。搜索窗口避开两端 20%
        # （标点本身就在端部，字内起收笔的细行不会落在窗口里被误切）。
        start, end = runs[0]
        body = axis_ink[start:end]
        positive = body[body > 0]
        if positive.size < 8:
            fail("墨迹太少")
            return None
        waist = max(2, int(np.percentile(positive, 50) * 0.35))
        lo = start + max(3, int((end - start) * 0.2))
        hi = end - max(3, int((end - start) * 0.2))
        cut_found = False
        if hi > lo:
            cut = lo + int(np.argmin(axis_ink[lo:hi]))
            if int(axis_ink[cut]) <= waist:
                runs = [(start, cut), (cut, end)]
                cut_found = True
        if not cut_found:
            fail(
                f"单段墨迹且无细腰（区间最低墨迹量未降到行中位数的 35% 以下，"
                f"waist阈值={waist}）"
            )
            return None
    # 剔除碎噪点段（既不够长也没有像样的墨迹）：不参与结构判定、不成框
    kept_runs = [
        (s, e) for s, e in runs
        if (e - s) >= 4 or int(axis_ink[s:e].sum()) >= 6
    ]
    if len(kept_runs) != len(runs):
        _log(
            f"[diag:punct-split] rect={rect} 剔除碎噪点段 "
            f"{len(runs)} -> {len(kept_runs)}"
        )
    runs = kept_runs
    if len(runs) < 2 or len(runs) > 3:
        fail(f"墨迹段数 {len(runs)} 不在 2..3（主字段+至多两段标点）")
        return None

    ink_amounts = [int(axis_ink[s:e].sum()) for s, e in runs]
    dominant = int(np.argmax(ink_amounts))
    dom_len = runs[dominant][1] - runs[dominant][0]
    if not (_PUNCT_SPLIT_MAIN_LO * median_span <= dom_len
            <= _PUNCT_SPLIT_MAIN_HI * median_span):
        fail(
            f"主墨迹段高 {dom_len} 不像正常字"
            f"（{_PUNCT_SPLIT_MAIN_LO}~{_PUNCT_SPLIT_MAIN_HI} × ref {median_span:.0f}）"
        )
        return None

    # 紧挨的非主段合并成一块：；：等标点本身由分离的墨迹组成（上圆点
    # + 下钩），拆分时若各成一框，一个分号就变成两个框（实测）。相邻
    # 非主段间距 ≤ 主字段高的 0.2 倍视为同一标点的组成部分；主字段
    # （字本身）永远独立成框。
    # 横画类字（一/乙/二…）墨迹矮但横向占满整列宽——只看轴向高度会
    # 被当成标点段、与紧挨的真标点合并成一个大框（实测『一』+ 标点）。
    # 判别信号用横向墨迹宽度：宽度 ≥ 主字段墨迹宽度的 65% 视为字，
    # 独立成组、不参与标点合并。
    dom_width = _run_ink_width(roi, runs[dominant][0], runs[dominant][1], vertical)
    char_like_width = dom_width * 0.65

    def run_is_char_like(idx: int) -> bool:
        s, e = runs[idx]
        return _run_ink_width(roi, s, e, vertical) >= char_like_width

    # 恰好两段墨迹、两段都达"字宽"、都只有半字高（<0.7×中位字高）、
    # 合计高度不足 1.5×中位字高：单字上下部件间的横向留白（需=雨+而
    # 类字形，部件在本印本里不相连），不是两个字粘连——拆开会把一个
    # 字切成上下两半、各读成别的字（实测『需』→『重』+『焉』）。真正
    # 的两字粘连至少有一段是整字高（粗『一』+字并框：主段 31≈0.78×
    # 字高，实测），合计 ≈1.5~2×字高（工/作并框 70px），都不会命中。
    glyph_run_cap = _PUNCT_SPLIT_GLYPH_RUN_MAX * median_span
    if (
        len(runs) == 2
        and run_is_char_like(0)
        and run_is_char_like(1)
        and runs[1][1] - runs[0][0] < _PUNCT_SPLIT_GLYPH_SPAN * median_span
        and max(e - s for s, e in runs) < glyph_run_cap
    ):
        fail(
            f"两个宽段都只有半字高（最高 {max(e - s for s, e in runs)} < "
            f"{_PUNCT_SPLIT_GLYPH_RUN_MAX}×ref {median_span:.0f}）且合计 "
            f"{runs[1][1] - runs[0][0]} < {_PUNCT_SPLIT_GLYPH_SPAN}×ref："
            f"单字部件留白（需/雨/而类字形），不是两字粘连"
        )
        return None

    # 宽段窄缝：部件高度不对称时上面的护栏漏放——『會』=人字头 26px+身
    # 45px，身部 0.87×中位超过半字高上限，会被当成"标点段+主字段"拦腰
    # 拆开（实测身部单独读成『日』）。判别信号有两个：①缝宽——字内部
    # 件缝只有几像素（會 4px、需 2px），字与标点/角点的间隔大得多；但
    # 字与紧贴的『一』实测间隔也只有 2~6px，缝宽单独不够，再加②形状
    # ——非主字段须非"实心横带"（一/乙是均匀横墨，會的人字头是上窄下
    # 宽的斜笔）。两者都满足才按单字部件留白不拆。窄标点（。，、）宽
    # 度不足 65% 字宽，不会命中此护栏，照常拆出独立标点框。
    glyph_gap_cap = max(3, int(round(_PUNCT_SPLIT_GLYPH_GAP * median_span)))

    def run_is_glyph_part(idx: int) -> bool:
        return run_is_char_like(idx) and not _run_is_solid_band(
            roi, runs[idx][0], runs[idx][1], vertical
        )

    if (
        len(runs) in (2, 3)
        and all(run_is_char_like(idx) for idx in range(len(runs)))
        and all(
            run_is_glyph_part(idx) for idx in range(len(runs)) if idx != dominant
        )
        and all(
            runs[idx + 1][0] - runs[idx][1] <= glyph_gap_cap
            for idx in range(len(runs) - 1)
        )
        and runs[-1][1] - runs[0][0] <= _PUNCT_SPLIT_GLYPH_SPAN * median_span
    ):
        fail(
            f"宽段窄缝：{len(runs)} 段都达字宽、相邻缝 ≤{glyph_gap_cap}px、"
            f"非主字段非实心横带、合计 {runs[-1][1] - runs[0][0]} ≤ "
            f"{_PUNCT_SPLIT_GLYPH_SPAN}×ref {median_span:.0f} → 单字部件"
            f"留白（會/需类，部件高度不对称），不是字+标点"
        )
        return None

    merge_gap = max(3, int(round(dom_len * 0.2)))
    groups: list[list[int]] = []
    for idx in range(len(runs)):
        if idx == dominant or run_is_char_like(idx):
            groups.append([idx])
            continue
        if (
            groups
            and groups[-1] != [dominant]
            and len(groups[-1]) == 1
            and groups[-1][0] != dominant
            and not run_is_char_like(groups[-1][0])
            and runs[idx][0] - runs[groups[-1][-1]][1] <= merge_gap
        ):
            groups[-1].append(idx)
        else:
            groups.append([idx])
    _log(
        f"[diag:punct-split] rect={rect} runs={len(runs)} 分组={len(groups)} "
        f"merge_gap={merge_gap} groups={groups}"
    )

    pad = max(2, min(image_w, image_h) // 700)
    pieces: list[tuple[int, int, int, int]] = []
    for group in groups:
        s = runs[group[0]][0]
        e = runs[group[-1]][1]
        length = e - s
        if group != [dominant]:
            # 组内每段都须是标点大小（接近主字段高度 → 疑似多字粘连）；
            # 例外：横向占满字宽的段（一/二等横画类字，笔画粗时高度可
            # 超过标点上限，实测『一』墨迹高 23 vs 主字段 31 被误拒）是
            # 字——独立成框，不按粘连拒绝。
            for idx in group:
                run_len = runs[idx][1] - runs[idx][0]
                if run_len > _PUNCT_SPLIT_PUNCT_RATIO * dom_len:
                    if not (
                        run_is_char_like(idx)
                        and run_len <= _PUNCT_SPLIT_MAIN_HI * median_span
                    ):
                        fail(
                            f"第 {idx} 段高 {run_len} 接近主字段 {dom_len}"
                            f"（>{_PUNCT_SPLIT_PUNCT_RATIO}×）→ 疑似多字粘连"
                        )
                        return None
            ink_amount = sum(ink_amounts[idx] for idx in group)
            if length < 4 or ink_amount < 6:
                continue  # 碎噪点：不单独成框，也不留在字框里
        if vertical:
            piece = _tight_piece(
                mask, x1, x2, y1 + s, y1 + e, pad, image_w, image_h,
            )
        else:
            piece = _tight_piece(
                mask, x1 + s, x1 + e, y1, y2, pad, image_w, image_h,
            )
        if piece is None:
            fail(f"分组 {group} 收紧失败")
            return None
        pieces.append(piece)
    if len(pieces) < 2:
        fail("拆后只剩 1 框（小段全是碎噪点）")
        return None
    return pieces




def _split_giant_box_by_runs(
    rect: tuple[int, int, int, int],
    mask: np.ndarray,
    image_w: int,
    image_h: int,
    vertical: bool,
) -> list[tuple[int, int, int, int]] | None:
    """巨框（数倍于本行字高）按墨迹白色空隙逐段拆开。

    Kraken cuts 在竖排拉丁字（边栏网址）、稀疏边注等列上会退化成很少
    几个大格（实测一列 1165px 被切成含 867px 单格），条带收紧把格内
    所有墨迹段吸进同一框，就成了"一框包住整列"。巨框里可能是任意
    多个正常字、小字或拉丁字符，不做主字段/标点段的结构约束——段与
    段之间的纯白区间就是天然分界，逐段成框。"""
    x, y, w, h = (int(v) for v in rect)
    x1, x2 = max(0, x), min(image_w, x + w)
    y1, y2 = max(0, y), min(image_h, y + h)
    if x2 - x1 < 2 or y2 - y1 < 2:
        return None
    roi = mask[y1:y2, x1:x2] > 0
    axis_ink = roi.sum(axis=1 if vertical else 0).astype(np.int32)
    runs = _runs(axis_ink > 0, min_len=1)
    runs = [
        (s, e) for s, e in runs
        if (e - s) >= 4 or int(axis_ink[s:e].sum()) >= 6
    ]
    # 尘点段下限：巨框常盖住大段空白（行框被尘点链拉宽后整块落入 cuts），
    # 空白里的尘点段每行平均只有几像素墨迹（实测一框 25 段里 24 段
    # ≤6.3px/行，唯一真实墨迹段 41.8px/行）。以最强段的平均每行墨迹的
    # 1/4 为门槛（下限 6px），尘点段不再成框——否则一块空白被拆成一串
    # 碎框并全部叠在同一位置（用户实测"禄字叠了 18 层"）。全部段都是
    # 尘点量级（最强段都不及门槛 ⇒ 每行平均 <6px）时整框没有真实墨迹，
    # 不拆、原框保留交给下游墨迹校验兜底。
    if runs:
        run_mean = [int(axis_ink[s:e].sum()) / float(e - s) for s, e in runs]
        dust_floor = max(6, round(max(run_mean) * 0.25))
        kept = [r for r, m in zip(runs, run_mean) if m >= dust_floor]
        if not kept:
            _log(
                f"[diag:punct-split] 巨框未拆 rect={rect} "
                f"原因=墨迹全是尘点量级（最强段 {max(run_mean):.1f}px/行 < "
                f"{dust_floor}）"
            )
            return None
        if len(kept) != len(runs):
            _log(
                f"[diag:punct-split] 巨框尘点段剔除 "
                f"{len(runs)} -> {len(kept)}（dust_floor={dust_floor}）"
            )
            runs = kept
    if len(runs) < 2:
        _log(f"[diag:punct-split] 巨框未拆 rect={rect} 原因=墨迹连成一段（无纯白空隙）")
        return None

    pad = max(2, min(image_w, image_h) // 700)
    pieces: list[tuple[int, int, int, int]] = []
    for s, e in runs:
        if vertical:
            piece = _tight_piece(
                mask, x1, x2, y1 + s, y1 + e, pad, image_w, image_h,
            )
        else:
            piece = _tight_piece(
                mask, x1 + s, x1 + e, y1, y2, pad, image_w, image_h,
            )
        if piece is None:
            return None
        pieces.append(piece)
    _log(f"[diag:punct-split] 巨框拆分 rect={rect} -> {len(pieces)} 段 {pieces}")
    return pieces




def _merge_adjacent_punct_fragments(
    boxes: list[tuple[int, int, int, int]],
    mask: np.ndarray,
    median_span: float,
    image_w: int,
    image_h: int,
    vertical: bool,
) -> tuple[list[tuple[int, int, int, int]], int]:
    """合并紧挨的标点小框（返回新列表与合并组数）。

    ；：等标点本身由分离墨迹组成（上圆点+下钩），cuts/连通域/拆分路径
    都可能把一个标点拆成上下两框（实测分号被拆两框）。判定：两个框
    都远小于本行中位字高（≤0.62×，即都是标点大小），且沿阅读轴的
    间距 ≤ 中位字高的 15%（同一标点内部的部件间距；两个独立标点
    （。，）的间距远大于此），合并后仍不超过一个字高——满足即合并
    为一个贴墨迹的框。

    宽度规则：一宽一窄（『一』+紧挨标点）保持分离——宽的是横画类
    字、窄的是标点，并起来就成了"字+标点"同框。两框**都**占满字宽
    且都只有半字高（≤0.7×中位）时是单字上下部件被切开（实测『需』=
    雨+而，Kraken cuts 把部件各切一格、读成两个字，两框 18/21px 高、
    31px 宽全宽）——同样并入一个字框；两个独立的整字（一一、二字被
    切开的两横）不会同时满足"都只有半字高"与"间距 ≤15% 中位字高"。"""
    if len(boxes) < 2:
        return boxes, 0
    punct_cap = _PUNCT_SPLIT_PUNCT_RATIO * median_span
    merge_gap = max(3, int(round(median_span * 0.15)))
    max_merged = 1.1 * median_span
    char_like_width = 0.65 * median_span
    glyph_half_cap = _PUNCT_SPLIT_GLYPH_RUN_MAX * median_span
    glyph_span_cap = _PUNCT_SPLIT_GLYPH_SPAN * median_span
    # 部件碎块判据（宽+窄）：宽段自身是"有分量的部件"（介于 0.45~0.75
    # ×中位字高——整字高的宽段必是字、不足 0.45 的是『一』类细笔画）
    # 且非实心横带，窄段是碎尾（≤0.35×中位）。本书字距最小实测 3~4px
    # （將/實/際 几乎相贴），与部件缝同量级，缝宽判据失效；"宽段不足
    # 整字高"把整字+标点挡在外面（标点框绘制不受影响）。
    glyph_frag_lo = 0.45 * median_span
    glyph_frag_cap = 0.75 * median_span
    glyph_tail_cap = 0.35 * median_span
    # 宽段窄缝并回的补充门槛：最短段须有明显部件高度（≥0.35×中位，矮
    # 于此的多是『一』类横画字/碎笔画），且不是实心横带（一/乙类均匀横
    # 墨——字+紧贴『一』实测间隔仅 2~6px，不能按部件缝并回）。
    glyph_part_min_h = 0.35 * median_span

    def box_is_solid_band(b: tuple[int, int, int, int]) -> bool:
        bx1, by1 = max(0, int(b[0])), max(0, int(b[1]))
        bx2 = min(mask.shape[1], int(b[0]) + int(b[2]))
        by2 = min(mask.shape[0], int(b[1]) + int(b[3]))
        if bx2 <= bx1 or by2 <= by1:
            return False
        sub = mask[by1:by2, bx1:bx2] > 0
        axis_len = sub.shape[0] if vertical else sub.shape[1]
        return _run_is_solid_band(sub, 0, axis_len, vertical)

    def span(b: tuple[int, int, int, int]) -> int:
        return b[3] if vertical else b[2]

    def cross_extent(b: tuple[int, int, int, int]) -> int:
        return b[2] if vertical else b[3]

    def axis_range(b: tuple[int, int, int, int]) -> tuple[int, int]:
        return (b[1], b[1] + b[3]) if vertical else (b[0], b[0] + b[2])

    pad = max(2, min(image_w, image_h) // 700)
    merged_count = 0
    changed = True
    while changed:
        changed = False
        for i in range(len(boxes) - 1):
            a, b = boxes[i], boxes[i + 1]
            a_wide = cross_extent(a) >= char_like_width
            b_wide = cross_extent(b) >= char_like_width
            a1, a2 = axis_range(a)
            b1, b2 = axis_range(b)
            gap = (a1 - b2) if a1 > b2 else (b1 - a2)
            lo, hi = min(a1, b1), max(a2, b2)
            shorter = a if span(a) <= span(b) else b
            glyph_part_glue = (
                a_wide and b_wide
                and gap <= merge_gap
                and hi - lo <= glyph_span_cap
                and span(shorter) >= glyph_part_min_h
                and not box_is_solid_band(shorter)
            )
            if a_wide and b_wide:
                # 都占满字宽：只有"都只有半字高"才是单字上下部件（需=
                # 雨+而）；任一达到整字高是两个独立的宽字（一/二横画类），
                # 保持分离。例外（宽段窄缝）：會=人字头+身这类高度不对称
                # 的部件被切开时（身部近整字高，超半字高上限），缝窄、
                # 合计 ≤1.5 字高、最短段非实心横带 → 仍按单字部件并回。
                if (span(a) > glyph_half_cap or span(b) > glyph_half_cap) and not (
                    glyph_part_glue
                ):
                    continue
            else:
                if span(a) > punct_cap or span(b) > punct_cap:
                    continue
                # 一宽一窄默认保持分离：宽的是横画类字（一，）。例外
                # （部件碎块）：宽段是有分量的部件（0.45~0.75×中位——
                # 整字高的宽段必是字、不足 0.45 的是『一』类细笔画）且
                # 非实心横带、窄段是碎尾时，是单字被切开的上下部件
                # （实测『數』=上部 29px+攵脚 11px、缝 2px），併回一
                # 个字框。合计上限仍走下方 1.1×中位，整字+标点（约
                # 1.2~1.4×中位）不会命中。
                if a_wide or b_wide:
                    wide_one = a if a_wide else b
                    narrow_one = b if a_wide else a
                    if not (
                        glyph_frag_lo <= span(wide_one) <= glyph_frag_cap
                        and span(narrow_one) <= glyph_tail_cap
                        and not box_is_solid_band(wide_one)
                    ):
                        continue
            if gap > merge_gap:
                continue
            # 宽段窄缝并回的部件合计可达 1.5 字高（會 70px vs 1.1×中位
            # 52.8px），glyph_part_glue 分支放宽合计上限；其余路径维持。
            if hi - lo > max_merged and not glyph_part_glue:
                continue
            if vertical:
                cx1 = min(a[0], b[0])
                cx2 = max(a[0] + a[2], b[0] + b[2])
                merged = _tight_piece(mask, cx1, cx2, lo, hi, pad, image_w, image_h)
            else:
                cy1 = min(a[1], b[1])
                cy2 = max(a[1] + a[3], b[1] + b[3])
                merged = _tight_piece(mask, lo, hi, cy1, cy2, pad, image_w, image_h)
            if merged is None:
                continue
            _log(f"[diag:punct-merge] {a} + {b} -> {merged} (gap={gap})")
            boxes = boxes[:i] + [merged] + boxes[i + 2:]
            merged_count += 1
            changed = True
            break
    return boxes, merged_count




def split_punct_merged_boxes(
    boxes: list[tuple[int, int, int, int]],
    mask: np.ndarray | None,
    image_w: int,
    image_h: int,
    orientation: str = "vertical",
    axis_desc: bool = False,
) -> tuple[list[tuple[int, int, int, int]], list[dict[str, Any]]]:
    """按本行中位字高找出"字+标点"同框的超高字框并按墨迹拆开。

    对每个沿阅读轴显著高于本行中位字高的字框，回看框内墨迹分布：
    达到 2.5 倍的是巨框（cuts 退化/并格，一框包住整列——按白色空隙
    逐段拆开，不受结构约束）；其余用 _split_tall_box_by_ink_runs 判定
    "主墨迹段+标点段"结构后拆分。正常高度的框一概不动；行内字框
    不足 3 个时中位数不稳，也不处理。

    多轮拆分（至多 _PUNCT_SPLIT_MAX_PASSES 轮，无新拆分即停）：一行
    里同框框偏多时中位基线会被它们抬高，1.18 倍的判定可能漏掉边缘
    案；拆掉最高的几个框后基线回落到真实字高，下一轮把漏网者捞出。
    上一轮拆出的字框在下一轮即便被复查，也会因框内只有一个字形而无
    法再拆，不会越拆越碎。

    axis_desc：阅读轴为降序（横排 rtl）时拆出的框按降序插入，保持与
    传入 boxes 相同的阅读顺序。返回 (新列表, 拆分事件)；事件含
    old/new 框与当轮中位字高，供日志与测试断言。
    """
    if mask is None or mask.ndim != 2 or len(boxes) < 3:
        return boxes, []
    vertical = orientation != "horizontal"
    # Keep the cross-axis bounds of the original cuts list.  Pieces produced
    # by a giant-box split may extend 1--2 px beyond that range because the
    # ink-tightener deliberately adds a safety pad; that is exactly where a
    # page ruling line appears.
    line_cross_bounds = (
        (min(b[0] for b in boxes), max(b[0] + b[2] for b in boxes))
        if vertical
        else (min(b[1] for b in boxes), max(b[1] + b[3] for b in boxes))
    )

    current = list(boxes)
    events: list[dict[str, Any]] = []
    for pass_no in range(_PUNCT_SPLIT_MAX_PASSES):
        spans = [b[3] if vertical else b[2] for b in current]
        median_span = float(np.median(spans))
        if median_span < 12:
            break
        out: list[tuple[int, int, int, int]] = []
        pass_events: list[dict[str, Any]] = []
        for rect in current:
            span = rect[3] if vertical else rect[2]
            if (span <= median_span * _PUNCT_SPLIT_TALL_RATIO
                    or span - median_span < _PUNCT_SPLIT_MIN_MARGIN):
                out.append(rect)
                continue
            if span >= median_span * _PUNCT_SPLIT_GIANT_RATIO:
                # 数倍于本行字高的巨框（cuts 退化/并格）：按白色空隙逐段
                # 拆开，不受"主字段+标点段"结构约束（巨框里可能是任意
                # 多个正常字、小字或拉丁字符）。
                pieces = _split_giant_box_by_runs(
                    rect, mask, image_w, image_h, vertical,
                )
            else:
                pieces = _split_tall_box_by_ink_runs(
                    rect, mask, median_span, image_w, image_h, vertical,
                )
            if pieces is None:
                out.append(rect)
                continue
            if axis_desc:
                pieces = list(reversed(pieces))
            filtered = [
                piece for piece in pieces
                if not _is_edge_ruling_fragment(
                    piece, mask, line_cross_bounds, orientation,
                )
                and not _is_cross_column_band(
                    piece, mask, line_cross_bounds, orientation,
                    max(4, int(round(0.2 * median_span))),
                )
            ]
            if filtered and len(filtered) != len(pieces):
                _log(
                    f"[diag:punct-split] drop edge ruling/cross-column band "
                    f"fragments rect={rect} dropped={len(pieces) - len(filtered)}"
                )
                pieces = filtered
            out.extend(pieces)
            pass_events.append({
                "old": rect,
                "new": list(pieces),
                "median_span": median_span,
            })
            _log(
                f"[diag:punct-split] pass={pass_no + 1} rect={rect} "
                f"median_span={median_span:.0f} -> {len(pieces)} boxes {pieces}"
            )
        current = out
        current, merged_count = _merge_adjacent_punct_fragments(
            current, mask, median_span, image_w, image_h, vertical,
        )
        if merged_count:
            _log(
                f"[diag:punct-merge] pass={pass_no + 1} 合并 "
                f"{merged_count} 组紧挨标点小框"
            )
        events.extend(pass_events)
        if not pass_events and merged_count == 0:
            break
    return current, events
