# -*- coding: utf-8 -*-
"""导出域路由（从 main.py 拆出）：/export_excalidraw /export_crnn /pack_lmdb。"""
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
from api_base import (_acquire_recognition_slot, app, _gated_recognition, _release_recognition_slot)





class ExcalidrawExportRequest(BaseModel):
    image_path: str
    x: int = 0
    y: int = 0
    w: int = 0  # 0/缺省 = 整页
    h: int = 0
    orientation: str = "vertical"
    horizontal_dir: str = "ltr"
    vertical_dir: str = "ttb"
    layout_mode: str = "all_text"
    # 编辑器已校对的行/字数据（注入则不重跑识别、不占 GPU 门）
    ocr_lines: Optional[List[dict]] = None
    # 工作台手画的文字识别框 {x,y,w,h}（全图坐标）：框内无既有字时单独识别
    text_boxes: Optional[List[dict]] = None
    # 附带管线过程图（stats["debug_images"]，四阶段叠加图）
    debug_images: bool = False
    # ── 导出设置（Excalidraw 工作台，默认值与 excalidraw_export 一致）──
    detect_rects: bool = True
    detect_ellipses: bool = True
    detect_lines: bool = True
    detect_curves: bool = True
    detect_arrows: bool = True
    min_shape_size: int = 10
    line_min_len: int = 24
    curve_simplify: float = 2.0
    snap_tolerance: int = 8
    merge_double_lines: bool = True
    min_char_conf: float = 0.0
    scale: float = 1.0  # 画布缩放（1 = 原图像素 1:1）
    roughness: int = 0  # 0=architect 简洁 / 1=sketch 手绘 / 2=粗糙
    stroke_width: int = 0  # 0=按实测笔画厚度
    color_mode: str = "original"  # original | mono | custom
    custom_color: Optional[str] = None
    font_family: int = 3  # 3=Normal / 1=Virgil 手写
    embed_image: bool = False  # 嵌入扫描底图（锁定底层）
    embed_opacity: int = 100
    group_elements: bool = True




@app.post("/export_excalidraw")
def export_excalidraw(req: ExcalidrawExportRequest):
    """区域（w/h=0 为整页）→ Excalidraw 场景 JSON：图形检测 + 文字。

    注入 ocr_lines（编辑器校对数据）时不跑识别 → 不占 GPU 门，工作台
    预览迭代即时；未注入才走区域重识别（串行门 + LRU 缓存）。手画文字
    框（text_boxes）可能触发按框识别，保守占门。"""
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    needs_recognition = req.ocr_lines is None or bool(req.text_boxes)
    if needs_recognition:
        # 手动占识别槽（占不到抛 409）；注入 ocr_lines 的纯预览不占。
        _acquire_recognition_slot("export_excalidraw")
    started = time.time()
    try:
        begin_debug_trace()
        import excalidraw_export

        settings = req.model_dump(exclude={
            "image_path", "x", "y", "w", "h",
            "orientation", "horizontal_dir", "vertical_dir", "layout_mode",
            "ocr_lines", "text_boxes", "debug_images",
        })
        scene, stats = excalidraw_export.region_to_excalidraw(
            req.image_path,
            (req.x, req.y, req.w, req.h),
            orientation=req.orientation,
            horizontal_dir=req.horizontal_dir,
            vertical_dir=req.vertical_dir,
            layout_mode=req.layout_mode,
            settings=settings,
            ocr_lines=req.ocr_lines,
            text_boxes=req.text_boxes,
            debug_images=req.debug_images,
        )
        return {
            "scene": scene,
            "stats": stats,
            "debug_trace": debug_trace_snapshot(),
        }
    except Exception as e:
        print(f"[export_excalidraw] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if needs_recognition:
            _release_recognition_slot()
            print(f"[export_excalidraw] finished in {time.time() - started:.1f}s", flush=True)




class CrnnLineItem(BaseModel):
    line_id: str
    x: int
    y: int
    w: int
    h: int
    orientation: str = "vertical"
    text: str = ""




class ExportCrnnRequest(BaseModel):
    image_path: str
    lines: List[CrnnLineItem]
    output_dir: str
    target_height: int = 32
    padding_color: int = 255




class PackLmdbRequest(BaseModel):
    crnn_output_dir: str
    lmdb_path: str
    map_size: int = 1073741824




@app.post("/export_crnn")
def export_crnn(req: ExportCrnnRequest):
    print(
        f"[export_crnn] path={req.image_path!r} lines={len(req.lines)} "
        f"output_dir={req.output_dir!r} target_height={req.target_height}",
        flush=True,
    )
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    img = _imread(req.image_path)
    if img is None:
        raise HTTPException(status_code=400, detail="cannot read image")

    out_dir = Path(req.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    img_h, img_w = img.shape[:2]
    th = req.target_height
    pad_color = (req.padding_color, req.padding_color, req.padding_color)

    results = []
    labels_lines = []

    for ln in req.lines:
        x0 = max(0, ln.x)
        y0 = max(0, ln.y)
        x1 = min(img_w, ln.x + ln.w)
        y1 = min(img_h, ln.y + ln.h)
        if x1 <= x0 or y1 <= y0:
            print(f"[export_crnn] skip {ln.line_id}: invalid rect", flush=True)
            continue

        crop = img[y0:y1, x0:x1]
        if crop.size == 0:
            continue

        # 竖排行图逆时针旋转 90 度，变成横排供 CRNN 使用
        if ln.orientation == "vertical":
            crop = cv2.rotate(crop, cv2.ROTATE_90_COUNTERCLOCKWISE)

        crop_h, crop_w = crop.shape[:2]
        if crop_h <= 0:
            continue

        scale = th / float(crop_h)
        new_w = max(1, int(round(crop_w * scale)))
        resized = cv2.resize(
            crop,
            (new_w, th),
            interpolation=cv2.INTER_AREA if scale < 1.0 else cv2.INTER_LINEAR,
        )

        # 不足 target_height 时上下对称填充（理论上 resize 后高度已等于 target_height，
        # 这里保留 padding 分支用于 target_height 与 resized 尺寸不一致的情况）
        rh, rw = resized.shape[:2]
        if rh < th:
            top = (th - rh) // 2
            bottom = th - rh - top
            resized = cv2.copyMakeBorder(
                resized, top, bottom, 0, 0,
                cv2.BORDER_CONSTANT, value=pad_color,
            )
        elif rh > th:
            resized = resized[:th]

        filename = f"{ln.line_id}.jpg"
        out_path = str(out_dir / filename)
        if not imwrite_unicode(out_path, resized, ext=".jpg",
                               params=[int(cv2.IMWRITE_JPEG_QUALITY), 95]):
            print(f"[export_crnn] encode failed: {ln.line_id}", flush=True)
            continue

        results.append({"line_id": ln.line_id, "file": filename})
        labels_lines.append(f"{filename}\t{ln.text}")

    labels_path = str(out_dir / "labels.txt")
    with open(labels_path, "w", encoding="utf-8") as f:
        f.write("\n".join(labels_lines))
        if labels_lines:
            f.write("\n")

    print(
        f"[export_crnn] done count={len(results)} labels={labels_path}",
        flush=True,
    )
    return {"count": len(results), "labels_file": labels_path, "lines": results}




@app.post("/pack_lmdb")
def pack_lmdb(req: PackLmdbRequest):
    print(
        f"[pack_lmdb] crnn_output_dir={req.crnn_output_dir!r} "
        f"lmdb_path={req.lmdb_path!r} map_size={req.map_size}",
        flush=True,
    )
    try:
        import lmdb
    except ImportError as exc:
        raise HTTPException(
            status_code=500,
            detail=f"lmdb not installed: {exc}",
        )

    crnn_dir = Path(req.crnn_output_dir)
    labels_path = crnn_dir / "labels.txt"
    if not labels_path.exists():
        raise HTTPException(
            status_code=400,
            detail=f"labels.txt not found in {req.crnn_output_dir}",
        )

    lmdb_path = Path(req.lmdb_path)
    lmdb_parent = lmdb_path.parent
    if str(lmdb_parent) and not lmdb_parent.exists():
        lmdb_parent.mkdir(parents=True, exist_ok=True)
    lmdb_name = lmdb_path.name or "lmdb"

    labels = {}
    with open(labels_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n").rstrip("\r")
            if not line:
                continue
            parts = line.split("\t", 1)
            if len(parts) != 2:
                parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            labels[parts[0]] = parts[1]

    env = lmdb.open(
        str(lmdb_path),
        map_size=req.map_size,
        subdir=True,
        lock=False,
    )
    count = 0
    with env.begin(write=True) as txn:
        for filename, label in labels.items():
            img_path = crnn_dir / filename
            if not img_path.exists():
                print(f"[pack_lmdb] missing image: {filename}", flush=True)
                continue
            with open(img_path, "rb") as img_f:
                img_bytes = img_f.read()
            sample = {
                "image": img_bytes,
                "label": label.encode("utf-8"),
            }
            import pickle
            value = pickle.dumps(sample)
            txn.put(filename.encode("utf-8"), value)
            count += 1

    env.close()
    print(f"[pack_lmdb] done count={count}", flush=True)
    return {"count": count, "lmdb_path": str(lmdb_path)}
