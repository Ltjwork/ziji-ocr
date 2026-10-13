# -*- coding: utf-8 -*-
"""标点拆分相关测试（从 test_segmenter 拆出）：标点合并拆分、单字组件间隙、标点尾列救援。"""
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





class PunctSplitTests(unittest.TestCase):
    """split_punct_merged_boxes：按本行中位字高检出"字+标点"同框并拆分。"""

    @staticmethod
    def _vertical_mask(extra_blobs=()):
        # 四个正常字（墨迹高 40，x 20..56）；extra_blobs 画标点等附加墨迹
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 90, 170, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        for x1, y1, x2, y2 in extra_blobs:
            cv2.rectangle(mask, (x1, y1), (x2, y2), 255, -1)
        return mask

    def test_split_separates_punct_below_char(self):
        # 第三个字的框把字下方贴着的标点画了进去：高 58 vs 中位 40
        mask = self._vertical_mask(extra_blobs=[(30, 218, 41, 227)])
        boxes = [(20, 10, 37, 40), (20, 90, 37, 40), (20, 170, 37, 58), (20, 250, 37, 40)]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 5)
        self.assertEqual(len(events), 1)
        # 拆出的字框回到正常字高，标点框小而靠下（碎片落在原框位置）
        char_box, punct_box = out[2], out[3]
        self.assertTrue(38 <= char_box[3] <= 46, char_box)
        self.assertTrue(166 <= char_box[1] <= 172, char_box)
        self.assertTrue(8 <= punct_box[3] <= 16, punct_box)
        self.assertGreaterEqual(punct_box[1], 214)

    def test_split_separates_punct_above_char(self):
        # 标点画进第三个字上方的同框：拆分后标点框在前（竖排阅读序）
        mask = self._vertical_mask(extra_blobs=[(30, 150, 41, 159)])
        boxes = [(20, 10, 37, 40), (20, 90, 37, 40), (20, 150, 37, 60), (20, 250, 37, 40)]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 5)
        punct_box, char_box = out[2], out[3]
        self.assertTrue(8 <= punct_box[3] <= 16, punct_box)
        self.assertLess(punct_box[1], char_box[1])
        self.assertTrue(38 <= char_box[3] <= 46, char_box)

    def test_split_touching_punct_via_ink_waist(self):
        # 标点与主字墨迹相连（无空档）：靠"细腰"（墨迹量骤减的行）切分
        mask = self._vertical_mask(extra_blobs=[(33, 208, 44, 223)])
        boxes = [(20, 10, 37, 40), (20, 90, 37, 40), (20, 170, 37, 54), (20, 250, 37, 40)]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 5, events)
        self.assertTrue(38 <= out[2][3] <= 46, out[2])
        self.assertGreaterEqual(out[3][1], 206)
        self.assertLessEqual(out[3][3], 18, out[3])

    def test_normal_boxes_untouched(self):
        mask = self._vertical_mask()
        boxes = [(20, 10, 37, 40), (20, 90, 37, 40), (20, 170, 37, 41), (20, 250, 37, 40)]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(out, boxes)
        self.assertEqual(events, [])

    def test_two_full_chars_in_box_split_into_two(self):
        # 超高框里是两个整字（如 cuts 错位并字）：每段都占满字宽 → 各自
        # 是字，拆成两框（此前保守不拆；宽度判据引入后按字独立成框）
        mask = self._vertical_mask(extra_blobs=[(20, 220, 56, 259)])
        boxes = [(20, 10, 37, 40), (20, 90, 37, 40), (20, 170, 37, 90), (20, 270, 37, 40)]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 5, events)
        pieces = events[0]["new"]
        self.assertEqual(len(pieces), 2)
        self.assertTrue(all(38 <= p[3] <= 46 for p in pieces), pieces)

    def test_thick_yi_run_splits_despite_punct_cap(self):
        # 用户实测：粗笔画『一』墨迹高 23 超过主字段 31 的 62%，此前被
        # "疑似多字粘连"误拒、整框 59px 保留；横向占满字宽 → 是字，
        # 独立成框
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 90, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        cv2.rectangle(mask, (22, 170), (56, 200), 255, -1)  # 上字 墨迹高 31
        cv2.rectangle(mask, (24, 206), (54, 228), 255, -1)  # 粗『一』高 23
        boxes = [(20, 10, 37, 40), (20, 90, 37, 40), (20, 170, 37, 62), (20, 250, 37, 40)]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 5, events)
        char_piece, yi_piece = out[2], out[3]
        self.assertTrue(29 <= char_piece[3] <= 37, char_piece)
        self.assertTrue(21 <= yi_piece[3] <= 29, yi_piece)
        self.assertTrue(yi_piece[2] >= 30, yi_piece)  # 『一』：全列宽

    def test_split_recovers_when_median_inflated(self):
        # 一行里同框框偏多（3/5），中位基线被抬到同框框高度，第一轮只
        # 拆得动最高的"标点+字+标点"框；拆掉后基线回落，第二轮把两个
        # 1.0 倍边缘框捞出
        mask = np.zeros((460, 80), dtype=np.uint8)
        for top in (10, 90, 170, 270, 350):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        for top in (138, 218, 250, 320):  # 4 个贴字标点
            cv2.rectangle(mask, (30, top), (41, top + 9), 255, -1)
        boxes = [
            (20, 10, 37, 40),    # 正常字
            (20, 90, 37, 58),    # 字+下方标点（边缘案例）
            (20, 170, 37, 58),   # 字+下方标点（边缘案例）
            (20, 250, 37, 80),   # 标点+字+标点（最高，第一轮可拆）
            (20, 350, 37, 40),   # 正常字
        ]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 460, "vertical")
        # 全部拆开：5 框 → 2 个正常字 + 2×(字+标点) + (标点+字+标点)
        self.assertEqual(len(out), 9, events)
        self.assertEqual(len(events), 3)
        # 拆完后再无超高框（除 pad 外都回到正常字高/标点高）
        self.assertTrue(all(b[3] <= 46 for b in out), out)

    def test_giant_box_dust_runs_not_made_into_speck_boxes(self):
        # 巨框盖住大段空白 + 空白里的尘点链：只有真实墨迹段成框。
        # 旧逻辑按"长度≥4 或 墨迹≥6px"留段，2px 宽的尘点（3 行×2px
        # =6px 墨迹）全部成框——一块空白拆成一串碎框并叠在同一位置
        # （用户实测"禄字叠了 18 层"）。尘点段每行平均墨迹远低于真实
        # 段，按最强段的 1/4 设门槛剔除。
        mask = np.zeros((420, 80), dtype=np.uint8)
        for top in (10, 90, 250, 330):
            cv2.rectangle(mask, (20, top), (44, top + 19), 255, -1)
        for top in range(120, 240, 16):   # 巨框空白区里的尘点链
            cv2.rectangle(mask, (30, top), (32, top + 2), 255, -1)
        boxes = [
            (18, 8, 30, 24),    # 正常字高的框
            (18, 86, 32, 190),  # 巨框：包住第 90 段真字 + 尘点区 + 第 250 段真字
            (18, 328, 30, 24),
        ]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 420, "vertical")
        # 巨框只拆出 2 个真实墨迹段，尘点全部不成框
        self.assertEqual(len(out), 4, (out, events))
        self.assertEqual(len(events), 1)
        self.assertEqual(len(events[0]["new"]), 2, events)

    def test_giant_box_over_pure_dust_keeps_single_box(self):
        # 巨框里只有尘点、没有真实墨迹段：不拆分（拆了只会产出碎框），
        # 整框原样保留交给下游墨迹校验兜底
        mask = np.zeros((420, 80), dtype=np.uint8)
        for top in (10, 330):
            cv2.rectangle(mask, (20, top), (44, top + 19), 255, -1)
        for top in range(120, 300, 16):
            cv2.rectangle(mask, (30, top), (32, top + 2), 255, -1)
        boxes = [
            (18, 8, 30, 24),
            (18, 100, 32, 200),  # 巨框：纯尘点区
            (18, 328, 30, 24),
        ]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 420, "vertical")
        self.assertEqual(len(out), 3, (out, events))
        self.assertEqual(events, [])

    def test_giant_box_split_by_white_gaps(self):
        # 边栏网址列实测形态：本行字高 ~24px，cuts 退化出巨框包住多段
        # 墨迹（拉丁字母串/小字）——按白色空隙逐段拆开，不受
        # "主字段+标点段"结构约束
        mask = np.zeros((420, 80), dtype=np.uint8)
        for top in (10, 90, 170, 250, 330):
            cv2.rectangle(mask, (20, top), (44, top + 19), 255, -1)
        boxes = [
            (18, 8, 30, 24),    # 正常字高的框（盖住第 1/5 段墨迹）
            (18, 328, 30, 24),
            (18, 86, 32, 190),  # 巨框：cuts 并格，包住第 2/3/4 三段
        ]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 420, "vertical")
        self.assertEqual(len(out), 5, events)
        self.assertEqual(len(events), 1)
        pieces = events[0]["new"]
        self.assertEqual(len(pieces), 3)
        self.assertTrue(all(p[3] <= 26 for p in pieces), pieces)
        ys = sorted(p[1] for p in pieces)
        self.assertTrue(84 <= ys[0] <= 92 and 164 <= ys[1] <= 172 and 244 <= ys[2] <= 252, pieces)

    def test_semicolon_glyph_runs_merge_into_one_piece(self):
        # 『字；』同框：分号由上圆点+下钩两段墨迹组成，拆分时紧挨的
        # 标点段合并成一块——一个分号一个框（此前圆点/钩各成一框）
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 90, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        cv2.rectangle(mask, (20, 170), (56, 209), 255, -1)   # 字
        cv2.circle(mask, (38, 216), 3, 255, -1)              # 上圆点 rows 213..219
        cv2.rectangle(mask, (33, 222), (43, 230), 255, -1)   # 下钩 rows 222..230
        boxes = [(20, 10, 37, 40), (20, 90, 37, 40), (20, 170, 37, 61), (20, 250, 37, 40)]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 5, events)
        char_piece, punct_piece = out[2], out[3]
        self.assertTrue(38 <= char_piece[3] <= 46, char_piece)
        self.assertTrue(16 <= punct_piece[3] <= 26, punct_piece)
        self.assertGreaterEqual(punct_piece[1], 209)

    def test_adjacent_punct_boxes_merged(self):
        # cuts/连通域路径已把分号拆成上下两个小框：行内后检按"都远小于
        # 本行字高 + 紧挨（间距 ≤ 15% 中位字高）"合并回一个框
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 90, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        cv2.circle(mask, (38, 176), 3, 255, -1)              # 上圆点 rows 173..179
        cv2.rectangle(mask, (33, 184), (43, 192), 255, -1)   # 下钩 rows 184..192
        boxes = [
            (20, 10, 37, 40), (20, 90, 37, 40),
            (28, 173, 10, 9), (28, 184, 10, 9),
            (20, 250, 37, 40),
        ]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 4, events)
        punct = out[2]
        self.assertTrue(16 <= punct[3] <= 26, punct)
        self.assertTrue(170 <= punct[1] <= 176, punct)

    def test_separate_puncts_not_merged(self):
        # 两个独立标点（间距远大于标点内部部件间距）不合并
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 90, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        cv2.circle(mask, (38, 176), 3, 255, -1)
        cv2.circle(mask, (38, 196), 3, 255, -1)
        boxes = [
            (20, 10, 37, 40), (20, 90, 37, 40),
            (28, 173, 10, 9), (28, 196, 10, 9),
            (20, 250, 37, 40),
        ]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 5, events)

    def test_yi_glyph_not_merged_with_adjacent_punct(self):
        # 『一』墨迹矮（按高度会被当标点大小）但横向占满列宽——不能与
        # 紧挨的标点合并成大框（实测『一』+标点同框问题）
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 90, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        cv2.rectangle(mask, (20, 172), (56, 180), 255, -1)  # 『一』rows 172..180
        cv2.rectangle(mask, (33, 184), (43, 192), 255, -1)  # 标点 rows 184..192
        boxes = [
            (20, 10, 37, 40), (20, 90, 37, 40),
            (19, 170, 38, 12),  # 『一』的框：宽 38（列宽级）、高 12
            (31, 182, 12, 12),  # 标点框：宽 12
            (20, 250, 37, 40),
        ]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 5, events)

    def test_yi_run_not_grouped_with_punct_in_split(self):
        # 『字一，』同框拆分：横画段（矮而宽）独立成框，不与紧挨的标点
        # 段合并成"大框"
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 90, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        cv2.rectangle(mask, (20, 170), (56, 209), 255, -1)  # 字 rows 170..209
        cv2.rectangle(mask, (20, 212), (56, 220), 255, -1)  # 『一』rows 212..220（全宽）
        cv2.rectangle(mask, (33, 222), (43, 230), 255, -1)  # 标点 rows 222..230
        boxes = [(20, 10, 37, 40), (20, 90, 37, 40), (20, 170, 37, 61), (20, 250, 37, 40)]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 6, events)  # 2 正常 + 字 + 一 + 标点 + 1 正常
        self.assertTrue(38 <= out[2][3] <= 46, out[2])  # 字
        self.assertTrue(8 <= out[3][3] <= 16, out[3])   # 一（矮）
        self.assertTrue(out[3][2] >= 30, out[3])        # 一（宽：列宽级）
        self.assertTrue(8 <= out[4][3] <= 16, out[4])   # 标点（矮且窄）
        self.assertLess(out[4][2], 25, out[4])

    def test_short_line_untouched(self):
        # 行内字框不足 3 个：中位数不稳，不处理
        mask = self._vertical_mask(extra_blobs=[(30, 218, 41, 227)])
        boxes = [(20, 10, 37, 40), (20, 170, 37, 58)]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(out, boxes)

    def test_horizontal_split_supported(self):
        mask = np.zeros((80, 400), dtype=np.uint8)
        for left in (10, 90, 170, 250):
            cv2.rectangle(mask, (left, 20), (left + 36, 59), 255, -1)
        cv2.rectangle(mask, (218, 30), (227, 41), 255, -1)  # 第三个字右上的标点
        boxes = [(10, 20, 40, 37), (90, 20, 40, 37), (170, 20, 58, 37), (250, 20, 40, 37)]
        out, events = split_punct_merged_boxes(boxes, mask, 400, 80, "horizontal")
        self.assertEqual(len(out), 5)
        char_box, punct_box = out[2], out[3]
        self.assertTrue(38 <= char_box[2] <= 46, char_box)
        self.assertTrue(8 <= punct_box[2] <= 16, punct_box)

    def test_axis_desc_keeps_reading_order(self):
        # 横排 rtl：阅读轴降序，拆出的框按降序插入（阅读序）
        mask = np.zeros((80, 400), dtype=np.uint8)
        for left in (10, 90, 170, 250):
            cv2.rectangle(mask, (left, 20), (left + 36, 59), 255, -1)
        cv2.rectangle(mask, (218, 30), (227, 41), 255, -1)
        boxes = [(250, 20, 40, 37), (170, 20, 58, 37), (90, 20, 40, 37), (10, 20, 40, 37)]
        out, _ = split_punct_merged_boxes(
            boxes, mask, 400, 80, "horizontal", axis_desc=True
        )
        self.assertEqual(len(out), 5)
        punct_box, char_box = out[1], out[2]
        self.assertGreater(punct_box[0], char_box[0])  # 阅读序：标点在字前
        self.assertLess(punct_box[2], char_box[2])




class SplitSingleGlyphComponentGapTests(unittest.TestCase):
    """『需』=雨+而 的部件间横向留白不被"两字粘连"分支拆开。"""

    def _mask(self, ink_bands):
        mask = np.zeros((400, 40), dtype=np.uint8)
        for y1, y2 in ink_bands:
            cv2.rectangle(mask, (10, y1), (30, y2), 255, -1)
        return mask

    def _run(self, mask, boxes):
        out, events = split_punct_merged_boxes(
            boxes, mask, mask.shape[1], mask.shape[0], "vertical",
        )
        return out, events

    def test_glyph_internal_gap_not_split(self):
        # 4 个正常字（span 30，中位）+『需』框（span 46）：雨 112..130、
        # 留白 131..132、而 133..149——两段都达字宽、都只有半字高、合计
        # 38 < 1.5×30 → 单字部件留白，不拆（修复前会拆成上下两半各读
        # 成一个别的字）。
        mask = self._mask([
            (10, 39), (50, 79), (170, 199), (210, 239),  # 4 个正常字
            (112, 130), (133, 149),  # 『需』的雨/而两段
        ])
        boxes = [
            (8, 8, 26, 30), (8, 48, 26, 30), (8, 168, 26, 30),
            (8, 208, 26, 30), (8, 106, 26, 46),
        ]
        out, events = self._run(mask, boxes)
        self.assertEqual(events, [])
        self.assertEqual(len(out), 5)
        self.assertIn((8, 106, 26, 46), out)

    def test_two_stuck_chars_still_split(self):
        # 真·两字粘连：两段各 ≈1×字高、合计 58 ≥ 1.5×30 → 照常拆开。
        mask = self._mask([
            (10, 39), (50, 79), (170, 199), (210, 239),
            (112, 141), (145, 169),  # 两个整字
        ])
        boxes = [
            (8, 8, 26, 30), (8, 48, 26, 30), (8, 168, 26, 30),
            (8, 208, 26, 30), (8, 106, 26, 66),
        ]
        out, events = self._run(mask, boxes)
        self.assertEqual(len(events), 1)
        self.assertEqual(len(out), 6)

    def test_cut_apart_glyph_halves_merged(self):
        # 真实链路场景：Kraken cuts 把『需』=雨+而 各切一格（两个全宽、
        # 半字高、互相搭接的框，各读成一个别的字）——行内合并按"都占
        # 满字宽 + 都只有半字高 + 紧挨/重叠 + 合计 ≤ 一个字高"并回
        # 一个字框。
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 90, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        cv2.rectangle(mask, (24, 170), (52, 188), 255, -1)  # 雨 18px 全宽
        cv2.rectangle(mask, (24, 186), (52, 207), 255, -1)  # 而 21px 全宽
        boxes = [
            (20, 10, 37, 40), (20, 90, 37, 40),
            (22, 170, 30, 18), (22, 186, 30, 21),
            (20, 250, 37, 40),
        ]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 4, events)
        glyph = out[2]
        self.assertTrue(36 <= glyph[3] <= 42, glyph)  # ≈ 一个字高
        self.assertTrue(28 <= glyph[2] <= 33, glyph)  # 全宽

    def test_yi_plus_punct_still_separate_after_merge_change(self):
        # 一宽一窄（『一』+紧挨标点）保持分离：横画类字保护不变。
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 90, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        cv2.rectangle(mask, (22, 172), (54, 176), 255, -1)  # 一 全宽 5px
        cv2.circle(mask, (38, 182), 3, 255, -1)             # ，窄小
        boxes = [
            (20, 10, 37, 40), (20, 90, 37, 40),
            (22, 172, 30, 5), (34, 179, 8, 9),
            (20, 250, 37, 40),
        ]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 5, events)

    def test_two_wide_thin_chars_with_gap_not_merged(self):
        # 两个独立的横画字（间距 > 15% 中位字高）不并。
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 90, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        cv2.rectangle(mask, (22, 172), (54, 176), 255, -1)  # 一
        cv2.rectangle(mask, (22, 186), (54, 190), 255, -1)  # 一（隔 9px）
        boxes = [
            (20, 10, 37, 40), (20, 90, 37, 40),
            (22, 172, 30, 5), (22, 186, 30, 5),
            (20, 250, 37, 40),
        ]
        out, events = split_punct_merged_boxes(boxes, mask, 80, 400, "vertical")
        self.assertEqual(len(out), 5, events)

    @staticmethod
    def _hui_mask():
        # 5 个正常字（52px 高、实心块）+『會』：人字头（V 形两笔，上窄
        # 下宽 → 非实心横带）+ 4px 部件缝 + 身部（空心框、45px 高）。
        mask = np.zeros((480, 80), dtype=np.uint8)
        for top in (10, 82, 154, 226, 298):
            cv2.rectangle(mask, (20, top), (56, top + 51), 255, -1)
        cv2.line(mask, (38, 370), (21, 395), 255, 3)  # 人字头左笔
        cv2.line(mask, (38, 370), (55, 395), 255, 3)  # 人字头右笔
        cv2.rectangle(mask, (24, 403), (54, 445), 255, 3)  # 身部（空心）
        return mask

    def test_asymmetric_glyph_gap_not_split(self):
        # 『會』=人字头 27px+身 44px：部件高度不对称（身部 0.8×中位，
        # 超半字高上限，旧护栏漏放会把會拦腰拆成两框、身部单独读成
        # 『日』）。缝仅 4px 且人字头非实心横带 → 宽段窄缝护栏拒拆。
        mask = self._hui_mask()
        boxes = [
            (18, 8, 40, 55), (18, 80, 40, 55), (18, 152, 40, 55),
            (18, 224, 40, 55), (18, 296, 40, 55),
            (19, 367, 38, 80),  # 『會』整字框
        ]
        out, events = self._run(mask, boxes)
        self.assertEqual(events, [])
        self.assertEqual(len(out), 6)
        self.assertIn((19, 367, 38, 80), out)

    def test_asymmetric_glyph_fragments_merged(self):
        # cuts 把『會』的人字头/身各切一格（高度不对称、身部超半字高
        # 上限）→ 宽段窄缝并回一个整字框（缝窄、合计 ≤1.5 字高、最短
        # 段非实心横带且达部件高度）。
        mask = self._hui_mask()
        boxes = [
            (18, 8, 40, 55), (18, 80, 40, 55), (18, 152, 40, 55),
            (18, 224, 40, 55), (18, 296, 40, 55),
            (19, 367, 38, 31),  # 人字头框
            (19, 401, 38, 47),  # 身部框
        ]
        out, events = self._run(mask, boxes)
        glyphs = [b for b in out if 365 <= b[1] <= 372]
        self.assertEqual(len(glyphs), 1, out)
        self.assertTrue(75 <= glyphs[0][3] <= 85, glyphs[0])  # ≈ 會 整字

    def test_tight_narrow_punct_below_char_still_splits(self):
        # 约束回归：窄标点紧贴字下（缝 4px，与部件缝同量级）→ 标点宽度
        # 不足 65% 字宽，不命中宽段窄缝护栏，照常拆出独立标点框。
        mask = np.zeros((480, 80), dtype=np.uint8)
        for top in (10, 82, 154, 226):
            cv2.rectangle(mask, (20, top), (56, top + 51), 255, -1)
        cv2.rectangle(mask, (20, 298), (56, 350), 255, -1)  # 字
        cv2.rectangle(mask, (33, 355), (44, 364), 255, -1)  # 窄标点（隔 4px）
        boxes = [
            (18, 8, 40, 55), (18, 80, 40, 55), (18, 152, 40, 55),
            (18, 224, 40, 55), (19, 296, 38, 72),  # 字+标点同框
        ]
        out, events = self._run(mask, boxes)
        self.assertEqual(len(events), 1)
        self.assertEqual(len(out), 6)
        punct = out[5]
        self.assertTrue(8 <= punct[3] <= 18, punct)
        self.assertLess(punct[2], 25, punct)

    def test_shu_class_fragment_tail_merged(self):
        # 『數』=上部（宽、约 0.5×中位、非实心）+攵脚碎尾（窄、约 0.2×
        # 中位）被切成两框：本书字距最小实测 3~4px（將/實/際 几乎相贴），
        # 缝宽判据失效——按"有分量的部件+碎尾、合计 ≤1.1×中位"併回一
        # 个字框。整字+紧贴标点不命中（宽段达整字高，>0.75×中位）。
        mask = np.zeros((480, 80), dtype=np.uint8)
        for top in (10, 82, 154, 226, 298):
            cv2.rectangle(mask, (20, top), (56, top + 51), 255, -1)
        cv2.rectangle(mask, (21, 370), (55, 392), 255, 3)  # 數 上部（空心）
        cv2.rectangle(mask, (30, 396), (38, 404), 255, -1)  # 攵脚碎尾（隔 3px）
        boxes = [
            (18, 8, 40, 55), (18, 80, 40, 55), (18, 152, 40, 55),
            (18, 224, 40, 55), (18, 296, 40, 55),
            (19, 368, 38, 26),   # 數 上部框
            (28, 393, 22, 13),   # 攵脚碎尾框
        ]
        out, events = self._run(mask, boxes)
        glyphs = [b for b in out if 365 <= b[1] <= 372]
        self.assertEqual(len(glyphs), 1, out)
        self.assertTrue(30 <= glyphs[0][3] <= 42, glyphs[0])  # ≈ 數 整字




class PunctTailColumnRescueTests(unittest.TestCase):
    """段末标点独占一列：行检测补捞成行，不再丢句号。"""

    @staticmethod
    def _write_page(path, width, height, blobs):
        img = np.full((height, width, 3), 255, dtype=np.uint8)
        for x1, y1, x2, y2 in blobs:
            cv2.rectangle(img, (x1, y1), (x2, y2), (0, 0, 0), -1)
        cv2.imwrite(str(path), img)

    @staticmethod
    def _body_blobs(columns=3, chars=10):
        # 二维抖动的字块：x_proj/y_proj 都要有分布，分列/行内的分位阈值
        # 才能像真实页面那样工作（完全整齐的字块会被阈值整体压掉）。
        blobs = []
        for ci in range(columns):
            cx = 300 - ci * 100
            for i in range(chars):
                y = 20 + i * 40 + (i % 2)
                jx = (i * 3) % 7 - 3
                jw = 22 + (i % 4) * 2
                jh = 24 + (i % 3) * 3
                blobs.append((cx + jx, y, cx + jx + jw, y + jh))
        return blobs

    def test_opencv_fallback_keeps_lone_punct_column(self):
        # OpenCV 兜底分列：正文列 + 段末句号独占一列 + 下方小噪点。
        # 修复前 35 分位阈值把句号列整个丢掉，段落少个句号。
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "page.png"
            blobs = self._body_blobs()
            blobs.append((40, 150, 52, 162))  # 句号 12x12 独占一列
            blobs.append((45, 500, 46, 501))  # 2x2 噪点（开运算清除）
            self._write_page(image_path, 400, 640, blobs)
            lines, _blocks = _segment_with_opencv(str(image_path))
            punct_lines = [l for l in lines if l["x"] <= 60]
            self.assertEqual(len(punct_lines), 1, lines)
            line = punct_lines[0]
            self.assertTrue(145 <= line["y"] <= 152, line)
            self.assertTrue(12 <= line["h"] <= 20, line)
            # 正文列不受影响
            self.assertEqual(len([l for l in lines if l["x"] >= 90]), 3)

    def test_projection_strips_rescue_ignores_specks(self):
        # 投影条带路径（YOLO 字检测分组用）：句号列被补捞，且条带内
        # 散落噪点（面积 <8）不撑大行框。
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "page.png"
            blobs = self._body_blobs()
            blobs.append((40, 150, 52, 162))  # 句号
            blobs.append((45, 500, 46, 502))  # 噪点（此 mask 无开运算）
            self._write_page(image_path, 400, 640, blobs)
            strips = _vertical_line_strips(str(image_path), 400, 640)
            self.assertTrue(any(sx <= 60 for sx, _sw in strips), strips)
            grouped = _group_yolo_char_rects_into_lines(
                [(300, 20, 26, 28)], 400, 640, image_path=str(image_path),
            )
            punct_lines = [g for g in grouped if g and g[0][0] <= 60]
            self.assertEqual(len(punct_lines), 1, grouped)
            rect = punct_lines[0][0]
            self.assertTrue(12 <= rect[3] <= 20, rect)

    def test_scattered_marks_column_not_rescued(self):
        # 跨度超限（散落半页的孤立点）不是段尾标点列，不补捞。
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "page.png"
            blobs = self._body_blobs()
            blobs.append((40, 150, 52, 162))   # 句号
            blobs.append((42, 480, 54, 500))   # 半页外的另一个墨块
            self._write_page(image_path, 400, 640, blobs)
            strips = _vertical_line_strips(str(image_path), 400, 640)
            self.assertFalse(any(sx <= 60 for sx, _sw in strips), strips)
