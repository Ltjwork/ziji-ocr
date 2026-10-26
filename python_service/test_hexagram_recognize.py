# -*- coding: utf-8 -*-
"""hexagram_recognize 编排测试：mock 引擎适配器（几何走真实检测，读字
走脚本），覆盖逐字读装配、纳甲互证校验、误读捕获、引擎失败回落。"""
from __future__ import annotations

import os
import tempfile
import unittest

import cv2
import numpy as np

import hexagram_recognize
from hexagram_recognize import recognize_hexagram
from test_hexagram_chart import _draw_mark, _draw_stack, _save_page, _white_page

# 乾卦（自下而上全阳）：纳甲定表 子/寅/辰/午/申/戌。
_QIAN = "111111"
_NAJIA_BRANCHES = ["子", "寅", "辰", "午", "申", "戌"]


class _FakeAdapter:
    """按到达顺序回字的假适配器（记录请求，脚本耗尽回空）。"""

    ocr_tag = "fake-test"

    def __init__(self, texts: list[str]):
        self.texts = list(texts)
        self.calls: list[list[tuple]] = []

    def read_char_boxes(self, image_path, rects, orientation,
                        horizontal_dir, pad=True):
        self.calls.append(list(rects))
        out = []
        for _r in rects:
            text = self.texts.pop(0) if self.texts else ""
            out.append({"text": text, "conf": 0.9})
        return out


class RecognizeHexagramTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self._orig_adapter = hexagram_recognize._engine_adapter

    def tearDown(self):
        hexagram_recognize._engine_adapter = self._orig_adapter

    def _patch(self, adapter: _FakeAdapter):
        hexagram_recognize._engine_adapter = (
            lambda engine, model: adapter
        )

    def _qian_page(self) -> str:
        """乾卦（100,80），右列自下而上标 子寅辰午申戌。"""
        canvas = _white_page()
        _draw_stack(canvas, 100, 80, 40, 120, 5, _QIAN)
        for pos in range(1, 7):
            cy = 80 + (6 - pos) * 40 + 2  # 条带中心 y
            _draw_mark(canvas, 100 + 120 + 40, cy)
        return _save_page(canvas, self._tmp.name)

    def test_full_flow_najia_match(self):
        path = self._qian_page()
        fake = _FakeAdapter(list(_NAJIA_BRANCHES))
        self._patch(fake)
        result = recognize_hexagram(path, 20, 20, 300, 320)
        self.assertTrue(result["ok"], result)
        # 卦体：乾为天 ䷀（几何判定，与读字无关）
        self.assertEqual(result["hexagram"]["king_wen"], 1)
        self.assertEqual(result["hexagram"]["full_name"], "乾为天")
        # 字框装配：一批一次请求，pos 1..6 右侧各一字
        self.assertEqual(len(fake.calls), 1)
        self.assertEqual(len(fake.calls[0]), 6)
        for pos, expect in enumerate(_NAJIA_BRANCHES, start=1):
            ln = result["lines"][pos - 1]
            self.assertEqual(ln["right"][0]["text"], expect)
            self.assertEqual(ln["najia"], result["najia"][pos - 1])
        # 纳甲互证：6/6 吻合
        self.assertTrue(result["validation"]["ok"], result["validation"])
        self.assertEqual(result["validation"]["najia"]["verdict"], "match")
        # 证据产物
        self.assertTrue(result["crop"])
        self.assertTrue(result["lines"][0]["right"][0]["thumb"])
        self.assertIn("<svg", result["svg"])
        self.assertIn("䷀", result["svg"])
        self.assertTrue(any("几何" in ln for ln in result["log"]))

    def test_misread_char_flagged(self):
        path = self._qian_page()
        # 第二爻读错成"李"（干支字表外）
        self._patch(_FakeAdapter(["子", "李", "辰", "午", "申", "戌"]))
        result = recognize_hexagram(path, 20, 20, 300, 320)
        self.assertTrue(result["ok"])  # 识别本身成功
        self.assertFalse(result["validation"]["ok"])
        self.assertTrue(any(
            "李" in e for e in result["validation"]["errors"]))

    def test_engine_failure_keeps_geometry(self):
        path = self._qian_page()

        class _Boom:
            ocr_tag = "boom"

            def read_char_boxes(self, *_a, **_k):
                raise RuntimeError("daemon down")

        hexagram_recognize._engine_adapter = lambda e, m: _Boom()
        result = recognize_hexagram(path, 20, 20, 300, 320)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["hexagram"]["name"], "乾")
        self.assertEqual(
            result["lines"][0]["right"][0]["text"], "")
        self.assertTrue(any("逐字读失败" in ln for ln in result["log"]))

    def test_geometry_failure_passthrough(self):
        path = _save_page(_white_page(), self._tmp.name)
        self._patch(_FakeAdapter([]))
        result = recognize_hexagram(path, 20, 20, 300, 320)
        self.assertFalse(result["ok"])
        self.assertIn("未检测到", result["reason"])


if __name__ == "__main__":
    unittest.main()
