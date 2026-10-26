# -*- coding: utf-8 -*-
"""卦图几何检测（易经卦图电子化）：六爻条堆定位 + 阴阳分类 + 左右干支字框。

两个入口（与 table_grid 同构）：
- detect_hexagrams_in_page(image_path)：整页卦画候选（六爻条堆）。
- analyze_hexagram_region(image_path, x, y, w, h)：区域卦图解析——
  爻条阴阳 + 每爻左右标注字框（供引擎逐字读）。

识别原理：卦画是版面里最规则的图形结构——窄列内 6 条等距横条（阳爻
一整条、阴爻两段），条堆 x 向严格对齐、条厚一致。流程：开运算提横
条段（闭运算桥接印刷断口）→ 按 y 聚带 → 滑动窗口找"连续 6 带等距
堆"，用 x 边缘对齐 / 带跨度一致 / 条厚一致 / 条宽爻距比四道闸门验证
（表格横线因条宽远超爻距被拒；文字横笔画因 x 边缘抖动被拒）。左右
干支字框 = 爻带 y 邻域内、条堆 x 区间之外的墨迹连通域（去掉横条与
竖栏线后）。

对真实扫描件的加固（2026-10-23 用户页反馈"检测不到"后）：页面轻微
斜切会让斜条变成"厚块"被条厚上限丢掉——先在缩图上按多角度试扫估计
全局斜切角，选条段得分最高的角度把墨迹 mask 转正再检测，检出的框经
逆变换映射回原图坐标；开运算核按页面尺寸取多档（原两档对小卦画的
阴爻半段过长，半段被核吃掉整爻消失）；爻带内混入的超长异物（卦画
外框横线）按"显著长于带内次长段"丢弃；带内碎屑按最长段的 30% 下限
过滤（防文字笔画把阳爻判成阴爻）。纯 OpenCV + 已有二值化入口。

区域解析再加固（2026-10-24 用户页 page_042 识别 422 后）：(1) 多档核
不再"首中即停"——首个出堆的小核常是文字噪声堆，真堆所在的大核轮不
到，改为全核评估取最规则堆；(2) 恢复阶梯：严格等距无果后先试宽松异
距档（恰一条间距不齐，真实版式存在上爻贴得近的卦画，该页首间距仅
0.57×爻距），再试剔旁挂段档——干支笔画贴着爻带 y 中心混进 x 组，把
所在带 y 中心平均歪、跨度撑到条宽外，真爻窗全被跨度门拒；剔段按"每
带最长段 x 对齐聚簇取多数簇、丢堆区外旁挂段"恢复（_trim_side_
strokes）。整页自动扫描不进任何恢复档；(3) 失败原因带上检测到的横条
数（5 条=框选裁掉一爻，提示扩大框选；多条不成堆=混入文字）。
"""
from __future__ import annotations

from typing import Any

import cv2
import numpy as np

from seg_imaging import _binarize_ink, _imread

# 横条闭运算桥接断口（与 table_grid 同值）：木刻版细断口 ≤8px。
_BRIDGE_GAP = 8
# 同一带内条段的 y 抖动容差（阴爻两段可能错位几像素）。
_BAND_TOL = 6
# 爻距（带间距）下限：小于它视为文字笔画行而非卦画。
_MIN_PITCH = 14
# 等距验证：带间距相对中位爻距的浮动窗（印刷爻距恒定，留扫描倾斜余量）。
_GAP_MIN_RATIO, _GAP_MAX_RATIO = 0.62, 1.55
# 宽松档异距窗（仅区域解析）：恰一条间距可落在此窗——真实版式存在上爻
# 贴得明显近的卦画（2026-10-24 用户页 page_042：首间距 0.57×爻距）。
# 比下限还小是同爻碎段、比上限大是缺了一爻，都不救；且其余 4 条间距
# 仍须落在上面的等距窗，六条横条也仍要过条厚/跨度/x 对齐全部结构闸门
# ——外物混进爻带依旧会被拒。整页自动扫描保持严格等距不进此档。
_GAP_OUTLIER_MIN, _GAP_OUTLIER_MAX = 0.35, 1.9
# 条宽/爻距之比窗口：上限拒表格横线（宽≫爻距），下限拒残段。
_BAR_PITCH_MIN, _BAR_PITCH_MAX = 0.7, 4.5
# 带跨度（含阴爻中断口）相对中位条宽的浮动窗。
_SPAN_MIN_RATIO, _SPAN_MAX_RATIO = 0.55, 1.45
# 阴爻半段最短长度（占条宽比例）。
_HALF_MIN_FRACTION = 0.3
# 公共重叠区下限（占中位条宽比例）：六带共享的水平区间。
_COMMON_OVERLAP_FRACTION = 0.6
# 带内碎屑滤：短于带内最长段 30% 的段（文字笔画残段）先丢。
_FRAG_FRACTION = 0.3
# 带内外物丢弃：显著长于次长段（>2.2 倍）且带内 ≥3 段时丢最长——
# 卦画外框横线混进爻带的情形（外框线 ≈ 条堆宽 + 边距，爻半段的一半左右）。
_OUTLIER_RATIO = 2.2

# 整页斜切估计：搜索 ±5°、步长 0.75°，在 1/4 缩图上按条段总长打分。
_SKEW_RANGE_DEG = 5.0
_SKEW_STEP_DEG = 0.75
_SKEW_MIN_SIDE = 300  # 小于该边长的小图不做斜切估计（噪声主导）
_SKEW_MIN_ABS_DEG = 0.5  # 估计角小于此不旋转（省一次全尺寸 warp）


def _bar_segments(
    ink: np.ndarray, kernel_len: int
) -> tuple[list[tuple[int, int, int, int]], np.ndarray]:
    """墨迹 mask → (横条段列表, 横条 mask)：开运算提横条 + 闭运算桥接
    断口 + 连通域。条厚上限随核长放宽（max(10, 核/3)，≤24）：同是横条
    结构，大页面（高 dpi）的条天然更厚，固定 10 会把真实爻条丢掉。
    段为 (x, y, w, h)（w=条长、h=条厚），与输入同坐标系。"""
    thick_cap = max(10, min(24, kernel_len // 3))
    h_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (kernel_len, 1))
    opened = cv2.morphologyEx(ink, cv2.MORPH_OPEN, h_kernel)
    bridge = cv2.getStructuringElement(cv2.MORPH_RECT, (_BRIDGE_GAP, 1))
    opened = cv2.morphologyEx(opened, cv2.MORPH_CLOSE, bridge)
    mask = (opened > 0).astype(np.uint8)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask)
    segs: list[tuple[int, int, int, int]] = []
    for i in range(1, n):
        x, y, w, h, _area = (int(v) for v in stats[i])
        if w >= kernel_len and h <= thick_cap:
            segs.append((x, y, w, h))
        else:
            # 厚块/碎块不进条段 mask：该 mask 供字框检测做减法，文字块
            # 若混进去会把标注字一起减没（小核档文字横笔画能活过开运算）。
            mask[labels == i] = 0
    return segs, mask


def _bands(segs: list[tuple[int, int, int, int]]) -> list[dict[str, Any]]:
    """横条段按 y 中心聚带（同一爻的阴爻两段 y 抖动 ≤ _BAND_TOL）。"""
    bands: list[dict[str, Any]] = []
    for seg in sorted(segs, key=lambda s: s[1] + s[3] / 2):
        yc = seg[1] + seg[3] / 2
        if bands and abs(yc - bands[-1]["yc"]) <= _BAND_TOL:
            b = bands[-1]
            b["segs"].append(seg)
            b["yc"] = (b["yc"] + yc) / 2
        else:
            bands.append({"yc": yc, "segs": [seg]})
    return bands


def _median(vals: list[float]) -> float:
    s = sorted(vals)
    n = len(s)
    if n % 2:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2


def _clean_band_segs(
    segs: list[tuple[int, int, int, int]],
) -> list[tuple[int, int, int, int]] | None:
    """一带的条段清洗：碎屑滤（< 最长段 30%）→ 外物丢弃（>2.2 倍次长
    段且 ≥3 段，如卦画外框横线）→ 至多两段。剩余多于两段且第三段仍
    接近最长（不是"一爻两段"结构）返回 None（整窗否决）。"""
    segs = sorted(segs, key=lambda s: s[2], reverse=True)
    if len(segs) > 1:
        segs = [s for s in segs if s[2] >= segs[0][2] * _FRAG_FRACTION]
    if len(segs) > 2 and segs[0][2] > _OUTLIER_RATIO * segs[1][2]:
        segs = segs[1:]
    if len(segs) > 2:
        if segs[2][2] >= segs[0][2] * _HALF_MIN_FRACTION:
            return None
        segs = segs[:2]
    return segs


def _window_ok(
    bands: list[dict[str, Any]], allow_gap_outlier: bool = False
) -> dict[str, Any] | None:
    """连续 6 带验证为卦画条堆；通过返回堆结构（含 score，越小越规则），
    否则 None。bands 自上而下（yc 升序）。allow_gap_outlier=True 时允许
    恰一条间距落在宽松异距窗（见 _GAP_OUTLIER_*），其余间距仍须严格
    等距，且结构闸门（条厚/跨度/x 对齐/半段长）一条不少。"""
    if len(bands) != 6:
        return None
    gaps = [bands[i + 1]["yc"] - bands[i]["yc"] for i in range(5)]
    pitch = _median(gaps)
    if pitch < _MIN_PITCH:
        return None
    bad = [g for g in gaps
           if g < pitch * _GAP_MIN_RATIO or g > pitch * _GAP_MAX_RATIO]
    if bad:
        if not allow_gap_outlier or len(bad) > 1:
            return None
        if any(g < pitch * _GAP_OUTLIER_MIN
               or g > pitch * _GAP_OUTLIER_MAX for g in bad):
            return None
    cleaned: list[dict[str, Any]] = []
    for b in bands:
        segs = _clean_band_segs(b["segs"])
        if segs is None:
            return None
        cleaned.append({"yc": b["yc"], "segs": segs})
    # 条厚一致（相对中位条厚浮动窗）且相对爻距是细条。
    thicks = [s[3] for b in cleaned for s in b["segs"]]
    med_t = _median([float(t) for t in thicks])
    if med_t < 1 or med_t > 0.45 * pitch:
        return None
    if any(t < med_t * 0.4 or t > med_t * 2.4 for t in thicks):
        return None
    # 带跨度一致（阳爻整条、阴爻两段的外沿都 ≈ 条宽）。
    edges = []
    for b in cleaned:
        segs = b["segs"]
        edges.append((min(s[0] for s in segs), max(s[0] + s[2] for s in segs)))
    spans = [float(e[1] - e[0]) for e in edges]
    bar_w = _median(spans)
    if bar_w < _BAR_PITCH_MIN * pitch or bar_w > _BAR_PITCH_MAX * pitch:
        return None
    if any(sp < bar_w * _SPAN_MIN_RATIO or sp > bar_w * _SPAN_MAX_RATIO
           for sp in spans):
        return None
    # 公共重叠区：六带必须共享一段 ≥60% 中位条宽的水平区间。真实爻条
    # 两端对齐、混入的外物（卦画外框线）只是外伸——公共区仍是条宽；
    # 文字列的横笔画左右散布，公共区碎成窄条，在此否决（比"外沿对齐
    # ±10%"宽容外伸、严打错位）。
    lo = max(e[0] for e in edges)
    hi = min(e[1] for e in edges)
    if hi - lo < bar_w * _COMMON_OVERLAP_FRACTION:
        return None
    # 条堆外沿取公共区边界（外伸的外物不算条堆宽度）。
    x0m = float(lo)
    x1m = float(hi)
    # 阴爻半段长度下限（短于此是碎段不是爻）。
    for b in cleaned:
        if any(s[2] < bar_w * _HALF_MIN_FRACTION for s in b["segs"]):
            return None
    score = (
        sum(abs(g - pitch) for g in gaps) / pitch
        + sum(abs(sp - bar_w) for sp in spans) / max(1.0, bar_w)
    )
    return {
        "bands": cleaned,
        "pitch": float(pitch),
        "bar_w": float(bar_w),
        "x0": int(round(x0m)),
        "x1": int(round(x1m)),
        "y0": int(round(min(s[1] for b in cleaned for s in b["segs"]))),
        "y1": int(round(max(s[1] + s[3] for b in cleaned for s in b["segs"]))),
        "score": float(score),
    }


def _x_groups(segs: list[tuple[int, int, int, int]]) -> list[list[tuple[int, int, int, int]]]:
    """条段按 x 归组（一卦一组）：x 区间重叠 ≥ 短段 30%，或同带（y 中心
    差 ≤ 带容差）且横向断口 ≤ 短段长——后者正是阴爻两段的拓扑（断口
    ≈0.16 条宽）。不同卦画/表格列横向不相交，各自成组。"""
    def _yc(s): return s[1] + s[3] / 2

    def _joins(seg: tuple[int, int, int, int], group) -> bool:
        for g in group:
            overlap = min(seg[0] + seg[2], g[0] + g[2]) - max(seg[0], g[0])
            if overlap >= 0.3 * min(seg[2], g[2]):
                return True
            if abs(_yc(seg) - _yc(g)) <= _BAND_TOL + 2:
                gap = max(seg[0], g[0]) - min(seg[0] + seg[2], g[0] + g[2])
                if 0 <= gap <= 1.0 * min(seg[2], g[2]):
                    return True
        return False

    groups: list[list[tuple[int, int, int, int]]] = []
    for seg in sorted(segs, key=lambda s: s[0]):
        for g in groups:
            if _joins(seg, g):
                g.append(seg)
                break
        else:
            groups.append([seg])
    return groups


def _max_band_count(segs: list[tuple[int, int, int, int]]) -> int:
    """条段集里最宽 x 组聚出的带数（失败原因诊断用：离六爻还差几条）。"""
    return max((len(_bands(g)) for g in _x_groups(segs)), default=0)


def _x_overlap_frac(a: tuple[int, int], b: tuple[int, int]) -> float:
    """两 x 区间重叠比例（÷ 短者长度；不相交为 0）。"""
    ov = min(a[1], b[1]) - max(a[0], b[0])
    if ov <= 0:
        return 0.0
    return ov / max(1.0, min(a[1] - a[0], b[1] - b[0]))


def _trim_side_strokes(
    group: list[tuple[int, int, int, int]],
) -> list[dict[str, Any]] | None:
    """x 组剔旁挂段（区域解析恢复路径）。干支笔画贴着爻带 y 中心、经
    "阴爻断口"归组条款混进 x 组——把所在带的 y 中心平均歪、带跨度撑到
    条宽外，真爻窗全被跨度门拒掉（2026-10-24 用户页：右侧干支列笔画
    w≈57 挂在爻带旁）。按每带最长段的 x 区间把带聚成对齐簇，取严格最
    大簇（≥6 带、多于一半）；簇内丢 x 中心落在堆区（簇内最长段中位外
    沿 ±0.2 条宽）之外的段、重算受污染带的 y 中心。条件不满足返回
    None（走原路径）。"""
    bands = _bands(group)
    if len(bands) < 7:
        return None
    key = []
    for b in bands:
        s = max(b["segs"], key=lambda t: t[2])
        key.append((s[0], s[0] + s[2]))
    order = sorted(range(len(bands)), key=lambda i: key[i][0])
    clusters: list[list[int]] = []
    for i in order:
        for cl in clusters:
            if any(_x_overlap_frac(key[i], key[j]) >= 0.6 for j in cl):
                cl.append(i)
                break
        else:
            clusters.append([i])
    sizes = sorted(len(cl) for cl in clusters)
    best = max(clusters, key=len)
    if len(best) < 6 or (len(sizes) > 1 and sizes[-1] == sizes[-2]):
        return None  # 没有（唯一的）多数对齐簇：不是"爻堆+旁挂"结构
    sel = sorted(best)
    lo = _median([float(key[i][0]) for i in sel])
    hi = _median([float(key[i][1]) for i in sel])
    margin = 0.2 * max(1.0, hi - lo)
    out: list[dict[str, Any]] = []
    for i in sel:
        b = bands[i]
        keep = [s for s in b["segs"]
                if lo - margin <= s[0] + s[2] / 2 <= hi + margin]
        if not keep:
            continue  # 整带都是旁挂段（干支笔画自成带）
        if len(keep) == len(b["segs"]):
            out.append(b)
        else:
            yc = sum(s[1] + s[3] / 2 for s in keep) / len(keep)
            out.append({"yc": yc, "segs": keep})
    if len(out) < 6:
        return None
    return out


def _find_stacks(
    segs: list[tuple[int, int, int, int]],
    allow_gap_outlier: bool = False,
    allow_side_trim: bool = False,
) -> list[dict[str, Any]]:
    """条段集 → 卦画条堆列表（按 score 升序）。先按 x 归组（一卦一组，
    同水平线上多卦互不干扰），组内贪心找堆：每轮取验证得分最好的 6 带
    窗口，取走该 6 带后继续找——一组多卦（上下排布）各自成堆。
    allow_gap_outlier 透传 _window_ok（仅区域解析启用）；allow_side_trim
    为组内无堆时按 _trim_side_strokes 剔旁挂段重试（同仅区域解析）——
    原始带找到堆就不进恢复路径，整页扫描两档都不启用。"""
    stacks: list[dict[str, Any]] = []
    for group in _x_groups(segs):
        cands = [_bands(group)]
        if allow_side_trim:
            trimmed = _trim_side_strokes(group)
            if trimmed is not None:
                cands.append(trimmed)
        for bands in cands:
            group_stacks: list[dict[str, Any]] = []
            while True:
                best: tuple[int, dict[str, Any]] | None = None
                for i in range(max(0, len(bands) - 5)):
                    st = _window_ok(bands[i:i + 6], allow_gap_outlier)
                    if st is not None and (
                        best is None or st["score"] < best[1]["score"]
                    ):
                        best = (i, st)
                if best is None:
                    break
                i, st = best
                group_stacks.append(st)
                bands = [
                    b for k, b in enumerate(bands) if not i <= k < i + 6
                ]
            if group_stacks:
                stacks.extend(group_stacks)
                break  # 原始带已出堆：不进剔段重试（防重复堆）
    return sorted(stacks, key=lambda s: s["score"])


# ── 斜切估计与转正 ────────────────────────────────────────────────

def _rot_matrix(shape: tuple[int, int], deg: float) -> np.ndarray:
    h, w = shape
    return cv2.getRotationMatrix2D((w / 2.0, h / 2.0), deg, 1.0)


def _segment_score(mask: np.ndarray, klen: int, thick_cap: int) -> int:
    """该角度下的"细长条"得分：Σ max(0, 条长 − 3×条厚)。斜条转正后
    变薄变长得分升高，正条转歪则变厚得分下降——干净页面 0° 必须得分
    最高（文字笔画短，贡献近 0 不影响极值）。"""
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (klen, 1))
    opened = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    n, _labels, stats, _ = cv2.connectedComponentsWithStats(
        (opened > 0).astype(np.uint8)
    )
    score = 0
    for i in range(1, n):
        _x, _y, w, h, _area = (int(v) for v in stats[i])
        if w >= klen and h <= thick_cap:
            score += max(0, w - 3 * h)
    return score


def _estimate_skew_deg(ink: np.ndarray, klen_ref: float) -> float:
    """1/4 缩图上扫 ±5°（步长 0.75°），返回条段得分最高的旋转角。
    klen_ref 为全尺寸参考核长（缩图同步缩小）。0° 先评且只有别的角度
    得分高出 5% 才让位——页面本来就正时必须稳选回 0（旋转是有代价的，
    平局不转）。"""
    ih, iw = ink.shape[:2]
    if min(ih, iw) < _SKEW_MIN_SIDE:
        return 0.0
    small = cv2.resize(ink, (max(1, iw // 4), max(1, ih // 4)),
                       interpolation=cv2.INTER_AREA)
    small = ((small > 127).astype(np.uint8)) * 255
    klen = max(4, int(klen_ref * 0.25))
    thick_cap = max(4, int(thick_cap_for(klen) * 0.25) + 2)
    best_deg = 0.0
    best_score = _segment_score(small, klen, thick_cap)
    floor = best_score * 1.05
    deg = -_SKEW_RANGE_DEG
    while deg <= _SKEW_RANGE_DEG + 1e-6:
        if abs(deg) >= 1e-6:
            M = _rot_matrix(small.shape, deg)
            cand = cv2.warpAffine(
                small, M, (small.shape[1], small.shape[0]),
                flags=cv2.INTER_NEAREST, borderValue=0,
            )
            s = _segment_score(cand, klen, thick_cap)
            if s > floor:
                best_deg, best_score, floor = deg, s, s * 1.05
        deg += _SKEW_STEP_DEG
    return best_deg


def thick_cap_for(kernel_len: int) -> int:
    """横条段条厚上限（与 _bar_segments 同式，供斜切打分复用）。"""
    return max(10, min(24, kernel_len // 3))


def _unmap_box(
    Minv: np.ndarray | None,
    box: dict[str, int],
    shape: tuple[int, int],
) -> dict[str, int]:
    """检测框从转正帧映射回原图帧：四角经逆仿射取外接框并钳回图内。
    Minv=None（未旋转）原样返回。"""
    x, y, w, h = box["x"], box["y"], box["w"], box["h"]
    if Minv is None:
        out = dict(box)
    else:
        pts = np.array(
            [[[x, y], [x + w, y], [x, y + h], [x + w, y + h]]],
            dtype=np.float32,
        )
        mapped = cv2.transform(pts, Minv)[0]
        x0 = int(np.floor(float(mapped[:, 0].min())))
        y0 = int(np.floor(float(mapped[:, 1].min())))
        x1 = int(np.ceil(float(mapped[:, 0].max())))
        y1 = int(np.ceil(float(mapped[:, 1].max())))
        out = {"x": x0, "y": y0, "w": x1 - x0, "h": y1 - y0}
    ih, iw = shape
    out["x"] = max(0, min(iw - 1, out["x"]))
    out["y"] = max(0, min(ih - 1, out["y"]))
    out["w"] = max(1, min(iw - out["x"], out["w"]))
    out["h"] = max(1, min(ih - out["y"], out["h"]))
    return out


# 整页多档开运算核（页面短边的比例；小核救小卦画/高 dpi，大核抗噪）。
_PAGE_KERNEL_FRACTIONS = (0.008, 0.0125, 0.02, 0.03)
# 区域（ROI）多档核（ROI 宽的比例；紧框/松框各覆盖）。
_REGION_KERNEL_FRACTIONS = (0.06, 0.09, 0.125, 0.18)


def _kernels_for(length: int, fractions, lo: int, hi: int) -> list[int]:
    out: list[int] = []
    for frac in fractions:
        klen = int(length * frac)
        klen = max(lo, min(hi, klen))
        if klen not in out:
            out.append(klen)
    return out


def _stack_lines(stack: dict[str, Any]) -> list[dict[str, Any]]:
    """堆 → 爻行几何（自下而上 pos 1..6，坐标与堆同系）。"""
    lines: list[dict[str, Any]] = []
    for idx in range(5, -1, -1):  # bands[0] 是最上带 = 上爻（pos 6）
        b = stack["bands"][idx]
        pos = 6 - idx
        segs = b["segs"]
        x0 = min(s[0] for s in segs)
        y0 = min(s[1] for s in segs)
        x1 = max(s[0] + s[2] for s in segs)
        y1 = max(s[1] + s[3] for s in segs)
        lines.append({
            "pos": pos,
            "yang": len(segs) == 1,
            "bar": {"x": int(x0), "y": int(y0), "w": int(x1 - x0),
                    "h": int(y1 - y0)},
        })
    return lines


def _mark_boxes(
    ink: np.ndarray,
    bar_mask: np.ndarray,
    stack: dict[str, Any],
) -> list[dict[str, Any]]:
    """左右标注字框：爻带 y 邻域内、条堆 x 区间之外的墨迹连通域。

    字框 mask = 二值墨迹 −（横条 mask ∪ 竖栏线 mask）各膨胀 3×3——
    爻条与栏线不占字框。字框尺寸约束按爻距（干支字 ≈ 爻距大小；竖排
    双字粘连连通域高 ≈ 2 爻距，上限放宽到 2.2 倍）。返回 pos 1..6 的
    {"pos","left","right"}，侧内自上而下。"""
    pitch = stack["pitch"]
    # 竖栏线剔除核长按爻距定（≥2.5 爻距）：栏线远高于字；若跟开运算
    # 核长走，小核档会短于文字高度，把标注字当"竖线"整块减掉。
    v_kernel = cv2.getStructuringElement(
        cv2.MORPH_RECT, (1, int(2.5 * pitch) + 1)
    )
    v_mask = cv2.morphologyEx(ink, cv2.MORPH_OPEN, v_kernel)
    dil = np.ones((3, 3), np.uint8)
    glyph = (ink > 0) & ~(
        (cv2.dilate(bar_mask, dil) > 0) | (cv2.dilate(v_mask, dil) > 0)
    )
    n, _labels, stats, _ = cv2.connectedComponentsWithStats(
        glyph.astype(np.uint8)
    )
    pad = max(3, int(stack["bar_w"] * 0.08))
    out = [{"pos": p, "left": [], "right": []} for p in range(1, 7)]
    for i in range(1, n):
        x, y, w, h, area = (int(v) for v in stats[i])
        if area < 6 or min(w, h) < 3 or max(w, h) > 2.2 * pitch:
            continue
        cx, cy = x + w / 2, y + h / 2
        best_d = None
        best_bi = -1
        for bi, b in enumerate(stack["bands"]):
            d = abs(cy - b["yc"])
            if d <= 0.6 * pitch and (best_d is None or d < best_d):
                best_d, best_bi = d, bi
        if best_bi < 0:
            continue  # 不落在任何爻带邻域：非爻注墨迹
        if cx < stack["x0"] - pad:
            side = "left"
        elif cx > stack["x1"] + pad:
            side = "right"
        else:
            continue  # 条堆正上/断口内的墨迹：不是侧注
        out[6 - best_bi - 1][side].append(
            {"x": x, "y": y, "w": w, "h": h}
        )
    for o in out:
        o["left"].sort(key=lambda b: b["y"])
        o["right"].sort(key=lambda b: b["y"])
    return out


def analyze_hexagram_region(
    image_path: str, x: int, y: int, w: int, h: int
) -> dict[str, Any]:
    """区域卦图解析：六爻阴阳 + 每爻左右标注字框（全图绝对坐标）。

    ok=False 时 reason 说明原因（图不存在 / 区域过小 / 无卦画，无卦画时
    附检测到的横条数：五条=框选裁掉一爻、多条不成堆=混入文字）。
    lines 自下而上 pos 1..6（初爻→上爻），与 hexagram_domain 口径一致。
    多档核逐一评估取最规则堆（不首中即停——小核的文字噪声堆会抢在真
    堆所在的大核前面）；原始检测无果时按恢复阶梯重试：宽松异距档（恰
    一条间距不齐，真实版式存在上爻贴得近的卦画）→ 剔旁挂段档（干支
    笔画贴着爻带混进 x 组、撑爆带跨度）→ 两者叠加。斜切先转正再检测、
    检出框映射回原图。不做整页式的贯穿线剔除——用户框定的区域里横贯
    全宽的线往往就是爻条。
    """
    img = None
    try:
        img = _imread(image_path)
    except OSError:
        img = None
    if img is None:
        return {"ok": False, "reason": "image not found"}
    ih, iw = img.shape[:2]
    x0, y0 = max(0, int(x)), max(0, int(y))
    x1, y1 = min(iw, x0 + max(1, int(w))), min(ih, y0 + max(1, int(h)))
    if x1 - x0 < 40 or y1 - y0 < 6 * _MIN_PITCH:
        return {"ok": False, "reason": "region too small"}
    roi = img[y0:y1, x0:x1]
    ink = _binarize_ink(roi)
    rw = x1 - x0
    klens = _kernels_for(rw, _REGION_KERNEL_FRACTIONS, 8, 90)
    deg = _estimate_skew_deg(ink, klens[len(klens) // 2])
    M = None
    Minv = None
    work = ink
    if abs(deg) >= _SKEW_MIN_ABS_DEG:
        M = _rot_matrix(ink.shape[:2], deg)
        Minv = cv2.invertAffineTransform(M)
        work = cv2.warpAffine(
            ink, M, (rw, ink.shape[0]),
            flags=cv2.INTER_NEAREST, borderValue=0,
        )
    strict: tuple[float, dict[str, Any], np.ndarray] | None = None
    loose: tuple[float, dict[str, Any], np.ndarray] | None = None
    max_bands = 0
    tiers = [(klen,) + _bar_segments(work, klen) for klen in klens]
    for _klen, segs, _bmask in tiers:
        max_bands = max(max_bands, _max_band_count(segs))
    # 恢复阶梯（假设最少的先试，全核取最规则堆）：
    #   严格等距 → 宽松异距（恰一条间距不齐）→ 严格+剔旁挂段 → 两者叠加
    stack = None
    bar_mask = None
    for gap_outlier, side_trim in ((False, False), (True, False),
                                   (False, True), (True, True)):
        best: tuple[float, dict[str, Any], np.ndarray] | None = None
        for _klen, segs, bmask in tiers:
            for st in _find_stacks(
                segs,
                allow_gap_outlier=gap_outlier,
                allow_side_trim=side_trim,
            ):
                if best is None or st["score"] < best[0]:
                    best = (st["score"], st, bmask)
        if best is not None:
            stack, bar_mask = best[1], best[2]
            break
    if stack is None:
        if max_bands == 0:
            return {
                "ok": False,
                "reason": "未检测到六爻卦画（区域内没有横条结构；需六条"
                          "等距横条：阳爻整条、阴爻两段——请确认框选"
                          "对准完整卦画）",
            }
        if max_bands == 5:
            return {
                "ok": False,
                "reason": "仅检测到 5 条横条：框选可能裁掉了一条爻，请"
                          "在编辑器扩大卦图框选，覆盖全部六条横条后再"
                          "识别",
            }
        return {
            "ok": False,
            "reason": f"检测到 {max_bands} 条横条，但间距或条宽不符合等距"
                      "六爻（可能混入文字笔画或框选不完整）——请确认框选"
                      "只覆盖卦画六条横条",
        }
    marks = _mark_boxes(work, bar_mask, stack)
    geo_lines = _stack_lines(stack)
    lines: list[dict[str, Any]] = []

    def _abs(box: dict[str, int]) -> dict[str, int]:
        mapped = _unmap_box(Minv, box, (y1 - y0, x1 - x0))
        return {"x": mapped["x"] + x0, "y": mapped["y"] + y0,
                "w": mapped["w"], "h": mapped["h"]}

    for lg, mk in zip(geo_lines, marks):  # 两者均 pos 1..6
        assert lg["pos"] == mk["pos"]
        lines.append({
            "pos": lg["pos"],
            "yang": lg["yang"],
            "bar": _abs(lg["bar"]),
            "left": [_abs(b) for b in mk["left"]],
            "right": [_abs(b) for b in mk["right"]],
        })
    stack_box = _abs({"x": stack["x0"], "y": stack["y0"],
                      "w": stack["x1"] - stack["x0"],
                      "h": stack["y1"] - stack["y0"]})
    return {
        "ok": True,
        "x": x0, "y": y0, "w": x1 - x0, "h": y1 - y0,
        "skew_deg": float(deg),
        "stack": stack_box,
        "pitch": int(round(stack["pitch"])),
        "bar_w": int(round(stack["bar_w"])),
        "lines": lines,
    }


def detect_hexagrams_in_page_with_diag(
    image_path: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """整页查找卦画候选（含诊断）：多档核提横条段 → 六带等距堆验证。

    返回 (候选列表, 诊断)。候选为 [{"x","y","w","h","pitch","bar_w"}]
    （含左右标注的扩展框，阅读序排序）；诊断含斜切角与逐核统计（空
    结果时给插件展示，便于定位是斜切/条宽/密度哪一环不匹配）。
    候选仅供插件/预标注（proposed），误报由人工拒绝。"""
    diag: dict[str, Any] = {"skew_deg": 0.0, "kernels": []}
    img = None
    try:
        img = _imread(image_path)
    except OSError:
        return [], diag
    if img is None:
        return [], diag
    ih, iw = img.shape[:2]
    ink = _binarize_ink(img)
    klens = _kernels_for(min(iw, ih), _PAGE_KERNEL_FRACTIONS, 10, 60)
    deg = _estimate_skew_deg(ink, klens[len(klens) // 2])
    diag["skew_deg"] = float(deg)
    M = None
    Minv = None
    work = ink
    if abs(deg) >= _SKEW_MIN_ABS_DEG:
        M = _rot_matrix(ink.shape[:2], deg)
        Minv = cv2.invertAffineTransform(M)
        work = cv2.warpAffine(
            ink, M, (iw, ih), flags=cv2.INTER_NEAREST, borderValue=0,
        )
    found: list[dict[str, Any]] = []
    for klen in klens:
        segs, _mask = _bar_segments(work, klen)
        segs = _drop_page_rules(segs, iw)
        stacks = _find_stacks(segs)
        diag["kernels"].append(
            {"klen": klen, "segments": len(segs), "stacks": len(stacks)}
        )
        found.extend(stacks)
    # 双档去重：堆中心距 < 1.2 爻距视为同一堆，保留 score 更好者。
    dedup: list[dict[str, Any]] = []
    for st in sorted(found, key=lambda s: s["score"]):
        cy = (st["y0"] + st["y1"]) / 2
        cx = (st["x0"] + st["x1"]) / 2
        if any(
            abs(cy - (d["y0"] + d["y1"]) / 2) < st["pitch"] * 1.2
            and abs(cx - (d["x0"] + d["x1"]) / 2) < st["bar_w"] * 1.2
            for d in dedup
        ):
            continue
        dedup.append(st)
    out: list[dict[str, Any]] = []
    for st in dedup:
        mx, my = int(st["bar_w"]), int(st["pitch"] * 0.9)
        bx, by = st["x0"] - mx, st["y0"] - my
        bx1, by1 = st["x1"] + mx, st["y1"] + my
        box = _unmap_box(
            Minv, {"x": bx, "y": by, "w": bx1 - bx, "h": by1 - by},
            (ih, iw),
        )
        box["pitch"] = int(round(st["pitch"]))
        box["bar_w"] = int(round(st["bar_w"]))
        out.append(box)
    out.sort(key=lambda b: (b["y"], b["x"]))
    return out, diag


def detect_hexagrams_in_page(image_path: str) -> list[dict[str, Any]]:
    """整页卦画候选（无诊断的兼容入口，见 detect_hexagrams_in_page_with_diag）。"""
    return detect_hexagrams_in_page_with_diag(image_path)[0]


def _drop_page_rules(
    segs: list[tuple[int, int, int, int]], width: int
) -> list[tuple[int, int, int, int]]:
    """贯穿全宽的横线（版框/栏线）不是爻条：两端都顶到窗口边缘。"""
    return [s for s in segs if not (s[0] <= 2 and s[0] + s[2] >= width - 2)]
