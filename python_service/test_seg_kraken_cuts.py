# -*- coding: utf-8 -*-
"""Kraken 字切分器测试（从 test_segmenter 拆出）。"""
import unittest
from pathlib import Path as FsPath
from tempfile import TemporaryDirectory
from unittest.mock import patch
import cv2
import numpy as np
from segmenter import (
    _apply_sort_and_renumber,
    _choose_expected_count,
    _clamp_result_to_image,
    _double_column_sub_rects,
    _enforce_hierarchy_containment,
    _expand_rect_for_punctuation,
    _filter_layout,
    _group_yolo_char_rects_into_lines,
    _merge_adjacent_line_fragments,
    _segment_with_opencv,
    _split_by_layout_grid,
    _split_chars_in_region,
    _text_mask_for_refinement,
    _vertical_line_strips,
    _zero_edge_filler_bands,
    expand_line_rect_to_neighbor_ink,
    extend_lines_to_region_ink,
    filter_result_to_region,
    line_alignment_primary,
    make_kraken_char_splitter,
    mask_polarity_info,
    segment_lines_in_region,
    get_char_candidates,
    split_double_column_lines,
    split_punct_merged_boxes,
)
from kraken_bridge import (
    _recognize_char_boxes,
    _tighten_boxes_to_ink,
    apply_kraken_recognition,
    kraken_segment_line,
    kraken_segment_rect,
)
from kraken_worker import _line_geometry
from metadata import normalize_status, stable_uid







class KrakenCharSplitterTests(unittest.TestCase):
    """make_kraken_char_splitter：Kraken 字框统一为像素（连通域）切分。"""

    def test_line_alignment_primary_policy(self):
        # 高吻合 → 序列正文；低吻合 → 框内正文
        self.assertEqual(line_alignment_primary(
            ["星", "臨", "曰"], ["星", "臨", "廟"]), "seq")
        self.assertEqual(line_alignment_primary(
            ["甲", "乙", "丙"], ["星", "臨", "廟"]), "box")
        # 可比较样本不足（逐框识别大量为空）时保守回退框内正文
        self.assertEqual(line_alignment_primary(["星"], ["星"]), "box")

    def test_line_alignment_primary_untrusted_boxes_prefer_seq(self):
        # cuts 条带框/兜底槽位框与字形可整体错半格：低吻合的分歧更可能
        # 是框错位（逐框读的是错位切片、整行乱码）而非序列错——信整行
        # 读法（实测木刻大字列 cuts 框逐字"夾夾災㤙…"乱码、整行读法
        # "夾月夾日誰能遇夾昌夾曲立貴兮"完全正确，旧策略采信乱码）。
        self.assertEqual(line_alignment_primary(
            ["夾", "夾", "災", "㤙", "日"],
            ["夾", "月", "夾", "日", "誰"],
            boxes_trusted=False), "seq")
        # 高吻合仍走 seq（与信任无关）；像素切分/用户框不受影响
        self.assertEqual(line_alignment_primary(
            ["星", "臨", "曰"], ["星", "臨", "廟"],
            boxes_trusted=False), "seq")
        self.assertEqual(line_alignment_primary(
            ["甲", "乙", "丙"], ["星", "臨", "廟"],
            boxes_trusted=True), "box")
        # 序列全空（横排跳过整行读法）时无可信，仍回框内
        self.assertEqual(line_alignment_primary(
            ["甲", "乙"], ["", ""],
            boxes_trusted=False), "box")

    @staticmethod
    def _write_image(path, width, height, blobs):
        img = np.full((height, width, 3), 255, dtype=np.uint8)
        for x1, y1, x2, y2 in blobs:
            cv2.rectangle(img, (x1, y1), (x2, y2), (0, 0, 0), -1)
        cv2.imwrite(str(path), img)

    def test_vertical_split_returns_tight_boxes_in_reading_order(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            # 三个字、间距不均（50 / 52），验证不是等分条带
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            splitter = make_kraken_char_splitter(str(image_path), "vertical", "rtl")
            boxes = splitter({"x": 10, "y": 0, "w": 60, "h": 250}, 3)
            self.assertIsNotNone(boxes)
            self.assertEqual(len(boxes), 3)
            # 阅读序：竖排上→下
            self.assertTrue(boxes[0][1] < boxes[1][1] < boxes[2][1])
            for (x, y, w, h), (bx1, by1, bx2, by2) in zip(boxes, blobs):
                self.assertLessEqual(abs(x - bx1), 4)
                self.assertLessEqual(abs(y - by1), 4)
                self.assertLessEqual(abs(w - (bx2 - bx1)), 8)
                # 紧致框（贴字形），而非跨整列的等分条带
                self.assertLess(h, 60)

    def test_horizontal_rtl_split_reverses_reading_order(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "row.png"
            blobs = [(10, 20, 50, 58), (100, 22, 140, 60), (190, 20, 230, 58)]
            self._write_image(image_path, 260, 80, blobs)
            splitter = make_kraken_char_splitter(str(image_path), "horizontal", "rtl")
            boxes = splitter({"x": 0, "y": 10, "w": 250, "h": 60}, 3)
            self.assertIsNotNone(boxes)
            self.assertEqual(len(boxes), 3)
            # 横排 rtl 阅读序：右→左
            self.assertTrue(boxes[0][0] > boxes[1][0] > boxes[2][0])

    def test_splitter_returns_none_when_image_unreadable(self):
        splitter = make_kraken_char_splitter(
            "Z:/__missing__/no_such_page.png", "vertical", "rtl"
        )
        self.assertIsNone(splitter({"x": 10, "y": 0, "w": 60, "h": 250}, 3))

    @staticmethod
    def _fake_kraken_line(blobs_count=3, text="作者簡"):
        # 模拟 worker 的 cuts 条带重建框：等分、跨整列宽
        n = len(text)
        strips = [
            {"x": 10, "y": int(i * 250 / n), "w": 60, "h": int(250 / n),
             "text": ch, "conf": 0.99}
            for i, ch in enumerate(text)
        ]
        return [{"x": 10, "y": 0, "w": 60, "h": 250, "text": text, "chars": strips}]

    @staticmethod
    def _fake_char_recs(texts):
        # 模拟第二阶段逐字框识别结果（与传入字框同序）
        return [{"text": t, "conf": 0.95} for t in texts]

    def test_kraken_segment_line_empty_result_with_ink_builds_punct_box(self):
        # 整列只有一个句号：Kraken 行读法为空，但行框内有墨迹——不再
        # 整行报错，合成占位字符走像素兜底，字框收紧到墨迹、逐框读法
        # 再试一次（实测"画框识别报 Kraken 对该行识别结果为空"）。
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            # 一个 ~14×14 的句号墨迹，居中
            self._write_image(image_path, 80, 260, [(33, 120, 47, 134)])
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    [{"x": 10, "y": 0, "w": 60, "h": 260, "text": "", "chars": []}],
                    self._fake_char_recs(["。"]),  # 阶段2：逐框读出句号
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 260},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            self.assertEqual(len(line["chars"]), 1)
            char = line["chars"][0]
            # 字框贴墨迹（~14px），不是整行条带
            self.assertTrue(10 <= char["h"] <= 24, char)
            self.assertTrue(10 <= char["w"] <= 24, char)
            # 逐框读法给出了标点，正文即为句号
            self.assertEqual(line["text"], "。")

    def test_kraken_segment_line_empty_result_without_ink_still_raises(self):
        # 行框内完全无墨迹（误画的空框/模型失败）：保持报错，编辑器保留
        # 原行数据，而不是把这一行清成 0 个字。
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            self._write_image(image_path, 80, 260, [])  # 全白
            with patch(
                "kraken_bridge.recognize_lines",
                return_value=[{"x": 10, "y": 0, "w": 60, "h": 260, "text": "", "chars": []}],
            ):
                with self.assertRaises(RuntimeError):
                    kraken_segment_line(
                        str(image_path), {"x": 10, "y": 0, "w": 60, "h": 260},
                        "l_1", 1, "vertical", "rtl",
                    )

    def test_kraken_segment_line_uses_pixel_splitter_and_box_texts(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),            # 阶段1：整行识别
                    self._fake_char_recs(["作", "者", "簡"]),  # 阶段2：逐框识别
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            self.assertEqual(line["text"], "作者簡")
            self.assertEqual([c["text"] for c in line["chars"]], ["作", "者", "簡"])
            # 像素紧致框（贴字形 ~44px）替代了 ~83px 的等分条带
            heights = [c["h"] for c in line["chars"]]
            self.assertTrue(all(h < 60 for h in heights), heights)
            # 逐框识别与整行序列一致 → 无候选
            self.assertTrue(all(c["candidates"] == [] for c in line["chars"]))

    def test_kraken_segment_line_strict_keeps_mismatched_user_boxes(self):
        """strict_char_boxes：字框数与整行读法不一致时保留人工框只重填
        文字。旧行为（实测用户 23 个手工框被 1 个 cuts 框替换）会把数量
        不一致的人工框整批弃用走自动重切——违背「重新识别本行/识别
        填字」只重填文字不改框的语义。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            # 整行读法只读出 1 个字（n=1），用户传 3 个人工框
            one_char_read = [{
                "x": 10, "y": 0, "w": 60, "h": 250, "text": "作",
                "chars": [{"x": 10, "y": 0, "w": 60, "h": 250,
                           "text": "作", "conf": 0.99}],
            }]
            user_boxes = [(18, 8, 40, 44), (20, 98, 40, 44), (18, 188, 40, 44)]
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    one_char_read,                          # 阶段1：读法 1 字
                    self._fake_char_recs(["作", "者", "簡"]),  # 阶段2：逐框读法
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_boxes=user_boxes,
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                    strict_char_boxes=True,
                )
            self.assertEqual(len(line["chars"]), 3)
            # 框几何逐点保留（不做收紧/重建）
            for got, want in zip(
                [(c["x"], c["y"], c["w"], c["h"]) for c in line["chars"]],
                user_boxes,
            ):
                self.assertEqual(got, want)
            self.assertEqual(line["text"], "作者簡")

            # 对照：不带 strict 时同一输入走自动重切（人工框被替换）
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    one_char_read,
                    self._fake_char_recs(["作", "者", "簡"]),
                ],
            ):
                relaxed = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_boxes=user_boxes,
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            relaxed_boxes = [
                (c["x"], c["y"], c["w"], c["h"]) for c in relaxed["chars"]
            ]
            self.assertNotEqual(relaxed_boxes, user_boxes)

    def test_kraken_segment_line_strict_keeps_even_split_user_boxes(self):
        """strict_char_boxes：框形似均分合成框（数据修复/自动均分的产
        物）在非 strict 链路会被判"不代表真实字形位置"而弃用；strict
        下同样保留——调用方（重新识别本行）承诺框是人工校对成果。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            # 精确均分的 3 框（跨度 250、各 83px）
            even_boxes = [
                (10, int(i * 250 / 3), 60, int(250 / 3)) for i in range(3)
            ]
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),
                    self._fake_char_recs(["作", "者", "簡"]),
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_boxes=even_boxes,
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                    strict_char_boxes=True,
                )
            got = [(c["x"], c["y"], c["w"], c["h"]) for c in line["chars"]]
            self.assertEqual(got, even_boxes)

    def test_kraken_segment_line_mismatch_attaches_aligned_alt(self):
        """顺序对齐后的真分歧把另一路读法挂为末位候选。旧策略"框内异读
        一律不挂候选"针对的是无对齐时代的逐位互挂（分歧大量混入邻位字/
        部件级误读，实测正确率接近零）；对齐 + 行内一致锚点（both ≥ 2）
        护栏下的分歧是"两路各读出一个不同的字"，正是最该人工复核的位
        置。正文仍取对齐可信的整行序列读法。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),                  # 阶段1：作者簡
                    self._fake_char_recs(["作", "者", "間"]),  # 阶段2：末字读成間
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            # 吻合率 2/3 ≥ 0.6 → 对齐可信，正文用序列字；末位两路分歧 →
            # 框内读法挂为末位候选，agree=conflict
            third = line["chars"][2]
            self.assertEqual(third["text"], "簡")
            self.assertEqual(third["agree"], "conflict")
            self.assertEqual(third["candidates"], [{"text": "間", "score": 0.95}])
            self.assertEqual(line["chars"][0]["agree"], "both")
            self.assertEqual(line["chars"][0]["candidates"], [])
            self.assertEqual(line["chars"][1]["candidates"], [])
            self.assertEqual(line["text"], "作者簡")

    def test_kraken_segment_line_low_match_rate_falls_back_to_box_texts(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),                  # 阶段1：作者簡
                    self._fake_char_recs(["甲", "乙", "丙"]),  # 阶段2：全部对不上
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            # 吻合率 0 → 疑似错位，正文以框内识别为准；序列字不再逐位挂
            # 候选（错位局面下序列字属于邻位，挂上就是"候选=上一字/下一
            # 字"的错位候选），候选留空由编辑器显示当前文字兜底。
            self.assertEqual([c["text"] for c in line["chars"]], ["甲", "乙", "丙"])
            self.assertEqual(line["chars"][0]["candidates"], [])
            self.assertEqual(line["text"], "甲乙丙")

    def test_kraken_segment_line_split_fallback_uses_kraken_cuts(self):
        """切分兜底（组件数≠期望字数走网格/等分）时弃用合成槽位框，改用
        与整行读法构造性对齐的 Kraken cuts 条带框——兜底槽位会并字/跳字，
        与真实字形整体错一格，逐框读法读进邻字后正文与候选双双错位。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            logs: list[str] = []
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(text="作者"),  # 阶段1：序列只读出 2 字
                    self._fake_char_recs(["作", "者"]),   # 阶段2：逐框识别（cuts 框）
                ],
            ), patch("kraken_bridge.log", side_effect=logs.append):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            # 3 个连通域 ≠ 期望 2 字 → 网格兜底 → 弃用，改用 cuts 条带框
            self.assertTrue(any("弃用合成槽位框" in m for m in logs), logs)
            self.assertEqual([c["text"] for c in line["chars"]], ["作", "者"])
            # cuts 条带框随后收紧为贴字框：按墨迹整段归属——中间字块
            # （y100-138，中心 119）整体归第一格，第二格收到底部字块。
            # 宽度是格内墨迹范围（20..58 / 20..56），不再是整列宽 60。
            self.assertEqual(
                [(c["x"], c["y"], c["w"], c["h"]) for c in line["chars"]],
                [(20, 10, 39, 129), (20, 190, 37, 41)],
            )

    def test_benign_count_delta_keeps_component_boxes(self):
        """良性差额：连通域比读法多出的框是标点尺寸小块时保留连通域框。

        整行读法常漏读小标点（实测一列 38 组件 vs 读法 35 字，多出的
        是 ？ 与句读点）。此前数量不符一律整行弃用、改用 cuts 条带框
        （格界与字形错位、會这类内部留白的整字被切碎）。良性差额交给
        下游序列-框对齐（difflib 容忍插入/删除）消化。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            # 两个整字（50px 高）+ 一个标点小块（12px 高、10px 宽）
            blobs = [(20, 10, 56, 60), (34, 100, 44, 112), (20, 150, 56, 200)]
            self._write_image(image_path, 80, 260, blobs)
            logs: list[str] = []
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(text="作者"),       # 序列只读出 2 字
                    self._fake_char_recs(["作", "者", "、"]),  # 逐框识别 3 框
                ],
            ), patch("kraken_bridge.log", side_effect=logs.append):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            # 3 组件 vs 期望 2，多出的是标点尺寸小块 → 良性，不再弃用
            self.assertFalse(any("弃用合成槽位框" in m for m in logs), logs)
            self.assertEqual(len(line["chars"]), 3)
            # 框来自连通域：标点框贴墨迹（10~12px），不是整行宽条带
            mark = line["chars"][1]
            self.assertTrue(mark["w"] <= 20, mark)
            self.assertTrue(8 <= mark["h"] <= 20, mark)

    def test_benign_extra_boxes_not_discarded_by_offset_detector(self):
        """良性差额框（数多于序列）不被错位检测误弃。

        错位检测的前提是框数=序列字数（逐位对照）；框数更多时标点位无
        序列字、crop[i]==seq[i-1] 天然成立——修复前会把几何正确的像素框
        整批弃用、cuts 重建（无标点拆分），标点全部失去字框（漏字）。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            # 标点块（中心 ≈62）+ 两个整字（中心 ≈187/300）
            blobs = [(34, 56, 44, 68), (20, 162, 56, 212), (20, 275, 56, 325)]
            self._write_image(image_path, 80, 360, blobs)
            logs: list[str] = []
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(text="作者"),
                    # 逐框读法相对中心对齐后的序列恰差一格（旧规则会判
                    # offset=-1 并弃用这批框）
                    self._fake_char_recs(["X", "作", "者"]),
                ],
            ), patch("kraken_bridge.log", side_effect=logs.append):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 350},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            self.assertFalse(any("错位一格" in m for m in logs), logs)
            self.assertFalse(any("弃用" in m for m in logs), logs)
            # 3 框全数保留（标点小块未被 cuts 重建吞掉）
            self.assertEqual(len(line["chars"]), 3)
            self.assertTrue(
                any(c["h"] <= 20 for c in line["chars"]), line["chars"]
            )

    def test_multichar_crop_not_attached_as_candidate(self):
        """框内读法读出多个字时，首字可能是邻字或部件（crop 吃进邻字、
        一字被拆读），不得作为候选挂出——此前这正是"候选=前一个字"的
        来源。正文仍取整行序列读法。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),  # 阶段1：整行读法 作者簡
                    # 阶段2：第一框读出 2 个字（吃进邻字），首字"前"
                    # 不是该框的字
                    self._fake_char_recs(["前作", "者", "簡"]),
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=None,  # 不传切分器 → 直接走 cuts 兜底
                )
            self.assertEqual([c["text"] for c in line["chars"]], ["作", "者", "簡"])
            # 多字框内读法：宁缺毋滥，不挂候选
            self.assertEqual(line["chars"][0]["candidates"], [])

    def test_kraken_segment_line_keeps_user_drawn_boxes(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            # 参差的手画框（非等跨度合成框）
            user_boxes = [(12, 8, 50, 46), (14, 98, 50, 44), (12, 188, 50, 46)]
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),
                    self._fake_char_recs(["作", "者", "簡"]),
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_boxes=user_boxes,
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            self.assertEqual(
                [(c["x"], c["y"], c["w"], c["h"]) for c in line["chars"]], user_boxes
            )
            self.assertEqual([c["text"] for c in line["chars"]], ["作", "者", "簡"])

    def test_kraken_segment_line_falls_back_when_box_rec_empty(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),
                    self._fake_char_recs(["", "", ""]),  # 逐框识别全空
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            # 回退整行序列的对应字
            self.assertEqual([c["text"] for c in line["chars"]], ["作", "者", "簡"])

    @staticmethod
    def _write_image_with_punct(path, width, height, blobs, punct_center, punct_r=5):
        img = np.full((height, width, 3), 255, dtype=np.uint8)
        for x1, y1, x2, y2 in blobs:
            cv2.rectangle(img, (x1, y1), (x2, y2), (0, 0, 0), -1)
        cv2.circle(img, punct_center, punct_r, (0, 0, 0), -1)
        cv2.imwrite(str(path), img)

    def test_kraken_segment_line_splits_punct_merged_box(self):
        """cuts 条带收紧把字下方贴着的标点吸进同格（超高框）时，按本行
        中位字高检出并拆成独立字框；标点框有自己的逐框读法。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image_with_punct(image_path, 80, 260, blobs, (38, 245))
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),  # 阶段1：整行序列没读出句号
                    self._fake_char_recs(["作", "者", "簡", "。"]),  # 阶段2：含拆出的标点框
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=None,  # 直接走 cuts 收紧路径（同框的来源）
                )
            self.assertEqual([c["text"] for c in line["chars"]], ["作", "者", "簡", "。"])
            self.assertEqual(line["text"], "作者簡。")
            # 第三个字框不再超高（拆回了正常字高）
            self.assertTrue(30 <= line["chars"][2]["h"] <= 50, line["chars"][2])
            # 标点独立成框：小而靠下
            punct = line["chars"][3]
            self.assertLess(punct["h"], 20, punct)
            self.assertGreater(punct["y"], 230, punct)

    def test_kraken_segment_line_splits_punct_at_line_start(self):
        """行首标点画进第一个字的同框：拆分后字框数比序列多一，逐位对照
        形似 -1 错位——刚拆过标点的行必须跳过错位重建，否则拆分框会被
    弃用、退回 cuts 重建而前功尽弃。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 20, 56, 60), (22, 110, 58, 148), (20, 200, 56, 240)]
            self._write_image_with_punct(image_path, 80, 270, blobs, (38, 8))
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),  # 阶段1：序列没读出引号类标点
                    self._fake_char_recs(["「", "作", "者", "簡"]),
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=None,
                )
            self.assertEqual([c["text"] for c in line["chars"]], ["「", "作", "者", "簡"])
            # 拆出的标点框在行首：小而靠上；第一个正文字框回到正常字高
            punct = line["chars"][0]
            self.assertLess(punct["h"], 20, punct)
            self.assertLess(punct["y"], 18, punct)
            self.assertTrue(38 <= line["chars"][1]["h"] <= 46, line["chars"][1])

    def test_kraken_segment_line_expands_short_rect_for_reading(self):
        """行框只画到第二个字（第三个字整字在框外）→ 单行重识别读不到
        也切不出，即"识别不全"。识别与切分改用沿阅读轴外扩到紧邻墨迹的
        框（白色区间超过约 3/4 字高即停），框外的字被捞回；行框几何仍
        返回传入原值。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 49), (22, 64, 58, 103), (20, 118, 56, 157)]
            self._write_image(image_path, 80, 200, blobs)

            def fake_recognize(_image_path, rects, *_args, **_kwargs):
                if len(rects) == 1:
                    # 阶段1：模拟真实 worker——只识别传入行框内的字
                    # （扩后框能读出 3 字，原框只能读出 2 字）
                    r = rects[0]
                    n = 3 if r["y"] + r["h"] >= 150 else 2
                    text = "作者簡"[:n]
                    strips = [
                        {"x": 10, "y": int(i * 160 / n), "w": 60, "h": int(160 / n),
                         "text": ch, "conf": 0.99}
                        for i, ch in enumerate(text)
                    ]
                    return [{"x": 10, "y": 0, "w": 60, "h": 160, "text": text, "chars": strips}]
                # 阶段2：逐框识别，与框数同序
                return [
                    {"text": "作者簡"[i] if i < 3 else "", "conf": 0.95}
                    for i in range(len(rects))
                ]

            with patch("kraken_bridge.recognize_lines", side_effect=fake_recognize):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 108},
                    "l_1", 1, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            # 行框几何同步为外扩后的实际识别范围（与字框一致，扩不动
            # 时即原值）——编辑器里行框不再是一小段而字框铺满整列
            self.assertEqual((line["x"], line["y"], line["w"], line["h"]), (10, 0, 60, 158))
            # 框外的第三个字被外扩捞回：读出且切出
            self.assertEqual([c["text"] for c in line["chars"]], ["作", "者", "簡"])
            self.assertGreater(line["chars"][2]["y"], 110)

    def test_kraken_segment_rect_expand_false_keeps_segment_rect(self):
        """小字注释列被拆成的分段单行（app 判定与其它行共享列带）传
        expand=False：行框不外扩到整列连续墨迹，识别/切分范围即传入
        行框——否则两字段被吞成整列，切出的全部字框叠在段图上（实测
        (885,198,67,183) 两字小注段被外扩成 (885,0,67,2131)、13 个字框
        全叠在两字段图上）。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            # 小字列 5 字连续（字高 50、字距 12），段框只盖住前两字。
            # 字宽须 <60px：实心块达到 60px 会被 _remove_ruling_lines 的
            # 横向形态学开运算当版框横线整块扣掉，mask 里就剩不下墨迹。
            blobs = [(92, 10 + k * 62, 148, 60 + k * 62) for k in range(5)]
            self._write_image(image_path, 240, 330, blobs)

            def fake_recognize(_image_path, rects, *_args, **_kwargs):
                if len(rects) == 1:
                    r = rects[0]
                    # 阶段1：模拟真实 worker——扩后整列读出 5 字，段框
                    # 只读出 2 字
                    n = 2 if r["h"] < 160 else 5
                    text = "注釋小字列"[:n]
                    strips = [
                        {"x": 85, "y": int(i * 320 / n), "w": 67,
                         "h": int(320 / n), "text": ch, "conf": 0.99}
                        for i, ch in enumerate(text)
                    ]
                    return [{"x": 85, "y": 0, "w": 67, "h": 320,
                             "text": text, "chars": strips}]
                # 阶段2：逐框识别，与框数同序（段内只有前两字的读法）
                return [
                    {"text": "注釋小字列"[i] if i < 2 else "", "conf": 0.95}
                    for i in range(len(rects))
                ]

            with patch("kraken_bridge.recognize_lines", side_effect=fake_recognize):
                lines = kraken_segment_rect(
                    str(image_path), {"x": 85, "y": 5, "w": 67, "h": 122},
                    "l_ann", 0, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                    expand=False,
                )
            self.assertEqual(len(lines), 1)
            # 行框保持段框几何（不被外扩成整列），只切出段内两字
            self.assertEqual((lines[0]["y"], lines[0]["h"]), (5, 122))
            self.assertEqual([c["text"] for c in lines[0]["chars"]], ["注", "釋"])

            # 同一输入缺省（expand=True）外扩到整列：对照证明开关生效
            with patch("kraken_bridge.recognize_lines", side_effect=fake_recognize):
                expanded = kraken_segment_rect(
                    str(image_path), {"x": 85, "y": 5, "w": 67, "h": 122},
                    "l_ann2", 0, "vertical", "rtl",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "vertical", "rtl"
                    ),
                )
            self.assertGreater(expanded[0]["h"], 122)

    def test_kraken_segment_line_keeps_single_glyph_box_geometry(self):
        """行重识别传入的既有字框保留几何——但框里只有一个字形时本来就
        没有可拆的标点，超高也不会被动过。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image(image_path, 80, 260, blobs)
            # 第三个框故意画高（框内只有第三个字的单字形），跨度参差 →
            # 非合成均分框 → 走"保留传入框几何"路径
            user_boxes = [(12, 8, 50, 46), (14, 98, 50, 44), (12, 185, 50, 70)]
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),
                    self._fake_char_recs(["作", "者", "簡"]),
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_boxes=user_boxes,
                    char_splitter=None,
                )
            self.assertEqual(
                [(c["x"], c["y"], c["w"], c["h"]) for c in line["chars"]], user_boxes
            )

    def test_kraken_segment_line_splits_merged_box_among_preserved_boxes(self):
        """行重识别会把该行当前字框传回后端"保留几何、仅重新填字"——
        上一轮自动切分的"字+标点"合并框也随之代代相传（实测如/因/者与
        逗号同框的来源）。保留框几何不保留合并错误：超高框里的标点
        同样拆分，标点框有自己的框内读法。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 56, 50), (22, 100, 58, 138), (20, 190, 56, 230)]
            self._write_image_with_punct(image_path, 80, 260, blobs, (38, 245))
            # 第三个框是上一轮切分留下的"簡+。"合并框；三个框与识别字数
            # 相符 → 走保留几何路径 → 仍要拆出标点
            preserved = [(20, 10, 37, 41), (22, 100, 37, 39), (20, 190, 37, 60)]
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_kraken_line(),
                    self._fake_char_recs(["作", "者", "簡", "。"]),
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), {"x": 10, "y": 0, "w": 60, "h": 250},
                    "l_1", 1, "vertical", "rtl",
                    char_boxes=preserved,
                    char_splitter=None,
                )
            self.assertEqual([c["text"] for c in line["chars"]], ["作", "者", "簡", "。"])
            self.assertTrue(30 <= line["chars"][2]["h"] <= 50, line["chars"][2])
            punct = line["chars"][3]
            self.assertLess(punct["h"], 20, punct)
            self.assertGreater(punct["y"], 230, punct)

    def _write_horizontal_row_image(self, path):
        # 260x80 的横排行：三个字在 x62..218，行带左侧 x10..34 还有一块
        # 同带墨迹（间隔 28px < 0.85×行高 34px 的外扩容限）——横排单行
        # 重识别若把行框左端外扩到 x10，字框/读法就会把行外墨迹一并
        # 卷进来、铺出行图。
        blobs = [
            (10, 25, 34, 55),      # 行带左侧的邻近墨迹
            (62, 22, 98, 58),      # 斗
            (122, 22, 158, 58),    # 數
            (182, 22, 218, 58),    # 命
        ]
        self._write_image(path, 260, 80, blobs)

    def test_horizontal_segment_line_keeps_caller_rect(self):
        """横排行单行重识别不再沿阅读轴外扩行框：字框（像素切分贴墨迹）
        与读法始终铺在编辑器传入的行框上，行外的邻近墨迹不卷入；编辑器
        还原手工行框后行图与字框同界（实测横排标题行修复前的错位来源）。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "row.png"
            self._write_horizontal_row_image(image_path)
            caller_rect = {"x": 58, "y": 18, "w": 164, "h": 44}

            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_char_recs(["斗", "數", "命"]),
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), dict(caller_rect),
                    "l_1", 1, "horizontal", "ltr",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "horizontal", "ltr"
                    ),
                )
            # 行框不被外扩覆盖
            self.assertEqual(
                (line["x"], line["y"], line["w"], line["h"]),
                (caller_rect["x"], caller_rect["y"], caller_rect["w"], caller_rect["h"]),
            )
            self.assertEqual([c["text"] for c in line["chars"]], ["斗", "數", "命"])
            # 像素切分：贴字形的紧致框（而非跨整行的条带），全部落在
            # 行框内，也不吃进行框左侧的邻近墨迹（x10..34）
            self.assertEqual(len(line["chars"]), 3)
            for c in line["chars"]:
                self.assertGreaterEqual(c["x"], caller_rect["x"])
                self.assertLessEqual(
                    c["x"] + c["w"], caller_rect["x"] + caller_rect["w"]
                )
                self.assertLess(c["w"], 60, c)
            self.assertGreaterEqual(line["chars"][0]["x"], 60)

    def test_horizontal_segment_line_rejects_shifted_user_boxes(self):
        """横排传入的历史错位字框（首框中心在行框外）不再被"保留人工框"
        原样收下，走像素切分重建——错位不再随重识别代代相传。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "row.png"
            self._write_horizontal_row_image(image_path)
            caller_rect = {"x": 58, "y": 18, "w": 164, "h": 44}
            # 历史 paddle 均分槽位时代行框外扩错位写出的框：网格铺在
            # [10,222] 上（行框左缘 58 之外），宽度参差 → 非均分 →
            # 修复前走"保留人工框"路径
            shifted_boxes = [(8, 18, 60, 44), (78, 18, 74, 44), (150, 18, 73, 44)]

            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_char_recs(["斗", "數", "命"]),
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), dict(caller_rect),
                    "l_1", 1, "horizontal", "ltr",
                    char_boxes=shifted_boxes,
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "horizontal", "ltr"
                    ),
                )
            self.assertEqual([c["text"] for c in line["chars"]], ["斗", "數", "命"])
            for c in line["chars"]:
                self.assertGreaterEqual(
                    c["x"] + c["w"] / 2, caller_rect["x"],
                    "首框中心不得落在行框外（错位框应被弃用）",
                )
            self.assertGreaterEqual(line["chars"][0]["x"], 60)

    def test_horizontal_segment_line_keeps_sane_user_boxes(self):
        """护栏不误伤：中心在行框内的手工调整框（含宽度参差的贴字框）
        仍走"保留人工框"。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "row.png"
            self._write_horizontal_row_image(image_path)
            caller_rect = {"x": 58, "y": 18, "w": 164, "h": 44}
            user_boxes = [(60, 20, 38, 40), (121, 20, 38, 40), (182, 20, 40, 40)]

            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    self._fake_char_recs(["斗", "數", "命"]),
                ],
            ):
                line = kraken_segment_line(
                    str(image_path), dict(caller_rect),
                    "l_1", 1, "horizontal", "ltr",
                    char_boxes=user_boxes,
                )
            self.assertEqual(
                [(c["x"], c["y"], c["w"], c["h"]) for c in line["chars"]], user_boxes
            )

    def test_horizontal_char_boxes_read_as_vertical(self):
        """横排逐字读法按竖排单字列喂给 Kraken：CHAT 模型只认"竖排矫形
        后躺倒的字形"，横排行以 horizontal-lr 直喂时直立字形完全在模型
        分布外、逐字全错（实测横排标题 8 字全错 conf 0.1~0.5；同一批框
        按 vertical-rl 喂 8 字全对 conf 0.88+）。单字框内没有阅读方向，
        orientation 只影响外扩边距取向，不影响喂给引擎的方向。"""
        calls = []

        def fake_recognize_lines(image_path, rects, orientation, horizontal_dir,
                                 per_line=True):
            calls.append((orientation, horizontal_dir, per_line, len(rects)))
            return [{"text": "", "conf": 0.0, "chars": []} for _ in rects]

        with patch(
            "kraken_bridge.recognize_lines", side_effect=fake_recognize_lines
        ):
            _recognize_char_boxes(
                "fake.png", [(10, 10, 30, 30), (50, 10, 30, 30)],
                "horizontal", "ltr",
            )
        self.assertEqual(len(calls), 1)
        orientation, _, per_line, n_boxes = calls[0]
        self.assertEqual(orientation, "vertical")
        self.assertFalse(per_line)
        self.assertEqual(n_boxes, 2)

    def test_horizontal_segment_line_skips_line_seq(self):
        """横排单行重识别跳过整行序列读法（CHAT 无横排域，序列只会产出
        乱码并污染切分数量校验）：recognize_lines 只剩逐字一批调用，
        正文全部来自框内读法（agree=box），行文本按框内读法拼出。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "row.png"
            self._write_horizontal_row_image(image_path)
            caller_rect = {"x": 58, "y": 18, "w": 164, "h": 44}

            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[self._fake_char_recs(["斗", "數", "命"])],
            ) as rl:
                line = kraken_segment_line(
                    str(image_path), dict(caller_rect),
                    "l_1", 1, "horizontal", "ltr",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "horizontal", "ltr"
                    ),
                )
            self.assertEqual(rl.call_count, 1, "只应有逐字一批识别调用")
            self.assertFalse(rl.call_args.kwargs.get("per_line"))
            self.assertEqual([c["text"] for c in line["chars"]], ["斗", "數", "命"])
            self.assertEqual(line["text"], "斗數命")
            self.assertTrue(all(c["agree"] == "box" for c in line["chars"]))

    def test_horizontal_apply_recognition_skips_line_seq(self):
        """横排整页识别同样跳过整行序列：字框由像素切分独立给出（期望
        字数未知 → 纯连通域），正文/候选全部来自逐字读法。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "row.png"
            # 整页路径的行框外扩（检测行框补捞同带墨迹，设计行为）会把
            # 同带邻近墨迹卷进行框，这里用三个字、无邻近墨迹的图。
            self._write_image(image_path, 260, 80, [
                (62, 22, 98, 58),      # 斗
                (122, 22, 158, 58),    # 數
                (182, 22, 218, 58),    # 命
            ])
            result = {"lines": [
                {"id": "l_0", "line_no": 0, "x": 58, "y": 18, "w": 164, "h": 44},
            ]}
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[self._fake_char_recs(["斗", "數", "命"])],
            ) as rl:
                out = apply_kraken_recognition(
                    result, str(image_path), "horizontal", "ltr",
                    char_splitter=make_kraken_char_splitter(
                        str(image_path), "horizontal", "ltr"
                    ),
                )
            self.assertEqual(rl.call_count, 1, "只应有逐字一批识别调用")
            self.assertFalse(rl.call_args.kwargs.get("per_line"))
            chars = out["blocks"]
            self.assertEqual([c["text"] for c in chars], ["斗", "數", "命"])
            self.assertTrue(all(c["agree"] == "box" for c in chars))
            self.assertEqual(out["lines"][0]["text"], "斗數命")

    def test_horizontal_split_without_expected_count(self):
        """横排无整行序列（n=0）：切分器走纯连通域路径按墨迹出框、不做
        数量校验（期望数未知时不退化为网格兜底、不因数量不符返回 None）。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "row.png"
            self._write_horizontal_row_image(image_path)
            splitter = make_kraken_char_splitter(str(image_path), "horizontal", "ltr")
            boxes = splitter({"x": 58, "y": 18, "w": 164, "h": 44}, 0)
            self.assertEqual(len(boxes), 3)
            self.assertEqual(splitter.last_method, "components")
            self.assertTrue(all(58 <= x for x, _y, _w, _h in boxes))
