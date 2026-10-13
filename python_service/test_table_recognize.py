# -*- coding: utf-8 -*-
"""table_recognize 测试：格方向判定、格内阅读序（横竖版 + rtl/btt）、
识别编排（Kraken 逐字读 mock，切字走真实连通域）。"""
from __future__ import annotations

import os
import tempfile
import unittest
from unittest.mock import patch

import cv2
import numpy as np

from table_recognize import (
    _order_rects,
    cell_orientation,
    recognize_table,
)
from test_table_grid import _draw_grid, _save_page, _white_page


def _stamp_chars(canvas, cells_xy, size=18):
    """在每格内画 2~3 个小方块模拟字（连通域切字的墨迹来源）。返回
    {格序号: [字框]}，字框为绝对坐标。"""
    boxes = {}
    for idx, (cx, cy) in enumerate(cells_xy):
        rects = []
        chars = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛"]
        for k in range(2 + idx % 2):
            x = cx + 6
            y = cy + 6 + k * 26
            cv2.rectangle(canvas, (x, y), (x + size, y + size), (0, 0, 0), -1)
            rects.append((x - 2, y - 2, size + 4, size + 4))
        boxes[idx] = rects
    return boxes


class CellOrientationTests(unittest.TestCase):
    def test_tall_cell_vertical_wide_cell_horizontal(self):
        self.assertEqual(cell_orientation({"w": 40, "h": 200}, "vertical"), "vertical")
        self.assertEqual(cell_orientation({"w": 40, "h": 200}, "horizontal"), "vertical")
        self.assertEqual(cell_orientation({"w": 200, "h": 40}, "vertical"), "horizontal")
        self.assertEqual(cell_orientation({"w": 200, "h": 40}, "horizontal"), "horizontal")

    def test_square_cell_follows_page(self):
        self.assertEqual(cell_orientation({"w": 100, "h": 100}, "vertical"), "vertical")
        self.assertEqual(cell_orientation({"w": 100, "h": 100}, "horizontal"), "horizontal")


class OrderRectsTests(unittest.TestCase):
    def test_vertical_rtl_columns_right_first(self):
        # 两列竖排（右列 x 大），rtl（古籍从右往左）→ 右列先读
        rects = [(30, 0, 20, 20), (30, 40, 20, 20), (100, 0, 20, 20), (100, 40, 20, 20)]
        ordered = _order_rects(rects, "vertical", "rtl", "ttb")
        self.assertEqual([r[0] for r in ordered], [100, 100, 30, 30])
        self.assertEqual([r[1] for r in ordered], [0, 40, 0, 40])

    def test_vertical_ltr_columns_left_first_btt(self):
        rects = [(30, 0, 20, 20), (30, 40, 20, 20), (100, 0, 20, 20)]
        ordered = _order_rects(rects, "vertical", "ltr", "btt")
        self.assertEqual([r[0] for r in ordered], [30, 30, 100])
        # 左列内 btt：y 降序 [40, 0]；右列单字 y=0
        self.assertEqual([r[1] for r in ordered], [40, 0, 0])

    def test_horizontal_rows_then_inline_dir(self):
        rects = [(0, 0, 20, 20), (40, 0, 20, 20), (0, 60, 20, 20)]
        ltr = _order_rects(rects, "horizontal", "ltr", "ttb")
        self.assertEqual([(r[0], r[1]) for r in ltr],
                         [(0, 0), (40, 0), (0, 60)])
        rtl = _order_rects(rects, "horizontal", "rtl", "ttb")
        self.assertEqual([(r[0], r[1]) for r in rtl],
                         [(40, 0), (0, 0), (0, 60)])


class RecognizeTableTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def test_cells_get_text_in_reading_order(self):
        canvas = _white_page()
        _draw_grid(canvas, 100, 80, 700, 560, n_rows=2, n_cols=3)
        # 每格左上角附近放两枚"字"
        xs = np.linspace(100, 700, 4).astype(int)
        ys = np.linspace(80, 560, 3).astype(int)
        for r in range(2):
            for c in range(3):
                for k in range(2):
                    x = int(xs[c]) + 20
                    y = int(ys[r]) + 20 + k * 40
                    cv2.rectangle(canvas, (x, y), (x + 18, y + 18), (0, 0, 0), -1)
        path = _save_page(canvas, self._tmp.name)

        def fake_rec(image_path, boxes, orientation, horizontal_dir, pad=True):
            return [{"text": "字", "conf": 0.9} for _ in boxes]

        with patch("table_recognize._recognize_char_boxes", side_effect=fake_rec):
            result = recognize_table(path, 90, 70, 620, 500, "vertical",
                                     "ltr", "ttb")
        self.assertTrue(result["ok"], result)
        self.assertEqual((result["rows"], result["cols"]), (2, 3))
        self.assertEqual(len(result["cells"]), 6)
        for cell in result["cells"]:
            self.assertEqual(cell["text"], "字字", cell)
            self.assertEqual(len(cell["chars"]), 2)
            self.assertTrue(cell["chars"][0]["conf"] > 0)
        # 阅读序：第一格是左上（ltr 列序）
        first = result["cells"][0]
        self.assertEqual((first["row"], first["col"]), (0, 0))

    def test_kraken_failure_keeps_geometry(self):
        canvas = _white_page()
        _draw_grid(canvas, 100, 80, 700, 560, n_rows=2, n_cols=2)
        # 格内要有字才会触发逐字识别调用
        cv2.rectangle(canvas, (130, 110), (148, 128), (0, 0, 0), -1)
        path = _save_page(canvas, self._tmp.name)

        def boom(*a, **k):
            raise RuntimeError("daemon down")

        with patch("table_recognize._recognize_char_boxes", side_effect=boom):
            result = recognize_table(path, 90, 70, 620, 500)
        # 几何仍完整返回，文字空，失败原因可见
        self.assertTrue(result["ok"])
        self.assertEqual(result["ocr"], "unavailable")
        self.assertIn("daemon down", result["reason"])
        self.assertTrue(all(c["text"] == "" for c in result["cells"]))
        self.assertEqual(len(result["cells"]), 4)

    def test_no_grid_reports_reason(self):
        canvas = _white_page()
        path = _save_page(canvas, self._tmp.name)
        result = recognize_table(path, 50, 50, 400, 300)
        self.assertFalse(result["ok"])
        self.assertIn("格线", result["reason"])


if __name__ == "__main__":
    unittest.main()
