# -*- coding: utf-8 -*-
"""服务 ↔ PaddleOCR 环境的桥接。

paddleocr（paddlepaddle + paddleocr，见 install_paddleocr.bat）装在独立
conda 环境，经 paddle_proc 的常驻 worker 池（paddle_worker.py daemon）
识别；识别管线（切分/对齐/融合）复用 kraken_bridge 的引擎无关核心
apply_recognition / segment_line_core，本模块只提供 PaddleEngineAdapter
与同名薄包装（apply_paddle_recognition / paddle_segment_rect /
paddle_recognize_char）。

与 Kraken 的引擎差异（预处理细节见 paddle_worker.py）：
- PP-OCR 识别模型只有横排域：横排行直读；竖排行不直读（旋转会把直立
  字形放倒出乱码），整行序列读法由 read_strip_chars 用"字框裁剪→等高
  拼横条"实现——与逐字读法构成互相独立的第二路，融合层完全复用。
- 无 cuts：整行读法只给文本，kchars 的字框几何按阅读轴均分合成（仅供
  对齐与兜底）；像素切分失败时兜底 = 均分条带收紧（cuts_src）。
"""
from __future__ import annotations

import json
import os
import time

import kraken_bridge
from kraken_bridge import (
    _recognize_lines_sharded,
    _pad_boxes_for_reading,
    log,
    text_direction,
)
import paddle_proc

# 表格识别 VL spotting 的单请求超时（秒）：交互场景用户在界面等结果，
# 预算远小于 read_page 的后台直读档（READ_TIMEOUT_VL=900s）。显存被
# kraken 池挤爆时 VL 推理会挂到分钟级（2026-10-23 实测 spotting 900s
# 烧满超时、历史日志零成功），超时后回落逐字/序列读法 ~10s 出结果，
# 不能让用户干等 15 分钟。显存宽裕的健康机器 spotting 常见几十秒，
# 180s 已留足余量；PADDLE_VL_SPOT_TIMEOUT 可调。
SPOT_TIMEOUT = float(os.environ.get("PADDLE_VL_SPOT_TIMEOUT", "180"))


def _synthesize_seq_chars(
    rect: dict, text: str, conf: float, orientation: str
) -> list[dict]:
    """整行读法文本 → 序列字列表（kchars 同构）。

    PP-OCR 识别只输出整行文本与置信度（无逐字几何），字框按阅读轴均分
    合成——几何只在两处被消费：_align_sequence_entries 的中心对齐（均分
    后中心单调，对齐可用）与切分失败时的兜底条带（均分即条带，收紧后
    即最终框），均不需要真实逐字几何。"""
    text = text or ""
    n = len(text)
    if n == 0:
        return []
    x, y = int(rect.get("x", 0)), int(rect.get("y", 0))
    w, h = int(rect.get("w", 0)), int(rect.get("h", 0))
    out: list[dict] = []
    if orientation == "horizontal":
        step = w / n
        for i, ch in enumerate(text):
            out.append(
                {
                    "x": x + int(i * step),
                    "y": y,
                    "w": max(1, int(step)),
                    "h": h,
                    "text": ch,
                    "conf": round(float(conf), 4),
                }
            )
    else:
        step = h / n
        for i, ch in enumerate(text):
            out.append(
                {
                    "x": x,
                    "y": y + int(i * step),
                    "w": w,
                    "h": max(1, int(step)),
                    "text": ch,
                    "conf": round(float(conf), 4),
                }
            )
    return out


class PaddleEngineAdapter:
    """kraken_bridge._KrakenEngineAdapter 的 PaddleOCR 实现。

    model 绑定识别模型档位（PP-OCRv6 tiny/small/medium _rec）；池由
    paddle_proc.ensure_pool(model) 按模型懒建/重建。"""

    def __init__(self, model: str | None = None):
        # 行/字识别适配器统一走 line_model：VL 选择在此回退 small
        # （VL 仅整页直读；read_page_text 不经适配器、仍用 VL）。
        self.model = paddle_proc.line_model(model)
        self.name = "paddle"
        self.ocr_tag = f"paddle+{self.model}"
        self.char_source = self.ocr_tag
        self.cuts_src = "paddle-even-strips"
        self.horizontal_line_read = True  # PP-OCR 原生横排域，横排行直读
        self.vertical_line_read = False  # 竖排无域：序列由字框拼条补读
        self.strip_read = True
        self.skip_note = "PP-OCR 无竖排域"

    def read_line_full(
        self,
        image_path: str,
        rect: dict,
        orientation: str = "vertical",
        horizontal_dir: str = "rtl",
        vertical_dir: str = "ttb",
    ) -> dict:
        """整行全文直读（全文对照用）：行框裁图整体识别，不经字框切分
        ——标点等无框字符也会被读出。竖排旋转进 PP-OCR 横排域（v5/v6
        原生支持，rotate 90/270 对应 ttb/btt 列首方向）。池未就绪时抛错
        （对照是增强路，绝不懒起池）。"""
        if paddle_proc.pool_size() <= 0:
            raise RuntimeError("paddle 池未就绪，跳过全文对照")
        rotate = 0
        if orientation != "horizontal":
            rotate = 270 if vertical_dir == "btt" else 90
        pool = paddle_proc.ensure_pool(self.model)
        return pool.request(
            "read_line",
            {"image_path": image_path, "rect": rect, "rotate": rotate},
            timeout=paddle_proc.read_timeout(),
        )

    def pool_size(self) -> int:
        return paddle_proc.pool_size()

    def read_lines(
        self,
        image_path: str,
        line_rects: list[dict],
        orientation: str = "vertical",
        horizontal_dir: str = "rtl",
    ) -> list[dict]:
        """整行序列读法。管线只在本引擎的可达方向（横排）调到这里。

        返回与 kraken recognize_lines 同构：每项 {x,y,w,h,text,conf,chars}，
        chars 由 _synthesize_seq_chars 按均分合成（含序列逐字文本）。"""
        if not line_rects:
            return []
        direction = text_direction(orientation, horizontal_dir)
        pool = paddle_proc.ensure_pool(self.model)
        shard = len(line_rects) > 1 and pool.size > 1
        log(
            f"paddle recognize {len(line_rects)} lines"
            + (f" ×{min(len(line_rects), pool.size)} shards" if shard else "")
        )
        t0 = time.time()
        if shard:
            # 与 kraken 同款按行分片（payload 协议相同，pool.request 同接口）
            lines = _recognize_lines_sharded(
                pool, image_path, line_rects, 1.0, direction
            )
        else:
            payload = {
                "image_path": image_path,
                "scale": 1.0,
                "text_direction": direction,
                "per_line": True,
                "lines": [
                    {
                        "x": int(r["x"]), "y": int(r["y"]),
                        "w": int(r["w"]), "h": int(r["h"]),
                    }
                    for r in line_rects
                ],
            }
            lines = pool.request("recognize", payload).get("lines", [])
        for line in lines:
            # paddle worker 不回逐字几何：按均分合成 kchars（阅读轴无关，
            # 均分对称）。分片兜底的空行 text 为空，chars 自然为空。
            line["chars"] = _synthesize_seq_chars(
                line, line.get("text") or "", float(line.get("conf") or 0.0),
                orientation,
            )
        log(f"paddle done: {len(lines)} lines in {time.time() - t0:.1f}s")
        return lines

    def read_char_boxes(
        self,
        image_path: str,
        boxes: list[tuple[int, int, int, int]],
        orientation: str,
        horizontal_dir: str,
        pad: bool = True,
    ) -> list[dict]:
        """逐字框读法：自动切分框先外扩边距再读（kraken 同语义）。"""
        if not boxes:
            return []
        read_boxes = _pad_boxes_for_reading(boxes, orientation) if pad else boxes
        payload = {
            "image_path": image_path,
            "boxes": [
                {
                    "x": int(b[0]), "y": int(b[1]),
                    "w": int(b[2]), "h": int(b[3]),
                }
                for b in read_boxes
            ],
        }
        t0 = time.time()
        lines = paddle_proc.ensure_pool(self.model).request(
            "read_boxes", payload
        ).get("lines", [])
        log(f"paddle per-char recognition: {len(read_boxes)} boxes in {time.time() - t0:.1f}s")
        return lines

    def read_strip_chars(
        self,
        image_path: str,
        rect: dict,
        boxes: list[tuple[int, int, int, int]],
        orientation: str,
        horizontal_dir: str,
    ) -> list[dict]:
        """竖排整行序列读法（字框拼横条）：返回合成 kchars，空序列返回 []。"""
        payload = {
            "image_path": image_path,
            "rect": {
                "x": int(rect.get("x", 0)), "y": int(rect.get("y", 0)),
                "w": int(rect.get("w", 0)), "h": int(rect.get("h", 0)),
            },
            "boxes": [
                {
                    "x": int(b[0]), "y": int(b[1]),
                    "w": int(b[2]), "h": int(b[3]),
                }
                for b in boxes
            ],
        }
        result = paddle_proc.ensure_pool(self.model).request("read_strip", payload)
        text = result.get("text") or ""
        conf = float(result.get("conf") or 0.0)
        return _synthesize_seq_chars(rect, text, conf, orientation)


def detect_page_lines(
    image_path: str,
    model: str | None = None,
) -> list[tuple[int, int, int, int]]:
    """PP-OCR det 行检测（engine=paddle 的行框来源，官网演示同款检测）。

    自训 YOLO 字框分组在部分影印本上碎片/粘连/漏检严重（整列漏检、句号
    成独立行、夹注并进正文）；PP-OCR det 对同一页面行框准确。池跟随行
    识别档位（line_model：VL 选择回退 small）。OCR_PADDLE_DET_LINES=0
    可整体停用（回退 YOLO 行框）。返回未排序 (x,y,w,h) 列表；空列表/
    异常由调用方回退 YOLO 链路。"""
    if os.environ.get("OCR_PADDLE_DET_LINES", "1").strip() == "0":
        return []
    adapter_model = paddle_proc.line_model(model)
    result = paddle_proc.ensure_pool(adapter_model).request(
        "detect_lines",
        {"image_path": image_path},
        timeout=paddle_proc.read_timeout(),
    )
    return [
        (int(l["x"]), int(l["y"]), int(l["w"]), int(l["h"]))
        for l in result.get("lines", [])
        if isinstance(l, dict)
    ]


# ── 整页直读参照（全文对照的页级参照源）──────────────────────────────
# 单字识别与整页直读（文本视图）对不上是常态（切字框漏标点、逐字读法
# 误读）——对照参照改用整页直读的行文本：与用户在文本视图所见同一份
# （VL 选择时带标点），标注行按行框 IoU 对齐取文本。参照读文本视图
# 直读时落盘的行记录（direct_text/<pageId>.meta.json 的 line_records，
# 零额外推理）；不做后端自动页读——VL 冷读在显存被挤时可达分钟级，
# 进识别请求会拖垮整体耗时（实测 300s/900s 预算都被超时掐断），参照
# 缺位时全文对照自动回退逐行直读（read_line_full）。
def _sidecar_page_lines(image_path: str) -> list | None:
    """direct_text 侧车 → 行记录 [{x,y,w,h,text}]（页面图同目录的
    direct_text/<stem>.meta.json）。缺文件/坏 JSON/无记录返回 None。"""
    folder = os.path.dirname(image_path) or "."
    stem = os.path.splitext(os.path.basename(image_path))[0]
    meta_path = os.path.join(folder, "direct_text", f"{stem}.meta.json")
    try:
        with open(meta_path, encoding="utf-8") as fh:
            meta = json.load(fh)
    except (OSError, ValueError):
        return None
    records = meta.get("line_records") if isinstance(meta, dict) else None
    lines: list = []
    if isinstance(records, list):
        for rec in records:
            if not isinstance(rec, dict):
                continue
            try:
                x, y = int(rec.get("x", 0)), int(rec.get("y", 0))
                w, h = int(rec.get("w", 0)), int(rec.get("h", 0))
            except (TypeError, ValueError):
                continue
            if w <= 0 or h <= 0:
                continue
            lines.append(
                {"x": x, "y": y, "w": w, "h": h, "text": str(rec.get("text") or "")}
            )
    return lines or None


def attach_page_text_ref(adapter, image_path: str) -> None:
    """给适配器挂整页直读行参照（adapter.page_text_lines，无值则全文
    对照自动回退逐行直读）。增强路：读取失败静默跳过。"""
    if os.environ.get("FULL_TEXT_CHECK", "1") == "0":
        return
    try:
        lines = _sidecar_page_lines(image_path)
    except Exception as exc:
        log(f"[page-ref] 整页参照读取失败（回退逐行直读）: {exc}")
        return
    if not lines:
        return
    adapter.page_text_lines = lines
    log(f"[page-ref] 整页参照就绪: 侧车 {len(lines)} 行")


def is_vl_model(name: str | None) -> bool:
    """模型是否为 PaddleOCR-VL 视觉语言模型（表格识别等按此分流：
    VL 走 spotting 区域读，PP-OCR 系走行/字读法）。"""
    return paddle_proc.normalize_model(name).startswith("PaddleOCR-VL")


def vl_spotting_read(
    image_path: str,
    rect: dict,
    model: str | None = None,
    vl_config: dict | None = None,
    vl_predict: dict | None = None,
) -> dict:
    """VL spotting 区域读（表格识别用，PaddleOCR 官网 Demo 同款能力）：
    裁剪 rect → VL 文本检测与识别 → {"boxes","texts","confs"}（原图
    绝对坐标）。[vl_config] 必须与文本视图同源传入——VL 池按（模型+
    解析配置）绑定，缺省签名不同会与文本视图交替重建池。VL 池懒启动
    （首请求含模型加载/下载）。非 VL 模型会抛 ValueError（调用方回落
    行/字读法）。超时用交互档 SPOT_TIMEOUT（默认 180s，显存被挤时
    快速回落逐字/序列读法，不烧 read_page 的 900s 后台预算）。"""
    payload: dict = {"image_path": image_path, "rect": rect}
    if vl_predict:
        payload["vl_predict"] = vl_predict
    return paddle_proc.ensure_pool(
        paddle_proc.normalize_model(model), vl_config=vl_config,
    ).request(
        "read_spotting", payload, timeout=SPOT_TIMEOUT
    )


def read_page_text(
    image_path: str,
    orientation: str,
    horizontal_dir: str,
    vertical_dir: str = "ttb",
    model: str | None = None,
    vl_config: dict | None = None,
    vl_predict: dict | None = None,
    gate_regions: list[dict] | None = None,
    progress_token: str | None = None,
) -> dict:
    """整页直读（PaddleOCR det+rec 全管线），不走标注切分管线。

    PP-OCRv5 起检测+识别原生支持竖排文本，页面无需旋转；worker 返回未
    排序行列表，阅读序由 page_text 按方向参数重排后拼接。vl_config 是
    VL 模型的解析配置（池绑定开关，书级设置）；vl_predict 是 predict
    级参数（Prompt 类型/生成参数/辅助内容忽略清单，随每次请求），非
    VL 模型两者都忽略。gate_regions：排除类版面区（文本视图「排除页
    眉页脚」开关的输入，由 /read_page_text 预先算好传入），拼接前整行
    剔除；None/空 = 不过滤（历史行为）。progress_token：进度登记
    （read_progress），准备引擎/读字/拼接各阶段打点供客户端轮询；
    None = 不登记。"""
    from page_text import lines_to_page_text

    def _stage(stage: str, detail: str) -> None:
        from read_progress import set_stage

        set_stage(progress_token, stage, detail)

    _stage("preparing", "加载 PaddleOCR 模型（首次/冷启动加载可达数分钟）…")
    adapter_model = paddle_proc.normalize_model(model)
    pool = paddle_proc.ensure_pool(adapter_model, vl_config=vl_config)
    payload: dict = {
        "image_path": image_path,
        # 方向参数给 VL 混合合并做段落切片的阅读序（版面分析开启时 VL
        # 块是整段段落，需按阅读序切回行；旧 worker 忽略该字段）。
        "orientation": orientation,
        "horizontal_dir": horizontal_dir,
        "vertical_dir": vertical_dir,
    }
    if vl_predict:
        payload["vl_predict"] = vl_predict
    _stage(
        "reading",
        "引擎读字中…（VL 为一整页一次推理；首读或显存被挤时可能数分钟）",
    )
    result = pool.request(
        "read_page",
        payload,
        timeout=paddle_proc.read_timeout(),
    )
    lines = result.get("lines", [])
    excluded_lines = 0
    if gate_regions:
        _stage("gating", "按版面区剔除页眉页脚行…")
        from seg_layout import filter_page_text_lines

        lines, excluded_lines = filter_page_text_lines(lines, gate_regions)
    _stage("assembling", "按阅读序拼接整页文本…")
    text, ordered = lines_to_page_text(
        lines, orientation, horizontal_dir, vertical_dir
    )
    return {
        "text": text,
        "lines": ordered,
        "engine": "paddle",
        "ocr": f"paddle+{adapter_model}",
        "excluded_lines": excluded_lines,
    }


def apply_paddle_recognition(
    result: dict,
    image_path: str,
    orientation: str,
    horizontal_dir: str,
    char_splitter=None,
    model: str | None = None,
    vertical_dir: str = "ttb",
) -> dict:
    """/segment 结果后处理（PaddleOCR）：复用 apply_recognition 引擎无关核心。"""
    adapter = PaddleEngineAdapter(model)
    attach_page_text_ref(adapter, image_path)
    return kraken_bridge.apply_recognition(
        result,
        image_path,
        orientation,
        horizontal_dir,
        char_splitter,
        adapter=adapter,
        vertical_dir=vertical_dir,
    )


def paddle_segment_rect(
    image_path: str,
    rect: dict,
    line_id: str,
    line_no: int,
    orientation: str,
    horizontal_dir: str,
    char_boxes: list[tuple[int, int, int, int]] | None = None,
    char_splitter=None,
    vertical_dir: str = "ttb",
    strict_char_boxes: bool = False,
    expected_char_count: int | None = None,
    expand: bool = True,
    model: str | None = None,
) -> list[dict]:
    """行框级识别入口（kraken_segment_rect 的 paddle 版，参数同构）。

    整页参照读文本视图直读的侧车行记录：单行重识别与整页识别用同一
    份参照，对照标记口径一致。"""
    adapter = PaddleEngineAdapter(model)
    attach_page_text_ref(adapter, image_path)
    return kraken_bridge.kraken_segment_rect(
        image_path,
        rect,
        line_id,
        line_no,
        orientation,
        horizontal_dir,
        char_boxes=char_boxes,
        char_splitter=char_splitter,
        vertical_dir=vertical_dir,
        strict_char_boxes=strict_char_boxes,
        expected_char_count=expected_char_count,
        expand=expand,
        adapter=adapter,
    )


def paddle_recognize_char(
    image_path: str,
    rect: tuple[int, int, int, int],
    orientation: str,
    horizontal_dir: str,
    model: str | None = None,
) -> dict:
    """单字框识别（kraken recognize_char 的 paddle 版）：{text, conf}。"""
    adapter = PaddleEngineAdapter(model)
    results = adapter.read_char_boxes(
        image_path, [rect], orientation, horizontal_dir, pad=False
    )
    if not results:
        return {"text": "", "conf": 0.0}
    return {
        "text": (results[0].get("text") or "").strip(),
        "conf": float(results[0].get("conf") or 0.0),
    }
