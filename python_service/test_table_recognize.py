# -*- coding: utf-8 -*-
"""table_recognize 测试：格方向判定、格内阅读序（横竖版 + rtl/btt）、
识别编排（引擎适配器 mock，切字走真实连通域）、引擎路由与序列读融合。"""
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


class _FakeAdapter:
    """引擎适配器桩：记录调用，按脚本回字。默认 kraken 能力面。"""

    name = "fake"
    ocr_tag = "fake+test"

    def __init__(self, crop_texts=None, seq_texts=None, horizontal_line_read=False,
                 vertical_line_read=True, name="fake", ocr_tag="fake+test",
                 model=""):
        self.crop_texts = list(crop_texts or [])
        self.seq_texts = list(seq_texts or [])
        self.horizontal_line_read = horizontal_line_read
        self.vertical_line_read = vertical_line_read
        self.name = name
        self.ocr_tag = ocr_tag
        self.model = model
        self.char_box_calls = []
        self.line_calls = []
        self.strip_calls = []

    def read_char_boxes(self, image_path, boxes, orientation, horizontal_dir,
                        pad=True):
        self.char_box_calls.append(list(boxes))
        texts = self.crop_texts or ["字"] * len(boxes)
        return [
            {"text": texts[i] if i < len(texts) else "", "conf": 0.5}
            for i in range(len(boxes))
        ]

    def read_lines(self, image_path, line_rects, orientation="vertical",
                   horizontal_dir="rtl"):
        self.line_calls.append((orientation, [dict(r) for r in line_rects]))
        out = []
        for i, _r in enumerate(line_rects):
            text = self.seq_texts[i] if i < len(self.seq_texts) else ""
            out.append({
                "text": text, "conf": 0.9,
                "chars": [
                    {"x": 0, "y": 0, "w": 1, "h": 1, "text": ch, "conf": 0.9}
                    for ch in text
                ],
            })
        return out

    def read_strip_chars(self, image_path, rect, boxes, orientation,
                         horizontal_dir):
        # 拼条读的 rect 必须是 dict（PaddleEngineAdapter 用 rect.get）——
        # 直传 tuple 会让竖排序列读整方向静默失败（实测教训）。
        assert isinstance(rect, dict), (
            f"read_strip_chars 需要 dict rect，收到 {type(rect)}"
        )
        self.strip_calls.append((rect, list(boxes)))
        text = self.seq_texts[len(self.strip_calls) - 1] if self.seq_texts else ""
        return [
            {"x": 0, "y": 0, "w": 1, "h": 1, "text": ch, "conf": 0.9}
            for ch in text
        ]


def _cells_of(path):
    """测试页的网格格列表（VL spotting 桩按格造文本框用）。"""
    from table_grid import detect_table_grid

    grid = detect_table_grid(path, 90, 70, 620, 500)
    assert grid.get("ok"), grid
    return grid["cells"]


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

    def test_horizontal_rows_ltr_inline_even_on_rtl_page(self):
        rects = [(0, 0, 20, 20), (40, 0, 20, 20), (0, 60, 20, 20)]
        ltr = _order_rects(rects, "horizontal", "ltr", "ttb")
        self.assertEqual([(r[0], r[1]) for r in ltr],
                         [(0, 0), (40, 0), (0, 60)])
        # 竖排 rtl 页面里的横排格（时辰表标签）：页面 rtl 是竖排列序
        # 方向，横排行内恒左→右，不再反读成「點至夜午」。
        rtl_page = _order_rects(rects, "horizontal", "rtl", "ttb")
        self.assertEqual([(r[0], r[1]) for r in rtl_page],
                         [(0, 0), (40, 0), (0, 60)])
        # 行序跟随页面 vertical_dir（btt 自下而上）
        btt = _order_rects(rects, "horizontal", "ltr", "btt")
        self.assertEqual([(r[0], r[1]) for r in btt],
                         [(0, 60), (0, 0), (40, 0)])


class RecognizeTableTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def _two_by_three_page(self):
        """2×3 网格、每格左上角两枚"字"（竖排列）的测试页。"""
        canvas = _white_page()
        _draw_grid(canvas, 100, 80, 700, 560, n_rows=2, n_cols=3)
        xs = np.linspace(100, 700, 4).astype(int)
        ys = np.linspace(80, 560, 3).astype(int)
        for r in range(2):
            for c in range(3):
                for k in range(2):
                    x = int(xs[c]) + 20
                    y = int(ys[r]) + 20 + k * 40
                    cv2.rectangle(canvas, (x, y), (x + 18, y + 18), (0, 0, 0), -1)
        return _save_page(canvas, self._tmp.name)

    def test_cells_get_text_in_reading_order(self):
        path = self._two_by_three_page()
        adapter = _FakeAdapter()
        with patch("table_recognize._engine_adapter", return_value=adapter):
            result = recognize_table(path, 90, 70, 620, 500, "vertical",
                                     "ltr", "ttb")
        self.assertTrue(result["ok"], result)
        self.assertEqual((result["rows"], result["cols"]), (2, 3))
        self.assertEqual(len(result["cells"]), 6)
        # 逐字读一批一次请求，全表 12 框
        self.assertEqual(len(adapter.char_box_calls), 1)
        self.assertEqual(len(adapter.char_box_calls[0]), 12)
        for cell in result["cells"]:
            self.assertEqual(cell["text"], "字字", cell)
            self.assertEqual(len(cell["chars"]), 2)
            self.assertTrue(cell["chars"][0]["conf"] > 0)
        # 阅读序：第一格是左上（ltr 列序）
        first = result["cells"][0]
        self.assertEqual((first["row"], first["col"]), (0, 0))
        self.assertEqual(result["ocr"], "fake+test")

    def test_engine_routing_paddle_uses_strip_and_lines(self):
        """paddle 能力面：竖排格走字框拼条（read_strip_chars），逐字读
        仍整批一次；kraken 能力面（竖排）走整行批读 read_lines。"""
        path = self._two_by_three_page()
        paddle_like = _FakeAdapter(
            horizontal_line_read=True, vertical_line_read=False,
        )
        with patch("table_recognize._engine_adapter", return_value=paddle_like):
            result = recognize_table(path, 90, 70, 620, 500, "vertical",
                                     "ltr", "ttb")
        self.assertTrue(result["ok"])
        self.assertEqual(len(paddle_like.char_box_calls), 1)
        # 6 个竖排格各 1 列 → 6 次拼条
        self.assertEqual(len(paddle_like.strip_calls), 6)
        self.assertEqual(paddle_like.line_calls, [])

        kraken_like = _FakeAdapter()
        with patch("table_recognize._engine_adapter", return_value=kraken_like):
            result = recognize_table(path, 90, 70, 620, 500, "vertical",
                                     "ltr", "ttb")
        self.assertTrue(result["ok"])
        # 竖排列合成一批整行读（一次调用收全部列）
        self.assertEqual(len(kraken_like.line_calls), 1)
        self.assertEqual(kraken_like.line_calls[0][0], "vertical")
        self.assertEqual(len(kraken_like.line_calls[0][1]), 6)
        self.assertEqual(kraken_like.strip_calls, [])

    def test_sequence_fusion_prefers_seq_on_agreement(self):
        """逐字读全错、序列读正确且数量一致 → 吻合率低但字框可信，
        行装配规则信框内读法（box）；逐字读与序列读一致 → 无差别。
        这里构造逐字读半对半错、序列读与逐字读相同 → 吻合率高，正文
        取序列字（提高 conf）。"""
        path = self._two_by_three_page()
        # 每格两字：crop 读 "甲乙"，序列读同 "甲乙" → 吻合率 100%
        adapter = _FakeAdapter(
            crop_texts=["甲", "乙"] * 6, seq_texts=["甲乙"] * 6,
        )
        with patch("table_recognize._engine_adapter", return_value=adapter):
            result = recognize_table(path, 90, 70, 620, 500, "vertical",
                                     "ltr", "ttb")
        for cell in result["cells"]:
            self.assertEqual(cell["text"], "甲乙", cell)
            # 序列字 conf 0.9 覆盖逐字读的 0.5
            self.assertEqual(cell["chars"][0]["conf"], 0.9)

    def test_sequence_mismatch_falls_back_to_crop(self):
        """序列读与逐字读数量不一致（如多读一字）→ 该组保持逐字读。"""
        path = self._two_by_three_page()
        # 序列每组读出 3 字（与 2 框不匹配），且第 3 字与框内文本对不上
        adapter = _FakeAdapter(
            crop_texts=["甲", "乙"] * 6, seq_texts=["甲乙丙"] * 6,
        )
        with patch("table_recognize._engine_adapter", return_value=adapter):
            result = recognize_table(path, 90, 70, 620, 500, "vertical",
                                     "ltr", "ttb")
        for cell in result["cells"]:
            self.assertEqual(cell["text"], "甲乙", cell)
            self.assertEqual(cell["chars"][0]["conf"], 0.5)

    def test_sequence_subsequence_trims_duplicate_crop_boxes(self):
        """框内复读/残框（数量多于序列）且序列字全部按序对上 → 多余框
        读空：「甲乙甲」+ 序列「甲乙」→「甲乙」（99至11點 同型）。"""
        canvas = _white_page()
        _draw_grid(canvas, 100, 80, 700, 560, n_rows=2, n_cols=3)
        xs = np.linspace(100, 700, 4).astype(int)
        ys = np.linspace(80, 560, 3).astype(int)
        for r in range(2):
            for c in range(3):
                for k in range(2):
                    x = int(xs[c]) + 20
                    y = int(ys[r]) + 20 + k * 40
                    cv2.rectangle(canvas, (x, y), (x + 18, y + 18), (0, 0, 0), -1)
        # 格(0,0) 多画一枚"复读字"（第三框）
        cv2.rectangle(canvas, (120, 180), (138, 198), (0, 0, 0), -1)
        path = _save_page(canvas, self._tmp.name)
        # 框内读法：格(0,0) 三框「甲乙甲」，其余格两框「甲乙」；
        # 序列读：每组（列）「甲乙」
        adapter = _FakeAdapter(
            crop_texts=["甲", "乙", "甲"] + ["甲", "乙"] * 5,
            seq_texts=["甲乙"] * 6,
        )
        with patch("table_recognize._engine_adapter", return_value=adapter):
            result = recognize_table(path, 90, 70, 620, 500, "vertical",
                                     "ltr", "ttb")
        first = result["cells"][0]
        self.assertEqual(first["text"], "甲乙", first)
        # 第三框被读空（子序列对齐，滤多余框）
        self.assertEqual(
            [c["text"] for c in first["chars"]], ["甲", "乙", ""],
        )
        for cell in result["cells"][1:]:
            self.assertEqual(cell["text"], "甲乙", cell)
        joined = "\n".join(result.get("log") or [])
        self.assertIn("子序列对齐，滤多余框 1", joined)

        # 序列字对不上框内（潜在误读）→ 不修剪，保持框内全文
        adapter2 = _FakeAdapter(
            crop_texts=["甲", "乙", "甲"] + ["甲", "乙"] * 5,
            seq_texts=["丙丁"] * 6,
        )
        with patch("table_recognize._engine_adapter", return_value=adapter2):
            result2 = recognize_table(path, 90, 70, 620, 500, "vertical",
                                      "ltr", "ttb")
        self.assertEqual(result2["cells"][0]["text"], "甲乙甲")

    def test_sequence_failure_keeps_crop_reading(self):
        """序列读法抛异常 → 回落逐字读，表格仍 ok。"""
        path = self._two_by_three_page()

        class _BoomSeq(_FakeAdapter):
            def read_lines(self, *a, **k):
                raise RuntimeError("seq daemon down")

        adapter = _BoomSeq()
        with patch("table_recognize._engine_adapter", return_value=adapter):
            result = recognize_table(path, 90, 70, 620, 500, "vertical",
                                     "ltr", "ttb")
        self.assertTrue(result["ok"])
        for cell in result["cells"]:
            self.assertEqual(cell["text"], "字字")

    def test_kraken_failure_keeps_geometry(self):
        canvas = _white_page()
        _draw_grid(canvas, 100, 80, 700, 560, n_rows=2, n_cols=2)
        # 格内要有字才会触发逐字识别调用
        cv2.rectangle(canvas, (130, 110), (148, 128), (0, 0, 0), -1)
        path = _save_page(canvas, self._tmp.name)

        class _Boom(_FakeAdapter):
            def read_char_boxes(self, *a, **k):
                raise RuntimeError("daemon down")

        with patch(
            "table_recognize._engine_adapter", return_value=_Boom(),
        ):
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

    def test_vl_spotting_overrides_cell_text(self):
        """VL 书（PaddleOCR-VL 模型）：spotting 文本按格归属并覆盖正文，
        字框文本按阅读轴几何分布（分隔符落框间不占框）；VL 全覆盖时
        **零逐字/序列读请求**（不切换识别池）。"""
        path = self._two_by_three_page()
        seen: dict = {}

        def fake_vl(image_path, rect, paddle_model,
                    vl_config=None, vl_predict=None):
            seen["model"] = paddle_model
            seen["vl_config"] = vl_config
            seen["vl_predict"] = vl_predict
            # 每格一个 VL 文本框：竖排 y 区间贴住两枚墨迹字
            #（fixture 字框 y = 80+row*240+{20..38, 60..78}），
            # 文本带分隔符「甲、乙」——、落在框间空隙不占框。
            boxes, texts, confs = [], [], []
            for cell in _cells_of(path):
                y0 = 80 + cell["row"] * 240 + 18
                boxes.append({
                    "x": cell["x"] + 10, "y": y0, "w": 20, "h": 62,
                })
                texts.append("甲、乙")
                confs.append(0.97)
            return {"boxes": boxes, "texts": texts, "confs": confs}

        adapter = _FakeAdapter(crop_texts=["甲", "乙"] * 6)
        vl_cfg = {"use_doc_orientation": False}
        vl_pred = {"temperature": 0.1}
        with patch(
            "table_recognize._vl_spotting_read", side_effect=fake_vl,
        ), patch(
            "table_recognize._engine_adapter", return_value=adapter,
        ):
            result = recognize_table(
                path, 90, 70, 620, 500, "vertical", "ltr", "ttb",
                engine="paddle", paddle_model="PaddleOCR-VL-1.6",
                vl_config=vl_cfg, vl_predict=vl_pred,
            )
        # 书内模型与 VL 配置原样到达 spotting 读（vl_config 保证与
        # 文本视图共享同一 VL 池）
        self.assertEqual(seen["model"], "PaddleOCR-VL-1.6")
        self.assertIs(seen["vl_config"], vl_cfg)
        self.assertIs(seen["vl_predict"], vl_pred)
        self.assertTrue(result["ok"])
        joined_head = (result.get("log") or [""])[0]
        self.assertIn("书内模型 PaddleOCR-VL-1.6", joined_head)
        self.assertIn("VL spotting 读表", joined_head)
        # VL 全覆盖：完全不发逐字读/序列读请求（不切换识别池）
        self.assertEqual(adapter.char_box_calls, [])
        self.assertEqual(adapter.line_calls, [])
        self.assertEqual(adapter.strip_calls, [])
        joined = "\n".join(result.get("log") or [])
        self.assertIn("VL 全覆盖 6 格：跳过逐字/序列读", joined)
        for cell in result["cells"]:
            self.assertEqual(cell["text"], "甲、乙", cell)
            # 甲→首字框、乙→次字框（、落框间不占框）
            self.assertEqual(cell["chars"][0]["text"], "甲")
            self.assertEqual(cell["chars"][1]["text"], "乙")
            self.assertGreaterEqual(cell["chars"][0]["conf"], 0.97)
        self.assertIn("paddle-vl+", result["ocr"])
        self.assertIn("VL=「甲、乙」", joined)

    def test_vl_spotting_failure_falls_back(self):
        """VL spotting 抛异常 → 日志记录并回落逐字/序列读法，表格仍 ok。"""
        path = self._two_by_three_page()

        def boom(image_path, rect, paddle_model,
                 vl_config=None, vl_predict=None):
            raise RuntimeError("VL pool cold")

        adapter = _FakeAdapter(crop_texts=["甲", "乙"] * 6)
        with patch(
            "table_recognize._vl_spotting_read", side_effect=boom,
        ), patch(
            "table_recognize._engine_adapter", return_value=adapter,
        ):
            result = recognize_table(
                path, 90, 70, 620, 500, "vertical", "ltr", "ttb",
                engine="paddle", paddle_model="PaddleOCR-VL-1.6",
            )
        self.assertTrue(result["ok"])
        for cell in result["cells"]:
            self.assertEqual(cell["text"], "甲乙", cell)
        joined = "\n".join(result.get("log") or [])
        self.assertIn("VL spotting 失败：VL pool cold", joined)
        # 非超时失败不带显存挤占提示（提示只对超时挂起有意义）
        self.assertNotIn("VL 推理超时", joined)
        # 末行引擎标记注明回落原因，避免看起来像书内 VL 设置没生效
        self.assertIn("（VL 失败回落）", result["ocr"])

    def test_vl_spotting_timeout_falls_back_with_hint(self):
        """VL spotting 超时（池真实超时文案）→ 回落逐字/序列读，且诊断
        日志带显存挤占提示：kraken 池路数 + 设置项指引——用户能据此把
        「识别进程数」调回自动恢复 VL 读表。"""
        path = self._two_by_three_page()

        def slow(image_path, rect, paddle_model,
                 vl_config=None, vl_predict=None):
            raise RuntimeError("PaddleOCR daemon 响应超时（>180s），已重启")

        adapter = _FakeAdapter(crop_texts=["甲", "乙"] * 6)
        with patch(
            "table_recognize._vl_spotting_read", side_effect=slow,
        ), patch(
            "table_recognize._engine_adapter", return_value=adapter,
        ):
            result = recognize_table(
                path, 90, 70, 620, 500, "vertical", "ltr", "ttb",
                engine="paddle", paddle_model="PaddleOCR-VL-1.6",
            )
        self.assertTrue(result["ok"])
        for cell in result["cells"]:
            self.assertEqual(cell["text"], "甲乙", cell)
        joined = "\n".join(result.get("log") or [])
        self.assertIn("VL spotting 失败：PaddleOCR daemon 响应超时", joined)
        self.assertIn("VL 推理超时", joined)
        self.assertIn("kraken 池", joined)
        self.assertIn("识别进程数", joined)
        # 末行引擎标记注明是超时回落
        self.assertIn("（VL 超时回落）", result["ocr"])

    def test_vl_spotting_timeout_cooldown_skips_retry(self):
        """VL spotting 超时 → 记冷却窗；窗内再次识别直接跳过 VL（不再
        烧一遍交互预算），回落结果照常。连续校对多张表时第二次起恢复
        秒级。"""
        import table_recognize as tr

        self.addCleanup(tr._vl_spot_skip_until.clear)
        tr._vl_spot_skip_until.clear()
        path = self._two_by_three_page()
        calls: list[int] = []

        def slow(image_path, rect, paddle_model,
                 vl_config=None, vl_predict=None):
            calls.append(1)
            raise RuntimeError("PaddleOCR daemon 响应超时（>180s），已重启")

        adapter = _FakeAdapter(crop_texts=["甲", "乙"] * 6)
        with patch(
            "table_recognize._vl_spotting_read", side_effect=slow,
        ), patch(
            "table_recognize._engine_adapter", return_value=adapter,
        ):
            first = recognize_table(
                path, 90, 70, 620, 500, "vertical", "ltr", "ttb",
                engine="paddle", paddle_model="PaddleOCR-VL-1.6",
            )
            second = recognize_table(
                path, 90, 70, 620, 500, "vertical", "ltr", "ttb",
                engine="paddle", paddle_model="PaddleOCR-VL-1.6",
            )
        # 第一次真的调了 spotting；冷却期内第二次不再调
        self.assertEqual(len(calls), 1)
        for result in (first, second):
            self.assertTrue(result["ok"])
            for cell in result["cells"]:
                self.assertEqual(cell["text"], "甲乙", cell)
            # 两次都是超时回落（第二次是冷却跳过），引擎标记都注明
            self.assertIn("（VL 超时回落）", result["ocr"])
        joined2 = "\n".join(second.get("log") or [])
        self.assertIn("VL spotting 跳过", joined2)
        self.assertIn("冷却期", joined2)

    def test_slash_dividers_filtered_not_read_as_chars(self):
        """格内字间分隔斜杠不是字：填充率低且面积不足中位字一半的连通域
        被滤掉（实测干支表「甲/己」格的斜杠被逐字读成 I/1），实体字保留。
        """
        canvas = _white_page()
        _draw_grid(canvas, 100, 80, 700, 560, n_rows=2, n_cols=2)
        # (0,0) 格：两枚实体字 + 中间一道对角分隔斜杠
        cv2.rectangle(canvas, (130, 100), (148, 118), (0, 0, 0), -1)
        cv2.line(canvas, (132, 128), (148, 148), (0, 0, 0), 2)
        cv2.rectangle(canvas, (130, 158), (148, 176), (0, 0, 0), -1)
        path = _save_page(canvas, self._tmp.name)
        adapter = _FakeAdapter()
        with patch("table_recognize._engine_adapter", return_value=adapter):
            result = recognize_table(path, 90, 70, 620, 500, "vertical",
                                     "ltr", "ttb")
        self.assertTrue(result["ok"])
        # 斜杠被滤：该格只有 2 个字框进识别（全表其余格为空）
        self.assertEqual(len(adapter.char_box_calls[0]), 2, adapter.char_box_calls)
        joined = "\n".join(result.get("log") or [])
        self.assertIn("斜杠滤=1", joined)

    def test_diagnostic_log_lines_present(self):
        """识别日志（诊断差异用）：引擎/模型、序列读可达性、每格连通域
        统计、逐字读批量、逐组融合决策、汇总行都应在场。"""
        path = self._two_by_three_page()
        adapter = _FakeAdapter(
            name="fake-paddle",
            ocr_tag="paddle+test",
            model="PP-OCRv6_small_rec",
            crop_texts=["甲", "乙"] * 6,
            seq_texts=["甲乙"] * 6,
            horizontal_line_read=True,
            vertical_line_read=False,
        )
        with patch("table_recognize._engine_adapter", return_value=adapter):
            result = recognize_table(
                path, 90, 70, 620, 500, "vertical", "ltr", "ttb",
                engine="paddle", paddle_model="PP-OCRv6_small_rec",
            )
        self.assertTrue(result["ok"])
        log = result.get("log") or []
        joined = "\n".join(log)
        # 引擎行如实显示书内设置的模型
        self.assertIn(
            "引擎=paddle（书内模型 PP-OCRv6_small_rec）", joined
        )
        self.assertIn("序列读法：竖排=字框拼条", joined)
        self.assertIn("网格 2×3 格数=6", joined)
        # 每格连通域统计行（融合决策行同样以"格("开头，按"连通域="区分）
        self.assertEqual(
            sum(1 for ln in log if ln.startswith("格(") and "连通域=" in ln),
            6,
            log,
        )
        self.assertIn("逐字读：12 框一批一次请求", joined)
        # 逐组融合决策：吻合高 → 取序列
        self.assertIn("吻合2/2 → 取序列（语境）", joined)
        self.assertIn("完成：6 格 / 12 字", joined)


if __name__ == "__main__":
    unittest.main()
