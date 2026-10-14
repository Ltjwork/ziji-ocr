# -*- coding: utf-8 -*-
"""切分主管线（从 segmenter 拆出）：YOLO 优先/OpenCV 兜底两条引擎、
排序重编号与元数据装配入口 segment_image_with_metadata。
segmenter.py 仍为门面。"""
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
from seg_trace import (begin_debug_trace, debug_trace_snapshot, _log, _exception_summary)
from seg_models import (_predict_detection_layer, _override_for, record_yolo_error, current_yolo_error, _YOLO_PREDICT_LOCK, _default_yolo_model_path, _import_opencc, _load_yolo_char_model, _yolo_diagnostics)
from seg_imaging import (_imread, _to_block, mask_polarity_info, _clamp_result_to_image, _merge_close_runs, _remove_ruling_lines, _runs, _text_mask_for_refinement, _tight_rect, _zero_edge_filler_bands)
from seg_refine import _tight_piece
from seg_lines import (line_alignment_primary, _filter_isolated_yolo_noise, _group_yolo_char_rects_into_lines)
from seg_chars import _split_chars_in_region
from seg_layout import (
    _filter_layout,
    _augment_with_model_hierarchy,
    detect_main_regions,
    build_body_gated_image,
    dispose_body_gated_image,
)
from seg_doublecol import (drop_duplicate_fragment_lines, split_double_column_lines, _merge_adjacent_line_fragments)
from seg_candidates import get_char_candidates





def _segment_with_yolo_chars(
    image_path: str,
    image_w: int,
    image_h: int,
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
    orientation: str = "vertical",
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    try:
        with _YOLO_PREDICT_LOCK:
            model = _load_yolo_char_model()
            if model is None:
                _log("[model-use] char_det: 未使用自训模型（无可用模型），走基线切分")
                return [], []
            _log(f"[model-use] char_det: 使用自训模型 {_default_yolo_model_path()}")

            conf = float(os.environ.get("OCR_YOLO_CHAR_CONF", "0.25"))
            iou = float(os.environ.get("OCR_YOLO_CHAR_IOU", "0.45"))
            imgsz = int(os.environ.get("OCR_YOLO_CHAR_IMGSZ", "1280"))
            _log(f"[diag:yolo] predict start conf={conf} iou={iou} imgsz={imgsz}")

            results = model.predict(
                source=image_path,
                conf=conf,
                iou=iou,
                imgsz=imgsz,
                verbose=False,
            )
    except Exception as exc:
        reason = _exception_summary(exc)
        record_yolo_error(reason)
        _log(f"[diag:yolo] predict failed: {reason}")
        _log(traceback.format_exc().rstrip())
        return [], []

    detections: list[tuple[tuple[int, int, int, int], float]] = []
    for result in results or []:
        boxes = getattr(result, "boxes", None)
        if boxes is None:
            continue
        xyxy = getattr(boxes, "xyxy", None)
        confs = getattr(boxes, "conf", None)
        if xyxy is None:
            continue
        try:
            xyxy_values = xyxy.cpu().numpy() if hasattr(xyxy, "cpu") else np.asarray(xyxy)
            conf_values = confs.cpu().numpy() if hasattr(confs, "cpu") else np.asarray(confs)
        except Exception as exc:
            _log(f"[diag:yolo] boxes conversion failed: {_exception_summary(exc)}")
            continue
        for idx, box in enumerate(xyxy_values):
            x1, y1, x2, y2 = [float(v) for v in box[:4]]
            bx1 = max(0, int(np.floor(x1)))
            by1 = max(0, int(np.floor(y1)))
            bx2 = min(image_w, int(np.ceil(x2)))
            by2 = min(image_h, int(np.ceil(y2)))
            bw = bx2 - bx1
            bh = by2 - by1
            if bw < 3 or bh < 6:
                continue
            score = float(conf_values[idx]) if idx < len(conf_values) else 0.0
            detections.append(((bx1, by1, bw, bh), score))

    if not detections:
        _log("[diag:yolo] no char boxes detected")
        return [], []

    # YOLO 偶尔会在短列的空白尾部把扫描污点/栏线碎片报成一个“字”。
    # 该框本身有少量墨迹，但会把整列的阅读轴范围撑进大段空白；后续
    # Kraken 为了凑齐字数会按整列网格切分，于是空白区被重新制造成一串
    # 窄框。先按同一跨轴列的墨迹连续性清理孤立小框，保留真正相邻的
    # 句号/点号（它们与同列字的轴向间距仍接近一个字距）。
    detections = _filter_isolated_yolo_noise(
        detections, image_path, image_w, image_h, orientation,
    )
    if not detections:
        _log("[diag:yolo] all detections filtered as isolated noise")
        return [], []

    char_rects = [rect for rect, _ in detections]
    line_groups = _group_yolo_char_rects_into_lines(
        char_rects, image_w, image_h, image_path=image_path, orientation=orientation,
    )
    lines: list[dict[str, Any]] = []
    blocks: list[dict[str, Any]] = []
    block_id = 0

    for line_idx, group in enumerate(line_groups):
        if not group:
            continue
        gx1 = min(r[0] for r in group)
        gy1 = min(r[1] for r in group)
        gx2 = max(r[0] + r[2] for r in group)
        gy2 = max(r[1] + r[3] for r in group)
        line_w = gx2 - gx1
        line_h = gy2 - gy1
        # 行方向以用户声明的整页排版为准（决定行内排序、kraken 读法、
        # 行外扩方向）；几何长宽比只作无声明时的兜底——条带切错时按
        # 长宽比猜会在横竖间随机翻转，让下游各环节方向互相矛盾。
        line_orientation = (
            orientation
            if orientation in ("horizontal", "vertical")
            else ("horizontal" if line_w > line_h else "vertical")
        )
        line_id = f"yolo_l_{line_idx:03d}"
        line_chars: list[dict[str, Any]] = []
        for order, rect in enumerate(group):
            block_id += 1
            block = _to_block(
                block_id,
                rect,
                "yolo-char",
                col=line_idx,
                order=order,
                text="",
                line_id=line_id,
            )
            blocks.append(block)
            line_chars.append(block)
        lines.append({
            "id": line_id,
            "x": gx1,
            "y": gy1,
            "w": line_w,
            "h": line_h,
            "line_no": line_idx,
            "orientation": line_orientation,
            "text": "",
            "chars": line_chars,
        })

    _apply_sort_and_renumber(lines, blocks, horizontal_dir, vertical_dir, orientation)
    # 文字由上层 Kraken 识别（kraken_bridge.apply_kraken_recognition）填充，
    # 引擎本身只负责出框。
    _log(f"[diag:yolo] detections={len(detections)} lines={len(lines)} blocks={len(blocks)}")
    return lines, blocks




def _segment_with_opencv(
    image_path: str,
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
    orientation: str = "vertical",
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """返回 (lines, blocks)，blocks 是 lines.chars 的扁平化。"""
    _log("[diag:opencv] fallback segmentation start")
    img = _imread(image_path)
    if img is None:
        raise ValueError(f"Cannot read image: {image_path}")

    h, w = img.shape[:2]
    _log(f"[diag:opencv] image size width={w} height={h}")
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

    _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    text_mask = _remove_ruling_lines(binary)
    text_mask = cv2.morphologyEx(
        text_mask,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (2, 2)),
    )
    text_mask = _zero_edge_filler_bands(gray, text_mask)

    # 横排在转置工作域切分（"列"=水平行、"列内 y 投影切字"=行内 x 投影
    # 切字），投影/标点补捞逻辑复用竖排实现，输出坐标再转置回原图。
    horizontal = orientation == "horizontal"
    if horizontal:
        work_mask = np.ascontiguousarray(text_mask.T)
        work_w, work_h = h, w
    else:
        work_mask, work_w, work_h = text_mask, w, h

    x_proj = np.sum(work_mask > 0, axis=0)
    x_threshold = max(2, int(np.percentile(x_proj[x_proj > 0], 35))) if np.any(x_proj > 0) else 2
    x_runs = _runs(x_proj > x_threshold, min_len=max(3, work_w // 300))
    x_runs = _merge_close_runs(x_runs, max_gap=max(2, work_w // 220))

    # 标点尾列补捞：段末句号/逗号独占一列时墨迹极少（x_proj 只有十几，
    # 35 分位阈值以正文列墨迹水平为基准，整列被丢）——段落少个句号、
    # 用户只能手画框（实测"整列一个句号"，画框后还会撞上 Kraken 行读
    # 法为空的报错）。地板阈值（x_proj>2）再切一遍，补捞与存活列不重
    # 叠、条带内墨迹"少而小"的条带：≤3 个面积 ≥8 的连通块、每个都只
    # 有标点大小（高宽 ≤ 版高的 1/45）、整体跨度 ≤4 个标点高（散落
    # 半页的孤立点不是段尾标点列）——正常文字列墨迹量/组件数远超此
    # 限，不会命中。捞到的列随后走正常行管线（识别为空由行兜底建框）。
    merge_gap_x = max(2, work_w // 220)
    punct_h_cap = max(18, work_h // 45)
    min_col_w = max(14, int(work_w * 0.012))
    punct_cols: list[tuple[int, int]] = []
    punct_col_set: set[tuple[int, int]] = set()
    for r in _merge_close_runs(_runs(x_proj > 2, min_len=3), max_gap=merge_gap_x):
        if not (max(8, min_col_w // 2) <= r[1] - r[0] <= work_w * 0.12):
            continue
        if not all(
            r[0] >= m[1] + merge_gap_x or r[1] <= m[0] - merge_gap_x
            for m in x_runs
        ):
            continue
        strip_mask = (work_mask[:, r[0]:r[1]] > 0).astype(np.uint8)
        num_labels, _labels, stats, _cent = cv2.connectedComponentsWithStats(
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
        punct_cols.append(r)
        punct_col_set.add(r)
        _log(
            f"[diag:opencv] 标点尾列补捞 x{r[0]}..{r[1]} "
            f"组件数={len(comps)} 跨度={span}"
        )
    x_runs = sorted(x_runs + punct_cols)

    lines: list[dict[str, Any]] = []
    blocks: list[dict[str, Any]] = []
    block_id = 0
    pad = max(2, min(w, h) // 350)

    for col_idx, (cx1, cx2) in enumerate(x_runs):
        if cx2 - cx1 > work_w * 0.12:
            continue

        col_mask = work_mask[:, cx1:cx2]
        y_proj = np.sum(col_mask > 0, axis=1)
        # 标点尾列只有 8~15px 高的墨迹：行内 y 投影的低阈值/最小段长都
        # 是按正文行标定的，照用会把句号行整个滤掉。
        is_punct_col = (cx1, cx2) in punct_col_set
        if is_punct_col:
            y_threshold = 2
            min_y_len = 1
        else:
            y_threshold = max(2, int(np.percentile(y_proj[y_proj > 0], 25))) if np.any(y_proj > 0) else 2
            min_y_len = max(8, work_h // 120)
        y_runs = _runs(y_proj > y_threshold, min_len=min_y_len)
        y_runs = _merge_close_runs(y_runs, max_gap=max(8, work_h // 90))

        line_id = f"l_col{col_idx:03d}"
        line_chars: list[dict[str, Any]] = []
        line_min_x = w
        line_min_y = h
        line_max_r = 0
        line_max_b = 0

        for order, (ry1, ry2) in enumerate(y_runs):
            # 标点墨迹只有 8~10px，_tight_rect 的 6x10 下限会整个丢掉。
            rect = (
                _tight_piece(work_mask, cx1, cx2, ry1, ry2, pad, work_w, work_h)
                if is_punct_col
                else _tight_rect(work_mask, cx1, cx2, ry1, ry2, pad, work_w, work_h)
            )
            if rect is None:
                continue
            x, y, bw, bh = rect
            if bw > work_w * 0.08 or bh > work_h * 0.55:
                continue
            if horizontal:
                # 工作域坐标转置回原图：域内 (x, y, w, h) → 原图 (y, x, h, w)
                x, y, bw, bh = y, x, bh, bw
            block_id += 1
            block = _to_block(
                block_id,
                (x, y, bw, bh),
                "opencv",
                col=col_idx,
                order=order,
                line_id=line_id,
            )
            blocks.append(block)
            line_chars.append(block)
            if x < line_min_x:
                line_min_x = x
            if y < line_min_y:
                line_min_y = y
            if x + bw > line_max_r:
                line_max_r = x + bw
            if y + bh > line_max_b:
                line_max_b = y + bh

        if not line_chars:
            continue

        line_w = line_max_r - line_min_x
        line_h = line_max_b - line_min_y
        # 行方向以用户声明的整页排版为准（与 yolo-char 引擎一致）
        line_orientation = (
            orientation
            if orientation in ("horizontal", "vertical")
            else ("horizontal" if line_w > line_h else "vertical")
        )
        line_text = "".join(c.get("text", "") for c in line_chars)
        lines.append({
            "id": line_id,
            "x": line_min_x,
            "y": line_min_y,
            "w": line_w,
            "h": line_h,
            "line_no": col_idx,
            "orientation": line_orientation,
            "text": line_text,
            "chars": line_chars,
        })

    _apply_sort_and_renumber(lines, blocks, horizontal_dir, vertical_dir, orientation)
    _log(f"[diag:opencv] columns={len(x_runs)} lines={len(lines)} blocks={len(blocks)}")
    return lines, blocks




def _apply_sort_and_renumber(
    lines: list[dict[str, Any]],
    blocks: list[dict[str, Any]],
    horizontal_dir: str,
    vertical_dir: str,
    layout_orientation: str | None = None,
) -> None:
    """按方向设置对 lines 和 blocks 排序，重写 col/order/line_no。

    竖排（默认古籍）：col 按 x 排，同 col 内按 y 排。
    横排：col 按 y 排，同 col 内按 x 排。
    方向反转（rtl/btt）只改变组内顺序。
    """
    if not lines:
        return

    # 判定整体方向：多数 orientation 投票，仅用于行间排序
    vertical_count = sum(1 for ln in lines if ln.get("orientation") == "vertical")
    is_vertical_layout = (
        layout_orientation == "vertical"
        if layout_orientation in ("horizontal", "vertical")
        else vertical_count >= len(lines) / 2
    )
    vertical = is_vertical_layout

    def _read_range(ln: dict[str, Any]) -> tuple[float, float]:
        if vertical:
            return ln["y"], ln["y"] + ln["h"]
        return ln["x"], ln["x"] + ln["w"]

    def _read_center(ln: dict[str, Any]) -> float:
        a, b = _read_range(ln)
        return (a + b) / 2.0

    def _cross_center(ln: dict[str, Any]) -> float:
        if vertical:
            return ln["x"] + ln["w"] / 2.0
        return ln["y"] + ln["h"] / 2.0

    def _cross_ov(a: dict[str, Any], b: dict[str, Any]) -> float:
        """两行在跨轴（竖排 x / 横排 y）上的重叠占窄行者宽度的比例。"""
        if vertical:
            a1, a2 = a["x"], a["x"] + a["w"]
            b1, b2 = b["x"], b["x"] + b["w"]
        else:
            a1, a2 = a["y"], a["y"] + a["h"]
            b1, b2 = b["y"], b["y"] + b["h"]
        ov = min(a2, b2) - max(a1, b1)
        if ov <= 0:
            return 0.0
        return ov / max(1.0, float(min(a2 - a1, b2 - b1)))

    # ── 重叠带聚类排序 ────────────────────────────────────────────────
    # 并排子列拆分（通栏上段 + 左右子列）与通栏标题行在跨轴上与所属列
    # 互相重叠，纯跨轴排序对这种 L 形结构没有稳定的阅读序。先按跨轴位
    # 次（原排序）逐行归带：与带内任一成员重叠 ≥0.75×窄者入带，否则新
    # 建一带——通栏上段无论在跨轴序里落在两条子列之间还是之后，都能归
    # 入同一带。带内先按阅读位次分组（阅读轴重叠 ≥0.5×矮者算并行同
    # 组），组间按阅读位次、组内按跨轴位次排——并行的子列回到跨轴次
    # 序，上段排到子列之前。普通非重叠列各自成带、单独成组，结果与旧
    # 的纯跨轴排序完全一致。
    if vertical:
        lines.sort(key=lambda ln: -ln["x"] if horizontal_dir == "rtl" else ln["x"])
    else:
        lines.sort(key=lambda ln: -ln["y"] if vertical_dir == "btt" else ln["y"])

    bands: list[list[dict[str, Any]]] = []
    for ln in lines:
        for b in bands:
            if any(_cross_ov(m, ln) >= 0.75 for m in b):
                b.append(ln)
                break
        else:
            bands.append([ln])

    ordered: list[dict[str, Any]] = []
    for band in bands:
        if len(band) == 1:
            ordered.extend(band)
            continue
        if vertical:
            band.sort(key=_read_center, reverse=(vertical_dir == "btt"))
        else:
            band.sort(key=_read_center, reverse=(horizontal_dir == "rtl"))
        groups: list[list[dict[str, Any]]] = []
        for ln in band:
            if groups:
                r1a, r1b = _read_range(ln)
                r0a, r0b = _read_range(groups[-1][-1])
                ov = min(r1b, r0b) - max(r1a, r0a)
                if ov > 0 and ov / max(1.0, float(min(r1b - r1a, r0b - r0a))) >= 0.5:
                    groups[-1].append(ln)
                    continue
            groups.append([ln])
        for g in groups:
            if vertical:
                g.sort(key=_cross_center, reverse=(horizontal_dir == "rtl"))
            else:
                g.sort(key=_cross_center, reverse=(vertical_dir == "btt"))
            ordered.extend(g)
    lines[:] = ordered

    # 行内排序：逐行按自身 orientation 判断，不受全局投票影响
    for new_col, ln in enumerate(lines):
        ln["line_no"] = new_col
        ln_chars = ln["chars"]
        if ln.get("orientation") == "horizontal":
            if horizontal_dir == "rtl":
                ln_chars.sort(key=lambda c: -c["x"])
            else:
                ln_chars.sort(key=lambda c: c["x"])
        else:
            if vertical_dir == "btt":
                ln_chars.sort(key=lambda c: -c["y"])
            else:
                ln_chars.sort(key=lambda c: c["y"])
        for new_order, c in enumerate(ln_chars):
            c["col"] = new_col
            c["order"] = new_order

    # 同步扁平 blocks 列表
    blocks_by_id = {b["id"]: b for b in blocks}
    blocks.clear()
    for ln in lines:
        blocks.extend(ln["chars"])

    _log(
        f"[diag:sort] layout={'vertical' if is_vertical_layout else 'horizontal'} "
        f"h_dir={horizontal_dir} v_dir={vertical_dir} "
        f"lines={len(lines)} blocks={len(blocks)}"
    )




def _lines_from_det_rects(
    det_rects: list[tuple[int, int, int, int]],
    image_w: int,
    image_h: int,
    orientation: str = "vertical",
) -> list[dict[str, Any]]:
    """PP-OCR det 行框 → 管线行结构（chars 空：切字/识别由识别阶段按行
    完成，与 YOLO 行的下游链路一致）。

    det 框是整条文本行的紧致外接框（非字框碎片），长宽比可判行方向：
    竖排页上的横排落款/页脚行（w>1.3h）标 horizontal，切字/外扩沿
    正确轴向进行——整页排版声明仍主导（与 YOLO 行同规则），只对几何
    上明显反向的行放行。"""
    lines: list[dict[str, Any]] = []
    for idx, (x, y, w, h) in enumerate(det_rects):
        x = max(0, int(x))
        y = max(0, int(y))
        w = min(int(w), image_w - x)
        h = min(int(h), image_h - y)
        if w < 3 or h < 6:
            continue
        line_orientation = (
            orientation
            if orientation in ("horizontal", "vertical")
            else ("horizontal" if w > h else "vertical")
        )
        if line_orientation == "vertical" and w > h * 1.3:
            line_orientation = "horizontal"
        elif line_orientation == "horizontal" and h > w * 1.3:
            line_orientation = "vertical"
        lines.append({
            "id": f"det_l_{idx:03d}",
            "x": x,
            "y": y,
            "w": w,
            "h": h,
            "line_no": idx,
            "orientation": line_orientation,
            "text": "",
            "chars": [],
        })
    return lines


# det 行可打的版面类型标签（与客户端 RegionLabel 词表同源；正文/眉批
# 之外的排除类 + 眉批本身）。
_DET_TYPE_LABELS = {"header", "footer", "page_number", "margin_note"}


def _det_line_position_label(
    ln: dict[str, Any], image_w: int, image_h: int
) -> str:
    """无门控区时的几何兜底：页眉/页脚 = 页顶/页底边带内的短行（正文
    列高占版心大半，25% 上限保证主列永不被误标）；页码 = 页脚带内的
    极短行（约 ≤5 字）。其余不猜——正文/眉批误标的代价高于漏标。"""
    h_page = max(1, image_h)
    vertical = ln.get("orientation") != "horizontal"
    read_ext = ln["h"] if vertical else ln["w"]
    cross_ext = ln["w"] if vertical else ln["h"]
    read_page = h_page if vertical else max(1, image_w)
    if read_ext <= 0 or read_ext > read_page * 0.25:
        return ""
    cy = ln["y"] + ln["h"] / 2.0
    if cy < h_page * 0.12:
        return "header"
    if cy > h_page * 0.88:
        if read_ext <= max(1, cross_ext) * 5.5:
            return "page_number"
        return "footer"
    return ""


def _type_det_lines(
    lines: list[dict[str, Any]],
    image_w: int,
    image_h: int,
    main_regions: list[dict[str, Any]] | None,
) -> None:
    """det 行打版面类型标签（region_label + layout_role=annotation）。

    用户需求：det 检出的页眉/页脚/页码内容用对应类型的识别框展示，
    不再混作正文行。归属优先人工已确认门控区（行中心落在页眉/页脚/
    页码/眉批区内即该类；门控区已在检测前抹像素，这是边缘残留的兜底）；
    无区时按几何位置判定。正文字行不打标签（客户端按缺省正文色）。"""
    regions = [
        r
        for r in (main_regions or [])
        if isinstance(r, dict)
        and str(r.get("label") or "") in _DET_TYPE_LABELS
        and r.get("status") != "rejected"
    ]
    typed = 0
    for ln in lines:
        label = ""
        cx = ln["x"] + ln["w"] / 2.0
        cy = ln["y"] + ln["h"] / 2.0
        for r in regions:
            if (
                r.get("x", 0) <= cx <= r.get("x", 0) + r.get("w", 0)
                and r.get("y", 0) <= cy <= r.get("y", 0) + r.get("h", 0)
            ):
                label = str(r.get("label"))
                break
        if not label:
            label = _det_line_position_label(ln, image_w, image_h)
        if label:
            ln["region_label"] = label
            ln["layout_role"] = "annotation"
            typed += 1
    if typed:
        counts: dict[str, int] = {}
        for ln in lines:
            k = str(ln.get("region_label") or "")
            if k:
                counts[k] = counts.get(k, 0) + 1
        _log(
            "[segment] det 行类型化："
            + "，".join(f"{k}={v}" for k, v in counts.items())
        )


def segment_image_with_metadata(
    image_path: str,
    layout_mode: str = "all_text",
    orientation: str = "vertical",
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
    gate_regions: list[dict[str, Any]] | None = None,
    line_detector=None,
) -> dict[str, Any]:
    img = _imread(image_path)
    if img is None:
        raise ValueError(f"Cannot read image: {image_path}")

    h, w = img.shape[:2]

    # 区域门控（用户规则：只有正文区域进行段落/行/单字划分与识别）：
    # region_det 先行，页眉/页脚/页码区在字检测之前就抹成页面底色——
    # 这些区域不再产出任何行/字/段落，后续 Kraken 识别自然读不到；
    # 区域框本身仍随结果输出供编辑器标注。region_det 不可用或没有
    # 排除类区时退回整页（无安全边界不强切）。眉批（margin_note）按
    # "标记不删除"哲学保留在管线内，走夹注打标。
    # gate_regions：调用方带入的**人工已确认**版面区（重识别时从标注
    # 取，含确认身份）——人工成果优先于模型预检：直接作为门控输入并
    # 作为结果的 main_regions 带回（不跑第二遍 region_det，确认身份
    # 不因重识别丢失），region_det 模型尚未训出也能按已确认的页眉/
    # 页脚/页码门控。
    human_regions = [r for r in (gate_regions or []) if isinstance(r, dict)]
    if human_regions:
        # 门控区直接作为结果 main_regions 回显：id 必须全程在场——旧
        # 请求不带 id 时补齐（客户端 MainRegion.fromJson 对缺失 id 抛
        # type cast，实测"重新识别当前页"type 'Null' 错误的根因）。
        main_regions = [
            dict(r, id=r.get("id") or f"mr_gate_{i:03d}")
            for i, r in enumerate(human_regions)
        ]
    else:
        main_regions = detect_main_regions(image_path, w, h)
    gated_path = build_body_gated_image(image_path, main_regions)
    detect_source = gated_path or image_path

    def _finish(engine: str, lines: list[dict[str, Any]],
                blocks: list[dict[str, Any]], fallback_reason: str | None,
                model_version: str) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "engine": engine,
            "ocr": "kraken",
            "converter": "opencc-ready" if _import_opencc() else "opencc-unavailable",
            "fallback_reason": fallback_reason,
            "yolo": _yolo_diagnostics(),
            "lines": lines,
            "blocks": blocks,
        }
        if main_regions is not None:
            # 预置区域：_augment 复用，不再跑第二遍 region_det。
            payload["main_regions"] = main_regions
        return _clamp_result_to_image(enrich_result(_filter_layout(
            _augment_with_model_hierarchy(payload, image_path, w, h),
            layout_mode,
        ), image_path, orientation=orientation,
            horizontal_dir=horizontal_dir, vertical_dir=vertical_dir,
            model_version=model_version, layout_mode=layout_mode), w, h)

    try:
        # PP-OCR det 行框优先（engine=paddle 时由调用方注入 line_detector，
        # paddle_bridge.detect_page_lines）：官网演示同款文本检测，行框
        # 质量远超 YOLO 字框分组（实测同页 17 列全检出 vs YOLO 碎片/漏检）。
        # 失败/空产出静默回退下方 YOLO 链路——det 是行框增强，不是硬依赖。
        if line_detector is not None:
            try:
                det_rects = line_detector(detect_source)
            except Exception as exc:
                det_rects = []
                _log(
                    "[segment] PP-OCR det 行检测失败，回退 yolo-char："
                    f"{_exception_summary(exc)}"
                )
            if det_rects:
                det_lines = _lines_from_det_rects(det_rects, w, h, orientation)
                _type_det_lines(det_lines, w, h, main_regions)
                _apply_sort_and_renumber(
                    det_lines, [], horizontal_dir, vertical_dir, orientation
                )
                _log(
                    f"[segment] engine selected: paddle-det, lines: {len(det_lines)}"
                )
                return _finish("paddle-det", det_lines, [], None, "paddle-det")
            _log("[segment] PP-OCR det 无行框产出，回退 yolo-char")
        _log(
            f"[segment] trying engine: yolo-char detector "
            f"layout={layout_mode} orientation={orientation} "
            f"h_dir={horizontal_dir} v_dir={vertical_dir} "
            f"region_gate={'on' if gated_path else 'off'}"
        )
        yolo_lines, yolo_blocks = _segment_with_yolo_chars(
            detect_source, w, h,
            horizontal_dir=horizontal_dir,
            vertical_dir=vertical_dir,
            orientation=orientation,
        )
        if yolo_blocks:
            # 夹注/旁注的并排子列结构在行层拆开（字框按中心归入拆分行），
            # 再统一排序编号——否则整条一个行框，行内切字把两条子列按 y 序
            # 交错输出。
            layout_mask = _text_mask_for_refinement(image_path)
            yolo_lines = split_double_column_lines(
                yolo_lines,
                layout_mask,
                orientation, horizontal_dir, vertical_dir,
            )
            yolo_lines, dropped = drop_duplicate_fragment_lines(
                yolo_lines, orientation, layout_mask
            )
            if dropped:
                _log(f"[segment] 删除与主列字框重复的窄碎片行 {len(dropped)} 条")
            yolo_lines = _merge_adjacent_line_fragments(yolo_lines, orientation)
            _apply_sort_and_renumber(yolo_lines, yolo_blocks, horizontal_dir, vertical_dir, orientation)
            _log(f"[segment] engine selected: yolo-char, blocks: {len(yolo_blocks)}")
            return _finish("hier", yolo_lines, yolo_blocks, None, "hier")

        yolo_reason = current_yolo_error() or "yolo returned no valid blocks"
        _log(f"[segment] yolo unavailable, fallback to opencv projection: {yolo_reason}")
        opencv_lines, opencv_blocks = _segment_with_opencv(
            detect_source,
            horizontal_dir=horizontal_dir,
            vertical_dir=vertical_dir,
            orientation=orientation,
        )
        layout_mask = _text_mask_for_refinement(image_path)
        opencv_lines = split_double_column_lines(
            opencv_lines,
            layout_mask,
            orientation, horizontal_dir, vertical_dir,
        )
        opencv_lines, dropped = drop_duplicate_fragment_lines(
            opencv_lines, orientation, layout_mask
        )
        if dropped:
            _log(f"[segment] 删除与主列字框重复的窄碎片行 {len(dropped)} 条")
        opencv_lines = _merge_adjacent_line_fragments(opencv_lines, orientation)
        _apply_sort_and_renumber(opencv_lines, opencv_blocks, horizontal_dir, vertical_dir, orientation)
        fallback_reason = f"yolo-char unavailable: {yolo_reason}"
        _log(f"[segment] engine selected: opencv, blocks: {len(opencv_blocks)} fallback_reason={fallback_reason}")
        return _finish("opencv", opencv_lines, opencv_blocks, fallback_reason, "opencv")
    finally:
        dispose_body_gated_image(gated_path)
