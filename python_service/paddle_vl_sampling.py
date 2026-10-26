# -*- coding: utf-8 -*-
"""PaddleOCR-VL 本地推理的采样参数补丁。

上游 paddlex 的本地 doc_vlm 预测器（DocVLMLocalPredictor.process）把
repetition_penalty / temperature / top_p 三个采样参数当未知项警告后丢弃，
只透传 max_new_tokens / use_cache；官网演示同款参数在其服务端推理栈才生效。
底层生成库（paddlex.inference.models.common.transformers.generation）其实
完整支持：repetition_penalty 走 logits processor（贪心解码也生效），
temperature / top_p 需 decode_strategy="sampling"。

本模块在两处补上丢失的转发（都是方法级 monkey-patch，不动 site-packages）：
1. DocVLMLocalPredictor.process：按请求参数临时给 self.infer 绑定一个
   会追加采样参数的 generate（用完还原），让参数能进到模型层；
2. PaddleOCRVLForConditionalGeneration.generate：原包装只转发
   max_new_tokens / use_cache，补转发三个采样参数到底层
   GenerationMixin.generate（temperature>0 时切 sampling 解码并显式
   top_k=0——生成库默认 top_k=50 会悄悄截断候选，不适合整页读字）。

temperature<=0（含界面默认 0.0）保持贪心解码、行为与历史一致；
repetition_penalty=1.0 为无操作。paddlex 不在（测试环境）时整体跳过。"""
from __future__ import annotations

import importlib
import threading

_lock = threading.Lock()
_installed = False
_result = ""


def _sampling_kwargs(
    repetition_penalty, temperature, top_p
) -> dict:
    """请求级采样参数 → 传给底层 generate 的 kwargs（空 dict = 保持原行为）。

    repetition_penalty != 1.0 在贪心解码下同样生效（logits processor）；
    temperature > 0 才切 sampling 解码（temperature=0 除零，保持贪心）；
    切 sampling 时显式 top_k=0 关闭库默认的 50 截断。"""
    out: dict = {}
    if isinstance(repetition_penalty, (int, float)) and repetition_penalty != 1.0:
        out["repetition_penalty"] = float(repetition_penalty)
    if isinstance(temperature, (int, float)) and temperature > 0:
        out["decode_strategy"] = "sampling"
        out["temperature"] = float(temperature)
        out["top_p"] = float(top_p) if isinstance(top_p, (int, float)) else 1.0
        out["top_k"] = 0
    return out


def _patch_local_predictor(predictor_mod) -> bool:
    """DocVLMLocalPredictor.process 包装：采样参数不再被丢弃。"""
    cls = getattr(predictor_mod, "DocVLMLocalPredictor", None)
    if cls is None or getattr(cls.process, "_ziji_sampling_patch", False):
        return getattr(cls, "_ziji_sampling_patched", False) if cls else False

    orig_process = cls.process

    def process(self, data, **kwargs):
        sampling = _sampling_kwargs(
            kwargs.get("repetition_penalty"),
            kwargs.get("temperature"),
            kwargs.get("top_p"),
        )
        infer = getattr(self, "infer", None)
        if not sampling or infer is None or not hasattr(infer, "generate"):
            return orig_process(self, data, **kwargs)
        had_own_generate = "generate" in vars(infer)
        orig_generate = infer.generate

        def _generate_with_sampling(inputs, **gk):
            return orig_generate(inputs, **gk, **sampling)

        infer.generate = _generate_with_sampling
        try:
            return orig_process(self, data, **kwargs)
        finally:
            if had_own_generate:
                infer.generate = orig_generate
            else:
                del infer.generate

    process._ziji_sampling_patch = True
    cls.process = process
    cls._ziji_sampling_patched = True
    return True


def _patch_model_generate(model_mod) -> bool:
    """PaddleOCRVLForConditionalGeneration.generate：补转发采样参数。"""
    cls = getattr(model_mod, "PaddleOCRVLForConditionalGeneration", None)
    if cls is None or getattr(cls.generate, "_ziji_sampling_patch", False):
        return getattr(cls, "_ziji_sampling_patched", False) if cls else False

    parent_generate = None
    for base in cls.__mro__:
        if base is not cls and "generate" in vars(base):
            parent_generate = vars(base)["generate"]
            break
    if parent_generate is None:
        return False

    def generate(self, inputs, **kwargs):
        import paddle

        gen_kwargs = {
            "max_new_tokens": kwargs.get("max_new_tokens", 8192),
            "use_cache": kwargs.get("use_cache", True),
        }
        gen_kwargs.update(
            _sampling_kwargs(
                kwargs.get("repetition_penalty"),
                kwargs.get("temperature"),
                kwargs.get("top_p"),
            )
        )
        gen_kwargs = {**inputs, **gen_kwargs}
        with paddle.no_grad():
            return parent_generate(self, **gen_kwargs)

    generate._ziji_sampling_patch = True
    cls.generate = generate
    cls._ziji_sampling_patched = True
    return True


def ensure_vl_sampling_support() -> str:
    """装上本地 VL 采样参数补丁（幂等）；返回人类可读结果供日志。

    依赖 paddleocr 环境里的 paddlex——导入失败（非 VL worker、测试环境）
    返回 'unavailable'，绝不抛错拖垮 worker 加载。"""
    global _installed, _result
    with _lock:
        if _installed:
            return _result
        try:
            predictor_mod = importlib.import_module(
                "paddlex.inference.models.doc_vlm.predictor"
            )
            model_mod = importlib.import_module(
                "paddlex.inference.models.doc_vlm.modeling.paddleocr_vl."
                "_paddleocr_vl"
            )
        except Exception:
            _installed = True
            _result = "unavailable"
            return _result
        ok_pred = _patch_local_predictor(predictor_mod)
        ok_model = _patch_model_generate(model_mod)
        if ok_pred and ok_model:
            _result = "installed"
        else:
            _result = f"partial (predictor={ok_pred}, model={ok_model})"
        _installed = True
        return _result
