# -*- coding: utf-8 -*-
"""表格识别 API（+83）：整页表格候选 / 手动区域表格识别。

两个端点全部只读——服务端不写 annotations，识别结果由 Flutter 端以
proposed 状态落盘，人工校对后进训练集（与版面区预标注同一哲学）。
"""
from typing import Optional

from fastapi import HTTPException
from pydantic import BaseModel

from api_base import app, _gated_recognition
from table_grid import detect_tables_in_page
from table_recognize import recognize_table


class DetectTablesRequest(BaseModel):
    image_path: str


class RecognizeTableRequest(BaseModel):
    image_path: str
    x: int
    y: int
    w: int
    h: int
    orientation: str = "vertical"
    horizontal_dir: str = "ltr"
    vertical_dir: str = "ttb"
    # 识别引擎（与整页识别同一口径：'kraken' 默认 | 'paddle' =
    # PaddleEngineAdapter，序列读法语境增强）。+161 表格识别接入引擎。
    engine: str = "kraken"
    paddle_model: Optional[str] = None
    # VL 书的解析配置/predict 参数（与 /read_page_text 同源——vl_config
    # 保证表格与文本视图共享同一个 VL 池；vl_predict 的 Prompt 类型被
    # spotting 强制覆盖，其余生成参数沿用）。
    vl_config: Optional[dict] = None
    vl_predict: Optional[dict] = None


@app.post("/detect_tables")
def detect_tables(req: DetectTablesRequest):
    """整页表格候选（rows≥2 且 cols≥2）：供预标注以 table 类 proposed
    候选区插入。界行/版框已被门槛挡掉，残余误报由人工拒绝。"""
    try:
        return {"tables": detect_tables_in_page(req.image_path)}
    except OSError:
        raise HTTPException(status_code=400, detail="image not found")
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/recognize_table")
@_gated_recognition("recognize_table")
def recognize_table_endpoint(req: RecognizeTableRequest):
    """手动标记区域的表格识别：格线网格 + 每格文字（格内方向自动判定，
    横竖版书页同一路径；引擎随请求——书里选了 PaddleOCR 时表格同样用
    Paddle 读法，不再固定 Kraken）。"""
    try:
        result = recognize_table(
            req.image_path, req.x, req.y, req.w, req.h,
            orientation=req.orientation,
            horizontal_dir=req.horizontal_dir,
            vertical_dir=req.vertical_dir,
            engine=req.engine,
            paddle_model=req.paddle_model,
            vl_config=req.vl_config,
            vl_predict=req.vl_predict,
        )
        if not result.get("ok"):
            raise HTTPException(status_code=422, detail=result.get("reason", "no grid"))
        return result
    except HTTPException:
        raise
    except OSError:
        raise HTTPException(status_code=400, detail="image not found")
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(exc))
