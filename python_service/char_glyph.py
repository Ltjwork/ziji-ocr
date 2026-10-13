# -*- coding: utf-8 -*-
"""楷体字形与匹配（从 char_verify 拆出）：LXGW 字模渲染、字形特征缓存、
点集对齐/骨架变形/采样与拓扑-形状打分。char_verify.py 仍为门面。"""
import base64
import json
import math
import os
import time
import unicodedata
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from segmenter import _imread, _text_mask_for_refinement
import registry_io
from char_skeleton import (CANVAS, _letterbox_square, CHAMFER_NORM, HARD_FAIL_DIFF, HARD_FAIL_RATIO, MATCH_FULL, MATCH_RADIUS, REL_TOL, SAMPLE_FULL, SAMPLE_RADIUS, SAMPLE_TARGET, TOPO_TOL, TOPO_WEIGHT, W_MATCH, W_SHAPE, W_TOPO, _normalize, _prepare, _skeleton, _topology, _minutiae, _stroke_width)



                          # （细笔画被误吃）即停止
# --- 对齐搜索（阶段 B：霍夫投票 + 相似变换网格） -------------------------
ALIGN_PAIR_RADIUS = 24    # 类型化候选点对的先验半径（128px 画布）


ALIGN_VOTE_BIN = 2        # 平移投票 bin 宽（px）


ALIGN_ROTATIONS = (-6.0, -4.0, -2.0, 0.0, 2.0, 4.0, 6.0)   # 旋转网格（度）


ALIGN_SCALES = (0.92, 0.96, 1.0, 1.04, 1.08)               # 等比缩放网格


ALIGN_IDENTITY_BONUS = 0.02  # 恒等变换偏好：几乎同分时不过拟合到非恒等


ALIGN_GRID_TRIGGER = 0.5  # 恒等对齐的峰值解释力低于此值才展开旋转/缩放


                          # verify_templates.EMB_STRONG）

# -------------------------------------------------------------------------

_FONT_CANDIDATES = [
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "resources", "fonts", "LXGWWenKai-Regular.ttf"),
]


_font = None


_font_failed = False


_glyph_cache: dict[str, tuple] = {}  # char -> (skeleton, topology, minutiae)




def _load_font():
    """楷体字形来源：随包分发的 LXGW WenKai（OFL，繁简均全）。"""
    global _font, _font_failed
    if _font is not None or _font_failed:
        return _font
    for path in _FONT_CANDIDATES:
        try:
            _font = ImageFont.truetype(path, 80)
            return _font
        except Exception:
            continue
    _font_failed = True
    return None




def _simplify_char(ch: str) -> str | None:
    """繁体缺字时经 OpenCC 转简体回退；一对多映射取首字。"""
    try:
        from opencc import OpenCC
        converted = OpenCC("t2s").convert(ch)
        return converted[:1] if converted else None
    except Exception:
        return None




def _render_glyph(ch: str) -> np.ndarray | None:
    """渲染单字为二值图（墨=255），紧裁切；缺字经繁转简回退。"""
    font = _load_font()
    if font is None:
        return None
    canvas = Image.new("L", (128, 128), 0)
    draw = ImageDraw.Draw(canvas)
    draw.text((64, 64), ch, fill=255, font=font, anchor="mm")
    binary = np.asarray(canvas)
    if binary.max() <= 0:
        fallback = _simplify_char(ch)
        if not fallback or fallback == ch:
            return None
        return _render_glyph(fallback)
    ys, xs = np.nonzero(binary)
    return binary[ys.min(): ys.max() + 1, xs.min(): xs.max() + 1]




def _glyph_features(ch: str):
    """字形（清洗后图, 骨架, 拓扑, 特征点, 笔宽）按字缓存（刻本页同字
    重复率高）；清洗后图供 debug 叠加图显示原字形底色，笔宽供墨迹收细
    的目标宽度。"""
    if ch in _glyph_cache:
        return _glyph_cache[ch]
    glyph = _render_glyph(ch)
    result = None
    if glyph is not None:
        prepared = _prepare(glyph)
        skel = _skeleton(prepared)
        result = (prepared, skel, _topology(skel), _minutiae(skel),
                  _stroke_width(prepared))
    _glyph_cache[ch] = result
    if len(_glyph_cache) > 3000:
        _glyph_cache.pop(next(iter(_glyph_cache)))
    return result




# --- 三层比对 -------------------------------------------------------------


def _topo_score(ink: dict, glyph: dict) -> tuple[float, dict]:
    """拓扑计数分（0-1）+ 明细。

    容差随量相对化（详见 REL_TOL 注释）；硬失败只看洞数与连通块，
    且要求绝对差 >= HARD_FAIL_DIFF 且占总量的 HARD_FAIL_RATIO 以上
    ——"昌→日"级结构错误仍硬拦截，复杂字的书法性波动交给分数层。"""
    diffs, penalty, total_w, hard_fail = {}, 0.0, 0.0, False
    for key, weight in TOPO_WEIGHT.items():
        a, b = int(ink.get(key, 0)), int(glyph.get(key, 0))
        diff = abs(a - b)
        diffs[key] = diff
        tol = max(TOPO_TOL[key], int(round(max(a, b) * REL_TOL[key])))
        penalty += weight * max(0.0, diff - tol)
        total_w += weight
        if (key in ("holes", "components") and diff >= HARD_FAIL_DIFF
                and diff >= HARD_FAIL_RATIO * max(a, b, 1)):
            hard_fail = True
    score = float(np.clip(1.0 - penalty / total_w, 0.0, 1.0))
    return score, {"diffs": diffs, "hard_fail": hard_fail}




def _apply_similarity(pts: np.ndarray, rot_deg: float, scale: float,
                      offset: tuple[float, float] = (0.0, 0.0)) -> np.ndarray:
    """对点集施加绕画布中心的旋转 + 等比缩放 + 平移。

    公式与 cv2.getRotationMatrix2D 完全一致（x' = α(x-cx)+β(y-cy)+cx，
    y' = -β(x-cx)+α(y-cy)+cy，α=scale·cosθ、β=scale·sinθ），保证点集
    变换与骨架 warpAffine 同一几何。"""
    if pts is None or not len(pts):
        return pts
    a = math.radians(rot_deg)
    alpha, beta = math.cos(a) * scale, math.sin(a) * scale
    cx = cy = CANVAS / 2.0
    x, y = pts[:, 0] - cx, pts[:, 1] - cy
    tx, ty = offset
    return np.column_stack((
        alpha * x + beta * y + cx + tx,
        -beta * x + alpha * y + cy + ty))




def _vote_offset(src: np.ndarray, dst: np.ndarray):
    """霍夫平移投票：候选点对（距离 <= ALIGN_PAIR_RADIUS）对 (dx,dy)
    按 ALIGN_VOTE_BIN 宽投票，返回 (峰值解释力, 最优平移)。

    峰值解释力 = 最大 bin 票数 / min(n_src, n_dst)——归一后跨变换可比；
    峰值 bin 内取候选对偏移均值做亚 bin 精化。无候选对返回 (0, 零平移)。"""
    if src is None or dst is None or not len(src) or not len(dst):
        return 0.0, np.zeros(2)
    d = np.linalg.norm(src[:, None, :] - dst[None, :, :], axis=2)
    si, di = np.nonzero(d <= ALIGN_PAIR_RADIUS)
    if not len(si):
        return 0.0, np.zeros(2)
    offs = src[si] - dst[di]
    bins = np.floor(offs / ALIGN_VOTE_BIN).astype(int)
    keys = bins[:, 0] * 100003 + bins[:, 1]
    uniq, counts = np.unique(keys, return_counts=True)
    peak_bin = int(uniq[np.argmax(counts)])
    peak = float(counts.max()) / min(len(src), len(dst))
    sel = keys == peak_bin
    return peak, offs[sel].mean(axis=0)




def _align_glyph_points(ink_e, ink_j, glyph_e, glyph_j):
    """估计作用于字形点集的最优相似变换，返回 ((rot, scale, dx, dy),
    峰值解释力)。

    指纹式对齐：类型化点对霍夫投票出平移，(rot, scale) 网格取峰值解释
    力最高者；恒等变换带 ALIGN_IDENTITY_BONUS 偏好（几乎同分时不把
    噪声拟合成旋转）。恒等对齐解释力足够（>= ALIGN_GRID_TRIGGER）时
    不展开网格——多数字是正立的，省下 35 倍投票开销。等比缩放不改变
    字内比例（未/末的横长差异保留），歪斜扫描与整体比例偏差被吸收。"""
    def evaluate(rot: float, sc: float):
        e = _apply_similarity(glyph_e, rot, sc)
        j = _apply_similarity(glyph_j, rot, sc)
        votes = []
        for ink, gl in ((ink_e, e), (ink_j, j)):
            if ink is not None and gl is not None and len(ink) and len(gl):
                votes.append(_vote_offset(ink, gl))
        if not votes:
            return 0.0, np.zeros(2)
        peak = sum(v[0] for v in votes) / len(votes)
        best_off = max(votes, key=lambda v: v[0])[1]
        return peak, best_off

    peak, off = evaluate(0.0, 1.0)
    best = (0.0, 1.0, float(off[0]), float(off[1]))
    best_score = peak + ALIGN_IDENTITY_BONUS
    if peak < ALIGN_GRID_TRIGGER:
        for rot in ALIGN_ROTATIONS:
            if rot == 0.0:
                continue
            for sc in ALIGN_SCALES:
                if sc == 1.0:
                    continue
                p, o = evaluate(rot, sc)
                if p > best_score:
                    best_score = p
                    best = (rot, sc, float(o[0]), float(o[1]))
    return best, best_score




def _warp_skeleton(skel: np.ndarray, align: tuple) -> np.ndarray:
    """按对齐变换 warp 骨架图（最近邻，保二值）。恒等变换原样返回。"""
    rot, sc, dx, dy = align
    if rot == 0.0 and sc == 1.0 and dx == 0.0 and dy == 0.0:
        return skel
    m = cv2.getRotationMatrix2D((CANVAS / 2.0, CANVAS / 2.0), rot, sc)
    m[0, 2] += dx
    m[1, 2] += dy
    return cv2.warpAffine(skel, m, (skel.shape[1], skel.shape[0]),
                          flags=cv2.INTER_NEAREST)




def _sample_skeleton(skel: np.ndarray) -> np.ndarray:
    """骨架均匀采样点集（扫描序等距抽样到 ~SAMPLE_TARGET 点），供封闭
    字的 L1 兜底——口/日/田的骨架是纯环，无端点无分叉，minutiae 匹配
    退化为形状采样匹配。"""
    pts = np.argwhere(skel > 0)[:, ::-1].astype(np.float64)
    if len(pts) <= SAMPLE_TARGET:
        return pts
    idx = np.linspace(0, len(pts) - 1, SAMPLE_TARGET).astype(int)
    return pts[idx]




def _match_score(ink_ends: list, ink_juncs: list,
                 glyph_ends: list, glyph_juncs: list,
                 ink_skel: np.ndarray | None = None,
                 glyph_skel: np.ndarray | None = None):
    """类型化特征点匹配（指纹式 minutiae），返回 (分数|None, 对齐变换)。

    端点↔端点、分叉↔分叉各自做最近邻双向匹配，按各类型点数加权平均；
    匹配前先做霍夫投票+相似变换网格对齐（替代旧的质心平移钳制）——歪
    斜扫描与整体比例偏差不再系统性拉低分数。一侧类型无点返回该类型
    None（数量失配交给拓扑层，不在位置层重复惩罚）。

    两边完全无类型点（全封闭字）改用骨架均匀采样点集做同款"对齐+半径
    内点率"兜底，让封闭字的 L1 不再整层缺失、全字分数同权重可比；采
    样匹配半径与归一阈值单独标定（风格容错比 minutiae 松）。"""
    ink_e = np.asarray(ink_ends, dtype=np.float64) if ink_ends else None
    ink_j = np.asarray(ink_juncs, dtype=np.float64) if ink_juncs else None
    glyph_e = np.asarray(glyph_ends, dtype=np.float64) if glyph_ends else None
    glyph_j = np.asarray(glyph_juncs, dtype=np.float64) if glyph_juncs else None
    identity = (0.0, 1.0, 0.0, 0.0)
    if (ink_e is None and ink_j is None and glyph_e is None and glyph_j is None):
        if ink_skel is None or glyph_skel is None:
            return None, identity
        s_ink, s_gl = _sample_skeleton(ink_skel), _sample_skeleton(glyph_skel)
        if not len(s_ink) or not len(s_gl):
            return None, identity
        (rot, sc, dx, dy), _ = _align_glyph_points(s_ink, None, s_gl, None)
        gl = _apply_similarity(s_gl, rot, sc, (dx, dy))
        d = np.linalg.norm(s_ink[:, None, :] - gl[None, :, :], axis=2)
        forward = float((d.min(axis=1) <= SAMPLE_RADIUS).mean())
        backward = float((d.min(axis=0) <= SAMPLE_RADIUS).mean())
        raw = (forward + backward) / 2.0
        return float(min(1.0, raw / SAMPLE_FULL)), (rot, sc, dx, dy)

    (rot, sc, dx, dy), _ = _align_glyph_points(ink_e, ink_j, glyph_e, glyph_j)
    if glyph_e is not None:
        glyph_e = _apply_similarity(glyph_e, rot, sc, (dx, dy))
    if glyph_j is not None:
        glyph_j = _apply_similarity(glyph_j, rot, sc, (dx, dy))

    def one_type(src: np.ndarray, dst: np.ndarray) -> float | None:
        """单类型双向匹配率（经 MATCH_FULL 归一拉伸）；一侧无点返回
        None（数量失配交给拓扑层，不在位置层重复惩罚）。"""
        if src is None or dst is None:
            return None
        d = np.linalg.norm(src[:, None, :] - dst[None, :, :], axis=2)
        forward = float((d.min(axis=1) <= MATCH_RADIUS).mean())
        backward = float((d.min(axis=0) <= MATCH_RADIUS).mean())
        raw = (forward + backward) / 2.0
        return float(min(1.0, raw / MATCH_FULL))

    scores, weights = [], []
    for score, pts in (
        (one_type(ink_e, glyph_e), len(ink_ends) + len(glyph_ends)),
        (one_type(ink_j, glyph_j), len(ink_juncs) + len(glyph_juncs)),
    ):
        if score is not None:
            scores.append(score)
            weights.append(max(1, pts))
    if not scores:
        return None, identity
    return float(np.average(scores, weights=weights)), (rot, sc, dx, dy)




def _shape_score(ink_skel: np.ndarray, glyph_skel: np.ndarray) -> float:
    """双向 Chamfer 距离形状分：骨架点集互测平均最近距离，归一到 0-1。"""
    ink_pts = np.argwhere(ink_skel > 0)[:, ::-1].astype(np.float64)
    glyph_pts = np.argwhere(glyph_skel > 0)[:, ::-1].astype(np.float64)
    if not len(ink_pts) or not len(glyph_pts):
        return 0.0
    dist_ink = cv2.distanceTransform(
        (ink_skel == 0).astype(np.uint8), cv2.DIST_L2, 3)
    dist_glyph = cv2.distanceTransform(
        (glyph_skel == 0).astype(np.uint8), cv2.DIST_L2, 3)
    d1 = dist_glyph[ink_pts[:, 1].astype(int), ink_pts[:, 0].astype(int)].mean()
    d2 = dist_ink[glyph_pts[:, 1].astype(int), glyph_pts[:, 0].astype(int)].mean()
    chamfer = (d1 + d2) / 2.0
    return float(np.clip(1.0 - chamfer / CHAMFER_NORM, 0.0, 1.0))


def _debug_overlay(ink_mask: np.ndarray, ink_skel: np.ndarray,
                   glyph_mask: np.ndarray, glyph_skel: np.ndarray,
                   ink_ends: list, ink_juncs: list,
                   glyph_ends: list, glyph_juncs: list,
                   orig_gray: np.ndarray | None = None,
                   glyph_mask_aligned: np.ndarray | None = None,
                   glyph_skel_aligned: np.ndarray | None = None,
                   glyph_ends_aligned: list | None = None,
                   glyph_juncs_aligned: list | None = None) -> str:
    """四联对照图（1024×256 = 4 格 256×256）：
    格1 原图裁字——原始扫描图按字框裁切的灰度原貌（识别时看到的字）；
    格2 墨迹侧——浅灰=二值化墨迹笔画、蓝=墨迹骨架、蓝圈=特征点；
    格3 印刷字侧——淡红=楷体印刷字笔画、红=字形骨架、红圈=特征点；
    格4 重叠——两侧同画布叠加（字形侧已按对齐变换旋转/缩放/平移）：
    墨迹底灰、字形底淡红、蓝/红骨架、绿=两骨架接近处（<3px），特征
    点圈保留（红侧为对齐后位置）。
    小圈=端点、大圈=分叉簇质心。四格同一裁切窗口与 letterbox 几何，
    逐格对照"原图 → 二值墨迹 → 骨架 → 与印刷字重叠"。PNG base64。"""
    size = 256
    up = lambda m: cv2.resize(m, (size, size), interpolation=cv2.INTER_NEAREST)
    ink_m, ink = up(ink_mask), up(ink_skel)
    glyph_m, glyph = up(glyph_mask), up(glyph_skel)

    scale = size / float(CANVAS)

    def draw_minutiae(cell, ends, juncs, color):
        for x, y in ends:
            cv2.circle(cell, (int(round(x * scale)),
                              int(round(y * scale))),
                       4, color, 1, cv2.LINE_AA)
        for x, y in juncs:
            cv2.circle(cell, (int(round(x * scale)),
                              int(round(y * scale))),
                       7, color, 2, cv2.LINE_AA)

    # 格1：原始扫描裁字（纸色/墨色原样）
    orig_panel = np.full((size, size, 3), 255, dtype=np.uint8)
    if orig_gray is not None and orig_gray.size:
        orig_up = cv2.resize(_letterbox_square(orig_gray), (size, size),
                             interpolation=cv2.INTER_AREA)
        orig_panel = cv2.cvtColor(orig_up, cv2.COLOR_GRAY2BGR)

    # 格2：墨迹原字 + 骨架 + 特征点
    ink_panel = np.full((size, size, 3), 255, dtype=np.uint8)
    ink_panel[ink_m > 0] = (225, 225, 225)
    ink_panel[ink > 0] = (255, 0, 0)
    draw_minutiae(ink_panel, ink_ends, ink_juncs, (255, 0, 0))

    # 格3：楷体印刷字 + 骨架 + 特征点
    glyph_panel = np.full((size, size, 3), 255, dtype=np.uint8)
    glyph_panel[glyph_m > 0] = (240, 222, 222)
    glyph_panel[glyph > 0] = (0, 0, 255)
    draw_minutiae(glyph_panel, glyph_ends, glyph_juncs, (0, 0, 255))

    # 格4：整体重叠（字形侧用对齐后的骨架/特征点——匹配与形状分正是
    # 在这套几何上算的，绿=实际参与打分的重合）
    overlay = np.full((size, size, 3), 255, dtype=np.uint8)
    glyph_m4 = (up(glyph_mask_aligned)
                if glyph_mask_aligned is not None else glyph_m)
    glyph4 = up(glyph_skel_aligned) if glyph_skel_aligned is not None else glyph
    ends4 = glyph_ends_aligned if glyph_ends_aligned is not None else glyph_ends
    juncs4 = (glyph_juncs_aligned
              if glyph_juncs_aligned is not None else glyph_juncs)
    overlay[ink_m > 0] = (225, 225, 225)         # 原字墨迹：浅灰
    overlay[glyph_m4 > 0] = (245, 232, 232)      # 楷体字形：淡红底
    overlay[ink_m > 0] = (225, 225, 225)         # 墨迹底优先（重叠处灰盖淡红）
    dist_ink = cv2.distanceTransform((ink == 0).astype(np.uint8),
                                     cv2.DIST_L2, 3)
    dist_glyph = cv2.distanceTransform((glyph4 == 0).astype(np.uint8),
                                       cv2.DIST_L2, 3)
    near = (dist_glyph <= 3.0) & (ink > 0) & (glyph4 > 0)
    overlay[near] = (0, 200, 0)
    overlay[(ink > 0) & ~near] = (255, 0, 0)
    overlay[(glyph4 > 0) & ~near & (ink == 0)] = (0, 0, 255)
    draw_minutiae(overlay, ink_ends, ink_juncs, (255, 0, 0))
    draw_minutiae(overlay, ends4, juncs4, (0, 0, 255))

    combo = np.hstack([orig_panel, ink_panel, glyph_panel, overlay])
    ok, buf = cv2.imencode(".png", combo)
    return base64.b64encode(buf).decode("ascii") if ok else ""
