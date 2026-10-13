# -*- coding: utf-8 -*-
"""YOLO/OpenCC 模型装载层（从 segmenter 拆出）：模型单例与加载锁、
项目覆写/测试模型/自训模型、分层检测推理。segmenter.py 仍为门面。"""
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
from seg_trace import _log, _exception_summary





_YOLO_CHAR_MODEL: Any | None = None


_YOLO_CHAR_PATH: str | None = None


_YOLO_ERROR: str | None = None


_OPENCC_ERROR: str | None = None


# 自训 YOLO 模型是模块级单例（含懒加载缓存），ultralytics 的 predict 不
# 保证线程安全；页间流水线允许两个识别请求在途时，所有 predict/懒加载
# 在这把锁下串行执行（版面检测每页仅 ~0.3s，串行化不是瓶颈）。
_YOLO_PREDICT_LOCK = threading.Lock()




def _import_opencc() -> bool:
    global _OPENCC_ERROR
    _log("[diag:opencc] import start")
    try:
        from opencc import OpenCC  # noqa: F401
        _OPENCC_ERROR = None
        _log("[diag:opencc] import ok")
        return True
    except Exception as exc:
        _OPENCC_ERROR = _exception_summary(exc)
        _log(f"[diag:opencc] import failed: {_OPENCC_ERROR}")
        return False




def _preload_torch_for_windows() -> bool:
    if os.name != "nt":
        return True
    try:
        import torch

        _log(f"[diag:torch] preload ok torch={torch.__version__}")
        return True
    except Exception as exc:
        _log(f"[diag:torch] preload failed: {_exception_summary(exc)}")
        _log(traceback.format_exc().rstrip())
        return False




def _default_yolo_model_path() -> str:
    # A manually activated char_det run takes precedence over the bundled
    # checkpoint; this keeps inference and the training registry in sync.
    try:
        import training_service
        active = training_service.active_model_path("char_det")
        if active and os.path.exists(active):
            return active
    except Exception:
        pass
    return resolve_model_path("char_det")




def _load_yolo_char_model():
    global _YOLO_CHAR_MODEL, _YOLO_ERROR, _YOLO_CHAR_PATH
    test = _load_test_model("char_det")
    if test is not None:
        return test
    if _MODELS_DISABLED:
        return None
    override = _override_for("char_det")
    if override is not None and override == "":
        return None  # 项目配置强制停用单字检测
    model_path = (
        override if override is not None else _default_yolo_model_path()
    )
    if not os.path.exists(model_path):
        _YOLO_ERROR = f"model not found: {model_path}"
        _log(f"[diag:yolo] {_YOLO_ERROR}")
        return None
    if _YOLO_CHAR_MODEL is not None and _YOLO_CHAR_PATH == model_path:
        _log("[diag:yolo] reuse initialized YOLO char model")
        return _YOLO_CHAR_MODEL
    if _YOLO_ERROR is not None:
        _log(f"[diag:yolo] previous init failed, skip reinitialization in current process: {_YOLO_ERROR}")
        return None

    _log(f"[diag:yolo] import start model={model_path}")
    try:
        from ultralytics import YOLO

        _YOLO_CHAR_MODEL = YOLO(model_path)
        _YOLO_CHAR_PATH = model_path
        _YOLO_ERROR = None
        _log(f"[diag:yolo] init ok class={type(_YOLO_CHAR_MODEL).__name__}")
        return _YOLO_CHAR_MODEL
    except Exception as exc:
        _YOLO_ERROR = _exception_summary(exc)
        _log(f"[diag:yolo] init failed: {_YOLO_ERROR}")
        _log(traceback.format_exc().rstrip())
        return None




def _yolo_diagnostics() -> dict[str, Any]:
    model_path = _default_yolo_model_path()
    return {
        "model_path": model_path,
        "model_exists": os.path.exists(model_path),
        "initialized": _YOLO_CHAR_MODEL is not None,
        "error": _YOLO_ERROR,
    }




# ── 自训模型（训练服务产出）的反哺接入 ──
# key: layer（line_det / paragraph_det / region_det / char_cls）
_CUSTOM_MODELS: dict[str, tuple[Any, str]] = {}



# 模型对比测试开关：置 True 时所有自训模型视为不可用，识别走基线管线
#（OpenCV 投影切分 + Kraken 文字识别）。/segment 的
# use_models=False 请求在识别锁保护内临时置位，跑完即恢复。
_MODELS_DISABLED = False



# 模型对比测试的"指定模型"覆写：(layer, model_path)。设置后该层识别
# 优先加载这个模型文件（无论注册表启用了什么），同样仅在一次请求内生效。
_MODEL_TEST: tuple[str, str] | None = None


_MODEL_TEST_CACHE: dict[str, tuple[Any, str]] = {}



# 按项目配置的多层模型覆写：layer -> 模型文件路径；'' 表示该层强制停用
#（走基线）。优先级：单层测试覆写 > 关闭开关 > 项目覆写 > 注册表启用。
_MODEL_OVERRIDES: dict[str, str] = {}




def set_models_disabled(disabled: bool) -> None:
    global _MODELS_DISABLED
    _MODELS_DISABLED = disabled




def _override_for(layer: str) -> str | None:
    """返回该层的项目覆写：路径 = 使用指定模型；'' = 强制停用；None = 未覆写。"""
    return _MODEL_OVERRIDES.get(layer)




def set_model_test(layer: str | None, model_path: str | None) -> None:
    global _MODEL_TEST
    _MODEL_TEST = (layer, model_path) if layer and model_path else None




def _load_test_model(layer: str) -> Any | None:
    """加载对比测试指定的模型（按层缓存，路径变化时重载）。"""
    if not _MODEL_TEST or _MODEL_TEST[0] != layer:
        return None
    path = _MODEL_TEST[1]
    cached = _MODEL_TEST_CACHE.get(layer)
    if cached and cached[1] == path:
        return cached[0]
    _log(f"[model-test] load {layer}: {path}")
    try:
        _preload_torch_for_windows()
        from ultralytics import YOLO

        model = YOLO(path)
        _MODEL_TEST_CACHE[layer] = (model, path)
        return model
    except Exception as exc:
        _log(f"[model-test] load failed: {_exception_summary(exc)}")
        return None




def _get_custom_model(layer: str) -> Any | None:
    """懒加载当前生效的自训模型：单层测试覆写 > 项目覆写 > 注册表启用。"""
    test = _load_test_model(layer)
    if test is not None:
        return test
    if _MODELS_DISABLED:
        return None
    override = _override_for(layer)
    if override is not None and override == "":
        return None  # 项目配置强制停用该层
    cached = _CUSTOM_MODELS.get(layer)
    try:
        import training_service

        active = override if override is not None else training_service.active_model_path(layer)
    except Exception:
        return None
    if not active:
        _CUSTOM_MODELS.pop(layer, None)
        return None
    if cached and cached[1] == active:
        return cached[0]
    _log(f"[custom-model] load {layer}: {active}")
    try:
        _preload_torch_for_windows()
        from ultralytics import YOLO

        model = YOLO(active)
        _CUSTOM_MODELS[layer] = (model, active)
        return model
    except Exception as exc:
        _log(f"[custom-model] load {layer} failed: {_exception_summary(exc)}")
        _CUSTOM_MODELS.pop(layer, None)
        return None




def reset_custom_models() -> None:
    """激活/停用模型后刷新所有自定义模型缓存（含单字检测引擎）。"""
    global _YOLO_CHAR_MODEL, _YOLO_ERROR, _YOLO_CHAR_PATH
    _CUSTOM_MODELS.clear()
    _YOLO_CHAR_MODEL = None
    _YOLO_CHAR_PATH = None
    _YOLO_ERROR = None
    _log("[custom-model] caches reset")




def record_yolo_error(reason: str) -> None:
    """跨模块写入 YOLO 失败原因（_YOLO_ERROR 属于本模块的模块级状态）。"""
    global _YOLO_ERROR
    _YOLO_ERROR = reason




def current_yolo_error() -> str | None:
    """跨模块读取 YOLO 失败原因（避免 from-import 拿到旧值快照）。"""
    return _YOLO_ERROR




def detection_layer_names(layer: str) -> dict[int, str] | None:
    """当前生效检测模型的类别名映射（checkpoint 自带的 names）。

    多类层的 cls→label 映射必须用它而不是 train_data.LAYER_INFO 的当前
    词表：旧单类模型、或未来按旧词表快照训练的模型，其类别顺序以
    checkpoint 为准（词表约定 main_text 恒为 id=0、新类只追加）。
    """
    try:
        with _YOLO_PREDICT_LOCK:
            model = _get_custom_model(layer)
            if model is None:
                return None
            names = getattr(model, "names", None)
            return dict(names) if isinstance(names, dict) else None
    except Exception:
        return None




def _predict_detection_layer(
    layer: str,
    image_path: str,
    image_w: int,
    image_h: int,
    conf: float = 0.35,
) -> list[tuple[tuple[int, int, int, int], float, int]]:
    """用自训检测模型预测一层框，返回 [(rect, score, class_id)]（全图绝对坐标）。"""
    try:
        with _YOLO_PREDICT_LOCK:
            model = _get_custom_model(layer)
            if model is None:
                _log(f"[model-use] {layer}: 未使用自训模型（基线切分）")
                return []
            results = model.predict(source=image_path, conf=conf, iou=0.45, imgsz=1280, verbose=False)
    except Exception as exc:
        _log(f"[custom-model] {layer} predict failed: {_exception_summary(exc)}")
        return []
    out: list[tuple[tuple[int, int, int, int], float, int]] = []
    for result in results or []:
        boxes = getattr(result, "boxes", None)
        if boxes is None:
            continue
        xyxy = getattr(boxes, "xyxy", None)
        if xyxy is None:
            continue
        try:
            arr = xyxy.cpu().numpy() if hasattr(xyxy, "cpu") else np.asarray(xyxy)
            confs = boxes.conf.cpu().numpy() if hasattr(boxes.conf, "cpu") else np.asarray(boxes.conf)
            clss = boxes.cls.cpu().numpy() if hasattr(boxes.cls, "cpu") else np.asarray(boxes.cls)
        except Exception as exc:
            _log(f"[custom-model] {layer} boxes conversion failed: {_exception_summary(exc)}")
            continue
        for i, box in enumerate(arr):
            x1, y1, x2, y2 = [float(v) for v in box[:4]]
            bx1 = max(0, int(np.floor(x1)))
            by1 = max(0, int(np.floor(y1)))
            bx2 = min(image_w, int(np.ceil(x2)))
            by2 = min(image_h, int(np.ceil(y2)))
            if bx2 - bx1 < 3 or by2 - by1 < 3:
                continue
            score = float(confs[i]) if i < len(confs) else 0.0
            cls_id = int(clss[i]) if i < len(clss) else 0
            out.append(((bx1, by1, bx2 - bx1, by2 - by1), score, cls_id))
    _log(f"[custom-model] {layer} predicted {len(out)} boxes")
    return out
