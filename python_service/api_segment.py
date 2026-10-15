# -*- coding: utf-8 -*-
"""切分域路由（从 main.py 拆出）：/segment /crop /segment_region /segment_lines_in_region /debug_char_split。"""
import base64
import functools
import os
import sys
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import List, Optional
import cv2
import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import kraken_bridge
import paddle_bridge
import segmenter
import char_cluster
import char_verify
import daemon_sizing
import page_dewarp
from imaging import imwrite_unicode
from layout_refinement import normalize_layout
from segmenter import (
    begin_debug_trace,
    debug_trace_snapshot,
    segment_image_with_metadata,
    segment_lines_in_region,
    get_char_candidates,
    make_kraken_char_splitter,
    mask_polarity_info,
    split_punct_merged_boxes,
    _imread,
    _text_mask_for_refinement,
    _split_chars_in_region,
    expand_line_rect_to_neighbor_ink,
)
from api_base import (Block, _acquire_recognition_slot, app, _gated_recognition, _release_recognition_slot)





class GateRegion(BaseModel):
    """重识别时随请求带入的人工已确认版面区（区域门控输入）。

    字段与标注里 main_regions 的子集对齐；id 透传——门控区会作为结果的
    main_regions 原样回显（确认身份不丢），客户端 MainRegion.fromJson
    对缺失 id 会抛 type cast（实测踩坑），id 必须全程在场；
    缺省由 seg_pipeline 补 mr_gate_NNN。"""
    x: int
    y: int
    w: int
    h: int
    label: str = "main_text"
    status: str = "confirmed"
    id: Optional[str] = None


class SegmentRequest(BaseModel):
    image_path: str
    layout_mode: str = "all_text"  # 'main_text_only' | 'all_text'
    orientation: str = "vertical"  # 'horizontal' | 'vertical'
    horizontal_dir: str = "ltr"  # 'ltr' | 'rtl'
    vertical_dir: str = "ttb"  # 'ttb' | 'btt'
    debug: bool = False  # 为 True 时额外返回可视化图路径
    use_models: bool = True  # False 时禁用自训模型走基线管线（模型对比测试用）
    test_layer: Optional[str] = None  # 模型对比：该层临时套用指定模型
    test_model_path: Optional[str] = None  # 指定的模型文件路径
    # 识别引擎：'kraken'（默认，历史行为不变）| 'paddle'（PaddleOCR，
    # 每本书可选，见 project.json 的 settings.engine）。
    engine: str = "kraken"
    # paddle 引擎的识别模型档位（PP-OCRv6 tiny/small/medium _rec）；
    # 缺省 PP-OCRv6_small_rec（20.4MB 蒸馏小模型）。kraken 引擎忽略。
    paddle_model: Optional[str] = None
    # 人工已确认版面区（Dart 侧 ensurePageAnnotation 从现有标注取）：
    # 区域门控优先用它，结果的 main_regions 原样带回（确认身份不丢）。
    gate_regions: List[GateRegion] = []
    # 按项目的多层模型覆写（Dart 侧 project.modelOverrides）：layer ->
    # .pt 路径（任意 run 的 best 或某轮检查点），''=该层强制停用；
    # 缺省/空 = 跟随全局注册表启用。线程本地存储，请求结束清空。
    model_overrides: dict = {}




def _draw_debug_overlay(image_path: str, lines: list[dict], blocks: list[dict]) -> str | None:
    """在原图上画绿框(行) + 蓝框(单字)，保存为 <basename>_debug.png，返回保存路径。"""
    img = _imread(image_path)
    if img is None:
        return None
    for ln in lines or []:
        x, y, w, h = ln["x"], ln["y"], ln["w"], ln["h"]
        cv2.rectangle(img, (x, y), (x + w, y + h), (0, 255, 0), 3)
    for b in blocks or []:
        x, y, w, h = b["x"], b["y"], b["w"], b["h"]
        cv2.rectangle(img, (x, y), (x + w, y + h), (255, 0, 0), 2)
    base, _ = os.path.splitext(image_path)
    out_path = f"{base}_debug.png"
    if not imwrite_unicode(out_path, img):
        return None
    return out_path




def _draw_mask_overlay(image_path: str, alpha: float = 0.45) -> str | None:
    """生成墨迹 mask 叠加图：墨迹区域显红色半透明，保存为 <basename>_mask.png。"""
    img = _imread(image_path)
    if img is None:
        return None
    mask = _text_mask_for_refinement(image_path)
    if mask is None:
        return None
    mask_bool = mask > 0
    blended = img.copy()
    blended[mask_bool] = cv2.addWeighted(
        img[mask_bool],
        1.0 - alpha,
        np.full_like(img[mask_bool], (0, 0, 255)),
        alpha,
        0,
    )
    base, _ = os.path.splitext(image_path)
    out_path = f"{base}_mask.png"
    if not imwrite_unicode(out_path, blended):
        return None
    return out_path




class CropRequest(BaseModel):
    image_path: str
    output_dir: str
    blocks: List[Block]




class CharBox(BaseModel):
    x: int
    y: int
    w: int
    h: int




class SegmentRegionRequest(BaseModel):
    image_path: str
    x: int
    y: int
    w: int
    h: int
    line_id: str
    line_no: int = 0
    orientation: str = "vertical"
    horizontal_dir: str = "ltr"
    vertical_dir: str = "ttb"
    # 提供时：跳过自动拆字，仅对给定的字框重新 OCR（保留手画/调整过的框）
    char_boxes: Optional[List[CharBox]] = None
    # 严格保留传入字框（编辑器「重新识别本行」/行内重切「识别填字」）：
    # 字框数与整行读法不一致、或框形似均分合成框时也不弃用用户框重切
    # ——框几何是人工校对成果，只重填文字。缺省 False 保持全页识别等
    # 链路的对齐校验行为。
    strict_char_boxes: bool = False
    # 提供时（且未给 char_boxes）：作为像素切分器的期望字数（AI 框检查按
    # 几何/视觉模型推算的真实字数）——Kraken 序列漏读/粘读时其字数不可信，
    # 切分器据此选对连通域合并/细切策略
    expected_char_count: Optional[int] = None
    # False 时行框不沿阅读轴外扩到整列墨迹，识别/切分范围即传入行框。
    # app 判定该行与其它行共享列带（小字注释列被拆成的分段单行）时传
    # False：外扩会把两字小注段吞成整列，切出的全部字框叠在段图上。
    expand: bool = True
    engine: str = "kraken"
    paddle_model: Optional[str] = None
    # 行的版面类型（det 定行打的 region_label，如 header/footer/
    # page_number）：单行重识别回包沿用传入类型——行类型是页级识别
    # 成果，重识别只换文字不该丢。空 = 正文行（不回盖）。
    region_label: str = ""


def _stamp_region_label(lines: list, region_label: str) -> None:
    """单行重识别回包回盖行版面类型（非正文类型同时标 annotation）。"""
    if not region_label:
        return
    for ln in lines:
        ln["region_label"] = region_label
        if region_label in ("header", "footer", "page_number", "margin_note"):
            ln["layout_role"] = "annotation"




class SegmentLinesInRegionRequest(BaseModel):
    image_path: str
    x: int
    y: int
    w: int
    h: int
    layout_mode: str = "all_text"
    orientation: str = "vertical"
    horizontal_dir: str = "ltr"
    vertical_dir: str = "ttb"
    # 与 /segment 同款区域门控输入（保持两条链路同一批次的一致性）：
    # 人工已确认的排除类区同样在字检测前抹除。
    gate_regions: List[GateRegion] = []
    engine: str = "kraken"
    paddle_model: Optional[str] = None




@app.post("/segment")
def segment(req: SegmentRequest):
    print(f"[segment] received path: {req.image_path!r}", flush=True)
    print(f"[segment] file exists: {os.path.exists(req.image_path)}", flush=True)
    print(
        f"[segment] layout={req.layout_mode} orientation={req.orientation} "
        f"h_dir={req.horizontal_dir} v_dir={req.vertical_dir}",
        flush=True,
    )
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    # 模型对比/基线请求会临时改写 segmenter 的全局模型状态，独占两个
    # 槽位执行（期间其他识别请求 409）；常规整页识别占一个槽位，允许
    # 与另一页在途请求流水线重叠。
    exclusive = (not req.use_models) or bool(req.test_layer and req.test_model_path)
    _acquire_recognition_slot("segment", exclusive=exclusive)
    segment_started = time.time()
    if not req.use_models:
        # 模型对比测试的基线跑法：识别锁保证此刻没有其他识别并发，
        # 临时禁用自训模型，结束后（无论成败）恢复。
        segmenter.set_models_disabled(True)
    if req.test_layer and req.test_model_path:
        segmenter.set_model_test(req.test_layer, req.test_model_path)
    # 项目级模型覆写（模型管理页「本项目使用」）：线程本地，本请求内
    # _get_custom_model 按层取用；finally 清空防串线。
    segmenter.set_model_overrides(req.model_overrides or None)
    try:
        begin_debug_trace()
        img_test = _imread(req.image_path)
        print(f"[segment] imread result: {None if img_test is None else img_test.shape}", flush=True)
        layout_t0 = time.time()
        print(f"[segment] layout detection start ...", flush=True)
        # engine=paddle：行框改用 PP-OCR det（官网演示同款检测，实测行框
        # 质量远超 YOLO 字框分组；OCR_PADDLE_DET_LINES=0 停用回退 YOLO）。
        line_detector = (
            functools.partial(
                paddle_bridge.detect_page_lines, model=req.paddle_model
            )
            if req.engine == "paddle"
            else None
        )
        result = segment_image_with_metadata(
            req.image_path,
            layout_mode=req.layout_mode,
            orientation=req.orientation,
            horizontal_dir=req.horizontal_dir,
            vertical_dir=req.vertical_dir,
            gate_regions=[g.model_dump() for g in req.gate_regions],
            line_detector=line_detector,
        )
        print(
            f"[segment] layout done in {time.time() - layout_t0:.1f}s, "
            f"lines={len(result.get('lines') or [])}",
            flush=True,
        )
        # 混合识别：版面/行检测保持上面的结果，单字识别文本换成所选引擎
        # （kraken 默认 / paddle 可选）；字框为像素（墨迹）切分框。
        print(
            f"[segment] {req.engine} recognition start: "
            f"{len(result.get('lines') or [])} lines ...",
            flush=True,
        )
        rec_t0 = time.time()
        char_splitter = make_kraken_char_splitter(
            req.image_path, req.orientation, req.horizontal_dir
        )
        if req.engine == "paddle":
            result = paddle_bridge.apply_paddle_recognition(
                result, req.image_path, req.orientation, req.horizontal_dir,
                char_splitter=char_splitter, model=req.paddle_model,
                vertical_dir=req.vertical_dir,
            )
        else:
            result = kraken_bridge.apply_kraken_recognition(
                result, req.image_path, req.orientation, req.horizontal_dir,
                char_splitter=char_splitter, vertical_dir=req.vertical_dir,
            )
        print(
            f"[segment] {req.engine} recognition done in {time.time() - rec_t0:.1f}s, "
            f"chars={len(result.get('blocks') or [])}",
            flush=True,
        )
        result["debug_trace"] = debug_trace_snapshot()
        if req.debug:
            debug_path = _draw_debug_overlay(
                req.image_path,
                result.get("lines", []),
                result.get("blocks", []),
            )
            result["debug_image_path"] = debug_path
            mask_path = _draw_mask_overlay(req.image_path)
            result["mask_image_path"] = mask_path
        print(
            f"[segment] result engine={result['engine']} "
            f"ocr={result['ocr']} converter={result['converter']} "
            f"lines={len(result.get('lines', []))} blocks={len(result['blocks'])}",
            flush=True,
        )
        return result
    except Exception as e:
        print(f"[segment] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if not req.use_models:
            segmenter.set_models_disabled(False)
        segmenter.set_model_test(None, None)
        segmenter.set_model_overrides(None)
        _release_recognition_slot(exclusive=exclusive)
        print(
            f"[segment] finished in {time.time() - segment_started:.1f}s",
            flush=True,
        )




@app.post("/crop")
def crop(req: CropRequest):
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")

    img = _imread(req.image_path)
    if img is None:
        raise HTTPException(status_code=400, detail="cannot read image")

    out_dir = Path(req.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    h, w = img.shape[:2]
    results = []
    for b in req.blocks:
        x = max(0, b.x)
        y = max(0, b.y)
        bw = min(b.w, w - x)
        bh = min(b.h, h - y)
        if bw <= 0 or bh <= 0:
            continue
        crop_img = img[y:y+bh, x:x+bw]
        filename = f"{b.id}.png"
        out_path = str(out_dir / filename)
        if not imwrite_unicode(out_path, crop_img):
            raise HTTPException(
                status_code=500,
                detail=f"crop write failed: {out_path}",
            )
        results.append({"id": b.id, "file": filename})

    return {"crops": results, "count": len(results)}




@app.post("/segment_region")
@_gated_recognition("segment_region")
def segment_region(req: SegmentRegionRequest):
    char_boxes = [(b.x, b.y, b.w, b.h) for b in (req.char_boxes or [])]
    print(
        f"[segment_region] path={req.image_path!r} "
        f"region=({req.x},{req.y},{req.w},{req.h}) line_id={req.line_id} "
        f"char_boxes={len(char_boxes)}",
        flush=True,
    )
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    try:
        begin_debug_trace()
        print(
            f"[segment_region] kraken recognition start: "
            f"rect=({req.x},{req.y},{req.w},{req.h}) ...",
            flush=True,
        )
        kraken_t0 = time.time()
        # 行框级入口：命中并排子列（夹注/旁注）结构时拆成多行识别，
        # 否则与原单行识别完全同链路。响应同时给 lines 列表与兼容字段
        # line（=首行）/ blocks（全部行字块扁平）。
        if req.engine == "paddle":
            lines = paddle_bridge.paddle_segment_rect(
                req.image_path,
                {"x": req.x, "y": req.y, "w": req.w, "h": req.h},
                req.line_id,
                req.line_no,
                req.orientation,
                req.horizontal_dir,
                char_boxes=char_boxes or None,
                char_splitter=make_kraken_char_splitter(
                    req.image_path, req.orientation, req.horizontal_dir
                ),
                vertical_dir=req.vertical_dir,
                strict_char_boxes=req.strict_char_boxes,
                expected_char_count=(req.expected_char_count if not char_boxes else None),
                expand=req.expand,
                model=req.paddle_model,
            )
        else:
            lines = kraken_bridge.kraken_segment_rect(
                req.image_path,
                {"x": req.x, "y": req.y, "w": req.w, "h": req.h},
                req.line_id,
                req.line_no,
                req.orientation,
                req.horizontal_dir,
                char_boxes=char_boxes or None,
                char_splitter=make_kraken_char_splitter(
                    req.image_path, req.orientation, req.horizontal_dir
                ),
                vertical_dir=req.vertical_dir,
                strict_char_boxes=req.strict_char_boxes,
                expected_char_count=(req.expected_char_count if not char_boxes else None),
                expand=req.expand,
            )
        print(
            f"[segment_region] {req.engine} ok lines={len(lines)} "
            f"chars={sum(len(l['chars']) for l in lines)} in {time.time() - kraken_t0:.1f}s",
            flush=True,
        )
        _stamp_region_label(lines, req.region_label)
        return {
            "lines": lines,
            "line": lines[0],
            "blocks": [c for l in lines for c in l["chars"]],
            "debug_trace": debug_trace_snapshot(),
        }
    except Exception as e:
        print(f"[segment_region] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




@app.post("/segment_lines_in_region")
@_gated_recognition("segment_lines_in_region")
def segment_lines_in_region_endpoint(req: SegmentLinesInRegionRequest):
    print(
        f"[segment_lines_in_region] path={req.image_path!r} "
        f"region=({req.x},{req.y},{req.w},{req.h})",
        flush=True,
    )
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    try:
        begin_debug_trace()
        # 与 /segment 完全相同的整页识别（同一批次、同一放大倍数），保证
        # 区域重识别与整页重识别对同一行产出一致；识别完成后再按区域
        # 过滤。此前先过滤再识别会让批内最窄行宽变化带动 Kraken 放大
        # 倍数与二值化改变，同一行的读法在两条链路间漂移、文字错乱。
        # engine=paddle 时行框同样走 PP-OCR det（与 /segment 同源）。
        result = segment_image_with_metadata(
            req.image_path,
            layout_mode=req.layout_mode,
            orientation=req.orientation,
            horizontal_dir=req.horizontal_dir,
            vertical_dir=req.vertical_dir,
            gate_regions=[g.model_dump() for g in req.gate_regions],
            line_detector=(
                functools.partial(
                    paddle_bridge.detect_page_lines, model=req.paddle_model
                )
                if req.engine == "paddle"
                else None
            ),
        )
        # 用户画的区域是行归属意图：与区域相交的行先沿自身列带扩到区域
        # 内墨迹再识别——夹注小字列的检测行框常被字距空白截短（0.85×
        # 列宽容限不够用），不扩的话区域重识别只换回半列，框外字连字框
        # 都没有（实测註四列顶部约 15 字）。仍与 /segment 同一批次识别，
        # 只是行框几何先行覆盖用户选中的整列。
        result = segmenter.extend_lines_to_region_ink(
            result,
            (req.x, req.y, req.w, req.h),
            _text_mask_for_refinement(req.image_path),
            req.orientation,
        )
        print(
            f"[segment_lines_in_region] kraken recognition start: "
            f"{len(result.get('lines') or [])} lines (full page) ...",
            flush=True,
        )
        kraken_t0 = time.time()
        char_splitter = make_kraken_char_splitter(
            req.image_path, req.orientation, req.horizontal_dir
        )
        if req.engine == "paddle":
            result = paddle_bridge.apply_paddle_recognition(
                result, req.image_path, req.orientation, req.horizontal_dir,
                char_splitter=char_splitter, model=req.paddle_model,
                vertical_dir=req.vertical_dir,
            )
        else:
            result = kraken_bridge.apply_kraken_recognition(
                result, req.image_path, req.orientation, req.horizontal_dir,
                char_splitter=char_splitter, vertical_dir=req.vertical_dir,
            )
        result = segmenter.filter_result_to_region(
            result,
            (req.x, req.y, req.w, req.h),
            req.horizontal_dir,
            req.vertical_dir,
            req.orientation,
        )
        print(
            f"[segment_lines_in_region] kraken done in {time.time() - kraken_t0:.1f}s, "
            f"chars={len(result.get('blocks') or [])}",
            flush=True,
        )
        result["debug_trace"] = debug_trace_snapshot()
        print(
            f"[segment_lines_in_region] ok engine={result['engine']} "
            f"lines={len(result['lines'])} blocks={len(result['blocks'])}",
            flush=True,
        )
        return result
    except Exception as e:
        print(f"[segment_lines_in_region] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




class RefreshFullTextLine(BaseModel):
    """待刷新对照标记的行：标注里的当前行框 + 逐字文本（只读不写回）。"""
    id: str
    x: int
    y: int
    w: int
    h: int
    char_texts: List[str] = []


class RefreshFullTextCheckRequest(BaseModel):
    image_path: str
    lines: List[RefreshFullTextLine] = []


@app.post("/refresh_full_text_check")
def refresh_full_text_check(req: RefreshFullTextCheckRequest):
    """用文本视图整页直读的行记录（direct_text 侧车）刷新标注行的对照
    标记——纯 CPU（读侧车 + IoU 匹配 + 序列对齐），不跑任何模型。

    背景：对照标记在"识别当前页"时随识别写入标注；之后用户重新整页
    直读（行记录更新，如版面模式切换/模型更换/AI 校对后）标注里的旧
    标记不会跟着变——编辑器在直读完成后调这里即时刷新，识别不用重跑。
    返回逐行 {id, full_text, full_extras, diff_indices}；行没匹配上/无
    侧车时对应字段为空（客户端按空值覆盖，清掉过期标记）。"""
    t0 = time.time()
    if os.environ.get("FULL_TEXT_CHECK", "1") == "0":
        return {"updates": [], "ref_lines": 0, "disabled": True}
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    try:
        ref_lines = paddle_bridge._sidecar_page_lines(req.image_path) or []
        updates = []
        for line in req.lines:
            update = {"id": line.id, "full_text": "", "full_extras": [],
                      "diff_indices": []}
            if ref_lines and line.w > 0 and line.h > 0:
                ref = kraken_bridge._match_page_ref_line(
                    ref_lines,
                    {"x": line.x, "y": line.y, "w": line.w, "h": line.h},
                )
                if ref is not None:
                    text = str(ref.get("text") or "")
                    if text.strip():
                        extras, diffs = kraken_bridge._align_full_text(
                            text, list(line.char_texts)
                        )
                        update["full_text"] = text
                        update["full_extras"] = extras
                        update["diff_indices"] = [
                            i for i, d in enumerate(diffs) if d
                        ]
            updates.append(update)
        matched = sum(1 for u in updates if u["full_text"])
        print(
            f"[refresh_full_text_check] lines={len(updates)} matched={matched} "
            f"ref={len(ref_lines)} in {time.time() - t0:.2f}s",
            flush=True,
        )
        return {"updates": updates, "ref_lines": len(ref_lines)}
    except Exception as e:
        print(f"[refresh_full_text_check] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




class DebugCharSplitLine(BaseModel):
    x: int
    y: int
    w: int
    h: int
    expected_count: int = 0  # 行内期望字数（编辑器传入当前字数）




class DebugCharSplitRequest(BaseModel):
    image_path: str
    lines: List[DebugCharSplitLine] = []  # 缺省时自动整页分行（只检测行，不识别文字）
    orientation: str = "vertical"  # "horizontal" | "vertical"




def _cleanup_debug_images(base: str) -> None:
    """删除本页旧的切字诊断图。

    诊断图文件名带时间戳（同名文件会被 Flutter 图片缓存钉住，换行重
    开时永远显示第一张——"只显示第一次打开的那一行"的根源），每次生
    成前先清掉旧图，避免累积。"""
    folder, name = os.path.split(base)
    if not folder:
        folder = "."
    prefix = f"{name}_dbg_"
    try:
        for entry in os.listdir(folder):
            if entry.startswith(prefix) and entry.endswith((".png", ".txt")):
                try:
                    os.remove(os.path.join(folder, entry))
                except OSError:
                    pass
    except OSError:
        pass




@app.post("/debug_char_split")
def debug_char_split(req: DebugCharSplitRequest):
    """切字过程可视化（诊断用，不参与识别）。

    切字链路：整页二值化墨迹 mask（含极性自检）→ 行框沿阅读轴外扩到
    本行连续墨迹 → 行内水平膨胀合并同字笔画 → 连通域分块 → 面积过滤
    （墨点丢弃）→ 碎片合并/粘连投影细切 → 数量校验（与期望字数不符
    回退网格均分，优先在纯白区间下刀）→ 超高字框"字+标点"同框拆分
    → 字框来源决策与条带收紧模拟（兜底切分行在识别链路会改用 kraken
    cuts 条带框再收紧，黄框即其模拟）→ 宽框体检（比同行中位宽 30% 的
    框量墨迹并写明成因）。
    本端点把每一步的中间产物画出来：

    - <basename>_dbg_mask_<t>.png     整页二值化墨迹（切分器"眼中"的图）
    - <basename>_dbg_line<i>_<t>.png  每行：绿粗=外扩后行框，绿细=传入
                                      行框，橙=连通域块，红=丢弃墨点，
                                      紫=被拆分的同框框，蓝=最终字框
                                      （含序号与方法标注），黄=识别框
                                      模拟（cuts 条带收紧后，仅兜底行）

    返回每行的方法（components/layout-grid/equal-division）、连通域数、
    丢弃墨点数、外扩前后行框、标点拆分数、mask 极性等结构化诊断。
    """
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    try:
        img = _imread(req.image_path)
        if img is None:
            raise HTTPException(status_code=400, detail="cannot read image")
        # 采集切分链路的逐行决策日志（行框外扩/连通域/碎片合并/兜底/
        # 标点拆分及其原因），随响应返回并在下面落盘，方便整份分享。
        begin_debug_trace()
        ih, iw = img.shape[:2]
        mask = _text_mask_for_refinement(req.image_path)
        if mask is None:
            raise HTTPException(status_code=500, detail="mask unavailable")

        base, _ = os.path.splitext(req.image_path)
        stamp = int(time.time() * 1000)
        _cleanup_debug_images(base)
        polarity = mask_polarity_info(req.image_path)

        # ① 整页二值化墨迹图（白底黑墨，所见即切分所得）
        mask_view = np.full((ih, iw, 3), 255, dtype=np.uint8)
        mask_view[mask > 0] = (0, 0, 0)
        mask_path = f"{base}_dbg_mask_{stamp}.png"
        imwrite_unicode(mask_path, mask_view)

        # ② 行框：传入优先，缺省自动整页分行（仅检测，不识别）
        line_specs: list[tuple[tuple[int, int, int, int], int]] = []
        if req.lines:
            line_specs = [((l.x, l.y, l.w, l.h), l.expected_count) for l in req.lines]
        else:
            seg = segment_image_with_metadata(
                req.image_path, orientation=req.orientation,
            )
            for ln in seg.get("lines", []):
                line_specs.append(
                    ((int(ln["x"]), int(ln["y"]), int(ln["w"]), int(ln["h"])), 0)
                )

        results: list[dict] = []
        for i, (rect_in, expected) in enumerate(line_specs):
            # 与识别链路一致：行框先沿阅读轴外扩到本行连续墨迹再切分，
            # 诊断所见即识别所得。
            rect = expand_line_rect_to_neighbor_ink(
                rect_in, mask, iw, ih, req.orientation,
            )
            rect_expanded = rect != rect_in
            x, y, w, h = rect
            diag: dict = {}
            boxes = _split_chars_in_region(
                mask, rect, iw, ih, expected_count=expected, diag=diag
            )
            # 与识别链路一致的"字+标点"同框后检拆分（拆分前的框留作
            # 下方条带收紧模拟的输入——真实链路是"先收紧、后拆分"，
            # 拆分出的碎片框拿去模拟收紧会被误判成"无墨迹归属"）
            boxes_pre_punct = list(boxes)
            boxes, punct_events = split_punct_merged_boxes(
                boxes, mask, iw, ih, req.orientation,
            )

            # ③ 与识别链路同源的字框来源决策 + 条带收紧模拟：像素切分走了
            # 网格/等分兜底时，真实识别会弃用这些合成槽位框、改用 Kraken
            # cuts 条带框（宽度恒为行宽），再逐格收紧到墨迹——『一』等
            # 横画字的识别框"比别的字宽一截"就出在这一步（墨迹矮被当噪
            # 点、整行宽条带原样保留）。这里把兜底框沿行宽展开成条带来
            # 模拟同一个收紧函数：黄框=收紧后的识别框模拟，逐格决策由
            # _tighten_boxes_to_ink 自己写进切分日志。
            method = str(diag.get("method") or "")
            sim_boxes: list[tuple[int, int, int, int]] | None = None
            sim_source = "none"
            if method.startswith("components"):
                segmenter._log(
                    f"[diag:box-src] 行#{i} method={method} → "
                    f"识别链路采用像素切分框（连通域紧致框，即蓝框）"
                )
                sim_source = "pixel-split"
            else:
                # 复跑真实链路（黄框保真）：真实识别的期望字数来自整行
                # 读法（n=len(kchars)）而非 app 传入的当前字数，条带也是
                # 真实 kraken cuts 而非兜底槽位。此前用"网格条带+app 期望"
                # 模拟，同一行可与线上结果结论相反（实测同一行模拟里會完
                # 整、线上會被切碎——app 期望 39 vs 整行读法 35 的分歧正
                # 是误导来源）。横排无整行读法，维持网格条带模拟。
                kchars: list[dict] = []
                probe_ok = req.orientation != "horizontal"
                if probe_ok:
                    try:
                        klines = kraken_bridge.recognize_lines(
                            req.image_path,
                            [{"x": x, "y": y, "w": w, "h": h}],
                            req.orientation,
                        )
                        kchars = [dict(c) for c in (klines[0].get("chars") or [])]
                    except Exception as exc:
                        probe_ok = False
                        segmenter._log(
                            f"[diag:box-src] 行#{i} kraken cuts 获取失败"
                            f"（回退网格条带模拟）：{exc}"
                        )
                if probe_ok:
                    # 读法为空（n_real=0）同样复跑：真实链路对空读法行合成
                    # 整行占位字符后按期望字数未知（n=0 纯连通域）切分
                    # （kraken_bridge.kraken_segment_line 的
                    # synthetic_placeholder），此处同源模拟；仅探测失败才
                    # 回退网格条带模拟。
                    n_real = len(kchars)
                    if n_real != expected:
                        segmenter._log(
                            f"[diag:box-src] 行#{i} 期望字数分歧：app 传入 "
                            f"{expected} vs 整行读法 {n_real}"
                            f"（识别链路取整行读法）"
                        )
                    diag2: dict = {}
                    boxes2 = _split_chars_in_region(
                        mask, rect, iw, ih, expected_count=n_real, diag=diag2,
                    )
                    method2 = str(diag2.get("method") or "")
                    if method2.startswith("components"):
                        segmenter._log(
                            f"[diag:box-src] 行#{i} 复跑(n={n_real}) "
                            f"method={method2} → 识别链路采用像素切分框"
                            f"（连通域紧致框）"
                        )
                        sim_boxes = boxes2
                        sim_source = "pixel-split"
                    elif kchars:
                        segmenter._log(
                            f"[diag:box-src] 行#{i} 复跑(n={n_real}) "
                            f"method={method2} → 识别链路弃用兜底槽位框、"
                            f"改用 kraken cuts 条带框（宽恒=行宽 {w}），"
                            f"黄框=真实 cuts 收紧并标点拆分后的识别框模拟"
                        )
                        strips = [
                            (x, int(c["y"]), w, int(c["h"])) for c in kchars
                        ]
                        sim_boxes = kraken_bridge._tighten_boxes_to_ink(
                            req.image_path, strips, req.orientation,
                        )
                        sim_boxes, _sim_punct_events = split_punct_merged_boxes(
                            sim_boxes, mask, iw, ih, req.orientation,
                        )
                        sim_source = "kraken-cuts"
                    else:
                        segmenter._log(
                            f"[diag:box-src] 行#{i} 复跑(n=0) "
                            f"method={method2} → 识别链路弃用兜底槽位框、"
                            f"整行读法为空无 cuts 可用，改用整行占位条带"
                            f"（宽恒=行宽 {w}），黄框=占位条带收紧后的"
                            f"识别框模拟"
                        )
                        sim_boxes = kraken_bridge._tighten_boxes_to_ink(
                            req.image_path, [(x, y, w, h)], req.orientation,
                        )
                        sim_boxes, _sim_punct_events = split_punct_merged_boxes(
                            sim_boxes, mask, iw, ih, req.orientation,
                        )
                        sim_source = "placeholder-strip"
                if sim_boxes is None:
                    segmenter._log(
                        f"[diag:box-src] 行#{i} method={method} → "
                        f"识别链路弃用兜底槽位框、改用 kraken cuts 条带框"
                        f"（宽恒=行宽 {w}），黄框=条带收紧后的识别框模拟"
                        f"（真实 cuts 不可用，以网格条带近似）"
                    )
                    strips = [(x, b[1], w, b[3]) for b in boxes_pre_punct]
                    try:
                        sim_boxes = kraken_bridge._tighten_boxes_to_ink(
                            req.image_path, strips, req.orientation,
                        )
                    except Exception as exc:
                        segmenter._log(
                            f"[diag:box-src] 行#{i} 条带收紧模拟失败：{exc}"
                        )
                    sim_source = "grid-strips"

            # ④ 宽框体检：字框比同行中位宽 30% 以上时量出框内墨迹并写明
            # 成因——直接回答"这个字的识别框为什么这么宽"。
            final_boxes = sim_boxes if sim_boxes is not None else boxes
            if len(final_boxes) >= 3:
                widths = sorted(b[2] for b in final_boxes)
                med_w = widths[len(widths) // 2]
                for j, b in enumerate(final_boxes):
                    if b[2] <= med_w * 1.3 or b[2] < 12:
                        continue
                    roi = mask[
                        max(0, b[1]):min(ih, b[1] + b[3]),
                        max(0, b[0]):min(iw, b[0] + b[2]),
                    ]
                    pts = cv2.findNonZero(roi) if roi.size else None
                    if pts is None:
                        ink_desc = "框内无墨迹"
                    else:
                        _, _, ink_w, ink_h = cv2.boundingRect(pts)
                        shape = (
                            "矮而宽（横画类字，如『一』）"
                            if ink_w >= ink_h * 2 else "接近方形"
                        )
                        ink_desc = f"框内墨迹 {ink_w}x{ink_h}，{shape}"
                    cause = (
                        "框≈整行宽：未收紧的 cuts 条带框"
                        "（该格无墨迹归属或被噪点判据跳过，原因见上方 [tighten] 行）"
                        if b[2] >= w * 0.9 and med_w < w * 0.85
                        else "墨迹本身偏宽或框含多列墨迹"
                    )
                    segmenter._log(
                        f"[diag:wide-box] 行#{i} 框#{j} rect={tuple(int(v) for v in b)} "
                        f"宽 {b[2]} vs 同行中位 {med_w}（行宽 {w}）："
                        f"{ink_desc}；{cause}"
                    )
            # 在原图裁剪区上画切分过程（外扩边距看全上下文）
            pad = max(24, min(w, h) // 2)
            cx1 = max(0, x - pad)
            cy1 = max(0, y - pad)
            cx2 = min(iw, x + w + pad)
            cy2 = min(ih, y + h + pad)
            view = img[cy1:cy2, cx1:cx2].copy()

            def draw_rect(
                r: tuple[int, int, int, int], color: tuple[int, int, int], t: int
            ) -> None:
                rx1, ry1 = int(r[0]) - cx1, int(r[1]) - cy1
                rx2, ry2 = rx1 + int(r[2]), ry1 + int(r[3])
                cv2.rectangle(view, (rx1, ry1), (rx2, ry2), color, t)

            for c in diag.get("components", []) or []:
                draw_rect(c, (0, 165, 255), 1)  # 橙：连通域块
            for d in diag.get("dropped", []) or []:
                draw_rect(d, (0, 0, 255), 1)  # 红：被丢弃的墨点
                draw_rect(d, (0, 0, 255), 3)
            for ev in punct_events or []:
                draw_rect(ev["old"], (255, 0, 255), 1)  # 紫：被拆分的同框框
            for j, b in enumerate(boxes):
                draw_rect(b, (255, 0, 0), 2)  # 蓝：最终字框
                bx = int(b[0]) - cx1
                by = int(b[1]) - cy1
                cv2.putText(
                    view, str(j), (bx + 2, by - 4),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 0, 0), 1, cv2.LINE_AA,
                )
            for j, b in enumerate(sim_boxes or []):
                draw_rect(b, (0, 215, 255), 1)  # 黄：识别框模拟（条带收紧后）
                sx = int(b[0]) - cx1
                cv2.putText(
                    view, str(j), (sx + 2, int(b[1]) - cy1 + int(b[3]) - 4),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 215, 255), 1, cv2.LINE_AA,
                )
            cv2.rectangle(
                view, (x - cx1, y - cy1), (x - cx1 + w, y - cy1 + h), (0, 180, 0), 2
            )
            if rect_expanded:
                ox, oy, ow, oh = rect_in
                cv2.rectangle(
                    view, (ox - cx1, oy - cy1), (ox - cx1 + ow, oy - cy1 + oh),
                    (0, 180, 0), 1,
                )
            cv2.putText(
                view,
                f"{diag.get('method', '?')} comp={len(diag.get('components', []) or [])}"
                f" drop={len(diag.get('dropped', []) or [])}"
                f" stuck={diag.get('stuck_fallback', 0)} exp={expected}"
                f" got={len(boxes)}"
                f" expand={'Y' if rect_expanded else 'N'}"
                f" punct_split={len(punct_events)}"
                f" sim={'Y' if sim_boxes else 'N'}({sim_source})",
                (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 200), 1, cv2.LINE_AA,
            )
            out_path = f"{base}_dbg_line{i}_{stamp}.png"
            imwrite_unicode(out_path, view)
            results.append({
                "rect": {"x": x, "y": y, "w": w, "h": h},
                "original_rect": {
                    "x": rect_in[0], "y": rect_in[1], "w": rect_in[2], "h": rect_in[3],
                },
                "rect_expanded": rect_expanded,
                "punct_split_count": len(punct_events),
                "tighten_sim_count": len(sim_boxes) if sim_boxes else 0,
                "sim_source": sim_source,
                "image": out_path,
                "method": diag.get("method"),
                "expected_count": expected,
                "component_count": len(diag.get("components", []) or []),
                "dropped_count": len(diag.get("dropped", []) or []),
                "stuck_fallback": diag.get("stuck_fallback", 0),
                "boxes": [
                    {"x": int(b[0]), "y": int(b[1]), "w": int(b[2]), "h": int(b[3])}
                    for b in boxes
                ],
            })
        trace = debug_trace_snapshot()
        trace_path = f"{base}_dbg_trace_{stamp}.txt"
        try:
            with open(trace_path, "w", encoding="utf-8") as trace_file:
                trace_file.write("\n".join(trace) + "\n")
        except OSError as exc:
            print(f"[debug_char_split] trace write failed: {exc}", flush=True)
            trace_path = ""
        return {
            "mask_image": mask_path,
            "mask_polarity": polarity,
            "lines": results,
            "trace": trace,
            "trace_file": trace_path,
        }
    except HTTPException:
        raise
    except Exception as e:
        print(f"[debug_char_split] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))
