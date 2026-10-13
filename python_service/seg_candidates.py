# -*- coding: utf-8 -*-
"""候选字（从 segmenter 拆出）：单字候选生成与 char_cls 分类映射。
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
from seg_trace import _log, _exception_summary
from seg_imaging import _imread
from seg_models import (_get_custom_model, _YOLO_PREDICT_LOCK)




def get_char_candidates(
    image_path: str,
    char_rect: tuple[int, int, int, int],
    top_k: int = 5,
    image: np.ndarray | None = None,
) -> list[dict[str, Any]]:
    """对单个单字 crop 出 top-k 候选 [{text, score}]。

    来源是自训候选字分类器（char_cls，训练自用户校正的字文本）。
    未训练/未启用分类器时返回空列表，编辑器会回退显示当前识别文字。
    char_rect 是 (x, y, w, h) 全图绝对坐标。
    """
    x, y, w, h = char_rect
    img = image if image is not None else _imread(image_path)
    if img is None:
        return []
    ih, iw = img.shape[:2]

    # 裁剪 padding 必须与训练数据导出（training_service._write_char_cls_
    # dataset）完全同公式，否则训练/推理分布漂移。此前推理用 //200：
    # 整页 3000px 时四边外扩 15px，而训练只有约 7px——密排竖排的推理
    # 裁剪吃进上下邻字笔画，候选被邻字（如前一字"星"）主导、正确字
    # （如"為"）反而不在候选里。
    pad_px = max(2, min(iw, ih) // 400)
    x1 = max(0, x - pad_px)
    y1 = max(0, y - pad_px)
    x2 = min(iw, x + w + pad_px)
    y2 = min(ih, y + h + pad_px)
    crop = img[y1:y2, x1:x2]
    if crop.size == 0:
        return []

    candidates = _char_cls_candidates(crop.copy(), top_k)

    # 去重并保留同一字符的最高分，避免候选列表重复占位。
    unique: dict[str, dict[str, Any]] = {}
    for candidate in candidates:
        text = candidate.get("text", "")
        if len(text) != 1:
            continue
        # 分类器的字类全部来自用户确认的古籍文字，理论上不会出现拉丁
        # 字母噪声；这里仍保留过滤，防御性排除误导性的 ASCII 猜测。
        if text.isascii() and text.isalpha():
            continue
        previous = unique.get(text)
        if previous is None or candidate["score"] > previous["score"]:
            unique[text] = candidate
    candidates = sorted(unique.values(), key=lambda c: -c["score"])[: max(1, min(10, top_k))]
    _log(f"[diag:candidates] rect=({x},{y},{w},{h}) k={len(candidates)}")
    return candidates




def _cls_name_to_char(name) -> str:
    """分类器类名还原为字符：目录式数据集的类名经 training_service.
    _safe_class_name 转义（Windows 非法字符 → _uXXXX），推理时还原。"""
    name = str(name)
    if len(name) == 6 and name.startswith("_u"):
        try:
            return chr(int(name[2:], 16))
        except ValueError:
            return name
    return name




def _char_cls_candidates(
    crop: np.ndarray, top_k: int
) -> list[dict[str, Any]]:
    """自训候选字分类器（char_cls）对字图出 top-K，未启用/失败返回空。"""
    try:
        with _YOLO_PREDICT_LOCK:
            model = _get_custom_model("char_cls")
            if model is None:
                return []
            results = model.predict(source=crop, verbose=False)
        probs = getattr(results[0], "probs", None) if results else None
        if probs is None:
            return []
        data = probs.data
        n = data.shape[-1]
        k = min(top_k, n)
        top = data.topk(k)
        names = model.names
        out = []
        for idx, score in zip(top.indices.tolist(), top.values.tolist()):
            text = _cls_name_to_char(
                names.get(idx, names[idx]) if isinstance(names, dict)
                else names[idx])
            if len(text) == 1:
                out.append({"text": text, "score": round(float(score), 4)})
        _log(f"[diag:candidates] char_cls top-{len(out)}: {[c['text'] for c in out[:5]]}")
        return out
    except Exception as exc:
        _log(f"[diag:candidates] char_cls failed: {_exception_summary(exc)}")
        return []
