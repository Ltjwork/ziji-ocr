# -*- coding: utf-8 -*-
"""PaddleOCR 域路由：/paddle/*（模型清单 / 状态 / 探测下载 / 进程池）。"""
import os
from typing import Optional

from fastapi import HTTPException
from pydantic import BaseModel

from api_base import app
import paddle_bridge  # noqa: F401  (路由注册 + 引用)
import paddle_proc


@app.get("/paddle/models")
def paddle_models():
    """识别模型清单（含体积与配置要求文案，客户端下拉原样展示）。"""
    return {
        "models": paddle_proc.PP_OCRV6_MODELS,
        "default": paddle_proc.DEFAULT_MODEL,
        "current": paddle_proc.current_model(),
    }


@app.get("/paddle/status")
def paddle_status():
    """PaddleOCR 环境与进程池状态（设置页/引擎切换对话框数据源）。

    downloaded：已下载到本机官方缓存的模型名列表（纯磁盘检查，环境
    未装/池未起也能回答哪些档已就位）。"""
    python_path = ""
    installed = False
    error = ""
    try:
        python_path = paddle_proc.paddle_python()
        installed = True
    except Exception as exc:
        error = str(exc)
    return {
        "installed": installed,
        "python": python_path,
        "error": error,
        "pool_size": paddle_proc.pool_size(),
        "pool_busy": paddle_proc.pool_busy(),
        "current_model": paddle_proc.current_model(),
        "workers_env": (os.environ.get(paddle_proc.WORKERS_ENV) or "").strip(),
        "models": paddle_proc.PP_OCRV6_MODELS,
        "downloaded": sorted(paddle_proc.downloaded_models()),
    }


class PaddleProbeRequest(BaseModel):
    model: Optional[str] = None  # None = 当前/默认档


@app.post("/paddle/probe")
def paddle_probe(req: PaddleProbeRequest):
    """探测 paddleocr 环境并加载（首载含官方源自动下载）指定识别模型。

    客户端"下载/测试模型"按钮的后端：建/换绑定该模型的池并 ping 就绪。
    首次下载视网速可达数分钟（medium 73.3MB），客户端超时要给足。"""
    try:
        return paddle_proc.probe(req.model)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"PaddleOCR 探测失败: {exc}")


class PaddleDownloadRequest(BaseModel):
    model: Optional[str] = None  # None = 默认档


@app.post("/paddle/download")
def paddle_download(req: PaddleDownloadRequest):
    """下载/校验指定模型，不影响正在使用的进程池（设置页逐档下载）。

    一次性临时 daemon 加载该模型（首载自动下载到官方缓存），就绪即关；
    已下载时等价于一次加载自检。含下载可达数分钟，客户端超时要给足。"""
    try:
        return paddle_proc.download_model(req.model)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"PaddleOCR 模型下载失败: {exc}")


class PaddlePoolResizeRequest(BaseModel):
    workers: Optional[int] = None  # None = 清除覆写，回到默认 1


@app.post("/paddle/pool/resize")
def paddle_pool_resize(req: PaddlePoolResizeRequest):
    """按给定并行数重建 PaddleOCR 进程池。识别进行中拒绝（409）。"""
    if paddle_proc.pool_busy() > 0:
        raise HTTPException(
            status_code=409,
            detail="识别正在进行中，请等识别结束后再重建进程池",
        )
    try:
        return paddle_proc.resize(req.workers)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
