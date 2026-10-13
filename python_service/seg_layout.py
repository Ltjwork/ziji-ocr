# -*- coding: utf-8 -*-
"""版面过滤与区域操作（从 segmenter 拆出）：版面模式过滤、层级包含、
区域结果裁剪与行延展。segmenter.py 仍为门面。"""
import os
import platform
import sys
import tempfile
import threading
import traceback
from contextvars import ContextVar
import cv2
import numpy as np
from typing import Any
from imaging import imread_unicode
from metadata import enrich_result
from model_registry import resolve_model_path
from seg_trace import _log, append_debug_trace
from seg_imaging import (_text_mask_for_refinement, _imread)
from seg_refine import expand_line_rect_to_neighbor_ink
from seg_models import _predict_detection_layer, detection_layer_names


# ── region_det 多类语义（词表本体在 train_data.LAYER_INFO["region_det"]；
# Dart 侧 flutter_app/lib/models/models.dart 的 regionLabels 是同一协议的
# 另一半，两侧必须同序：main_text 恒为 id=0、新类只追加不重排）──
# 正文宿主类：main_text_only 的包含边界（margin_note=眉批，内容有价值，
# 保留并按夹注打标，与双行夹注同一"标记不删除"哲学）。
REGION_BODY_LABELS = frozenset({"main_text", "margin_note"})
# 排除类：不作为包含边界，其中的行/字在 main_text_only 下被过滤，
# build_body_gated_image 在字检测前抹底色。figure/table 同走门控——
# 表格格线/插图若不抹除会被 char_det 误切成"字"（+83 表格识别）。
REGION_EXCLUDED_LABELS = frozenset(
    {"header", "footer", "page_number", "figure", "table"}
)
# 冲突审计类：与 main_text 的重叠 ≥ REGION_CONFLICT_OVERLAP 记冲突。
# figure/table 不参与——插图/表格出现在正文区内部是正常版面，不是
# region_det 不可信的信号。
REGION_CONFLICT_LABELS = frozenset({"header", "footer", "page_number"})
# main_text 区与排除类区的重叠超过该比例（交集占排除类框）记为冲突。
REGION_CONFLICT_OVERLAP = 0.3


def region_label(region: dict[str, Any]) -> str:
    """区域类别；旧标注/旧模型结果无 label 时按 main_text（与训练侧
    name_index 的缺省同口径，也保证 label 不在词表时仍有确定语义）。"""
    label = region.get("label")
    return label if isinstance(label, str) and label else "main_text"





def _filter_layout(result: dict[str, Any], layout_mode: str) -> dict[str, Any]:
    """Apply layout_mode in the service, before results reach exporters/UI."""
    # 多类互证审计挂在过滤入口（两条管线路径必经）：与 layout_mode 无关，
    # all_text 模式下前端同样要能看到区域冲突提示。
    conflicts = _region_overlap_conflicts(result)
    if conflicts:
        result["region_conflicts"] = conflicts
    if layout_mode != "main_text_only":
        return result
    all_regions = [
        r
        for r in (result.get("main_regions") or [])
        if r.get("status") != "rejected"
    ]
    # 包含边界只认正文宿主类；header/footer/page_number 区不再是边界，
    # 其中的行/字自然落在边界外被过滤——"只识别正文"真正排除页眉页脚页码。
    # 无区域时回退 body 段落（旧行为），此时全部按 main_text 归属。
    regions = [r for r in all_regions if region_label(r) in REGION_BODY_LABELS]
    if regions:
        main_regions = [r for r in regions if region_label(r) == "main_text"]
        margin_regions = [r for r in regions if region_label(r) == "margin_note"]
    else:
        regions = [p for p in (result.get("paragraphs") or [])
                   if p.get("type") == "body" and p.get("status") != "rejected"]
        main_regions, margin_regions = regions, []
    if not regions:
        # No region detector result means there is no safe exclusion boundary.
        result["layout_filter"] = {"mode": layout_mode, "applied": False, "reason": "no_main_regions_or_body_paragraphs"}
        return result

    def inside(item: dict[str, Any], region: dict[str, Any]) -> bool:
        cx = item.get("x", 0) + item.get("w", 0) / 2
        cy = item.get("y", 0) + item.get("h", 0) / 2
        return (region.get("x", 0) <= cx <= region.get("x", 0) + region.get("w", 0)
                and region.get("y", 0) <= cy <= region.get("y", 0) + region.get("h", 0))

    kept_lines = []
    kept_blocks = []
    for line in result.get("lines", []):
        # main_text 区优先归属：同一字框跨 main_text 与 margin_note 区时按
        # 正文算（排除类区咬进眉批区的极端情况不丢正文）。
        chars = [c for c in line.get("chars", [])
                 if any(inside(c, r) for r in main_regions)
                 or any(inside(c, r) for r in margin_regions)]
        if not chars and not any(inside(line, r) for r in regions):
            continue
        line["chars"] = chars
        line["text"] = "".join(str(c.get("text") or "") for c in chars)
        for char in chars:
            char["type"] = (
                "main_text"
                if any(inside(char, r) for r in main_regions) else "annotation"
            )
            kept_blocks.append(char)
        # 行内保留字全是眉批 → 行按夹注打标（与 line_det 的 line_annotation
        # 判定同口径），下游导出/渲染按 annotation 处理。
        if chars and all(c.get("type") == "annotation" for c in chars):
            line["layout_role"] = "annotation"
        kept_lines.append(line)
    result["lines"] = kept_lines
    result["blocks"] = kept_blocks
    result["layout_filter"] = {
        "mode": layout_mode,
        "applied": True,
        "regions": len(regions),
        "excluded_regions": sum(
            1 for r in all_regions if region_label(r) in REGION_EXCLUDED_LABELS
        ),
    }
    return result




def _rect_of(item: dict[str, Any]) -> list[int]:
    return [
        int(item.get("x", 0)),
        int(item.get("y", 0)),
        int(item.get("w", 0)),
        int(item.get("h", 0)),
    ]




def _set_rect(item: dict[str, Any], rect: list[int]) -> None:
    item["x"], item["y"], item["w"], item["h"] = rect




def _clamp_rect_into(rect: list[int], bounds: list[int]) -> list[int] | None:
    """rect 与 bounds 的交集矩形；交集不足 1px 返回 None。"""
    x1 = max(rect[0], bounds[0])
    y1 = max(rect[1], bounds[1])
    x2 = min(rect[0] + rect[2], bounds[0] + bounds[2])
    y2 = min(rect[1] + rect[3], bounds[1] + bounds[3])
    if x2 - x1 < 1 or y2 - y1 < 1:
        return None
    return [x1, y1, x2 - x1, y2 - y1]




def _region_containing(
    rect: list[int], regions: list[dict[str, Any]]
) -> dict[str, Any] | None:
    """中心点落在其中的第一个主区（与 _filter_layout/段落认领同口径）。"""
    cx = rect[0] + rect[2] / 2
    cy = rect[1] + rect[3] / 2
    for r in regions:
        rx, ry = int(r.get("x", 0)), int(r.get("y", 0))
        rw, rh = int(r.get("w", 0)), int(r.get("h", 0))
        if rx <= cx <= rx + rw and ry <= cy <= ry + rh:
            return r
    return None




def _enforce_hierarchy_containment(result: dict[str, Any]) -> None:
    """识别框层级包含（用户规则）：行框 ⊆ 段落框 ⊆ 主区框。

    检测/标点墨迹外扩的行框常伸出主区几个像素，段落框取行外接矩形
    后随之越界；自训段落模型的段框是独立预测，成员行框（按中心归属）
    也可能伸出段框。这里统一收敛：
    ① 行框中心落在某主区内 → 行框钳进该主区（中心在区外的行不动，
       版面外的夹注小字不遭殃）；
    ② 段落框先扩到包住全部成员行框（模型段框可能比成员行小），中心
       落在某主区内 → 钳进该主区并回填 main_region_id；
    ③ 段落框被钳小后，与段落框仍有 ≥1px 交集的成员行框钳进段落框
       （三层框严格嵌套；完全在段落框外的成员行不动）。

    多类化后宿主区只认 main_text：margin_note（眉批）行本就游离在正文
    区外（中心不在宿主内、自然不动），header/footer/page_number 永不
    作为钳制宿主——页眉页脚的行不该被"嵌套进正文"。
    """
    regions = [
        r
        for r in (result.get("main_regions") or [])
        if isinstance(r, dict) and r.get("status") != "rejected"
        and region_label(r) == "main_text"
    ]
    lines = [l for l in (result.get("lines") or []) if isinstance(l, dict)]

    clamped_lines = 0
    if regions:
        for ln in lines:
            rect = _rect_of(ln)
            host = _region_containing(rect, regions)
            if host is None:
                continue
            clamped = _clamp_rect_into(rect, _rect_of(host))
            if clamped is None or clamped == rect:
                continue
            _set_rect(ln, clamped)
            clamped_lines += 1

    clamped_paras = 0
    by_id = {ln.get("id"): ln for ln in lines}
    for p in result.get("paragraphs") or []:
        if not isinstance(p, dict):
            continue
        members = [by_id[i] for i in (p.get("line_ids") or []) if i in by_id]
        original = _rect_of(p)
        rect = list(original)
        for ln in members:
            lr = _rect_of(ln)
            x2 = max(rect[0] + rect[2], lr[0] + lr[2])
            y2 = max(rect[1] + rect[3], lr[1] + lr[3])
            rect = [
                min(rect[0], lr[0]),
                min(rect[1], lr[1]),
                x2 - min(rect[0], lr[0]),
                y2 - min(rect[1], lr[1]),
            ]
        host = _region_containing(rect, regions) if regions else None
        if host is None:
            # 无主区可归属：仍把段落框扩到包住成员行框（行 ⊆ 段落）
            if rect != original:
                _set_rect(p, rect)
                clamped_paras += 1
            continue
        clamped = _clamp_rect_into(rect, _rect_of(host))
        if clamped is None:
            continue
        if clamped != original:
            _set_rect(p, clamped)
            clamped_paras += 1
        p["main_region_id"] = host.get("id", "")
        for ln in members:
            lr = _rect_of(ln)
            inner = _clamp_rect_into(lr, clamped)
            if inner is not None and inner != lr:
                _set_rect(ln, inner)
                clamped_lines += 1
    if clamped_lines or clamped_paras:
        append_debug_trace(
            f"[diag:hierarchy] 层级包含：行框钳制 {clamped_lines} 个、"
            f"段落框钳制 {clamped_paras} 个（行⊆段落⊆主区）"
        )




def regions_from_boxes(
    region_boxes: list[tuple[list[int], float, int]],
    names: dict[int, str] | None,
) -> list[dict[str, Any]]:
    """region_det 原始框 → main_regions 标注格式（含类别 label）。

    cls→label 用 checkpoint 自带 names（旧单类模型 cls 恒 0=main_text，
    追加式词表下映射天然兼容）；names 缺失时按 id 查当前词表兜底。
    与训练侧 name_index 的缺省同口径。
    """
    names = names or {}
    from train_data import LAYER_INFO

    fallback_names = LAYER_INFO["region_det"]["names"]

    def _label_of(cls: int) -> str:
        label = names.get(cls)
        if isinstance(label, str) and label:
            return label
        if 0 <= cls < len(fallback_names):
            return fallback_names[cls]
        return "main_text"

    return [
        {
            "id": f"mr_model_{i:03d}",
            "x": rect[0],
            "y": rect[1],
            "w": rect[2],
            "h": rect[3],
            "label": _label_of(cls),
            "confidence": round(score, 3),
        }
        for i, (rect, score, cls) in enumerate(region_boxes)
    ]


def detect_main_regions(
    image_path: str,
    image_w: int,
    image_h: int,
) -> list[dict[str, Any]] | None:
    """整页 region_det 先行检测（区域门控用）。

    返回 main_regions 列表；模型不可用/出错返回 None（无安全边界，
    调用方退回整页识别，不强切）。结果同时可供 _augment 复用，避免
    同一页跑两遍 region_det。
    """
    try:
        region_boxes = _predict_detection_layer(
            "region_det", image_path, image_w, image_h
        )
    except Exception as exc:
        _log(f"[region-gate] region_det 预检失败，退回整页: {exc}")
        return None
    if not region_boxes:
        return []
    return regions_from_boxes(
        region_boxes, detection_layer_names("region_det")
    )


def build_body_gated_image(
    image_path: str,
    regions: list[dict[str, Any]] | None,
) -> str | None:
    """生成"正文门控图"：把排除类区（页眉/页脚/页码/插图/表格）抹成页面底色。

    区域门控（用户规则：只有正文区域进行段落/行/单字划分与识别，
    页眉页脚等止步于版面区检测）——检测源换成门控图后，排除类区域
    内不再产出任何行/字，后续 Kraken 识别自然不会读到它们；区域
    框本身仍随结果原样输出，供编辑器标注。无排除类区时返回 None
    （用原图即可，不产生临时文件）。表格/插图区同走此门控：格线与
    插图墨迹不抹除就会被 char_det 误切成"字"。
    """
    if not regions:
        return None
    excluded = [
        r for r in regions
        if region_label(r) in REGION_EXCLUDED_LABELS
        and r.get("status") != "rejected"
    ]
    if not excluded:
        return None
    img = _imread(image_path)
    if img is None:
        return None
    h, w = img.shape[:2]
    # 页面底色取边框像素中值：黑底白字的扫描也能抹对颜色。
    border = np.concatenate([
        img[: max(1, h // 50), :, :].reshape(-1, 3),
        img[-max(1, h // 50):, :, :].reshape(-1, 3),
        img[:, : max(1, w // 50), :].reshape(-1, 3),
        img[:, -max(1, w // 50):, :].reshape(-1, 3),
    ])
    bg = np.median(border, axis=0).astype(np.uint8)
    for r in excluded:
        x1 = max(0, int(r.get("x", 0)))
        y1 = max(0, int(r.get("y", 0)))
        x2 = min(w, x1 + max(0, int(r.get("w", 0))))
        y2 = min(h, y1 + max(0, int(r.get("h", 0))))
        if x2 - x1 < 1 or y2 - y1 < 1:
            continue
        img[y1:y2, x1:x2, :] = bg
    fd, tmp_path = tempfile.mkstemp(prefix="ocr_bodygate_", suffix=".png")
    os.close(fd)
    try:
        cv2.imwrite(tmp_path, img)
    except Exception:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        return None
    _log(
        f"[region-gate] 页眉/页脚/页码门控：{len(excluded)} 个排除类区已抹除"
        f"（字检测走门控图 {os.path.basename(tmp_path)}）"
    )
    return tmp_path


def dispose_body_gated_image(path: str | None) -> None:
    """删除门控临时图（识别完成后调用；失败静默，临时目录兜底）。"""
    if not path:
        return
    try:
        os.remove(path)
    except OSError:
        pass


def _augment_with_model_hierarchy(
    result: dict[str, Any],
    image_path: str,
    image_w: int,
    image_h: int,
) -> dict[str, Any]:
    """自训段/区模型启用时，在识别结果上附加 main_regions / paragraphs。

    段落行归属按行中心点落在段框内判定；未启用对应模型时不添加字段，
    前端保持原有规则推断。管线预置过 main_regions（区域门控先行检测）
    时直接复用，不再跑第二遍 region_det。
    """
    lines = result.get("lines") or []

    if "main_regions" in result:
        region_boxes = None  # 已由区域门控预置，跳过重复推理
    else:
        region_boxes = _predict_detection_layer("region_det", image_path, image_w, image_h)
    if region_boxes:
        result["main_regions"] = regions_from_boxes(
            region_boxes, detection_layer_names("region_det")
        )

    para_boxes = _predict_detection_layer("paragraph_det", image_path, image_w, image_h)
    if para_boxes:
        paragraphs = []
        for i, (rect, _score, cls) in enumerate(para_boxes):
            member_ids = []
            for ln in lines:
                cx = ln["x"] + ln["w"] / 2
                cy = ln["y"] + ln["h"] / 2
                if rect[0] <= cx <= rect[0] + rect[2] and rect[1] <= cy <= rect[1] + rect[3]:
                    member_ids.append(ln["id"])
            if not member_ids:
                continue
            paragraphs.append(
                {
                    "id": f"mp_{i:03d}",
                    "x": rect[0],
                    "y": rect[1],
                    "w": rect[2],
                    "h": rect[3],
                    "main_region_id": "",
                    "line_ids": member_ids,
                    "type": "annotation" if cls == 1 else "body",
                    "manual": False,
                }
            )
        if paragraphs:
            result["paragraphs"] = paragraphs
    _enforce_hierarchy_containment(result)
    return result




def _region_overlap_conflicts(result: dict[str, Any]) -> list[dict[str, Any]]:
    """main_text 区与排除类区（header/footer/page_number）的重叠审计。

    多类互证：main_text 框画进页眉、或页眉框咬掉正文边缘，都是 region_det
    结果不可信的信号。只标记不裁决——前端据此提示走预标注或人工修正。
    """
    regions = [r for r in (result.get("main_regions") or []) if isinstance(r, dict)]
    body = [r for r in regions if region_label(r) == "main_text"]
    excluded = [r for r in regions if region_label(r) in REGION_CONFLICT_LABELS]
    conflicts: list[dict[str, Any]] = []
    for ex in excluded:
        for b in body:
            inter = _clamp_rect_into(_rect_of(b), _rect_of(ex))
            if inter is None:
                continue
            ex_area = max(1, _rect_of(ex)[2] * _rect_of(ex)[3])
            ratio = (inter[2] * inter[3]) / ex_area
            if ratio >= REGION_CONFLICT_OVERLAP:
                conflicts.append({
                    "main_region_id": b.get("id", ""),
                    "other_region_id": ex.get("id", ""),
                    "label": region_label(ex),
                    "overlap": round(ratio, 3),
                })
    return conflicts




def filter_result_to_region(
    result: dict[str, Any],
    region: tuple[int, int, int, int],
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
    orientation: str = "vertical",
) -> dict[str, Any]:
    """把整页识别结果过滤为"与区域相交的行"（整行保留），并重排序号。

    在识别之后调用：调用方先对整页结果跑完全部识别（与 /segment 同一
    批次），再过滤——保证区域重识别与整页重识别对同一行产出完全一致。
    此前先过滤再识别会让识别批次只含区域内的行，批内最窄行宽变化带动
    Kraken 放大倍数（recognize_lines 的 effective_scale）与二值化随之
    改变，同一行的读法/正文判定在两条链路间漂移。

    行保留条件：行中心或任一字中心落在区域内（行外扩成整列后行中心
    可能移出区域，只要区域内有本行的字就保留）。保留整行、不按区域
    裁字：行是完整的阅读单元，把跨区域边界的列拦腰截断会让区域外的
    字直接消失（重识别后"文字照不全"）；跨边界列与区域外的旧行可能
    短暂并存重复内容，由编辑器/人工去重。"""
    # 懒导入：seg_pipeline 依赖本模块（_filter_layout），顶层互相 import 成环
    from seg_pipeline import _apply_sort_and_renumber

    rx, ry, rw, rh = region
    rx = max(0, rx)
    ry = max(0, ry)

    def center_inside(item: dict[str, Any]) -> bool:
        try:
            cx = float(item.get("x", 0)) + float(item.get("w", 0)) / 2.0
            cy = float(item.get("y", 0)) + float(item.get("h", 0)) / 2.0
        except (TypeError, ValueError):
            return False
        return rx <= cx <= rx + rw and ry <= cy <= ry + rh

    lines: list[dict[str, Any]] = []
    for source_line in result.get("lines", []) or []:
        if not isinstance(source_line, dict):
            continue
        chars = [
            c for c in (source_line.get("chars", []) or [])
            if isinstance(c, dict)
        ]
        if not center_inside(source_line) and not any(
            center_inside(c) for c in chars
        ):
            continue
        lines.append(dict(source_line))
    _log(
        f"[diag:region-filter] region={region} 整行保留 "
        f"{len(lines)}/{len(result.get('lines') or [])} 行"
    )

    # 过滤后重新编号，保持返回结果与整页识别相同的阅读顺序。
    blocks = [c for line in lines for c in (line.get("chars", []) or [])]
    _apply_sort_and_renumber(lines, blocks, horizontal_dir, vertical_dir, orientation)
    result = dict(result)
    result["lines"] = lines
    result["blocks"] = blocks
    result["region"] = (rx, ry, rw, rh)
    result["coordinate_space"] = "image"
    return result




def extend_lines_to_region_ink(
    result: dict[str, Any],
    region: tuple[int, int, int, int],
    mask: np.ndarray | None,
    orientation: str = "vertical",
) -> dict[str, Any]:
    """把与用户区域相交的行框沿阅读轴扩到覆盖区域内的墨迹（就地更新）。

    夹注小字列的检测行框常只盖住中段：夹注字距可大于列宽，行框外扩的
    0.85×列宽空白容限被字距空白挡停（实测註四列墨迹 y129..1553、行框
    只到 y618，顶部约 15 字留在框外——区域重识别整行替换后这些字连
    字框都没有）。用户画区域框的动作本身就是"这一列属于同一行"的
    意图表达：与区域相交的行沿自身列带向区域内墨迹扩展行框，切字与
    识别随之覆盖整列。

    只扩不缩；墨迹范围以区域阅读轴边界为限（区域外的段落不吸入）；
    行带（跨阅读轴）保持不变，不会吃到邻列。mask 与像素切分同源。
    """
    lines = [l for l in (result.get("lines") or []) if isinstance(l, dict)]
    if not lines or mask is None or mask.ndim != 2:
        return result
    vertical = orientation != "horizontal"
    img_h, img_w = mask.shape[:2]
    cross_limit = img_w if vertical else img_h
    read_limit = img_h if vertical else img_w
    rx = max(0, int(region[0]))
    ry = max(0, int(region[1]))
    rw = max(0, int(region[2]))
    rh = max(0, int(region[3]))
    if vertical:
        reg_cross = (rx, min(img_w, rx + rw))
        reg_read = (ry, min(img_h, ry + rh))
    else:
        reg_cross = (ry, min(img_h, ry + rh))
        reg_read = (rx, min(img_w, rx + rw))
    pad = max(2, min(img_w, img_h) // 700)

    for line in lines:
        try:
            lx, ly = int(line.get("x", 0)), int(line.get("y", 0))
            lw, lh = int(line.get("w", 0)), int(line.get("h", 0))
        except (TypeError, ValueError):
            continue
        if lw <= 0 or lh <= 0:
            continue
        # 并排子列拆分行：框已贴各自子带墨迹，外扩会把上段通栏框吃进
        # 下方双列段（见 split_double_column_lines）。
        if line.get("double_col_split"):
            continue
        if vertical:
            cross1, cross2 = lx - pad, lx + lw + pad
            read1, read2 = ly, ly + lh
        else:
            cross1, cross2 = ly - pad, ly + lh + pad
            read1, read2 = lx, lx + lw
        # 行带与区域无交集（邻列）：不属用户框选意图，原样保留。
        if cross2 <= reg_cross[0] or cross1 >= reg_cross[1]:
            continue
        band1 = max(0, cross1)
        band2 = min(cross_limit, cross2)
        if band2 <= band1:
            continue
        r1 = max(0, reg_read[0])
        r2 = min(read_limit, reg_read[1])
        if r2 <= r1:
            continue
        # 区域阅读轴范围内的本带墨迹（跨轴投影，任一行/列有墨即算）。
        if vertical:
            roi = mask[r1:r2, band1:band2]
            ink_axis = np.nonzero(roi.any(axis=1))[0]
        else:
            roi = mask[band1:band2, r1:r2]
            ink_axis = np.nonzero(roi.any(axis=0))[0]
        if ink_axis.size == 0:
            continue
        ink1 = r1 + int(ink_axis[0])
        ink2 = r1 + int(ink_axis[-1]) + 1
        new1 = min(read1, max(r1, ink1 - pad))
        new2 = max(read2, min(r2, ink2 + pad))
        if new1 >= read1 and new2 <= read2:
            continue
        if vertical:
            line["x"], line["y"], line["w"], line["h"] = lx, new1, lw, new2 - new1
        else:
            line["x"], line["y"], line["w"], line["h"] = new1, ly, new2 - new1, lh
        _log(
            f"[diag:region-extend] 区域墨迹扩展行框 "
            f"({lx},{ly},{lw},{lh}) -> "
            f"({line['x']},{line['y']},{line['w']},{line['h']}) "
            f"墨迹 {ink1}..{ink2}"
        )
    return result




def segment_lines_in_region(
    image_path: str,
    region: tuple[int, int, int, int],
    layout_mode: str = "all_text",
    orientation: str = "vertical",
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
) -> dict[str, Any]:
    """重跑指定区域内的分行、拆字和 OCR，并返回全图坐标。

    识别在原图上执行，再按区域筛选结果。旧实现先裁剪段框再识别，
    对新增的窄段会改变 OCR/投影的尺度，导致行框尺寸随段框大小漂移，
    尤其是竖排古籍的行框会被错误压缩。原图识别保持统一像素尺度，
    也不需要再做裁剪坐标平移。

    注意：本函数不做文字识别（识别由调用方在过滤前后统一执行——
    /segment_lines_in_region 端点会先对整页结果跑完识别再过滤）。
    """
    # 懒导入：seg_pipeline 依赖本模块（_filter_layout），顶层互相 import 成环
    from seg_pipeline import _apply_sort_and_renumber, segment_image_with_metadata

    img = _imread(image_path)
    if img is None:
        raise ValueError(f"Cannot read image: {image_path}")
    img_h, img_w = img.shape[:2]
    rx, ry, rw, rh = region
    rx = max(0, min(int(rx), max(0, img_w - 1)))
    ry = max(0, min(int(ry), max(0, img_h - 1)))
    rw = max(1, min(int(rw), img_w - rx))
    rh = max(1, min(int(rh), img_h - ry))
    region_rect = (rx, ry, rw, rh)

    _log(
        f"[segment_region_lines] image={image_path} "
        f"region=({rx},{ry},{rw},{rh}) mode=full-image-filter"
    )
    result = segment_image_with_metadata(
        image_path,
        layout_mode=layout_mode,
        orientation=orientation,
        horizontal_dir=horizontal_dir,
        vertical_dir=vertical_dir,
    )
    result = filter_result_to_region(
        result, region_rect, horizontal_dir, vertical_dir, orientation
    )
    _log(
        f"[segment_region_lines] ok engine={result.get('engine')} "
        f"lines={len(result['lines'])} chars={len(result['blocks'])}"
    )
    return result
