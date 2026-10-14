# -*- coding: utf-8 -*-
"""PaddleOCR 识别 daemon——在独立的 paddleocr conda 环境中常驻运行，被
paddle_bridge/paddle_proc 调起。

协议（stdin/stdout，均为单行 JSON，UTF-8）——与 kraken_worker 同款框架：
  请求：{"id": int, "op": "ping" | "recognize" | "read_boxes" | "read_strip"
         | "read_line" | "read_page" | "detect_lines" | "shutdown",
         "payload": {...}}
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

# PaddleOCR-VL 视觉语言模型（0.9B）：整页直读专用管线（版面+VL 识别），
# 不是 TextRecognition 单模型——行/字识别 op（recognize/read_boxes/
# read_strip）不支持，worker 明确拒绝；只有 read_page 走 VL 分支。
# 1.6 为当前主推版本（paddleocr 3.7 默认），v1/1.5 同族兼容一并接受。
VL_MODEL_NAMES = ("PaddleOCR-VL", "PaddleOCR-VL-1.5", "PaddleOCR-VL-1.6")
_VL_PIPELINE_VERSION = {
    "PaddleOCR-VL": "v1",
    "PaddleOCR-VL-1.5": "v1.5",
    "PaddleOCR-VL-1.6": "v1.6",
}


def _is_vl_model() -> bool:
    return _MODEL_NAME in VL_MODEL_NAMES


def _vl_reject() -> None:
    raise ValueError(
        "PaddleOCR-VL 视觉语言模型仅支持整页直读（文本视图）；"
        "行/单字识别请选择 PP-OCR 系模型（如 PP-OCRv6_small_rec）"
    )


def _vl_config() -> dict:
    """VL 解析配置（池经 PADDLE_VL_CONFIG 注入的 JSON；缺省=全关 +
    merge_blocks 开的历史行为）。白名单键防御：未知键不透传。"""
    raw = os.environ.get("PADDLE_VL_CONFIG", "").strip()
    if not raw:
        return {
            "use_doc_orientation_classify": False,
            "use_doc_unwarping": False,
            "use_layout_detection": False,
            "use_chart_recognition": False,
            "use_seal_recognition": False,
            "use_ocr_for_image_block": False,
            "merge_layout_blocks": True,
        }
    try:
        cfg = json.loads(raw)
    except Exception:
        cfg = {}
    allowed = {
        "use_doc_orientation_classify",
        "use_doc_unwarping",
        "use_layout_detection",
        "use_chart_recognition",
        "use_seal_recognition",
        "use_ocr_for_image_block",
        "merge_layout_blocks",
    }
    return {k: bool(v) for k, v in cfg.items() if k in allowed}

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
        data = _result_data(res)
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


def _result_data(res) -> dict:
    """paddleocr 结果对象 → 字段 dict（{'res': {...}} 包装或直接字段）。"""
    if isinstance(res, dict):
        inner = res.get("res")
        return inner if isinstance(inner, dict) else res
    data = getattr(res, "res", None)
    return data if isinstance(data, dict) else {}


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
    if _is_vl_model():
        _vl_reject()
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
    if _is_vl_model():
        _vl_reject()
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
    if _is_vl_model():
        _vl_reject()
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


# 整页直读用的完整 OCR 管线（det+rec）：懒建，与 TextRecognition 并存。
_PIPELINE = None


def _get_pipeline():
    """构造/取整页直读管线：检测模型跟随本 daemon 绑定的识别档位
    （PP-OCRv6_<tier>_rec → PP-OCRv6_<tier>_det，首次构造自动下载）。

    PP-OCRv5 起检测+识别原生支持竖排文本，整页直读无需旋转页面。
    VL daemon 没有对应的 det/rec 档位——混合直读的几何管线固定用
    small 档（只要行框，行文本由 VL 给出，rec 结果丢弃）。"""
    global _PIPELINE
    if _PIPELINE is None:
        from paddleocr import PaddleOCR

        if _is_vl_model():
            det_name = "PP-OCRv6_small_det"
            rec_name = "PP-OCRv6_small_rec"
        else:
            det_name = f"{_MODEL_NAME.rsplit('_rec', 1)[0]}_det"
            rec_name = _MODEL_NAME
        device = _DEVICE or "gpu"
        tlog(f"init full pipeline: det={det_name} rec={rec_name} (device={device})")
        t0 = time.time()
        _PIPELINE = PaddleOCR(
            text_detection_model_name=det_name,
            text_recognition_model_name=rec_name,
            use_doc_orientation_classify=False,
            use_doc_unwarping=False,
            use_textline_orientation=False,
            device=device,
        )
        tlog(f"full pipeline ready in {time.time() - t0:.1f}s")
    return _PIPELINE


# ── 直读标点诊断（只记日志，不参与识别结果）────────────────────────────
# 古籍影印本的句读/圈点多为印在字间空隙的小号墨块（约 0.4 字高）：det 行框
# 包得住它们，但 PP-OCRv6 rec 按现代排版训练（标点与正字同高），整行识别
# 时系统性跳过这类小符号——加大 det 外扩、放大图片均无效（实测记录见
# CHANGELOG 1.0.0+188）。直读日志把"文本里读出的标点数 vs 行框裁图内
# 检出的小墨块数（疑似标点）"并排打出，每次直读丢标点的规模一眼可量化；
# cv2/PIL 缺失或图异常时诊断降级跳过，绝不影响识别路径。

_PUNCT_CHARS = set("，。、；：！？·—…「」『』（）《》〈〉")


def _small_mark_count(crop_gray):
    """统计行裁图内的"小墨块"（疑似标点）：连通域里高度 < 0.6×中位字高、
    宽度 < 1×中位字高且面积达标的分量。返回 (小墨块数, 参与统计的分量数)；
    依赖缺失/图过小返回 None（诊断尽力而为）。"""
    try:
        import cv2
        import numpy as np
    except Exception:
        return None
    try:
        arr = np.asarray(crop_gray)
        h, w = arr.shape[:2]
        if w < 16 or h < 16:
            return None
        ink = (arr < 180).astype("uint8")
        _n, _lab, stats, _cent = cv2.connectedComponentsWithStats(
            ink, connectivity=8
        )
        comps = [s for s in stats[1:] if s[4] >= 60 and s[2] >= 4 and s[3] >= 4]
        if len(comps) < 3:
            return None
        heights = sorted(s[3] for s in comps)
        char_h = heights[len(heights) // 2]
        small = sum(1 for s in comps if s[3] < char_h * 0.6 and s[2] < char_h)
        return small, len(comps)
    except Exception:
        return None


def _log_mark_stats(lines: list, image_path: str) -> None:
    """整页直读的标点统计日志：文本标点数 vs 检出小墨块数（疑似被模型
    跳过的标点）。只走 stderr 日志，任何失败都不上抛。"""
    try:
        from PIL import Image

        im = Image.open(image_path).convert("L")
    except Exception as exc:
        tlog(f"mark stats: image unavailable ({exc})")
        return
    text_punct = 0
    blob_total = 0
    dropped_lines = 0
    for i, ln in enumerate(lines):
        text = str(ln.get("text") or "")
        punct = sum(1 for c in text if c in _PUNCT_CHARS)
        text_punct += punct
        if ln.get("w", 0) < 8 or ln.get("h", 0) < 8:
            continue
        try:
            crop = im.crop(
                (ln["x"], ln["y"], ln["x"] + ln["w"], ln["y"] + ln["h"])
            )
        except Exception:
            continue
        stats = _small_mark_count(crop)
        if stats is None:
            continue
        small, _comps = stats
        blob_total += small
        if small > punct:
            dropped_lines += 1
            tlog(
                f"mark stats line {i + 1}/{len(lines)}: {len(text)} chars, "
                f"text punct={punct}, mark-like blobs≈{small} "
                f"(model likely skipped ≈{small - punct})"
            )
    ratio = f"{100 * text_punct / blob_total:.0f}%" if blob_total else "n/a"
    tlog(
        f"mark stats: {len(lines)} lines, text puncts={text_punct}, "
        f"mark-like blobs≈{blob_total} ({dropped_lines} lines dropping), "
        f"read ratio {ratio}"
    )


def _op_read_page(model, payload: dict) -> dict:
    """整页直读：det+rec 全管线直接读原始页面（不走版面/切分管线）。

    返回未排序的行列表 {x,y,w,h,text,conf,chars:[]}（原图坐标）——
    PP-OCR 自带的排序对古籍竖排不可靠，阅读序由服务端 page_text 按
    方向参数重排。rec_boxes 优先（轴对齐外接框），缺时回落 rec_polys
    外接矩形（斜排/弯曲行的 poly 不是轴对齐框）。orientation/h_dir/
    v_dir 透传给 VL 混合合并做段落切片的阅读序（缺省=旧行为）。"""
    image_path = payload["image_path"]
    if _is_vl_model():
        lines = _vl_read_page(
            model, image_path, payload.get("vl_predict") or None,
            orientation=str(payload.get("orientation") or "vertical"),
            horizontal_dir=str(payload.get("horizontal_dir") or "ltr"),
            vertical_dir=str(payload.get("vertical_dir") or "ttb"),
        )
    else:
        lines = _pp_read_page(image_path)
    tlog(f"page read done: {len(lines)} lines")
    # 标点诊断日志（只读不改结果）：文本标点 vs 图上小墨块，量化丢标点。
    try:
        _log_mark_stats(lines, image_path)
    except Exception as exc:  # 诊断失败绝不能影响直读结果
        tlog(f"mark stats failed: {exc}")
    return {"lines": lines}


def _vl_result_dict(res) -> dict:
    """VL 管线结果对象 → 字段 dict。

    paddlex 的 VL 结果可靠通道是 `json`（属性或方法，返回 dict 或 JSON
    字符串；实测结构 {'res': {parsing_res_list...}}）；`.res` 属性在部分
    结果类上缺失，_result_data 会拿到空 dict——这里优先 json，最后再
    兜底 _result_data。"""
    try:
        if isinstance(res, dict):
            return res
        j = getattr(res, "json", None)
        if j is not None:
            data = j() if callable(j) else j
            if isinstance(data, str):
                data = json.loads(data)
            if isinstance(data, dict):
                return data
    except Exception as exc:
        # json 通道失效（序列化抛错等）走 _result_data 兜底——留痕，
        # 否则提取落空时无从判断是哪个通道出的问题。
        tlog(f"VL result json channel failed: {type(exc).__name__}: {exc}")
    return _result_data(res)


def _vl_block_content(block) -> str:
    """VL 版面块 → 文本内容。paddlex 的 parsing_res_list 元素随取用路径
    不同而是 dict（json 序列化，字段名 block_content）或 PaddleOCRVLBlock
    对象（res 数据直取，属性名 content；实测两条路径都会出现）。"""
    if isinstance(block, dict):
        return str(block.get("block_content") or block.get("content") or "")
    return str(
        getattr(block, "block_content", None) or getattr(block, "content", "")
        or ""
    )


# VL predict 级参数白名单（官网演示同款：Prompt 类型/生成参数/像素
# 限制/辅助内容忽略清单）。全部随每次 read_page 请求传入——不绑定池，
# 改参数不重建进程。
_VL_PROMPT_LABELS = ("ocr", "formula", "table", "chart", "seal", "spotting")
_VL_IGNORE_LABELS = (
    "number", "footnote", "header", "header_image",
    "footer", "footer_image", "aside_text",
)


def _vl_predict_kwargs(params: dict | None) -> dict:
    """请求里的 vl_predict dict → pipe.predict 的合法 kwargs（白名单 +
    类型归一；None/非法值剔除，保持模型默认）。"""
    src = params if isinstance(params, dict) else {}
    out: dict = {}
    label = str(src.get("prompt_label") or "").strip().lower()
    if label in _VL_PROMPT_LABELS:
        out["prompt_label"] = label
    for key in ("repetition_penalty", "temperature", "top_p"):
        val = src.get(key)
        if isinstance(val, (int, float)) and not isinstance(val, bool):
            out[key] = float(val)
    for key in ("min_pixels", "max_pixels", "max_new_tokens"):
        val = src.get(key)
        if isinstance(val, int) and not isinstance(val, bool) and val > 0:
            out[key] = val
    ignore = src.get("markdown_ignore_labels")
    if isinstance(ignore, list):
        # 空清单有效（= 辅助内容全部恢复解析），不能丢——丢了会退化回
        # 模型默认的"忽略全部 7 类"。
        out["markdown_ignore_labels"] = [
            str(x) for x in ignore if str(x) in _VL_IGNORE_LABELS
        ]
    if src.get("merge_layout_blocks") is not None:
        out["merge_layout_blocks"] = bool(src["merge_layout_blocks"])
    return out


def _vl_read_page(
    pipe,
    image_path: str,
    vl_predict: dict | None = None,
    orientation: str = "vertical",
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
) -> list[dict]:
    """VL 视觉语言模型的整页直读（混合方案：VL 读文 + PP-OCR 定框）。

    VL（0.9B）对古籍竖排/小号标点原生友好（实测 page_005：86 个标点
    vs PP-OCRv6 的 3 个），但输出只有块级 bbox、无逐行坐标；PP-OCR
    det 行框快而准但文本丢标点。两路互补：无版面模式下 VL 的 ocr 块
    按列分行（每个 \\n 一列），去标点后与 PP-OCR 行文本按相似度对齐
    ——行框用 PP-OCR（阅读序重排/行文对照/标点诊断都依赖几何），行
    文本换成 VL 的带标点版本。**版面分析开启时** VL 块是整段段落文本
    （几十上百字），逐行相似度对不上——由段落切片路径（见
    _vl_merge_texts）按阅读序把段落切回逐行，标点落回各行。"""
    tlog(f"page read (VL): {image_path}")
    predict_kwargs = _vl_predict_kwargs(vl_predict)
    if predict_kwargs:
        tlog(f"VL predict params: {predict_kwargs}")
    t0 = time.time()
    vl_texts: list[str] = []
    last_data: dict = {}
    for res in pipe.predict(input=image_path, **predict_kwargs):
        data = _vl_result_dict(res)
        # VL 结果结构 {'res': {parsing_res_list...}}——解掉包装层。
        if isinstance(data.get("res"), dict):
            data = data["res"]
        last_data = data
        for block in data.get("parsing_res_list") or []:
            content = _vl_block_content(block)
            vl_texts.extend(
                line.strip() for line in content.split("\n") if line.strip()
            )
    if not vl_texts:
        # 提取落空：把结果对象形态打进日志（解析回归时后端控制台直接
        # 可见是 json 通道失效还是版面块为空）。
        prl = last_data.get("parsing_res_list")
        tlog(
            f"VL text empty: data keys={list(last_data)[:8]}, "
            f"parsing_res_list type={type(prl).__name__}, "
            f"len={len(prl) if isinstance(prl, (list, tuple)) else 'n/a'}"
        )
    tlog(
        f"VL text done: {len(vl_texts)} lines in {time.time() - t0:.1f}s"
    )
    if not vl_texts:
        return []
    geo_lines = _pp_read_page(image_path)
    merged = _vl_merge_texts(
        geo_lines, vl_texts, orientation, horizontal_dir, vertical_dir
    )
    tlog(f"VL hybrid read done: {len(merged)} lines in {time.time() - t0:.1f}s")
    return merged


def _plain_chars(s: str) -> str:
    """对齐用纯文本：去标点/空白（VL 文本与 PP-OCR 行文本的公平比较面）。"""
    return "".join(
        ch for ch in str(s or "") if ch not in _PUNCT_CHARS and not ch.isspace()
    )


def _order_geo_reading(
    lines: list[dict],
    orientation: str,
    horizontal_dir: str,
    vertical_dir: str,
) -> list[dict]:
    """PP-OCR 行按阅读序粗排（段落切片用；最终阅读序仍由服务端重排）。

    竖排：列序按 x（rtl 反向）、列内按 y（btt 反向）；横排对称。"""
    vertical = orientation != "horizontal"

    def key(ln: dict):
        cx = ln.get("x", 0) + ln.get("w", 0) / 2.0
        cy = ln.get("y", 0) + ln.get("h", 0) / 2.0
        if vertical:
            return (
                -cx if horizontal_dir == "rtl" else cx,
                -cy if vertical_dir == "btt" else cy,
            )
        return (
            -cy if vertical_dir == "btt" else cy,
            -cx if horizontal_dir == "rtl" else cx,
        )

    return sorted(lines, key=key)


def _slice_paragraph_to_lines(
    paragraph: str, ordered_lines: list[dict]
) -> tuple[list[tuple[dict, str]], int]:
    """段落文本按阅读序行文本切回逐行（含标点）——版面分析开启时 VL
    块是整段，逐行相似度对不上，这里是段落→行的还原路径。

    顺序在段落纯文本里逐行定位（去标点后 difflib 匹配，覆盖率 ≥0.55）；
    相邻定位之间的标点归属前一行，段首残余并入首行、段尾残余并入末行
    （不产生整段零框重复）。返回 ([(行, 带标点行文本), ...], 消费行数)；
    一行都没对上返回 ([], 0)（调用方走零框兜底，文本不丢）。"""
    import difflib

    idx = [i for i, ch in enumerate(paragraph) if not ch.isspace()]
    if not idx:
        return [], 0
    pstr = "".join(paragraph[i] for i in idx)
    spans: list[tuple[int, int, int, float]] = []  # (行序, start, end, 覆盖率)
    cursor = 0
    for pos, ln in enumerate(ordered_lines):
        g = _plain_chars(ln.get("text") or "")
        if not g:
            continue
        window = pstr[cursor : cursor + len(g) + 40]
        sm = difflib.SequenceMatcher(None, window, g, autojunk=False)
        blocks = [b for b in sm.get_matching_blocks() if b.size > 0]
        if not blocks:
            continue
        cov = sum(b.size for b in blocks) / len(g)
        if cov < 0.55:
            continue
        start = cursor + min(b.a for b in blocks)
        end = cursor + max(b.a + b.size for b in blocks)
        spans.append((pos, start, end, cov))
        cursor = end
    if not spans:
        return [], 0
    prefix = paragraph[: idx[spans[0][1]]]
    slices: list[tuple[dict, str]] = []
    for k, (pos, start, end, cov) in enumerate(spans):
        nxt_start = spans[k + 1][1] if k + 1 < len(spans) else len(pstr)
        begin = idx[start]
        stop = idx[nxt_start - 1] + 1
        text = paragraph[begin:stop]
        if k == 0 and prefix:
            text = prefix + text
        ln = ordered_lines[pos]
        slices.append((ln, text))
        ln["text"] = text
        ln["conf"] = round(cov, 4)
    return slices, spans[-1][0] + 1


def _vl_merge_texts(
    geo_lines: list[dict],
    vl_texts: list[str],
    orientation: str = "vertical",
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
) -> list[dict]:
    """VL 分行/分段文本（带标点）对齐到 PP-OCR 行框（无标点、几何准）。

    ① 逐行匹配（无版面模式的逐列输出）：每条 VL 文本去标点后与未占用
    的 PP-OCR 行文本做相似度匹配，取最优且 ≥0.55：命中则该行 text 换成
    VL 版本（conf 记匹配度）。
    ② 段落切片（版面分析开启时块=整段，几十上百字）：逐行对不上的
    leftovers 按阅读序切回未占用行，标点落回各行；切片一行没中才走
    零框兜底（文本不丢）。
    未命中的 PP-OCR 行（页码/噪声等 VL 不出的）保留原文；行级 leftover
    贴到上一个命中行旁边（同框）。"""
    used: set[int] = set()
    last_hit: dict | None = None
    leftovers: list[str] = []
    for full in vl_texts:
        p = _plain_chars(full)
        if not p:
            continue
        best_idx = -1
        best_ratio = 0.0
        for idx, g in enumerate(geo_lines):
            if idx in used:
                continue
            ratio = _seq_ratio(p, g.get("text", ""))
            if ratio > best_ratio:
                best_ratio = ratio
                best_idx = idx
        if best_idx >= 0 and best_ratio >= 0.55:
            used.add(best_idx)
            geo_lines[best_idx]["text"] = full
            geo_lines[best_idx]["conf"] = round(best_ratio, 4)
            last_hit = geo_lines[best_idx]
        else:
            leftovers.append(full)

    # ② 段落级 leftovers：按阅读序切回未占用行（实测版面分析开启时
    # VL 输出 2~3 个整段块、逐行相似度全部落空的失败形态）。
    geo_plain_lens = sorted(
        len(_plain_chars(g.get("text") or "")) for g in geo_lines
    )
    median_len = (
        geo_plain_lens[len(geo_plain_lens) // 2] if geo_plain_lens else 24
    )
    para_min = max(48, int(median_len * 2.0))
    sliced_any = False
    id_to_idx = {id(g): i for i, g in enumerate(geo_lines)}
    ordered = _order_geo_reading(
        [g for g in geo_lines if id_to_idx[id(g)] not in used
         and _plain_chars(g.get("text") or "")],
        orientation, horizontal_dir, vertical_dir,
    )
    line_leftovers: list[str] = []
    for full in leftovers:
        if ordered and len(_plain_chars(full)) > para_min:
            slices, consumed = _slice_paragraph_to_lines(full, ordered)
            if slices:
                sliced_any = True
                used.update(id_to_idx[id(ln)] for ln, _t in slices)
                last_hit = slices[-1][0]
                ordered = ordered[consumed:]
                continue
        line_leftovers.append(full)

    # 行级 leftover（无版面模式的页码/单行噪声）：贴到上一个命中行旁边
    # （同框），文本不丢。一个都没命中时留给末尾零框兜底统一处理。
    for full in line_leftovers:
        if last_hit is not None:
            geo_lines.append(
                {
                    "x": last_hit["x"],
                    "y": last_hit["y"],
                    "w": last_hit["w"],
                    "h": last_hit["h"],
                    "text": full,
                    "conf": 0.0,
                    "chars": [],
                }
            )
    if not used and not sliced_any and vl_texts:
        # PP-OCR 一行都没对上（检测全失败）：全文本退回零框行，保文本
        for full in vl_texts:
            geo_lines.append(_zero_box_line(full))
    return geo_lines


def _zero_box_line(text: str) -> dict:
    return {"x": 0, "y": 0, "w": 0, "h": 0, "text": text, "conf": 0.0, "chars": []}


def _seq_ratio(a: str, b: str) -> float:
    """段落/行文本相似度（difflib 快速比一次）。"""
    from difflib import SequenceMatcher

    return SequenceMatcher(None, a, b).ratio()


def _pp_read_page(image_path: str) -> list[dict]:
    """PP-OCR 系（det+rec 完整管线）的整页直读。"""
    pipeline = _get_pipeline()
    tlog(f"page read: {image_path}")
    t0 = time.time()
    lines: list[dict] = []
    for res in pipeline.predict(input=image_path):
        data = _result_data(res)
        texts = data.get("rec_texts") or []
        scores = data.get("rec_scores") or []
        boxes = data.get("rec_boxes")
        polys = data.get("rec_polys")
        for i, text in enumerate(texts):
            x = y = 0.0
            w = h = 0.0
            try:
                if boxes is not None and i < len(boxes):
                    b = list(boxes[i])[:4]
                    x, y = float(b[0]), float(b[1])
                    w = max(1.0, float(b[2]) - x)
                    h = max(1.0, float(b[3]) - y)
                elif polys is not None and i < len(polys):
                    pts = [(float(p[0]), float(p[1])) for p in polys[i]]
                    xs = [p[0] for p in pts]
                    ys = [p[1] for p in pts]
                    x, y = min(xs), min(ys)
                    w = max(1.0, max(xs) - x)
                    h = max(1.0, max(ys) - y)
            except Exception:
                x = y = w = h = 0.0
            conf = float(scores[i]) if i < len(scores) else 0.0
            lines.append(
                {
                    "x": int(max(0.0, x)),
                    "y": int(max(0.0, y)),
                    "w": int(w),
                    "h": int(h),
                    "text": str(text),
                    "conf": round(conf, 4),
                    "chars": [],
                }
            )
    tlog(f"PP page read done: {len(lines)} lines in {time.time() - t0:.1f}s")
    return lines


# ── PP-OCR det 行检测（engine=paddle 的行框来源）────────────────────────
# 自训 YOLO 字框分组在部分影印本上产出碎片/粘连/漏检行框（实测整列漏检、
# 单个句号成独立行、夹注小字并进正文）；PP-OCR det（官网演示同款文本
# 检测）对同一页面行框又快又准（实测 page_005：17 列全部紧致检出 0.6s）。
# detect_lines 在 daemon 内跑 TextDetection 单模（懒建常驻，与识别模型
# 共存），行框几何交回服务端管线——切字/识别/融合链路照旧。
_DET_MODEL = None


def _get_det_model():
    """构造/取 det 单模。检测档位跟随本 daemon 绑定的识别档位
    （PP-OCRv6_<tier>_rec → PP-OCRv6_<tier>_det；首建自动下载），档位
    det 名不可用（如 PP-OCRv3 mobile 拼接名）退回 small——行框质量在
    档位间差异远小于识别精度差异。"""
    global _DET_MODEL
    if _DET_MODEL is None:
        from paddleocr import TextDetection

        det_name = (
            "PP-OCRv6_small_det"
            if _is_vl_model()
            else f"{_MODEL_NAME.rsplit('_rec', 1)[0]}_det"
        )
        device = _DEVICE or "gpu"
        tlog(f"init det model: {det_name} (device={device})")
        t0 = time.time()
        try:
            _DET_MODEL = TextDetection(model_name=det_name, device=device)
        except Exception as exc:
            tlog(f"det model {det_name} unavailable ({exc}), fallback small")
            _DET_MODEL = TextDetection(
                model_name="PP-OCRv6_small_det", device=device
            )
        tlog(f"det model ready in {time.time() - t0:.1f}s")
    return _DET_MODEL


def _det_rects_from_result(data: dict) -> list[dict]:
    """det 结果字段 → 轴对齐行框列表 {x,y,w,h}（外接矩形，浮点）。

    实测 paddleocr 3.7 TextDetection 输出键是 dt_polys(4,2)+dt_scores；
    det_boxes/rec_boxes（轴对齐）与 det_polys/rec_polys 等管线/历史通道
    键一并兼容，取不到按空处理。"""
    rects: list[dict] = []
    for key in ("det_boxes", "rec_boxes", "dt_boxes"):
        try:
            axis = data.get(key)
            if axis is None or len(axis) == 0:
                continue
            for box in axis:
                v = [float(x) for x in list(box)[:4]]
                x, y = v[0], v[1]
                rects.append(
                    {"x": x, "y": y, "w": max(1.0, v[2] - x), "h": max(1.0, v[3] - y)}
                )
            return rects
        except Exception:
            rects = []
    for key in ("det_polys", "rec_polys", "dt_polys"):
        try:
            polys = data.get(key)
            if polys is None or len(polys) == 0:
                continue
            for poly in polys:
                pts = [(float(p[0]), float(p[1])) for p in list(poly)[:4]]
                xs = [p[0] for p in pts]
                ys = [p[1] for p in pts]
                rects.append(
                    {
                        "x": min(xs),
                        "y": min(ys),
                        "w": max(1.0, max(xs) - min(xs)),
                        "h": max(1.0, max(ys) - min(ys)),
                    }
                )
            return rects
        except Exception:
            rects = []
    return rects


def _op_detect_lines(model, payload: dict) -> dict:
    """PP-OCR det 行检测：返回未排序行框 {x,y,w,h}（原图坐标，int）——
    阅读序由服务端按方向参数重排，行内切字/识别照旧走服务端管线。"""
    if _is_vl_model():
        _vl_reject()
    det = _get_det_model()
    t0 = time.time()
    rects: list[dict] = []
    for res in det.predict(input=payload["image_path"]):
        data = _vl_result_dict(res)
        inner = data.get("res")
        if isinstance(inner, dict) and (
            inner.get("dt_polys") is not None
            or inner.get("det_polys") is not None
            or inner.get("det_boxes") is not None
        ):
            data = inner
        rects.extend(_det_rects_from_result(data))
    tlog(f"det lines: {len(rects)} in {time.time() - t0:.1f}s")
    return {
        "lines": [
            {
                "x": int(r["x"]),
                "y": int(r["y"]),
                "w": int(r["w"]),
                "h": int(r["h"]),
            }
            for r in rects
        ]
    }


def _load_model():
    global _DEVICE
    device = "gpu"
    try:
        import paddle

        if not paddle.is_compiled_with_cuda():
            device = "cpu"
    except Exception:
        device = "cpu"

    if _is_vl_model():
        # VL 是完整文档解析管线（非 TextRecognition 单模型）：构造即触发
        # 模型下载/加载（0.9B 约 1.9GB）。解析配置（文档方向/矫正/版面
        # 检测/图表/印章/图片块OCR/合并块，官网演示同款开关）由池经
        # PADDLE_VL_CONFIG 注入，配置变化=换池重建新 daemon。
        from paddleocr import PaddleOCRVL

        vl_cfg = _vl_config()
        if device == "cpu":
            tlog("WARNING: VL 模型跑在 CPU 上会极慢（分钟级/页），建议 GPU")
        tlog(f"load VL pipeline: {_MODEL_NAME} (device={device}, cfg={vl_cfg})")
        t0 = time.time()

        def build():
            return PaddleOCRVL(
                pipeline_version=_VL_PIPELINE_VERSION[_MODEL_NAME],
                device=device,
                **vl_cfg,
            )

        try:
            model = build()
        except Exception as exc:
            if device == "gpu":
                tlog(f"gpu load failed ({exc}), fallback to cpu")
                device = "cpu"
                model = build()
            else:
                raise
        _DEVICE = device
        tlog(f"VL pipeline loaded on {device} in {time.time() - t0:.1f}s")
        return model

    from paddleocr import TextRecognition

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


def _op_read_line(model, payload: dict) -> dict:
    """整行全文直读（全文对照用）：行框裁图整体识别，不经字框切分——
    行内标点等没有字框的字符在这里也会被读出。竖排走 rotate（PP-OCRv5+
    原生竖排域，rotate 90/270 对应 ttb/btt 的列首方向；横排不转）。
    返回 {text, conf}。"""
    if _is_vl_model():
        _vl_reject()
    from PIL import Image

    rect = payload["rect"]
    rotate = int(payload.get("rotate") or 0)
    im = Image.open(payload["image_path"]).convert("RGB")
    crop = im.crop(
        (rect["x"], rect["y"], rect["x"] + rect["w"], rect["y"] + rect["h"])
    )
    if rotate:
        crop = crop.rotate(rotate, expand=True)
    text, conf = _predict_entries(model, [crop])[0]
    tlog(f"line full read: {len(text)} chars conf={conf:.2f} rotate={rotate}")
    return {"text": text, "conf": round(float(conf), 4)}


_OPS = {
    "recognize": _op_recognize,
    "read_boxes": _op_read_boxes,
    "read_strip": _op_read_strip,
    "read_line": _op_read_line,
    "read_page": _op_read_page,
    "detect_lines": _op_detect_lines,
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
