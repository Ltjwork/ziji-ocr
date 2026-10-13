# -*- coding: utf-8 -*-
"""书页成像增强：去透印 / 去色 / 锐化 / 暗块量测（从 page_dewarp 拆出）。

与几何矫正（角点检测 + 拉平，留在 page_dewarp.py）分离的原因：两者职责
不同——增强是纯像素处理、不依赖任何几何结果；page_dewarp 经
`from page_enhance import ...` re-export 保持既有 import 面不变。
接口全部收发 ndarray，本模块保持纯函数便于单测。
"""

import cv2
import numpy as np

# ---------------------------------------------------------------------------
# 增强（去透印 / 去色 / 锐化）
# ---------------------------------------------------------------------------

# 去透印：背景估计网格长边。块内只要有一角纸隙就能取到纸色（局部
# 最亮成分是纸，墨迹再密也拉不低背景面）。
_SHOW_THROUGH_GRID = 400
# 背景最大值滤波核长 = 网格长边 × 该比例（半径须盖过最粗笔画半宽；
# 深入纯墨块内部取不到纸色的部分由"按原始深浅保护深墨"兜底）。
_SHOW_THROUGH_MAX_FRAC = 0.10


def remove_show_through(img, strength=50):
    """去透印：把背面/下一页透出来的浅色文字压成纸白，保留深色主墨。

    strength 1..100，越大压得越狠（会伤到最淡的主字，由滑块权衡）。
    做法：灰度在粗网格上取"局部最亮"并经中值回填得到纸色背景面（最
    亮值不会被墨迹拉低，背景面处处 ≥ 原灰度）→ 逐点除背景得墨深信号
    d（纸面≈0，透印中灰，主墨最深，光照不匀一并拉平）→ 按强度软阈值
    映射成保留系数（透印带→0，主墨→1，纸面→0 洗白）→ 与"原始像素越
    深越保"的保护系数取大（粗墨核心不丢；逐点独立计算，不会像旧的
    "背景过暗区整体跳过"那样在粗字周围留一圈原纸色灰块）→ 按系数逐
    通道压暗度（纸面净化为白，墨色色相保留）。返回 BGR uint8。
    """
    s = max(1, min(100, int(strength))) / 100.0
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape[:2]
    # 纸色背景面：粗网格横向+纵向各一次最大值滤波（max 可分离，墨迹
    # 只可能抬不低）→ 中值回填深入纯墨取不到纸色的网格 → 平滑放大。
    scale = min(1.0, _SHOW_THROUGH_GRID / max(h, w))
    if scale < 1.0:
        small = cv2.resize(
            gray,
            (max(1, int(round(w * scale))), max(1, int(round(h * scale)))),
            interpolation=cv2.INTER_AREA,
        )
    else:
        small = gray
    k_max = max(15, int(round(_SHOW_THROUGH_MAX_FRAC * max(small.shape[:2]))))
    k_max += 1 - k_max % 2  # 偶数转奇数
    bg = cv2.dilate(small, cv2.getStructuringElement(cv2.MORPH_RECT, (k_max, 1)))
    bg = cv2.dilate(bg, cv2.getStructuringElement(cv2.MORPH_RECT, (1, k_max)))
    k_med = max(9, k_max // 2)
    k_med += 1 - k_med % 2
    if k_med > min(small.shape[:2]):
        k_med = min(small.shape[:2])
        k_med -= 1 - k_med % 2
    if k_med >= 3:
        bg = cv2.medianBlur(bg, k_med)
    if scale < 1.0:
        bg = cv2.resize(bg, (w, h), interpolation=cv2.INTER_LINEAR)
    bg = bg.astype(np.float32)
    # 墨深信号：背景归一化后离纸色有多远（不匀光照/纸色深浅一并消掉）。
    d = 255.0 - np.clip(gray.astype(np.float32) * 255.0 / np.maximum(bg, 1.0), 0, 255)
    # 强度 → 软阈值带中心（低强度只压淡透印，高强度连较深透印一起压），
    # 带内线性过渡取平方（偏向压制、主墨全保），纸纹噪点随之洗净。
    center = 30.0 + 55.0 * s
    t_weak = center - 18.0
    t_strong = center + 18.0
    keep = np.clip((d - t_weak) / (t_strong - t_weak), 0.0, 1.0) ** 2
    # 深墨保护：按原始灰度逐点判深浅（<70 全保，>130 不保），粗墨核心
    # 与插图深色部分不丢。
    keep = np.maximum(
        keep, np.clip((130.0 - gray.astype(np.float32)) / 60.0, 0.0, 1.0)
    )
    dark = 255.0 - img.astype(np.float32)
    out = 255.0 - dark * keep[..., None]
    return np.clip(out, 0, 255).astype(np.uint8)


def enhance_page(img, grayscale=False, sharpen=False, debleed=False,
                 debleed_strength=50):
    """去透印、去色（灰度 + 分位对比度拉伸）与锐化（unsharp mask），
    顺序固定：先去透印（把透印背景洗净，后续拉伸才不会把透印再放大）
    再去色后锐化。返回处理后的 BGR 图。"""
    out = img
    if debleed:
        out = remove_show_through(out, debleed_strength)
    if grayscale:
        g = cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)
        lo, hi = np.percentile(g, (2, 98))
        if hi - lo >= 8:
            # 拉伸前先判平坦图（lo/hi 几乎重合），避免把扫描噪声放大成雪花。
            g = np.clip(
                (g.astype(np.float32) - lo) * 255.0 / (hi - lo), 0, 255
            ).astype(np.uint8)
        out = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
    if sharpen:
        blur = cv2.GaussianBlur(out, (0, 0), 2.0)
        out = cv2.addWeighted(out, 1.6, blur, -0.6, 0)
    return out


# ---------------------------------------------------------------------------
# 源图暗色块诊断（纯量测，不影响任何判定行为）
# ---------------------------------------------------------------------------

_DARK_REGION_LUMA = 64  # 亮度低于此的像素算"近黑"
_DARK_REGION_THUMB = 320  # 量测前降采样到的长边上限


def dark_region_stats(img, dark_luma=_DARK_REGION_LUMA):
    """量测图像里最大的"近黑连通块"（诊断导入黑边/黑底用，不改行为）。

    背景：有些 PDF 页渲染出的 PNG 自带一大圈黑边/黑底（盒径不一致或
    页内有黑底对象），轮廓法两种极性都试，这块黑会全过过滤被当成
    "纸"，校对摆正里显示成"小页 + 大圈黑边"。本函数找出最大暗色块，
    返回 dict（share=占图幅比、bbox=[x,y,w,h] 原图像素、luma=块内平均
    亮度）或 None（最大暗块 <5% 图幅）。

    白纸上的字笔画在缩样上是细小独立组件，开运算后抢不到最大块——
    能成为最大块的是成片的黑。内嵌黑环（外围还有白边）与贴边黑底都
    能量到。供 /pdf_to_images 逐页日志与 detect_page_quad 的 trace 使用。
    """
    if img.ndim == 3:
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    else:
        gray = img
    h, w = gray.shape[:2]
    scale = min(1.0, _DARK_REGION_THUMB / max(h, w))
    if scale < 1.0:
        gray = cv2.resize(
            gray,
            (max(1, int(round(w * scale))), max(1, int(round(h * scale)))),
            interpolation=cv2.INTER_AREA,
        )
    th, tw = gray.shape[:2]
    dark = (gray < dark_luma).astype(np.uint8)
    # 开运算去掉细笔画/噪点（缩样上文字只有 1-2px 宽），留下成片的黑。
    dark = cv2.morphologyEx(dark, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
    n, labels, stats, _ = cv2.connectedComponentsWithStats(dark, connectivity=8)
    if n <= 1:
        return None
    k = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    share = float(stats[k, cv2.CC_STAT_AREA]) / float(th * tw)
    if share < 0.05:
        return None
    x = int(stats[k, cv2.CC_STAT_LEFT])
    y = int(stats[k, cv2.CC_STAT_TOP])
    bw = int(stats[k, cv2.CC_STAT_WIDTH])
    bh = int(stats[k, cv2.CC_STAT_HEIGHT])
    luma = float(gray[labels == k].mean())
    inv = 1.0 / scale
    return {
        "share": round(share, 4),
        "bbox": [
            int(round(x * inv)),
            int(round(y * inv)),
            int(round(bw * inv)),
            int(round(bh * inv)),
        ],
        "luma": round(luma, 1),
    }


def pixmap_rgb_array(pix):
    """fitz Pixmap → H×W×C uint8 ndarray（samples 前段切片视图，只读用）。

    stride 可能带行填充，按 w*n 取前段再 reshape，兼容各版本 PyMuPDF。"""
    arr = np.frombuffer(pix.samples, dtype=np.uint8)
    expected = pix.height * pix.width * pix.n
    if arr.size < expected:
        raise ValueError(f"pixmap samples too small: {arr.size} < {expected}")
    return arr[:expected].reshape(pix.height, pix.width, pix.n)
