# -*- coding: utf-8 -*-
"""整页直读域路由：/read_page_text（PaddleOCR 全管线 / Kraken blla，
不走主区/段落/单行/单字标注管线；客户端「文本」视图的数据源）。"""
import os
import time
from typing import Optional

from fastapi import HTTPException
from pydantic import BaseModel

from api_base import app, _gated_recognition
import kraken_bridge
import paddle_bridge


class ReadPageTextRequest(BaseModel):
    image_path: str
    orientation: str = "vertical"
    horizontal_dir: str = "ltr"
    vertical_dir: str = "ttb"
    engine: str = "kraken"  # 'kraken' | 'paddle'
    paddle_model: Optional[str] = None
    # VL 模型的解析配置（官网演示同款开关，见 paddle_proc.VL_CONFIG_KEYS）；
    # 非 VL 模型忽略。书级设置，随请求传入。
    vl_config: Optional[dict] = None
    # VL 模型的 predict 级参数（Prompt 类型/生成参数/辅助内容忽略清单，
    # 见 paddle_worker._vl_predict_kwargs 白名单）；随每次请求，不换池。
    vl_predict: Optional[dict] = None


@app.post("/read_page_text")
@_gated_recognition("read_page_text")
def read_page_text(req: ReadPageTextRequest):
    """整页直读：引擎自己分行读字，返回按阅读序拼接的整页文本与行列表。

    与 /segment 的区别：不做主区/段落/行/字的检测切分、不产标注框、
    不融合逐字读法——纯文本输出（编辑器「文本」视图的文本框内容，
    供快速通读与 AI 校对，标注校对走原管线互不影响）。"""
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    print(
        f"[read_page_text] path={req.image_path!r} engine={req.engine} "
        f"orientation={req.orientation}",
        flush=True,
    )
    started = time.time()
    try:
        if req.engine == "paddle":
            result = paddle_bridge.read_page_text(
                req.image_path,
                req.orientation,
                req.horizontal_dir,
                req.vertical_dir,
                model=req.paddle_model,
                vl_config=req.vl_config,
                vl_predict=req.vl_predict,
            )
        else:
            result = kraken_bridge.read_page_text(
                req.image_path,
                req.orientation,
                req.horizontal_dir,
                req.vertical_dir,
            )
    except Exception as exc:
        print(f"[read_page_text] error: {exc}", flush=True)
        raise HTTPException(status_code=500, detail=str(exc))
    result["elapsed_s"] = round(time.time() - started, 1)
    print(
        f"[read_page_text] {req.engine} ok lines={len(result.get('lines') or [])} "
        f"chars={len(result.get('text') or '')} in {result['elapsed_s']}s",
        flush=True,
    )
    return result
