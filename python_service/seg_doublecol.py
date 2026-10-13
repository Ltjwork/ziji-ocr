# -*- coding: utf-8 -*-
"""双栏体系（从 segmenter 拆出）：双栏子区域判定、角色、伪件过滤、
跨栏行拆分与重复碎片清理。segmenter.py 仍为门面。"""
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
from seg_imaging import (_to_block, _runs)
from seg_refine import _tight_piece





def _char_body_blocks(
    side_mask: np.ndarray,
    med_h: float,
    width_frac: float = 0.35,
) -> int:
    """侧带（段内单侧墨迹）里的"字身块"个数。

    字身块 = 连续非零行段，块高 ≥0.25×字高（字高尺度，与段长无关——
    8 字长段的块若按段高算会要求 96px 高，字永远达不到），且块内最宽
    一行的墨宽 ≥width_frac×侧带宽。夹注小字块又宽又高，每侧至少两
    块；部首缝的侧影要么是细笔画条（每行墨宽只有侧宽的两三成），要
    么整段只有一个块，都凑不满。"""
    if side_mask.size == 0:
        return 0
    cols = np.nonzero(side_mask.any(axis=0))[0]
    if cols.size == 0:
        return 0
    side_w = int(cols[-1] - cols[0]) + 1
    prof = side_mask.sum(axis=1)
    min_block_h = max(3, int(med_h * 0.25))
    need_w = side_w * width_frac
    good = 0
    for a, b in _runs(prof > 0, min_len=min_block_h):
        if int(prof[a:b].max()) >= need_w:
            good += 1
    return good




def _two_char_note_span(
    sub: np.ndarray,
    rx1: int,
    ry1: int,
    a: int,
    b: int,
    cx: int,
    med_h: float,
) -> bool:
    """两行小注（每侧仅两字）的段长放行判定，配合 3×字高主门槛使用。

    主门槛按整列根字高（≈正文字号）设 3×，而每侧只有两字的短注整段
    只有 ~2.9×根字高（实测 1790460224098 第 287 页"即天|姚星"注
    222px/77.5、夹具 xingnan 129px/45），差一口气，在候选阶段就被
    静默丢弃——整页识别里该列被当单列读成交错乱串。放行改按段内小字
    自己的尺度：段长 ≥2.2×段内两侧字符带高中位，且 ≥1.7×根字高。
    切穿正文部首缝的假段两侧是同号大字（带高≈根字高），1.0~1.6×的
    实测段长两条都过不了；碎笔画假段带高极小、第一条形同虚设，但 ⑧
    的"每侧 ≥2 个 ≥0.45×上段字距整字块"会拦住。"""
    heights: list[int] = []
    for band in (
        sub[a - ry1:b - ry1, :cx - rx1],
        sub[a - ry1:b - ry1, cx - rx1 + 1:],
    ):
        for s, e in _runs(band.sum(axis=1) > 0, min_len=2):
            if e - s >= max(6, int(med_h * 0.3)):
                heights.append(e - s)
    if not heights:
        return False
    side_med = float(np.median(heights))
    return (b - a) >= max(int(2.2 * side_med), 24) and (b - a) >= int(1.7 * med_h)


def _extend_note_segment_edges(
    sub: np.ndarray,
    la: int,
    lb: int,
    lgx1: int,
    lgx2: int,
    lgmid: int,
    med_h: float,
) -> tuple[int, int]:
    """缝隙段边界外扩到被同段夹注末字截断的墨迹，返回新 [la, lb)。

    段边界取自缝隙列的空白跑：末字（斷/使类密字）的笔画跨进缝隙带会
    把跑提前截断，边界落进夹注字中间——实测 287 页左列斷 y459..537、
    右列使 y457..532，空白跑却在 496 断掉，斷 的字框被就近分进下方
    正文行（注释行缺字、正文行框上沿压住注释行）。外扩只认"已经压在
    边界上"的侧带墨迹段、每步只推进到最近一个跨界段端点、逐步重验
    （缝隙对面的正文永远隔着整段空白）；且每步三重校验，任一不过即
    停在原边界：
    ① 缝隙带在该区间的墨迹：占比 ≤0.35（只对 ≥0.25×字高的窗口生效
       ——边界处 2~5px 蹭墨在小窗里占比噪声极大，实测 426 页末字
       1521..1605 因此漏补），且最长连续跨缝墨迹 ≤0.35×字高——通栏
       正文一笔横穿整条缝隙（实测 367 页上段正文 70px 连续），夹注
       末字最多蹭到缝边（斷 实测 11px）；
    ② 跨界每一侧在该区间的墨宽 ≤0.8×上段通栏墨宽：通栏字占满整条，
       夹注字只占半条（④ 的 0.42× 是下限，这里防上界；夹具实测末字
       底部墨宽 22~23 vs 通栏 57）；
    ③ 单步外扩量 ≤1.2×字高：单步至多越过一个字高，再多必是正文。"""
    tol = max(3, int(med_h * 0.12))
    cap = int(med_h * 1.2) + tol
    gap_rows = sub[:, lgx1:lgx2].any(axis=1)
    left_rows = sub[:, :lgmid].sum(axis=1) > 0
    right_rows = sub[:, lgmid:].sum(axis=1) > 0
    hc = np.nonzero(sub[:la].any(axis=0))[0]
    head_w = int(hc[-1] - hc[0]) + 1 if hc.size else 0

    def accept(lo: int, hi: int) -> bool:
        if hi <= lo:
            return False
        win_gap = gap_rows[lo:hi]
        if win_gap.size:
            # 占比检查只对 ≥0.25×字高的窗口生效：边界处 2~5px 的蹭墨
            # 在 8px 小窗里占比能到 0.4+，把整条外扩拦死（实测 426 页
            # 末字 1521..1605 因此漏补）；窗口够大时占比才是稳定量。
            if hi - lo >= max(int(med_h * 0.25), 6) and float(win_gap.mean()) > 0.35:
                return False
            # 最长连续跨缝墨迹 ≤0.35×字高：通栏正文一笔就横穿整条缝隙
            # （实测 367 页上段正文 70px 连续），夹注末字最多蹭到缝边。
            longest = 0
            run = 0
            for v in win_gap:
                run = run + 1 if v else 0
                longest = max(longest, run)
            if longest > max(int(med_h * 0.35), 5):
                return False
        for band in (sub[:, :lgmid], sub[:, lgmid:]):
            cols = np.nonzero(band[lo:hi].any(axis=0))[0]
            if cols.size and head_w and (cols[-1] - cols[0] + 1) > head_w * 0.8:
                return False
        return True

    def side_runs() -> list[tuple[int, int]]:
        return _runs(left_rows, min_len=2) + _runs(right_rows, min_len=2)

    cur = lb
    while True:
        # 渐进步进：每次只扩到最近一个跨界段的端点（长粘连段不会一步
        # 超出单步上限而整步作废），逐步推进、每步重验三重守卫。
        nxt = None
        for s, e in side_runs():
            if e > cur and s - tol <= cur:
                nxt = e if nxt is None else min(nxt, e)
        if nxt is None or nxt - cur > cap or not accept(cur, nxt):
            break
        cur = nxt
    lb2 = cur

    cur = la
    while True:
        nxt = None
        for s, e in side_runs():
            if s < cur and e + tol >= cur:
                nxt = s if nxt is None else max(nxt, s)
        if nxt is None or cur - nxt > cap or not accept(nxt, cur):
            break
        cur = nxt
    la2 = cur
    return la2, lb2


def _double_column_sub_rects(
    rect: tuple[int, int, int, int],
    mask: np.ndarray | None,
    orientation: str = "vertical",
    horizontal_dir: str = "rtl",
    vertical_dir: str = "ttb",
    allow_short: bool = False,
) -> list[tuple[int, int, int, int]]:
    """行框内并排子列结构检测，返回按阅读顺序排列的行框列表。

    古籍竖排常见的"通栏正文段下方并排两条窄列"版式（正文缩行后旁注
    小字、或双行小字夹注）在行切分里是同一条带：条带投影/行模型都把
    整条当一个行框，行内按阅读轴投影切字会把两条子列的字按 y 序交错
    输出。此函数要求候选缝隙同时满足一组强结构判据（全部基于真实页面
    误报教训，缺一不可）：
    ① 空白带沿阅读轴持续 ≥3 个字高（allow_short 时 ≥1.2 个字高，
       供单行识别拆两行小注），带内墨迹 ≤2%；
    ② 段内两侧各有 ≥2 个字符带（字内空隙两侧各只有 1 个带，栏线残
       留是 1 条长带）；
    ③ 通栏桥接：缝隙正上方 2 个字高窗内，"缝隙带、左侧、右侧同时有
       墨"的跨缝行累计 ≥0.35×字高——即上段通栏字的笔画横穿缝隙。正文
       列的自然竖缝（相邻字笔画间的 1~2px 细缝）是整条贯通的，上方没
       有跨缝墨迹，真实页面 15 页实测仅此一条判据即可压掉全部误报；
    ④ 段内两侧墨宽各 ≥0.42×上段通栏墨宽（真夹注子列约为通栏的一半，
       实测 0.49~0.65；相邻字部首缝对齐的假缝实测只有 0.37），且
       ≥0.3 个字高（排除栏线残留等细条）；
    ⑤ 缝隙带宽度 ≥0.07×字高——真夹注两列是分开刻/排的（实测
       0.10×字高），左右结构字的部首缝实测只有 0.06（现代页"搭配，
       始"）；
    ⑥ 条带只容"一字余"：条带宽 ≤3×全条带字高且 ≤2.5×上段字高——真
       夹注条带宽约 1~2.2 倍字高；页缘噪声/表格格子条带实测是字高的
       5~20 倍，一条即排除；
    ⑦ 夹注字小于正文：两侧段内字符带高度的 75 分位 ≤0.75×上段最高字
       带（木刻字粘连/疏朗字断裂都会让单带失真，取分位与最大值最稳；
       真夹注实测 0.27~0.65，同号字部首缝假缝实测 0.94）。

    命中时把行框拆成 [上段通栏, 右子列, 左子列, 下段通栏]（竖排 rtl；
    ltr 对调左右。横排转置后同构，子行次序跟随 vertical_dir）。子列段
    以缝隙段实际范围 [a, b) 为界——夹注可出现在列中段，其下还有正文；
    上段/下段允许递归再拆（嵌套双列段），子列本身永不递归（防"双列里
    再拆双列"）。无该结构时返回 [rect]。"""
    try:
        x, y, w, h = (int(v) for v in rect)
    except (TypeError, ValueError):
        return [rect]
    if mask is None or mask.ndim != 2 or w <= 4 or h <= 4:
        return [(x, y, w, h)]
    vertical = orientation != "horizontal"
    work = mask if vertical else np.ascontiguousarray(mask.T)
    wh, ww = work.shape[:2]
    wx1, wy1 = max(0, x), max(0, y)
    wx2, wy2 = min(ww, x + w), min(wh, y + h)
    if wx2 - wx1 < 8 or wy2 - wy1 < 8:
        return [(x, y, w, h)]
    # 子列先后：工作域里"高 x 侧先读"当 reverse_cross 为真。竖排跟随
    # horizontal_dir（rtl=右列先）；横排转置后子行次序跟随 vertical_dir。
    reverse_cross = (horizontal_dir == "rtl") if vertical else (vertical_dir == "btt")
    ctx: dict[str, float] = {}

    def split_depth(rx1: int, ry1: int, rx2: int, ry2: int, depth: int):
        sub = work[ry1:ry2, rx1:rx2] > 0
        whole = (rx1, ry1, rx2 - rx1, ry2 - ry1)
        if sub.size == 0 or depth > 2:
            return [whole]
        rows = np.nonzero(sub.any(axis=1))[0]
        cols = np.nonzero(sub.any(axis=0))[0]
        if rows.size == 0 or cols.size == 0:
            return [whole]
        ty1, ty2 = ry1 + int(rows[0]), ry1 + int(rows[-1]) + 1
        tx1, tx2 = rx1 + int(cols[0]), rx1 + int(cols[-1]) + 1
        if depth == 0:
            root_bands = _runs(sub.sum(axis=1) > 0, min_len=2)
            # 字高以整行根区域估计并全程复用：子区域里字带易粘连/断裂，
            # 就地重估会让 min_seg 缩到字内空隙也能过。
            ctx["med_h"] = (
                float(np.median([b - a for a, b in root_bands])) if root_bands else 0.0
            )
        med_h = ctx.get("med_h", 0.0)
        if med_h < 6:
            return [whole]
        # 段长下限：整页自动识别 3×字高；单行识别（用户明确指向该行）
        # allow_short 放宽到 2.5×字高。两行小注（每侧仅两字，"姚即|星天"
        # 实测 2.9×）按段内小字尺度经 _two_char_note_span 放行；切穿单字
        # 部件缝的假缝段实测只有 1.0~1.6×（假段两侧是同号大字，双尺度
        # 都过不了；更短的假段与真短注在几何上不可分，仍按"宁可漏拆、
        # 不可误拆"取舍：漏拆可行内重切/手画两框补救）。
        min_seg = max(int(2.5 if allow_short else 3.0) * int(med_h), 24)
        min_side_w = max(6, int(med_h * 0.3))
        band_min = max(2, int(med_h * 0.15))
        min_bridge_h = max(2, int(med_h * 0.35))
        # 缝宽下限：真夹注两列是分开排的（实测 0.10~0.14×字距）；左右
        # 结构字的部件缝是发丝级（实测 2~3px = 0.06~0.07×字距）。
        min_gap_w = max(3, round(med_h * 0.09))
        # ⑤ 预筛：页缘噪声/表格格子条带宽是字高的 5~20 倍，一条即排除
        # （跨双列宽框的精确排除在候选循环里按上段字高判——注文占多数
        # 的条带 med_h 会被小字拉低，用 med_h 会误杀真夹注）。
        if (tx2 - tx1) > 3.0 * med_h:
            return [whole]
        # 候选按空隙长度降序逐个做全量校验（空白带扩展 + 桥接 + 侧宽），
        # 第一个通过全部校验的胜出。不能只验最长者：栏线残留与子列间
        # 的空隙可能比真缝隙更长（实测 4x 样张 2072px vs 1931px），最长
        # 者被校验否决后必须回退到次优候选，而不是放弃拆分。
        cands: list[tuple[int, int, int, int]] = []
        for cx in range(tx1, tx2):
            colmask = sub[:, cx - rx1]
            for a, b in _runs(~colmask, min_len=1):
                if b - a < min_seg and not _two_char_note_span(
                    sub, rx1, ry1, a, b, cx, med_h
                ):
                    continue
                if colmask[a:b].sum() > max(2, int((b - a) * 0.02)):
                    continue
                if sub[a:b, :cx - rx1].sum() < 8 or sub[a:b, cx - rx1 + 1:].sum() < 8:
                    continue
                # 每侧段内至少 2 个"字身块"：连续墨行块本身够高（≥0.2×段
                # 高）且块内最宽行墨 ≥0.55×侧宽——小字块又宽又高；部首缝
                # 的侧影是细笔画条（"陀"的阝每行只有 3~6px 墨）或只有一
                # 个块（"斗加"），都凑不满两块。字内空隙两侧各只有 1 带、
                # 栏线残留是 1 条长带，同样被排除。
                left_body = _char_body_blocks(
                    sub[a:b, :cx - rx1], med_h
                )
                right_body = _char_body_blocks(
                    sub[a:b, cx - rx1 + 1:], med_h
                )
                if left_body < 2 or right_body < 2:
                    continue
                cands.append((b - a, a + ry1, b + ry1, cx))
        cands.sort(reverse=True)
        chosen: tuple[int, int, int, int, int, int] | None = None
        for run_len, a, b, gx in cands:
            tol = max(2, int((b - a) * 0.02))
            seg_cols = sub[a - ry1:b - ry1].sum(axis=0)
            blank = seg_cols <= tol
            gx1 = gx
            while gx1 - 1 >= tx1 and blank[gx1 - 1 - rx1]:
                gx1 -= 1
            gx2 = gx + 1
            while gx2 < tx2 and blank[gx2 - rx1]:
                gx2 += 1
            gmid = (gx1 + gx2) // 2
            # 缝宽下限：真夹注两列是分开刻/排的，缝宽实测 0.10×字高；
            # 左右结构字的部首缝只有 0.06×字高（现代页"搭配，始"实测）。
            if gx2 - gx1 < min_gap_w:
                if os.environ.get("OCR_DC_DEBUG"):
                    print(f"DC-REJ gap_w gap={gx2-gx1}<{min_gap_w} seg={a}..{b}")
                continue
            # ③ 通栏桥接：缝隙正上方（2 个字高窗）内的"跨缝行"总数达到
            # 0.35×字高——跨缝行 = 该行缝隙带、左侧、右侧同时有墨，即
            # 通栏字的笔画横穿缝隙的行。正文列的自然竖缝（相邻字笔画间
            # 的 1~2px 细缝）整条贯通、上方没有跨缝墨迹。木刻字笔画在
            # 单列上断续（一块只有几行），按行累计、不要求连续。
            up_y1 = max(0, a - ry1 - int(2 * med_h))
            win = sub[up_y1:a - ry1, :]
            crossing = (
                win[:, gx1 - rx1:gx2 - rx1].any(axis=1)
                & win[:, :gx1 - rx1].any(axis=1)
                & win[:, gx2 - rx1:].any(axis=1)
            )
            if int(np.count_nonzero(crossing)) < min_bridge_h:
                continue
            # ④ 段内两侧墨宽（只量 [a,b) 段内，不吃段外墨迹），相对上段
            # 通栏墨宽有下限，且不低于 0.3 个字高。
            seg = sub[a - ry1:b - ry1, :]
            lc = np.nonzero(seg[:, :gmid - rx1].any(axis=0))[0]
            rc = np.nonzero(seg[:, gmid - rx1:].any(axis=0))[0]
            if lc.size == 0 or rc.size == 0:
                continue
            left_w = int(lc[-1] - lc[0]) + 1
            right_w = int(rc[-1] - rc[0]) + 1
            if left_w < min_side_w or right_w < min_side_w:
                continue
            hc = np.nonzero(sub[:a - ry1].any(axis=0))[0]
            if hc.size:
                head_w = int(hc[-1] - hc[0]) + 1
                # 真夹注子列 ≈ 通栏宽的一半（实测 0.49~0.65）；相邻字部首
                # 缝对齐的假缝实测只有 0.37，0.42 一条即分界。
                if left_w < head_w * 0.42 or right_w < head_w * 0.42:
                    continue
            # 上段（正文）字高基准：最高字带。字带粘连（木刻）会把两三
            # 个字并成一带、疏朗字（三/川）会断成碎带，单带中位/分位都
            # 不可靠；最高带 ≥ 单字高，作分母只会更宽裕，方向安全。
            head_bands = _runs(sub[:a - ry1].sum(axis=1) > 0, min_len=band_min)
            if not head_bands:
                continue
            # 上段"单字尺度"用字距（相邻字带起点的中位差）：最高/中位字带
            # 会被竖向粘连膨胀（现代印刷列连续墨迹把两三字并成一带，实
            # 测把 head_h 撑到 2~3 倍），⑦ 的"夹注字小于正文"随之失效、
            # 半字切片被判成小字夹注（page_059 普通列被拆四块的根因）。
            # 字带起点不受粘连影响（粘连只是少了一个起点），中位差稳健。
            starts = [aa for aa, _bb in head_bands]
            deltas = [t - s for s, t in zip(starts, starts[1:]) if t > s]
            if deltas:
                head_h = float(np.median(deltas))
            else:
                head_h = float(max(bb - aa for aa, bb in head_bands))
            if head_h < 6:
                continue
            # ⑤ 条带只容"一列余"（相对上段字高）：真夹注实测 0.97~1.65
            # 倍；跨双列宽框（相邻两条正文列被并成一条）实测 ≥2.2 倍字
            # 高——拆了会把两条正文列跺成碎块、与邻列行框互相重叠；表
            # 格格子列宽常是字高的十倍。
            if (tx2 - tx1) > 2.0 * head_h:
                if os.environ.get("OCR_DC_DEBUG"):
                    print(f"DC-REJ cap stripw={tx2-tx1}>{2.0*head_h:.0f} head_h={head_h:.0f}")
                continue
            # ⑦ 夹注字小于正文：两侧段内字符带高度的 75 分位 ≤0.75×上段
            # 最高字带。左右结构字部首缝连续对齐的假缝两侧是同号字
            # （实测比值 0.94），真夹注实测 0.27~0.65。
            lb2 = _runs(sub[a - ry1:b - ry1, :gmid - rx1].sum(axis=1) > 0, min_len=band_min)
            rb2 = _runs(sub[a - ry1:b - ry1, gmid - rx1:].sum(axis=1) > 0, min_len=band_min)
            if not lb2 or not rb2:
                continue
            side_h = max(
                float(np.percentile([bb - aa for aa, bb in lb2], 75)),
                float(np.percentile([bb - aa for aa, bb in rb2], 75)),
            )
            if side_h > head_h * 0.75:
                if os.environ.get("OCR_DC_DEBUG"):
                    print(f"DC-REJ size side_h={side_h:.0f}>{0.75*head_h:.0f} head_h={head_h:.0f}")
                continue
            # ⑧ 两侧子列各需 ≥2 个整字级字块（高 ≥0.45×上段字距）：真夹
            # 注两侧是成串的完整小字（实测 0.6~0.8×字距）；切穿单字部件
            # 缝时两侧只是同一字的左右部件碎片（实测 9~17px ≈ 0.3×字
            # 距）——字带高度在小字/碎笔画下列不可靠，块高下限直接按
            # 上段字距计。
            need_block_h = max(4, int(head_h * 0.45))
            l_big = sum(1 for aa, bb in lb2 if bb - aa >= need_block_h)
            r_big = sum(1 for aa, bb in rb2 if bb - aa >= need_block_h)
            if l_big < 2 or r_big < 2:
                if os.environ.get("OCR_DC_DEBUG"):
                    print(f"DC-REJ blocks l={l_big} r={r_big} need_h={need_block_h} seg={a}..{b}")
                continue

            if os.environ.get("OCR_DC_DEBUG"):
                print(
                    f"DC-ACCEPT rect={rect} gap={gx1}..{gx2} seg={a}..{b} "
                    f"med_h={med_h:.0f} head_h={head_h:.0f} side_h={side_h:.0f} "
                    f"lw={int(lc[-1]-lc[0])+1} rw={int(rc[-1]-rc[0])+1} "
                    f"stripw={tx2-tx1}"
                )
            chosen = (run_len, a, b, gx1, gx2, gmid)
            break
        if chosen is None:
            return [whole]
        _, a, b, gx1, gx2, _gmid = chosen
        # 段边界外扩：末字笔画跨进缝隙带时空白跑提前截断，边界会切进
        # 夹注末字（见 _extend_note_segment_edges）。
        la2, lb2 = _extend_note_segment_edges(
            sub, a - ry1, b - ry1, gx1 - rx1, gx2 - rx1, _gmid - rx1, med_h
        )
        if la2 != a - ry1 or lb2 != b - ry1:
            a, b = la2 + ry1, lb2 + ry1
            _log(
                f"[diag:double-col] 段边界外扩至 y={a}..{b}"
                f"（补被缝隙墨迹截断的末字）"
            )
        _log(
            f"[diag:double-col] rect={rect} 拆子列 gap x={gx1}..{gx2} "
            f"段 y={a}..{b} 字高~{med_h:.0f}"
        )
        # 子列段以缝隙段实际范围 [a, b) 为界：夹注可在列中段，其下还有
        # 正文（下段通栏）。子列本身不再递归；上段/下段可继续拆嵌套。
        # 元组统一 (x, y, w, h) 格式。
        first = (gx2, a, tx2 - gx2, b - a)
        second = (tx1, a, gx1 - tx1, b - a)
        head = split_depth(tx1, ty1, tx2, a, depth + 1) if a - ty1 >= med_h * 0.6 else []
        tail = split_depth(tx1, b, tx2, ty2, depth + 1) if ty2 - b >= med_h * 0.6 else []
        lo, hi = (first, second) if reverse_cross else (second, first)
        return head + [lo, hi] + tail

    parts = split_depth(wx1, wy1, wx2, wy2, 0)
    if len(parts) <= 1:
        return [(x, y, w, h)]
    if not vertical:
        # 工作域 (x, y, w, h) 转回原图 (y, x, h, w)
        return [(p[1], p[0], p[3], p[2]) for p in parts]
    return parts




def double_column_roles(subs, orientation='vertical'):
    """Parallel pieces share a reading-axis interval, even without head/tail."""
    # Three-piece layouts are the established [通栏正文, 右注, 左/下正文]
    # shape used by the regional recognizer and old annotations. Preserve its
    # compatibility while four-piece layouts expose both note columns.
    if len(subs) == 3:
        return ['body', 'annotation', 'body']
    if len(subs) <= 2:
        return ['body' for _ in subs]
    axis = 1 if orientation != 'horizontal' else 0
    size = axis + 2
    return [
        'annotation' if any(
            i != j and min(a[axis] + a[size], b[axis] + b[size])
            - max(a[axis], b[axis]) > 0.5 * min(a[size], b[size])
            for j, b in enumerate(subs)
        ) else 'body'
        for i, a in enumerate(subs)
    ]




def _filter_spurious_double_column_parts(
    subs: list[tuple[int, int, int, int]],
    mask: np.ndarray,
    orientation: str,
) -> list[tuple[int, int, int, int]]:
    """Drop a very thin bleed/noise strip before it becomes a child line.

    A real夹注 column is normally at least about one third of the body
    column's cross-axis width.  Detector bleed beside a body column is much
    thinner and shares the same reading-axis ink.  Keeping that strip creates
    the extra narrow line seen in the editor; it is not a recognition-safe
    column.  The conservative threshold leaves genuine small-note columns
    intact and only filters an extreme outlier.
    """
    if len(subs) < 2:
        return subs
    cross = [r[2] if orientation != 'horizontal' else r[3] for r in subs]
    largest = max(cross)
    if largest <= 0:
        return subs
    keep: list[tuple[int, int, int, int]] = []
    removed_any = False
    for rect, width in zip(subs, cross):
        # A two-piece split is the common shape of a false "extra column":
        # one real body column plus a very thin bleed strip.  Keep the
        # threshold conservative so a genuine small annotation (roughly a
        # third of the body width or more) is still preserved.
        # A two-piece split can still be a main column plus a thin bleed strip.
        # The old 0.25 cutoff kept the page-84 failure (19px against a 66px
        # column), creating a second recognition line from edge fragments.
        # Collapsing the pair restores the original full-width line; it never
        # narrows either side. Wider, genuine note columns remain split.
        min_ratio = 0.32
        if width >= largest * min_ratio:
            keep.append(rect)
            continue
        x, y, w, h = rect
        roi = mask[max(0, y):min(mask.shape[0], y + h),
                   max(0, x):min(mask.shape[1], x + w)]
        if roi.size == 0:
            continue
        # A genuine tiny punctuation/body segment can still survive when it
        # has dense independent ink; a sparse bleed strip is discarded.
        density = float(np.count_nonzero(roi)) / float(roi.size)
        # In the two-piece case a thin part is almost always a bleed strip;
        # accepting it merely because the bleed is dark would reintroduce the
        # narrow extra column.  Three-piece layouts retain the older density
        # escape hatch for genuinely ink-dense punctuation/annotation parts.
        if len(subs) > 2 and density >= 0.12:
            keep.append(rect)
            continue
        elif os.environ.get('OCR_DC_DEBUG'):
            print(
                f"DC-REJ thin-part rect={rect} width={width} "
                f"largest={largest} density={density:.3f}"
            )
        removed_any = True
    if not removed_any:
        return subs
    # Removing one part means the detector found a spurious narrow strip
    # rather than a complete body/annotation/body structure. Collapse back to
    # one parent rectangle; keeping the remaining pieces would still create
    # the unwanted extra column (and could narrow a real column at its edge).
    if len(keep) < len(subs):
        x1 = min(r[0] for r in subs)
        y1 = min(r[1] for r in subs)
        x2 = max(r[0] + r[2] for r in subs)
        y2 = max(r[1] + r[3] for r in subs)
        return [(x1, y1, x2 - x1, y2 - y1)]
    return keep




def split_double_column_lines(
    lines: list[dict[str, Any]],
    mask: np.ndarray | None,
    orientation: str = "vertical",
    horizontal_dir: str = "rtl",
    vertical_dir: str = "ttb",
    allow_short: bool = False,
) -> list[dict[str, Any]]:
    """行级后处理：把含并排子列结构的行拆成多个单列行并返回新列表。

    对每行调 _double_column_sub_rects；命中时按子框就近分配字框（旧切
    分留下的跨子列粘连框中心可能落在缝隙上，就近归属保证不丢字框）、
    行框收紧到子带墨迹（无字框但有墨迹的子带照常成行，识别链路会兜
    底切字），并按列表顺序重编 line_no/col/order 与行内字序。未命中任
    何结构时原样返回。"""
    if not lines or mask is None or mask.ndim != 2:
        return lines
    img_h, img_w = mask.shape[:2]
    pad = max(2, min(img_w, img_h) // 500)
    out: list[dict[str, Any]] = []
    split_cnt = 0
    for ln in lines:
        if not isinstance(ln, dict):
            continue
        # 所有行统一携带版面角色字段；未命中双列结构的普通行保持 body。
        ln.setdefault("layout_role", "body")
        ln.setdefault("column_group", "")
        ln.setdefault("parent_line_id", "")
        ln.setdefault("layout_confidence", 0.0)
        if ln.get('double_col_split') or ln.get('layout_role') == 'annotation':
            out.append(ln)
            continue
        try:
            rect = (
                int(ln.get("x", 0)), int(ln.get("y", 0)),
                int(ln.get("w", 0)), int(ln.get("h", 0)),
            )
        except (TypeError, ValueError):
            out.append(ln)
            continue
        subs = _double_column_sub_rects(
            rect, mask, orientation, horizontal_dir, vertical_dir, allow_short
        )
        subs = _filter_spurious_double_column_parts(subs, mask, orientation)
        if len(subs) <= 1:
            out.append(ln)
            continue
        split_cnt += 1
        chars = [c for c in (ln.get("chars") or []) if isinstance(c, dict)]
        base_id = str(ln.get("id") or "line")
        # 子框生成前把父行 ID 记录到源行，便于 /analyze_layout 将建议
        # 与用户当前行稳定关联。
        for c in chars:
            c.setdefault("parent_line_id", base_id)
        # 字框按中心点就近归属（不算严格"落入"：旧切分留下的跨子列粘连
        # 框中心可能落在缝隙/边界上，半开区间首-match 会把字整批丢掉）。
        part_chars: list[list[dict[str, Any]]] = [[] for _ in subs]
        for c in chars:
            try:
                cx = float(c.get("x", 0)) + float(c.get("w", 0)) / 2.0
                cy = float(c.get("y", 0)) + float(c.get("h", 0)) / 2.0
            except (TypeError, ValueError):
                continue
            best, best_d = 0, float("inf")
            for si, (sx, sy, sw, sh) in enumerate(subs):
                dx = max(sx - cx, 0.0, cx - (sx + sw))
                dy = max(sy - cy, 0.0, cy - (sy + sh))
                d = dx * dx + dy * dy
                if d < best_d:
                    best_d, best = d, si
            part_chars[best].append(c)
        # 中间两段是夹注子列，首尾段属于通栏正文。保留结构元数据，
        # 供 Flutter 在段落聚类与 AI 上下文中区分正文/注释。
        roles = double_column_roles(subs, orientation)
        column_group = f"dc_{base_id}"
        for si, (sx, sy, sw, sh) in enumerate(subs):
            part_chars_si = part_chars[si]
            tight = _tight_piece(mask, sx, sx + sw, sy, sy + sh, pad, img_w, img_h)
            if part_chars_si:
                bx1 = min(int(c.get("x", 0)) for c in part_chars_si)
                by1 = min(int(c.get("y", 0)) for c in part_chars_si)
                bx2 = max(int(c.get("x", 0)) + int(c.get("w", 0)) for c in part_chars_si)
                by2 = max(int(c.get("y", 0)) + int(c.get("h", 0)) for c in part_chars_si)
                bx1, by1 = max(0, bx1), max(0, by1)
                new_line = dict(ln)
                new_line["x"], new_line["y"] = bx1, by1
                new_line["w"], new_line["h"] = bx2 - bx1, by2 - by1
            elif tight is not None:
                new_line = dict(ln)
                new_line["x"], new_line["y"] = tight[0], tight[1]
                new_line["w"], new_line["h"] = tight[2], tight[3]
            else:
                continue
            new_line["id"] = f"{base_id}_d{si}"
            # 拆分行框已贴各自子带墨迹：后续行框外扩（区域墨迹扩展、
            # Kraken 识别前行框外扩）必须跳过——上段通栏框沿阅读轴外扩
            # 会顺着连续墨迹吃进下方双列段，把拆开的结构又合回去。
            new_line["double_col_split"] = True
            new_line["column_group"] = column_group
            new_line["parent_line_id"] = base_id
            new_line["layout_role"] = roles[si]
            if roles[si] == 'annotation':
                for c in part_chars_si:
                    if c.get('type') != 'ignore':
                        c['type'] = 'annotation'
            # 结构检测由多个几何判据共同通过；这是布局置信度而非 OCR 置信度。
            new_line["layout_confidence"] = 0.92
            new_line["chars"] = part_chars_si
            new_line["text"] = "".join(str(c.get("text") or "") for c in part_chars_si)
            out.append(new_line)
        _log(
            f"[diag:double-col] 行 {base_id} 拆为 {len(subs)} 行 "
            f"({rect[0]},{rect[1]},{rect[2]},{rect[3]})"
        )
    if not split_cnt:
        return lines

    # 按拆分结果的列表顺序重编号（不做跨行重排——上段/右列/左列的
    # 阅读序已由 _double_column_sub_rects 给出），行内字按阅读轴排序。
    for i, ln in enumerate(out):
        ln["line_no"] = i
        ln_chars = ln.get("chars") or []
        if (ln.get("orientation") or orientation) == "horizontal":
            if horizontal_dir == "rtl":
                ln_chars.sort(key=lambda c: -(float(c.get("x", 0)) + float(c.get("w", 0)) / 2.0))
            else:
                ln_chars.sort(key=lambda c: float(c.get("x", 0)) + float(c.get("w", 0)) / 2.0)
        else:
            if vertical_dir == "btt":
                ln_chars.sort(key=lambda c: -(float(c.get("y", 0)) + float(c.get("h", 0)) / 2.0))
            else:
                ln_chars.sort(key=lambda c: float(c.get("y", 0)) + float(c.get("h", 0)) / 2.0)
        for j, c in enumerate(ln_chars):
            c["col"] = i
            c["order"] = j
            c["line_id"] = ln.get("id")
    _log(f"[diag:double-col] 共拆分 {split_cnt} 行，行数 {len(lines)} -> {len(out)}")
    return out




def drop_duplicate_fragment_lines(
    lines: list[dict[str, Any]],
    orientation: str = "vertical",
    mask: np.ndarray | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Drop a narrow detector row that repeats glyphs from a neighbouring row.

    A few-pixel safety overlap between real columns is allowed. A different
    failure is a short, narrow detector result that sits on top of a wider
    column and contains smaller boxes aligned with that column's character
    boxes. Keep the wider line and all of its geometry intact; only remove
    the redundant fragment. Explicit annotation children are never folded
    into their parent by this rule.
    """
    if len(lines) < 2:
        return lines, []
    vertical = orientation != "horizontal"

    def rect(item: dict[str, Any]) -> tuple[int, int, int, int]:
        return tuple(int(item.get(k, 0)) for k in ("x", "y", "w", "h"))

    def aligned_char_ratio(fragment: dict[str, Any], owner: dict[str, Any]) -> float:
        fragment_chars = [c for c in fragment.get("chars", []) if isinstance(c, dict)]
        owner_chars = [c for c in owner.get("chars", []) if isinstance(c, dict)]
        if mask is None or mask.ndim != 2 or len(fragment_chars) < 4 or len(owner_chars) < 4:
            return 0.0
        matched = 0
        for fc in fragment_chars:
            fx, fy, fw, fh = rect(fc)
            if fw <= 0 or fh <= 0:
                continue
            ih, iw = mask.shape[:2]
            fx1, fy1 = max(0, fx), max(0, fy)
            fx2, fy2 = min(iw, fx + fw), min(ih, fy + fh)
            if fx2 <= fx1 or fy2 <= fy1:
                continue
            fragment_ink = mask[fy1:fy2, fx1:fx2] > 0
            ink_total = int(np.count_nonzero(fragment_ink))
            if ink_total == 0:
                continue
            owner_ink = np.zeros_like(fragment_ink)
            fcross1, fcross2 = (fx, fx + fw) if vertical else (fy, fy + fh)
            fread1, fread2 = (fy, fy + fh) if vertical else (fx, fx + fw)
            fcross, fread = fcross2 - fcross1, fread2 - fread1
            if fcross <= 0 or fread <= 0:
                continue
            for oc in owner_chars:
                ox, oy, ow, oh = rect(oc)
                ocross1, ocross2 = (ox, ox + ow) if vertical else (oy, oy + oh)
                oread1, oread2 = (oy, oy + oh) if vertical else (ox, ox + ow)
                cross_overlap = min(fcross2, ocross2) - max(fcross1, ocross1)
                read_overlap = min(fread2, oread2) - max(fread1, oread1)
                if cross_overlap <= 0 or read_overlap <= 0:
                    continue
                cross_ratio = cross_overlap / max(1, min(fcross, ocross2 - ocross1))
                read_ratio = read_overlap / max(1, min(fread, oread2 - oread1))
                # A tiny border safety overlap (<12% of the small glyph) does
                # not establish duplicate ownership. Requiring alignment in
                # both axes avoids collapsing genuinely adjacent notes.
                if cross_ratio >= 0.12 and read_ratio >= 0.55:
                    ox1, oy1 = max(fx1, ox), max(fy1, oy)
                    ox2, oy2 = min(fx2, ox + ow), min(fy2, oy + oh)
                    if ox2 > ox1 and oy2 > oy1:
                        owner_ink[oy1 - fy1:oy2 - fy1, ox1 - fx1:ox2 - fx1] = True
            # Bounding rectangles can overlap even when the two columns contain
            # different ink. Only collapse a fragment when most of its actual
            # strokes are covered by the wider line's character boxes.
            shared_ink = int(np.count_nonzero(fragment_ink & owner_ink))
            if shared_ink / ink_total >= 0.70:
                matched += 1
        return matched / max(1, len(fragment_chars))

    removed: list[dict[str, Any]] = []
    removed_ids: set[int] = set()
    for i, a in enumerate(lines):
        if i in removed_ids or a.get("double_col_split") or a.get("layout_role") == "annotation":
            continue
        ax, ay, aw, ah = rect(a)
        a_cross, a_read = (aw, ah) if vertical else (ah, aw)
        if a_cross <= 0 or a_read <= 0:
            continue
        best_owner = None
        best_score = 0.0
        for j, b in enumerate(lines):
            if i == j or j in removed_ids:
                continue
            if b.get("double_col_split") or b.get("layout_role") == "annotation":
                continue
            bx, by, bw, bh = rect(b)
            b_cross, b_read = (bw, bh) if vertical else (bh, bw)
            if b_cross < a_cross * 1.8 or a_cross > b_cross * 0.4 or b_read <= 0:
                continue
            if a_read > b_read * 0.45:
                continue
            if vertical:
                cross_overlap = min(ax + aw, bx + bw) - max(ax, bx)
                read_overlap = min(ay + ah, by + bh) - max(ay, by)
            else:
                cross_overlap = min(ay + ah, by + bh) - max(ay, by)
                read_overlap = min(ax + aw, bx + bw) - max(ax, bx)
            # Require a small frame overlap rather than treating distant
            # columns as a pair. No box is ever narrowed.
            if cross_overlap < 0 or cross_overlap > max(6, round(a_cross * 0.25)):
                continue
            if read_overlap / max(1, a_read) < 0.65:
                continue
            aligned = aligned_char_ratio(a, b)
            if aligned >= 0.70 and aligned > best_score:
                best_owner, best_score = b, aligned
        if best_owner is not None:
            removed_ids.add(i)
            removed.append(a)
            _log(
                f"[diag:fragment-drop] 删除重复窄碎片 {a.get('id')} "
                f"owner={best_owner.get('id')} aligned={best_score:.2f} "
                f"保留主列完整框=({best_owner.get('x')},{best_owner.get('y')} "
                f"{best_owner.get('w')}x{best_owner.get('h')})"
            )
    if not removed_ids:
        return lines, []
    return [line for i, line in enumerate(lines) if i not in removed_ids], removed




def _merge_adjacent_line_fragments(
    lines: list[dict[str, Any]],
    orientation: str = "vertical",
) -> list[dict[str, Any]]:
    """合并检测器把同一列切成的窄碎片。

    古籍页的真实夹注列之间会留出可见的纸白缝；YOLO 偶尔把一条大字
    列的左半边单独报成 20~30 像素的窄列。若把这种碎片当成双排注释，
    后续切字就会出现一条多余列，并把真实列压窄。这里只合并满足全部
    几何条件的相邻碎片：跨阅读轴高度（或宽度）高度重合、缝隙不超过
    4 像素、窄侧不超过宽侧的 55%，且合并后的宽度不超过宽侧 1.6 倍。
    因此不会把正常有纸白间隔的两列注释合成一列，也不会强制消除安全
    边距重叠。
    """
    if len(lines) < 2:
        return lines
    vertical = orientation != "horizontal"
    # 几何相邻性按图像坐标判断；最终阅读顺序由统一排序阶段恢复。
    ordered = sorted(
        (ln for ln in lines if isinstance(ln, dict)),
        key=lambda ln: int(ln.get("x" if vertical else "y", 0)),
    )
    merged: list[dict[str, Any]] = []
    i = 0
    merge_count = 0
    while i < len(ordered):
        a = ordered[i]
        if i + 1 < len(ordered):
            b = ordered[i + 1]
            if not a.get("double_col_split") and not b.get("double_col_split") and \
                    a.get("layout_role", "body") != "annotation" and \
                    b.get("layout_role", "body") != "annotation":
                ax, ay, aw, ah = (int(a.get(k, 0)) for k in ("x", "y", "w", "h"))
                bx, by, bw, bh = (int(b.get(k, 0)) for k in ("x", "y", "w", "h"))
                if vertical:
                    cross_a, cross_b = ah, bh
                    cross_overlap = min(ay + ah, by + bh) - max(ay, by)
                    # Keep the sign: 0 means touching, negative means a
                    # safety-margin overlap.  They need different handling.
                    gap = max(bx - (ax + aw), ax - (bx + bw))
                    narrow, wide = min(aw, bw), max(aw, bw)
                    union_w = max(ax + aw, bx + bw) - min(ax, bx)
                else:
                    cross_a, cross_b = aw, bw
                    cross_overlap = min(ax + aw, bx + bw) - max(ax, bx)
                    gap = max(by - (ay + ah), ay - (by + bh))
                    narrow, wide = min(ah, bh), max(ah, bh)
                    union_w = max(ay + ah, by + bh) - min(ay, by)
                overlap_ratio = cross_overlap / max(1, min(cross_a, cross_b))
                narrow_fragment = narrow <= max(1, wide * 0.55)
                if (
                    # A positive paper-white gap distinguishes a detector
                    # fragment from two columns that merely have generous
                    # safety-margin overlap.  The latter must stay separate
                    # so recognition does not lose an annotation column.
                    # A zero-width paper gap is also a detector fragment: the
                    # narrow box touches the body box at its edge.  Real
                    # neighbouring columns retain a visible paper gap; keep
                    # negative (overlapping) safety margins separate so we do
                    # not narrow either recognition box.
                    0 <= gap <= 4
                    and overlap_ratio >= 0.75
                    and narrow_fragment
                    and union_w <= max(1, wide * 1.60)
                ):
                    keep = dict(a)
                    keep["x"] = min(ax, bx)
                    keep["y"] = min(ay, by)
                    keep["w"] = max(ax + aw, bx + bw) - keep["x"]
                    keep["h"] = max(ay + ah, by + bh) - keep["y"]
                    keep["chars"] = [
                        c for c in (a.get("chars") or []) + (b.get("chars") or [])
                        if isinstance(c, dict)
                    ]
                    keep["text"] = "".join(str(c.get("text") or "") for c in keep["chars"])
                    keep["layout_role"] = "body"
                    keep["column_group"] = ""
                    keep["parent_line_id"] = ""
                    keep["layout_confidence"] = max(
                        float(a.get("layout_confidence") or 0),
                        float(b.get("layout_confidence") or 0),
                    )
                    merged.append(keep)
                    merge_count += 1
                    _log(
                        f"[diag:fragment-merge] {a.get('id')} + {b.get('id')} "
                        f"gap={gap} cross_overlap={overlap_ratio:.2f} "
                        f"-> ({keep['x']},{keep['y']},{keep['w']},{keep['h']})"
                    )
                    i += 2
                    continue
        merged.append(a)
        i += 1
    if merge_count:
        _log(f"[diag:fragment-merge] 合并同列窄碎片 {merge_count} 组")
    return merged
