# -*- coding: utf-8 -*-
"""table_grid 格线检测/网格构建测试：合成格线图（规则网格、合并格、
断线、极性、无表格拒判、整页自动检测的界行误报过滤、横竖版对称）。"""
from __future__ import annotations

import os
import tempfile
import unittest

import cv2
import numpy as np

from table_grid import detect_table_grid, detect_tables_in_page


def _save_page(canvas: np.ndarray, directory: str, name: str = "page.png") -> str:
    path = os.path.join(directory, name)
    cv2.imwrite(path, canvas)
    return path


def _white_page(w: int = 900, h: int = 700) -> np.ndarray:
    return np.full((h, w, 3), 255, dtype=np.uint8)


def _draw_grid(
    canvas: np.ndarray,
    x0: int, y0: int, x1: int, y1: int,
    n_rows: int, n_cols: int,
    thickness: int = 2,
    skip_segments: list[tuple[str, int, int]] | None = None,
    breaks: list[tuple[str, int]] | None = None,
    color: tuple[int, int, int] = (0, 0, 0),
) -> None:
    """画 n_rows×n_cols 单元格的表格线。skip_segments 挖掉指定边界线段
    制造合并格：("v", col_idx, row_idx) = 第 col 条竖线在第 row 行带缺；
    breaks=("h", i) 在第 i 条横线上挖 5px 断口 ×2 制造印刷断线。
    color 白底页用黑线、黑底页（极性测试）用白线。"""
    skip_segments = skip_segments or []
    breaks = breaks or []
    xs = np.linspace(x0, x1, n_cols + 1).astype(int)
    ys = np.linspace(y0, y1, n_rows + 1).astype(int)

    def hline(y: int, xa: int, xb: int) -> None:
        cv2.line(canvas, (xa, y), (xb, y), color, thickness)

    def vline(x: int, ya: int, yb: int) -> None:
        cv2.line(canvas, (x, ya), (x, yb), color, thickness)

    for i, y in enumerate(ys):
        if ("h", i) in breaks:
            mid = (x0 + x1) // 2
            hline(y, x0, mid - 3)
            hline(y, mid + 3, x1)
        else:
            hline(y, x0, x1)
    for j, x in enumerate(xs):
        for r in range(n_rows):
            if ("v", j, r) in skip_segments:
                continue
            vline(x, int(ys[r]), int(ys[r + 1]))


class DetectTableGridTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def test_regular_grid(self):
        canvas = _white_page()
        _draw_grid(canvas, 100, 80, 800, 620, n_rows=3, n_cols=3)
        path = _save_page(canvas, self._tmp.name)
        grid = detect_table_grid(path, 90, 70, 720, 560)
        self.assertTrue(grid["ok"], grid)
        self.assertEqual((grid["rows"], grid["cols"]), (3, 3))
        self.assertEqual(len(grid["cells"]), 9)
        self.assertTrue(all(
            c["row_span"] == 1 and c["col_span"] == 1 for c in grid["cells"]))
        # 单元格内容框 = 边界线中心 ± inset（inset≥2），不含格线墨迹。
        # linspace(100, 800, 4) = [100, 333, 566, 800]，首列宽 233。
        c00 = grid["cells"][0]
        self.assertAlmostEqual(c00["x"], 102, delta=3)
        self.assertAlmostEqual(c00["y"], 82, delta=3)
        self.assertAlmostEqual(c00["w"], 229, delta=6)
        # 外框落在最外侧格线上
        self.assertAlmostEqual(grid["x"], 100, delta=3)
        self.assertAlmostEqual(grid["w"], 700, delta=6)

    def test_merged_cell(self):
        canvas = _white_page()
        # 第 2 条竖线在第 2 行带缺失 → (row=1, col=0) 起 col_span=2 的合并格
        _draw_grid(canvas, 100, 80, 800, 620, n_rows=3, n_cols=3,
                   skip_segments=[("v", 1, 1)])
        path = _save_page(canvas, self._tmp.name)
        grid = detect_table_grid(path, 90, 70, 720, 560)
        self.assertTrue(grid["ok"], grid)
        self.assertEqual(len(grid["cells"]), 8)
        merged = [c for c in grid["cells"] if c["col_span"] == 2]
        self.assertEqual(len(merged), 1)
        self.assertEqual((merged[0]["row"], merged[0]["col"]), (1, 0))

    def test_broken_lines_bridged(self):
        canvas = _white_page()
        _draw_grid(canvas, 100, 80, 800, 620, n_rows=3, n_cols=3,
                   breaks=[("h", 1), ("h", 2)])
        path = _save_page(canvas, self._tmp.name)
        grid = detect_table_grid(path, 90, 70, 720, 560)
        self.assertTrue(grid["ok"], grid)
        self.assertEqual((grid["rows"], grid["cols"]), (3, 3))

    def test_plain_border_rejected(self):
        # 纯版框（单矩形环）：1×1 不构成网格
        canvas = _white_page()
        cv2.rectangle(canvas, (100, 80), (800, 620), (0, 0, 0), 2)
        path = _save_page(canvas, self._tmp.name)
        grid = detect_table_grid(path, 50, 40, 810, 630)
        self.assertFalse(grid["ok"])

    def test_text_only_rejected(self):
        # 模拟一列文字（竖排小黑块），无格线
        canvas = _white_page()
        for r in range(10):
            for c in range(3):
                cv2.rectangle(
                    canvas,
                    (120 + c * 60, 80 + r * 55),
                    (140 + c * 60, 100 + r * 55),
                    (0, 0, 0), -1)
        path = _save_page(canvas, self._tmp.name)
        grid = detect_table_grid(path, 80, 50, 300, 600)
        self.assertFalse(grid["ok"])

    def test_white_on_black_polarity(self):
        canvas = np.zeros((700, 900, 3), dtype=np.uint8)
        _draw_grid(canvas, 100, 80, 800, 620, n_rows=2, n_cols=2,
                   color=(255, 255, 255))
        path = _save_page(canvas, self._tmp.name)
        grid = detect_table_grid(path, 50, 40, 810, 630)
        self.assertTrue(grid["ok"], grid)
        self.assertEqual((grid["rows"], grid["cols"]), (2, 2))

    def test_wide_table_landscape(self):
        # 横版宽扁表：4 行 × 8 列
        canvas = _white_page(w=1600, h=500)
        _draw_grid(canvas, 60, 60, 1540, 440, n_rows=4, n_cols=8)
        path = _save_page(canvas, self._tmp.name)
        grid = detect_table_grid(path, 40, 40, 1520, 420)
        self.assertTrue(grid["ok"], grid)
        self.assertEqual((grid["rows"], grid["cols"]), (4, 8))

    def test_tall_table_portrait(self):
        # 竖版窄高表：12 行 × 3 列
        canvas = _white_page(w=500, h=1600)
        _draw_grid(canvas, 60, 60, 440, 1540, n_rows=12, n_cols=3)
        path = _save_page(canvas, self._tmp.name)
        grid = detect_table_grid(path, 40, 40, 420, 1520)
        self.assertTrue(grid["ok"], grid)
        self.assertEqual((grid["rows"], grid["cols"]), (12, 3))

    def test_missing_image(self):
        grid = detect_table_grid(
            os.path.join(self._tmp.name, "none.png"), 0, 0, 100, 100)
        self.assertFalse(grid["ok"])
        self.assertEqual(grid["reason"], "image not found")


class DetectTablesInPageTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def test_finds_table_skips_ruling_lines(self):
        # 页面：右侧年表 3×3 + 左侧正文界行区（8 条横线 + 两侧竖线，
        # cols=1）+ 散字块。界行是整页自动检测的最大误报源。
        canvas = _white_page(w=1400, h=900)
        # 年表
        _draw_grid(canvas, 680, 100, 1320, 700, n_rows=3, n_cols=3)
        # 界行区（模拟古籍行格：横线贯穿 + 左右版框竖线）
        for i in range(9):
            y = 100 + i * 70
            cv2.line(canvas, (80, y), (560, y), (0, 0, 0), 2)
        cv2.line(canvas, (80, 100), (80, 660), (0, 0, 0), 2)
        cv2.line(canvas, (560, 100), (560, 660), (0, 0, 0), 2)
        # 界行间放点"字"
        for r in range(8):
            cv2.rectangle(canvas, (300, 110 + r * 70), (320, 140 + r * 70),
                          (0, 0, 0), -1)
        path = _save_page(canvas, self._tmp.name)
        tables = detect_tables_in_page(path)
        self.assertEqual(len(tables), 1, tables)
        self.assertAlmostEqual(tables[0]["x"], 680, delta=4)
        self.assertEqual((tables[0]["rows"], tables[0]["cols"]), (3, 3))

    def test_no_table_no_false_positive(self):
        canvas = _white_page()
        for r in range(10):
            cv2.rectangle(canvas, (200, 80 + r * 60), (240, 120 + r * 60),
                          (0, 0, 0), -1)
        path = _save_page(canvas, self._tmp.name)
        self.assertEqual(detect_tables_in_page(path), [])

    def test_plain_border_not_reported(self):
        canvas = _white_page()
        cv2.rectangle(canvas, (100, 80), (800, 620), (0, 0, 0), 2)
        path = _save_page(canvas, self._tmp.name)
        self.assertEqual(detect_tables_in_page(path), [])


if __name__ == "__main__":
    unittest.main()
