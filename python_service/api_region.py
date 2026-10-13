# -*- coding: utf-8 -*-
"""版面区预标注 API：规则预标注 / 区域几何精修 / VLM 整页素材图。

多类 region_det（main_text/header/footer/page_number/margin_note）的
标注提效链路。三个端点全部只读——服务端从不写 annotations 目录，建议/
精修结果由 Flutter 端以 proposed 状态落盘，人工确认后进训练集。
"""
from typing import List, Optional

from fastapi import HTTPException
from pydantic import BaseModel

import region_prelabel
from api_base import app


class RegionPrelabelRequest(BaseModel):
    project_dir: str
    page_id: str


class RegionRefineItem(BaseModel):
    x: int
    y: int
    w: int
    h: int
    label: str = "main_text"
    confidence: Optional[float] = None


class RegionRefineRequest(BaseModel):
    image_path: str
    regions: List[RegionRefineItem]


class PagePrelabelImageRequest(BaseModel):
    image_path: str
    max_side: int = 1536  # 长边上限（与 AI 行条图同档，钳制 256~2048）
    regions: List[RegionRefineItem] = []  # 已有区域（画底色提示 VLM 别重标）
    grid_div: int = 8  # 网格密度（钳 4~32）：版面区 8 格够用，字框级锚点用 16


# 处理函数名不得与模块 region_prelabel 同名：def 会把全局名从模块重绑成
# 函数，函数体内的 region_prelabel.suggest_regions 就变成查函数自身属性，
# 每次调用必 500（HTTP 层回归测试 lock 住这一点）。
@app.post("/region_prelabel")
def region_prelabel_endpoint(req: RegionPrelabelRequest):
    """规则 + 跨页一致性预标注建议（只读，返回 proposed 候选区）。"""
    try:
        return region_prelabel.suggest_regions(req.project_dir, req.page_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@app.post("/region_refine")
def region_refine(req: RegionRefineRequest):
    """粗框几何精修：钳图内、词表校验、墨迹收紧、近重复去除（VLM 坐标
    安全层——语义归模型，像素归几何）。"""
    if not req.regions:
        return {"regions": [], "dropped": []}
    if len(req.regions) > 100:
        raise HTTPException(status_code=400, detail="too many regions (max 100)")
    try:
        return region_prelabel.refine_regions(
            req.image_path, [r.dict() for r in req.regions])
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@app.post("/page_prelabel_image")
def page_prelabel_image(req: PagePrelabelImageRequest):
    """VLM 整页预标注素材图（降采样 + 网格坐标刻度 + 已有区域底色）。"""
    try:
        return region_prelabel.prelabel_page_image(
            req.image_path, [r.dict() for r in req.regions], req.max_side,
            grid_div=req.grid_div)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
