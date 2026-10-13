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

import time

import kraken_bridge
from kraken_bridge import (
    _recognize_lines_sharded,
    _pad_boxes_for_reading,
    log,
    text_direction,
)
import paddle_proc


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
        self.model = paddle_proc.normalize_model(model)
        self.name = "paddle"
        self.ocr_tag = f"paddle+{self.model}"
        self.char_source = self.ocr_tag
        self.cuts_src = "paddle-even-strips"
        self.horizontal_line_read = True  # PP-OCR 原生横排域，横排行直读
        self.vertical_line_read = False  # 竖排无域：序列由字框拼条补读
        self.strip_read = True
        self.skip_note = "PP-OCR 无竖排域"

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


def apply_paddle_recognition(
    result: dict,
    image_path: str,
    orientation: str,
    horizontal_dir: str,
    char_splitter=None,
    model: str | None = None,
) -> dict:
    """/segment 结果后处理（PaddleOCR）：复用 apply_recognition 引擎无关核心。"""
    return kraken_bridge.apply_recognition(
        result,
        image_path,
        orientation,
        horizontal_dir,
        char_splitter,
        adapter=PaddleEngineAdapter(model),
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
    """行框级识别入口（kraken_segment_rect 的 paddle 版，参数同构）。"""
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
        adapter=PaddleEngineAdapter(model),
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
