# -*- coding: utf-8 -*-
"""Kraken 域路由（从 main.py 拆出）：/kraken/*。"""
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
from api_base import app, _gated_recognition





class KrakenExportRequest(BaseModel):
    project_dir: str
    max_lines: Optional[int] = None




class KrakenTrainStartRequest(BaseModel):
    project_dir: str
    epochs: int = 30
    base_model: Optional[str] = None
    max_lines: Optional[int] = 2000




class KrakenStopRequest(BaseModel):
    task_id: str




class KrakenActivateRequest(BaseModel):
    model_path: Optional[str] = None




@app.post("/kraken/export")
def kraken_export(req: KrakenExportRequest):
    """导出确认行为 Kraken 微调数据（行图 + .gt.txt，全库汇总到全局目录）。

    export_dataset 接受的是书籍目录列表——此前把单个路径字符串直接传入，
    迭代时按字符拆成单字符路径，永远报"确认行太少"。Kraken 为全局引擎，
    这里按 project_dir 所在书库的全部书籍导出。"""
    import kraken_training

    try:
        books = kraken_training._all_book_dirs(req.project_dir)
        return kraken_training.export_dataset(books, max_lines=req.max_lines)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




@app.post("/kraken/train/start")
def kraken_train_start(req: KrakenTrainStartRequest):
    """导出数据并启动 Kraken 识别模型微调（后台任务）。"""
    import kraken_training

    try:
        return kraken_training.start_training(
            req.project_dir,
            epochs=req.epochs,
            base_model=req.base_model,
            max_lines=req.max_lines,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




@app.get("/kraken/status")
def kraken_status():
    import kraken_training

    tasks = kraken_training.kraken_status()
    return {"tasks": tasks, "latest_model": kraken_training.latest_kraken_model()}




@app.get("/kraken/data")
def kraken_data(project_dir: str):
    """Kraken 微调的数据就绪状态：确认行数 vs 当前代数需求。"""
    import kraken_training

    try:
        return kraken_training.data_status(project_dir)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




@app.post("/kraken/train/stop")
def kraken_stop(req: KrakenStopRequest):
    import kraken_training

    try:
        return kraken_training.kraken_stop(req.task_id)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




@app.post("/kraken/activate")
def kraken_activate(req: KrakenActivateRequest):
    """启用微调模型：替换识别引擎模型并重启识别守护进程。"""
    import kraken_training

    try:
        return kraken_training.activate_kraken_model(req.model_path)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




@app.post("/kraken/deactivate")
def kraken_deactivate():
    """恢复官方底座识别模型。"""
    import kraken_training

    try:
        return kraken_training.deactivate_kraken_model()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




class KrakenPoolResizeRequest(BaseModel):
    workers: Optional[int] = None  # None = 清除覆盖，回到硬件自动决策




@app.post("/kraken/pool/resize")
def kraken_pool_resize(req: KrakenPoolResizeRequest):
    """按给定并行数重建识别进程池（设置页"识别进程数"的立即生效路径）。

    识别进行中拒绝（409）：重建先排空在途请求，空闲时才允许。耗时主要
    在逐个 daemon 加载模型（每个十几秒起），客户端等 5 分钟上限。"""
    if kraken_bridge.pool_busy() > 0:
        raise HTTPException(
            status_code=409,
            detail="识别正在进行中，请等识别结束后再重建进程池")
    try:
        return kraken_bridge.resize_pool(req.workers)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




def _probe_line_rect(img_w: int, img_h: int, direction: str) -> dict:
    """压测探针的行框：图中心取一条带（竖排取纵向带、横排取横向带）。

    只为消耗一次真实的行识别（裁剪/二值化/解码全链路），内容是否可读
    无关紧要；同一张图 + 同一框保证各档耗时可对比。"""
    if direction.startswith("vertical"):
        w, h = max(48, img_w // 8), img_h
        x, y = max(0, (img_w - w) // 2), 0
    else:
        w, h = img_w, max(48, img_h // 8)
        x, y = 0, max(0, (img_h - h) // 2)
    return {"x": x, "y": y, "w": w, "h": h}




class KrakenProbeRequest(BaseModel):
    image_path: str  # 书库里的任意页图（客户端从书库自动选）
    text_direction: str = "vertical-rl"




@app.post("/kraken/probe")
def kraken_probe(req: KrakenProbeRequest):
    """对识别进程池发一次单行识别（压力测试探针，不占识别闸门）。

    一次请求占住一个池成员；k 路并发探针在 k 成员池上无排队、在小于 k
    的池上必然排队变慢——客户端据此判稳。返回耗时与池规模供爬坡判据。"""
    image_path = req.image_path
    if not image_path or not os.path.isfile(image_path):
        raise HTTPException(
            status_code=400,
            detail=f"样本图不存在: {image_path}（客户端应从书库选一张真实页图）")
    from train_data import _image_size

    size = _image_size(image_path)
    if not size:
        raise HTTPException(status_code=400, detail=f"样本图无法读取: {image_path}")
    img_w, img_h = size
    payload = {
        "image_path": image_path,
        "scale": 1.0,
        "text_direction": req.text_direction,
        "per_line": True,
        "lines": [_probe_line_rect(img_w, img_h, req.text_direction)],
    }
    started = time.time()
    try:
        result = kraken_bridge._ensure_pool().request(
            "recognize", payload, timeout=120)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"识别进程请求失败: {exc}")
    elapsed = time.time() - started
    lines = result.get("lines") or []
    return {
        "elapsed_s": round(elapsed, 3),
        "pool_size": kraken_bridge.pool_size(),
        "text_len": len((lines[0] or {}).get("text") or "") if lines else 0,
    }
