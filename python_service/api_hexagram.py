# -*- coding: utf-8 -*-
"""卦图识别 API（易经卦图电子化）：整页卦画候选 / 区域卦图识别。

两个端点全部只读——服务端不写 annotations，识别结果（结构化记录 +
切片 + 校验）由插件/前端以 proposed 状态自行落盘，人工校对后确认
（与表格识别、版面区预标注同一哲学）。消费方是易经卦图插件
（.zjplugin，经 backend.post 桥调用），也可被编辑器直接接入。
"""
from typing import Optional

from fastapi import HTTPException
from pydantic import BaseModel

from api_base import app, _gated_recognition
from hexagram_chart import detect_hexagrams_in_page_with_diag
from hexagram_recognize import recognize_hexagram


class DetectHexagramsRequest(BaseModel):
    image_path: str


class RecognizeHexagramRequest(BaseModel):
    image_path: str
    x: int
    y: int
    w: int
    h: int
    # 识别引擎（与整页识别/表格识别同一口径：'kraken' 默认 | 'paddle'）。
    engine: str = "kraken"
    paddle_model: Optional[str] = None


@app.post("/detect_hexagrams")
def detect_hexagrams(req: DetectHexagramsRequest):
    """整页卦画候选（六爻条堆）：返回含左右标注的扩展框，供插件/预标注
    挑选（候选缩略图可另调 /char_thumbnails）。候选只是 proposed，误报
    由人工拒绝。diag 附检测诊断（斜切角/逐核条段统计），空结果时前端
    可展示以定位原因。"""
    try:
        hexagrams, diag = detect_hexagrams_in_page_with_diag(req.image_path)
        return {"hexagrams": hexagrams, "diag": diag}
    except OSError:
        raise HTTPException(status_code=400, detail="image not found")
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/recognize_hexagram")
@_gated_recognition("recognize_hexagram")
def recognize_hexagram_endpoint(req: RecognizeHexagramRequest):
    """手动区域卦图识别：几何阴阳 + 干支逐字读 + 领域校验 + 切片/SVG
    重绘（切片↔重绘对照校对）。"""
    try:
        result = recognize_hexagram(
            req.image_path, req.x, req.y, req.w, req.h,
            engine=req.engine, paddle_model=req.paddle_model,
        )
        if not result.get("ok"):
            raise HTTPException(
                status_code=422, detail=result.get("reason", "no hexagram")
            )
        return result
    except HTTPException:
        raise
    except OSError:
        raise HTTPException(status_code=400, detail="image not found")
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(exc))
