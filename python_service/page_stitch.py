# -*- coding: utf-8 -*-
"""两页智能拼接：把跨页连续的内容（连续表格/图片）拼成看起来正常的一页。

不是把两张整页图（含页边空白）直接首尾相接，而是三步：
1) 空白裁切：按墨迹投影找到上页内容结束、下页内容开始的位置，各留
   一点纸边余量后裁掉接缝侧的空白（留余量后接缝两侧都是纸白，
   硬拼接的缝天然不可见）；
2) 内容对齐：接缝带内做投影相关，恢复两页垂直于拼接方向的错位
   （装订/扫描偏移——连续表格的竖线靠它对齐），并检测可能的重复
   扫描重叠（两页拍了同一段内容）；
3) 接缝融合：有重叠时在重叠带内线性羽化（真重复内容交叉淡化无缝），
   无重叠时硬拼接。

手动微调（重叠/错位像素）优先于自动判定；direction='v' 上下拼
（A 上 B 下，错位为 x 位移）、'h' 左右拼（A 左 B 右，错位为 y 位移）。
错位正方向：B 相对 A 沿坐标轴正向平移（v: 右移；h: 下移）。
"""
import cv2
import numpy as np

# 裁切后保留的纸边余量：max(6px, 页宽/高的 0.8%)。
_TRIM_MARGIN_RATIO = 0.008
_TRIM_MARGIN_MIN = 6
# 自动错位搜索范围：两页尺寸小者的 8%（2000px 宽页 ±160px，覆盖
# 装订/扫描的横向错位；搜的是相关峰，范围大不误报）。
_ALIGN_MAX_RATIO = 0.08
# 自动重叠检测：上限为两页（裁后）短边的 20%，下限 8px。
_OVERLAP_MAX_RATIO = 0.20
_OVERLAP_MIN_PX = 8
_OVERLAP_CORR_GATE = 0.80  # 行/列投影相关低于此视为非重复扫描
# 对齐置信门限：混合相关分低于此不自动错位（宁可不错位，可手动）。
_ALIGN_CONF_GATE = 0.35
# 接缝带宽度（对齐/重叠分析取这么宽的内容带）：max(48px, 短边 12%)。
_BAND_RATIO = 0.12
_BAND_MIN = 48


def _ink_mask(gray):
    """墨迹掩码：Otsu 取暗部 + 2x2 开运算去孤立噪点。"""
    mask = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)[1]
    if mask.max() == 0:
        return mask
    return cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))


def _row_profile(mask):
    """每行的墨迹像素数（shape=(h,)）——行投影，找内容的上/下缘。"""
    return mask.sum(axis=1).astype(np.float64) / 255.0


def _col_profile(mask):
    """每列的墨迹像素数（shape=(w,)）——列投影，找内容的左/右缘与
    竖线错位对齐。"""
    return mask.sum(axis=0).astype(np.float64) / 255.0


def _corr(a, b):
    """皮尔逊相关；样本太少或方差为 0 返回 -1（视为无信号）。"""
    n = min(len(a), len(b))
    if n < 8:
        return -1.0
    a = np.asarray(a[:n], dtype=np.float64)
    b = np.asarray(b[:n], dtype=np.float64)
    sa, sb = a.std(), b.std()
    if sa < 1e-9 or sb < 1e-9:
        return -1.0
    return float(np.corrcoef(a, b)[0, 1])


def _smooth(prof, k=9):
    """投影平滑（滑动均值），容忍墨迹边缘的抖动。"""
    if len(prof) < k:
        return prof
    return cv2.blur(prof.reshape(-1, 1).astype(np.float32), (1, k)).ravel()


def _trim_edge(img, mask, edge, margin):
    """裁掉接缝侧空白：edge='bottom'/'top'（调用方对 'v'），行/列投影
    找内容结束/开始处 ±margin。无墨迹（空页）不裁。返回 (裁后图, 裁掉
    的像素数)。"""
    prof = _row_profile(mask)
    idx = np.flatnonzero(prof >= 1.0)
    if idx.size == 0:
        return img, 0
    if edge == "bottom":
        cut = min(img.shape[0], int(idx[-1]) + 1 + margin)
        return img[:cut], img.shape[0] - cut
    cut = max(0, int(idx[0]) - margin)
    return img[cut:], cut


def _align_offset(prof_a, prof_b, max_shift):
    """垂直于拼接方向的错位：两条投影的相关峰。prof 取自接缝带；返回
    (offset, confidence)，offset 使 B 的投影与 A 对齐（B 相对 A 平移量）。

    相关在**梯度域**为主计算：原始投影被文本块的大包络主导——整版
    文字的两个接缝带在任何错位下都"高度相似"，峰不显著（实测切换自动
    对齐看不出任何变化）。投影差分突出文字列/竖线的边界，错位才产生
    显著峰；包络相关以 0.3 权重辅助（周期性文字列在 ±列距 处有等价
    峰，包络帮助挑出真峰）。
    """
    smooth_a = _smooth(prof_a)
    smooth_b = _smooth(prof_b)
    grad_a = np.gradient(smooth_a)
    grad_b = np.gradient(smooth_b)
    best_s, best_c = 0, -1.0
    wa, wb = len(prof_a), len(prof_b)
    for s in range(-max_shift, max_shift + 1):
        # B 平移 s 后与 A 的公共区：B 的 [lo_b, hi_b) 对 A 的 [lo_a, hi_a)。
        lo_a, hi_a = max(0, s), min(wa, wb + s)
        lo_b, hi_b = max(0, -s), min(wb, wa - s)
        n = hi_a - lo_a
        if n < max(8, int(min(wa, wb) * 0.3)):
            continue
        c = 0.7 * _corr(grad_a[lo_a:hi_a], grad_b[lo_b:hi_b]) + 0.3 * _corr(
            prof_a[lo_a:hi_a], prof_b[lo_b:hi_b]
        )
        if c > best_c:
            best_s, best_c = s, c
    return best_s, best_c


def _detect_overlap(prof_a, prof_b, max_overlap):
    """重复扫描重叠：B 开头 o 个采样与 A 结尾 o 个采样的投影相关峰。
    高于 [_OVERLAP_CORR_GATE] 才认定（文字行的周期性会抬高低位峰）。"""
    best_o, best_c = 0, -1.0
    for o in range(_OVERLAP_MIN_PX, max_overlap, 2):
        c = _corr(prof_a[-o:], prof_b[:o])
        if c > best_c:
            best_o, best_c = o, c
    if best_c >= _OVERLAP_CORR_GATE:
        return best_o, best_c
    return 0, best_c


def stitch_pages(img_a, img_b, direction="v", auto_trim=True, auto_align=True,
                 overlap=None, offset=None, seam_fade=24):
    """拼接两页。[overlap]/[offset] 为 None 时自动判定（auto_* 开关控制），
    否则手动值优先（仍做安全钳制）。返回 (拼接图, trace dict)。

    trace：trim_a/trim_b（各裁掉像素）、offset/offset_auto、
    overlap/overlap_auto、align_confidence、out_w/out_h。
    """
    if img_a is None or img_b is None or img_a.size == 0 or img_b.size == 0:
        raise ValueError("empty page image")
    if img_a.ndim == 2:
        img_a = cv2.cvtColor(img_a, cv2.COLOR_GRAY2BGR)
    if img_b.ndim == 2:
        img_b = cv2.cvtColor(img_b, cv2.COLOR_GRAY2BGR)
    # 'h' 左右拼：转置后按上下拼处理（行/列语义互换），最后转回来。
    transposed = direction == "h"
    if transposed:
        a = np.ascontiguousarray(img_a.transpose(1, 0, 2))
        b = np.ascontiguousarray(img_b.transpose(1, 0, 2))
    else:
        a, b = img_a, img_b

    gray_a = cv2.cvtColor(a, cv2.COLOR_BGR2GRAY)
    gray_b = cv2.cvtColor(b, cv2.COLOR_BGR2GRAY)
    mask_a = _ink_mask(gray_a)
    mask_b = _ink_mask(gray_b)

    # ① 空白裁切（接缝侧：A 的底边、B 的顶边）。
    trim_a = trim_b = 0
    if auto_trim:
        margin_a = max(_TRIM_MARGIN_MIN, int(a.shape[0] * _TRIM_MARGIN_RATIO))
        margin_b = max(_TRIM_MARGIN_MIN, int(b.shape[0] * _TRIM_MARGIN_RATIO))
        a, trim_a = _trim_edge(a, mask_a, "bottom", margin_a)
        b, trim_b = _trim_edge(b, mask_b, "top", margin_b)
        if a.shape[0] == 0 or b.shape[0] == 0:  # 空页把整页裁没：退回不裁
            a, b = (img_a, img_b) if not transposed else (
                np.ascontiguousarray(img_a.transpose(1, 0, 2)),
                np.ascontiguousarray(img_b.transpose(1, 0, 2)),
            )
            trim_a = trim_b = 0

    ha, wa = a.shape[:2]
    hb, wb = b.shape[:2]
    band_a = a[max(0, ha - _band(ha)):]
    band_b = b[:min(hb, _band(hb))]
    band_mask_a = _ink_mask(cv2.cvtColor(band_a, cv2.COLOR_BGR2GRAY))
    band_mask_b = _ink_mask(cv2.cvtColor(band_b, cv2.COLOR_BGR2GRAY))

    # ② 错位（x 方向）：接缝带的列投影相关。
    offset_auto = offset is None and auto_align
    align_confidence = -1.0
    if offset_auto:
        max_shift = int(min(wa, wb) * _ALIGN_MAX_RATIO)
        prof_a = _smooth(_col_profile(band_mask_a))
        prof_b = _smooth(_col_profile(band_mask_b))
        s, conf = _align_offset(prof_a, prof_b, max_shift)
        align_confidence = conf
        # 混合分（梯度 0.7 + 包络 0.3）太低（图片页/空带/纯平直页）
        # 不动：宁可不错位，用户可手动。
        offset = s if conf >= _ALIGN_CONF_GATE else 0
    if offset is None:
        offset = 0
    offset = int(np.clip(offset, -int(min(wa, wb) * 0.25), int(min(wa, wb) * 0.25)))

    # ③ 重叠（y 方向）：行投影相关检测重复扫描。窗口独立于接缝带
    #（复拍重叠可达页高的 20%，带只有 12% 搜不到）。
    overlap_auto = overlap is None and auto_align
    if overlap_auto:
        max_overlap = max(
            _OVERLAP_MIN_PX + 2,
            int(min(ha, hb) * _OVERLAP_MAX_RATIO),
        )
        win_a = a[max(0, ha - max_overlap):]
        win_b = b[:min(hb, max_overlap)]
        row_a = _row_profile(_ink_mask(cv2.cvtColor(win_a, cv2.COLOR_BGR2GRAY)))
        row_b = _row_profile(_ink_mask(cv2.cvtColor(win_b, cv2.COLOR_BGR2GRAY)))
        o, _ = _detect_overlap(row_a, row_b, max_overlap)
        overlap = o
    if overlap is None:
        overlap = 0
    overlap = int(np.clip(overlap, 0, min(ha - 1, hb - 1)))

    out = _compose_vertical(a, b, offset, overlap, seam_fade)
    if transposed:
        out = np.ascontiguousarray(out.transpose(1, 0, 2))

    trace = {
        "direction": direction,
        "trim_a": int(trim_a),
        "trim_b": int(trim_b),
        "offset": int(offset),
        "offset_auto": bool(offset_auto),
        "overlap": int(overlap),
        "overlap_auto": bool(overlap_auto),
        "align_confidence": round(float(align_confidence), 3),
        "out_w": int(out.shape[1]),
        "out_h": int(out.shape[0]),
    }
    return out, trace


def _band(h):
    """接缝带宽度。"""
    return max(_BAND_MIN, int(h * _BAND_RATIO))


def _paper_color(a, b):
    """纸色：两图边界像素的中位数（拼接底色与纸面一致，空白处不突兀）。"""
    edges = np.concatenate([
        a[:2].reshape(-1, 3), b[:2].reshape(-1, 3),
        a[-2:].reshape(-1, 3), b[-2:].reshape(-1, 3),
    ])
    return np.median(edges, axis=0)


def _compose_vertical(a, b, offset, overlap, seam_fade):
    """上下合成：A 在上，B 起点 (offset, ha-overlap)。重叠带内 B 淡入。"""
    ha, wa = a.shape[:2]
    hb, wb = b.shape[:2]
    pad_left = max(0, -offset)
    out_w = max(pad_left + wa, pad_left + offset + wb)
    out_h = ha + hb - overlap
    canvas = np.empty((out_h, out_w, 3), np.uint8)
    canvas[:] = _paper_color(a, b)
    # A 整块落下（B 不与 A 的非接缝区重叠）。
    canvas[0:ha, pad_left:pad_left + wa] = a
    # B：前 seam 行（且在 A 的重叠区内）做线性淡入，其余直接覆盖。
    y0 = ha - overlap
    seam = int(np.clip(seam_fade, 0, overlap)) if overlap > 0 else 0
    for i in range(hb):
        y = y0 + i
        if y < 0 or y >= out_h:
            continue
        x0 = pad_left + offset
        xs, xe = max(0, x0), min(out_w, x0 + wb)
        if xs >= xe:
            continue
        src = b[i, xs - x0:xe - x0]
        if seam > 0 and i < seam:
            alpha = (i + 1) / (seam + 1)
            under = canvas[y, xs:xe].astype(np.float32)
            canvas[y, xs:xe] = (under * (1 - alpha) + src.astype(np.float32) * alpha + 0.5).astype(np.uint8)
        else:
            canvas[y, xs:xe] = src
    return canvas
