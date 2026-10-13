# -*- coding: utf-8 -*-
"""朝代基准评测域路由（从 main.py 拆出）：古籍分时期样张的识别评测与历史。

识别执行在 Flutter 端（与整本识别同链路），这里收拼好文字的评测请求；
口径与落盘见 dynasty_bench.py 模块注释。"""
from typing import Any, Dict, List, Optional

from fastapi import HTTPException
from pydantic import BaseModel

from api_base import app
import dynasty_bench


class BenchPredItem(BaseModel):
    id: str
    # 识别端拼好的全篇预测文字（阅读顺序任意空白分隔均可，评测前归一）
    pred_text: str = ""
    line_count: Optional[int] = None
    duration_ms: Optional[int] = None
    error: Optional[str] = None
    # 人工查看明细（行框/字框/逐字置信度），Dart 侧产消、Python 原样
    # 存档进 run 记录（格式基准声明见 dynasty_bench._case_report）。
    lines: Optional[List[Dict[str, Any]]] = None
    # 管线元信息（/segment 响应元数据 + AI 整行裁决状态）：engine=hier
    # 为自训 YOLO 层级 / opencv 为回退（fallback_reason 给原因）；yolo
    # 为字模诊断；ai_assist.status ∈ applied/skipped-no-model/
    # skipped-toggle（历史记录里可能还有早期版本的 skipped-settings /
    # skipped-error-* 值，按未知值展示）。同样原样存档不解释。
    engine: Optional[str] = None
    fallback_reason: Optional[str] = None
    converter: Optional[str] = None
    yolo: Optional[Dict[str, Any]] = None
    ai_assist: Optional[Dict[str, Any]] = None


class BenchEvalRequest(BaseModel):
    bench_dir: str
    preds: List[BenchPredItem]


@app.get("/bench/dynasty/cases")
def bench_dynasty_cases(bench_dir: str):
    """基准样张清单（含 GT 释文与阅读方向），供测试界面展示。"""
    try:
        return {"cases": dynasty_bench.load_cases(bench_dir)}
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc))


@app.post("/bench/dynasty/eval")
def bench_dynasty_eval(req: BenchEvalRequest):
    """对齐评测一次运行并落盘历史记录，返回完整运行记录。"""
    try:
        return dynasty_bench.evaluate(
            req.bench_dir,
            [p.model_dump() for p in req.preds],
        )
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    except KeyError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@app.get("/bench/dynasty/runs")
def bench_dynasty_runs(bench_dir: str, limit: int = 50) -> dict[str, Any]:
    """历史运行摘要（新→旧）；完整记录按 path 字段直接读文件。"""
    return {"runs": dynasty_bench.list_runs(bench_dir, limit=limit)}
