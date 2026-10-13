# -*- coding: utf-8 -*-
"""Kraken 框几何与配对（从 kraken_bridge 拆出）：字框拆分/收紧/噪声过滤、
序列-框配对、读法方向补边、行框含墨与钳回。kraken_bridge.py 仍为门面。"""
from __future__ import annotations
import json
import os
import queue
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path
import numpy as np
from kraken_proc import log





def _split_boxes_or_none(char_splitter, rect: dict, n: int, ctx: str):
    """调切分器并兜住异常，失败返回 None（调用方回退 cuts 条带框）。

    n=0 表示期望字数未知（横排行无整行序列读法），切分器走纯连通域
    路径、不做数量校验。"""
    if char_splitter is None or n < 0:
        return None
    try:
        return char_splitter(rect, n)
    except Exception as exc:
        log(f"char split failed on {ctx}: {exc}")
        return None




def _split_punct_merged_line_boxes(
    image_path: str,
    per_line_boxes: list[list[tuple[int, int, int, int]]],
    orientation: str,
    horizontal_dir: str,
) -> list[bool]:
    """逐行做"字+标点"同框的后检拆分（segmenter.split_punct_merged_boxes
    的批量包装），就地替换发生拆分的行的字框。

    返回每行是否发生拆分。mask 不可用/切分异常时该行保持原框，行为
    与引入本函数前一致。"""
    try:
        from segmenter import _text_mask_for_refinement, split_punct_merged_boxes

        mask = _text_mask_for_refinement(image_path)
    except Exception as exc:
        log(f"[punct-split] mask unavailable ({exc})，跳过标点拆分")
        mask = None
    if mask is None:
        return [False] * len(per_line_boxes)
    mask_h, mask_w = mask.shape[:2]
    axis_desc = orientation == "horizontal" and horizontal_dir == "rtl"
    split_flags: list[bool] = []
    for idx, boxes in enumerate(per_line_boxes):
        if not boxes:
            split_flags.append(False)
            continue
        try:
            new_boxes, events = split_punct_merged_boxes(
                boxes, mask, mask_w, mask_h, orientation, axis_desc=axis_desc,
            )
        except Exception as exc:
            log(f"[punct-split] line#{idx} failed: {exc}")
            new_boxes, events = boxes, []
        if events:
            per_line_boxes[idx] = new_boxes
            for ev in events:
                log(
                    f"[punct-split] line#{idx} rect={ev['old']} "
                    f"median_span={ev['median_span']:.0f} -> {ev['new']}"
                )
        split_flags.append(bool(events))
    return split_flags




def _split_trusted(char_splitter) -> bool:
    """像素切分是否走了可信的连通域路径。

    网格/等分兜底产出的框是合成槽位（期望字数本身可能漏了标点），
    与真实字形可整体错位——正文/候选再按位互挂就会"候选=邻字"。
    无 last_method 属性的切分器（测试桩等）默认可信，行为不变。
    """
    return getattr(char_splitter, "last_method", "components") == "components"




def _tighten_boxes_to_ink(
    image_path: str,
    boxes: list[tuple[int, int, int, int]],
    orientation: str = "vertical",
) -> list[tuple[int, int, int, int]]:
    """kraken-cuts 条带框收紧为贴字框（导出训练数据用）。

    cuts 只含字符沿阅读轴的分界，条带框宽度恒为行宽，小字（句号、
    小注）两侧留白很大，拿这种框当检测模型的训练标注会把框教松。
    收紧以"墨迹整段"为单位：先沿阅读轴把行内墨迹切成连续 run，再把
    每个 run 归给中心所在的格，格的阅读轴范围 = 其名下 run 的整体
    范围——高字、贴字标点不会被格边界（相邻字中心线的中点）切断，
    逐框识别 crop 到完整字形。唯一例外是跨多格的粘连长段（洇墨把多
    个字连成一整段）：整段归中心格会把该格拉成跨数十字位的巨框、段
    内其余字位成幽灵空位条带，这样的段按跨过的格边界切开各归各格。
    宽度方向仍限制在行宽内（不吃邻列）。
    无 run 归属或墨迹过小（疑似噪点）的格保留原条带框——横画类字
    （一/二/〇…）墨迹矮而宽，不按噪点处理，照常收紧。mask 与像素
    切分同源（同一份整页二值化，带 (路径,mtime) 缓存）。
    """
    if not boxes:
        return boxes
    try:
        from seg_refine import _run_is_solid_band
        from segmenter import _runs, _text_mask_for_refinement

        mask = _text_mask_for_refinement(image_path)
    except Exception as exc:
        log(f"[tighten] mask unavailable ({exc})，保留条带框")
        return boxes
    if mask is None:
        log("[tighten] mask unavailable，保留条带框")
        return boxes
    mask_h, mask_w = mask.shape[:2]
    vertical = orientation != "horizontal"

    # 行的包围范围（各格同属一行，X 范围即列宽）。
    lx1 = max(0, min(int(b[0]) for b in boxes))
    ly1 = max(0, min(int(b[1]) for b in boxes))
    lx2 = min(mask_w, max(int(b[0] + b[2]) for b in boxes))
    ly2 = min(mask_h, max(int(b[1] + b[3]) for b in boxes))
    if lx2 <= lx1 or ly2 <= ly1:
        return boxes

    strip = mask[ly1:ly2, lx1:lx2] > 0
    # 阅读轴上的连续墨迹段（不合并相近段：三/二这类内部留空的字天然
    # 成多段，按中心归属会回到同一格；句号贴字则各归各格，互不切断）。
    axis = strip.any(axis=1) if vertical else strip.any(axis=0)
    axis_runs = _runs(axis, 1)
    if not axis_runs:
        return boxes

    # 行内墨迹沿跨阅读轴方向的整体跨度：横画类字（一/二/〇…）墨迹高度
    # 只有 2~5px、横向却占大半行墨宽——矮而宽是字，又矮又窄才是噪点。
    # 高度阈值对这类字放行，否则整行宽的 cuts 条带框原样保留，『一』
    # 的字框比同行其他字宽一截（实测 43px vs 同行中位 29px）。
    cross_all = (strip.any(axis=0) if vertical else strip.any(axis=1)).tolist()
    cross_ink = [i for i, v in enumerate(cross_all) if v]
    char_like_w = (
        max(8, int(round((cross_ink[-1] - cross_ink[0] + 1) * 0.65)))
        if cross_ink else 0
    )
    line_ink_span = cross_ink[-1] - cross_ink[0] + 1 if cross_ink else 0

    cells = [(int(b[0]), int(b[1]), int(b[2]), int(b[3])) for b in boxes]
    # run 归属：中心点落在哪个格就归哪个格；都不落（罕见，run 跨出
    # 所有格的范围）时归重叠最多的格。run 坐标是行内相对坐标，cell
    # 是全图坐标，比较前先补偏移。
    off = ly1 if vertical else lx1
    # 跨格粘连段例外：洇墨把多个字的墨迹连成一整段（无纯白空隙）时，
    # 整段归中心格会把该格拉成跨数十字位的巨框，段内其余字位又因"无
    # 墨迹归属"保留幽灵空位条带（实测 22 格列里 11 字连成 1044px 一段
    # → 一个 11 字高巨框 + 11 个空位占位框层层叠压）。这样的段按它
    # 跨过的格边界切开、各归各格——格边界是 Kraken 的切字位置，正是
    # 粘连处可用的分界。只跨 ≤1 条边界且不足 1.8×中位格长的段不在此
    # 列：那是高字/贴字标点（见 docstring），仍整段归属、不被格边界
    # 切断；被误切的单字上下部件（需=雨+而，两半段都占满字宽）由下游
    # punct-merge 重新并回一个字框。
    cell_axes = [
        ((cy - off, cy + ch - off) if vertical else (cx - off, cx + cw - off))
        for cx, cy, cw, ch in cells
    ]
    cell_starts = sorted({a1 for a1, _ in cell_axes})
    cell_len_median = (
        float(np.median([a2 - a1 for a1, a2 in cell_axes])) if cell_axes else 0.0
    )
    # 窄缝并段：字内部件缝（會的人字头与身实测仅 1~4px）先并成一段再
    # 按中心归属，否则部件两段分落相邻两格、整字被切成两框（实测會的
    # 身部单独读成『日』）。阈值取"本行 run 间缝中位数的 35%"（再以
    # 0.12×格长为上限、2px 为下限）——部件缝远小于本行典型字距：紧排
    # 書（实测字距 4~7px）中位缝 ~5px → 只并 ≤2px 的部件缝，字与字保
    # 持独立 run、整段归属不受格界切割；疏排版同理自适应。固定阈值在
    # 紧排書会把正常字距也并成巨段、退化为按（可能错位的）格边界切字，
    # 每框带邻字墨迹出血。"实心横带"（一/乙/三的每一横）不参与并段
    # ——字与紧贴的『一』（实测间隔仅 2~6px）仍各归各格；三/二这类内
    # 部留空更宽的字并段前后中心都落同格，行为不变。紧贴的非横带标点
    # 并进字框后，由后续"字+标点"拆分再独立成框。
    if cell_len_median >= 12 and len(axis_runs) > 1:
        run_gaps = [
            axis_runs[idx + 1][0] - axis_runs[idx][1]
            for idx in range(len(axis_runs) - 1)
        ]
        median_gap = float(np.median(run_gaps))
        fuse_gap = max(
            2,
            min(
                int(round(median_gap * 0.35)),
                int(round(cell_len_median * 0.12)),
            ),
        )
        solid_cache: dict[int, bool] = {}

        def run_is_solid(idx: int) -> bool:
            if idx not in solid_cache:
                s, e = axis_runs[idx]
                solid_cache[idx] = _run_is_solid_band(strip, s, e, vertical)
            return solid_cache[idx]

        fused_runs: list[tuple[int, int]] = []
        fused_count = 0
        for idx, (s, e) in enumerate(axis_runs):
            if (
                fused_runs
                and s - fused_runs[-1][1] <= fuse_gap
                and not run_is_solid(idx)
                and not run_is_solid(idx - 1)
            ):
                fused_runs[-1] = (fused_runs[-1][0], e)
                fused_count += 1
            else:
                fused_runs.append((s, e))
        if fused_count:
            log(
                f"[tighten] 窄缝并段: {len(axis_runs)} 段中 {fused_count} 处缝 "
                f"≤{fuse_gap}px 并为 {len(fused_runs)} 段"
                f"（中位缝 {median_gap:.0f}px；字内部件缝，會/需类整字"
                f"不被格界切碎）"
            )
            axis_runs = fused_runs
    assigned: list[list[tuple[int, int]]] = [[] for _ in cells]
    stuck_run_split = 0
    row_ink_cache: np.ndarray | None = None
    for s, e in axis_runs:
        crossed = [b for b in cell_starts if s < b < e]
        if len(crossed) >= 2 or (crossed and (e - s) > 1.8 * cell_len_median):
            # 分界贴谷：切开位置取"cut 附近墨迹最薄的行"而不是原始 cut。
            # cut 是相邻字符中心线的中点，行尾/洇墨处的估计可偏出二三十
            # 像素（实测末两格分界 2066 vs 真实字界 ~2043：按原始 cut 切
            # 开后倒数第二框吞末字顶部、末框矮）。粘连段内没有纯白缝，
            # 最少墨行就是字与字的连接处（笔画最细的地方）。窗口内墨迹
            # 均匀（无谷，实心合成块）时保持原 cut——argmin 在均匀区间
            # 里是任意的，不能让噪声移动分界。
            if row_ink_cache is None:
                row_ink_cache = (
                    strip.sum(axis=1) if vertical else strip.sum(axis=0)
                )
            row_ink = row_ink_cache

            def _valley(b: int) -> int:
                delta = max(3, int(cell_len_median * 0.35))
                lo, hi = max(s, b - delta), min(e, b + delta)
                if hi - lo < 4:
                    return b
                win = row_ink[lo:hi]
                med = float(np.median(win))
                idx = int(np.argmin(win))
                if med <= 0 or win[idx] >= med * 0.75:
                    return b  # 窗口内墨迹均匀：cut 不可改进
                return lo + idx

            refined = [_valley(b) for b in crossed]
            # 贴谷后仍须严格递增（窗口重叠时谷可能被吸到一起）
            for k in range(1, len(refined)):
                refined[k] = max(refined[k], refined[k - 1] + 1)
            edges = [s, *refined, e]
            seg_cells = 0
            for k in range(len(edges) - 1):
                ss, se = edges[k], edges[k + 1]
                if se <= ss:
                    continue
                owner = -1
                best = 0
                for ci, (a1, a2) in enumerate(cell_axes):
                    overlap = min(se, a2) - max(ss, a1)
                    if overlap > best:
                        best, owner = overlap, ci
                if owner >= 0:
                    assigned[owner].append((ss, se))
                    seg_cells += 1
            if seg_cells >= 2:
                stuck_run_split += 1
                moved = [
                    f"{b}->{r}"
                    for b, r in zip(crossed, refined)
                    if r != b
                ]
                log(
                    f"[tighten] 粘连段切分: run=({s},{e}) 长={e - s} "
                    f"跨格边界 {crossed} -> {seg_cells} 段各归各格"
                    f"（洇墨连成一整段，不并成单格巨框）"
                    + (f"；分界贴谷 {moved}（cut 漂移校正到最少墨行）"
                       if moved else "")
                )
                continue
            # 切分没落到 ≥2 个格（格框异常/全在界外）：回落整段归属
        center = (s + e - 1) / 2.0 + off
        owner = -1
        for ci, (cx, cy, cw, ch) in enumerate(cells):
            a1, a2 = (cy, cy + ch) if vertical else (cx, cx + cw)
            if a1 <= center < a2:
                owner = ci
                break
        if owner < 0:
            best_overlap = 0
            for ci, (cx, cy, cw, ch) in enumerate(cells):
                a1, a2 = (cy, cy + ch) if vertical else (cx, cx + cw)
                overlap = max(0, min(e + off, a2) - max(s + off, a1))
                if overlap > best_overlap:
                    best_overlap = overlap
                    owner = ci
        if owner >= 0:
            assigned[owner].append((s, e))

    # ── 行尾格界漂移校正：短部件重归 ──
    # kraken 的格界取自相邻字符中心线的中点（首尾格借行框边缘，见
    # kraken_worker._record_to_line）。行尾字符（部件留白字形干/才类、
    # 句读小字）的中心估计偏移时，分界会整体漂进末字上半部：按中心
    # 归属后，倒数第二格吞进末字顶部短部件（框偏高）、末格只剩下半截
    # （框矮，逐框读法把半截读成『丨』）。贴界的短部件（高度 < 0.55×
    # 中位格长）按"两侧墨迹跨度都向中位格长收敛"并回正确一侧：只在
    # 代价改善 ≥0.15×格长、接收侧跨度不超 1.4×格长时挪。會/需类的整
    # 字部件两半高度接近半格以上、且正确归属时两侧已接近格长（挪动
    # 只会更差/超上限），不受影响。
    if cell_len_median >= 12 and len(cells) >= 2:
        frag_h = cell_len_median * 0.55
        margin = cell_len_median * 0.15
        span_cap = cell_len_median * 1.4

        def _runs_span(rs: list[tuple[int, int]]) -> int:
            return max(e for _, e in rs) - min(s for s, _ in rs)

        for ci in range(len(cells) - 1):
            left = sorted(assigned[ci])
            right = sorted(assigned[ci + 1])
            if not left or not right or left[-1][1] > right[0][0]:
                continue  # 空格（保留条带）或几何交错：不是相邻格
            moved = 0
            while True:
                base = (
                    abs(_runs_span(left) - cell_len_median)
                    + abs(_runs_span(right) - cell_len_median)
                )
                best = None
                best_cost = base - margin
                if len(left) > 1 and left[-1][1] - left[-1][0] <= frag_h:
                    cand_l, cand_r = left[:-1], right + [left[-1]]
                    if _runs_span(cand_r) <= span_cap:
                        cost = (
                            abs(_runs_span(cand_l) - cell_len_median)
                            + abs(_runs_span(cand_r) - cell_len_median)
                        )
                        if cost < best_cost:
                            best, best_cost = (cand_l, cand_r), cost
                if len(right) > 1 and right[0][1] - right[0][0] <= frag_h:
                    cand_l, cand_r = left + [right[0]], right[1:]
                    if _runs_span(cand_l) <= span_cap:
                        cost = (
                            abs(_runs_span(cand_l) - cell_len_median)
                            + abs(_runs_span(cand_r) - cell_len_median)
                        )
                        if cost < best_cost:
                            best, best_cost = (cand_l, cand_r), cost
                if best is None:
                    break
                left, right = best
                moved += 1
            if moved:
                log(
                    f"[tighten] 行尾部件重归: 格#{ci}↔#{ci + 1} 挪 {moved} 个"
                    f"短部件（格界漂移校正：两侧墨迹跨度向中位格长 "
                    f"{cell_len_median:.0f}px 收敛）"
                )
                assigned[ci] = left
                assigned[ci + 1] = right

    out: list[tuple[int, int, int, int]] = []
    kept_no_run = 0
    kept_speck = 0
    stroke_tightened = 0
    for cell_idx, ((bx, by, bw, bh), runs) in enumerate(zip(cells, assigned)):
        keep = (bx, by, bw, bh)
        if not runs:
            kept_no_run += 1
            log(
                f"[tighten] 保留条带: 框#{cell_idx} rect={keep} "
                f"原因=格内无墨迹归属（空位/空格）"
            )
            out.append(keep)
            continue
        s_min, e_max = min(s for s, _ in runs), max(e for _, e in runs)
        # 阅读轴范围 = 名下墨迹段整体；宽度 = 该范围内的墨迹列/行。
        if vertical:
            roi = strip[s_min:e_max, :]
            ny1, nh = ly1 + s_min, e_max - s_min
            cols = roi.any(axis=0)
            nx1 = lx1 + int(cols.argmax())
            nw = len(cols) - int(cols.argmax()) - int(cols[::-1].argmax())
        else:
            roi = strip[:, s_min:e_max]
            nx1, nw = lx1 + s_min, e_max - s_min
            rows = roi.any(axis=1)
            ny1 = ly1 + int(rows.argmax())
            nh = len(rows) - int(rows.argmax()) - int(rows[::-1].argmax())
        if nw < 3 or (nh < 6 and nw < char_like_w):
            # 墨迹过小疑似噪点：贴上去会生成误导训练数据的微框。
            # 横画类字例外（墨迹矮但宽度达行墨宽 65%），见 char_like_w。
            kept_speck += 1
            reason = (
                f"墨迹过窄（nw={nw}<3）"
                if nw < 3 else
                f"墨迹又矮又窄（{nw}x{nh}，噪声判据 nh<6 且 nw<行墨宽65%={char_like_w}）"
            )
            log(
                f"[tighten] 保留条带: 框#{cell_idx} rect={keep} "
                f"原因=疑似噪点不收紧（{reason}），条带框宽度恒为行宽"
            )
            out.append(keep)
            continue
        if nh < 6:
            stroke_tightened += 1
            log(
                f"[tighten] 横画收紧: 框#{cell_idx} 条带={keep} -> "
                f"({nx1},{ny1},{nw},{nh})（墨迹仅 {nh}px 高、宽 {nw}px ≥ "
                f"行墨宽 65%={char_like_w}：横画类字不按噪点处理）"
            )
        out.append((nx1, ny1, nw, nh))
    # A cuts cell can legitimately be tall and narrow, but a page/column
    # ruling fragment has the distinctive combination of being glued to the
    # row edge, only a few pixels wide, and inked almost continuously along
    # the reading axis.  The earlier per-cell noise check intentionally kept
    # such cells because they were not tiny in the reading direction.  Drop
    # only that ruling signature here; keep the original list if every cell
    # would be removed so a sparse punctuation-only line remains readable.
    try:
        from segmenter import _is_edge_ruling_fragment, _is_cross_column_band

        line_bounds = (lx1, lx2) if vertical else (ly1, ly2)
        def edge_micro_fragment(b: tuple[int, int, int, int]) -> bool:
            bx, by, bw, bh = b
            if vertical:
                near = bx <= lx1 + 4 or bx + bw >= lx2 - 4
                return near and bw <= 8
            near = by <= ly1 + 4 or by + bh >= ly2 - 4
            return near and bh <= 8

        axis_spans = [b[3] if vertical else b[2] for b in out]
        band_cap = (
            max(4, int(round(0.2 * float(np.median(axis_spans)))))
            if axis_spans else 4
        )
        filtered = [
            b for b in out
            if not _is_edge_ruling_fragment(b, mask, line_bounds, orientation)
            and not _is_cross_column_band(b, mask, line_bounds, orientation, band_cap)
            and not edge_micro_fragment(b)
        ]
        if filtered and len(filtered) != len(out):
            log(
                f"[tighten] drop ruling fragments "
                f"{len(out) - len(filtered)} cell(s) from row "
                f"({lx1},{ly1},{lx2 - lx1},{ly2 - ly1})"
            )
            out = filtered
    except Exception as exc:
        log(f"[tighten] ruling-fragment filter skipped: {exc}")
    log(
        f"[tighten] 行框=({lx1},{ly1},{lx2 - lx1},{ly2 - ly1}) "
        f"格数={len(cells)} 收紧={len(out) - kept_no_run - kept_speck}"
        f"（含横画豁免 {stroke_tightened}） 保留条带={kept_no_run + kept_speck}"
        f"（无墨迹 {kept_no_run}/疑似噪点 {kept_speck}） "
        f"粘连段切分={stuck_run_split} "
        f"行墨宽跨度={line_ink_span} 噪点宽度阈值={char_like_w}"
    )
    return out




def _filter_pixel_noise_boxes(
    image_path: str,
    boxes: list[tuple[int, int, int, int]],
    line_rect: dict,
    orientation: str,
) -> list[tuple[int, int, int, int]]:
    """Remove page/ruling fragments that survived pixel component splitting.

    Pixel splitting normally returns tight character boxes, so the cuts-based
    tightening filter is not involved.  A page border can nevertheless be a
    connected component at the edge of an expanded line, and a broken vertical
    rule can look like a very narrow character in the middle of a column.  Drop
    only those edge/rule signatures when the row also contains several normal
    boxes; preserve sparse punctuation and never collapse a whole row.
    """
    if len(boxes) < 3:
        return boxes
    try:
        from segmenter import _text_mask_for_refinement

        mask = _text_mask_for_refinement(image_path)
    except Exception as exc:
        log(f"[pixel-noise] mask unavailable: {exc}")
        return boxes
    if mask is None or mask.ndim != 2:
        return boxes
    ih, iw = mask.shape[:2]
    vertical = orientation != "horizontal"
    lx = int(line_rect.get("x", 0))
    ly = int(line_rect.get("y", 0))
    lw = int(line_rect.get("w", 0))
    lh = int(line_rect.get("h", 0))
    cross_start, cross_end = (lx, lx + lw) if vertical else (ly, ly + lh)
    cross_span = max(1, cross_end - cross_start)
    kept: list[tuple[int, int, int, int]] = []
    dropped: list[tuple[int, int, int, int]] = []
    for box in boxes:
        x, y, w, h = (int(v) for v in box)
        x1, y1 = max(0, x), max(0, y)
        x2, y2 = min(iw, x + w), min(ih, y + h)
        roi = mask[y1:y2, x1:x2]
        if roi.size == 0:
            kept.append(box)
            continue
        ink = int(np.count_nonzero(roi))
        density = ink / float(roi.size)
        axis_span = h if vertical else w
        cross_size = w if vertical else h
        near_cross_edge = (
            min(abs((x if vertical else y) - cross_start),
                abs((x + w if vertical else y + h) - cross_end))
            <= max(4, int(cross_span * 0.25))
        )
        near_page_edge = (
            (vertical and (y <= 4 or y + h >= ih - 5))
            or (not vertical and (x <= 4 or x + w >= iw - 5))
        )
        axis_occupancy = float(
            (roi.any(axis=1 if vertical else 0)).mean()
        ) if roi.size else 0.0
        widths = (
            (roi > 0).sum(axis=0 if vertical else 1)
            if roi.size else np.array([], dtype=np.int32)
        )
        positive = widths[widths > 0]
        median_stroke = float(np.median(positive)) if positive.size else 999.0
        # A broken ruling has a long reading-axis span, narrow cross span and
        # near-continuous ink.  The page frame produces short 3–8px components
        # at the final image edge and is handled separately.
        ruling = (
            near_cross_edge
            and axis_span >= 12
            and cross_size <= max(8, int(cross_span * 0.10))
            and axis_occupancy >= 0.65
            and median_stroke <= 5.0
            and density <= 0.45
        )
        page_fragment = (
            near_page_edge
            and axis_span <= 8
            and cross_size >= 3
            and density <= 0.75
        )
        if ruling or page_fragment:
            dropped.append(box)
        else:
            kept.append(box)
    if dropped and kept:
        log(f"[pixel-noise] drop {len(dropped)} ruling/page fragment box(es): {dropped[:8]}")
        return kept
    return boxes




def _pad_boxes_for_reading(
    boxes: list[tuple[int, int, int, int]],
    orientation: str,
) -> list[tuple[int, int, int, int]]:
    """读字框外扩 ~15%（仅用于识别读法，字框几何本身不变）。

    自动切分的字框紧贴墨迹，喂给识别模型时字形周围没有留白，逐字
    读法准确率显著更低（21 行人工确认 GT 实测：紧致框逐字 0.59，
    外扩后 0.86）；手画单字框识别准的原因正是这圈自然边距。裁剪
    范围限制在本批字框包围盒外扩 6px 内，避免吃进邻列。"""
    vertical = orientation != "horizontal"
    xs1 = max(0, min(b[0] for b in boxes) - 6)
    ys1 = max(0, min(b[1] for b in boxes) - 6)
    xs2 = max(b[0] + b[2] for b in boxes) + 6
    ys2 = max(b[1] + b[3] for b in boxes) + 6
    out = []
    for x, y, w, h in boxes:
        if vertical:
            dx, dy = max(2, int(w * 0.15)), max(3, int(h * 0.15))
        else:
            dx, dy = max(3, int(w * 0.15)), max(2, int(h * 0.15))
        x1, y1 = max(xs1, x - dx), max(ys1, y - dy)
        x2, y2 = min(xs2, x + w + dx), min(ys2, y + h + dy)
        out.append((x1, y1, max(1, x2 - x1), max(1, y2 - y1)))
    return out




def _is_even_split(
    boxes: list[tuple[int, int, int, int]], rect: dict, orientation: str
) -> bool:
    """判断字框列表是否为合成框：所有字框沿阅读轴的跨度完全相等。

    手画/手调过的框几乎不可能所有跨度都精确相等；而数据修复的均排框、
    自动均分兜底框、历史上半尺寸 bug 写出的框都满足。对合成框应改用
    Kraken 真实切分位置，只有真正人工画的框才值得保留几何。
    """
    if len(boxes) < 2:
        return False
    vertical = orientation != "horizontal"
    spans = [b[3] for b in boxes] if vertical else [b[2] for b in boxes]
    return max(spans) - min(spans) <= 1




def _horizontal_user_boxes_reject_reason(
    boxes: list[tuple[int, int, int, int]],
    rect: dict,
) -> str | None:
    """横排编辑器传入字框的体检：不可用返回原因（写日志），可用返回 None。

    编辑器「重识别本行」把该行现有字框原样传回、期望保留人工几何；但
    历史 paddle 均分槽位时代行框外扩错位写出的框（首框落在行框外、
    其余整体错一格）数量恰好等于字数且非均分，会被"保留人工框"原样
    收下——错位代代相传。体检一条：每框中心落在行框内（编辑器新增
    字框本就按中心归属行，中心在行框外=历史错位数据）。不通过即弃用，
    走像素切分重建，让字框、行图与读法重新对齐。竖排像素切分框贴墨迹
    本就如此校验过归属，不做重复体检。"""
    try:
        rx, rw = int(rect["x"]), int(rect["w"])
    except (KeyError, TypeError, ValueError):
        return "行框参数异常"
    if rw <= 0:
        return "行宽为 0"
    for idx, (bx, _by, bw, _bh) in enumerate(boxes):
        cx = bx + bw / 2.0
        if not (rx <= cx <= rx + rw):
            return f"框#{idx} 中心 {cx:.0f} 在行框 [{rx},{rx + rw}] 外"
    return None




def _line_rect_has_ink(image_path: str, read_rect: dict) -> bool:
    """行框内是否有墨迹（整页二值化 mask 与页边裁剪）。mask 不可用时
    返回 False，由调用方按"无墨迹=异常输入"处理。"""
    try:
        from segmenter import _text_mask_for_refinement

        ink_mask = _text_mask_for_refinement(image_path)
        if ink_mask is not None:
            mh, mw = ink_mask.shape[:2]
            ix1 = max(0, int(read_rect["x"]))
            iy1 = max(0, int(read_rect["y"]))
            ix2 = min(mw, int(read_rect["x"]) + int(read_rect["w"]))
            iy2 = min(mh, int(read_rect["y"]) + int(read_rect["h"]))
            if ix2 > ix1 and iy2 > iy1:
                return bool((ink_mask[iy1:iy2, ix1:ix2] > 0).any())
    except Exception:
        pass
    return False




def _expand_line_rect_for_reading(
    image_path: str,
    rect: dict,
    line_id: str,
    orientation: str,
) -> dict:
    """行框沿阅读轴外扩到本行墨迹的连续段两端（返回新框，不改原值）。

    偏短的行框（人工画的行框、历史上切短的自动行框）把行外的字整段
    留在框外，识别与切分都看不到 → "识别不全"。识别与切分改用扩后的
    框（沿轴找墨迹，白色区间超过约 0.85 字高即停——行末空白/段首缩进
    远大于字距，扩展自然止于本行连续墨迹段）。横排不做外扩：编辑器对
    手工调过的行会把行框还原成用户几何（外扩被丢弃），外扩后切出的字
    框（贴行外墨迹）就会画到行图外——实测横排标题行的识别框跑到行图
    左缘外、只剩一条窄条。"""
    if orientation == "horizontal":
        return dict(rect)
    try:
        from segmenter import (
            _text_mask_for_refinement,
            expand_line_rect_to_neighbor_ink,
        )

        ink_mask = _text_mask_for_refinement(image_path)
        if ink_mask is not None:
            mask_h, mask_w = ink_mask.shape[:2]
            base = (int(rect["x"]), int(rect["y"]), int(rect["w"]), int(rect["h"]))
            expanded = expand_line_rect_to_neighbor_ink(
                base, ink_mask, mask_w, mask_h, orientation
            )
            if expanded != base:
                log(f"[line-rec] {line_id} rect {base} expanded to ink {expanded}")
                return {
                    "x": expanded[0], "y": expanded[1],
                    "w": expanded[2], "h": expanded[3],
                }
    except Exception as exc:
        log(f"[line-rec] {line_id} rect expand failed: {exc}")
    return dict(rect)




def _clamp_lines_to_image(lines: list[dict], image_path: str) -> list[dict]:
    """行框与字框统一钳回图片范围（识别框不得超出书页图片本身）。"""
    try:
        from segmenter import _text_mask_for_refinement, _clamp_rect_to_image

        mask = _text_mask_for_refinement(image_path)
        if mask is None:
            return lines
        mh, mw = mask.shape[:2]
    except Exception as exc:
        log(f"[line-rec] clamp to image skipped: {exc}")
        return lines
    for ln in lines:
        ln["x"], ln["y"], ln["w"], ln["h"] = _clamp_rect_to_image(
            ln.get("x", 0), ln.get("y", 0), ln.get("w", 0), ln.get("h", 0), mw, mh
        )
        for c in ln.get("chars") or []:
            c["x"], c["y"], c["w"], c["h"] = _clamp_rect_to_image(
                c.get("x", 0), c.get("y", 0), c.get("w", 0), c.get("h", 0), mw, mh
            )
    return lines




def _safe_text_mask(image_path: str):
    try:
        from segmenter import _text_mask_for_refinement

        return _text_mask_for_refinement(image_path)
    except Exception as exc:
        log(f"[line-rec] mask unavailable: {exc}")
        return None
