# -*- coding: utf-8 -*-
"""识别与批处理域路由（从 main.py 拆出）：候选字、字符识别、聚类、缩略图、行墨迹、版面分析、消融评测。"""
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
import segmenter
import char_cluster
import char_verify
import smart_merge
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
from api_base import Block, app, _gated_recognition





class CharCandidatesRequest(BaseModel):
    image_path: str
    x: int
    y: int
    w: int
    h: int
    top_k: int = 10




class RecognizeCharRequest(BaseModel):
    image_path: str
    x: int
    y: int
    w: int
    h: int
    orientation: str = "vertical"
    horizontal_dir: str = "ltr"
    top_k: int = 10
    engine: str = "kraken"
    paddle_model: Optional[str] = None




class CharCandidatesBatchRequest(BaseModel):
    image_path: str
    blocks: List[Block]
    top_k: int = 10




@app.post("/char_candidates")
def char_candidates(req: CharCandidatesRequest):
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    try:
        begin_debug_trace()
        candidates = get_char_candidates(
            req.image_path,
            (req.x, req.y, req.w, req.h),
            top_k=max(1, min(10, req.top_k)),
        )
        return {"candidates": candidates, "debug_trace": debug_trace_snapshot()}
    except Exception as e:
        print(f"[char_candidates] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




@app.post("/recognize_char")
@_gated_recognition("recognize_char")
def recognize_char(req: RecognizeCharRequest):
    """单字框识别（编辑器画新框/调整框后调用）。

    正文取所选引擎（kraken 默认 / paddle 可选）框内识别的首字，自训
    char_cls 分类器的 top-K 追加为候选；两路合并去重后一起返回，编辑器
    直接落文字并挂候选。
    """
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    try:
        begin_debug_trace()
        if req.engine == "paddle":
            import paddle_bridge

            kraken = paddle_bridge.paddle_recognize_char(
                req.image_path,
                (req.x, req.y, req.w, req.h),
                req.orientation,
                req.horizontal_dir,
                model=req.paddle_model,
            )
        else:
            kraken = kraken_bridge.recognize_char(
                req.image_path,
                (req.x, req.y, req.w, req.h),
                req.orientation,
                req.horizontal_dir,
            )
        candidates = get_char_candidates(
            req.image_path,
            (req.x, req.y, req.w, req.h),
            top_k=max(1, min(10, req.top_k)),
        )
        text = (kraken.get("text") or "").strip()
        conf = float(kraken.get("conf") or 0.0)
        merged: list[dict] = []
        seen: set[str] = set()
        if text:
            first = text[:1]
            merged.append({"text": first, "score": round(conf, 4)})
            seen.add(first)
        for item in candidates:
            char = (item.get("text") or "").strip()
            if len(char) == 1 and char not in seen:
                merged.append(item)
                seen.add(char)
        print(
            f"[recognize_char] rect=({req.x},{req.y},{req.w},{req.h}) "
            f"text={text[:1]!r} candidates={len(merged)}",
            flush=True,
        )
        return {
            "text": text[:1] if text else "",
            "conf": conf,
            "candidates": merged,
            "debug_trace": debug_trace_snapshot(),
        }
    except HTTPException:
        raise
    except Exception as e:
        print(f"[recognize_char] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




@app.post("/char_candidates_batch")
def char_candidates_batch(req: CharCandidatesBatchRequest):
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    image = _imread(req.image_path)
    if image is None:
        raise HTTPException(status_code=400, detail="cannot read image")
    top_k = max(1, min(10, req.top_k))
    result: dict[str, list[dict]] = {}
    errors: dict[str, str] = {}
    begin_debug_trace()
    for block in req.blocks:
        try:
            result[block.id] = get_char_candidates(
                req.image_path,
                (block.x, block.y, block.w, block.h),
                top_k=top_k,
                image=image,
            )
        except Exception as exc:
            errors[block.id] = f"{type(exc).__name__}: {exc}"
            result[block.id] = []
    return {
        "candidates": result,
        "errors": errors,
        "debug_trace": debug_trace_snapshot(),
    }




class CharClustersRequest(BaseModel):
    image_path: str
    blocks: List[Block]
    threshold: float = char_cluster.DEFAULT_THRESHOLD
    min_cluster_size: int = 2




@app.post("/char_clusters")
def char_clusters(req: CharClustersRequest):
    """单字墨迹聚类（编辑器「墨迹归类」页）：按笔画形态把本页字块分组。

    只依赖整页二值化墨迹 mask（与识别文字无关），前端按组统一/单独
    校正文字。纯 CPU（numpy/scipy），不走 GPU 识别门，不与识别抢资源。
    """
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    try:
        result = char_cluster.cluster_chars(
            req.image_path,
            req.blocks,
            threshold=req.threshold,
            min_cluster_size=req.min_cluster_size,
        )
        print(
            f"[char_clusters] blocks={len(req.blocks)} "
            f"clusters={len(result['clusters'])} threshold={req.threshold} "
            f"elapsed={result['elapsed_ms']:.0f}ms",
            flush=True,
        )
        return result
    except HTTPException:
        raise
    except Exception as e:
        print(f"[char_clusters] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




class CharClustersPage(BaseModel):
    image_path: str
    blocks: List[Block]




class CharClustersBatchRequest(BaseModel):
    pages: List[CharClustersPage]
    threshold: float = char_cluster.DEFAULT_THRESHOLD
    min_cluster_size: int = 2




@app.post("/char_clusters_batch")
def char_clusters_batch(req: CharClustersBatchRequest):
    """全书墨迹归类（「墨迹归类·全书版」页）：多页字块按墨迹形态聚类。

    逐页提特征 + 页内 complete-linkage 聚类，组原型跨页贪心并入全局组
    （见 char_cluster.cluster_chars_batch）。块 id 需由前端保证全局唯一
    （带页前缀）。整批同步执行，大书耗时可达分钟级；单页失败只记入
    failed_pages，不中断整批。纯 CPU，不与识别抢 GPU。
    """
    if not req.pages:
        raise HTTPException(status_code=400, detail="no pages")
    for page in req.pages:
        if not os.path.exists(page.image_path):
            raise HTTPException(status_code=400, detail="image not found")
    try:
        result = char_cluster.cluster_chars_batch(
            req.pages,
            threshold=req.threshold,
            min_cluster_size=req.min_cluster_size,
        )
        print(
            f"[char_clusters_batch] pages={len(req.pages)} chars={result['chars']} "
            f"clusters={len(result['clusters'])} threshold={req.threshold} "
            f"failed={len(result['failed_pages'])} "
            f"elapsed={result['elapsed_ms']:.0f}ms",
            flush=True,
        )
        return result
    except HTTPException:
        raise
    except Exception as e:
        print(f"[char_clusters_batch] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




class SmartMergeBox(BaseModel):
    x: int
    y: int
    w: int
    h: int


class SmartMergeBlock(BaseModel):
    id: str
    x: int
    y: int
    w: int
    h: int
    confirmed: bool = False
    box_confirmed: bool = False


class SmartMergeLine(BaseModel):
    # 行内阅读方向：ttb（竖排上→下，默认）/ btt / ltr / rtl；行按此
    # 方向的阅读序给 blocks，模板与候选的配对方向须一致才可比。
    dir: str = "ttb"
    blocks: List[SmartMergeBlock]


class SmartMergePage(BaseModel):
    page_id: str
    image_path: str
    lines: List[SmartMergeLine]


class SmartMergeScanRequest(BaseModel):
    template_image_path: str
    # 合并前的两个模板框（顺序不限，内部按 template_dir 归位阅读序）。
    template_boxes: List[SmartMergeBox]
    template_dir: str = "ttb"
    threshold: float = smart_merge.DEFAULT_THRESHOLD
    pages: List[SmartMergePage]


@app.post("/smart_merge_scan")
def smart_merge_scan(req: SmartMergeScanRequest):
    """智能合并扫描：以一次手工合并的两框为模板，在多页的同行相邻
    字框对中找同类墨迹（几何构型 + HOG 特征双门槛，见 smart_merge.py）。

    已确认（confirmed / box_confirmed）的框恒不参与；返回按 score 升
    序、同页互斥的匹配对，由前端按与手工合并相同口径批量合并。纯
    CPU，不与识别抢 GPU 门。
    """
    if len(req.template_boxes) != 2:
        raise HTTPException(status_code=400, detail="template_boxes must have 2 boxes")
    if not req.pages:
        raise HTTPException(status_code=400, detail="no pages")
    if not os.path.exists(req.template_image_path):
        raise HTTPException(status_code=400, detail="template image not found")
    for page in req.pages:
        if not os.path.exists(page.image_path):
            raise HTTPException(status_code=400, detail="image not found")
    try:
        result = smart_merge.scan_smart_merge(
            req.template_image_path,
            [(b.x, b.y, b.w, b.h) for b in req.template_boxes],
            req.template_dir,
            req.pages,
            threshold=req.threshold,
        )
        print(
            f"[smart_merge_scan] pages={len(req.pages)} "
            f"matches={len(result['matches'])} threshold={req.threshold} "
            f"failed={len(result['failed_pages'])} "
            f"elapsed={result['elapsed_ms']:.0f}ms",
            flush=True,
        )
        return result
    except HTTPException:
        raise
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        print(f"[smart_merge_scan] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




class SmartSplitScanRequest(BaseModel):
    template_image_path: str
    # 手工 Alt 拆分前的原框（一个框里挤了两个字的那只框）。
    template_box: SmartMergeBox
    threshold: float = smart_merge.DEFAULT_THRESHOLD
    pages: List[SmartMergePage]


@app.post("/smart_split_scan")
def smart_split_scan(req: SmartSplitScanRequest):
    """智能分割扫描：以一次手工 Alt 拆分前的原框为模板，在多页字框中
    找同类墨迹的单框（HOG 含宽高比惩罚，见 smart_merge.scan_smart_split）。

    与 /smart_merge_scan 同一套 pages 结构；已确认的框恒不参与。命中
    由前端按"同比例沿阅读轴一分为二"批量拆分（与手工拆分同口径）。
    纯 CPU，不与识别抢 GPU 门。
    """
    if not req.pages:
        raise HTTPException(status_code=400, detail="no pages")
    if not os.path.exists(req.template_image_path):
        raise HTTPException(status_code=400, detail="template image not found")
    for page in req.pages:
        if not os.path.exists(page.image_path):
            raise HTTPException(status_code=400, detail="image not found")
    try:
        result = smart_merge.scan_smart_split(
            req.template_image_path,
            (req.template_box.x, req.template_box.y, req.template_box.w, req.template_box.h),
            req.pages,
            threshold=req.threshold,
        )
        print(
            f"[smart_split_scan] pages={len(req.pages)} "
            f"matches={len(result['matches'])} threshold={req.threshold} "
            f"failed={len(result['failed_pages'])} "
            f"elapsed={result['elapsed_ms']:.0f}ms",
            flush=True,
        )
        return result
    except HTTPException:
        raise
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        print(f"[smart_split_scan] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




class CharThumbItem(BaseModel):
    image_path: str
    x: int
    y: int
    w: int
    h: int




class CharThumbnailsRequest(BaseModel):
    items: List[CharThumbItem]
    size: int = 96  # 输出边长（px）




# 缩略图解码缓存：全书归类页按组拉取缩略图，同页的请求往往连续到达，
# 缓存几张解码图避免重复 imread（对齐 _TEXT_MASK_CACHE 的简汰策略）。
_THUMB_IMG_CACHE: dict[str, "np.ndarray | None"] = {}




@app.post("/char_thumbnails")
def char_thumbnails(req: CharThumbnailsRequest):
    """批量字块缩略图（全书墨迹归类页）：按字框裁切 + 白底 letterbox
    正方形 + 缩放到 size，返回 base64 PNG 列表（与 items 顺序对齐）。

    裁切失败的项返回 None（前端显示占位灰块），不中断整批。
    """
    if not req.items:
        return {"thumbs": []}
    if len(req.items) > 2000:
        raise HTTPException(status_code=400, detail="too many items (max 2000)")

    size = max(32, min(256, int(req.size)))
    thumbs: list[str | None] = []
    last_path = None
    img = None
    for item in req.items:
        if item.image_path != last_path:
            last_path = item.image_path
            if len(_THUMB_IMG_CACHE) > 4:
                _THUMB_IMG_CACHE.clear()
            img = _THUMB_IMG_CACHE.get(last_path)
            if last_path not in _THUMB_IMG_CACHE:
                try:
                    img = _imread(last_path)
                except OSError:
                    img = None
                # 读取失败（None）也缓存，避免同一坏文件反复 imread
                _THUMB_IMG_CACHE[last_path] = img
        thumb = None
        if img is not None:
            h, w = img.shape[:2]
            x1, y1 = max(0, item.x), max(0, item.y)
            x2, y2 = min(w, item.x + item.w), min(h, item.y + item.h)
            if x2 - x1 >= 2 and y2 - y1 >= 2:
                crop = img[y1:y2, x1:x2]
                side = max(crop.shape[0], crop.shape[1])
                square = np.full((side, side), 255, dtype=np.uint8)
                if crop.ndim == 3:
                    square = np.full((side, side, 3), 255, dtype=np.uint8)
                oy = (side - crop.shape[0]) // 2
                ox = (side - crop.shape[1]) // 2
                square[oy : oy + crop.shape[0], ox : ox + crop.shape[1]] = crop
                thumb_img = cv2.resize(
                    square, (size, size), interpolation=cv2.INTER_AREA
                )
                ok, buf = cv2.imencode(".png", thumb_img)
                if ok:
                    thumb = base64.b64encode(buf).decode("ascii")
        thumbs.append(thumb)
    return {"thumbs": thumbs}




class LineThumbBox(BaseModel):
    x: int
    y: int
    w: int
    h: int




class _LineThumbItemFull(BaseModel):
    image_path: str
    x: int
    y: int
    w: int
    h: int
    orientation: str = "vertical"
    # 可选：在裁图上叠加当前字框（2px 橙框 + 序号），AI 框检查据此直
    # 观看到框与字形的偏差；不提供时输出纯裁图
    boxes: Optional[List[LineThumbBox]] = None




class LineThumbnailsWithBoxesRequest(BaseModel):
    items: List[_LineThumbItemFull]
    max_side: int = 640  # 长边缩放上限（px，服务端钳制 128~2048）
    pad_ratio: float = 0.15  # 行框四周上下文外扩比例（相对长边）




@app.post("/line_thumbnails")
def line_thumbnails(req: LineThumbnailsWithBoxesRequest):
    """批量行条裁图（AI 框检查的诊断素材）：按行框裁切 + 四周上下文外扩
    （钳回图内）+ **保持纵横比** + 长边缩放到 max_side，可选叠加当前字框
    （框内 25% 半透明橙色高亮 + 橙色描边 + 框外 1 基序号白块，竖排行
    序号在框左侧、横排在框上方；任何字框尺寸都不实心遮字），返回
    base64 PNG 列表（与 items 顺序对齐）。

    与 /char_thumbnails 的正方形 letterbox 不同：竖排整行（长宽比可达
    1:20）压进正方形会把字压成不可读细条，这里保持原比例。裁切失败的
    项返回 None（前端跳过该行的 AI 诊断），不中断整批。
    """
    if not req.items:
        return {"thumbs": []}
    if len(req.items) > 200:
        raise HTTPException(status_code=400, detail="too many items (max 200)")
    # 上限 2048：竖排长行纵横比悬殊（一列 20~40 字），长边 768 时单字
    # 只剩 30~40px、明显低于书页原图的观感——AI 辅助识别行条图按 1536
    # 请求，给单字留 ~76px 以上；2048 是防超大图的绝对上限。
    max_side = max(128, min(2048, int(req.max_side)))
    pad_ratio = max(0.0, min(0.5, float(req.pad_ratio)))
    thumbs: list[str | None] = []
    last_path = None
    img = None
    for item in req.items:
        if item.image_path != last_path:
            last_path = item.image_path
            if len(_THUMB_IMG_CACHE) > 4:
                _THUMB_IMG_CACHE.clear()
            img = _THUMB_IMG_CACHE.get(last_path)
            if last_path not in _THUMB_IMG_CACHE:
                try:
                    img = _imread(last_path)
                except OSError:
                    img = None
                _THUMB_IMG_CACHE[last_path] = img
        thumb = None
        if img is not None:
            h, w = img.shape[:2]
            # 上下文外扩（相对行框长边），让 VLM 看到邻列/邻行的分界。
            long_side = max(item.w, item.h)
            pad = int(long_side * pad_ratio) if pad_ratio > 0 else 0
            x1, y1 = max(0, item.x - pad), max(0, item.y - pad)
            x2, y2 = min(w, item.x + item.w + pad), min(h, item.y + item.h + pad)
            if x2 - x1 >= 4 and y2 - y1 >= 4:
                crop = img[y1:y2, x1:x2].copy()
                if item.boxes:
                    ch = crop.shape[0]
                    cw = crop.shape[1]
                    # 标注三原则：① 框内 25% 半透明橙色高亮——无论字框多
                    # 小（标点小框、异常窄框）都透得出字形，绝不实心盖字；
                    # ② 橙色描边 2px（先在原图尺度画完再缩，缩后仍清晰）；
                    # ③ 序号白块放框外（竖排行=框左侧、横排行=框上方），
                    # 贴裁图边缘放不下时才退回框内左上角。
                    vertical = ch > cw
                    for bi, b in enumerate(item.boxes):
                        bx1, by1 = max(0, b.x - x1), max(0, b.y - y1)
                        bx2 = min(cw, b.x + b.w - x1)
                        by2 = min(ch, b.y + b.h - y1)
                        if bx2 - bx1 <= 0 or by2 - by1 <= 0:
                            continue
                        inner = crop[by1:by2, bx1:bx2]
                        if inner.size:
                            tint = inner.copy()
                            tint[:] = (66, 133, 244)
                            cv2.addWeighted(tint, 0.25, inner, 0.75, 0, inner)
                        cv2.rectangle(crop, (bx1, by1), (bx2, by2), (66, 133, 244), 2)
                        tx, ty = bx1, by1
                        if vertical and bx1 - 16 >= 0:
                            tx = bx1 - 16
                        elif not vertical and by1 - 16 >= 0:
                            ty = by1 - 16
                        cv2.rectangle(
                            crop, (tx, ty), (tx + 14, ty + 14), (255, 255, 255), -1
                        )
                        cv2.putText(
                            crop,
                            str(bi + 1),
                            (tx + 2, ty + 11),
                            cv2.FONT_HERSHEY_SIMPLEX,
                            0.42,
                            (200, 60, 0),
                            1,
                            cv2.LINE_AA,
                        )
                scale = min(1.0, max_side / max(crop.shape[0], crop.shape[1]))
                if scale < 1.0:
                    crop = cv2.resize(
                        crop,
                        (max(1, int(crop.shape[1] * scale)), max(1, int(crop.shape[0] * scale))),
                        interpolation=cv2.INTER_AREA,
                    )
                ok, buf = cv2.imencode(".png", crop)
                if ok:
                    thumb = base64.b64encode(buf).decode("ascii")
        thumbs.append(thumb)
    return {"thumbs": thumbs}




class LineInkBox(BaseModel):
    x: int
    y: int
    w: int
    h: int




class LineInkItem(BaseModel):
    image_path: str
    x: int
    y: int
    w: int
    h: int
    # 可选：按字框测墨迹（更准——字框核心区避开邻列渗入的边缘笔画）。
    # 缺省时按行框核心区测整行。
    chars: Optional[List[LineInkBox]] = None




class LineInkRequest(BaseModel):
    items: List[LineInkItem]




class LayoutAnalyzeLine(BaseModel):
    id: str = ""
    x: int
    y: int
    w: int
    h: int
    chars: list[dict] = []




class LayoutAnalyzeRequest(BaseModel):
    image_path: str
    orientation: str = "vertical"
    horizontal_dir: str = "ltr"
    vertical_dir: str = "ttb"
    lines: List[LayoutAnalyzeLine] = []




@app.post("/analyze_layout")
def analyze_layout(req: LayoutAnalyzeRequest):
    """CPU-only layout repair proposals for editor/AI box review.

    The endpoint never mutates the page. It uses the same ruling-line-removed
    mask as segmentation, so long blank bands and one-to-three pixel clipped
    edges are diagnosed with the exact geometry later used by recognition.
    """
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    if len(req.lines) > 1000:
        raise HTTPException(status_code=400, detail="too many lines (max 1000)")
    img = _imread(req.image_path)
    mask = _text_mask_for_refinement(req.image_path)
    if img is None or mask is None:
        raise HTTPException(status_code=400, detail="cannot build text mask")
    ih, iw = mask.shape[:2]
    raw = [{"id": l.id, "x": l.x, "y": l.y, "w": l.w, "h": l.h,
            "chars": list(l.chars or [])}
           for l in req.lines]
    refined = normalize_layout(
        raw, mask, req.orientation, req.horizontal_dir, req.vertical_dir
    )
    # The normalizer is deliberately the single geometry authority. Keep the
    # old shape compatible while exposing complete child lines on repairs.
    return refined





def _structural_ink(crop: "np.ndarray") -> float:
    """结构性笔画墨迹占比：Otsu 二值化后剔除界格长线与噪点，只留笔画。

    直接用暗像素占比无法区分"空白列间带"与"真文字列"——界格线 + 纸底
    噪声会让空白带达到 0.07~0.14，与真列（0.11~0.17）重叠。按连通域
    结构过滤（纵向/横向长线、小噪点）后，真列 ≈0.10+，界格带 ≈0。
    """
    if crop is None or crop.size == 0:
        return 0.0
    gray = crop if crop.ndim == 2 else cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    blur = cv2.GaussianBlur(gray, (3, 3), 0)
    thresh, bw = cv2.threshold(
        blur, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU
    )
    if thresh == 0:
        # 纯色图 Otsu 退化返回 0（THRESH_BINARY_INV 下全黑核心会被测成
        # 零墨迹）；退回固定阈值。实心墨字/印章应记为满墨。
        thresh, bw = cv2.threshold(blur, 128, 255, cv2.THRESH_BINARY_INV)
    n, _labels, stats, _ = cv2.connectedComponentsWithStats(bw, 8)
    ch, cw = gray.shape[:2]
    total = float(ch * cw)
    keep = 0.0
    for k in range(1, n):
        x, y, w, h, area = stats[k]
        if area < 40:  # 噪点
            continue
        # 界格/版框线按"绝对细"判定（≤10px）：相对细度在高瘦的行级裁剪
        # 里会把扁平的文字块误判成横线。
        if h >= ch * 0.7 and w <= 10:  # 纵向界格/长线
            continue
        if w >= cw * 0.7 and h <= 10:  # 横向框线
            continue
        keep += float(area)
    return keep / total




def _core_ink(img: "np.ndarray", x: int, y: int, w: int, h: int) -> float:
    """框核心区（内缩 15%）的结构性墨迹：避开框边缘蹭到的邻列笔画。"""
    ih, iw = img.shape[:2]
    cx = int(x + w * 0.15)
    cy = int(y + h * 0.15)
    cw = max(1, int(w * 0.7))
    ch = max(1, int(h * 0.7))
    x1, y1 = max(0, cx), max(0, cy)
    x2, y2 = min(iw, cx + cw), min(ih, cy + ch)
    if x2 - x1 < 2 or y2 - y1 < 2:
        return 0.0
    return _structural_ink(img[y1:y2, x1:x2])




@app.post("/line_ink")
def line_ink(req: LineInkRequest):
    """批量行墨迹测量（AI 框检查的判空依据）：逐字框核心区结构性墨迹
    占比的中位数 + 空字数（核心墨迹 < 0.05 的字框数）。实测校准：真文
    字行中位 ≈0.23~0.47，落在列间空白带的幽灵行中位 ≈0。

    前端据此判定"空框"（框内无文字墨迹）并直接删除，不再依赖视觉模
    型的肉眼判断。坏项返回 ok=false，不中断整批。
    """
    if not req.items:
        return {"results": []}
    if len(req.items) > 500:
        raise HTTPException(status_code=400, detail="too many items (max 500)")

    results: list[dict] = []
    last_path = None
    img = None
    for item in req.items:
        if item.image_path != last_path:
            last_path = item.image_path
            if len(_THUMB_IMG_CACHE) > 4:
                _THUMB_IMG_CACHE.clear()
            img = _THUMB_IMG_CACHE.get(last_path)
            if last_path not in _THUMB_IMG_CACHE:
                try:
                    img = _imread(last_path)
                except OSError:
                    img = None
                _THUMB_IMG_CACHE[last_path] = img
        if img is None:
            results.append({"ok": False})
            continue
        boxes = item.chars or [LineInkBox(x=item.x, y=item.y, w=item.w, h=item.h)]
        inks = sorted(_core_ink(img, b.x, b.y, b.w, b.h) for b in boxes)
        median = inks[len(inks) // 2] if inks else 0.0
        results.append(
            {
                "ok": True,
                "char_ink_median": round(float(median), 4),
                "blank_chars": sum(1 for v in inks if v < 0.05),
                "char_count": len(inks),
            }
        )
    return {"results": results}




class RegionInkRequest(BaseModel):
    image_path: str
    # 参考页映射来的版面区框（页眉/页脚/页码等），整批同页一次判定。
    rects: List[LineInkBox] = []



@app.post("/region_ink")
def region_ink(req: RegionInkRequest):
    """页面矩形批量墨迹检测（主区快设「按参考页适配」的判空依据）：
    给定页面图与矩形列表，逐框返回核心区结构性墨迹占比——同一本书版式
    一致但个别页没有页眉/页脚/页码时，空框墨迹 ≈0（界格线与噪点已被
    连通域结构过滤），前端据此跳过不落框。坏图整批 ok=false，前端保守
    保留框不删。
    """
    if not req.rects:
        return {"results": []}
    if len(req.rects) > 64:
        raise HTTPException(status_code=400, detail="too many rects (max 64)")
    if len(_THUMB_IMG_CACHE) > 4:
        _THUMB_IMG_CACHE.clear()
    img = _THUMB_IMG_CACHE.get(req.image_path)
    if req.image_path not in _THUMB_IMG_CACHE:
        try:
            img = _imread(req.image_path)
        except OSError:
            img = None
        _THUMB_IMG_CACHE[req.image_path] = img
    if img is None:
        return {"results": [{"ok": False} for _ in req.rects]}
    return {
        "results": [
            {"ok": True, "ink": round(_core_ink(img, r.x, r.y, r.w, r.h), 4)}
            for r in req.rects
        ]
    }




class RecognitionEvalRequest(BaseModel):
    project_dir: str  # 单本书或书库根（与训练入口同语义）
    limit: int = 100  # 评测集最多取多少确认行
    rebuild: bool = False  # True=重新抽样冻结评测集（否则复用已冻结的）




@app.post("/recognition_eval")
@_gated_recognition("recognition_eval")
def recognition_eval(req: RecognitionEvalRequest):
    """识别消融评测：冻结评测集上跑 A/B/C 三档（裸模型整行 / 切分+逐框 /
    全链路），量出识别准确率里模型与链路代码各自的贡献。"""
    import recog_eval

    try:
        eval_set = recog_eval.load_eval_set()
        if req.rebuild or eval_set is None:
            eval_set = recog_eval.build_eval_set(req.project_dir, limit=req.limit)
        return recog_eval.run_ablation(eval_set)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




@app.get("/recognition_eval/set")
def recognition_eval_set():
    """识别消融评测：当前冻结评测集与上次运行的摘要。"""
    import recog_eval

    data = recog_eval.load_eval_set()
    return {
        "eval_set": recog_eval.eval_set_summary(data) if data else None,
        "last_run": recog_eval.last_run_summary(),
    }
