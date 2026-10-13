# -*- coding: utf-8 -*-
"""apply_kraken_recognition 并行路径 ≡ 串行路径 的等价性测试。

用无状态的 fake recognize_lines（输出只依赖输入几何，与调用顺序无关）
分别跑串行（KRAKEN_LINE_TASKS=0）与并行（伪池 size=3）两条路径，断言
归一化时间戳后的输出逐字节一致——并行化只改调度、不改任何一行/一字
的识别内容，这是"提速不降精度"的回归守门员。
"""

import copy
import json
import re
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import kraken_bridge
import kraken_proc
from kraken_bridge import apply_kraken_recognition
from segmenter import make_kraken_char_splitter

VOCAB = list("乾坤震巽坎離艮兌")


def _make_fake(track: set | None = None):
    """包一层无状态 fake：可选记录阶段二（per_line=False）调用的线程 id，
    用于断言并行路径真的在多线程里跑。"""

    def fake(image_path, line_rects, orientation="vertical", horizontal_dir="rtl",
             scale=2.0, per_line=True):
        if track is not None and not per_line:
            track.add(threading.get_ident())
        return _fake_recognize_lines(
            image_path, line_rects, orientation, horizontal_dir, scale, per_line
        )

    return fake


def _write_vertical_page(path, cols: int = 3, rows: int = 3) -> None:
    """竖排测试页：cols 列 × rows 个堆叠墨块（黑底白纸由 PIL 绘制）。"""
    from PIL import Image, ImageDraw

    cell = 44
    img = Image.new("L", (cols * cell + 20, rows * cell + 20), 255)
    draw = ImageDraw.Draw(img)
    for c in range(cols):
        for r in range(rows):
            x0 = 10 + c * cell + 12
            y0 = 10 + r * cell + 10
            draw.rectangle((x0, y0, x0 + 20, y0 + 28), fill=0)
    img.save(path)


def _fake_recognize_lines(
    image_path, line_rects, orientation="vertical", horizontal_dir="rtl",
    scale=2.0, per_line=True,
):
    """无状态 fake：结果只由输入几何决定（并行/串行调用顺序无关）。"""

    def _char_for(x: int, y: int) -> str:
        return VOCAB[(x // 7 + y // 5) % len(VOCAB)]

    if per_line:
        out = []
        for r in line_rects:
            n = 3
            chars = []
            for k in range(n):
                cy = int(r["y"] + r["h"] * (k + 0.5) / n) - 8
                cx = int(r["x"] + r["w"] * 0.25)
                chars.append({
                    "x": int(r["x"]), "y": max(0, cy), "w": int(r["w"]),
                    "h": 16, "text": _char_for(cx, cy), "conf": 0.9,
                })
            out.append({
                "x": int(r["x"]), "y": int(r["y"]), "w": int(r["w"]), "h": int(r["h"]),
                "text": "".join(c["text"] for c in chars),
                "conf": 0.9, "chars": chars,
            })
        return out
    return [
        {"text": _char_for(int(r["x"]), int(r["y"])), "conf": 0.95}
        for r in line_rects
    ]


class _FakePool:
    def __init__(self, size: int = 3):
        self.size = size


def _normalize(obj) -> str:
    """序列化并归一化 id 里的毫秒时间戳（k_{stamp}_{idx}_{order}）。"""
    s = json.dumps(obj, ensure_ascii=False, sort_keys=True)
    return re.sub(r"k_\d+_(\d+)_", r"k_X_\1_", s)


def _base_result() -> dict:
    lines = []
    for i in range(3):
        lines.append({
            "id": f"l_{i}", "line_no": i,
            "x": 10 + i * 44, "y": 10, "w": 44, "h": 3 * 44,
        })
    return {"engine": "hier", "lines": lines}


class ParallelEquivTests(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.image = Path(self._tmp.name) / "page.png"
        _write_vertical_page(self.image)
        self._saved_pool = kraken_proc._pool
        self.addCleanup(self._restore_pool)

    def _restore_pool(self):
        kraken_proc._pool = self._saved_pool

    def _run(self, parallel: bool, track: set | None = None) -> dict:
        import os

        old = os.environ.get("KRAKEN_LINE_TASKS")
        os.environ["KRAKEN_LINE_TASKS"] = "0" if not parallel else "1"
        try:
            result = copy.deepcopy(_base_result())
            with patch(
                "kraken_bridge.recognize_lines", side_effect=_make_fake(track)
            ):
                kraken_proc._pool = _FakePool(3) if parallel else None
                out = apply_kraken_recognition(
                    result, str(self.image), "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(self.image), "vertical", "rtl"
                    ),
                )
        finally:
            if old is None:
                os.environ.pop("KRAKEN_LINE_TASKS", None)
            else:
                os.environ["KRAKEN_LINE_TASKS"] = old
        return out

    def test_parallel_output_identical_to_serial(self):
        serial = self._run(parallel=False)
        parallel = self._run(parallel=True)
        self.assertGreater(len(serial["blocks"]), 0)
        self.assertEqual(
            _normalize(serial), _normalize(parallel),
            "并行路径输出必须与串行路径逐字节一致（归一化时间戳后）",
        )

    def test_parallel_actually_used_threads(self):
        # 防退化：并行跑法必须真的在多个线程里执行行任务（阶段二调用来自
        # ≥2 个线程）；串行跑法则始终单线程。
        stage2_threads: set = set()
        self._run(parallel=True, track=stage2_threads)
        self.assertGreaterEqual(
            len(stage2_threads), 2,
            f"并行路径应使用多线程执行行任务，实际 {stage2_threads}",
        )
        serial_threads: set = set()
        self._run(parallel=False, track=serial_threads)
        self.assertEqual(len(serial_threads), 1)


if __name__ == "__main__":
    unittest.main()
