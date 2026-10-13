# -*- coding: utf-8 -*-
"""字形骨架与拓扑特征（从 char_verify 拆出）：二值化净化、细化、交叉数/
端点/骨架拓扑、笔宽与 128 画布归一。char_verify.py 仍为门面。"""
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




# --- 可调参数（回测标定区） ---------------------------------------------

CANVAS = 128             # 骨架归一化画布边长。96px 时刻本细笔画只剩


                         # 1-2px 宽，清洗/细化的数值噪声直接吃掉笔画结构
                         # （會字田框内部竖线消失即此）；128px 让细笔画
                         # 留在 3px 以上，管线余量充足。匹配半径/剪枝长
                         # 度等参数已随画布等比标定
BIN_THRESHOLD = 100      # 缩放后二值化阈值：INTER_AREA 缩细笔画会产生


                         # 灰度（255×面积比可低至 ~110），127 会把细笔画
                         # 震断，取 100 保连通
CLOSE_KERNEL = 4         # 闭运算核：粘合 <=3px 断笔缝。刻意保守：多


                         # 部件字（昌/品/二）的部件间隙在 128px 画布上
                         # 约 6-8px，更大的核会把部件粘连、连通块数产生
                         # 系统性偏差——断笔缝与部件间隙的尺度重叠是闭
                         # 运算的根本矛盾，宁少粘不误粘
NOISE_AREA_MIN = 14      # 小于此面积的前景连通域视为飞白/噪点删除


HOLE_FILL_MIN = 35       # 小洞填充：刻本墨渗粘连与楷体书法连笔都会产


HOLE_FILL_RATIO = 0.04   # 生小面积假洞（真洞如"日"内腔在 128px 画布上


                         # >=250px）；两侧对称填充后洞数才可比。真实书
                         # 页回测归因：A 组误报的主因正是两侧假洞
PRUNE_SPUR_LEN = 8       # 细化毛刺长度上限：短于此的端点短枝删除。


                         # 刻本边缘粗糙的毛刺可达 7-10px；真实最短笔画
                         # "点"在 128px 画布上 13px 以上，不会误伤
JUNCTION_RADIUS = 3      # 分叉簇凝聚半径：细化把一个交叉拉成相距 2-3px


                         # 的多个候选点，按此半径的邻接关系合并回一个
TOPO_TOL = {             # 各拓扑量的基础容差；实际容差 = max(基础值,
    "holes": 0,          # round(max(ink,glyph) * REL_TOL))：复杂字（觀/
    "endpoints": 2,      # 廟/機）笔画多、拓扑量大，同样 2 个端点的绝
    "junctions": 2,      # 对差异在简单字上是 50% 噪声、在复杂字上只
    "crossings": 2,      # 是 15%——回测证明绝对容差在复杂字上系统性
    "components": 1,     # 误报，按量的比例放宽
}


REL_TOL = {"holes": 0.34, "endpoints": 0.3, "junctions": 0.3,
           "crossings": 0.5, "components": 0.3}


HARD_FAIL_DIFF = 2       # 洞/连通块差 >=2 且占总量的 HARD_FAIL_RATIO


HARD_FAIL_RATIO = 0.5    # 以上才硬判 mismatch：昌→日（洞 4vs2，差 2 占


                         # 50%）硬拦截；論/廟这类复杂字洞差 2 只占
                         # 33-40%，是书法性波动，交给分数层。
                         # （端点/分叉的硬失败扩展经回测否决：保守到从不
                         # 触发、收紧则推高误报，维持只看洞/连通块。）
TOPO_WEIGHT = {"holes": 3.0, "endpoints": 1.0, "junctions": 2.0,
               "crossings": 2.0, "components": 1.0}


MATCH_RADIUS = 9         # 特征点最近邻匹配半径（同类型点之间，128px


                         # 画布）。R 放大会把未/末这类横长比例差异也吸
                         # 进半径（区分度归零），风格位置噪声改由
                         # MATCH_FULL 归一化吸收而不是放大半径
MATCH_FULL = 0.75        # 匹配率归一阈值：raw/MATCH_FULL 截断到 1——


                         # 手写/刻本风格下同类型特征点匹配率天然只有
                         # 0.6-0.8（笔画位置风格性偏移），错字的同类型
                         # 匹配率在 0-0.4；拉伸后风格噪声不再掉分
CHAMFER_NORM = CANVAS * 0.25   # 双向平均距离达到此值时形状分为 0


# 融合权重：特征点主导（指纹式 minutiae 思路）——拓扑计数与特征点
# 位置合计 0.8，骨架形状重叠只作 0.2 的兜底辅助。曾因回测误报把形状
# 层提到 0.5，但那是"重叠式"判定：手写/刻本风格与楷体字形对不上就
# 拉低总分，与"看结构不看风格"的设计相悖，回调为特征点主导。
W_TOPO = 0.4


W_MATCH = 0.4


W_SHAPE = 0.2


                           # 确字的分数整体抬高，错字分数分布不变，阈值带
                           # 随之上移才保持两侧分离度——回测（第五册 A/B
                           # 组 + 明刻本 B 组）：误报 36.6%→34.2%、命中
                           # 80.9%→81.1%、96.6%→95.6%

# --- 裁切门禁与笔宽归一（阶段 A） ----------------------------------------
# 墨迹裁切的两道净化（贴边跳过门禁经回测否决——密集刻本的检测框紧贴
# 墨迹、笔画顶端普遍冒出字框 2-3px，任何贴边判据都会把整页字误跳掉，
# 详见 CHANGELOG 1.0.0+22 归因记录）：
# 1. 邻字渗墨剔除——裁切图里只保留与"字框内部"相交的连通域；
# 2. 紧致化——按墨迹包围盒紧裁后再 letterbox，与字形侧（_render_glyph
#    紧裁）的中心化口径一致，消除检测框松紧带来的位置噪声。
STROKE_W_MIN = 3.0        # 笔宽归一目标下限：低于此宽不收（"會"类 2px


                          # 细笔画再收会直接消失，是收细的硬红线）
STROKE_W_TOL = 0.5        # 两侧笔宽差小于此值不动（避免无谓重阈值化）


SHRINK_MAX = 2.0          # 每侧最大剥离层数（px）：超过说明洇墨异常粗，


                          # 收太多会把边缘锯齿剥进骨架
SHRINK_LOSS_GUARD = 0.55  # 收细守卫：实际剩余墨量低于等比期望的这个比例


                          # 网格（多数字是正立的，省 35 倍投票开销）
SAMPLE_TARGET = 128       # 封闭字 L1 兜底：骨架均匀采样目标点数


SAMPLE_RADIUS = 12        # 采样点匹配半径（骨架带状，比 minutiae 宽）


SAMPLE_FULL = 0.55        # 采样匹配率的归一阈值（风格容错比 minutiae 松）




# --- 骨架管线 -------------------------------------------------------------


def _normalize(binary: np.ndarray) -> np.ndarray:
    """紧裁切字图 -> letterbox 正方形 -> CANVAS 尺寸二值图。

    letterbox 保留宽高比（"曰"扁"日"长的形状差异是比对特征，不能在
    归一化时拉伸掉）。"""
    side = max(binary.shape)
    square = np.zeros((side, side), dtype=np.uint8)
    oy, ox = (side - binary.shape[0]) // 2, (side - binary.shape[1]) // 2
    square[oy: oy + binary.shape[0], ox: ox + binary.shape[1]] = binary
    small = cv2.resize(square, (CANVAS, CANVAS), interpolation=cv2.INTER_AREA)
    return (small > BIN_THRESHOLD).astype(np.uint8) * 255




def _clean(binary: np.ndarray) -> np.ndarray:
    """清洗管线：闭运算粘断笔 → 膨胀+中值平滑+腐蚀还原（保结构的边
    缘去毛刺）→ 删小连通域噪声 → 填小洞。

    平滑用"膨胀→中值→腐蚀"而非开运算：开运算（腐蚀+膨胀）会把
    2px 宽的细笔画（"會"中部田框的内部竖线、曰部横线）整个腐蚀
    掉且膨胀不回来，实测每字丢前景 7-10%，骨架直接缺笔画；先膨胀
    把细笔画临时加到 3px 以上，中值滤波只平滑边缘锯齿（不删 ≥2px
    结构），再腐蚀回原粗细——毛刺钝化、细笔画完整保留。孤立噪点
    由中值滤波与面积过滤共同清除。"""
    k = cv2.getStructuringElement(cv2.MORPH_RECT, (CLOSE_KERNEL, CLOSE_KERNEL))
    cleaned = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, k)
    cleaned = cv2.dilate(cleaned, k)
    cleaned = cv2.medianBlur(cleaned, 3)
    cleaned = cv2.erode(cleaned, k)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(cleaned, connectivity=8)
    out = np.zeros_like(cleaned)
    for i in range(1, n):
        if stats[i, cv2.CC_STAT_AREA] >= NOISE_AREA_MIN:
            out[labels == i] = 255
    return _fill_small_holes(out)




def _fill_small_holes(binary: np.ndarray) -> np.ndarray:
    """填充面积小于 max(HOLE_FILL_MIN, 前景*HOLE_FILL_RATIO) 的洞。

    背景主连通域面积远超阈值天然跳过；96px 画布上真洞（"日"内腔）
    约 150px 以上、假洞几十像素，阈值落在两者之间。两侧（墨迹与
    字形）对称过滤，洞数差异才反映结构差异而非墨渗/书法噪声。"""
    inv = (binary == 0).astype(np.uint8)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(inv, connectivity=4)
    ink_px = int((binary > 0).sum())
    min_area = max(HOLE_FILL_MIN, int(ink_px * HOLE_FILL_RATIO))
    out = binary.copy()
    for i in range(1, n):
        if stats[i, cv2.CC_STAT_AREA] <= min_area:
            out[labels == i] = 255
    return out




def _thin(binary: np.ndarray) -> np.ndarray:
    """Zhang-Suen 细化（numpy 向量化，两步迭代直到稳定）。

    输入/输出均为 0/255 uint8。标准条件：2<=B(P)<=6（非端点非孤立）、
    A(P)==1（8 邻域 0→1 跳变数为 1，保证不撕裂连通性）、步 1 删南/东
    边界点、步 2 删北/西边界点。"""
    img = (binary > 0).astype(np.uint8)
    for _ in range(200):  # 96px 画布细化至多几十轮，200 为保险上限
        # 两步各自独立执行（step1 无删除时 step2 仍可能删），都无删
        # 除才算收敛。
        removed = _thin_step(img, first=True)
        removed = _thin_step(img, first=False) or removed
        if not removed:
            break
    return img * 255




def _thin_step(img: np.ndarray, first: bool) -> bool:
    pad = np.pad(img, 1)
    p2, p3 = pad[0:-2, 1:-1], pad[0:-2, 2:]      # 北、东北
    p4, p5 = pad[1:-1, 2:], pad[2:, 2:]          # 东、东南
    p6, p7 = pad[2:, 1:-1], pad[2:, 0:-2]        # 南、西南
    p8, p9 = pad[1:-1, 0:-2], pad[0:-2, 0:-2]    # 西、西北
    seq = (p2, p3, p4, p5, p6, p7, p8, p9, p2)
    b = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9
    a = np.zeros_like(img, dtype=np.uint8)
    for i in range(8):
        a += ((seq[i] == 0) & (seq[i + 1] == 1)).astype(np.uint8)
    if first:
        m = (p2 * p4 * p6 == 0) & (p4 * p6 * p8 == 0)
    else:
        m = (p2 * p4 * p8 == 0) & (p2 * p6 * p8 == 0)
    hit = (img == 1) & (b >= 2) & (b <= 6) & (a == 1) & m
    if not hit.any():
        return False
    img[hit] = 0
    return True




def _crossing_number(skel: np.ndarray) -> np.ndarray:
    """8 邻域环序 0→1 跳变数（crossing number），仅在前景像素上有意义：
    端点=1、普通点=2、T 形分叉=3、十字交叉=4。

    必须用跳变数而非邻居计数做拓扑分类：细化在对角笔画上产生的锯齿
    像素（如北+东北+东三个邻居的对角走廊）邻居和为 3、会被误判成分
    叉，而跳变数为 2、正确归类为普通点——这是指纹 minutiae 提取的标
    准做法。"""
    pad = np.pad(skel > 0, 1).astype(np.uint8)
    seq = (pad[0:-2, 1:-1], pad[0:-2, 2:], pad[1:-1, 2:], pad[2:, 2:],
           pad[2:, 1:-1], pad[2:, 0:-2], pad[1:-1, 0:-2], pad[0:-2, 0:-2],
           pad[0:-2, 1:-1])
    cn = np.zeros(skel.shape, dtype=np.uint8)
    for i in range(8):
        cn += ((seq[i] == 0) & (seq[i + 1] == 1)).astype(np.uint8)
    return cn




def _prune_spurs(skel: np.ndarray) -> np.ndarray:
    """删细化毛刺：从端点出发走 <=PRUNE_SPUR_LEN 步就碰到分叉点的
    短枝整条删除（分叉点本身保留，主干不受影响）；顺手删除无分叉的
    孤立微连通块（飞白残点）。

    细化算法会在笔画交叉附近产生 1-3px 的伪短枝，其端点是伪特征点，
    直接污染端点计数与 L1 匹配。孤立长线段（如短横"一"）同样无分叉
    但是真实笔画，只删长度 <=2 的微块。"""
    out = (skel > 0).astype(np.uint8)
    h, w = out.shape
    while True:
        cn = _crossing_number(out)
        changed = False
        n, labels = cv2.connectedComponents(out, connectivity=8)
        for i in range(1, n):
            comp = labels == i
            if (comp & (cn >= 3)).any():
                continue
            if int(comp.sum()) <= 2:
                out[comp] = 0
                changed = True
        if changed:
            continue
        for ey, ex in np.argwhere((out == 1) & (cn == 1)):
            if out[ey, ex] == 0:
                continue  # 已被本轮前序删除波及
            cur, prev = (int(ey), int(ex)), None
            path = [cur]
            hit = False
            for _ in range(PRUNE_SPUR_LEN):
                cy, cx = cur
                cand = [(ny, nx)
                        for ny in range(max(0, cy - 1), min(h, cy + 2))
                        for nx in range(max(0, cx - 1), min(w, cx + 2))
                        if (ny, nx) != (cy, cx) and (ny, nx) != prev
                        and out[ny, nx] == 1]
                if not cand:
                    break
                if any(cn[c[0], c[1]] >= 3 for c in cand):
                    hit = True  # 尽头是分叉点，path 未含它
                    break
                if len(cand) > 1:
                    break  # 非单线路径（环/锯齿），保守不删
                prev, cur = cur, cand[0]
                path.append(cur)
            if hit and len(path) <= PRUNE_SPUR_LEN:
                for py, px in path:
                    out[py, px] = 0
                changed = True
                break  # 邻域已变，重扫
        if not changed:
            return out * 255




def _junction_clusters(skel: np.ndarray, cn: np.ndarray) -> list[np.ndarray]:
    """分叉簇凝聚：CN>=3 候选点先按 8 连通成种子簇，再按膨胀邻接合并。

    细化把一个真实交叉拆成相距 1-2px 的多个候选点（T 交点被拉成短
    棒、两端各报一个分叉），纯 8 连通聚不拢；直接对候选点图做连通聚
    类又会把两个真实交叉错误合并。折中：种子簇之间只有在膨胀
    JUNCTION_RADIUS 后落入同一连通域才算同一交叉。"""
    cand = ((skel > 0) & (cn >= 3)).astype(np.uint8)
    if not cand.any():
        return []
    seeds, seed_labels = cv2.connectedComponents(cand, connectivity=8)
    if seeds <= 2:
        return [seed_labels == i for i in range(1, seeds)]
    k = cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE,
        (2 * JUNCTION_RADIUS + 1, 2 * JUNCTION_RADIUS + 1))
    _, dil_labels = cv2.connectedComponents(cv2.dilate(cand, k), connectivity=8)
    # 种子簇自身 8 连通，膨胀后必落在同一连通域，取任一像素即可代表
    groups: dict[int, list[int]] = {}
    for i in range(1, seeds):
        ys, xs = np.nonzero(seed_labels == i)
        groups.setdefault(int(dil_labels[ys[0], xs[0]]), []).append(i)
    masks: list[np.ndarray] = []
    for members in groups.values():
        merged = np.zeros(cand.shape, dtype=bool)
        for i in members:
            merged |= seed_labels == i
        masks.append(merged)
    return masks




def _topology(skel: np.ndarray) -> dict:
    """骨架拓扑量：洞数、连通块、端点、T 形分叉、十字交叉。

    分类全部基于跳变数（_crossing_number），分叉按膨胀半径凝聚成簇后
    计数（簇内含 CN>=4 的点记十字，否则记 T 形）；洞数用 RETR_CCOMP
    层级数内轮廓，骨架化只让洞变大不会增减。"""
    n, _ = cv2.connectedComponents((skel > 0).astype(np.uint8), connectivity=8)
    cn = _crossing_number(skel)
    endpoints = int(((skel > 0) & (cn == 1)).sum())
    junctions, crossings = 0, 0
    for cluster in _junction_clusters(skel, cn):
        if (cluster & (cn >= 4)).any():
            crossings += 1
        else:
            junctions += 1
    contours, hierarchy = cv2.findContours(
        (skel > 0).astype(np.uint8), cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
    holes = 0
    if hierarchy is not None:
        for h in hierarchy[0]:
            if h[3] != -1:  # 有父轮廓 = 内轮廓 = 洞
                holes += 1
    return {
        "holes": holes,
        "components": n - 1,
        "endpoints": endpoints,
        "junctions": junctions,
        "crossings": crossings,
    }




def _minutiae(skel: np.ndarray) -> tuple[list, list]:
    """L1 用的特征点：(端点列表, 分叉簇质心列表)（不分类型参与匹
    配；分叉单独返回供质心对齐用——分叉数量两侧更稳定）。"""
    cn = _crossing_number(skel)
    ends = [(float(x), float(y)) for y, x in
            zip(*np.nonzero((skel > 0) & (cn == 1)))]
    junctions: list[tuple[float, float]] = []
    for cluster in _junction_clusters(skel, cn):
        ys, xs = np.nonzero(cluster)
        if len(ys):
            junctions.append((float(xs.mean()), float(ys.mean())))
    return ends, junctions




def _stroke_width(binary: np.ndarray) -> float:
    """中位笔宽估计：距离变换的墨内中位距离 × 2。

    均匀宽 w 的笔画其内部像素距离 ≈ w/2，中位数对毛笔/刻本的宽度分布
    与边缘毛刺都稳（用最大值会被主笔和墨疙瘩带偏）。"""
    ink = binary > 0
    if not ink.any():
        return 0.0
    dist = cv2.distanceTransform((ink).astype(np.uint8), cv2.DIST_L2, 3)
    return float(2.0 * np.median(dist[ink]))




def _shrink_to_width(binary: np.ndarray, target_w: float) -> np.ndarray:
    """把墨迹按距离变换收细到目标笔宽（只收、从不加粗）。

    刻本墨迹因墨渗比楷体字模粗，粗笔画粘连会产生假洞/假分叉（A 组
    误报主因），收细到与字形同宽让两侧拓扑真正可比。按"每侧剥离 s 层"
    迭代（保留距背景 > s+0.5 的像素——整数距离下保留 >=s+0.5 与
    >=s+1 等价，纯半宽阈值在 s 为整数时会退化成空操作），双守卫随时
    回退：某条真实笔画（面积 >= NOISE_AREA_MIN 的连通域）被整条吃掉、
    或剩余墨量低于等比期望的 SHRINK_LOSS_GUARD 倍，都停在上一档——
    宁可不收也不丢笔画（"會"类 2px 细笔画的教训）。"""
    w0 = _stroke_width(binary)
    if w0 <= STROKE_W_MIN or w0 <= target_w + STROKE_W_TOL:
        return binary
    dist = cv2.distanceTransform((binary > 0).astype(np.uint8),
                                 cv2.DIST_L2, 3)
    n0, labels, stats, _ = cv2.connectedComponentsWithStats(
        (binary > 0).astype(np.uint8), connectivity=8)
    significant = [i for i in range(1, n0)
                   if stats[i, cv2.CC_STAT_AREA] >= NOISE_AREA_MIN]
    ink0 = max(1, int((binary > 0).sum()))
    strip_cap = int(min(SHRINK_MAX, (w0 - target_w) / 2.0))
    best = binary
    for s in range(1, strip_cap + 1):
        cand = ((dist >= s + 0.5).astype(np.uint8)) * 255
        alive = cv2.countNonZero(cand)
        expect = max(0.2, (w0 - 2 * s) / w0)
        if alive < ink0 * expect * SHRINK_LOSS_GUARD:
            break  # 墨量掉得比等比收缩快得多：细笔画被吃
        ok = True
        for i in significant:
            if not ((labels == i) & (cand > 0)).any():
                ok = False
                break
        if not ok:
            break  # 有真实笔画整条消失：停在上一档
        best = cand
    return best




def _prepare(binary: np.ndarray, target_w: float | None = None) -> np.ndarray:
    """二值字图 → 归一化 → （可选）收细到目标笔宽 → 清洗。

    收细放在清洗前：清洗的闭运算把收细后重新露出的微断缝粘回。"""
    norm = _normalize(binary)
    if target_w is not None:
        norm = _shrink_to_width(norm, target_w)
    return _clean(norm)




def _skeleton(prepared: np.ndarray) -> np.ndarray:
    """清洗后的字图 → 细化 → 去毛刺的骨架。"""
    return _prune_spurs(_thin(prepared))


def _letterbox_square(binary: np.ndarray) -> np.ndarray:
    """对称补边成正方形（与 _normalize 同一几何，不做缩放与阈值）。"""
    side = max(binary.shape)
    square = np.zeros((side, side), dtype=binary.dtype)
    oy = (side - binary.shape[0]) // 2
    ox = (side - binary.shape[1]) // 2
    square[oy: oy + binary.shape[0], ox: ox + binary.shape[1]] = binary
    return square
