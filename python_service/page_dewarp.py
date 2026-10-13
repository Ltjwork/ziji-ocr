"""书页摆正（校对摆正）的核心算法：智能裁切点检测 + 透视/弯边拉平 + 去色锐化。

前端「校对摆正」页把书页照片显示为 8 个可拖拽控制点（4 角 + 4 边中点，
仿白描），本模块负责对应的像素级处理：

- detect_page_quad：从照片自动找出书页四角（"智能分析裁切点"）。主路径
  是**墨迹对齐**：投影清晰度扫描找出文本行列的主方向（横排/竖排都识
  别），裁切框沿墨迹行列方向贴合内容块——矫正后文字正是横平竖直（用户
  指定的行为：不要分析正文内容，只要主要墨迹点的横竖对齐）。纸边轮廓
  仅在方向与墨迹一致时采用（保留页边距）；无墨迹信号时退回纸边/内缩
  全图兜底。
- dewarp_page：把四边形（四边可为二次贝塞尔弯边，弯边用于装订弯曲的
  书页）拉平成矩形。四边都直时用严格单应（getPerspectiveTransform +
  warpPerspective）；任一边弯曲时用 Coons patch 双向插值构造重采样网格
  （cv2.remap）。输出尺寸取对边弧长均值。
- enhance_page：去色（灰度 + 2%~98% 分位对比度拉伸）与锐化（unsharp
  mask）。

接口全部收发 ndarray，磁盘读写（中文路径）由 main.py 的 _imread /
imencode+tofile 负责，本模块保持纯函数便于单测。
"""

import math

import cv2
import numpy as np

# 检测用降采样上限：长边压到该值以内做轮廓分析，坐标最后再放大回原图。
_DETECT_MAX_DIM = 1000
# 轮廓法承认书页的最小面积占比。真页面在照片里是主体（≥35%）；调低到
# 20% 时，密排文字会被闭运算熔成 ~23% 的实心块冒充"纸"（PDF 白底页实
# 测：纸边无信号、暗极性通道抓到墨迹块，框成窄条裁掉大半页），且随后
# 的一致性判据会自我印证（按墨迹块拉正墨迹残余恒为 0°）。
_MIN_PAGE_AREA_RATIO = 0.35
# 判定"无需摆正"：四角离图像四角的最大偏差 < 对角线的该比例，且无弯边。
# 容差取小值：干净贴满全图的页（PDF 渲染，偏差≈0）如实跳过不产出假矫正；
# 而真实拍摄/扫描页哪怕 1-2° 的倾斜（偏差 2-4%）也要拉正——这正是用户
# 要的"点位贴着纸边、把页面转正"。
_FLAT_TOLERANCE_RATIO = 0.01
# 直边判定：边中点离弦中点小于该像素数视为直边（走单应路径）。
_STRAIGHT_EDGE_EPS = 1.0
# 墨迹掩码双档强度（自适应阈值的 C，即"比局部背景暗多少"）：
# 敏感档 15 用于对齐测量（淡笔也有信号）；强档 50 用于定框范围与含墨
# 校验——页边淡渍/扫描阴影的暗度中位仅 30-41，调高强度即被忽略（用户
# 指定：淡墨渍不该把橙框撑出去），真字笔画暗度中位 91-106 不受影响。
_INK_SENSITIVE_C = 15
_INK_STRONG_C = 50
# 墨迹框的深墨扩展：有效墨迹的渍块过滤（大而实心剔除）会连书缘黑带、
# 边框线一起剔掉（它们也"大而实心"），导致框切进书体。用强墨掩码
# （C=50，淡渍暗度 30-41 达不到）的成规模组件包围盒与墨迹框取并集：
# 深色书缘/边框包回来，淡渍不在强墨掩码里不受影响，白边裁切不回归。
# 组件门槛：面积 ≥0.02% 图幅或最长边 ≥1.5% 图幅（滤掉远处小墨斑）。
_DEEP_EXPAND_MIN_AREA = 0.0002
_DEEP_EXPAND_MIN_DIM = 0.015


# ---------------------------------------------------------------------------
# 角点检测
# ---------------------------------------------------------------------------

def detect_page_quad(img):
    """检测书页四角，返回 (points, method, trace)。

    points 为 TL,TR,BR,BL 顺序的原图像素坐标列表；method ∈
    {"ink", "contour", "default"}（ink=按墨迹行列对齐，contour=按纸边
    轮廓，default=无信号、内缩全图）。trace 为检测决策的诊断信息 dict
    （墨迹分析、纸边分析、一致性判据、判定原因），前端"检测日志"据此
    展示每页的智能边框是怎样确定的。
    """
    h, w = img.shape[:2]
    scale = min(1.0, _DETECT_MAX_DIM / max(h, w))
    if scale < 1.0:
        small = cv2.resize(
            img, (max(1, int(round(w * scale))), max(1, int(round(h * scale)))),
            interpolation=cv2.INTER_AREA,
        )
    else:
        small = img

    ink = _quad_from_ink(small)
    paper = _quad_from_contour(small)
    ink_quad, ink_info = ink if ink else (None, None)
    paper_quad, paper_info = paper if paper else (None, None)

    residual = None
    if paper_quad is not None:
        # 判据用"拉正后的残余倾角"而不是直接比角度：透视页上文字列倾角
        # 本来就从左到右渐变（实测 −2.5°→+4°），与纸边角的差会被透视
        # 误导。按纸边单应把墨迹拉正后残余 ≤1.2° → 纸边与文字一致
        # （干净扫描/正常拍摄的常态，用纸边框保留页边距）；残余更大 →
        # 文字与纸边真不一致，改按墨迹行列对齐（矫正后文字横平竖直，
        # 这正是用户要的效果）。
        residual = _ink_residual_angle(small, paper_quad)
        if paper_info.get("full_frame") and ink_quad is not None:
            # 纸边候选≈整图四角 = 页边与背景无反差（白底 PDF/渲染页）：
            # 没有真边界可贴，直接按墨迹框包裹内容区，裁掉周围空白。
            decision = (
                "纸边无信号（页边与背景无反差，贴满全图）：按墨迹行列包裹"
                f"内容区并裁掉周围空白（主方向角 "
                f"{ink_info['align_angle_deg']:.1f}°）"
            )
            pts, method = ink_quad, "ink"
        elif residual is None:
            decision = "墨迹信号不足，无法校验纸边与文字的一致性，采用纸边框"
            pts, method = paper_quad, "contour"
        elif abs(residual) <= 1.2:
            decision = (
                f"按纸边拉正后墨迹残余 {residual:.1f}°（≤1.2°）：纸边与文字"
                "方向一致，采用纸边框（保留页边距）"
            )
            pts, method = paper_quad, "contour"
        elif ink_quad is None:
            decision = (
                f"按纸边拉正后墨迹残余 {residual:.1f}°（>1.2°），文字与纸边"
                "不一致，但墨迹包围盒不可用，仍采用纸边框（建议手动调整）"
            )
            pts, method = paper_quad, "contour"
        else:
            decision = (
                f"按纸边拉正后墨迹残余 {residual:.1f}°（>1.2°）：文字与纸边"
                f"方向不一致，改按墨迹行列对齐（主方向角 "
                f"{ink_info['align_angle_deg']:.1f}°）"
            )
            pts, method = ink_quad, "ink"
    elif ink_quad is not None:
        decision = "未检测到纸边信号（页边与背景无反差），按墨迹行列对齐"
        pts, method = ink_quad, "ink"
    else:
        decision = "墨迹与纸边均无有效信号（空页或反差全无），内缩全图，请手动调整"
        pts, method = _default_quad(small), "default"

    if paper_info is not None and paper_info.get("full_frame") and method == "contour":
        decision += "；纸边候选≈整图四角（贴满全图，通常无需摆正）"

    # 源图最大暗色块量测（纯诊断，不影响任何判定）：黑底/黑边导入进来
    # 的页面会被轮廓法当成"纸"（两种极性都试，黑色大块恰好全过过滤），
    # 校对摆正显示"小页+大圈黑边"。trace 带上这块的占比与位置，检测
    # 日志能直接说明"黑边是怎么进来的、有多大"。
    dark_region = dark_region_stats(small)
    if dark_region is not None and dark_region["share"] >= 0.05:
        decision += (
            f"；⚠ 源图有占 {dark_region['share'] * 100:.0f}% 的近黑暗块"
            f"（均亮 {dark_region['luma']:.0f}）——若 PDF/原稿没有黑边黑底，"
            "请检查导入来源"
        )

    trace = {
        "ink": ink_info,
        "paper": paper_info,
        "residual_after_paper_deg": None if residual is None else round(residual, 2),
        "decision": decision,
        "threshold_deg": 1.2,
        "scan_range_deg": 12.0,
        "scan_step_deg": 0.5,
    }
    if dark_region is not None and dark_region["share"] >= 0.02:
        inv = 1.0 / scale
        bx, by, bw, bh = dark_region["bbox"]
        trace["source_dark_region"] = {
            "share": dark_region["share"],
            "luma": dark_region["luma"],
            "bbox": [
                int(round(bx * inv)),
                int(round(by * inv)),
                int(round(bw * inv)),
                int(round(bh * inv)),
            ],
        }
    pts = _order_corners(np.asarray(pts, dtype=np.float64))
    if scale < 1.0:
        pts = pts / scale
    return [p.tolist() for p in pts], method, trace


def _default_quad(img):
    h, w = img.shape[:2]
    mx, my = 0.02 * w, 0.02 * h
    return np.array(
        [[mx, my], [w - 1 - mx, my], [w - 1 - mx, h - 1 - my], [mx, h - 1 - my]],
        dtype=np.float64,
    )


# ---------------------------------------------------------------------------
# 墨迹对齐检测（主路径）
# ---------------------------------------------------------------------------

def _quad_tilt(quad):
    """四边形纵向边的倾角（度，0=竖直）。取左、右两条竖边向量的均值。

    透视下对边角度略有差异，均值足够做"墨迹 vs 纸边是否同向"的判断。"""

    def tilt(a, b):
        dx, dy = b[0] - a[0], b[1] - a[1]
        if abs(dy) < 1e-6:
            return 90.0
        return math.degrees(math.atan2(dx, dy))

    tl, tr, _br, bl = quad
    return (tilt(tl, bl) + tilt(tr, quad[2])) / 2.0


def _ink_mask(small, c=_INK_SENSITIVE_C):
    """墨迹掩码：自适应阈值（抗阴影渐变）取暗色笔迹，去小噪点。

    [c] 为强度（比局部背景暗多少才算墨）：敏感档对齐测量用，强档
    定框/校验用（忽略页边淡渍）。"""
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    ink = cv2.adaptiveThreshold(
        gray, 255, cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY_INV, 31, c
    )
    ink = cv2.medianBlur(ink, 3)
    return cv2.morphologyEx(ink, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))


def _effective_ink(small):
    """有效墨迹（定框/含墨校验用）：三重过滤区分文字与渍。

    ① 强核邻域：强墨 ±9px 内的墨全保留（贴着深笔画的淡字不丢）；
    ② 结构过滤：大且实心的连通块（凸包填充率 >0.75 且面积 >0.5% 图幅）
       判为渍/阴影——无论深浅一律丢弃（深色渍靠对比度杀不掉，靠形状）；
       小组件（字符/笔画/栏线）与稀疏排布的块保留；
    ③ 近邻过滤：无强核的小组件须距深墨 ≤25px（文字密集成片，孤立
       远处小斑点丢弃）。
    整页淡墨（有效墨损失过半）退回敏感掩码，不丢内容。
    返回 (eff, stats)；stats 供检测日志展示过滤细节。"""
    sens = _ink_mask(small)
    strong = _ink_mask(small, c=_INK_STRONG_C)
    hh_, ww_ = sens.shape[:2]
    frame = float(hh_ * ww_)
    core = cv2.dilate(strong, np.ones((9, 9), np.uint8))
    near = cv2.dilate(strong, np.ones((25, 25), np.uint8))
    eff = sens.copy()
    eff[core == 0] = 0
    n, labels, stats, _ = cv2.connectedComponentsWithStats(
        (sens > 0).astype(np.uint8)
    )
    stain_count = 0
    stain_area = 0
    for i in range(1, n):
        x, y, cw, ch, area = stats[i]
        comp = labels == i
        drop = False
        if area > 0.005 * frame:
            cnts, _ = cv2.findContours(
                comp.astype(np.uint8) * 255, cv2.RETR_EXTERNAL,
                cv2.CHAIN_APPROX_SIMPLE,
            )
            hull_area = 0.0
            if cnts:
                hull_area = cv2.contourArea(cv2.convexHull(cnts[0]))
            fill = area / hull_area if hull_area > 0 else 1.0
            # 大而实心 = 渍/阴影块（深色渍也逃不掉：形状与文字不同）。
            if fill > 0.75:
                stain_count += 1
                stain_area += area
                eff[comp] = 0
                drop = True
        if not drop and (strong[comp] == 0).all():
            # 无强核的小组件：距深墨太远的孤立斑点丢弃。
            if not (near[comp] > 0).any():
                eff[comp] = 0
            else:
                eff[comp] = sens[comp]
    sens_px = int((sens > 0).sum())
    eff_px = int((eff > 0).sum())
    fallback = eff_px < 0.4 * sens_px
    info = {
        "sensitive_px": sens_px,
        "strong_px": int((strong > 0).sum()),
        "effective_px": eff_px,
        "retention": round(eff_px / sens_px, 4) if sens_px else 1.0,
        "stains_dropped": stain_count,
        "stain_px_dropped": int(stain_area),
        "fallback_sensitive": bool(fallback),
    }
    if fallback:
        return sens, info
    return eff, info


def _scan_align_angle(ink):
    """投影清晰度扫描：找出使文本"行"水平的旋转角。

    横排文本的行在行方向投影上尖锐（行间空白），竖排文本转置后同理——
    两个方向都扫，取清晰度峰值更高者。返回 (score, angle, transposed,
    zero_score)：zero_score 为最优方向在 0° 的得分，score/zero_score 即
    "确有倾斜"的置信比（≈1 说明本来就把得正）。
    """
    best = None
    best_zero = None
    for transposed in (False, True):
        m = ink.T if transposed else ink
        hh, ww = m.shape
        center = (ww / 2.0, hh / 2.0)
        zero_score = None
        for angle in np.arange(-12.0, 12.01, 0.5):
            rot = cv2.warpAffine(
                m,
                cv2.getRotationMatrix2D(center, float(angle), 1.0),
                (ww, hh),
                flags=cv2.INTER_NEAREST,
            )
            proj = rot.sum(axis=1).astype(np.float64)
            score = float((proj * proj).sum())
            if angle == 0.0:
                zero_score = score
            if best is None or score > best[0]:
                best = (score, float(angle), transposed)
                best_zero = zero_score if zero_score is not None else score
    return best[0], best[1], best[2], best_zero


def _ink_residual_angle(small, paper_quad):
    """按纸边四边形把墨迹单应拉正后，扫描残余倾角（度）。

    返回 None 表示墨迹信号不足（无从判断，视作与纸边一致）。近 0 =
    纸边矫正后文字已经横平竖直；非 0 = 文字与纸边方向不一致。"""
    ink = _ink_mask(small)
    if ink.sum() < 255 * 300:
        return None
    tl, tr, br, bl = [np.asarray(p, dtype=np.float64) for p in paper_quad]
    out_w = int(max(32.0, (np.linalg.norm(tr - tl) + np.linalg.norm(br - bl)) / 2))
    out_h = int(max(32.0, (np.linalg.norm(bl - tl) + np.linalg.norm(br - tr)) / 2))
    src = np.float32([tl, tr, br, bl])
    dst = np.float32(
        [[0, 0], [out_w - 1, 0], [out_w - 1, out_h - 1], [0, out_h - 1]]
    )
    M = cv2.getPerspectiveTransform(src, dst)
    warped = cv2.warpPerspective(
        ink, M, (out_w, out_h), flags=cv2.INTER_NEAREST
    )
    _score, angle, _t, _z = _scan_align_angle(warped)
    return angle


def _quad_from_ink(small):
    """按墨迹行列对齐的裁切框：投影扫描定主方向 → 旋正取墨迹包围盒 →
    外扩少量余量 → 旋回原方向。

    返回 (quad, info)：无有效墨迹（空页/覆盖率异常）返回 None。
    info 供前端"检测日志"展示判定依据。"""
    ink = _ink_mask(small)
    frac = float((ink > 0).mean())
    if ink.sum() < 255 * 300 or not (0.002 < frac < 0.7):
        return None

    score, angle, transposed, zero_score = _scan_align_angle(ink)
    confidence = score / zero_score if zero_score and zero_score > 0 else 1.0
    # 定框范围用"有效墨迹"（结构过滤见 _effective_ink）：同页淡字保留，
    # 淡渍/深色渍都按形状剔除。
    ink_eff, mask_stats = _effective_ink(small)
    m = ink_eff.T if transposed else ink_eff
    hh, ww = m.shape
    center = (ww / 2.0, hh / 2.0)
    rot = cv2.warpAffine(
        m,
        cv2.getRotationMatrix2D(center, angle, 1.0),
        (ww, hh),
        flags=cv2.INTER_NEAREST,
    )
    ys, xs = np.where(rot > 0)
    if len(xs) < 50:
        return None
    x0, x1 = float(xs.min()), float(xs.max())
    y0, y1 = float(ys.min()), float(ys.max())

    # 深墨扩展：渍块过滤（大而实心剔除）会连书缘黑带、边框线一起剔掉
    # （它们也"大而实心"），导致框切进书体（真实封面页实测：书占图
    # 2%-95%，墨迹框只到 8%-87%）。用强墨掩码的成规模组件包围盒与墨迹
    # 框取并集——淡渍（暗度 30-41）不在强墨掩码里不受影响，白边裁切
    # 不回归。
    strong = _ink_mask(small, c=_INK_STRONG_C)
    m_strong = strong.T if transposed else strong
    strong_rot = cv2.warpAffine(
        m_strong,
        cv2.getRotationMatrix2D(center, angle, 1.0),
        (ww, hh),
        flags=cv2.INTER_NEAREST,
    )
    sn, slabels, sstats, _ = cv2.connectedComponentsWithStats(
        (strong_rot > 0).astype(np.uint8)
    )
    min_area = _DEEP_EXPAND_MIN_AREA * ww * hh
    min_dim = _DEEP_EXPAND_MIN_DIM * max(ww, hh)
    sx0 = sy0 = float("inf")
    sx1 = sy1 = float("-inf")
    for i in range(1, sn):
        x, y, cw, ch, area = sstats[i]
        if area < min_area and max(cw, ch) < min_dim:
            continue
        sx0, sy0 = min(sx0, float(x)), min(sy0, float(y))
        sx1, sy1 = max(sx1, float(x + cw - 1)), max(sy1, float(y + ch - 1))
    ring_expanded = False
    if sx1 > sx0 and (sx0 < x0 or sy0 < y0 or sx1 > x1 or sy1 > y1):
        x0, x1 = min(x0, sx0), max(x1, sx1)
        y0, y1 = min(y0, sy0), max(y1, sy1)
        ring_expanded = True

    # 外扩余量：别贴着字切（版框/页眉页脚常紧贴墨迹边缘）。
    x0 -= 0.03 * (x1 - x0)
    x1 += 0.03 * (x1 - x0)
    y0 -= 0.03 * (y1 - y0)
    y1 += 0.03 * (y1 - y0)
    corners_r = np.array(
        [[x0, y0], [x1, y0], [x1, y1], [x0, y1]], dtype=np.float32
    ).reshape(-1, 1, 2)
    corners = cv2.transform(
        corners_r,
        cv2.getRotationMatrix2D(center, -angle, 1.0),
    ).reshape(-1, 2).astype(np.float64)
    if transposed:
        corners = corners[:, ::-1]  # (x,y)→(y,x) 回到原图坐标

    sh, sw = small.shape[:2]
    # 框必须完全在图内（用户要求：出界的控制点拖拽困难）。墨迹都在图
    # 内，夹回图像边界不会切掉有效墨迹（有效墨迹口径实测切墨 0.0%）。
    corners[:, 0] = corners[:, 0].clip(0, sw - 1)
    corners[:, 1] = corners[:, 1].clip(0, sh - 1)
    quad = _order_corners(corners)
    # 墨迹块太小（印章/页脚残字）不作为页面主方向依据。
    if cv2.contourArea(quad.reshape(-1, 1, 2).astype(np.float32)) < 0.1 * sw * sh:
        return None
    info = {
        "available": True,
        "coverage": round(frac, 4),
        "mask_stats": mask_stats,
        "orientation": "columns" if transposed else "rows",
        "align_angle_deg": round(angle, 2),
        "confidence": round(confidence, 2),
        "deep_expanded": ring_expanded,
        "quad_area_ratio": round(
            cv2.contourArea(quad.reshape(-1, 1, 2).astype(np.float32))
            / float(sw * sh),
            4,
        ),
    }
    return quad, info


def _quad_corners_of_contour(c):
    """取轮廓的 4 个真实角点：minAreaRect 求页面主方向，把轮廓点旋正后
    按对角极值（x+y、x−y 的最值）取角——角点直接来自轮廓上的真实点，
    同时贴合纸的旋转与透视（梯形页的"缺角"不外扩）。"""
    (cx, cy), (rw, rh), angle = cv2.minAreaRect(c)
    if rw <= 0 or rh <= 0:
        return None
    pts32 = c.astype(np.float32).reshape(-1, 1, 2)
    M = cv2.getRotationMatrix2D((cx, cy), angle, 1.0)
    pts = cv2.transform(pts32, M).reshape(-1, 2)
    s = pts[:, 0] + pts[:, 1]
    d = pts[:, 0] - pts[:, 1]
    corners_r = np.stack(
        [pts[np.argmin(s)], pts[np.argmax(d)], pts[np.argmax(s)], pts[np.argmin(d)]]
    )
    Minv = cv2.getRotationMatrix2D((cx, cy), -angle, 1.0)
    return cv2.transform(corners_r.reshape(-1, 1, 2), Minv).reshape(-1, 2)


def _is_full_frame(box, w, h):
    """候选框是否≈整图四角（无页面边界信号：干净渲染/PDF 页）。"""
    tol = 0.015 * float(np.hypot(w, h))
    frame = np.array(
        [[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]], dtype=np.float64
    )
    ob = _order_corners(np.asarray(box, dtype=np.float64))
    return bool(np.linalg.norm(ob - frame, axis=1).max() < tol)


def _quad_from_contour(img):
    """轮廓法：按亮度 Otsu 把"纸 vs 背景"分开（两种极性都试，纸通常
    比背景亮也可能更暗），页面色块取真实角点得到贴合纸边倾斜与透视的
    四边形——效果即"框贴着拍歪的纸边"。

    返回 (quad, info) 或 None；info 供"检测日志"展示。"""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)
    _, otsu = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY | cv2.THRESH_OTSU)

    h, w = img.shape[:2]
    frame_area = float(w * h)
    min_area = _MIN_PAGE_AREA_RATIO * frame_area

    def info_of(c, box, full_frame):
        (_cx, _cy), (rw, rh), _ang = cv2.minAreaRect(c)
        return {
            "available": True,
            "area_ratio": round(cv2.contourArea(c) / frame_area, 4),
            "fill_ratio": round(cv2.contourArea(c) / (rw * rh), 4),
            "full_frame": bool(full_frame),
            "quad_tilt_deg": round(_quad_tilt(_order_corners(np.asarray(box, dtype=np.float64))), 2),
        }

    fallback_full_frame = None  # (area, box, info)：整图候选兜底用

    # 真纸边必须包含几乎全部墨迹：字一定印在纸上。表格/题名块等子区域
    # 会以高填充率冒充"纸"，而残余判据只看框内墨迹（框内自洽），拦不住
    # 这种漏字的假框。校验用**强墨口径 + 95% 阈值**：真纸边外的强墨应≈0
    #（纸边外侧自适应阈值产生的窄伪墨迹带属边缘效应，膨胀 8px 豁免）；
    # 曾用全墨迹+90% 阈值，真实页实测纸框恰好切掉 9.7% 强墨从阈值下
    # 溜过（page_001 教训）。
    strong = _ink_mask(img, c=_INK_STRONG_C)
    strong_total = int((strong > 0).sum())

    def ink_inside_ratio(box):
        if strong_total == 0:
            return 1.0
        inside = np.zeros(img.shape[:2], np.uint8)
        cv2.fillPoly(
            inside, [np.asarray(box, np.float64).round().astype(np.int32)], 255
        )
        inside_dil = cv2.dilate(inside, np.ones((17, 17), np.uint8))
        far_outside = int(((strong > 0) & (inside_dil == 0)).sum())
        return 1.0 - far_outside / strong_total

    def info_of_with_ink(c, box, full_frame):
        info = info_of(c, box, full_frame)
        info["ink_inside_ratio"] = round(ink_inside_ratio(box), 4)
        return info

    for mask in (otsu, cv2.bitwise_not(otsu)):
        closed = cv2.morphologyEx(
            mask, cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8)
        )
        contours, _ = cv2.findContours(
            closed, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        for c in sorted(contours, key=cv2.contourArea, reverse=True)[:5]:
            area = cv2.contourArea(c)
            if area < min_area:
                break
            (_cx, _cy), (rw, rh), _ang = cv2.minAreaRect(c)
            if rw <= 0 or rh <= 0:
                continue
            # 填充率：一页纸是实心矩形，枝杈状/细长的色块不算。
            if area / (rw * rh) < 0.55:
                continue
            box = _quad_corners_of_contour(c)
            if box is None:
                continue
            if _is_full_frame(box, w, h):
                # ≈整图四角的色块 = 无页面边界信号（干净渲染/PDF 页），
                # 只在没有"真页面"候选时兜底。
                if (
                    fallback_full_frame is None
                    or area > fallback_full_frame[0]
                ):
                    fallback_full_frame = (
                        area,
                        box,
                        info_of_with_ink(c, box, True),
                    )
                continue
            # 漏墨过滤：框外远处强墨超过 5% → 是子区域不是整页。
            if ink_inside_ratio(box) < 0.95:
                continue
            quad = _order_corners(np.asarray(box, dtype=np.float64))
            return quad, info_of_with_ink(c, box, False)

    if fallback_full_frame is not None:
        quad = _order_corners(
            np.asarray(fallback_full_frame[1], dtype=np.float64)
        )
        return quad, fallback_full_frame[2]
    return None


def _order_corners(pts):
    """把 4 个点排成 TL,TR,BR,BL。

    和值 x+y 最小者是左上、最大者是右下；差值 y-x 最小者是右上、最大者
    是左下。对适度旋转（<45°）的四边形都成立，不依赖轮廓遍历顺序。
    """
    s = pts.sum(axis=1)
    d = pts[:, 1] - pts[:, 0]
    return np.array(
        [pts[np.argmin(s)], pts[np.argmin(d)], pts[np.argmax(s)], pts[np.argmax(d)]],
        dtype=np.float64,
    )


def quad_needs_warp(w, h, corners, edge_mids=None):
    """检测到的四边形是否已足够"正"，可跳过拉平（批量模式的自动跳过）。

    四角都贴近图像四角（偏差 < 对角线 1.5%）且没有弯边时返回 False。
    """
    corners = np.asarray(corners, dtype=np.float64)
    img_corners = np.array(
        [[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]], dtype=np.float64
    )
    tol = _FLAT_TOLERANCE_RATIO * float(np.hypot(w, h))
    if np.linalg.norm(corners - img_corners, axis=1).max() < tol:
        if not edge_mids:
            return False
        for (a, b), mid in zip(
            ((0, 1), (1, 2), (2, 3), (3, 0)),
            (edge_mids.get(k) for k in ("top", "right", "bottom", "left")),
        ):
            if mid is None:
                continue
            chord_mid = (corners[a] + corners[b]) / 2.0
            if np.linalg.norm(np.asarray(mid, dtype=np.float64) - chord_mid) >= _STRAIGHT_EDGE_EPS:
                return True
        return False
    return True


# ---------------------------------------------------------------------------
# 拉平（单应 / Coons patch）
# ---------------------------------------------------------------------------

def _edge_control(a, b, mid):
    """边的二次贝塞尔控制点：曲线过 mid，则 C = 2·mid − (A+B)/2。"""
    if mid is None:
        mid = (a + b) / 2.0
    return 2.0 * np.asarray(mid, dtype=np.float64) - (a + b) / 2.0


def _bezier(a, ctrl, b, t):
    """二次贝塞尔批量求值。t 为任意形状数组，返回同形状的点集 (…,2)。"""
    t = np.asarray(t, dtype=np.float64)[..., None]
    return (1 - t) ** 2 * a + 2 * (1 - t) * t * ctrl + t**2 * b


def _bezier_length(a, ctrl, b, samples=64):
    t = np.linspace(0.0, 1.0, samples)
    pts = _bezier(a, ctrl, b, t)
    return float(np.hypot(*(np.diff(pts, axis=0).T)).sum())


def dewarp_page(img, corners, edge_mids=None):
    """把 corners 四边形（边可弯曲）拉平成矩形，返回 (out, out_w, out_h)。

    corners：TL,TR,BR,BL 像素坐标；edge_mids：dict，键 top/right/bottom/
    left，值为该边中点的实际像素坐标（缺省或落在弦中点附近 = 直边）。
    四边全直走严格单应（透视拍摄的平面页这是正确模型）；任一边弯曲走
    Coons patch（边界曲线双向插值），装订弯曲页借此摊平。两种路径的
    出界区域都填白。
    """
    corners = np.asarray(corners, dtype=np.float64)
    if corners.shape != (4, 2):
        raise ValueError("corners must be 4 [x,y] points")
    mids = {
        k: (np.asarray(edge_mids[k], dtype=np.float64) if edge_mids and k in edge_mids and edge_mids[k] is not None else None)
        for k in ("top", "right", "bottom", "left")
    }
    tl, tr, br, bl = corners
    ctrls = {
        "top": _edge_control(tl, tr, mids["top"]),
        "right": _edge_control(tr, br, mids["right"]),
        "bottom": _edge_control(bl, br, mids["bottom"]),
        "left": _edge_control(tl, bl, mids["left"]),
    }
    bent = any(
        mids[k] is not None
        and np.linalg.norm(
            mids[k] - (corners[i] + corners[(i + 1) % 4]) / 2.0
        ) >= _STRAIGHT_EDGE_EPS
        for i, k in enumerate(("top", "right", "bottom", "left"))
    )

    out_w = max(
        8,
        int(
            round(
                (
                    _bezier_length(tl, ctrls["top"], tr)
                    + _bezier_length(bl, ctrls["bottom"], br)
                )
                / 2.0
            )
        ),
    )
    out_h = max(
        8,
        int(
            round(
                (
                    _bezier_length(tl, ctrls["left"], bl)
                    + _bezier_length(tr, ctrls["right"], br)
                )
                / 2.0
            )
        ),
    )

    if not bent:
        src = np.float32(corners)
        dst = np.float32(
            [[0, 0], [out_w - 1, 0], [out_w - 1, out_h - 1], [0, out_h - 1]]
        )
        mat = cv2.getPerspectiveTransform(src, dst)
        out = cv2.warpPerspective(
            img, mat, (out_w, out_h),
            flags=cv2.INTER_CUBIC,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=(255, 255, 255),
        )
        return out, out_w, out_h

    # Coons patch：P(u,v) = (1-v)T(u) + vB(u) + (1-u)L(v) + uR(v)
    #                     - 双线性角点修正项。
    # 目标像素 (u,v) 反查源坐标，直接喂 cv2.remap。
    u = np.linspace(0.0, 1.0, out_w)
    v = np.linspace(0.0, 1.0, out_h)
    uu, vv = np.meshgrid(u, v)  # (out_h, out_w)
    top = _bezier(tl, ctrls["top"], tr, uu)
    bottom = _bezier(bl, ctrls["bottom"], br, uu)
    left = _bezier(tl, ctrls["left"], bl, vv)
    right = _bezier(tr, ctrls["right"], br, vv)
    # 4 个角点广播成 (1,1,2)，与 (out_h,out_w) 的参数网格逐点组合。
    c_tl, c_tr = corners[0][None, None, :], corners[1][None, None, :]
    c_br, c_bl = corners[2][None, None, :], corners[3][None, None, :]
    bilinear = (
        (1 - uu)[..., None] * (1 - vv)[..., None] * c_tl
        + uu[..., None] * (1 - vv)[..., None] * c_tr
        + (1 - uu)[..., None] * vv[..., None] * c_bl
        + uu[..., None] * vv[..., None] * c_br
    )
    pts = (
        (1 - vv)[..., None] * top
        + vv[..., None] * bottom
        + (1 - uu)[..., None] * left
        + uu[..., None] * right
        - bilinear
    )
    map_x = pts[..., 0].astype(np.float32)
    map_y = pts[..., 1].astype(np.float32)
    out = cv2.remap(
        img, map_x, map_y, cv2.INTER_CUBIC,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(255, 255, 255),
    )
    return out, out_w, out_h


# ---------------------------------------------------------------------------
# 增强（去透印 / 去色 / 锐化）与暗块量测已拆分至 page_enhance.py。
# 此处 re-export 保持既有 import 面（page_dewarp.enhance_page 等调用方
# 与 `from page_dewarp import ...` 的测试）不变。
# ---------------------------------------------------------------------------
from page_enhance import (  # noqa: E402,F401
    dark_region_stats,
    enhance_page,
    pixmap_rgb_array,
    remove_show_through,
)
