# -*- coding: utf-8 -*-
"""PaddleOCR 识别 daemon——在独立的 paddleocr conda 环境中常驻运行，被
paddle_bridge/paddle_proc 调起。

协议（stdin/stdout，均为单行 JSON，UTF-8）——与 kraken_worker 同款框架：
  请求：{"id": int, "op": "ping" | "recognize" | "read_boxes" | "read_strip"
         | "shutdown", "payload": {...}}
  响应：{"id": int, "ok": true, "result": {...}} 或
        {"id": int, "ok": false, "error": "...", "traceback": "..."}

  recognize  payload：{"image_path", "scale", "text_direction", "per_line",
                       "lines": [{"x","y","w","h"}, ...]}
             result：{"lines": [{"x","y","w","h","text","conf","chars": []}]}
             只对横排行出文本（PP-OCR 识别模型的域）；竖排行返回空文本——
             桥接层对竖排不会调这个 op（见下）。
  read_boxes payload：{"image_path", "boxes": [{"x","y","w","h"}, ...]}
             result：{"lines": [...]}——每个框当独立"单字"直读（框坐标原样
             回带，与输入同序）。
  read_strip payload：{"image_path", "rect": {...}, "boxes": [...]}
             result：{"text", "conf"}——竖排整行序列读法：按输入顺序逐字
             裁剪、等高拼成横条图再整条读。

与 kraken_worker 的关键差异：
- 只装识别模型（paddleocr.TextRecognition）；版面/行/字框由服务端 YOLO 与
  像素切分器给出。
- 不做 nlbin 二值化：PP-OCR 期望原始灰度/彩色输入，二值化会伤读法。
- PP-OCR 识别模型只有横排域：竖排行直接旋转会把直立字形放倒、读出乱码，
  整行序列读法由 read_strip 的"字框裁剪→等高拼横条"实现（拼条里字形
  全部直立，落在模型分布内）。
- 无 cuts：line 结果的 chars 恒为空，字框几何由服务端像素切分器/均分条带
  给出（kraken 的 cuts 兜底在 paddle 桥接层换成均分条带）。

模型在启动时加载一次并常驻（首次加载会自动从官方源下载到 ~/.paddlex 等
用户缓存，pong/ping 就绪即代表模型已可用）；进度日志全部走 stderr，stdout
只允许出现协议响应。stdin 关闭（父进程退出）时 daemon 自行退出。
"""

from __future__ import annotations

import json
import os
import sys
import time
import traceback

from PIL import Image

DEFAULT_MODEL = "PP-OCRv6_small_rec"

# 单字/拼条的统一高度目标：PP-OCR 识别输入高度 48px，64 留一点清晰度裕量；
# 源字更高（大图扫描）时保持原高不缩小。
TARGET_CHAR_H = 64

# 拼条字间留白（像素）：模拟真实横行的字间距，避免相邻字粘连误读。
STRIP_GAP = 12

_T0 = time.time()
_TAG = os.environ.get("PADDLE_WORKER_ID", "")
_MODEL_NAME = os.environ.get("PADDLE_REC_MODEL", "").strip() or DEFAULT_MODEL
_DEVICE: str | None = None

# 致命（粘性）CUDA 错误标记（与 kraken_worker 同款判定，双保险）。
_FATAL_CUDA_MARKERS = (
    "cuda error",
    "illegal memory access",
    "cudaerrorillegaladdress",
    "device-side assert",
)


def _is_fatal_cuda_error(text: str) -> bool:
    lowered = (text or "").lower()
    if "out of memory" in lowered:
        return False
    return any(marker in lowered for marker in _FATAL_CUDA_MARKERS)


def tlog(msg: str) -> None:
    """带相对时间戳的进度日志：走 stderr（stdout 是协议通道）。"""
    tag = f":{_TAG}" if _TAG else ""
    print(
        f"[paddle-worker{tag} +{time.time() - _T0:7.1f}s] {msg}",
        file=sys.stderr,
        flush=True,
    )


def _crop(page_im, rect: dict, pad: int = 0):
    """按框裁剪（可外扩 pad 像素），收进图像界内。返回 None 表示空框。"""
    x = int(rect.get("x", 0))
    y = int(rect.get("y", 0))
    w = int(rect.get("w", 0))
    h = int(rect.get("h", 0))
    if pad:
        x, y = x - pad, y - pad
        w, h = w + pad * 2, h + pad * 2
    x0, y0 = max(0, x), max(0, y)
    x1 = min(page_im.width, x + w)
    y1 = min(page_im.height, y + h)
    if x1 - x0 < 2 or y1 - y0 < 2:
        return None
    return page_im.crop((x0, y0, x1, y1))


def _upscale_small(im, min_side: int = TARGET_CHAR_H, limit: float = 4.0):
    """窄边过小的裁剪放大到 min_side（识别网络输入下限附近），过大的不动。"""
    short = min(im.width, im.height)
    if short >= min_side or short <= 0:
        return im
    factor = min(limit, min_side / short)
    return im.resize(
        (max(1, int(im.width * factor)), max(1, int(im.height * factor))),
        Image.LANCZOS,
    )


def _predict_entries(model, images: list) -> list[tuple[str, float]]:
    """批量识别，与输入同序返回 [(text, conf), ...]。

    传入 ndarray 按 cv2/BGR 约定（paddleocr 内部按 BGR 处理）。
    结果对象各版本形态略有差异（{'res': {...}} 包装或直接字段），按多种
    形态取值，取不到按空文本处理——识别失败不该拖垮整个请求。"""
    import numpy as np

    arrays = [np.asarray(im.convert("RGB"))[:, :, ::-1].copy() for im in images]
    results = list(model.predict(input=arrays, batch_size=min(len(arrays), 8)))
    out: list[tuple[str, float]] = []
    for res in results:
        data = None
        if isinstance(res, dict):
            data = res.get("res") if isinstance(res.get("res"), dict) else res
        else:
            data = getattr(res, "res", None)
            if not isinstance(data, dict):
                data = None
        data = data or {}
        try:
            text = str(data.get("rec_text") or "")
        except Exception:
            text = ""
        try:
            conf = float(data.get("rec_score") or 0.0)
        except Exception:
            conf = 0.0
        out.append((text, conf))
    return out


def _empty_line(rect: dict) -> dict:
    return {
        "x": int(rect.get("x", 0)),
        "y": int(rect.get("y", 0)),
        "w": int(rect.get("w", 0)),
        "h": int(rect.get("h", 0)),
        "text": "",
        "conf": 0.0,
        "chars": [],
    }


def _op_recognize(model, payload: dict) -> dict:
    """行读法（横排直读；竖排按协议返回空文本——桥接层对竖排走 read_strip）。"""
    image_path = payload["image_path"]
    text_direction = str(payload.get("text_direction", "vertical-rl"))
    rects = payload.get("lines") or []
    horizontal = text_direction.startswith("horizontal")
    im = Image.open(image_path).convert("RGB")

    out: list[dict | None] = [None] * len(rects)
    pending: list[tuple[int, dict]] = []
    crops: list = []
    for i, rect in enumerate(rects):
        if not horizontal:
            out[i] = _empty_line(rect)
            continue
        crop = _crop(im, rect, pad=8)
        if crop is None:
            out[i] = _empty_line(rect)
            continue
        crops.append(_upscale_small(crop))
        pending.append((i, rect))
    if crops:
        entries = _predict_entries(model, crops)
        for (i, rect), (text, conf) in zip(pending, entries):
            out[i] = {
                "x": int(rect["x"]),
                "y": int(rect["y"]),
                "w": int(rect["w"]),
                "h": int(rect["h"]),
                "text": text,
                "conf": round(float(conf), 4),
                "chars": [],
            }
    return {"lines": [v if v is not None else _empty_line({}) for v in out]}


def _op_read_boxes(model, payload: dict) -> dict:
    """逐字框直读：每个框当独立的单字（极短横行）批量识别。"""
    im = Image.open(payload["image_path"]).convert("RGB")
    boxes = payload.get("boxes") or []
    out: list[dict] = []
    crops: list = []
    pending: list[dict] = []
    for rect in boxes:
        crop = _crop(im, rect)
        if crop is None:
            out.append(_empty_line(rect))
            continue
        crops.append(_upscale_small(crop))
        pending.append(rect)
    if crops:
        for rect, (text, conf) in zip(pending, _predict_entries(model, crops)):
            out.append(
                {
                    "x": int(rect["x"]),
                    "y": int(rect["y"]),
                    "w": int(rect["w"]),
                    "h": int(rect["h"]),
                    "text": text,
                    "conf": round(float(conf), 4),
                    "chars": [],
                }
            )
    return {"lines": out}


def _op_read_strip(model, payload: dict) -> dict:
    """竖排整行序列读法：按输入顺序逐字裁剪 → 等高拼横条 → 整条识别。

    输入 boxes 即桥接层像素切分/人工框（阅读序），拼条内字形全部直立，
    落在 PP-OCR 横排识别模型的分布内；单字读法之外的独立第二路读法，
    供融合层（_fuse_line_chars）对齐裁决。少于 2 个框拼不出序列，返回空。"""
    im = Image.open(payload["image_path"]).convert("RGB")
    boxes = payload.get("boxes") or []
    if len(boxes) < 2:
        return {"text": "", "conf": 0.0}

    crops: list = []
    for rect in boxes:
        crop = _crop(im, rect)
        if crop is None:
            continue
        crops.append(crop)
    if len(crops) < 2:
        return {"text": "", "conf": 0.0}

    # 等高归一：以字高中位数为基准（个别噪点框过高/过矮不拉动整体），
    # 不低于 TARGET_CHAR_H（过小则统一放大）。
    heights = sorted(c.height for c in crops)
    target_h = int(max(TARGET_CHAR_H, heights[len(heights) // 2]))
    target_h = min(target_h, 320)  # 防御：异常高框不无限放大拼条
    pieces = []
    for crop in crops:
        if crop.height <= 0:
            continue
        pieces.append(
            crop.resize(
                (max(1, int(crop.width * target_h / crop.height)), target_h),
                Image.LANCZOS,
            )
        )
    if len(pieces) < 2:
        return {"text": "", "conf": 0.0}

    strip_w = sum(p.width for p in pieces) + STRIP_GAP * (len(pieces) - 1)
    strip = Image.new("RGB", (strip_w, target_h), (255, 255, 255))
    offset = 0
    for piece in pieces:
        strip.paste(piece, (offset, 0))
        offset += piece.width + STRIP_GAP
    text, conf = _predict_entries(model, [strip])[0]
    tlog(f"strip read: {len(pieces)} chars -> {len(text)} chars")
    return {"text": text, "conf": round(float(conf), 4)}


def _load_model():
    from paddleocr import TextRecognition

    global _DEVICE
    device = "gpu"
    try:
        import paddle

        if not paddle.is_compiled_with_cuda():
            device = "cpu"
    except Exception:
        device = "cpu"
    tlog(f"load model: {_MODEL_NAME} (device={device})")
    t0 = time.time()
    try:
        model = TextRecognition(model_name=_MODEL_NAME, device=device)
    except Exception as exc:
        if device == "gpu":
            tlog(f"gpu load failed ({exc}), fallback to cpu")
            device = "cpu"
            model = TextRecognition(model_name=_MODEL_NAME, device=device)
        else:
            raise
    _DEVICE = device
    tlog(f"model loaded on {device} in {time.time() - t0:.1f}s, waiting for requests")
    return model


def _release_vram_cache() -> None:
    """请求结束后归还 paddle 缓存显存（与 kraken worker 的 torch.empty_cache
    同动机：防止显存棘轮式上涨打满整卡）。"""
    if _DEVICE != "gpu":
        return
    try:
        import paddle

        paddle.device.cuda.empty_cache()
    except Exception:
        pass


_OPS = {
    "recognize": _op_recognize,
    "read_boxes": _op_read_boxes,
    "read_strip": _op_read_strip,
}


def _write_response(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def daemon_loop() -> int:
    model = _load_model()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req_id = None
        try:
            req = json.loads(line)
            req_id = req.get("id")
            op = req.get("op", "recognize")
            if op == "ping":
                _write_response(
                    {
                        "id": req_id,
                        "ok": True,
                        "result": {
                            "pong": True,
                            "device": _DEVICE,
                            "model": _MODEL_NAME,
                        },
                    }
                )
            elif op == "shutdown":
                _write_response({"id": req_id, "ok": True, "result": {"bye": True}})
                tlog("shutdown requested, daemon exit")
                return 0
            else:
                handler = _OPS.get(op)
                if handler is None:
                    raise ValueError(f"unknown op: {op}")
                try:
                    result = handler(model, req.get("payload") or {})
                finally:
                    _release_vram_cache()
                _write_response({"id": req_id, "ok": True, "result": result})
        except Exception as exc:
            tlog(f"request failed: {exc}")
            _write_response(
                {
                    "id": req_id,
                    "ok": False,
                    "error": f"{exc}",
                    "traceback": traceback.format_exc(),
                }
            )
            if _is_fatal_cuda_error(f"{exc}"):
                tlog("致命 CUDA 错误（上下文已损坏），daemon 退出等待服务端重启")
                return 1
    tlog("stdin closed (parent exited), daemon exit")
    return 0


if __name__ == "__main__":
    sys.exit(daemon_loop())
