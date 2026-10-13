# -*- coding: utf-8 -*-
"""校验域路由（从 main.py 拆出）：/verify_char*、/verify/train/*、/verify/templates/*。"""
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





class VerifyCharRequest(BaseModel):
    image_path: str
    x: int
    y: int
    w: int
    h: int
    text: str = ""
    conf: float | None = None  # 识别置信度：平移判定阈值带（高置信难标红）
    cls_rank: int | None = None  # 当前文字在 char_cls 候选的 1 基排名（0=掉出）
    debug: bool = False  # 为 True 时返回墨迹/字形骨架叠加图 base64




class VerifyCharItem(BaseModel):
    id: str
    x: int
    y: int
    w: int
    h: int
    text: str = ""
    conf: float | None = None
    status: str | None = None  # proposed|confirmed|...：批量同伴校验的锚




class VerifyCharsBatchRequest(BaseModel):
    image_path: str
    blocks: List[VerifyCharItem]
    project_dir: str | None = None  # 模板库定位本书（缺省则模板互证缺席）




@app.post("/verify_char")
def verify_char(req: VerifyCharRequest):
    """单字墨迹校验：识别文字的字形骨架与墨迹骨架做拓扑+形状重叠比对。

    纯 CPU（细化/拓扑计数），不走 GPU 识别门。返回 level ∈
    {ok, suspect, mismatch, skipped} 与分层分数；mismatch 供前端标红
    并转待复核。
    """
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    try:
        return char_verify.verify_char(
            req.image_path, (req.x, req.y, req.w, req.h), req.text,
            conf=req.conf, cls_rank=req.cls_rank, debug=req.debug)
    except HTTPException:
        raise
    except Exception as e:
        print(f"[verify_char] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




@app.post("/verify_chars_batch")
def verify_chars_batch(req: VerifyCharsBatchRequest):
    """整页字块批量墨迹校验（编辑器「校验本页」）。纯 CPU，不走 GPU
    识别门；整页墨迹 mask 只构建一次，单字异常不中断整批。"""
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    try:
        result = char_verify.verify_chars_batch(
            req.image_path, req.blocks, project_dir=req.project_dir)
        levels: dict[str, int] = {}
        for item in result["results"].values():
            level = item.get("level", "skipped")
            levels[level] = levels.get(level, 0) + 1
        print(
            f"[verify_chars_batch] blocks={len(req.blocks)} levels={levels} "
            f"errors={len(result['errors'])} "
            f"elapsed={result['elapsed_ms']:.0f}ms",
            flush=True,
        )
        return result
    except HTTPException:
        raise
    except Exception as e:
        print(f"[verify_chars_batch] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




# --- 墨迹比对模型（siamese）训练 + 跨页模板库（模型化阶段 2/3） -------------

import verify_templates  # noqa: E402


import verify_training  # noqa: E402




class VerifyTrainDataRequest(BaseModel):
    project_dir: str




class VerifyTrainExportRequest(BaseModel):
    project_dir: str
    force: bool = False




class VerifyTrainStartRequest(BaseModel):
    project_dir: str
    epochs: int = verify_training.DEFAULT_EPOCHS
    device: str = "auto"




class VerifyTrainStopRequest(BaseModel):
    task_id: str




class VerifyTrainActivateRequest(BaseModel):
    run_dir: str | None = None




class VerifyTemplatesUpdateRequest(BaseModel):
    project_dir: str
    image_path: str
    blocks: List[VerifyCharItem]




class VerifyTemplatesClearRequest(BaseModel):
    project_dir: str




@app.post("/verify/train/data")
def verify_train_data(req: VerifyTrainDataRequest):
    """墨迹比对模型的数据概况：确认单字数（正样本）/改过首选（硬负）/
    字集大小/是否达到训练门槛。"""
    try:
        return verify_training.data_status(req.project_dir)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        print(f"[verify/train/data] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




@app.post("/verify/train/export")
def verify_train_export(req: VerifyTrainExportRequest):
    """导出图对数据集（墨迹/字形 128 画布 + 正/硬负样本 + 易混挖掘）。"""
    try:
        return verify_training.export_dataset(req.project_dir,
                                              force=req.force)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        print(f"[verify/train/export] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




@app.post("/verify/train/start")
def verify_train_start(req: VerifyTrainStartRequest):
    """启动比对模型训练（子进程，进度走 /verify/train/status）。"""
    try:
        data = verify_training.dataset_dir(req.project_dir)
        if not os.path.isdir(data):
            raise ValueError("数据集不存在，请先导出")
        return verify_training.start_training(
            data, epochs=req.epochs, device=req.device)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=409, detail=str(e))
    except Exception as e:
        print(f"[verify/train/start] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




@app.get("/verify/train/status")
def verify_train_status():
    """比对模型训练任务列表（含进度与日志尾部）。"""
    return {"tasks": verify_training.training_status(),
            "models": verify_training.list_models()}




@app.post("/verify/train/stop")
def verify_train_stop(req: VerifyTrainStopRequest):
    try:
        return verify_training.stop_training(req.task_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))




@app.post("/verify/train/activate")
def verify_train_activate(req: VerifyTrainActivateRequest):
    """激活比对模型（热重载，无需重启后端）。"""
    try:
        return verify_training.activate_model(req.run_dir)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))




@app.post("/verify/train/deactivate")
def verify_train_deactivate():
    return verify_training.deactivate_model()




@app.post("/verify/templates/update")
def verify_templates_update(req: VerifyTemplatesUpdateRequest):
    """增量合并一页已确认字的墨迹模板（编辑器「确认并保存」后调用）。"""
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    try:
        return verify_templates.update_from_blocks(
            req.project_dir, req.image_path, req.blocks)
    except Exception as e:
        print(f"[verify/templates/update] error: {e}", flush=True)
        raise HTTPException(status_code=500, detail=str(e))




@app.post("/verify/templates/clear")
def verify_templates_clear(req: VerifyTemplatesClearRequest):
    """清空本书模板库（「本书重置为未确认」时同步调用）。"""
    return verify_templates.clear(req.project_dir)
