# -*- coding: utf-8 -*-
"""版面区预标注（规则 + 跨页一致性）与区域几何精修。

为 region_det 多类标注（词表见 train_data.LAYER_INFO["region_det"]，Dart 侧
flutter_app/lib/models/models.dart 的 regionLabels 是同一协议的另一半）提供
三个纯函数，全部只读、从不写 annotations 目录（落盘权在 Flutter）：

① suggest_regions：横排条带（顶/底墨迹聚行、孤立短列）与竖排列（书耳/
   天头眉批列/边栏书名/版心题名叶码——按列投影 × 行簇切分，与横排路径
   对称）→ header/footer/page_number/margin_note 的 proposed 建议区，辅以
   页码文字模式与跨页同位重复文字加权（main_text 不自动建议——正文边界
   由人工/inferHierarchy 兜底更可靠）。
② refine_regions：任意来源（规则/VLM）粗框的几何安全层——钳回图内、
   墨迹收紧（复用 layout_refinement.ink_rect）、词表校验、近重复去除。
   VLM 坐标只当粗框，像素精度由这里的几何保证。
③ prelabel_page_image：VLM 整页预标注素材图（降采样 + 网格坐标刻度 +
   已有区域半透明底色），给 VLM 的归一化坐标输出一个可见参考系。
"""
import base64
import os
import re
from typing import Any

import cv2
import numpy as np

from layout_refinement import ink_rect, overlap
from seg_imaging import _imread, _text_mask_for_refinement
from seg_layout import region_label
from table_grid import detect_tables_in_page
from train_data import LAYER_INFO, _annotation_pages, _book_dirs_under, _image_size

# 顶/底条带占页高比例：古籍天头（眉批/书名）与地脚（页脚/叶码）的活动范围。
TOP_STRIP_RATIO = 0.15
BOTTOM_STRIP_RATIO = 0.15
# 左右边条占页宽比例（书耳/边栏书名/边栏叶码竖列的活动范围）。
SIDE_STRIP_RATIO = 0.15
# 版心候选的中心容差（页宽比例）：版心在单页扫描居中、跨页扫描在两个
# 半页的 1/4 与 3/4 处，三处都认。
SPINE_CENTER_TOLERANCE = 0.08
# 页面四边清零边距（占同轴尺寸比例）：扫描件物理边缘的装订阴影/纸边
# 卷曲/摄影背景都在这一圈，不是版面内容（真实页眉/叶码/书耳都在纸面
# 内圈）。
PAGE_EDGE_MARGIN_RATIO = 0.025
# 竖排候选框的最小墨迹填充率：文字列/块有 15% 以上的笔画密度，扫描碎
# 屑（fill 常 <0.05）过不了门槛。
MIN_BOX_FILL = 0.08
# 条带内墨迹带高度超过正文行带中位高的该倍数 → 不当页眉页脚（多半是正文
# 顶到了条带里，误报会咬掉正文）。
STRIP_BAND_MAX_RATIO = 2.5
# 建议与已有区域重叠超过该比例（占建议面积）→ 跳过（只填空，不重复标）。
EXISTING_OVERLAP_SKIP = 0.05
# 同类建议 IoU 超过该值视为近重复（refine 阶段去重）。
NEAR_DUP_IOU = 0.8
# 疑似页码的短文本：纯数字/中文数字，或「第X叶/卷X/第X頁」形态。
_PAGENO_RE = re.compile(
    r"^[0-9０-９]{1,6}$"
    r"|^[一二三四五六七八九十百千零〇两二]{1,8}$"
    r"|^第[0-9０-９一二三四五六七八九十百千]{1,6}[頁页叶葉張张幅]$"
    r"|^[卷册][0-9０-９一二三四五六七八九十百千]{1,6}$"
)

# VLM 素材图上的区域底色（BGR），与 Flutter 端编辑器配色同语义。
REGION_OVERLAY_COLORS = {
    "main_text": (176, 39, 156),
    "header": (0, 180, 255),
    "footer": (200, 120, 60),
    "page_number": (0, 180, 70),
    "margin_note": (180, 140, 0),
    "figure": (65, 76, 109),
    "table": (87, 20, 173),
    "hexagram": (12, 54, 191),
}


def _vocab() -> list[str]:
    return LAYER_INFO["region_det"]["names"]


def _clamp_rect(rect, w: int, h: int):
    x, y, rw, rh = [int(v) for v in rect]
    x, y = max(0, x), max(0, y)
    rw, rh = min(w, x + rw) - x, min(h, y + rh) - y
    if rw < 3 or rh < 3:
        return None
    return (x, y, rw, rh)


def _line_texts_in(ann: dict, rect) -> list[str]:
    """中心点落在 rect 内的行文字（跨页佐证 / 页码模式判定用）。"""
    x, y, w, h = rect
    texts = []
    for ln in ann.get("lines") or []:
        cx = ln.get("x", 0) + ln.get("w", 0) / 2
        cy = ln.get("y", 0) + ln.get("h", 0) / 2
        if x <= cx <= x + w and y <= cy <= y + h:
            text = "".join(str(c.get("text") or "") for c in ln.get("chars") or [])
            text = re.sub(r"\s+", "", text)
            if text:
                texts.append(text)
    return texts


def _y_bands(mask: np.ndarray) -> list[tuple[int, int, int, int]]:
    """按行墨迹量聚带：返回 [(y1, y2, row_ink_max, x1, x2)]。

    行墨迹阈值取页宽的 0.8%（下限 3px）：一列竖排文字每行至少几十像素
    宽的墨迹，噪声点/单字残墨过不了门槛。带间空隙小于中位带高的 0.5
    倍时合并（行间距）。
    """
    h, w = mask.shape
    row_ink = (mask > 0).sum(axis=1)
    threshold = max(3, int(w * 0.008))
    rows = np.nonzero(row_ink >= threshold)[0]
    if not len(rows):
        return []
    bands = []
    start = prev = int(rows[0])
    for r in rows[1:]:
        r = int(r)
        if r - prev > 1:
            bands.append((start, prev))
            start = r
        prev = r
    bands.append((start, prev))
    heights = [b - a + 1 for a, b in bands]
    median_h = max(1.0, float(np.median(heights)))
    merged = [list(bands[0])]
    for a, b in bands[1:]:
        if a - merged[-1][1] - 1 < 0.5 * median_h:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    out = []
    for a, b in merged:
        cols = np.nonzero((mask[a : b + 1] > 0).sum(axis=0) > 0)[0]
        out.append((a, b, int(cols.min()), int(cols.max())))
    return out


def _clusters_in_band(mask: np.ndarray, y1: int, y2: int):
    """条带内的墨迹列簇（x 投影按空隙切分），返回 [(x1, x2)]。"""
    band_h = max(1, y2 - y1 + 1)
    col_ink = (mask[y1 : y2 + 1] > 0).sum(axis=0)
    return _runs(np.nonzero(col_ink > 0)[0], max(8, int(1.2 * band_h)))


def _x_bands(mask: np.ndarray) -> tuple[list[tuple[int, int, int, int]], float]:
    """按列墨迹量聚带（_y_bands 的竖排对称版）：返回 ([(x1, x2, y1, y2)],
    原始列游程中位宽)。

    列墨迹阈值取页高的 0.8%（下限 3px）；带间空隙小于中位带宽的 0.5 倍
    时合并（列间距）。原始游程中位宽 ≈ 单字宽，是竖排候选噪声门的比
    例尺（候选簇至少要小半个字高/宽，扫描碎屑过不了门槛）。"""
    h, w = mask.shape
    col_ink = (mask > 0).sum(axis=0)
    threshold = max(3, int(h * 0.008))
    cols = np.nonzero(col_ink >= threshold)[0]
    if not len(cols):
        return [], 0.0
    raw = _runs(cols, 1)
    char_scale = max(1.0, float(np.median([b - a + 1 for a, b in raw])))
    widths = [b - a + 1 for a, b in raw]
    median_w = max(1.0, float(np.median(widths)))
    merged = [list(raw[0])]
    for a, b in raw[1:]:
        if a - merged[-1][1] - 1 < 0.5 * median_w:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    out = []
    for a, b in merged:
        rows = np.nonzero((mask[:, a : b + 1] > 0).sum(axis=1) > 0)[0]
        out.append((a, b, int(rows.min()), int(rows.max())))
    return out, char_scale


def _vertical_strip_suggestions(mask: np.ndarray, ann: dict, img_w: int,
                                img_h: int, neighbors: list[dict]):
    """竖排书页的页眉/页脚候选（横排条带规则的对称路径）。

    竖排整页几乎每行都有墨，_y_bands 聚不出"顶/底条带 vs 正文"的层次，
    横排规则整页空转——书耳题名/天头眉批列/边栏书名/版心题名叶码这些
    **竖排短列**只能按列投影（_x_bands）再按行簇切分来找（与横排"y 带 ×
    x 簇"对称的"x 带 × y 簇"）。天头/地脚的行簇逐列出框，不再并成横向
    大框（用户实测"识别的都是横向的"即旧路径按行投影的并框）。横排页整
    段文字聚成一条宽带、行簇也切不开，本路径自然空转不误报。"""
    bands, char_scale = _x_bands(mask)
    if not bands:
        return []
    widths = [b - a + 1 for a, b, _, _ in bands]
    median_w = max(1.0, float(np.median(widths)))
    # 噪声门：候选簇至少小半个字高、候选框至少小半个字宽（char_scale ≈
    # 单字宽）。真实扫描的页缘碎屑/装订阴影只有几个像素，过不了门槛。
    min_ch = max(10, int(0.35 * char_scale))
    min_bw = max(8, int(0.3 * char_scale))
    top_limit = int(img_h * TOP_STRIP_RATIO)
    top_slack = int(img_h * 0.05)
    bottom_limit = img_h - int(img_h * BOTTOM_STRIP_RATIO)
    left_limit = int(img_w * SIDE_STRIP_RATIO)
    right_limit = img_w - int(img_w * SIDE_STRIP_RATIO)
    # 各列的行簇与正文簇高基准（贯穿页面中部的最大簇——同页正文列基本
    # 等高，眉批/题名/叶码簇显著更矮）。
    band_rows = []
    body_ref = 1.0
    for x1, x2, _, _ in bands:
        band_w = x2 - x1 + 1
        row_ink = (mask[:, x1 : x2 + 1] > 0).sum(axis=1)
        clusters = _runs(np.nonzero(row_ink > 0)[0], max(8, int(1.2 * band_w)))
        band_rows.append((x1, x2, clusters))
        for cy1, cy2 in clusters:
            if cy1 < bottom_limit and cy2 > top_limit:
                body_ref = max(body_ref, float(cy2 - cy1 + 1))
    suggestions = []
    for x1, x2, clusters in band_rows:
        band_w = x2 - x1 + 1
        in_side = x2 <= left_limit or x1 >= right_limit
        cx_center = (x1 + x2) / 2 / max(1, img_w)
        spine_like = (
            min_bw <= band_w <= STRIP_BAND_MAX_RATIO * median_w
            and any(abs(cx_center - c) <= SPINE_CENTER_TOLERANCE
                    for c in (0.25, 0.5, 0.75))
        )
        for cy1, cy2 in clusters:
            ch = cy2 - cy1 + 1
            if ch < min_ch:
                continue  # 噪声碎屑（扫描污点/页缘阴影）
            # 顶/底条带允许 5% 页高的越界松弛（版心题名常贴着条带下沿），
            # 但簇必须真正起于条带内（正文列起点虽可能落进天头，但整簇
            # 贯穿中部，过不了"整簇在松弛条带内"这一关）。
            in_top = cy1 < top_limit and cy2 < top_limit + top_slack
            in_bottom = (cy2 > bottom_limit
                         and cy1 > bottom_limit - top_slack)
            boxes = []  # [(rect, label, reason)]
            if in_top or in_bottom:
                # 天头/地脚行簇：按该簇的 x 游程逐列出框（多列眉批不再并
                # 成一个横向大框）。天头多列沿用横排路径的眉批语义。
                cols = np.nonzero((mask[cy1 : cy2 + 1] > 0).sum(axis=0) > 0)[0]
                # 单个"列"游程宽 ≤ 1/4 页宽：更宽的是暗带段/横排行，不是
                # 竖排列（真横排行由横排条带路径负责）。
                col_runs = [run for run in
                            _runs(cols, max(8, int(0.5 * median_w)))
                            if min_bw <= run[1] - run[0] + 1 <= 0.25 * img_w]
                if (col_runs
                        and col_runs[-1][1] - col_runs[0][0] >= 0.6 * img_w
                        and (len(col_runs) == 1 or len(col_runs) >= 5)):
                    # 行簇横贯大半页宽，且是连续暗带（1 游程）或碎屑散布
                    # （≥5 游程）：纸边阴影带/背光噪声（真实扫描的底边常
                    # 见）。2~4 列的真眉批阵保留；真横排文字行由横排条带
                    # 路径负责，此处整簇不报。
                    continue
                if in_top and len(col_runs) >= 2:
                    label, reason = "margin_note", "天头小字多列（疑似眉批）"
                else:
                    label = "header" if in_top else "footer"
                    reason = "顶部条带竖排墨迹列" if in_top else "底部条带竖排墨迹列"
                for cx1, cx2 in col_runs:
                    rect = _clamp_rect((cx1, cy1, cx2 - cx1 + 1, ch), img_w, img_h)
                    if rect is not None:
                        boxes.append((rect, label, reason))
            elif in_side and band_w >= min_bw and ch <= 0.5 * body_ref:
                rect = _clamp_rect((x1, cy1, band_w, ch), img_w, img_h)
                if rect is not None:
                    cy = (cy1 + cy2) / 2 / max(1, img_h)
                    if cy < 0.34:
                        boxes.append((rect, "header", "边栏上部竖排短列"))
                    elif cy > 0.66:
                        boxes.append((rect, "footer", "边栏下部竖排短列"))
                    else:
                        boxes.append((rect, "margin_note", "边栏竖排短列"))
            elif spine_like and ch <= 0.5 * body_ref:
                # 版心短列（题名/叶码）：只报有把握的——文字像页码，或簇
                # 在版心上/下半（中部多为鱼尾墨块，不报）。
                rect = _clamp_rect((x1, cy1, band_w, ch), img_w, img_h)
                if rect is None:
                    continue
                texts = _line_texts_in(ann, rect)
                pageno = next((t for t in texts if _PAGENO_RE.match(t)), "")
                cy = (cy1 + cy2) / 2 / max(1, img_h)
                if pageno:
                    boxes.append((rect, "page_number", "版心短列（疑似叶码）"))
                elif cy < 0.45:
                    boxes.append((rect, "header", "版心短列（疑似题名）"))
                elif cy > 0.55:
                    boxes.append((rect, "footer", "版心短列（疑似叶码）"))
            for rect, base_label, base_reason in boxes:
                # 填充率门：文字列/块的笔画密度 ≥8%，页缘清零后残余的
                # 扫描碎屑（fill 常 <5%）在这里挡掉。
                ink = int((mask[rect[1] : rect[1] + rect[3],
                                rect[0] : rect[0] + rect[2]] > 0).sum())
                if ink < MIN_BOX_FILL * rect[2] * rect[3]:
                    continue
                confidence = (0.45
                              if base_label == "margin_note"
                              or base_reason.startswith("版心")
                              else 0.5)
                reasons = [base_reason]
                texts = _line_texts_in(ann, rect)
                pageno_text = next((t for t in texts if _PAGENO_RE.match(t)), "")
                # 列状（窄高）→ 竖排列，跨页佐证比 x；扁宽 → 横排行，比 y。
                column_like = rect[2] <= 0.22 * img_w
                hits = _cross_page_hits(
                    rect, img_h, texts, neighbors,
                    axis="x" if column_like else "y", img_w=img_w)
                if hits:
                    confidence += 0.2
                    reasons.append(f"跨页同位重复×{hits}")
                if pageno_text:
                    base_label = "page_number"
                    confidence += 0.2
                    reasons.append(f"页码文字模式（{pageno_text}）")
                elif column_like:
                    confidence += 0.05
                    reasons.append("孤立短列")
                suggestions.append({
                    "x": rect[0], "y": rect[1], "w": rect[2], "h": rect[3],
                    "label": base_label,
                    "confidence": round(min(0.9, confidence), 3),
                    "reason": "；".join(reasons),
                })
    return suggestions


def _dedup_suggestions(suggestions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """横排条带与竖排列两路建议可能指向同一墨迹（如天头孤立书眉列两条路
    都能兜住）：交集占小框面积 >NEAR_DUP_IOU 视为同框，保留置信高的。"""
    kept: list[dict[str, Any]] = []
    for s in sorted(suggestions, key=lambda s: -s["confidence"]):
        r = (s["x"], s["y"], s["w"], s["h"])
        area = max(1, r[2] * r[3])
        dup = False
        for t in kept:
            tr = (t["x"], t["y"], t["w"], t["h"])
            if overlap(r, tr) / min(area, max(1, tr[2] * tr[3])) > NEAR_DUP_IOU:
                dup = True
                break
        if not dup:
            kept.append(s)
    return kept


def _crop_page_border_ink(mask: np.ndarray) -> np.ndarray:
    """把页面四边 [PAGE_EDGE_MARGIN_RATIO] 边距内的墨迹清零（坐标系不
    动）：扫描件物理边缘的装订阴影/纸边卷曲/摄影背景都聚在这一圈，真
    实的页眉/叶码/书耳都在纸面内圈。横排/竖排两条规则路径共用。"""
    h, w = mask.shape
    out = mask.copy()
    my = int(h * PAGE_EDGE_MARGIN_RATIO)
    mx = int(w * PAGE_EDGE_MARGIN_RATIO)
    out[:my, :] = 0
    out[h - my:, :] = 0
    out[:, :mx] = 0
    out[:, w - mx:] = 0
    return out


def _runs(values: np.ndarray, gap: int) -> list[tuple[int, int]]:
    """一维游程切分：下标数组按间隔 > gap 分段，返回 [(start, end)]（含端
    点）。_y_bands/_x_bands/_clusters_in_band 的同构内核，竖排路径共用。"""
    if not len(values):
        return []
    runs = []
    start = prev = int(values[0])
    for v in values[1:]:
        v = int(v)
        if v - prev > gap:
            runs.append((start, prev))
            start = v
        prev = v
    runs.append((start, prev))
    return runs


def _cross_page_hits(suggestion_rect, img_h: int, page_texts: list[str],
                     neighbors: list[dict], max_neighbors: int = 4,
                     axis: str = "y", img_w: int = 0) -> int:
    """相邻页同归一化位置出现相同文字的页数（页眉书名/叶码的强信号）。

    axis="y"（横排条带）：比行中心 y / 页高；axis="x"（竖排列）：比行中
    心 x / 页宽。邻页标注缺尺寸时回退当前页的同轴尺寸。"""
    if not page_texts:
        return 0
    span_now = img_w if axis == "x" else img_h
    if axis == "x":
        c_norm = (suggestion_rect[0] + suggestion_rect[2] / 2) / max(1, span_now)
    else:
        c_norm = (suggestion_rect[1] + suggestion_rect[3] / 2) / max(1, span_now)
    hits = 0
    for ann in neighbors[:max_neighbors]:
        span = (ann.get("image_width") if axis == "x"
                else ann.get("image_height")) or span_now
        for ln in ann.get("lines") or []:
            text = "".join(str(c.get("text") or "") for c in ln.get("chars") or [])
            text = re.sub(r"\s+", "", text)
            if not text:
                continue
            pos = ((ln.get("x", 0) + ln.get("w", 0) / 2) if axis == "x"
                   else (ln.get("y", 0) + ln.get("h", 0) / 2))
            if abs(pos / max(1, span) - c_norm) > 0.03:
                continue
            if any(text == t for t in page_texts):
                hits += 1
                break
    return hits


def suggest_regions(project_dir: str, page_id: str) -> dict[str, Any]:
    """规则 + 跨页一致性预标注（只读）。返回建议区列表，由客户端落为
    proposed 状态的 MainRegion，人工确认后进训练集。"""
    books = _book_dirs_under(project_dir)
    book_dir = None
    ann = None
    for candidate in books:
        for page in _annotation_pages(candidate):
            if str(page.get("page_id")) == str(page_id):
                book_dir, ann = candidate, page
                break
        if ann is not None:
            break
    if ann is None:
        raise ValueError(f"没有找到页面标注：{page_id}（在 {project_dir} 下）")
    image_path = ann.get("image_path") or ""
    size = _image_size(image_path) if image_path else None
    if not size:
        raise ValueError(f"页面图片不存在或无法读取：{image_path}")
    img_w, img_h = size
    mask = _text_mask_for_refinement(image_path)
    if mask is None:
        raise ValueError("无法生成页面墨迹 mask")
    # 页缘清零：装订阴影/纸边卷曲/摄影背景不是版面内容（真实扫描的顶/底
    # 边缘噪声曾让两条路径各报过整页假候选）。
    mask = _crop_page_border_ink(mask)

    pages = _annotation_pages(book_dir)
    index = next(
        (i for i, p in enumerate(pages) if str(p.get("page_id")) == str(page_id)), -1)
    neighbors = [p for i, p in enumerate(pages)
                 if i != index and abs(i - index) <= 2 and p is not ann]

    bands = _y_bands(mask)
    # 格线表格候选（+83）：明确的网格结构特征，置信高于条带规则；同样
    # 只填空（与已有区域重叠的丢弃）。格线检测失败不拖垮页眉/页脚规则。
    try:
        table_suggestions = [
            {
                "x": t["x"], "y": t["y"], "w": t["w"], "h": t["h"],
                "label": "table", "confidence": 0.8,
                "reason": f"格线网格结构（{t['rows']}×{t['cols']}）",
            }
            for t in detect_tables_in_page(image_path)
        ]
    except Exception:
        table_suggestions = []
    suggestions: list[dict[str, Any]] = list(table_suggestions)
    if not bands:
        return {"page_id": str(page_id), "book_dir": book_dir,
                "image_width": img_w, "image_height": img_h, "suggestions": suggestions}
    body_heights = [b - a + 1 for a, b, _, _ in bands]
    median_h = max(1.0, float(np.median(body_heights)))
    top_limit = int(img_h * TOP_STRIP_RATIO)
    bottom_limit = img_h - int(img_h * BOTTOM_STRIP_RATIO)
    # 眉批判定的小字基准：中部（非条带）最高墨迹带 ≈ 正文列高度。中位
    # 带高在"页眉+正文+页码"三带的页面上会被页眉/页码带拉低，直接比
    # 中位数会把真眉批（比正文字小、比页码带宽）判成普通页眉。
    body_ref = max(
        (b - a + 1 for a, b, _, _ in bands if b > top_limit and a < bottom_limit),
        default=median_h)

    for y1, y2, bx1, bx2 in bands:
        band_h = y2 - y1 + 1
        is_top = y2 <= top_limit
        is_bottom = y1 >= bottom_limit
        if not (is_top or is_bottom):
            continue
        if is_bottom and y1 > 0.95 * img_h:
            continue  # 带底紧贴纸边（<5% 页高）：纸边阴影/背光，不是页脚
        if band_h > STRIP_BAND_MAX_RATIO * median_h:
            continue  # 正文顶进条带，不当页眉页脚
        base_label = "header" if is_top else "footer"
        reasons = ["顶部条带墨迹行" if is_top else "底部条带墨迹行"]
        confidence = 0.5
        rect = _clamp_rect((bx1, y1, bx2 - bx1 + 1, band_h), img_w, img_h)
        if rect is None:
            continue
        clusters = _clusters_in_band(mask, y1, y2)
        texts = _line_texts_in(ann, rect)
        pageno_text = next((t for t in texts if _PAGENO_RE.match(t)), "")
        hits = _cross_page_hits(rect, img_h, texts, neighbors)
        if hits:
            confidence += 0.2
            reasons.append(f"跨页同位重复×{hits}")
        if len(clusters) == 1 and (bx2 - bx1 + 1) <= 0.22 * img_w:
            # 孤立短列：页码/卷次的典型形态
            if pageno_text:
                base_label = "page_number"
                confidence += 0.2
                reasons.append(f"页码文字模式（{pageno_text}）")
            else:
                confidence += 0.05
                reasons.append("孤立短列")
        elif len(clusters) >= 2:
            if is_top and band_h <= 0.7 * body_ref and not hits:
                # 天头小字多列、跨页不重复 → 疑似眉批（低置信，等人工确认）
                base_label = "margin_note"
                confidence = 0.45
                reasons = ["天头小字多列（疑似眉批）"]
            elif pageno_text:
                # 页码簇单列：页码与其余墨迹（书名等）拆开建议
                pageno_cluster = None
                for cx1, cx2 in clusters:
                    crect = (cx1, y1, cx2 - cx1 + 1, band_h)
                    if any(t == pageno_text for t in _line_texts_in(ann, crect)):
                        pageno_cluster = crect
                        break
                if pageno_cluster is not None:
                    suggestions.append({
                        "x": pageno_cluster[0], "y": pageno_cluster[1],
                        "w": pageno_cluster[2], "h": pageno_cluster[3],
                        "label": "page_number", "confidence": min(0.9, confidence + 0.2),
                        "reason": "；".join(reasons + [f"页码文字模式（{pageno_text}）"]),
                    })
                    rest_x1 = min(cx1 for cx1, _ in clusters
                                  if (cx1, y1) != (pageno_cluster[0], y1))
                    rect = _clamp_rect(
                        (rest_x1, y1, bx2 - rest_x1 + 1, band_h), img_w, img_h)
                    if rect is None:
                        continue
        suggestions.append({
            "x": rect[0], "y": rect[1], "w": rect[2], "h": rect[3],
            "label": base_label, "confidence": round(min(0.9, confidence), 3),
            "reason": "；".join(reasons),
        })

    # 竖排对称路径：x 带 × 行簇（横排条带在竖排页聚不出层次，书耳/眉批
    # 列/边栏书名/版心题名叶码只能按列找）。
    suggestions.extend(
        _vertical_strip_suggestions(mask, ann, img_w, img_h, neighbors))
    # 尺寸门（两路共用的最后一道）：候选框高 ≥ 页高的 1.2%、宽 ≥ 页宽的
    # 0.4%（各留 10/8px 下限，与行/列墨迹阈值同刻度）——版框残线（细长
    # 竖线）/纸边碎屑（矮细条）都过不了，真文字行列至少小半字见方。
    min_h = max(10, int(img_h * 0.012))
    min_w = max(8, int(img_w * 0.004))
    suggestions = [s for s in suggestions
                   if s["h"] >= min_h and s["w"] >= min_w]
    suggestions = _dedup_suggestions(suggestions)

    # 只填空：与已有区域（任何状态/类别）显著重叠的建议丢弃
    existing = [r for r in (ann.get("main_regions") or []) if isinstance(r, dict)]
    kept = []
    for s in suggestions:
        s_rect = (s["x"], s["y"], s["w"], s["h"])
        s_area = max(1, s_rect[2] * s_rect[3])
        if any(overlap(s_rect, (r.get("x", 0), r.get("y", 0),
                                r.get("w", 0), r.get("h", 0))) / s_area
               > EXISTING_OVERLAP_SKIP for r in existing):
            continue
        kept.append(s)
    kept.sort(key=lambda s: -s["confidence"])
    return {"page_id": str(page_id), "book_dir": book_dir,
            "image_width": img_w, "image_height": img_h,
            "neighbors_checked": len(neighbors), "suggestions": kept}


def refine_regions(image_path: str, regions: list[dict[str, Any]]) -> dict[str, Any]:
    """粗框几何安全层：钳回图内 → 词表校验 → 墨迹收紧 → 近重复去除。"""
    size = _image_size(image_path)
    if not size:
        raise ValueError(f"图片不存在或无法读取：{image_path}")
    img_w, img_h = size
    mask = _text_mask_for_refinement(image_path)
    vocab = _vocab()
    refined: list[dict[str, Any]] = []
    dropped: list[dict[str, Any]] = []
    for item in regions:
        label = str(item.get("label") or "main_text")
        rect = _clamp_rect(
            (item.get("x", 0), item.get("y", 0), item.get("w", 0), item.get("h", 0)),
            img_w, img_h)
        if rect is None:
            dropped.append({**item, "reason": "越界或尺寸不足"})
            continue
        if label not in vocab:
            dropped.append({**item, "reason": f"类别不在词表：{label}"})
            continue
        if mask is not None:
            tight, _noise = ink_rect(rect, mask)
            if tight is None:
                dropped.append({**item, "reason": "无结构性墨迹（空框）"})
                continue
            rect = tight
        refined.append({"x": rect[0], "y": rect[1], "w": rect[2], "h": rect[3],
                        "label": label,
                        "confidence": item.get("confidence")})
    # 同类近重复去重：保留置信度高（缺省按 0.5）的
    refined.sort(key=lambda r: -(r.get("confidence") if r.get("confidence") is not None else 0.5))
    kept: list[dict[str, Any]] = []
    for r in refined:
        r_rect = (r["x"], r["y"], r["w"], r["h"])
        dup = False
        for k in kept:
            if k["label"] != r["label"]:
                continue
            k_rect = (k["x"], k["y"], k["w"], k["h"])
            inter = overlap(r_rect, k_rect)
            union = r_rect[2] * r_rect[3] + k_rect[2] * k_rect[3] - inter
            if union > 0 and inter / union > NEAR_DUP_IOU:
                dup = True
                break
        if dup:
            dropped.append({**r, "reason": "同类近重复"})
        else:
            kept.append(r)
    return {"regions": kept, "dropped": dropped,
            "image_width": img_w, "image_height": img_h}


def prelabel_page_image(image_path: str, existing_regions: list[dict[str, Any]],
                        max_side: int = 1536, grid_div: int = 8) -> dict[str, Any]:
    """VLM 整页预标注素材图：降采样 + 网格坐标刻度 + 已有区域半透明
    底色。已有区域画出来是为了提示 VLM"这些不用再标"（只填空原则）。
    grid_div 控制网格密度（钳 4~32）：版面区默认 8 格，字框级实验用 16。"""
    img = None
    try:
        img = _imread(image_path)
    except OSError:
        img = None
    if img is None:
        raise ValueError(f"图片不存在或无法读取：{image_path}")
    h, w = img.shape[:2]
    max_side = max(256, min(2048, int(max_side)))
    scale = min(1.0, max_side / max(w, h))
    canvas = cv2.resize(img, (max(1, int(w * scale)), max(1, int(h * scale))))
    ch, cw = canvas.shape[:2]
    div = max(4, min(32, int(grid_div)))
    # 1/div 网格 + 边缘坐标刻度（归一化），浅色不压字
    grid_color = (200, 200, 200)
    for i in range(1, div):
        gx, gy = int(cw * i / div), int(ch * i / div)
        cv2.line(canvas, (gx, 0), (gx, ch - 1), grid_color, 1)
        cv2.line(canvas, (0, gy), (cw - 1, gy), grid_color, 1)
        cv2.putText(canvas, f"{i / div:.3f}", (gx + 2, 14), cv2.FONT_HERSHEY_SIMPLEX,
                    0.4, grid_color, 1)
        cv2.putText(canvas, f"{i / div:.3f}", (2, gy + 14), cv2.FONT_HERSHEY_SIMPLEX,
                    0.4, grid_color, 1)
    for r in existing_regions or []:
        if not isinstance(r, dict):
            continue
        x1 = max(0, int(r.get("x", 0) * scale))
        y1 = max(0, int(r.get("y", 0) * scale))
        x2 = min(cw, int((r.get("x", 0) + r.get("w", 0)) * scale))
        y2 = min(ch, int((r.get("y", 0) + r.get("h", 0)) * scale))
        if x2 - x1 < 2 or y2 - y1 < 2:
            continue
        color = REGION_OVERLAY_COLORS.get(region_label(r), (120, 120, 120))
        overlay = canvas.copy()
        cv2.rectangle(overlay, (x1, y1), (x2, y2), color, -1)
        canvas = cv2.addWeighted(overlay, 0.15, canvas, 0.85, 0)
        cv2.rectangle(canvas, (x1, y1), (x2, y2), color, 2)
        cv2.putText(canvas, str(r.get("label") or "main_text"), (x1 + 3, y1 + 16),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1)
    ok, buf = cv2.imencode(".png", canvas)
    if not ok:
        raise ValueError("素材图编码失败")
    return {"image_base64": base64.b64encode(buf.tobytes()).decode("ascii"),
            "width": cw, "height": ch, "orig_width": w, "orig_height": h,
            "scale": round(scale, 4), "grid": {"cols": div, "rows": div}}
