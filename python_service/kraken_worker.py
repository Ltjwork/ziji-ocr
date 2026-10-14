"""Kraken 识别 daemon——在独立的 kraken conda 环境中常驻运行，被 kraken_bridge 调起。

协议（stdin/stdout，均为单行 JSON，UTF-8）：
  请求：{"id": int, "op": "ping" | "recognize" | "shutdown", "payload": {...}}
  响应：{"id": int, "ok": true, "result": {...}} 或 {"id": int, "ok": false, "error": "..."}

  recognize 的 payload：{"image_path": str, "scale": float, "text_direction": str,
                        "lines": [{"x","y","w","h"}, ...]}
  result：{"lines": [{"x","y","w","h","text","conf",
                      "chars": [{"x","y","w","h","text","conf"}]}]}

模型在启动时加载一次并常驻显存/内存；进度日志全部走 stderr（实时透传到
服务控制台），stdout 只允许出现协议响应。stdin 关闭（父进程退出）时 daemon
自行退出，防止孤儿进程。
"""

from __future__ import annotations

import json
import os
import sys
import time
import traceback
from pathlib import Path

MODEL_DIR = Path(__file__).resolve().parent / "kraken_models"
REC_MODEL = MODEL_DIR / "chat_rec.mlmodel"


def _effective_rec_model() -> Path:
    """识别模型路径：父进程（kraken_proc._start）经 KRAKEN_REC_MODEL 传入
    的优先（.zjpack 发行包物化文件），缺省回落散文件——开发机直接起 worker
    也能跑。"""
    override = os.environ.get("KRAKEN_REC_MODEL", "").strip()
    return Path(override) if override else REC_MODEL


SEG_MODEL = MODEL_DIR / "chat_seg.mlmodel"


def _effective_seg_model() -> Path:
    """整页直读的分行模型（blla 类）：环境变量覆写 > 散文件。"""
    override = os.environ.get("KRAKEN_SEG_MODEL", "").strip()
    return Path(override) if override else SEG_MODEL


# 分行模型懒加载缓存（首个 read_page 请求时加载并常驻，与识别模型同设备）。
_SEG_MODEL_OBJ = None


def _merge_line_rects_by_band(rects: list[dict], direction: str) -> list[dict]:
    """把同行/同列的碎片段合并成整行/整列框（带状合并）。

    blla 类分行模型在竖排小图上常把一列拆成单字级碎片（实测 284px 宽
    的源图，chat_seg 与 kraken 默认 blla 都把 6 列正文拆成 28 个 15~42px
    高的碎框，放大 2~4 倍也不恢复）——每片单独识别只有 1~2 字且无列语
    境。按阅读轴的垂直轴中心贪心聚类（容差 = 该轴跨度中位数的一半，
    与服务端 page_text 分列同款启发），每簇取联合框：得到整列（竖排）/
    整行（横排）框，交给逐行识别路径读完整语境。"""
    if len(rects) < 2:
        return rects
    vertical = direction.startswith("vertical")
    axis_idx = 0 if vertical else 1
    span_key = "w" if vertical else "h"

    def center(r: dict) -> float:
        return r["x"] + r["w"] / 2.0 if vertical else r["y"] + r["h"] / 2.0

    tol = sorted(r[span_key] for r in rects)[len(rects) // 2] * 0.5
    ordered = sorted(rects, key=center)
    # 逐簇独立的运行均值（簇均值）：比较基准只能是当前簇的均值，用全局
    # 累计均值会在第二簇起把比较点拖离当前簇、永远不并（实测 27 片只
    # 并成 25 的根源）。
    groups: list[list[dict]] = []
    sums: list[float] = []
    counts: list[int] = []
    for r in ordered:
        c = center(r)
        if groups and abs(c - sums[-1] / counts[-1]) <= tol:
            groups[-1].append(r)
            sums[-1] += c
            counts[-1] += 1
        else:
            groups.append([r])
            sums.append(c)
            counts.append(1)
    merged: list[dict] = []
    for group in groups:
        x0 = min(r["x"] for r in group)
        y0 = min(r["y"] for r in group)
        x1 = max(r["x"] + r["w"] for r in group)
        y1 = max(r["y"] + r["h"] for r in group)
        merged.append({"x": x0, "y": y0, "w": x1 - x0, "h": y1 - y0})
    return merged


def _op_read_line(rec, payload: dict) -> dict:
    """整行全文直读（全文对照用）：单行框直接走与标注识别完全相同的
    逐行预处理+识别（_per_line_pipeline 单矩形），不经字框切分——行内
    标点等没有字框的字符在这里也会被读出。返回 {text, conf}。"""
    from PIL import Image

    rect = payload["rect"]
    direction = str(payload.get("text_direction", "vertical-rl"))
    im = Image.open(payload["image_path"]).convert("L")
    out = _per_line_pipeline(rec, im, [rect], direction, 2.0)
    line = out[0] if out else {}
    text = str(line.get("text") or "")
    conf = float(line.get("conf") or 0.0)
    tlog(f"line full read: {len(text)} chars conf={conf:.2f}")
    return {"text": text, "conf": round(conf, 4)}


def _op_read_page(rec, payload: dict) -> dict:
    """整页直读：blla 分行出"行框"，识别走与标注管线完全相同的逐行
    预处理路径（裁剪 + 窄轴 ≥100px 定倍 + 局部 nlbin + rpred + cuts
    重建），不走主区/段落/单行/单字标注管线。

    CHAT 模型对原始灰度/欠放大的整页直读会输出空文本（列宽不足 100px
    且未二值化，见 _prepare_line 注释），因此不能把整页 seg 直接喂
    rpred——blla 只负责检测（行框 = boundary 多边形外接矩形），每行
    独立走 _per_line_pipeline。返回未排序行列表（阅读序由服务端
    page_text 按方向参数重排；blla 自带行序对竖排不可靠）。"""
    import warnings

    from PIL import Image

    from kraken import blla
    from kraken.lib.vgsl import TorchVGSLModel

    global _SEG_MODEL_OBJ
    device = "cuda" if _DEVICE == "cuda" else "cpu"
    if _SEG_MODEL_OBJ is None:
        seg_path = _effective_seg_model()
        tlog(f"load seg model: {seg_path}")
        t0 = time.time()
        # 分割模型必须用 TorchVGSLModel.load_model 加载：load_any 只适用于
        # 识别模型（无条件包 TorchSeqRecognizer 并取 nn.codec——分割模型
        # 没有该属性，kraken 7.1 实测 AttributeError 'TorchVGSLModel' object
        # has no attribute 'codec'）。blla.segment 内部默认模型走的也是
        # TorchVGSLModel.load_model（CPU 加载，device 由 segment 内部处理）。
        _SEG_MODEL_OBJ = TorchVGSLModel.load_model(str(seg_path))
        tlog(f"seg model loaded in {time.time() - t0:.1f}s")

    image_path = payload["image_path"]
    # 行方向与识别管线同源（竖排列旋转后进识别网络），由桥接层按书的
    # 方向设置计算传入；blla 的行朝向兜底也依赖它。
    direction = str(payload.get("text_direction", "vertical-rl"))
    im = Image.open(image_path).convert("L")
    tlog(f"page read (blla): {image_path}")
    t0 = time.time()
    with warnings.catch_warnings():
        # blla.segment 弃用告警（kraken 8 起移除，本环境 7.1.1；替代 API 为
        # kraken.tasks.segmentation.SegmentationTaskModel，升级 kraken 时换）。
        warnings.simplefilter("ignore", DeprecationWarning)
        seg = blla.segment(
            im, text_direction=direction, model=_SEG_MODEL_OBJ, device=device
        )
    tlog(f"segment done: {len(seg.lines)} lines in {time.time() - t0:.1f}s")

    # boundary 多边形外接矩形 → 行框；缺 boundary 用 baseline 外接并加
    # 半个行高边距（baseline 只是中心线）。过小的框（<5px）是 blla 的
    # 噪声检出，直接丢弃。
    rects: list[dict] = []
    for sline in seg.lines:
        pts = [tuple(p) for p in (getattr(sline, "boundary", None) or [])]
        if pts:
            xs = [float(p[0]) for p in pts]
            ys = [float(p[1]) for p in pts]
        else:
            bl = [tuple(p) for p in (getattr(sline, "baseline", None) or [])]
            if not bl:
                continue
            xs = [float(p[0]) for p in bl]
            ys = [float(p[1]) for p in bl]
        x, y = min(xs), min(ys)
        w, h = max(xs) - x, max(ys) - y
        if not pts:
            pad = max(4.0, h / 2.0)
            x, y, w, h = x - pad, y - pad, w + pad * 2, h + pad * 2
        if w < 5 or h < 5:
            continue
        rects.append(
            {"x": int(x), "y": int(y), "w": int(w), "h": int(h)}
        )
    rects = _merge_line_rects_by_band(rects, direction)
    tlog(f"{len(rects)} line rects to recognize (after band merge)")

    # 逐行流水线：预处理（生产者线程）与推理重叠，参数与"本行单独
    # 识别"完全同路径——空白行裁剪按空行返回（_prepare_line_safe）。
    out_lines = _per_line_pipeline(rec, im, rects, direction, 2.0)
    tlog(f"page read done: {len(out_lines)} lines in {time.time() - t0:.1f}s")
    return {"lines": out_lines}

_T0 = time.time()
# 实例标签（KRAKEN_WORKER_ID，由 kraken_bridge 起 daemon 时注入）：多实例
# 并行池下 stderr 日志可区分是哪个 daemon 打的。
_TAG = os.environ.get("KRAKEN_WORKER_ID", "")
# 本 daemon 实际加载到的设备（_load_model 写入），ping 时上报给服务端
# ——服务端据此判断 CUDA 是否真的可用（主服务 torch 环境未必有 CUDA）。
_DEVICE: str | None = None

# 致命（粘性）CUDA 错误标记：illegal memory access / device-side assert
# 后 CUDA 上下文损坏，本进程后续一切 CUDA 调用都会重复同一错误。命中时
# daemon 在写回错误响应后自行退出（服务端会惰性重启新进程），坏上下文
# 绝不再接客——与服务端 kraken_proc 的同款判定互为双保险。OOM 是瞬态
# 错误，显式排除。
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
    print(f"[kraken-worker{tag} +{time.time() - _T0:7.1f}s] {msg}", file=sys.stderr, flush=True)


def _line_geometry(
    rect: dict, text_direction: str, scale: float,
    im_w: int = 0, im_h: int = 0,
):
    """行框 → (baseline 折线, boundary 闭合多边形, 阅读轴)。均为放大后坐标。

    boundary 沿阅读轴向外各扩 2px 避免字形贴边被裁；贴到图像边缘的行框
    （如 x=0/y=0 的页缘行）外扩会越出图像，extract_polygons 直接报
    "outside of image bounds"、整行读空——传入图像尺寸（放大后）时把
    外扩收进界内。"""
    x = rect["x"] * scale
    y = rect["y"] * scale
    w = rect["w"] * scale
    h = rect["h"] * scale
    vertical = text_direction.startswith("vertical")
    if vertical:
        cx = x + w / 2
        baseline = [(cx, y), (cx, y + h)]
    else:
        cy = y + h / 2
        baseline = [(x, cy), (x + w, cy)]
    if vertical:
        lo, hi = y - 2, y + h + 2
        boundary = [
            (x, lo), (x + w, lo), (x + w, hi), (x, hi), (x, lo),
        ]
    else:
        lo, hi = x - 2, x + w + 2
        boundary = [
            (lo, y), (hi, y), (hi, y + h), (lo, y + h), (lo, y),
        ]
    if im_w or im_h:
        # 行框自身贴到图像边缘（如 x+w == im_w）时多边形同样越界，
        # 两个方向都收进界内。
        boundary = [
            (
                min(max(px, 0), im_w - 1) if im_w else px,
                min(max(py, 0), im_h - 1) if im_h else py,
            )
            for px, py in boundary
        ]
    return baseline, boundary, vertical


def _crop_bounds(rects: list[dict], page_w: int, page_h: int, pad: int = 24):
    """所有行框的包围盒（四边外扩 pad 像素），裁剪到页面范围内。

    返回 None 表示包围盒已是整页（无需裁剪）。供快速识别只处理请求
    涉及的局部区域，而不是整页缩放+二值化。
    """
    x0 = min(r["x"] for r in rects) - pad
    y0 = min(r["y"] for r in rects) - pad
    x1 = max(r["x"] + r["w"] for r in rects) + pad
    y1 = max(r["y"] + r["h"] for r in rects) + pad
    x0 = max(0, x0)
    y0 = max(0, y0)
    x1 = min(page_w, x1)
    y1 = min(page_h, y1)
    if x0 <= 0 and y0 <= 0 and x1 >= page_w and y1 >= page_h:
        return None
    if x1 - x0 < 8 or y1 - y0 < 8:
        return None
    return x0, y0, x1, y1


def _record_to_line(
    record, rect: dict, scale: float, axis_off: float, vertical: bool
) -> dict:
    """rpred 结果 → line dict（文本、逐字置信度、cuts 重建的字符单元框）。

    rect 为本次处理的坐标空间（行框）；scale 为放大倍数；axis_off 是
    cuts 的阅读轴坐标除以 scale 后需要加回的偏移（per-line 裁剪时为
    裁剪原点，整批路径为 0）。产出的 line/char 框与 rect 同坐标空间。
    """
    line_t0 = time.time()
    pred = record.prediction
    text = "".join(pred) if isinstance(pred, (list, tuple)) else str(pred)
    confs = list(record.confidences or [])
    n = len(text)
    tlog(f"line: {n} chars in {time.time() - line_t0:.1f}s")

    x = rect["x"]
    y = rect["y"]
    w = rect["w"]
    h = rect["h"]

    # kraken 7 的 cuts 对竖排行是横穿列宽的“字符中心线段”（多边形
    # 高度为 0，轴坐标在放大后的行图空间）。据此重建字符单元框：
    # 相邻中心线取中点为界、首尾用行边界；cuts 不可用/非单调时均分。
    cuts = list(getattr(record, "cuts", None) or [])[:n]
    axis_pos: list[float] = []
    for cut in cuts:
        pts = list(cut or [])
        if not pts:
            axis_pos = []
            break
        axis_pos.append(
            (sum(p[1] for p in pts) / len(pts)) / scale + axis_off
            if vertical
            else (sum(p[0] for p in pts) / len(pts)) / scale + axis_off
        )
    usable = (
        len(axis_pos) == n
        and n > 0
        and all(axis_pos[i] < axis_pos[i + 1] for i in range(n - 1))
    )
    lo = y if vertical else x
    hi = (y + h) if vertical else (x + w)
    bounds: list[float]
    if usable:
        bounds = [lo]
        bounds.extend(
            (axis_pos[i] + axis_pos[i + 1]) / 2 for i in range(n - 1)
        )
        bounds.append(hi)
    else:
        step = (hi - lo) / n if n else 0.0
        bounds = [lo + i * step for i in range(n + 1)]

    chars = []
    for k, ch in enumerate(text):
        conf = confs[k] if k < len(confs) else 0.0
        span = max(1.0, bounds[k + 1] - bounds[k])
        if vertical:
            box = (x, bounds[k], w, span)
        else:
            box = (bounds[k], y, span, h)
        chars.append(
            {
                "x": round(box[0]),
                "y": round(box[1]),
                "w": max(1, round(box[2])),
                "h": max(1, round(box[3])),
                "text": ch,
                "conf": round(float(conf), 4),
            }
        )
    return {
        "x": int(x),
        "y": int(y),
        "w": int(w),
        "h": int(h),
        "text": text,
        "conf": round(sum(confs) / len(confs), 4) if confs else 0.0,
        "chars": chars,
    }


def _prepare_line(page_im, rect: dict, text_direction: str, base_scale: float) -> dict:
    """单行识别的纯 CPU 预处理段：裁剪（外扩 24px）→ 按本行窄轴定放大
    倍数（列宽 ≥100px）→ 局部 nlbin → 几何/Segmentation 构造。

    与推理段（_infer_line）拆开是为了流水线化：预处理在生产者线程跑
    （PIL/numpy 段释放 GIL），主线程同时做上一行的 rpred。参数与输出
    和原 _recognize_line 内联版逐项一致。
    """
    from PIL import Image

    from kraken import binarization
    from kraken.containers import BaselineLine, Segmentation

    crop = _crop_bounds([rect], page_im.width, page_im.height)
    off_x, off_y = (crop[0], crop[1]) if crop else (0, 0)
    im = page_im.crop(crop) if crop else page_im
    # 窄轴定倍：竖排是列宽（rect.w），横排是行高（rect.h）——CHAT 模型
    # 要求窄轴放大后 ≥100px，轴用错会让横排行欠放大、识别为空。
    narrow = rect["w"] if text_direction.startswith("vertical") else rect["h"]
    line_scale = min(4.0, max(base_scale, 100.0 / max(1, int(narrow))))
    if line_scale != 1.0:
        im = im.resize(
            (int(im.width * line_scale), int(im.height * line_scale)), Image.LANCZOS
        )
    im = binarization.nlbin(im)
    local = {
        "x": rect["x"] - off_x,
        "y": rect["y"] - off_y,
        "w": rect["w"],
        "h": rect["h"],
    }
    baseline, boundary, vertical = _line_geometry(
        local, text_direction, line_scale, im.width, im.height
    )
    # no_legacy_polygons：legacy 提取器在竖排 baseline 上会把条带取到列
    # 间隙（张量全白→空结果）；新提取器按 boundary 多边形取行。
    seg = Segmentation(
        type="baselines",
        imagename="per-line",
        text_direction=text_direction,
        script_detection=False,
        lines=[BaselineLine(id=0, baseline=baseline, boundary=boundary)],
    )
    return {
        "im": im,
        "seg": seg,
        "scale": line_scale,
        "off_x": off_x,
        "off_y": off_y,
        "vertical": vertical,
    }


def _infer_line(rec, rect: dict, prep: dict) -> dict:
    """单行识别的推理段：rpred + cuts 重建字符框（GPU 段）。"""
    from kraken import rpred

    record = next(
        iter(rpred.rpred(rec, prep["im"], prep["seg"], no_legacy_polygons=True)), None
    )
    if record is None:
        return {
            "x": int(rect["x"]),
            "y": int(rect["y"]),
            "w": int(rect["w"]),
            "h": int(rect["h"]),
            "text": "",
            "conf": 0.0,
            "chars": [],
        }
    axis_off = float(prep["off_y"] if prep["vertical"] else prep["off_x"])
    return _record_to_line(record, rect, prep["scale"], axis_off, prep["vertical"])


def _recognize_line(rec, page_im, rect: dict, text_direction: str, base_scale: float) -> dict:
    """单行独立识别：本行裁剪（外扩 24px）→ 按本行宽度定放大倍数
    （列宽 ≥100px）→ 局部 nlbin → 识别。输出为全图坐标。

    与"重新识别本行单字"的请求处理完全同路径。整页一次 nlbin 时，
    边框/污渍/邻列墨迹会参与局部阈值估计，行级读法与逐行二值化不同
    （实测同页同框读出的字数都会变，逐行局部二值化更贴本行墨迹）。
    空白行裁剪按空行结果返回（见 _prepare_line_safe）。
    """
    prep = _prepare_line_safe(page_im, rect, text_direction, base_scale)
    if prep is _EMPTY_LINE:
        return _empty_line_result(rect)
    return _infer_line(rec, rect, prep)


def _empty_line_result(rect: dict) -> dict:
    """空行结果：与推理段 record=None 的分支同构（文本空、无字块），
    框坐标保留供上游定位。"""
    return {
        "x": int(rect["x"]),
        "y": int(rect["y"]),
        "w": int(rect["w"]),
        "h": int(rect["h"]),
        "text": "",
        "conf": 0.0,
        "chars": [],
    }


def _is_empty_image_error(exc: BaseException) -> bool:
    """nlbin 对空白裁剪抛 KrakenInputException('Image is empty')。
    按类名识别（kraken 的重导入在各函数内懒加载，这里不引依赖）。"""
    return type(exc).__name__ == "KrakenInputException" and "empty" in str(exc).lower()


def _prepare_line_safe(page_im, rect: dict, text_direction: str, base_scale: float):
    """_prepare_line 的容错版：空白行裁剪（nlbin 判空）返回哨兵
    _EMPTY_LINE 而非抛异常——一条空白行框不应把整页识别拖成 500
    （实测某页 14 行中 1 行空白，整页失败、批量断点反复卡同一页）。
    其余异常原样抛出（CUDA/模型错误仍走崩溃上报路径）。"""
    try:
        return _prepare_line(page_im, rect, text_direction, base_scale)
    except Exception as exc:
        if _is_empty_image_error(exc):
            tlog(f"[skip-empty] line rect=({rect['x']},{rect['y']},{rect['w']},{rect['h']}) 空白裁剪，按空行跳过")
            return _EMPTY_LINE
        raise


class _EmptyLineSentinel:
    """空白行哨兵（None 会被误当正常 prep 用，专用类型防混）。"""


_EMPTY_LINE = _EmptyLineSentinel()


def _per_line_pipeline(rec, page_im, rects, text_direction: str, base_scale: float) -> list[dict]:
    """行级流水线：一个生产者线程做 _prepare_line（CPU 段），主线程按序
    做 _infer_line（GPU 段）——预处理与推理重叠，行与行之间不再互相等待。

    行按输入顺序逐行投喂/取用，每行的预处理与推理参数和串行版完全
    相同，结果与 [_recognize_line(...) for r in rects] 逐字节一致
    （空白行除外：按空行结果跳过，见 _prepare_line_safe）。
    KRAKEN_PREP_PIPELINE=0 时退回串行（调试/对比用）。"""
    import queue as _queue
    import threading

    n = len(rects)
    if n <= 1 or os.environ.get("KRAKEN_PREP_PIPELINE", "1") == "0":
        out = []
        for r in rects:
            prep = _prepare_line_safe(page_im, r, text_direction, base_scale)
            out.append(
                _empty_line_result(r) if prep is _EMPTY_LINE
                else _infer_line(rec, r, prep)
            )
        return out

    feed: "_queue.Queue" = _queue.Queue(maxsize=3)  # 预取深度：预处理最多领先 3 行
    done = object()  # 生产者结束哨兵

    def produce():
        try:
            for r in rects:
                feed.put(_prepare_line_safe(page_im, r, text_direction, base_scale))
        except Exception as exc:  # 预处理失败：把异常交给消费侧抛出
            feed.put(exc)
            return
        feed.put(done)

    threading.Thread(target=produce, daemon=True).start()
    out: list[dict] = []
    while True:
        item = feed.get()
        if item is done:
            break
        if isinstance(item, Exception):
            raise item
        rect = rects[len(out)]
        out.append(
            _empty_line_result(rect) if item is _EMPTY_LINE
            else _infer_line(rec, rect, item)
        )
    return out


def _recognize(rec, payload: dict) -> dict:
    from PIL import Image

    image_path = payload["image_path"]
    scale = float(payload.get("scale", 2.0))
    text_direction = payload.get("text_direction", "vertical-rl")
    rects = payload["lines"]

    tlog(f"image open: {image_path}")
    im = Image.open(image_path).convert("L")

    if payload.get("per_line"):
        # 逐行模式（行级识别的默认路径）：每行独立裁剪+定倍+二值化；
        # 预处理与推理流水线化（见 _per_line_pipeline），行序与结果不变。
        tlog(f"per-line mode: {len(rects)} lines, base scale={scale:.2f}")
        t0 = time.time()
        out_lines = _per_line_pipeline(rec, im, rects, text_direction, scale)
        tlog(f"per-line done: {len(out_lines)} lines in {time.time() - t0:.1f}s")
        return {"lines": out_lines}

    from kraken import binarization, rpred
    from kraken.containers import BaselineLine, Segmentation

    # 整批模式（逐字框批量请求）：所有框的包围盒一次裁剪、统一倍数
    # 放大、一次 nlbin，与历史行为一致。坐标平移回写在输出时抵消。
    crop = _crop_bounds(rects, im.width, im.height)
    off_x, off_y = (crop[0], crop[1]) if crop else (0, 0)
    if crop:
        tlog(f"crop fast-path: box={crop} (page {im.width}x{im.height})")
        im = im.crop(crop)
        rects = [dict(r, x=r["x"] - off_x, y=r["y"] - off_y) for r in rects]
    if scale != 1.0:
        tlog(f"resize x{scale:.2f} ({im.width}x{im.height} -> "
             f"{int(im.width * scale)}x{int(im.height * scale)})")
        im = im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS)
    tlog("binarize (nlbin) start")
    try:
        im = binarization.nlbin(im)
    except Exception as exc:
        # 整批裁剪均匀（全白/全黑）时 nlbin 判空抛错，与逐行模式的
        # _prepare_line_safe 同口径：整批按空行返回而非 500。裁剪是
        # 本批全部框的包围盒，包围盒均匀 ⇒ 每个框都均匀（都无墨），
        # 典型来源：整行字框全是无墨空位槽（tighten 保留的空格条带）
        # 或纯白页边里检出的假行——一条空白行不应拖垮整个请求。
        if not _is_empty_image_error(exc):
            raise
        tlog(f"[skip-empty] batch crop uniform, {len(rects)} lines as empty")
        empty = []
        for r in rects:
            line = _empty_line_result(r)
            line["x"] += off_x  # 批内坐标已平移到裁剪系，还原全图坐标
            line["y"] += off_y
            empty.append(line)
        return {"lines": empty}
    tlog(f"binarize done, {len(rects)} lines to recognize")

    seg_lines = []
    geoms = []
    for i, rect in enumerate(rects):
        baseline, boundary, vertical = _line_geometry(
            rect, text_direction, scale, im.width, im.height
        )
        geoms.append((baseline, boundary, vertical))
        seg_lines.append(
            BaselineLine(id=i, baseline=baseline, boundary=boundary)
        )
    seg = Segmentation(
        type="baselines",
        imagename=str(image_path),
        text_direction=text_direction,
        script_detection=False,
        lines=seg_lines,
    )

    out_lines = []
    for rect, (baseline, boundary, vertical), record in zip(
        rects, geoms, rpred.rpred(rec, im, seg, no_legacy_polygons=True)
    ):
        line = _record_to_line(record, rect, scale, 0.0, vertical)
        # 裁剪快速路径的偏移平移回全图坐标
        line["x"] += off_x
        line["y"] += off_y
        for c in line["chars"]:
            c["x"] += off_x
            c["y"] += off_y
        out_lines.append(line)
    tlog(f"all {len(out_lines)} lines done")
    return {"lines": out_lines}


def _write_response(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def _load_model():
    from kraken.lib.models import load_any

    global _DEVICE
    try:
        import torch

        device = "cuda" if torch.cuda.is_available() else "cpu"
    except Exception:
        device = "cpu"
    rec_model = _effective_rec_model()
    tlog(f"load model: {rec_model} (device={device})")
    t0 = time.time()
    try:
        rec = load_any(str(rec_model), device=device)
    except Exception as exc:
        if device == "cuda":
            tlog(f"cuda load failed ({exc}), fallback to cpu")
            device = "cpu"
            rec = load_any(str(rec_model), device=device)
        else:
            raise
    _DEVICE = device
    tlog(f"model loaded on {device} in {time.time() - t0:.1f}s, waiting for requests")
    return rec


def _release_vram_cache() -> None:
    """请求结束后把 caching allocator 持有的空闲显存块还给系统（仅 CUDA）。

    allocator 只增不减：daemon 显存会从空载 ~1.5GB 棘轮式涨到历史峰值
    （实测 2.5~3.4GB），N 个 daemon 叠加把整卡打满后 WDDM 转用共享内存
    换页、吞吐塌缩——整书识别"显存到顶就停摆"的根源。每请求释放一次，
    单 daemon 稳态回到「上下文+模型+单请求峰值」；代价是下个请求重新
    cudaMalloc（毫秒级，相对百毫秒~秒级的推理可忽略）。"""
    if _DEVICE != "cuda":
        return
    try:
        import torch

        torch.cuda.empty_cache()
    except Exception:
        pass


def daemon_loop() -> int:
    rec = _load_model()
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
                    {"id": req_id, "ok": True,
                     "result": {"pong": True, "device": _DEVICE}}
                )
            elif op == "shutdown":
                _write_response({"id": req_id, "ok": True, "result": {"bye": True}})
                tlog("shutdown requested, daemon exit")
                return 0
            else:
                try:
                    if op == "read_page":
                        # 整页直读（blla 分行 + rpred）：不走标注切分管线。
                        result = _op_read_page(rec, req.get("payload") or {})
                    elif op == "read_line":
                        # 整行全文直读（全文对照用）：单行框直接走逐行
                        # 预处理+识别，不经字框切分。
                        result = _op_read_line(rec, req.get("payload") or {})
                    else:
                        result = _recognize(rec, req.get("payload") or {})
                finally:
                    # 成败都释放：失败请求的半途分配同样会占住峰值水位。
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
