# -*- coding: utf-8 -*-
"""调试 trace 设施（从 segmenter 拆出）：按请求（ContextVar）隔离的调试日志
与异常摘要，最底层模块。segmenter.py 仍为门面。"""
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



# 调试日志按请求（上下文）隔离：/segment 在处理开始时 begin_debug_trace()
# 换一个新列表，本请求内的所有写入（含 kraken_bridge 经 copy_context 派生
# 的行任务线程）都落进该列表；未 begin 的上下文（后台线程/测试）回落到
# 模块级共享列表——与单请求串行时代的旧行为一致。
_TRACE_DEFAULT: list[str] = []


_DEBUG_TRACE: ContextVar = ContextVar("debug_trace", default=None)




def _trace_list() -> list[str]:
    lst = _DEBUG_TRACE.get()
    return lst if lst is not None else _TRACE_DEFAULT




def _append_trace(message: str) -> None:
    lst = _trace_list()
    lst.append(message)
    if len(lst) > 500:
        del lst[:-500]




def _log(message: str):
    _append_trace(message)
    print(message, flush=True)




def begin_debug_trace():
    """开启一段新的调试日志（当前上下文及其 copy_context 派生任务可见）。"""
    _DEBUG_TRACE.set([])




def debug_trace_snapshot() -> list[str]:
    return list(_trace_list())




def append_debug_trace(message: str) -> None:
    """外部模块（kraken_bridge 等）向调试日志追加一行（不重复打印）。"""
    _append_trace(message)




def _exception_summary(exc: Exception) -> str:
    return f"{type(exc).__name__}: {exc}"
