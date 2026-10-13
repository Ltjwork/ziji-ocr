# -*- coding: utf-8 -*-
"""行框与收紧相关测试（从 test_segmenter 拆出）：行框扩展、边界几何、kraken-cuts 收紧、区域行延展、边缘填充与钳回。"""
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





class LineRectExpandTests(unittest.TestCase):
    """expand_line_rect_to_neighbor_ink：偏短行框沿阅读轴外扩到贴边字。"""

    def test_absorbs_edge_char_across_small_gap(self):
        # 密排竖列（字墨 40px、字距 14px），行框只画到第二个字：
        # 第三个字隔着正常字间距被捞回
        mask = np.zeros((220, 80), dtype=np.uint8)
        for top in (10, 64, 118):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        expanded = expand_line_rect_to_neighbor_ink(
            (15, 5, 50, 100), mask, 80, 220, "vertical"
        )
        self.assertEqual(expanded[1], 5)  # 上方无墨不扩
        self.assertTrue(157 <= expanded[1] + expanded[3] <= 160, expanded)

    def test_stops_at_large_white_gap(self):
        # 远处墨迹（空白超过约 3/4 字高）属于行外/栏外，不吸收
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 64, 250):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        same = expand_line_rect_to_neighbor_ink(
            (15, 5, 50, 100), mask, 80, 400, "vertical"
        )
        self.assertEqual((same[1], same[3]), (5, 100))

    def test_dust_chain_does_not_extend_line_into_blank_tail(self):
        # 行尾空白里的纸面尘点链不把行框拉走：文字行每行墨迹 37px，
        # 尘点行只有 2px 且间隔（20px）远小于 gap_limit（42px）——旧
        # "任一像素即墨迹"让尘点链不断重置空白计数、行框被一路拉到
        # 尘点链尽头（用户实测 11 字行扩到整页高，空白尾区被下游拆成
        # 一串碎框全部叠在同一位置）。尘点量级的行不算墨迹后，扩展
        # 停在真实墨迹末端。
        mask = np.zeros((400, 80), dtype=np.uint8)
        for top in (10, 64):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        for top in range(130, 380, 20):
            cv2.rectangle(mask, (38, top), (40, top + 2), 255, -1)
        rect = (15, 5, 50, 100)
        self.assertEqual(
            expand_line_rect_to_neighbor_ink(rect, mask, 80, 400, "vertical"),
            rect,
        )

    def test_no_expansion_without_edge_ink(self):
        mask = np.zeros((220, 80), dtype=np.uint8)
        for top in (10, 64, 118):
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        rect = (15, 5, 50, 165)  # 已覆盖全部墨迹
        self.assertEqual(
            expand_line_rect_to_neighbor_ink(rect, mask, 80, 220, "vertical"), rect
        )

    def test_horizontal_expansion_along_reading_axis(self):
        mask = np.zeros((80, 400), dtype=np.uint8)
        for left in (10, 64, 118):
            cv2.rectangle(mask, (left, 20), (left + 39, 56), 255, -1)
        expanded = expand_line_rect_to_neighbor_ink(
            (5, 15, 100, 50), mask, 400, 80, "horizontal"
        )
        self.assertEqual(expanded[1], 15)  # 纵向（非阅读轴）不动
        self.assertTrue(157 <= expanded[0] + expanded[2] <= 160, expanded)

    def test_expands_to_full_column_run_from_middle(self):
        # 用户实测案例形态：整列 10 字连续墨迹（字距 18px），行框只盖住
        # 中段第 5 字附近——外扩沿字距一路走到列的真实两端（没有 1.2 字
        # 高之类的上限，白色区间规则本身界定边界）
        mask = np.zeros((600, 80), dtype=np.uint8)
        for k in range(10):
            top = 10 + k * 58
            cv2.rectangle(mask, (20, top), (56, top + 39), 255, -1)
        rect = (15, 5 + 58 * 4, 50, 100)
        expanded = expand_line_rect_to_neighbor_ink(rect, mask, 80, 600, "vertical")
        self.assertLessEqual(expanded[1], 12)
        self.assertGreaterEqual(expanded[1] + expanded[3], 568)

    def test_neighbor_column_through_narrow_gutter_not_chained(self):
        # 夹注小字段（x90..150）与相邻正文列只隔 3px 窄缝、正文列连续
        # 整页高：外扩的跨轴窗口只统计原框自有墨迹范围，邻列左缘笔画
        # 不经缝隙喂入链条——两字段保持原框（只有自有墨迹连续才外扩）。
        mask = np.zeros((400, 240), dtype=np.uint8)
        for top in (10, 77):
            cv2.rectangle(mask, (90, top), (150, top + 54), 255, -1)
        cv2.rectangle(mask, (153, 0), (200, 399), 255, -1)
        rect = (85, 5, 67, 132)
        self.assertEqual(
            expand_line_rect_to_neighbor_ink(rect, mask, 240, 400, "vertical"),
            rect,
        )




class LineGeometryBoundaryTests(unittest.TestCase):
    """worker 行几何：boundary 沿阅读轴外扩 2px 不得越出图像（贴边行框
    外扩越界时 extract_polygons 直接报错、整行读空）。"""

    def test_boundary_clamped_at_page_edge_vertical(self):
        # 行框贴页顶（y=0）：竖排 boundary 的 y-2 收进界内
        _, boundary, _ = _line_geometry(
            {"x": 0, "y": 0, "w": 40, "h": 120}, "vertical-rl", 2.0, 80, 240
        )
        for px, py in boundary:
            self.assertGreaterEqual(px, 0)
            self.assertGreaterEqual(py, 0)
            self.assertLessEqual(px, 79)
            self.assertLessEqual(py, 239)

    def test_boundary_clamped_at_page_edge_horizontal(self):
        # 行框贴页左（x=0）：横排 boundary 的 x-2 收进界内
        _, boundary, _ = _line_geometry(
            {"x": 0, "y": 0, "w": 120, "h": 40}, "horizontal-lr", 2.0, 240, 80
        )
        for px, py in boundary:
            self.assertGreaterEqual(px, 0)
            self.assertGreaterEqual(py, 0)
            self.assertLessEqual(px, 239)
            self.assertLessEqual(py, 79)

    def test_boundary_extends_when_room_available(self):
        _, boundary, _ = _line_geometry(
            {"x": 10, "y": 10, "w": 40, "h": 120}, "vertical-rl", 1.0, 200, 200
        )
        ys = [py for _px, py in boundary]
        self.assertEqual(min(ys), 8)
        self.assertEqual(max(ys), 132)




class TightenBoxesTests(unittest.TestCase):
    """kraken-cuts 条带框收紧为贴字框（训练导出的框要贴住字形）。"""

    def _tighten(self, boxes, mask):
        with patch("segmenter._text_mask_for_refinement", return_value=mask):
            return _tighten_boxes_to_ink("fake.png", boxes)

    def test_strip_box_tightens_to_ink(self):
        mask = np.zeros((100, 100), dtype=np.uint8)
        mask[30:40, 20:30] = 255  # 墨迹 x∈[20,30) y∈[30,40)
        out = self._tighten([(0, 25, 100, 20)], mask)
        self.assertEqual(out, [(20, 30, 10, 10)])

    def test_empty_cell_keeps_strip_box(self):
        mask = np.zeros((100, 100), dtype=np.uint8)
        out = self._tighten([(0, 0, 100, 50)], mask)
        self.assertEqual(out, [(0, 0, 100, 50)])

    def test_speck_keeps_strip_box(self):
        mask = np.zeros((100, 100), dtype=np.uint8)
        mask[50, 50] = 255  # 1×1 噪点
        out = self._tighten([(40, 45, 20, 12)], mask)
        self.assertEqual(out, [(40, 45, 20, 12)])

    def test_horizontal_stroke_char_tightens_despite_thin_ink(self):
        # 『一』墨迹只有 2~5px 高、宽度却占满大半行墨宽：矮而宽是字
        # 不是噪点，照常收紧——否则整行宽的条带框原样保留，字框比
        # 同行其他字宽一截（实测 43px vs 同行中位 29px）。
        mask = np.zeros((120, 60), dtype=np.uint8)
        cv2.rectangle(mask, (25, 10), (34, 39), 255, -1)  # 第一格的整字
        cv2.rectangle(mask, (25, 70), (35, 72), 255, -1)  # 第二格的『一』(11×3)
        strip = [(20, 5, 20, 50), (20, 55, 20, 50)]
        out = self._tighten(strip, mask)
        self.assertEqual(out[0], (25, 10, 10, 30))
        self.assertEqual(out[1], (25, 70, 11, 3))

    def test_thin_narrow_ink_still_keeps_strip_box(self):
        # 又矮又窄（宽度不足行墨宽 65%）的墨迹仍是噪点：保留条带框。
        mask = np.zeros((120, 60), dtype=np.uint8)
        cv2.rectangle(mask, (25, 10), (34, 39), 255, -1)  # 第一格的整字
        cv2.rectangle(mask, (28, 70), (30, 72), 255, -1)  # 3×3 墨点
        strip = [(20, 5, 20, 50), (20, 55, 20, 50)]
        out = self._tighten(strip, mask)
        self.assertEqual(out[0], (25, 10, 10, 30))
        self.assertEqual(out[1], strip[1])

    def test_decisions_logged_to_debug_trace(self):
        # 切分日志要能解释"这个字的框为什么宽"：保留条带写明原因与
        # 阈值，横画豁免收紧单独成行，行级汇总给出参考行墨宽。
        import segmenter as seg_mod

        mask = np.zeros((120, 60), dtype=np.uint8)
        cv2.rectangle(mask, (25, 10), (34, 39), 255, -1)  # 第一格的整字
        cv2.rectangle(mask, (25, 70), (35, 72), 255, -1)  # 第二格的『一』(11×3)
        mask[110, 28] = 255  # 第三格里的 1×1 墨点
        strip = [(20, 5, 20, 50), (20, 55, 20, 50), (20, 105, 20, 10)]
        seg_mod.begin_debug_trace()
        with patch("segmenter._text_mask_for_refinement", return_value=mask):
            out = _tighten_boxes_to_ink("fake.png", strip)
        trace = "\n".join(seg_mod.debug_trace_snapshot())
        self.assertEqual(out[1], (25, 70, 11, 3))
        self.assertIn("横画收紧", trace)
        self.assertIn("疑似噪点不收紧", trace)
        self.assertIn("[tighten] 行框=", trace)  # 行级汇总
        self.assertIn("噪点宽度阈值", trace)

    def test_box_clamped_to_mask_bounds(self):
        mask = np.zeros((100, 100), dtype=np.uint8)
        mask[90:100, 90:100] = 255
        out = self._tighten([(80, 85, 40, 40)], mask)  # 越出 mask 的部分被裁掉
        self.assertEqual(out, [(90, 90, 10, 10)])

    def test_each_cell_tightened_independently(self):
        # 一列两格：主体字格收紧到字，句号格收紧到小圆点。
        mask = np.zeros((120, 60), dtype=np.uint8)
        cv2.rectangle(mask, (25, 10), (34, 49), 255, -1)  # 第一格的整字
        cv2.circle(mask, (29, 65), 4, 255, -1)  # 第二格的句号（约 9px）
        strip = [(20, 5, 20, 50), (20, 55, 20, 50)]
        out = self._tighten(strip, mask)
        self.assertEqual(out[0], (25, 10, 10, 40))
        self.assertEqual(out[1], (25, 61, 9, 9))
        # 收紧后框不再等宽（不再被判为合成均分框）
        self.assertNotEqual(out[0][2], out[1][2])

    def test_glyph_crossing_cell_boundary_not_chopped(self):
        # 高字/贴字标点跨过格边界（相邻字中心线的中点）：格边界在 y=55，
        # 字的墨迹 45..74。按墨迹整段归属（中心 59.5 落在第二格），
        # 第二格的框向上扩到完整字形，不再被格边界切成半个字——
        # 半个字的 crop 会被识别成部件相似的字（需→雨、出→山），
        # 再当候选挂出就是"候选=别的字"。
        mask = np.zeros((120, 60), dtype=np.uint8)
        cv2.rectangle(mask, (25, 45), (34, 74), 255, -1)
        strip = [(20, 5, 20, 50), (20, 55, 20, 50)]
        out = self._tighten(strip, mask)
        self.assertEqual(out[1], (25, 45, 10, 30))  # 完整字形，越过 y=55
        self.assertEqual(out[0], strip[0])  # 第一格无墨迹，保留条带框

    def test_stuck_multichar_run_split_across_cells(self):
        # 洇墨粘连：三个字的墨迹连成一整段（无纯白空隙），跨 2 条格
        # 边界。整段归中心格会拉出一个 3 字高巨框、其余两格成幽灵
        # 空位条带（实测 22 格列 11 字连成 1044px：11 字高巨框 + 11
        # 个空位框）。应按格边界切开各归各格。
        mask = np.zeros((120, 60), dtype=np.uint8)
        cv2.rectangle(mask, (25, 10), (34, 89), 255, -1)  # 三字连成一段
        strip = [(20, 5, 20, 30), (20, 35, 20, 30), (20, 65, 20, 30)]
        out = self._tighten(strip, mask)
        self.assertEqual(out, [(25, 10, 10, 25), (25, 35, 10, 30), (25, 65, 10, 25)])

    def test_stuck_two_char_run_split_at_single_boundary(self):
        # 两个字粘连恰好跨两格（只跨 1 条边界）但段长 ≈ 两格
        # （> 1.8× 中位格长）：同样切开——不切就是"两字高"巨框。
        mask = np.zeros((140, 60), dtype=np.uint8)
        cv2.rectangle(mask, (25, 10), (34, 109), 255, -1)  # 两字粘连
        strip = [(20, 5, 20, 50), (20, 55, 20, 50)]
        out = self._tighten(strip, mask)
        self.assertEqual(out, [(25, 10, 10, 45), (25, 55, 10, 50)])

    def test_single_char_run_crossing_one_boundary_stays_whole(self):
        # 单字墨迹跨 1 条格边界但不足 1.8× 中位格长：仍是"高字/贴字
        # 标点"保护范围，整段归属、不被格边界切断（回归保护）。
        mask = np.zeros((120, 60), dtype=np.uint8)
        cv2.rectangle(mask, (25, 45), (34, 84), 255, -1)  # 40px，跨 y=55 一条边界
        strip = [(20, 5, 20, 50), (20, 55, 20, 50)]
        out = self._tighten(strip, mask)
        self.assertEqual(out[1], (25, 45, 10, 40))
        self.assertEqual(out[0], strip[0])

    def test_stuck_run_split_horizontal(self):
        # 横排同链路：粘连长段沿 X 轴按格边界切开（判据沿阅读轴自适应）。
        mask = np.zeros((60, 120), dtype=np.uint8)
        cv2.rectangle(mask, (10, 25), (109, 34), 255, -1)  # 两字粘连
        strip = [(5, 20, 50, 20), (55, 20, 50, 20)]
        with patch("segmenter._text_mask_for_refinement", return_value=mask):
            out = _tighten_boxes_to_ink("fake.png", strip, "horizontal")
        self.assertEqual(out, [(10, 25, 45, 10), (55, 25, 50, 10)])

    def test_tiny_gap_glyph_runs_fused_to_one_cell(self):
        # 『會』的人字头（非实心、上窄下宽）与身部（空心、行墨量仅两
        # 竖笔）隔 4px 部件缝：归格前先并成一段再按中心归属，整字落同
        # 一格（不并段时两段中心分落相邻两格、會被切成两框，实测身部
        # 单独读成『日』）。
        mask = np.zeros((160, 60), dtype=np.uint8)
        cv2.line(mask, (32, 10), (25, 34), 255, 3)   # 人字头左笔
        cv2.line(mask, (32, 10), (39, 34), 255, 3)   # 人字头右笔
        cv2.rectangle(mask, (23, 41), (41, 82), 255, 3)  # 身部（空心）
        cv2.rectangle(mask, (27, 120), (36, 155), 255, -1)  # 下一字
        strip = [(20, 0, 24, 55), (20, 55, 24, 105)]
        out = self._tighten(strip, mask)
        self.assertEqual(out[0], (21, 8, 23, 77))       # 會 整字（部件缝不再切開）
        self.assertEqual(out[1], (27, 120, 10, 36))     # 下一字不受影响

    def test_solid_band_runs_not_fused(self):
        # 字与紧贴的『一』（实测间隔可仅 2~6px，与部件缝同量级）：『一』
        # 是实心横带（延展均匀且行墨量≈延展宽），不参与窄缝并段，仍各
        # 归各格、各自成框。
        mask = np.zeros((160, 60), dtype=np.uint8)
        cv2.rectangle(mask, (27, 10), (36, 49), 255, -1)   # 字（40px）
        cv2.rectangle(mask, (23, 53), (37, 60), 255, -1)   # 一（隔 3px）
        strip = [(20, 0, 24, 55), (20, 55, 24, 105)]
        out = self._tighten(strip, mask)
        self.assertEqual(out[0], (27, 10, 10, 40))
        self.assertEqual(out[1], (23, 53, 15, 8))

    def test_drifted_end_boundary_fragment_reassigned(self):
        # 行尾格界漂移（kraken 相邻字符中心线的中点在行尾偏下，实测
        # "每行末两字：倒数第二框偏高、末框只剩半截"的来源）：末字是
        # "顶部短部件 + 主体"的留白字形（干/才类），漂移的分界把顶部
        # 部件按中心划给了倒数第二格。短部件按"两侧跨度向中位格长收敛"
        # 并回末格——倒数第二框回到本字、末框收回完整字形。
        mask = np.zeros((600, 60), dtype=np.uint8)
        # 前 5 字各占一格（格长 94，字高 90）
        for k in range(5):
            top = 10 + k * 94
            cv2.rectangle(mask, (25, top + 2), (34, top + 91), 255, -1)
        # 末字（干类留白字形）：顶部短部件 484..500（17px 高、全宽），
        # 部件缝 21px，主体 522..568（窄条，丨形）
        cv2.rectangle(mask, (23, 484), (37, 500), 255, -1)
        cv2.rectangle(mask, (28, 522), (33, 568), 255, -1)
        # kraken 格界：前四条正常（中心线中点），第 5/6 格分界漂到 505
        # （末字中心估计偏下，落在末字部件缝里）
        strip = [
            (20, 10, 24, 94),
            (20, 104, 24, 94),
            (20, 198, 24, 94),
            (20, 292, 24, 94),
            (20, 386, 24, 119),  # 386..505：吞了末格顶部
            (20, 505, 24, 69),   # 505..574
        ]
        out = self._tighten(strip, mask)
        # 倒数第二框只含第 5 字，不再吞末字顶部部件
        self.assertEqual(out[4], (25, 388, 10, 90))
        # 末框收回顶部部件：完整字形（含留白），不再只剩半截
        self.assertEqual(out[5], (23, 484, 15, 85))

    def test_drifted_boundary_normal_pair_untouched(self):
        # 正常行（每格一个整字、两侧跨度已接近格长）：校正不挪任何段，
        # 收紧结果与归属原样一致（校正只在"一格虚胖一格不足"的漂移形态
        # 下介入）。
        mask = np.zeros((300, 60), dtype=np.uint8)
        for k in range(3):
            top = 10 + k * 94
            cv2.rectangle(mask, (25, top + 2), (34, top + 91), 255, -1)
        strip = [(20, 10, 24, 94), (20, 104, 24, 94), (20, 198, 24, 94)]
        out = self._tighten(strip, mask)
        self.assertEqual(out[0], (25, 12, 10, 90))
        self.assertEqual(out[1], (25, 106, 10, 90))
        self.assertEqual(out[2], (25, 200, 10, 90))

    def test_stuck_run_split_refined_to_ink_valley(self):
        # 洇墨粘连的两字（1px 窄桥连接）+ 漂移的格界（cut 在真实字界
        # 下方 ~21px）：切开位置贴到 cut 附近的最少墨行（粘连桥处），
        # 而不是原始 cut——按原始 cut 切开，上一格吞进下一字顶部（框偏
        # 高）、下一格矮（用户实测末两格分界 2066 vs 真实字界 ~2043 的
        # 形态）。
        mask = np.zeros((300, 60), dtype=np.uint8)
        cv2.rectangle(mask, (25, 12), (34, 98), 255, -1)   # 上一字
        cv2.rectangle(mask, (25, 104), (34, 190), 255, -1)  # 下一字
        cv2.line(mask, (29, 99), (29, 103), 255, 1)        # 洇墨窄桥
        # 格界漂移：真实字界 ~101，cut 放到 125
        strip = [(20, 10, 24, 115), (20, 125, 24, 73)]
        out = self._tighten(strip, mask)
        # 上格只含上一字（不被拉高吞进下一字顶部）
        self.assertEqual(out[0], (25, 12, 10, 87))
        # 下格从粘连桥处起：完整下一字，不再是半截
        self.assertEqual(out[1], (25, 99, 10, 92))

    def test_stuck_run_uniform_ink_keeps_raw_cut(self):
        # 窗口内墨迹均匀（实心合成块，无谷）：贴谷不介入，保持原始 cut
        # ——argmin 在均匀区间里是任意的，不能让噪声移动分界（既有
        # 粘连切分行为的回归保护）。
        mask = np.zeros((140, 60), dtype=np.uint8)
        cv2.rectangle(mask, (25, 10), (34, 109), 255, -1)  # 两字粘连（实心）
        strip = [(20, 5, 20, 50), (20, 55, 20, 50)]
        out = self._tighten(strip, mask)
        self.assertEqual(out, [(25, 10, 10, 45), (25, 55, 10, 50)])




class ExtendLinesToRegionInkTests(unittest.TestCase):
    """区域意图扩展：与区域相交的行沿自身列带扩到区域内的墨迹。"""

    def _line(self, x, y, w, h):
        return {"id": "l1", "x": x, "y": y, "w": w, "h": h, "chars": []}

    def test_vertical_line_extended_to_region_ink(self):
        # 夹注列：检测行框只盖下半段，用户区域盖整列 → 行框扩到区域
        # 内墨迹两端（顶部段是检测漏掉的字，区域框选表达了归属意图）。
        mask = np.zeros((200, 60), dtype=np.uint8)
        mask[20:45, 26:34] = 255  # 顶部字（检测漏掉）
        mask[100:130, 25:35] = 255  # 行框内已有字
        result = {"lines": [self._line(27, 95, 8, 40)]}
        out = extend_lines_to_region_ink(
            result, (10, 10, 50, 180), mask, "vertical",
        )
        ln = out["lines"][0]
        self.assertEqual(ln["y"], 18)  # 20 - pad(2)
        self.assertEqual(ln["h"], 117)  # (130 + 2) - 18

    def test_ink_outside_region_not_pulled_in(self):
        # 区域只盖下半段：顶部墨迹在区域阅读轴范围外，不吸入；行框也
        # 绝不会被缩小。
        mask = np.zeros((200, 60), dtype=np.uint8)
        mask[20:45, 26:34] = 255
        result = {"lines": [self._line(27, 95, 8, 40)]}
        out = extend_lines_to_region_ink(
            result, (10, 60, 50, 50), mask, "vertical",
        )
        self.assertEqual((out["lines"][0]["y"], out["lines"][0]["h"]), (95, 40))

    def test_line_outside_region_band_untouched(self):
        # 行带与区域无交集（邻列）→ 原样。
        mask = np.zeros((200, 60), dtype=np.uint8)
        mask[20:45, 26:34] = 255
        result = {"lines": [self._line(27, 95, 8, 40)]}
        out = extend_lines_to_region_ink(
            result, (40, 10, 20, 180), mask, "vertical",
        )
        self.assertEqual((out["lines"][0]["y"], out["lines"][0]["h"]), (95, 40))

    def test_horizontal_mirror(self):
        # 横排：阅读轴为 X，行框沿 X 扩到区域内墨迹，行带（y）不变。
        mask = np.zeros((60, 200), dtype=np.uint8)
        mask[26:34, 20:45] = 255
        mask[25:35, 100:130] = 255
        result = {"lines": [self._line(95, 27, 40, 8)]}
        out = extend_lines_to_region_ink(
            result, (10, 10, 180, 50), mask, "horizontal",
        )
        ln = out["lines"][0]
        self.assertEqual(ln["x"], 18)
        self.assertEqual(ln["w"], 117)

    def test_mask_none_noop(self):
        result = {"lines": [self._line(27, 95, 8, 40)]}
        out = extend_lines_to_region_ink(
            result, (10, 10, 50, 180), None, "vertical",
        )
        self.assertEqual(out["lines"][0]["h"], 40)






class EdgeFillerAndClampTests(unittest.TestCase):
    """裁切填充带剔除 + 识别框钳回图片范围。"""

    def test_zero_edge_filler_bands_removes_solid_dark_bands(self):
        # 白底 + 两列文字 + 左侧 30px / 底部 40px 纯黑填充带（裁切产物）
        img = np.full((400, 300), 220, dtype=np.uint8)
        img[:, :30] = 5
        img[360:, :] = 5
        img[60:140, 80:130] = 30   # 文字列 1
        img[200:280, 180:230] = 30  # 文字列 2
        mask = np.ones_like(img)
        out = _zero_edge_filler_bands(img, mask)
        # 填充带清零，内容墨迹保留
        self.assertEqual(int(out[:, :30].sum()), 0)
        self.assertEqual(int(out[360:, :].sum()), 0)
        self.assertGreater(int(out[60:140, 80:130].sum()), 0)
        self.assertGreater(int(out[200:280, 180:230].sum()), 0)

    def test_zero_edge_filler_bands_skips_dark_background_pages(self):
        # 整页暗底（阴文/夜间模式）：极性翻转负责，不做填充带剔除
        img = np.full((300, 300), 20, dtype=np.uint8)
        img[100:200, 100:200] = 230  # 白字
        mask = np.ones_like(img)
        out = _zero_edge_filler_bands(img, mask)
        self.assertEqual(int(out.sum()), mask.sum())

    def test_mask_keeps_content_with_filler_bands(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "page.png"
            img = np.full((400, 300, 3), 220, dtype=np.uint8)
            img[:, :30] = 5
            img[360:, :] = 5
            for y0 in range(60, 340, 60):
                img[y0:y0 + 40, 80:130] = 20
                img[y0:y0 + 40, 180:230] = 20
            cv2.imwrite(str(image_path), img)
            mask = _text_mask_for_refinement(str(image_path))
            self.assertEqual(int(mask[:, :30].sum()), 0)
            self.assertEqual(int(mask[360:, :].sum()), 0)
            self.assertGreater(int(mask[:, 80:130].sum()), 0)

    def test_clamp_result_to_image_bounds(self):
        result = {
            "lines": [
                {"id": "a", "x": -10, "y": 5, "w": 40, "h": 30,
                 "chars": [{"id": "c0", "x": -5, "y": 6, "w": 10, "h": 10}]},
                {"id": "b", "x": 95, "y": 90, "w": 20, "h": 20, "chars": []},
            ],
            "main_regions": [
                {"id": "mr_001", "x": 0, "y": 0, "w": 1342, "h": 2157,
                 "label": "main_text"},
            ],
            "paragraphs": [
                {"id": "mp_001", "x": 90, "y": 90, "w": 300, "h": 200},
            ],
        }
        out = _clamp_result_to_image(result, 100, 100)
        a = out["lines"][0]
        self.assertEqual((a["x"], a["y"], a["w"], a["h"]), (0, 5, 30, 30))
        self.assertEqual(
            (a["chars"][0]["x"], a["chars"][0]["w"]), (0, 5)
        )
        b = out["lines"][1]
        self.assertEqual((b["x"], b["y"], b["w"], b["h"]), (95, 90, 5, 10))
        # 区域检测模型预测出图外的主区/段落：钳回图片范围
        mr = out["main_regions"][0]
        self.assertEqual((mr["x"], mr["y"], mr["w"], mr["h"]), (0, 0, 100, 100))
        pg = out["paragraphs"][0]
        self.assertEqual((pg["x"], pg["y"], pg["w"], pg["h"]), (90, 90, 10, 10))
        # 图片尺寸随响应带回（前端 inferHierarchy 主区钳制依赖）
        self.assertEqual(out["image_width"], 100)
        self.assertEqual(out["image_height"], 100)
