# -*- coding: utf-8 -*-
"""单字切分（从 segmenter 拆出）：区域内切字、等分/版面格/纵投影三路、
kraken 字切分器。segmenter.py 仍为门面。"""
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
from seg_trace import _log, _exception_summary
from seg_imaging import (_to_block, _runs, _merge_close_runs, _tight_rect, _text_mask_for_refinement, _is_cross_column_band)
from seg_refine import split_punct_merged_boxes





def _split_chars_in_region(
    mask: np.ndarray | None,
    region: tuple[int, int, int, int],
    image_w: int,
    image_h: int,
    expected_count: int = 0,
    diag: dict[str, Any] | None = None,
) -> list[tuple[int, int, int, int]]:
    """在检出的竖排区域框内切单字。

    采用连通域聚类 + 粘连兜底的策略，比纯投影更鲁棒：

    1. 在 region 内做水平膨胀，把同一字内分散笔画合并成块
    2. connectedComponentsWithStats 找空间连通块
    3. 按面积/形状过滤：太小的当噪声丢，太大的判定为多字粘连
    4. 对粘连块回退到 Y 轴投影细切

    region 是 (x, y, w, h)；mask 是全图去栏线后的二值化 mask。
    expected_count > 0 时作为交叉验证：若连通域结果数量不匹配，回退到等分。
    diag 非空时回填切分诊断（method/components/dropped，供切字过程可视化）。
    """
    def _note(method: str, **extra: Any) -> None:
        if diag is not None:
            diag["method"] = method
            diag["expected_count"] = expected_count
            diag.update(extra)

    if mask is None:
        _log(f"[diag:split] mask unavailable region={region} expected={expected_count}")
        _note("equal-division(mask-unavailable)")
        if expected_count > 1:
            return _split_by_equal_division(mask, region, expected_count, image_w, image_h)
        return [region]

    x, y, w, h = region
    if w > h:
        roi = mask[max(0, y):min(image_h, y + h), max(0, x):min(image_w, x + w)]
        local_rects = _split_chars_in_region(
            roi.T,
            (0, 0, h, w),
            h,
            w,
            expected_count=expected_count,
            diag=diag,
        )
        return [(x + ry, y + rx, rh, rw) for rx, ry, rw, rh in local_rects]

    pad = max(2, min(image_w, image_h) // 500)
    x1 = max(0, x - pad)
    y1 = max(0, y - pad)
    x2 = min(image_w, x + w + pad)
    y2 = min(image_h, y + h + pad)

    roi = mask[y1:y2, x1:x2]
    if roi.size == 0:
        _log(f"[diag:split] empty roi region={region} clamped=({x1},{y1},{x2},{y2}) expected={expected_count}")
        _note("equal-division(empty-roi)")
        if expected_count > 1:
            return _split_by_equal_division(mask, region, expected_count, image_w, image_h)
        return [region]

    region_w = x2 - x1
    region_h = y2 - y1
    ink_pixels = int(np.count_nonzero(roi))

    if ink_pixels == 0:
        _log(f"[diag:split] no ink region={region} roi={region_w}x{region_h} expected={expected_count}")
        _note("equal-division(no-ink)")
        if expected_count > 1:
            return _split_by_equal_division(mask, region, expected_count, image_w, image_h)
        return [region]

    # 估算单字尺寸：取区域宽度作为字宽参考，单字高度近似字宽（古籍方块字）
    char_size = max(12, region_w)

    # 水平膨胀：同字笔画在 X 方向是连通的，在 Y 方向是分离的。
    # 水平 kernel 让同字笔画聚成块，但不合并上下相邻的字。
    dilate_w = max(3, char_size // 3)
    _log(
        f"[diag:split] start region=({x},{y},{w},{h}) clamp=({x1},{y1},{x2},{y2}) "
        f"roi={region_w}x{region_h} ink={ink_pixels} expected={expected_count} "
        f"char_size={char_size} dilate_w={dilate_w}"
    )
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (dilate_w, 1))
    dilated = cv2.dilate(roi, kernel, iterations=1)

    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(dilated, connectivity=8)

    # 面积参考：单字面积的 5% 下限（过滤碎片），300% 上限（超过判粘连）
    min_area = max(12, (char_size * char_size) // 40)
    stuck_area_threshold = (char_size * char_size) * 3

    components: list[tuple[int, int, int, int, int]] = []  # (cx, cy, cw, ch, area)
    dropped_specks: list[tuple[int, int, int, int]] = []
    band_cap = max(4, char_size // 5)
    for label_idx in range(1, num_labels):
        area = int(stats[label_idx, cv2.CC_STAT_AREA])
        cx = int(stats[label_idx, cv2.CC_STAT_LEFT])
        cy = int(stats[label_idx, cv2.CC_STAT_TOP])
        cw = int(stats[label_idx, cv2.CC_STAT_WIDTH])
        ch = int(stats[label_idx, cv2.CC_STAT_HEIGHT])
        if area < min_area:
            dropped_specks.append((x1 + cx, y1 + cy, cw, ch))
            continue
        # 残缺版框横线/页缘黑带（横贯整列、越出列界进纸白缝）：不是字
        # 也不是标点，按噪声丢弃——否则以独立组件身份混成"一个点"伪
        # 字框，还会多计一个字把期望校验顶翻、整行弃用组件框。
        band_rect = (x1 + cx, y1 + cy, cw, ch)
        if _is_cross_column_band(band_rect, mask, (x, x + w), "vertical", band_cap):
            dropped_specks.append(band_rect)
            _log(
                f"[diag:split] drop cross-column band rect={band_rect} "
                f"char_size={char_size}"
            )
            continue
        components.append((cx, cy, cw, ch, area))

    _log(
        f"[diag:split] components raw_labels={num_labels - 1} kept={len(components)} "
        f"min_area={min_area} stuck_area={stuck_area_threshold}"
    )

    if not components:
        _log(f"[diag:split] no components after filter region={region} expected={expected_count}")
        _note("equal-division(no-components)", dropped=dropped_specks)
        if expected_count > 1:
            return _split_by_equal_division(mask, region, expected_count, image_w, image_h)
        return [region]

    # 先把碎片按 Y 坐标排序，合并过短且垂直相邻的碎片到一个字。
    # 碎片判定：高度 < 半个单字高度。相邻判定：Y 间隔 < 半个单字高度。
    components.sort(key=lambda c: c[1])
    min_meaningful_h = max(6, char_size // 2)
    fragment_gap = max(3, char_size // 2)

    merged: list[list[tuple[int, int, int, int, int]]] = []
    for comp in components:
        if merged:
            last_group = merged[-1]
            last = last_group[-1]
            last_bottom = last[1] + last[3]
            is_short = last[3] < min_meaningful_h or comp[3] < min_meaningful_h
            close_enough = comp[1] - last_bottom < fragment_gap
            # 并入后组的高度仍在一个字高内才并：短小组件贴着上方/下方
            # 整字时是标点（。，、）而非本字部件（部件合起来也在一个
            # 字高内），并入就成了"字+标点"同框、整行出现超高字框。
            union_top = min(last_group[0][1], comp[1])
            union_bottom = max(last_bottom, comp[1] + comp[3])
            fits_one_char = union_bottom - union_top <= char_size * 1.1
            if is_short and close_enough and fits_one_char:
                last_group.append(comp)
                continue
        merged.append([comp])

    final_components: list[tuple[int, int, int, int, int]] = []
    for group in merged:
        if len(group) == 1:
            final_components.append(group[0])
        else:
            gx1 = min(c[0] for c in group)
            gy1 = min(c[1] for c in group)
            gx2 = max(c[0] + c[2] for c in group)
            gy2 = max(c[1] + c[3] for c in group)
            garea = sum(c[4] for c in group)
            final_components.append((gx1, gy1, gx2 - gx1, gy2 - gy1, garea))
    _log(
        f"[diag:split] grouped fragments groups={len(merged)} final_components={len(final_components)} "
        f"fragment_gap={fragment_gap} min_meaningful_h={min_meaningful_h}"
    )

    char_rects: list[tuple[int, int, int, int]] = []
    stuck_fallback_count = 0
    # 粘连块的期望字数按块高/单字高局部估计，不透传整行剩余期望：
    # 103px 的粘连块配上"剩余 34 字"的整行期望时，投影数量(2)与期望(34)
    # 不符会在块内等分出 34 个微格，污染整行切分（组件数暴涨 → 整行
    # 网格兜底 → 字框相对读法整体错一格）。单字高优先取本行非粘连
    # 组件高度的中位数（真实字形高度），无参考时退回 char_size。
    # 高度下限：几像素高的残条（宽而扁、靠宽度过了面积门）不是字——
    # 实测栏线带行里唯一非粘连组件是 4px 残条，中位数被拉到 4 后粘连
    # 块期望爆到 140/格长 4px，整行切出 538 个微框。
    sane_heights = [
        c[3] for c in final_components
        if c[4] <= stuck_area_threshold
        and max(10, char_size // 3) <= c[3] <= char_size * 1.6
    ]
    unit_h = float(np.median(sane_heights)) if sane_heights else float(char_size)
    for cx_rel, cy_rel, cw, ch, area in final_components:
        abs_x = x1 + cx_rel
        abs_y = y1 + cy_rel

        if area > stuck_area_threshold or ch > char_size * 1.6:
            stuck_fallback_count += 1
            sub_region = (abs_x, abs_y, cw, ch)
            local_expected = max(1, int(round(ch / unit_h)))
            _log(
                f"[diag:split] stuck component rect=({abs_x},{abs_y},{cw},{ch}) "
                f"area={area} char_size={char_size} local_expected={local_expected}, "
                f"use y-projection"
            )
            sub_chars = _split_chars_by_y_projection(
                mask, sub_region, image_w, image_h, char_size,
                expected_count=local_expected,
            )
            char_rects.extend(sub_chars)
            continue

        tight = _tight_rect(mask, abs_x, abs_x + cw, abs_y, abs_y + ch, pad, image_w, image_h)
        if tight is not None:
            char_rects.append(tight)

    char_rects.sort(key=lambda r: r[1])

    component_rects = [
        (x1 + c[0], y1 + c[1], c[2], c[3]) for c in final_components
    ]

    # 期望字数已知且连通域结果数量不匹配 → 先做良性差额检查（通过则
    # 保留连通域框），否则使用布局网格兜底（网格函数会优先寻找投影谷
    # 值，避免固定等分把相邻字切进同一框）。
    if expected_count > 0 and len(char_rects) != expected_count:
        # 良性差额：框数只多不少、多出的都是标点/部件碎块（高度不足
        # 0.6×字高）、正常字高的框不多于期望字数、且没有粘连块走投影
        # 细切。整行读法常漏读小标点/部件（实测一列 38 组件 vs 读法
        # 35 字，多出的是 ？ 与句读点），此时连通域框的几何仍逐字准确
        # ——数量不齐交给下游序列-框对齐（difflib 容忍插入/删除）处理，
        # 远好于整体弃用改用 cuts 条带框（格界与字形错位、整字被切碎）。
        # 反之：正常字高框多于期望（读法漏了整字且无从定位）、差额过
        # 大、或发生过粘连细切（可能有并字）时仍走网格兜底。
        normal_sized = sum(1 for r in char_rects if r[3] > 0.6 * char_size)
        if (
            stuck_fallback_count == 0
            and len(char_rects) > expected_count
            and len(char_rects) - expected_count <= 4
            and normal_sized <= expected_count
        ):
            _log(
                f"[diag:split] benign count delta: got={len(char_rects)} "
                f"expected={expected_count} normal_sized={normal_sized}, "
                f"keep component boxes (extras are mark-sized)"
            )
            _note(
                "components",
                components=component_rects,
                dropped=dropped_specks,
                stuck_fallback=stuck_fallback_count,
                component_count=len(char_rects),
                count_delta_ok=True,
            )
            return char_rects
        # 期望对区域高荒谬（槽高不足下限）：期望本身是坏的（如上一轮
        # 已经切出 537 个微框的行，诊断/重识别带着这个字数进来），等分
        # 只会再造一批微格——保留连通域框。
        slot_floor = max(6, char_size // 8)
        if (y + h) / max(1, expected_count) < slot_floor:
            _log(
                f"[diag:split] expected={expected_count} 对区域高 {h} 荒谬"
                f"（slot < {slot_floor}px），保留连通域框"
                f"（got={len(char_rects)}）"
            )
            _note(
                "components",
                components=component_rects,
                dropped=dropped_specks,
                stuck_fallback=stuck_fallback_count,
                component_count=len(char_rects),
                count_absurd=True,
            )
            return char_rects
        _log(
            f"[diag:split] component count mismatch: got={len(char_rects)} "
            f"expected={expected_count}, fallback to equal division"
        )
        _note(
            "layout-grid(count-mismatch)",
            components=component_rects,
            dropped=dropped_specks,
            stuck_fallback=stuck_fallback_count,
            component_count=len(char_rects),
        )
        return _split_by_layout_grid(mask, region, expected_count, image_w, image_h)

    _log(
        f"[diag:split] region=({x},{y},{w},{h}) "
        f"components={len(components)} chars={len(char_rects)} "
        f"stuck_fallback={stuck_fallback_count}"
    )
    _note(
        "components",
        components=component_rects,
        dropped=dropped_specks,
        stuck_fallback=stuck_fallback_count,
        component_count=len(char_rects),
    )
    return char_rects if char_rects else [region]




def _slot_tight_rect(
    mask: np.ndarray | None,
    x1: int,
    x2: int,
    y1: int,
    y2: int,
    pad: int,
    image_w: int,
    image_h: int,
) -> tuple[int, int, int, int] | None:
    """槽位内收紧到墨迹；碎片槽返回 None，由调用方退回整槽框。

    等分/网格切出的每个槽位本应容纳一个整字；若槽内墨迹只有一小截
    （切线从邻字笔画穿过留下的尾巴），收紧框会缩成"一个点"的伪字框
    ——用户在编辑器里根本看不到、也选不中。整槽框几何与槽位对齐、
    可见可选中，识别对不齐交给下游序列-框对齐消化。
    """
    if mask is None:
        return None
    tight = _tight_rect(mask, x1, x2, y1, y2, pad, image_w, image_h)
    if tight is None:
        return None
    slot_h = y2 - y1
    if slot_h > 8 and tight[3] < 0.3 * slot_h:
        _log(
            f"[diag:slot-guard] discard sliver tight={tight} "
            f"slot=({x1},{y1},{x2 - x1},{slot_h})"
        )
        return None
    return tight


def _split_by_equal_division(
    mask: np.ndarray | None,
    region: tuple[int, int, int, int],
    n: int,
    image_w: int,
    image_h: int,
) -> list[tuple[int, int, int, int]]:
    """沿 Y 轴把 region 等分成 n 段，每段用 _slot_tight_rect 收紧。

    用于 mask 不可用、区域内无墨等拿不到墨迹信息时的兜底：已知一个
    竖排列里有 n 个字，就直接按等高切分；槽内收紧只剩碎片时退回整槽
    （见 _slot_tight_rect），不产出点状伪字框。
    """
    x, y, w, h = region
    if n <= 1:
        return [region]
    pad = max(2, min(image_w, image_h) // 500)
    x1 = max(0, x - pad)
    x2 = min(image_w, x + w + pad)

    char_rects = []
    seg_h = h / n
    for i in range(n):
        seg_y1 = int(round(y + i * seg_h))
        seg_y2 = int(round(y + (i + 1) * seg_h))
        tight = _slot_tight_rect(mask, x1, x2, seg_y1, seg_y2, pad, image_w, image_h)
        if tight is not None:
            char_rects.append(tight)
        else:
            char_rects.append((x, seg_y1, w, max(1, seg_y2 - seg_y1)))

    _log(f"[diag:equal-split] region=({x},{y},{w},{h}) n={n} rects={len(char_rects)}")
    return char_rects




def _split_by_layout_grid(
    mask: np.ndarray | None,
    region: tuple[int, int, int, int],
    n: int,
    image_w: int,
    image_h: int,
) -> list[tuple[int, int, int, int]]:
    if n <= 1:
        return [region]

    x, y, w, h = region
    # 横排行沿 X 轴切分：转置 ROI 后复用竖排的投影谷值算法，再映射回原图。
    if w > h:
        roi = None
        if mask is not None:
            roi = mask[max(0, y):min(image_h, y + h), max(0, x):min(image_w, x + w)]
            roi = roi.T
        local_rects = _split_by_layout_grid(
            roi,
            (0, 0, h, w),
            n,
            h,
            w,
        )
        return [(x + ry, y + rx, rh, rw) for rx, ry, rw, rh in local_rects]

    pad = max(1, min(image_w, image_h) // 700)
    x1 = max(0, x - pad)
    x2 = min(image_w, x + w + pad)

    if mask is not None:
        roi = mask[max(0, y):min(image_h, y + h), x1:x2]
        points = cv2.findNonZero(roi) if roi.size else None
        if points is not None:
            rx, ry, rw, rh = cv2.boundingRect(points)
            x1 = max(0, x1 + rx - pad)
            x2 = min(image_w, x1 + rw + pad * 2)
            # 按墨迹实际范围切分，避免行框上下留白造成整体偏移。
            y = max(0, y + ry - pad)
            h = min(image_h - y, rh + pad * 2)

    slot_h = h / n
    boundaries = [y]
    if mask is not None and h > n:
        roi = mask[max(0, y):min(image_h, y + h), x1:x2]
        projection = np.sum(roi > 0, axis=1).astype(np.float32)
        if len(projection) > 2:
            smooth = cv2.GaussianBlur(
                projection.reshape(-1, 1), (1, 0), sigmaX=1.2
            ).reshape(-1)
            for i in range(1, n):
                target = int(round(i * slot_h))
                radius = max(2, int(round(slot_h * 0.32)))
                lo = max(1, target - radius)
                hi = min(len(smooth) - 2, target + radius)
                cut = target
                if hi >= lo:
                    # 优先在"纯白区间"（整行几乎无墨的连续段）中心下刀：
                    # 白色区间的高度是字距的直接量度，字与字之间总有纯
                    # 白空隙；而墨迹残缺/笔画稀疏时投影谷值可能落在字内
                    # 留白上，把一个字拦腰切开。找不到纯白段再退回投影
                    # 谷值。
                    window = projection[lo:hi + 1]
                    best_start, best_len = 0, 0
                    run_start, run_len = None, 0
                    for k, is_white in enumerate(window <= 2.0):
                        if is_white:
                            if run_start is None:
                                run_start = k
                            run_len += 1
                        else:
                            if run_len > best_len:
                                best_start, best_len = run_start, run_len
                            run_start, run_len = None, 0
                    if run_len > best_len:
                        best_start, best_len = run_start, run_len
                    if best_len >= 2:
                        cut = lo + best_start + best_len // 2
                    else:
                        local = smooth[lo:hi + 1]
                        if local.size:
                            cut = lo + int(np.argmin(local))
                # 保证每个槽位有足够高度，必要时退回目标等分点。
                previous = boundaries[-1] - y
                if cut - previous < max(2, int(slot_h * 0.35)):
                    cut = target
                boundaries.append(y + cut)
    while len(boundaries) < n:
        boundaries.append(int(round(y + len(boundaries) * slot_h)))
    boundaries.append(y + h)

    rects: list[tuple[int, int, int, int]] = []
    for i in range(n):
        gy1 = max(0, int(boundaries[i]))
        gy2 = min(image_h, max(gy1 + 1, int(boundaries[i + 1])))
        tight = _slot_tight_rect(mask, x1, x2, gy1, gy2, pad, image_w, image_h)
        rects.append(tight or (x1, gy1, max(1, x2 - x1), max(1, gy2 - gy1)))

    _log(
        f"[diag:grid-split] region={region} n={n} rects={len(rects)} slot_h={slot_h:.2f} "
        f"guided_boundaries={len(boundaries)}"
    )
    return rects




def make_kraken_char_splitter(
    image_path: str,
    orientation: str = "vertical",
    horizontal_dir: str = "ltr",
):
    """Kraken 模式字框与投影切分统一的像素切分器。

    返回闭包 (rect, n) -> 字框列表（原图坐标、阅读序，个数=n 或略多），
    供 kraken_bridge 把 worker 的 cuts 条带框换成与投影切分同源的
    连通域紧致框。mask 整页只算一次；expected_count=n 校验框数与识别
    字数：数量不符且非良性差额（多出的框须为标点/部件碎块尺寸，见
    _split_chars_in_region）时内部退化为投影谷值网格并返回 None。
    良性差额时返回多于 n 的连通域框，数量不齐由下游序列-框对齐消化。
    mask 不可用或切分异常时返回 None，调用方回退 worker 的条带框。

    n=0 表示期望字数未知（横排行没有整行序列读法可对齐）：走纯连通域
    路径按墨迹出框，不做数量校验。

    切分结果沿阅读轴升序（竖排上→下、横排左→右）；横排 rtl 时按
    阅读序反转。
    """
    mask: np.ndarray | None = None
    mask_ready = False
    diag: dict[str, Any] = {}

    def splitter(rect: dict, n: int) -> list[tuple[int, int, int, int]] | None:
        nonlocal mask, mask_ready
        if n < 0:
            return None
        try:
            if not mask_ready:
                mask = _text_mask_for_refinement(image_path)
                mask_ready = True
            if mask is None:
                _log(f"[diag:kraken-split] mask unavailable image={image_path}")
                return None
            image_h, image_w = mask.shape[:2]
            rects = _split_chars_in_region(
                mask,
                (int(rect["x"]), int(rect["y"]), int(rect["w"]), int(rect["h"])),
                image_w,
                image_h,
                expected_count=n,
                diag=diag,
            )
        except Exception as exc:
            _log(
                f"[diag:kraken-split] split failed rect={rect} n={n}: "
                f"{_exception_summary(exc)}"
            )
            return None
        method = str(diag.get("method") or "")
        if n > 0 and len(rects) != n:
            # 连通域路径的良性差额（多出的框是标点/部件碎块，见
            # _split_chars_in_region）可以接受：字框几何来自真实墨迹，
            # 数量不齐由下游序列-框对齐消化。网格/等分兜底的合成槽位
            # 框数量恒等于 n，走到这里说明不是良性差额，照旧拒绝。
            if method != "components":
                _log(f"[diag:kraken-split] count mismatch rect={rect} n={n} got={len(rects)}")
                return None
            _log(
                f"[diag:kraken-split] benign count delta accepted "
                f"rect={rect} n={n} got={len(rects)} (components, extras mark-sized)"
            )
        if not rects:
            return None
        if orientation == "horizontal" and horizontal_dir == "rtl":
            rects = list(reversed(rects))
        # 记录本次切分方式供调用方判断可信度：连通域路径(components)的
        # 字框几何与数量来自真实墨迹；网格/等分兜底的框是合成槽位，与
        # 实际字形可能整体错位，调用方应改用 Kraken cuts 重建。
        splitter.last_method = method
        return [(int(x), int(y), int(w), int(h)) for x, y, w, h in rects]

    splitter.last_method = ""  # type: ignore[attr-defined]
    return splitter




def _split_chars_by_y_projection(
    mask: np.ndarray,
    region: tuple[int, int, int, int],
    image_w: int,
    image_h: int,
    char_size: int,
    expected_count: int = 0,
) -> list[tuple[int, int, int, int]]:
    """对连通域判定的多字粘连块，回退到 Y 轴投影细切。

    region 是粘连块的全图绝对坐标 (x, y, w, h)。char_size 是预估单字高度。
    expected_count 是期望的字数；若 > 0 且投影切出的数量不对，则回退到
    版面网格（白隙/投影谷引导切线）。粘连块常因笔画交叠把投影 runs 合并
    成一段，此时盲等分会在字距不匀时把切线落进字间空隙，槽内只剩邻字
    笔画的尾巴，收紧成"一个点"的伪字框。
    """
    x, y, w, h = region
    pad = max(2, min(image_w, image_h) // 500)
    x1 = max(0, x - pad)
    y1 = max(0, y - pad)
    x2 = min(image_w, x + w + pad)
    y2 = min(image_h, y + h + pad)

    roi = mask[y1:y2, x1:x2]
    if roi.size == 0:
        if expected_count > 1:
            return _split_by_equal_division(mask, region, expected_count, image_w, image_h)
        return [region]

    y_proj = np.sum(roi > 0, axis=1)
    if np.count_nonzero(y_proj) == 0:
        if expected_count > 1:
            return _split_by_equal_division(mask, region, expected_count, image_w, image_h)
        return [region]

    min_char_h = max(8, char_size // 2)
    max_gap = max(3, char_size // 3)

    runs = _runs(y_proj > 0, min_len=min_char_h)
    runs = _merge_close_runs(runs, max_gap=max_gap)

    if not runs:
        if expected_count > 1:
            return _split_by_equal_division(mask, region, expected_count, image_w, image_h)
        return [region]

    char_rects = []
    for start, end in runs:
        rect = _tight_rect(mask, x1, x2, y1 + start, y1 + end, pad, image_w, image_h)
        if rect is not None:
            char_rects.append(rect)

    if not char_rects:
        if expected_count > 1:
            return _split_by_equal_division(mask, region, expected_count, image_w, image_h)
        return [region]

    # 期望字数已知且投影结果数量不匹配 → 版面网格兜底（白隙/投影谷引导
    # 切线，槽内碎片退回整槽，见 _slot_tight_rect）
    if expected_count > 0 and len(char_rects) != expected_count:
        # 投影只有一段且段内行墨量近乎均匀（无浅谷）：实心带——栏线/
        # 版框残带被检测成"文字列"的形态（实测三条填充带投影各得 1 段，
        # 行墨量全程恒定）。里面没有 N 个字，按一个结构元素出框；按期望
        # 网格细切只会造出成百个 4px 微框。段内有浅谷（字距留白被
        # merge_close_runs 并段的真·多字粘连）照旧走网格兜底恢复。
        if len(char_rects) == 1 and runs:
            s, e = runs[0]
            seg = y_proj[s:e]
            med = float(np.median(seg))
            if med > 0 and float(np.min(seg)) > med * 0.65:
                _log(
                    f"[diag:split] solid band rect={region} 行墨量均匀"
                    f"（min/median={float(np.min(seg)):.0f}/{med:.0f}）"
                    f"-> 单框，不按期望 {expected_count} 细切"
                )
                return char_rects
        _log(
            f"[diag:split] projection mismatch: got={len(char_rects)} "
            f"expected={expected_count}, fallback to layout grid"
        )
        return _split_by_layout_grid(mask, region, expected_count, image_w, image_h)

    return char_rects
