# -*- coding: utf-8 -*-
"""训练域路由（从 main.py 拆出）：/train/*、/models/*、/char_cls/evaluate。"""
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





class TrainDatasetsRequest(BaseModel):
    project_dir: str
    layers: List[str] = []  # 空 = 全部 5 层
    force: bool = False
    train_ratio: float = 0.8
    seed: int = 42




class TrainExportRequest(BaseModel):
    project_dir: str
    layers: List[str] = []  # 空 = 全部 5 层
    force: bool = False  # 重写书库内全部有效页（书库外的书仍不动）
    train_ratio: float = 0.8
    seed: int = 42



class TrainStartRequest(BaseModel):
    project_dir: str
    layer: str  # char_det | line_det | paragraph_det | region_det | char_cls
    base_model: str = "yolov8s.pt"
    epochs: int = 150
    imgsz: int = 1280
    batch: int = -1
    device: str = "auto"  # auto | cpu | cuda
    save_period: int = 0  # 每 N 轮存一次中间检查点（0=不存）




class TrainStopRequest(BaseModel):
    task_id: str




class ModelActivateRequest(BaseModel):
    layer: str
    model_path: Optional[str] = None  # 指定启用某次训练的 best.pt；空 = 最新一次



class ModelDeleteRunRequest(BaseModel):
    layer: str
    run_dir: str



class TrainPathsRequest(BaseModel):
    dataset_root: str = ""  # 空 = 不改
    trained_root: str = ""



# ────────────────────────── 训练与模型管理 ──────────────────────────


@app.get("/train/paths")
def train_paths_get():
    """数据集/训练模型根目录配置（train_paths.json，机器本地）。"""
    import train_paths

    cfg = train_paths.load_paths()
    return {**cfg, "config_path": train_paths.config_path(),
            "defaults": train_paths.defaults()}


@app.post("/train/paths")
def train_paths_set(req: TrainPathsRequest):
    import train_paths

    try:
        cfg = train_paths.save_paths(
            dataset_root=req.dataset_root, trained_root=req.trained_root)
    except OSError as exc:
        raise HTTPException(status_code=400, detail=f"路径不可用：{exc}")
    return {**cfg, "config_path": train_paths.config_path()}


# /train/stats 短缓存：训练页有任务时每 2s 轮询一次，而统计每次都是
# 全库扫描（实测书库 3300 页标注时单次 ~33s、瞬时分配 GB 级，且
# json 解析全程持 GIL——识别请求被拖到超时的直接根源）。按库根缓存
# 一个 TTL；扫描本身远长于 TTL，必须再做在途去重：并发轮询等同一个
# 在途扫描的结果，而不是各开一个 33s 的全库扫描（多扫描并发会把
# 上面 GB 级的瞬时分配叠加，直接顶爆提交内存——夜间批量识别时
# 服务反复 access violation 崩溃的诱因）。
_STATS_CACHE_TTL = 5.0
_stats_cache: dict[str, tuple[float, dict]] = {}
_stats_cache_lock = threading.Lock()
_stats_inflight: dict[str, object] = {}
_stats_inflight_cond = threading.Condition(_stats_cache_lock)


@app.get("/train/stats")
def train_stats(project_dir: str):
    import training_service

    lib_root = os.path.normpath(training_service.library_root_of(project_dir))
    with _stats_inflight_cond:
        cached = _stats_cache.get(lib_root)
        if cached is not None and time.monotonic() - cached[0] < _STATS_CACHE_TTL:
            return cached[1]
        # 已有同库扫描在途：等它完成并直接用它的结果（最多等一个
        # 扫描周期；扫描异常时回退为自己再扫一次）。
        while lib_root in _stats_inflight:
            _stats_inflight_cond.wait(timeout=1.0)
            cached = _stats_cache.get(lib_root)
            if cached is not None and time.monotonic() - cached[0] < 60.0:
                return cached[1]
        # 醒来时在途扫描可能刚结束：复查 TTL，新鲜就别再扫了。
        cached = _stats_cache.get(lib_root)
        if cached is not None and time.monotonic() - cached[0] < _STATS_CACHE_TTL:
            return cached[1]
        _stats_inflight[lib_root] = True
    try:
        try:
            stats = training_service.dataset_stats(project_dir)
        except Exception as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        with _stats_inflight_cond:
            _stats_cache[lib_root] = (time.monotonic(), stats)
            return stats
    finally:
        with _stats_inflight_cond:
            _stats_inflight.pop(lib_root, None)
            _stats_inflight_cond.notify_all()




@app.post("/train/datasets")
def train_datasets(req: TrainDatasetsRequest):
    import training_service

    # 与 generate_datasets 同语义：单本书目录或库根目录（汇总全部书籍）都
    # 接受。数据集全局共享——这里只决定刷新哪些书的样本，其他书已生成
    # 的样本保持不动。
    if not training_service.has_books(req.project_dir):
        raise HTTPException(status_code=400, detail="project not found")
    try:
        return training_service.generate_datasets(
            req.project_dir,
            layers=req.layers or None,
            force=req.force,
            train_ratio=req.train_ratio,
            seed=req.seed,
        )
    except Exception as exc:
        print(f"[train/datasets] error: {exc}", flush=True)
        raise HTTPException(status_code=500, detail=str(exc))




@app.post("/train/start")
def train_start(req: TrainStartRequest):
    import training_service

    # 与 /train/datasets 同语义：单本书目录或库根目录（汇总全部书籍）都接受
    if not training_service.has_books(req.project_dir):
        raise HTTPException(status_code=400, detail="project not found")
    try:
        stats = training_service.dataset_stats(req.project_dir)
        layer_stats = (stats.get("layers") or {}).get(req.layer) or {}
        # Match the actual backbone passed to the worker, including the
        # legacy classification fallback for non-classification checkpoints.
        model_key = os.path.splitext(os.path.basename(req.base_model))[0]
        if req.layer == "char_cls":
            model_key = model_key.removesuffix("-cls") if req.base_model.endswith("-cls.pt") else "yolov8n"
        readiness = (layer_stats.get("readiness") or {}).get("requirements", {}).get(model_key)
        if readiness is not None and not readiness.get("ready", False):
            missing = readiness.get("missing_instances", 0)
            missing_classes = readiness.get("missing_classes", 0)
            detail = f"{req.layer}/{model_key} 尚需确认 {missing} 个样本"
            if missing_classes:
                detail += f"，还需 {missing_classes} 个字类"
            raise HTTPException(status_code=400, detail=detail)
        data_path = training_service.dataset_dir(req.project_dir, req.layer)
        if not data_path:
            raise HTTPException(status_code=400, detail=f"dataset for {req.layer} unavailable")
        return training_service.start_training(
            req.layer,
            data_path,
            base_model=req.base_model,
            epochs=req.epochs,
            imgsz=req.imgsz,
            batch=req.batch,
            device=req.device,
            save_period=req.save_period,
        )
    except HTTPException:
        raise
    except Exception as exc:
        print(f"[train/start] error: {exc}", flush=True)
        raise HTTPException(status_code=500, detail=str(exc))




@app.post("/train/export")
def train_export(req: TrainExportRequest):
    """页级增量导出：只写新增/变化的页；manifest 记账（与数据同住、可跨
    机迁移）；书籍任务删除不影响已导出数据与统计。"""
    import train_export

    try:
        return train_export.export_datasets(
            req.project_dir, req.layers or None, force=req.force,
            train_ratio=req.train_ratio, seed=req.seed)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@app.get("/train/status")
def train_status():
    import training_service

    return {"tasks": training_service.training_status()}




@app.get("/train/log")
def train_log(task_id: Optional[str] = None):
    """完整训练日志（status 接口只带最后 30 行 log_tail）。"""
    import training_service

    try:
        return training_service.training_log(task_id)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))



@app.get("/train/curve")
def train_curve(run_dir: str):
    """训练曲线：逐 epoch 指标/损失（results.csv）+ 已存中间检查点清单。

    run_dir 支持进行中任务与注册表历史 run；前端画折线图并按曲线
    挑中间检查点启用（/models/activate 收任意 .pt 路径）。"""
    import training_service

    try:
        return training_service.training_curve(run_dir)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




class CharClsEvaluateRequest(BaseModel):
    project_dir: str
    image_path: str
    use_models: bool = True  # False = 禁用自训分类模型（基线候选）
    test_model_path: Optional[str] = None  # 指定评测某次训练的 best.pt
    limit: int = 100  # 最多评测多少个字
    chars: Optional[List[dict]] = None  # 显式给出参考单字 [{text,x,y,w,h}]




@app.post("/char_cls/evaluate")
def char_cls_evaluate(req: CharClsEvaluateRequest):
    """单字候选分类模型对比评测：以单字文字为答案统计候选命中率。"""
    import training_service

    try:
        return training_service.evaluate_char_cls(
            req.project_dir,
            req.image_path,
            use_models=req.use_models,
            test_model_path=req.test_model_path,
            limit=req.limit,
            chars=req.chars,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




@app.get("/train/preflight")
def train_preflight(project_dir: str):
    """训练前体检：训练环境 + 各层数据集完整性逐项检查，供界面展示。"""
    import training_service

    checks: list[dict] = []

    def add(name: str, ok: bool, detail: str) -> None:
        checks.append({"name": name, "ok": ok, "detail": detail})

    try:
        import torch

        cuda = bool(torch.cuda.is_available())
        add("PyTorch", True, f"torch={torch.__version__}，CUDA 可用={cuda}")
        if not cuda:
            add(
                "训练设备",
                True,
                "当前为 CPU 训练：可用但很慢；需 GPU 训练请安装 CUDA 版 torch",
            )
    except Exception as exc:
        add("PyTorch", False, f"导入失败：{exc}")

    try:
        import ultralytics

        add("Ultralytics", True, f"版本 {ultralytics.__version__}")
    except Exception as exc:
        add("Ultralytics", False, f"导入失败：{exc}")

    try:
        stats = training_service.dataset_stats(project_dir)
    except Exception as exc:
        add("数据集", False, f"统计失败：{exc}")
        return {"checks": checks}

    layers = stats.get("layers", {})
    if not layers:
        add("数据集", False, "项目没有可训练的标注数据（没有已保存的页面标注）")
        return {"checks": checks}

    for layer, info in layers.items():
        dataset_dir = info.get("dataset_dir", "")
        if not info.get("dataset_dir_exists"):
            add(
                f"数据集 · {layer}",
                True,
                "尚未生成（点「生成数据集并训练」时会自动生成）",
            )
            continue
        yaml_path = os.path.join(dataset_dir, "data.yaml")
        try:
            from ultralytics.data.utils import check_det_dataset

            checked = check_det_dataset(yaml_path)
            counts = []
            for key in ("train", "val"):
                split = checked.get(key)
                paths = split if isinstance(split, list) else [split]
                n = 0
                for path in paths:
                    if path and os.path.isdir(str(path)):
                        n += len(os.listdir(str(path)))
                counts.append(f"{key} {n} 张")
            add(f"数据集 · {layer}", True, "校验通过：" + "，".join(counts))
        except Exception as exc:
            detail = str(exc).splitlines()[-1] if str(exc) else "未知错误"
            add(f"数据集 · {layer}", False, f"校验失败：{detail}")

    return {"checks": checks}




@app.post("/train/stop")
def train_stop(req: TrainStopRequest):
    import training_service

    try:
        return training_service.stop_training(req.task_id)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




@app.get("/models")
def models_list():
    import training_service

    return {"layers": training_service.list_models()}




@app.post("/models/activate")
def models_activate(req: ModelActivateRequest):
    import training_service

    try:
        return training_service.activate_model(req.layer, req.model_path)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))




@app.post("/models/delete_run")
def models_delete_run(req: ModelDeleteRunRequest):
    """删除一次训练的 run（目录+注册表条目；启用中的先自动停用）。"""
    import train_registry

    if req.layer not in train_registry.LAYERS:
        raise HTTPException(status_code=400, detail=f"未知层：{req.layer}")
    try:
        size_mb = round(train_registry.run_dir_size_mb(req.run_dir), 1)
        result = train_registry.delete_run(req.layer, req.run_dir)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    result["size_mb_deleted"] = size_mb
    return result


@app.get("/models/run_size")
def models_run_size(run_dir: str):
    """run 目录磁盘占用（删除确认框展示用）。"""
    import train_registry

    try:
        return {"run_dir": run_dir,
                "size_mb": round(train_registry.run_dir_size_mb(run_dir), 1)}
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@app.post("/models/deactivate")
def models_deactivate(req: ModelActivateRequest):
    import training_service

    try:
        return training_service.deactivate_model(req.layer)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
