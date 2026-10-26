# -*- coding: utf-8 -*-
"""整页直读域路由：/read_page_text（PaddleOCR 全管线 / Kraken blla，
不走主区/段落/单行/单字标注管线；客户端「文本」视图的数据源）。"""
import os
import time
from typing import List, Optional

from fastapi import HTTPException
from pydantic import BaseModel

from api_base import app, _gated_recognition
from api_segment import GateRegion
from imaging import imread_unicode
import kraken_bridge
import paddle_bridge
import read_progress
from seg_layout import REGION_EXCLUDED_LABELS, detect_main_regions, region_label


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
    # 文本视图「排除页眉页脚」开关：开 = 识别后剔除落在排除类版面区
    # （页眉/页脚/页码/插图/表格/卦图）内的行。VL 模型自身的辅助内容
    # 忽略走 vl_predict.markdown_ignore_labels，两套开关互不影响。
    exclude_header_footer: bool = False
    # 排除开关开启时随请求带入的人工已确认版面区（/segment 的
    # gate_regions 同款输入）：非空时优先于 region_det 模型预检——
    # 模型未训出也能按用户画的页眉/页脚/页码区门控。
    gate_regions: Optional[List[GateRegion]] = None
    # 进度登记 token（客户端每次识别随机生成）：传入后服务端在准备引擎/
    # 读字/拼接各阶段打点，客户端凭它轮询 /read_page_progress 展示进度；
    # 缺省 = 不登记（历史行为）。VL 直读是一次整页推理，粒度为阶段+用时。
    progress_token: Optional[str] = None


def _gate_regions_for(
    req: ReadPageTextRequest, progress_token: str
) -> Optional[List[dict]]:
    """排除开关开启时算出门控区输入；None = 无安全边界，不过滤。

    人工确认区优先（与 seg_pipeline 区域门控同规则）；否则跑 region_det
    预检，模型不可用返回 None（退回整页识别，不强切）。"""
    if not req.exclude_header_footer:
        return None
    read_progress.set_stage(
        progress_token, "gating", "版面区检测与页眉页脚排除过滤中…"
    )
    human = [g.model_dump() for g in (req.gate_regions or [])]
    if human:
        print(
            f"[read_page_text] 排除页眉页脚：用 {len(human)} 个人工确认版面区门控",
            flush=True,
        )
        return human
    img = imread_unicode(req.image_path)
    if img is None:
        print("[read_page_text] 排除页眉页脚：页图读不出，跳过门控", flush=True)
        return None
    h, w = img.shape[:2]
    regions = detect_main_regions(req.image_path, w, h)
    if regions is None:
        print(
            "[read_page_text] 排除页眉页脚：region_det 不可用，退回整页不过滤",
            flush=True,
        )
        return None
    print(
        f"[read_page_text] 排除页眉页脚：region_det 检出 {len(regions)} 个版面区",
        flush=True,
    )
    return regions


@app.get("/read_page_progress")
def read_page_progress(token: str = ""):
    """整页直读进度查询（客户端识别中每秒轮询）。

    返回 {active, stage, detail, engine, elapsed_s}；token 未知或该次
    识别已结束返回 {"active": false}。进度粒度为阶段 + 已用时（VL 是
    一整页一次推理，无逐行百分比）。"""
    return read_progress.get(token)


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
    token = req.progress_token or ""
    if token:
        read_progress.start(
            token, engine=req.engine, detail="准备识别引擎与模型…"
        )
    try:
        gate_regions = _gate_regions_for(req, token)
        if req.engine == "paddle":
            result = paddle_bridge.read_page_text(
                req.image_path,
                req.orientation,
                req.horizontal_dir,
                req.vertical_dir,
                model=req.paddle_model,
                vl_config=req.vl_config,
                vl_predict=req.vl_predict,
                gate_regions=gate_regions,
                progress_token=token or None,
            )
        else:
            result = kraken_bridge.read_page_text(
                req.image_path,
                req.orientation,
                req.horizontal_dir,
                req.vertical_dir,
                gate_regions=gate_regions,
                progress_token=token or None,
            )
    except Exception as exc:
        print(f"[read_page_text] error: {exc}", flush=True)
        raise HTTPException(status_code=500, detail=str(exc))
    finally:
        # 成败都清登记：客户端下次轮询拿到 active=false 即停表。
        read_progress.finish(token)
    result["elapsed_s"] = round(time.time() - started, 1)
    # 门控元信息（客户端状态栏如实展示本次是否真的排除了内容）：
    # excluded_regions = 参与过滤的排除类区数（0 = 没有可用版面区，开
    # 关没实际生效）；excluded_lines = 剔除的行数（桥回传，缺省 0）。
    result["excluded_regions"] = (
        sum(
            1
            for r in (gate_regions or [])
            if region_label(r) in REGION_EXCLUDED_LABELS
            and r.get("status") != "rejected"
        )
        if gate_regions is not None
        else 0
    )
    result.setdefault("excluded_lines", 0)
    print(
        f"[read_page_text] {req.engine} ok lines={len(result.get('lines') or [])} "
        f"chars={len(result.get('text') or '')} "
        f"excluded={result['excluded_lines']}/{result['excluded_regions']}区 "
        f"in {result['elapsed_s']}s",
        flush=True,
    )
    return result
