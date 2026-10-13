# -*- coding: utf-8 -*-
"""行装配（从 segmenter 拆出）：行对齐、纵条带、重叠消解、条带缝切字、
YOLO 字框归行与噪声过滤。segmenter.py 仍为门面。"""
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
from seg_imaging import (_runs, _merge_close_runs, _merge_fragmentary_strips, _text_mask_for_refinement, _tight_rect)
from seg_models import _predict_detection_layer
from seg_refine import _tight_piece





# 逐框读法与整行序列读法的对齐策略（Kraken 桥在用）：
# 吻合率高 → 正文取整行序列字；吻合率低（标点/漏识别导致整体错开）
# → 正文以逐框读法为准。
def line_alignment_primary(
    box_texts: list[str],
    seq_texts: list[str],
    min_comparable: int = 2,
    min_match_rate: float = 0.6,
    boxes_trusted: bool = True,
) -> str:
    """逐框读法与整行序列读法的吻合率决定该行正文来源。

    返回 "seq"：吻合率高，说明字框与序列对齐可信——正文用整行序列字
    （语境识别更准），框内读法进候选。返回 "box"：吻合率低，疑似错位
    （标点/漏识别导致整体错开）——正文以框内识别为准，序列字进候选。

    boxes_trusted=False（字框来自 kraken cuts 条带框/网格兜底槽位框，
    与真实字形可整体错半格）：低吻合时的分歧更可能源于**框错位**而非
    序列错——逐框读的是错位切片（实测木刻大字列 cuts 框逐字整行乱码
    "夾夾災㤙日能遇…"而整行读法完全正确"夾月夾日誰能遇夾昌夾曲立貴
    兮"），此时信整行序列。"""
    has_seq = any((t or "").strip() for t in seq_texts)
    comparable = 0
    matches = 0
    for box_text, seq_text in zip(box_texts, seq_texts):
        box1 = (box_text or "").strip()[:1]
        seq1 = (seq_text or "").strip()[:1]
        if box1 and seq1:
            comparable += 1
            if box1 == seq1:
                matches += 1
    if comparable >= min_comparable and matches / comparable >= min_match_rate:
        return "seq"
    if has_seq and not boxes_trusted:
        return "seq"
    return "box"




def _vertical_line_strips(
    image_path: str, image_w: int, image_h: int, orientation: str = "vertical"
) -> list[tuple[int, int]]:
    """整页墨迹投影切行条带：行划分与字检测解耦。

    竖排（默认）：沿 X 轴投影切竖排行（列）条带，返回 [(x, w)]。
    横排：mask 转置后复用同一套投影/补捞逻辑——转置域的"列"即原图的
    水平行、"列宽"上下限对应行高上下限、"标点尾列"补捞对应行尾标点，
    返回 [(y, h)] 水平条带（调用方按条带轴归组字框）。

    层级顺序（主区>段>行>字）中"行"这一层由页面墨迹分布决定——先划行，
    字检测框随后按中心归入行、只提供行内字几何；字检测漏检不再导致
    行缺失或断行。mask 与字框像素切分同源（同一份二值化墨迹）。"""

    def runs_at(percentile: int) -> list[tuple[int, int]]:
        threshold = max(2, int(np.percentile(positive, percentile))) if positive.size else 2
        r = _runs(x_proj > threshold, min_len=max(3, work_w // 300))
        return _merge_close_runs(r, max_gap=max(2, work_w // 220))

    mask = _text_mask_for_refinement(image_path)
    if mask is None:
        return []
    if orientation == "horizontal":
        mask = np.ascontiguousarray(mask.T)
        work_w, work_h = image_h, image_w
    else:
        work_w, work_h = image_w, image_h
    x_proj = np.sum(mask > 0, axis=0)
    positive = x_proj[x_proj > 0]
    # 主阈值（35 分位）抓正文列——列高墨浓，阈值高可压掉界欄/散点噪声。
    # 但大字标题/短注列墨迹密度远低于正文列（实测标题列 x_proj 只有正文
    # 的 1/3），单一阈值会把整列压掉——主区已圈入标题、重识别后行/段/
    # 字三层却全都不出现该行的根因。低阈值整体替代不可行（相邻正文列
    # 会粘连、反被宽度上限误杀，实测某页 12 列变 6 列），因此双阈值
    # 补捞：低阈值（10 分位）再切一遍，只补与任何主条带不重叠的条带
    # ——补捞目标周围没有正文列，不存在粘连；正文区的低阈值条带都与
    # 主条带重叠，自然跳过。
    runs = runs_at(35)
    # 最小列宽：拦掉界欄/边框残留等细长墨迹条带（实测约 7-8px），真实
    # 文字列（含半宽小注列）远宽于此。
    min_strip_w = max(14, int(work_w * 0.012))
    max_strip_w = work_w * 0.12

    def width_ok(r: tuple[int, int]) -> bool:
        return min_strip_w <= r[1] - r[0] <= max_strip_w

    kept_runs = [r for r in runs if width_ok(r)]
    # 双阈值补捞：低阈值再切一遍，补与任何存活主条带不重叠的条带——
    # 补捞目标周围没有正文列，不存在粘连；正文区的低阈值条带都与主
    # 条带重叠，自然跳过。重叠检查只对"存活"主条带做：主阈值那遍可
    # 能探到稀疏列的零星粗笔画（宽 3px 的碎条带），它们随后会因宽度
    # 不足被丢弃，不能让它们挡住补捞（实测大字标题正是这种情形）。
    merge_gap = max(2, work_w // 220)
    extra_runs = [
        r
        for r in runs_at(10)
        if width_ok(r)
        and all(
            r[0] >= m[1] + merge_gap or r[1] <= m[0] - merge_gap
            for m in kept_runs
        )
    ]
    runs = _merge_fragmentary_strips(
        sorted(kept_runs + extra_runs), work_w, work_h
    )
    # 标点尾列补捞：段落末尾的句号/逗号独占一列时墨迹极少（x_proj 只有
    # 十几，而主/低两档分位阈值都以正文列的墨迹水平为基准，都捞不到），
    # 整列被丢——段落少个句号、只能手画框（实测"整列一个句号"画框后
    # 还会撞上 Kraken 行读法为空的报错）。用绝对地板阈值（x_proj>2）
    # 再切一遍，补捞与所有存活条带不重叠且条带内墨迹"少而小"的条带：
    # ≤3 个连通块、每个都只有标点大小（高宽 ≤ 版高的 1/45、面积 ≥8）
    # ——正常文字列的墨迹量/组件数远超此限，散点噪声面积不足，均不会
    # 命中。捞到的条带随后走正常行管线（识别为空时由行兜底建字框）。
    punct_runs: list[tuple[int, int]] = []
    floor_runs = _merge_close_runs(_runs(x_proj > 2, min_len=3), max_gap=merge_gap)
    if floor_runs:
        punct_h_cap = max(18, work_h // 45)
        punct_min_w = max(8, min_strip_w // 2)
        for r in floor_runs:
            if not (punct_min_w <= r[1] - r[0] <= max_strip_w):
                continue
            if not all(
                r[0] >= m[1] + merge_gap or r[1] <= m[0] - merge_gap
                for m in runs
            ):
                continue
            strip_mask = (mask[:, r[0]:r[1]] > 0).astype(np.uint8)
            num_labels, _labels, stats, _ = cv2.connectedComponentsWithStats(
                strip_mask, connectivity=8,
            )
            comps = [
                i for i in range(1, num_labels)
                if int(stats[i, cv2.CC_STAT_AREA]) >= 8
            ]
            if not comps or len(comps) > 3:
                continue
            if any(
                int(stats[i, cv2.CC_STAT_HEIGHT]) > punct_h_cap
                or int(stats[i, cv2.CC_STAT_WIDTH]) > punct_h_cap
                for i in comps
            ):
                continue
            span = (
                max(
                    int(stats[i, cv2.CC_STAT_TOP]) + int(stats[i, cv2.CC_STAT_HEIGHT])
                    for i in comps
                )
                - min(int(stats[i, cv2.CC_STAT_TOP]) for i in comps)
            )
            if span > 4 * punct_h_cap:
                continue
            punct_runs.append(r)
        runs = _merge_fragmentary_strips(sorted(runs + punct_runs), work_w, work_h)
    strips: list[tuple[int, int]] = [(rx1, rx2 - rx1) for rx1, rx2 in runs]
    _log(
        f"[diag:line-strips] projection strips={len(strips)}"
        + (f" (recovered={len(extra_runs)})" if extra_runs else "")
        + (f" (punct_recovered={len(punct_runs)})" if punct_runs else "")
    )
    return strips




def _resolve_overlapping_line_boxes(
    boxes: list[tuple[int, int, int, int]],
    orientation: str = "vertical",
) -> list[tuple[int, int, int, int]]:
    """行检测模型对同一列可能输出重叠的多个框（实测同页"整列框+半列
    框"成对、"跨双列宽框+单列框"并存），照单全收会让同一列出现互相
    重叠的识别框、字被劈到两行。按跨轴（竖排 x / 横排 y）重叠分类：

    ① 互相覆盖 ≥0.7（双方）→ 同一列的重复框，合并为一个；
    ② 一侧被另一侧覆盖 ≥0.8、反向 <0.7 → 宽框吞了邻列，把宽框裁窄，
       让两框各管一列（窄框已有自己的行，宽框的这部分不再越界）；
    ③ 其余部分重叠（≥0.4×窄者宽）→ 在重叠带中点裁开，两框不重叠。

    返回互不重叠的最终框列表（并集框用于同列合并，行框几何随后仍由
    框内字框并集给出）。"""
    if not boxes:
        return []
    vertical = orientation != "horizontal"
    rects = [[int(v) for v in b] for b in boxes]
    n = len(rects)
    parent = list(range(n))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(i: int, j: int) -> None:
        ri, rj = find(i), find(j)
        if ri != rj:
            parent[rj] = ri

    def cross_range(r: list[int]) -> tuple[int, int]:
        return (r[0], r[0] + r[2]) if vertical else (r[1], r[1] + r[3])

    def read_range(r: list[int]) -> tuple[int, int]:
        return (r[1], r[1] + r[3]) if vertical else (r[0], r[0] + r[2])

    def cross_trim(r: list[int], lo: int, hi: int) -> None:
        if vertical:
            x1, x2 = r[0], r[0] + r[2]
            r[0], r[2] = lo, max(0, hi - lo)
        else:
            x1, x2 = r[1], r[1] + r[3]
            r[1], r[3] = lo, max(0, hi - lo)
        _ = x1, x2

    for _pass in range(3):
        changed = False
        for i in range(n):
            for j in range(i + 1, n):
                ri_, rj_ = find(i), find(j)
                if ri_ == rj_:
                    continue
                A, B = rects[i], rects[j]
                if A[2] <= 2 or A[3] <= 2 or B[2] <= 2 or B[3] <= 2:
                    continue
                a1, a2 = cross_range(A)
                b1, b2 = cross_range(B)
                ov = min(a2, b2) - max(a1, b1)
                if ov <= 0:
                    continue
                r1a, r2a = read_range(A)
                r1b, r2b = read_range(B)
                rov = min(r2a, r2b) - max(r1a, r1b)
                if rov <= 0:
                    continue
                narrow = min(A[2] if vertical else A[3], B[2] if vertical else B[3])
                if ov < 0.4 * narrow:
                    continue
                cov_a = ov / max(1, A[2] if vertical else A[3])
                cov_b = ov / max(1, B[2] if vertical else B[3])
                if min(cov_a, cov_b) >= 0.7:
                    union(i, j)
                    changed = True
                elif max(cov_a, cov_b) >= 0.8:
                    # 相邻真实列可能共享少量几何范围。强制零重叠会
                    # 把宽列裁成窄缝，导致整列笔画被切掉；字符归属
                    # 会按中心/墨迹重叠处理，因此保留两列的完整范围。
                    continue
                else:
                    # 部分重叠也保留；中点硬切会切断边缘字。
                    continue
        if not changed:
            break

    # 并查集簇 → 并集框；退化框（裁没）丢弃
    clusters: dict[int, list[int]] = {}
    for i in range(n):
        clusters.setdefault(find(i), []).append(i)
    out: list[tuple[int, int, int, int]] = []
    for members in clusters.values():
        ms = [rects[i] for i in members if rects[i][2] > 4 and rects[i][3] > 4]
        if not ms:
            continue
        if vertical:
            x1 = min(r[0] for r in ms)
            x2 = max(r[0] + r[2] for r in ms)
            y1 = min(r[1] for r in ms)
            y2 = max(r[1] + r[3] for r in ms)
        else:
            y1 = min(r[1] for r in ms)
            y2 = max(r[1] + r[3] for r in ms)
            x1 = min(r[0] for r in ms)
            x2 = max(r[0] + r[2] for r in ms)
        out.append((x1, y1, x2 - x1, y2 - y1))
    out.sort(key=lambda r: (-r[0], -r[1]) if vertical else (-r[1], -r[0]))
    _log(f"[diag:line-dedup] line_det boxes {n} -> {len(out)} after overlap resolve")
    return out




def _split_char_rect_at_strip_seams(
    rect: tuple[int, int, int, int],
    strips: list[tuple[int, int]],
    mask: np.ndarray | None,
    image_w: int,
    image_h: int,
    orientation: str,
) -> list[tuple[int, int, int, int]]:
    """按真实墨迹把一个跨列字框拆成各列的完整字框。

    YOLO 偶尔会把同一水平位置的两个竖排字（尤其是正文与夹注）
    检成一个宽框。直接把宽框裁到某一列会切掉字；直接保留又会把
    两列文字送进同一次识别。只有在框确实跨过两个条带、且每个条带
    内都有足够墨迹时，才按墨迹外接框拆分，否则原框原样保留。
    """
    if mask is None or orientation == "horizontal":
        return [rect]
    x, y, w, h = (int(v) for v in rect)
    x2, y2 = x + w, y + h
    candidates: list[tuple[int, int, int, int, int]] = []
    for ss, sl in strips:
        se = ss + sl
        ov = min(x2, se) - max(x, ss)
        if ov <= 0 or ov < max(4, min(w, sl) * 0.16):
            continue
        pad = max(2, min(image_w, image_h) // 500)
        # 条带本身可能只覆盖字形主体的一侧，向两边留少量安全边距，
        # 让 _tight_rect 依据墨迹决定最终边界。
        tx1 = max(0, ss - pad)
        tx2 = min(image_w, se + pad)
        ty1 = max(0, y - pad)
        ty2 = min(image_h, y2 + pad)
        roi = mask[ty1:ty2, tx1:tx2]
        ink = int(np.count_nonzero(roi)) if roi.size else 0
        if ink < max(18, int(w * h * 0.004)):
            continue
        tight = _tight_rect(mask, tx1, tx2, ty1, ty2, pad, image_w, image_h)
        if tight is not None:
            candidates.append((*tight, ink))
    if len(candidates) < 2:
        return [rect]
    total = sum(c[4] for c in candidates)
    # 仅当两个子域共同解释了原框中的主要墨迹才拆，避免栏线/噪声触发。
    original = int(np.count_nonzero(mask[max(0, y):min(image_h, y2), max(0, x):min(image_w, x2)]))
    if total < max(30, int(original * 0.45)):
        return [rect]
    return [(c[0], c[1], c[2], c[3]) for c in candidates]




def _filter_isolated_yolo_noise(
    detections: list[tuple[tuple[int, int, int, int], float]],
    image_path: str,
    image_w: int,
    image_h: int,
    orientation: str,
) -> list[tuple[tuple[int, int, int, int], float]]:
    """Remove isolated low-scale detector boxes outside a column's text span.

    A detector box is not rejected merely because it is narrow: punctuation and
    small annotations are valid.  We only remove a small/low-ink box when the
    same cross-axis band contains several normal character boxes and the box is
    separated from them by a large reading-axis gap.  This catches a page-edge
    speck at the tail of a short column without shrinking a real adjacent column
    or forcing all columns to have the same height.
    """
    if len(detections) < 3:
        return detections
    try:
        mask = _text_mask_for_refinement(image_path)
    except Exception as exc:
        _log(f"[diag:yolo-noise] mask unavailable: {exc}")
        return detections
    if mask is None or mask.ndim != 2:
        return detections

    vertical = orientation != "horizontal"
    h, w = mask.shape[:2]
    rect_data: list[dict[str, float | int | bool]] = []
    axis_sizes: list[float] = []
    ink_values: list[float] = []
    for rect, score in detections:
        x, y, rw, rh = (int(v) for v in rect)
        x1, y1 = max(0, x), max(0, y)
        x2, y2 = min(w, x + rw), min(h, y + rh)
        roi = mask[y1:y2, x1:x2]
        ink = int(np.count_nonzero(roi)) if roi.size else 0
        axis_size = float(rh if vertical else rw)
        cross_size = float(rw if vertical else rh)
        axis_center = float(y + rh / 2.0 if vertical else x + rw / 2.0)
        cross_center = float(x + rw / 2.0 if vertical else y + rh / 2.0)
        rect_data.append({
            "rect": rect,
            "score": float(score),
            "ink": ink,
            "axis_size": axis_size,
            "cross_size": cross_size,
            "axis_center": axis_center,
            "cross_center": cross_center,
        })
        if ink > 0:
            axis_sizes.append(axis_size)
            ink_values.append(float(ink))
    if not ink_values:
        return detections

    med_axis = float(np.median(axis_sizes)) if axis_sizes else 0.0
    med_ink = float(np.median(ink_values)) if ink_values else 0.0
    # A candidate is “small” only relative to the current page/model output;
    # fixed pixel thresholds alone fail on high-resolution scans and small-note
    # columns.  Keep a generous floor for genuine tiny punctuation.
    small_ink = max(24.0, med_ink * 0.12)
    small_axis = max(12.0, med_axis * 0.45)
    gap_limit = max(2.0 * med_axis, 120.0)
    kept: list[tuple[tuple[int, int, int, int], float]] = []
    dropped: list[tuple[int, int, int, int]] = []

    for item in rect_data:
        rect = item["rect"]  # type: ignore[assignment]
        if not (
            float(item["ink"]) <= small_ink
            or float(item["axis_size"]) <= small_axis
        ):
            kept.append((rect, float(item["score"])))  # type: ignore[arg-type]
            continue

        x, y, rw, rh = (int(v) for v in rect)  # type: ignore[arg-type]
        c1 = x if vertical else y
        c2 = x + rw if vertical else y + rh
        peers: list[dict[str, float | int | bool]] = []
        for other in rect_data:
            if other is item:
                continue
            # A peer must belong to the same physical column/row.  Overlap is
            # measured on the cross axis so neighboring columns cannot provide
            # false support for a page-edge speck.
            orct = other["rect"]  # type: ignore[assignment]
            ox, oy, ow, oh = (int(v) for v in orct)  # type: ignore[arg-type]
            o1 = ox if vertical else oy
            o2 = ox + ow if vertical else oy + oh
            overlap = max(0, min(c2, o2) - max(c1, o1))
            if overlap < max(4.0, 0.18 * min(c2 - c1, o2 - o1)):
                continue
            # Only normal-sized peers are useful evidence.  A cluster of
            # equally tiny specks must not turn itself into a valid column.
            if float(other["ink"]) > small_ink and float(other["axis_size"]) > small_axis:
                peers.append(other)
        if len(peers) < 2:
            kept.append((rect, float(item["score"])))  # type: ignore[arg-type]
            continue
        nearest = min(
            abs(float(item["axis_center"]) - float(peer["axis_center"]))
            for peer in peers
        )
        if nearest > gap_limit:
            dropped.append(rect)  # type: ignore[arg-type]
        else:
            kept.append((rect, float(item["score"])))  # type: ignore[arg-type]

    if dropped:
        _log(
            f"[diag:yolo-noise] drop {len(dropped)} isolated detector box(es) "
            f"med_axis={med_axis:.1f} med_ink={med_ink:.0f} gap>{gap_limit:.0f}: "
            f"{dropped[:8]}"
        )
    return kept




def _group_yolo_char_rects_into_lines(
    char_rects: list[tuple[int, int, int, int]],
    image_w: int,
    image_h: int,
    image_path: str | None = None,
    orientation: str = "vertical",
) -> list[list[tuple[int, int, int, int]]]:
    if not char_rects:
        return []

    # 层级顺序（主区>段>行>字）：
    # ① 行模型启用时行框用模型输出，字框按中心点归属行；
    # ② 否则先按整页墨迹投影划出行条带（与字检测无关），
    #    字检测框按中心归入条带、只提供行内字几何；完全没有字落入的
    #    条带照样成行（行框取条带内墨迹范围）——字检测漏检不影响行
    #    完整性，这正是"先划行、再对行做单字检测"的顺序。
    # 行模型按竖排列训练，横排页输出不可信——横排直接走条带投影。
    if image_path is not None and orientation != "horizontal":
        line_boxes = _predict_detection_layer("line_det", image_path, image_w, image_h)
        if line_boxes:
            # 同列重复框/跨列宽框先解析成互不重叠的框（见
            # _resolve_overlapping_line_boxes），再按中心归字
            resolved = _resolve_overlapping_line_boxes(
                [lb[0] for lb in line_boxes], orientation
            )
            groups: list[list[tuple[int, int, int, int]]] = [[] for _ in resolved]
            leftovers: list[tuple[int, int, int, int]] = []
            for rect in char_rects:
                cx, cy = rect[0] + rect[2] / 2, rect[1] + rect[3] / 2
                placed = False
                for gi, lrect in enumerate(resolved):
                    if lrect[0] <= cx <= lrect[0] + lrect[2] and lrect[1] <= cy <= lrect[1] + lrect[3]:
                        groups[gi].append(rect)
                        placed = True
                        break
                if not placed:
                    leftovers.append(rect)
            grouped = [g for g in groups if g]
            # 未落入任何行框的字各自成行，避免丢字
            grouped.extend([[r] for r in leftovers])
            _log(
                f"[custom-model] line_det grouping: {len(line_boxes)} model lines -> "
                f"{len(resolved)} after overlap resolve, "
                f"{len(leftovers)} unassigned chars"
            )
            return grouped

    if image_path is not None:
        strips = _vertical_line_strips(image_path, image_w, image_h, orientation)
        if strips:
            horizontal = orientation == "horizontal"
            mask = _text_mask_for_refinement(image_path)
            strip_groups: list[list[tuple[int, int, int, int]]] = [[] for _ in strips]
            for rect in char_rects:
                # 竖排按字框中心 x 归列；横排按中心 y 归行
                center = (
                    rect[1] + rect[3] / 2 if horizontal else rect[0] + rect[2] / 2
                )
                best = -1
                best_dist = 1e9
                for si, (ss, sl) in enumerate(strips):
                    if ss <= center <= ss + sl:
                        best_dist, best = 0.0, si
                        break
                    # A detector box in the white gutter often straddles the
                    # edge of a neighbouring column.  Choosing the nearest
                    # *edge* biases it toward the previous strip (the edge
                    # distances are smaller), merging two real columns.  The
                    # strip centre is the stable ownership signal; the box
                    # itself is kept intact and may still be split later when
                    # both strips contain substantial ink.
                    dist = abs(center - (ss + sl / 2.0))
                    if dist < best_dist:
                        best_dist, best = dist, si
                tol = max(rect[3] / 2 if horizontal else rect[2] / 2, 8.0)
                # A YOLO box can end just before the projection strip starts
                # (the detector trims a faint edge stroke).  Do not drop that
                # character merely because its centre is in the white gutter:
                # when the nearest strip centre is within roughly one box
                # width, assign it to that strip.  The old edge-distance rule
                # assigned the same case to the previous strip and widened it
                # across two real columns.
                cross_size = rect[3] if horizontal else rect[2]
                gutter_tol = max(tol, float(cross_size) * 1.5)
                if best >= 0 and best_dist <= gutter_tol:
                    # 先尝试把确实跨过两个条带的宽框按真实墨迹拆开。
                    # 拆分失败时保留原框，绝不为了消除重叠而硬裁窄。
                    pieces = _split_char_rect_at_strip_seams(
                        tuple(int(v) for v in rect),
                        strips,
                        mask,
                        image_w,
                        image_h,
                        orientation,
                    )
                    if len(pieces) == 1:
                        strip_groups[best].append(pieces[0])
                    else:
                        for piece in pieces:
                            pcx = piece[0] + piece[2] / 2
                            pbest = min(
                                range(len(strips)),
                                key=lambda si: abs(
                                    pcx - (strips[si][0] + strips[si][1] / 2)
                                ),
                            )
                            strip_groups[pbest].append(piece)
            # 无字落入的条带也成行：行框取条带内墨迹的紧致范围
            grouped2: list[list[tuple[int, int, int, int]]] = []
            for si, (ss, sl) in enumerate(strips):
                # 页边连续细线有时被字检测器误报成两三个“字框”。
                # 只过滤贴边、很窄且逐行只有 1~4 个墨点的条带；真正的
                # 贴边文字通常具有较高行内墨量，不会满足这一组合条件。
                cross_limit = image_h if horizontal else image_w
                if (
                    (ss <= 0 or ss + sl >= cross_limit)
                    and sl <= max(28, int(cross_limit * 0.03))
                    and mask is not None
                ):
                    edge_mask = (
                        mask[ss:ss + sl, :]
                        if horizontal
                        else mask[:, ss:ss + sl]
                    ) > 0
                    row_ink = edge_mask.sum(axis=1 if horizontal else 1)
                    if (
                        float(np.mean(row_ink > 0)) >= 0.70
                        and float(np.median(row_ink)) <= 4.0
                    ):
                        _log(
                            f"[diag:line-strips] drop edge ruling strip "
                            f"start={ss} width={sl}"
                        )
                        continue
                if strip_groups[si]:
                    grouped2.append(strip_groups[si])
                    continue
                if mask is not None:
                    # 行框取条带内墨迹的紧致范围。两处与正文条带不同：
                    # ① 标点尾（竖排尾列/横排行尾）的墨迹可小到 8~10px
                    # （、·），_tight_rect 的 6x10 下限会整个丢掉；② 带内
                    # 散落的噪点不能撑大行框——按面积 ≥8 的连通块取
                    # 阅读轴方向的范围再收紧。
                    strip_mask = (
                        (mask[ss:ss + sl, :] > 0).astype(np.uint8)
                        if horizontal
                        else (mask[:, ss:ss + sl] > 0).astype(np.uint8)
                    )
                    num_labels, _labels, stats, _ = cv2.connectedComponentsWithStats(
                        strip_mask, connectivity=8,
                    )
                    comps = [
                        i for i in range(1, num_labels)
                        if int(stats[i, cv2.CC_STAT_AREA]) >= 8
                    ]
                    if comps:
                        if horizontal:
                            r1 = min(int(stats[i, cv2.CC_STAT_LEFT]) for i in comps)
                            r2 = max(
                                int(stats[i, cv2.CC_STAT_LEFT]) + int(stats[i, cv2.CC_STAT_WIDTH])
                                for i in comps
                            )
                        else:
                            r1 = min(int(stats[i, cv2.CC_STAT_TOP]) for i in comps)
                            r2 = max(
                                int(stats[i, cv2.CC_STAT_TOP]) + int(stats[i, cv2.CC_STAT_HEIGHT])
                                for i in comps
                            )
                    else:
                        r1, r2 = 0, (image_w if horizontal else image_h)
                    # _tight_piece(mask, x1, x2, y1, y2, ...)：竖排 x 段是
                    # 条带、y 段是墨迹紧致范围；横排对调
                    if horizontal:
                        tight = _tight_piece(
                            mask, r1, r2, ss, ss + sl,
                            max(2, min(image_w, image_h) // 500), image_w, image_h,
                        )
                    else:
                        tight = _tight_piece(
                            mask, ss, ss + sl, r1, r2,
                            max(2, min(image_w, image_h) // 500), image_w, image_h,
                        )
                    if tight is not None and tight[2] >= 3 and tight[3] >= 6:
                        grouped2.append([tight])
            _log(
                f"[diag:line-strips] strips={len(strips)} "
                f"with_chars={sum(1 for g in strip_groups if g)} lines={len(grouped2)}"
            )
            return grouped2

    # 投影不可用（mask 缺失等）时退回字框聚类成行：竖排按中心 x 聚列、
    # 横排按中心 y 聚行
    if orientation == "horizontal":
        heights = [hh for _, _, _, hh in char_rects]
        median_h = float(np.median(heights)) if heights else max(8.0, image_h / 40)
        y_tolerance = max(10.0, median_h * 0.75)
        sorted_h = sorted(char_rects, key=lambda r: r[1] + r[3] / 2)
        row_groups: list[list[tuple[int, int, int, int]]] = []
        for rect in sorted_h:
            cy = rect[1] + rect[3] / 2
            best_index = -1
            best_distance = 1e9
            for idx, group in enumerate(row_groups):
                group_cy = float(np.median([r[1] + r[3] / 2 for r in group]))
                distance = abs(cy - group_cy)
                if distance < best_distance:
                    best_distance = distance
                    best_index = idx
            if best_index >= 0 and best_distance <= y_tolerance:
                row_groups[best_index].append(rect)
            else:
                row_groups.append([rect])
        rows: list[list[tuple[int, int, int, int]]] = []
        for group in row_groups:
            if group:
                group.sort(key=lambda r: r[0])
                rows.append(group)
        return rows

    widths = [w for _, _, w, _ in char_rects]
    median_w = float(np.median(widths)) if widths else max(8.0, image_w / 40)
    x_tolerance = max(10.0, median_w * 0.75)
    sorted_rects = sorted(char_rects, key=lambda r: r[0] + r[2] / 2)
    groups2: list[list[tuple[int, int, int, int]]] = []

    for rect in sorted_rects:
        cx = rect[0] + rect[2] / 2
        best_index = -1
        best_distance = 1e9
        for idx, group in enumerate(groups2):
            group_cx = float(np.median([r[0] + r[2] / 2 for r in group]))
            distance = abs(cx - group_cx)
            if distance < best_distance:
                best_distance = distance
                best_index = idx
        if best_index >= 0 and best_distance <= x_tolerance:
            groups2[best_index].append(rect)
        else:
            groups2.append([rect])

    lines = []
    for group in groups2:
        if not group:
            continue
        group.sort(key=lambda r: r[1])
        gx1 = min(r[0] for r in group)
        gx2 = max(r[0] + r[2] for r in group)
        gy1 = min(r[1] for r in group)
        gy2 = max(r[1] + r[3] for r in group)
        if gx2 - gx1 > image_w * 0.25 and gy2 - gy1 < image_h * 0.25:
            lines.append(group)
            continue
        if len(group) >= 1:
            lines.append(group)
    return lines
