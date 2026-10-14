# -*- coding: utf-8 -*-
"""整页直读阅读序（page_text.sort_lines_reading_order / lines_to_page_text）
的单元测试。

覆盖：竖排 rtl/ltr 的列序与列内序、列中心抖动不拆列、相邻列不并列、
横排行序与行内序、btt/rtl 行内反向、空输入。
"""
import unittest

import kraken_worker
from page_text import lines_to_page_text, sort_lines_reading_order


def vline(cx: float, y: float, text: str, w: float = 40.0, h: float = 50.0) -> dict:
    """竖排列：窄高框，中心 (cx, y+h/2)。"""
    return {
        "x": int(cx - w / 2),
        "y": int(y),
        "w": int(w),
        "h": int(h),
        "text": text,
        "conf": 0.9,
        "chars": [],
    }


def hline(cy: float, x: float, text: str, w: float = 200.0, h: float = 40.0) -> dict:
    """横排行：宽扁框，中心 (x+w/2, cy)。"""
    return {
        "x": int(x),
        "y": int(cy - h / 2),
        "w": int(w),
        "h": int(h),
        "text": text,
        "conf": 0.9,
        "chars": [],
    }


class VerticalOrderTests(unittest.TestCase):
    def test_rtl_columns_then_rows(self):
        # 两列（右列 x=200、左列 x=100），每列三行；输入顺序打乱。
        lines = [
            vline(100, 100, "左二"), vline(200, 0, "右一"),
            vline(100, 0, "左一"), vline(200, 100, "右二"),
            vline(100, 50, "左中"), vline(200, 50, "右中"),
        ]
        ordered = sort_lines_reading_order(lines, "vertical", "rtl", "ttb")
        self.assertEqual(
            [l["text"] for l in ordered],
            ["右一", "右中", "右二", "左一", "左中", "左二"],
        )

    def test_ltr_column_order(self):
        lines = [vline(200, 0, "右"), vline(100, 0, "左")]
        ordered = sort_lines_reading_order(lines, "vertical", "ltr", "ttb")
        self.assertEqual([l["text"] for l in ordered], ["左", "右"])

    def test_column_wobble_stays_in_column(self):
        # 同列各行中心抖动 ±5px（列宽 40，容差 20）：不得拆列。
        lines = [
            vline(205, 0, "一"), vline(195, 50, "二"),
            vline(200, 100, "三"),
        ]
        ordered = sort_lines_reading_order(lines, "vertical", "rtl", "ttb")
        self.assertEqual([l["text"] for l in ordered], ["一", "二", "三"])

    def test_adjacent_columns_not_merged(self):
        # 两列间距一整列宽（中心差 100 > 容差 20）：不得并作一列。
        lines = [vline(100, 0, "左"), vline(200, 0, "右"), vline(100, 50, "左二")]
        ordered = sort_lines_reading_order(lines, "vertical", "rtl", "ttb")
        self.assertEqual([l["text"] for l in ordered], ["右", "左", "左二"])

    def test_btt_reverses_inline_text(self):
        # btt（从下到上）：列内 y 降序（下面的行先读），行内字符反向。
        lines = [vline(100, 0, "abc"), vline(100, 50, "def")]
        text, ordered = lines_to_page_text(lines, "vertical", "rtl", "btt")
        self.assertEqual(text, "fed\ncba")
        self.assertEqual([l["text"] for l in ordered], ["def", "abc"])


class HorizontalOrderTests(unittest.TestCase):
    def test_rows_top_down_ltr(self):
        lines = [
            hline(100, 0, "第二行"), hline(50, 0, "第一行"),
            hline(50, 300, "第一行右"),  # 同行更靠右（框不重叠的稀疏输出）
        ]
        ordered = sort_lines_reading_order(lines, "horizontal", "ltr", "ttb")
        self.assertEqual(
            [l["text"] for l in ordered],
            ["第一行", "第一行右", "第二行"],
        )

    def test_rtl_reverses_inline_text(self):
        lines = [hline(50, 0, "abc")]
        text, _ = lines_to_page_text(lines, "horizontal", "rtl", "ttb")
        self.assertEqual(text, "cba")

    def test_row_wobble_stays_in_row(self):
        lines = [
            hline(48, 0, "一", w=100), hline(52, 150, "二", w=100),
            hline(50, 300, "三", w=100),
        ]
        text, _ = lines_to_page_text(lines, "horizontal", "ltr", "ttb")
        self.assertEqual(text, "一\n二\n三")


class MiscTests(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(sort_lines_reading_order([], "vertical", "rtl"), [])
        text, ordered = lines_to_page_text([], "vertical")
        self.assertEqual(text, "")
        self.assertEqual(ordered, [])

    def test_text_join_per_line(self):
        lines = [vline(100, 0, "甲乙"), vline(100, 50, "丙丁")]
        text, _ = lines_to_page_text(lines, "vertical", "rtl", "ttb")
        self.assertEqual(text, "甲乙\n丙丁")


class KrakenBandMergeTests(unittest.TestCase):
    """kraken 整页直读的碎片段带状合并（blla 在竖排小图上把列拆成单字级
    碎片，按列中心聚簇取联合框还原整列）。kraken_worker 只依赖标准库，
    服务环境可直接导入测试。"""

    def test_vertical_fragments_merge_into_column(self):
        # 一列拆成三片（列中心 140/150.5/151，容差=列宽中位数一半）→
        # 一条整列框（联合框覆盖三片范围）。
        rects = [
            {"x": 128, "y": 274, "w": 24, "h": 19},
            {"x": 129, "y": 219, "w": 43, "h": 17},
            {"x": 131, "y": 312, "w": 40, "h": 14},
        ]
        merged = kraken_worker._merge_line_rects_by_band(rects, "vertical-rl")
        self.assertEqual(len(merged), 1)
        self.assertEqual(
            (merged[0]["x"], merged[0]["y"], merged[0]["w"], merged[0]["h"]),
            (128, 219, 44, 107),  # 联合框：x=min 128，右缘 max(129+43,131+40)=172
        )

    def test_adjacent_columns_not_merged(self):
        # 两列中心差（~50）大于容差（~20）→ 各自成簇。
        rects = [
            {"x": 128, "y": 0, "w": 40, "h": 300},
            {"x": 188, "y": 0, "w": 40, "h": 300},
        ]
        merged = kraken_worker._merge_line_rects_by_band(rects, "vertical-rl")
        self.assertEqual(len(merged), 2)

    def test_cluster_mean_is_per_cluster(self):
        # 回归：比较基准必须是"当前簇"的运行均值（全局累计均值会让第二
        # 簇起永远不并——实测 27 片只并成 25 的 bug）。两簇各两片，簇间
        # 中心距大于容差：应得到恰好 2 条带。
        rects = [
            {"x": 100, "y": 0, "w": 40, "h": 50},   # 中心 120
            {"x": 102, "y": 60, "w": 40, "h": 50},  # 中心 122
            {"x": 200, "y": 0, "w": 40, "h": 50},   # 中心 220
            {"x": 202, "y": 60, "w": 40, "h": 50},  # 中心 222
        ]
        merged = kraken_worker._merge_line_rects_by_band(rects, "vertical-rl")
        self.assertEqual(len(merged), 2)
        self.assertEqual(merged[0]["h"], 110)
        self.assertEqual(merged[1]["h"], 110)

    def test_horizontal_rows_merge_by_y(self):
        # 横排：按 y 中心聚成行带。
        rects = [
            {"x": 0, "y": 48, "w": 100, "h": 40},
            {"x": 150, "y": 52, "w": 100, "h": 40},
            {"x": 0, "y": 148, "w": 100, "h": 40},
        ]
        merged = kraken_worker._merge_line_rects_by_band(rects, "horizontal-lr")
        self.assertEqual(len(merged), 2)

    def test_single_rect_passthrough(self):
        rects = [{"x": 0, "y": 0, "w": 40, "h": 300}]
        merged = kraken_worker._merge_line_rects_by_band(rects, "vertical-rl")
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0], rects[0])
        self.assertEqual(
            kraken_worker._merge_line_rects_by_band([], "vertical-rl"), []
        )


if __name__ == "__main__":
    unittest.main()
