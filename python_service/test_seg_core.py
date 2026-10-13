# -*- coding: utf-8 -*-
"""切分核心几何与 Kraken 切分器测试（从 test_segmenter 拆出）。"""
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
    _split_by_equal_division,
    _split_by_layout_grid,
    _split_chars_in_region,
    _split_chars_by_y_projection,
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





class SegmenterGeometryTests(unittest.TestCase):
    def test_vertical_line_expands_for_small_punctuation_below(self):
        mask = np.zeros((180, 80), dtype=np.uint8)
        # 主体字高度约 40px，行框恰好包到主体字底部。
        cv2.rectangle(mask, (20, 10), (55, 48), 255, -1)
        # 竖排句号/逗号落在字下方，不能被行框漏掉。
        cv2.circle(mask, (37, 63), 4, 255, -1)
        expanded = _expand_rect_for_punctuation(
            (15, 5, 45, 45), mask, 80, 180, "vertical"
        )
        self.assertGreater(expanded[3], 45)
        self.assertGreaterEqual(expanded[1] + expanded[3], 68)

    def test_vertical_line_without_punctuation_keeps_geometry(self):
        mask = np.zeros((180, 80), dtype=np.uint8)
        cv2.rectangle(mask, (20, 10), (55, 48), 255, -1)
        self.assertEqual(
            (15, 5, 45, 45),
            _expand_rect_for_punctuation((15, 5, 45, 45), mask, 80, 180, "vertical"),
        )

    def test_horizontal_line_expands_for_punctuation_on_right(self):
        mask = np.zeros((80, 180), dtype=np.uint8)
        cv2.rectangle(mask, (10, 20), (48, 55), 255, -1)
        cv2.circle(mask, (63, 37), 4, 255, -1)
        expanded = _expand_rect_for_punctuation(
            (5, 15, 45, 45), mask, 180, 80, "horizontal"
        )
        self.assertGreater(expanded[2], 45)
        self.assertGreaterEqual(expanded[0] + expanded[2], 68)

    def test_char_candidates_from_classifier_only(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "char.png"
            cv2.imwrite(str(image_path), np.full((48, 48, 3), 255, dtype=np.uint8))
            with patch("seg_candidates._char_cls_candidates", return_value=[
                {"text": "星", "score": 0.9},
                {"text": "星", "score": 0.5},   # 同字去重保留最高分
                {"text": "m", "score": 0.99},   # ASCII 噪声剔除
                {"text": "臨", "score": 0.4},
            ]):
                result = get_char_candidates(str(image_path), (0, 0, 48, 48), top_k=5)
            self.assertEqual([c["text"] for c in result], ["星", "臨"])
            self.assertAlmostEqual(result[0]["score"], 0.9)

    def test_char_candidates_empty_without_classifier(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "char.png"
            cv2.imwrite(str(image_path), np.full((48, 48, 3), 255, dtype=np.uint8))
            with patch("seg_candidates._char_cls_candidates", return_value=[]):
                self.assertEqual(
                    get_char_candidates(str(image_path), (0, 0, 48, 48)), []
                )

    def test_main_text_only_filters_chars_and_lines(self):
        result = {
            "lines": [
                {"id": "body", "x": 0, "y": 0, "w": 100, "h": 100,
                 "chars": [{"x": 10, "y": 10, "w": 20, "h": 20, "text": "甲"},
                           {"x": 300, "y": 10, "w": 20, "h": 20, "text": "注"}]},
                {"id": "outside", "x": 300, "y": 0, "w": 80, "h": 100, "chars": []},
            ],
            "blocks": [],
            "main_regions": [{"x": 0, "y": 0, "w": 100, "h": 100}],
        }
        filtered = _filter_layout(result, "main_text_only")
        self.assertEqual(["body"], [line["id"] for line in filtered["lines"]])
        self.assertEqual(["甲"], [char["text"] for char in filtered["blocks"]])
        self.assertTrue(filtered["layout_filter"]["applied"])

    def test_main_text_only_excludes_header_footer_page_number_regions(self):
        # 排除类区不再是包含边界：落在页眉/页脚/页码区里的行被过滤，
        # 即使页面存在已识别区域（旧行为会把它们当正文边界放行）。
        result = {
            "lines": [
                {"id": "body", "x": 10, "y": 50, "w": 20, "h": 20,
                 "chars": [{"x": 10, "y": 50, "w": 20, "h": 20, "text": "正"}]},
                {"id": "header", "x": 10, "y": 2, "w": 20, "h": 10,
                 "chars": [{"x": 10, "y": 2, "w": 20, "h": 10, "text": "眉"}]},
                {"id": "pageno", "x": 10, "y": 190, "w": 20, "h": 8,
                 "chars": [{"x": 10, "y": 190, "w": 20, "h": 8, "text": "一"}]},
            ],
            "blocks": [],
            "main_regions": [
                {"x": 0, "y": 40, "w": 200, "h": 140, "label": "main_text"},
                {"x": 0, "y": 0, "w": 200, "h": 20, "label": "header"},
                {"x": 0, "y": 185, "w": 200, "h": 15, "label": "page_number"},
            ],
        }
        filtered = _filter_layout(result, "main_text_only")
        self.assertEqual(["body"], [line["id"] for line in filtered["lines"]])
        self.assertEqual(["正"], [c["text"] for c in filtered["blocks"]])
        self.assertEqual(filtered["layout_filter"]["excluded_regions"], 2)

    def test_main_text_only_keeps_margin_note_as_annotation(self):
        # 眉批区是正文宿主：行保留，但字打 annotation、行打夹注角色。
        result = {
            "lines": [
                {"id": "body", "x": 10, "y": 60, "w": 20, "h": 20,
                 "chars": [{"x": 10, "y": 60, "w": 20, "h": 20, "text": "正"}]},
                {"id": "note", "x": 10, "y": 5, "w": 20, "h": 10,
                 "chars": [{"x": 10, "y": 5, "w": 20, "h": 10, "text": "批"}]},
            ],
            "blocks": [],
            "main_regions": [
                {"x": 0, "y": 50, "w": 200, "h": 140, "label": "main_text"},
                {"x": 0, "y": 0, "w": 200, "h": 20, "label": "margin_note"},
            ],
        }
        filtered = _filter_layout(result, "main_text_only")
        self.assertEqual(["body", "note"],
                         [line["id"] for line in filtered["lines"]])
        by_id = {c["text"]: c for c in filtered["blocks"]}
        self.assertEqual(by_id["正"]["type"], "main_text")
        self.assertEqual(by_id["批"]["type"], "annotation")
        note_line = [l for l in filtered["lines"] if l["id"] == "note"][0]
        self.assertEqual(note_line["layout_role"], "annotation")

    def test_region_overlap_conflicts_flagged_for_all_layout_modes(self):
        # main_text 区咬进页眉区 >30% → 冲突标记；all_text 模式也照标（只
        # 标记不裁决）；互不重叠时不产生字段。
        def _result(overlap: bool) -> dict:
            # overlap=True：页眉框咬进正文区（交集=页眉框的 100%）；
            # overlap=False：两区完全分离（页眉挪到正文下方之外）
            header_y, header_h = (0, 40) if overlap else (310, 40)
            return {
                "lines": [], "blocks": [],
                "main_regions": [
                    {"id": "mr_body", "x": 0, "y": 0, "w": 300, "h": 300,
                     "label": "main_text"},
                    {"id": "mr_head", "x": 0, "y": header_y, "w": 200,
                     "h": header_h, "label": "header"},
                ],
            }

        conflicting = _result(True)
        _filter_layout(conflicting, "all_text")
        self.assertEqual(
            conflicting["region_conflicts"],
            [{"main_region_id": "mr_body", "other_region_id": "mr_head",
              "label": "header", "overlap": 1.0}],
        )
        # 同样的冲突在 main_text_only 下也保留
        conflicting2 = _result(True)
        _filter_layout(conflicting2, "main_text_only")
        self.assertEqual(len(conflicting2["region_conflicts"]), 1)
        clean = _result(False)
        _filter_layout(clean, "all_text")
        self.assertNotIn("region_conflicts", clean)

    def test_enforce_hierarchy_ignores_excluded_regions_as_host(self):
        # header 区不是钳制宿主：落在 header 区内的行不被钳进 header 框；
        # main_text 区照常钳制越界行。
        result = {
            "main_regions": [
                {"id": "mr_b", "x": 0, "y": 50, "w": 100, "h": 100,
                 "label": "main_text"},
                {"id": "mr_h", "x": 0, "y": 0, "w": 100, "h": 20,
                 "label": "header"},
            ],
            "paragraphs": [],
            "lines": [
                # 中心在 main_text 区内但行框越出下边界 10px → 钳回
                {"id": "l1", "x": 10, "y": 40, "w": 20, "h": 120, "chars": []},
                # 完全在 header 区内的行 → 不动（header 不是宿主）
                {"id": "l2", "x": 10, "y": 2, "w": 20, "h": 30, "chars": []},
            ],
        }
        _enforce_hierarchy_containment(result)
        lines = {l["id"]: l for l in result["lines"]}
        self.assertEqual(lines["l1"]["y"] + lines["l1"]["h"], 150)
        self.assertEqual((lines["l2"]["y"], lines["l2"]["h"]), (2, 30))

    def test_region_segmentation_keeps_full_image_geometry(self):
        # Region reruns must use the original image; crop-based inference changes
        # scale and produces different line box dimensions for narrow paragraphs.
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "page.png"
            cv2.imwrite(str(image_path), np.zeros((100, 100), dtype=np.uint8))
            source_line = {
                "id": "l0", "x": 10, "y": 20, "w": 12, "h": 70,
                "orientation": "vertical", "chars": [
                    {"id": "c0", "x": 10, "y": 20, "w": 12, "h": 20, "text": "甲"},
                    {"id": "c1", "x": 10, "y": 45, "w": 12, "h": 20, "text": "乙"},
                ],
            }
            outside = {"id": "l1", "x": 70, "y": 20, "w": 12, "h": 70,
                       "orientation": "vertical", "chars": []}
            def fake_segment(path, **kwargs):
                self.assertEqual(str(image_path), path)
                return {"engine": "test", "lines": [source_line, outside]}
            with patch("seg_pipeline.segment_image_with_metadata", side_effect=fake_segment):
                result = segment_lines_in_region(str(image_path), (0, 0, 40, 100))
            self.assertEqual(["l0"], [line["id"] for line in result["lines"]])
            self.assertEqual((10, 20, 12, 70), tuple(result["lines"][0][k] for k in ("x", "y", "w", "h")))
            self.assertEqual("image", result["coordinate_space"])

    def test_status_and_uid_are_compatible_and_deterministic(self):
        self.assertEqual("confirmed", normalize_status("reviewed"))
        self.assertEqual("confirmed", normalize_status("proposed", confirmed=True))
        a = stable_uid("abc", "char", (1, 2, 3, 4), order=2, parent_uid="line")
        self.assertEqual(a, stable_uid("abc", "char", (1, 2, 3, 4), order=2, parent_uid="line"))
        self.assertNotEqual(a, stable_uid("abc", "char", (1, 2, 3, 4), order=3, parent_uid="line"))
    def test_text_mask_flips_polarity_for_white_on_black_page(self):
        """白字黑底（阴文页/暗底扫描）时 OTSU 把"墨"切到背景一侧；
        极性自检发现墨占比过半即翻转，转为识别白色文字。"""
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "white_on_black.png"
            img = np.full((200, 100, 3), 30, dtype=np.uint8)
            for top in (20, 70, 120):
                cv2.rectangle(img, (30, top), (70, top + 38), (240, 240, 240), -1)
            cv2.imwrite(str(image_path), img)
            mask = _text_mask_for_refinement(str(image_path))
            self.assertIsNotNone(mask)
            # 翻转后"墨"回到少数（白字成为墨），而不是整页背景
            frac = np.count_nonzero(mask) / mask.size
            self.assertLess(frac, 0.45, frac)
            for top in (20, 70, 120):
                self.assertGreater(
                    np.count_nonzero(mask[top + 5:top + 33, 35:65]), 300
                )
            info = mask_polarity_info(str(image_path))
            self.assertTrue(info.get("flipped"))
            self.assertGreater(info.get("ink_fraction_before", 0.0), 0.55)

    def test_text_mask_keeps_polarity_for_normal_page(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "normal.png"
            img = np.full((200, 100, 3), 235, dtype=np.uint8)
            for top in (20, 70, 120):
                cv2.rectangle(img, (30, top), (70, top + 38), (20, 20, 20), -1)
            cv2.imwrite(str(image_path), img)
            mask = _text_mask_for_refinement(str(image_path))
            self.assertIsNotNone(mask)
            frac = np.count_nonzero(mask) / mask.size
            self.assertLess(frac, 0.45, frac)
            for top in (20, 70, 120):
                self.assertGreater(
                    np.count_nonzero(mask[top + 5:top + 33, 35:65]), 300
                )
            self.assertFalse(mask_polarity_info(str(image_path)).get("flipped", True))

    def test_region_filter_keeps_whole_lines(self):
        """区域重识别保留整行：行外扩成整列后，按区域矩形裁字会把
        区域外的字裁掉（重识别后"文字照不全"）。"""
        result = {
            "lines": [
                {"id": "l0", "x": 10, "y": 20, "w": 12, "h": 70,
                 "orientation": "vertical", "chars": [
                     {"id": "c0", "x": 10, "y": 20, "w": 12, "h": 20, "text": "甲"},  # 中心在区域内
                     {"id": "c1", "x": 10, "y": 45, "w": 12, "h": 20, "text": "乙"},  # 中心在区域外
                 ]},
                {"id": "l1", "x": 70, "y": 20, "w": 12, "h": 70, "chars": []},
            ],
            "blocks": [],
        }
        filtered = filter_result_to_region(result, (0, 0, 40, 40))
        self.assertEqual(["l0"], [line["id"] for line in filtered["lines"]])
        # 整行保留：区域外的字不再被裁掉
        self.assertEqual(
            [c["text"] for c in filtered["lines"][0]["chars"]], ["甲", "乙"]
        )
        self.assertEqual(2, len(filtered["blocks"]))

    def test_expected_count_prefers_line_ocr_when_geometry_conflicts(self):
        count, source, _ = _choose_expected_count((0, 0, 40, 500), 9)
        self.assertEqual(count, 9)
        self.assertIn(source, {"ocr-compatible", "ocr-conflict"})

    def test_guided_vertical_grid_keeps_each_glyph_in_its_slot(self):
        mask = np.zeros((500, 80), dtype=np.uint8)
        for index in range(10):
            y = 8 + index * 49
            cv2.rectangle(mask, (20, y), (60, y + 35), 255, -1)
        rects = _split_by_layout_grid(mask, (10, 0, 60, 500), 10, 80, 500)
        self.assertEqual(len(rects), 10)
        self.assertTrue(all(rect[2] < 60 for rect in rects))
        self.assertTrue(all(rect[3] <= 45 for rect in rects))

    def test_projection_mismatch_falls_back_to_grid_without_sliver_boxes(self):
        # 粘连块投影 runs 因字距过近合并成 2 段、与期望 5 字不符时，
        # 走白隙引导的版面网格而非盲等分：切线落在字间空隙上，
        # 不再产出"一个点"的碎片字框（如戎/人之间只剩笔画尾巴的槽）。
        mask = np.zeros((500, 200), dtype=np.uint8)
        spans = [(10, 88), (98, 176), (186, 264), (305, 383), (393, 460)]
        for y1, y2 in spans:
            cv2.rectangle(mask, (10, y1), (86, y2), 255, -1)
        rects = _split_chars_by_y_projection(
            mask, (0, 0, 96, 470), 200, 500, char_size=90, expected_count=5
        )
        self.assertEqual(len(rects), 5)
        # 不允许点状伪字框：每个框都接近整字高度
        self.assertTrue(all(rect[3] >= 60 for rect in rects))
        # 每个字的中心行恰好落进一个框（不丢字、不重复）
        for y1, y2 in spans:
            center = (y1 + y2) // 2
            hits = sum(1 for rx, ry, rw, rh in rects if ry <= center < ry + rh)
            self.assertEqual(1, hits, f"字中心 y={center} 命中 {hits} 个框")

    def test_equal_division_sliver_slot_falls_back_to_full_segment(self):
        # 等分切线落进字间空隙、槽内只剩邻字笔画尾巴（本例高约 17px）时，
        # 收紧框是一个点；应退回整槽框，保证字框可见、与槽位对齐。
        mask = np.zeros((300, 200), dtype=np.uint8)
        cv2.rectangle(mask, (10, 5), (86, 103), 255, -1)  # 字1 尾巴伸到 y=103
        cv2.rectangle(mask, (10, 185), (86, 262), 255, -1)  # 字3
        rects = _split_by_equal_division(mask, (0, 0, 96, 270), 3, 200, 300)
        self.assertEqual(len(rects), 3)
        self.assertGreaterEqual(rects[1][3], 60)

    def test_cross_column_border_band_is_dropped_from_component_boxes(self):
        # 残缺版框横线横穿整页（含列间纸白缝），行框扩展把它捞进列尾：
        # 组件切分必须把它当噪声丢弃——否则它以独立组件身份混成
        # "一个点"伪字框，还多计一个字把期望校验顶翻（实测 24≠23）。
        mask = np.zeros((600, 300), dtype=np.uint8)
        for y1, y2 in [(20, 100), (120, 200), (220, 300), (320, 400)]:
            cv2.rectangle(mask, (110, y1), (150, y2), 255, -1)
        cv2.rectangle(mask, (0, 420), (299, 426), 255, -1)  # 横贯全页的版框带
        rects = _split_chars_in_region(mask, (100, 0, 62, 440), 300, 600, expected_count=4)
        self.assertEqual(len(rects), 4)
        self.assertTrue(all(r[3] >= 60 for r in rects))
        self.assertTrue(all(r[1] + r[3] <= 412 for r in rects))

    def test_ruling_strip_line_not_split_into_micro_slots(self):
        # 栏线/版框残带被检测成"文字列"（用户实测：region=(383,0,126,2163)、
        # 整行读法 0 字、行里只剩一条实心带 + 4px 残条）：4px 残条不该当
        # 单字高参考（unit_h 被拉到 4 → 粘连块期望 140、格长 4px），实心
        # 带投影只得 1 段且行墨量均匀 → 按一个结构元素出框（残条高度
        # 不足 _tight_rect 下限自然丢弃）。整行结果 = 1 个贴住整条墨迹的
        # 带框，而不是 538 个 4px 微框全叠在行图上。
        mask = np.zeros((500, 100), dtype=np.uint8)
        cv2.rectangle(mask, (35, 10), (65, 450), 255, -1)   # 实心栏线带
        cv2.rectangle(mask, (10, 480), (90, 484), 255, -1)  # 4px 高的扁残条
        rects = _split_chars_in_region(mask, (5, 0, 90, 500), 100, 500, expected_count=0)
        self.assertEqual(len(rects), 1)
        # 带框贴住整条墨迹（不是被网格切碎的微格）
        self.assertGreaterEqual(rects[0][3], 400)

    def test_absurd_expected_count_keeps_component_boxes(self):
        # 期望字数对区域高荒谬（上一轮已切出 537 个微框的行带着旧字数
        # 进诊断/重识别）：等分只会再造一批 4px 微格——保留连通域框。
        mask = np.zeros((500, 100), dtype=np.uint8)
        cv2.rectangle(mask, (35, 10), (65, 450), 255, -1)
        cv2.rectangle(mask, (10, 480), (90, 484), 255, -1)
        rects = _split_chars_in_region(
            mask, (5, 0, 90, 500), 100, 500, expected_count=300,
        )
        self.assertEqual(len(rects), 1)
        self.assertGreaterEqual(rects[0][3], 400)

    def test_fused_text_run_with_valley_still_recovers_by_grid(self):
        # 回归保护：投影并段后的真·多字粘连（段内有字距浅谷，行墨量
        # 不均匀）不受实心带判据影响，照旧按期望走网格兜底恢复成两框。
        mask = np.zeros((200, 100), dtype=np.uint8)
        cv2.rectangle(mask, (30, 20), (60, 80), 255, -1)    # 字1
        cv2.rectangle(mask, (30, 100), (60, 160), 255, -1)  # 字2（缝 20px 被并段）
        rects = _split_chars_by_y_projection(
            mask, (30, 20, 31, 140), 100, 200, char_size=60, expected_count=2,
        )
        self.assertEqual(len(rects), 2)
        self.assertTrue(all(r[3] >= 35 for r in rects))

    def test_wide_stroke_char_inside_column_is_kept(self):
        # 横画类字（一）矮而宽，但墨迹停在列界内（不越进纸白缝），
        # 不得被版框带过滤误杀——『一』（54px 宽、12px 高）照常成框。
        mask = np.zeros((600, 300), dtype=np.uint8)
        for y1, y2 in [(20, 100), (120, 200), (220, 300)]:
            cv2.rectangle(mask, (110, y1), (150, y2), 255, -1)
        cv2.rectangle(mask, (104, 330), (158, 342), 255, -1)  # 『一』
        rects = _split_chars_in_region(mask, (100, 0, 62, 360), 300, 600, expected_count=4)
        self.assertEqual(len(rects), 4)
        self.assertTrue(any(325 <= r[1] <= 345 for r in rects))

    def test_punct_split_drops_cross_column_band_piece(self):
        # cuts 管线：末格"人+版框带"拆开后，版框带小框（横贯列宽、越出
        # 列界）必须被丢弃，只留人字框——不再产出 9px 高伪字框。
        mask = np.zeros((600, 300), dtype=np.uint8)
        boxes = [
            (100, 10, 62, 90), (100, 110, 62, 90), (100, 210, 62, 90),
            (100, 310, 62, 130),
        ]
        for y in (15, 115, 215):
            cv2.rectangle(mask, (110, y), (150, y + 80), 255, -1)
        cv2.rectangle(mask, (110, 315), (150, 400), 255, -1)  # 人
        cv2.rectangle(mask, (0, 415), (299, 421), 255, -1)  # 横贯全页的版框带
        new_boxes, events = split_punct_merged_boxes(boxes, mask, 300, 600)
        self.assertEqual(len(new_boxes), 4)
        self.assertTrue(all(b[3] >= 60 for b in new_boxes))
        self.assertTrue(all(b[1] + b[3] <= 412 for b in new_boxes))

    def test_horizontal_grid_is_supported(self):
        mask = np.zeros((80, 500), dtype=np.uint8)
        for index in range(10):
            x = 8 + index * 49
            cv2.rectangle(mask, (x, 20), (x + 35, 60), 255, -1)
        rects = _split_chars_in_region(mask, (0, 10, 500, 60), 500, 80, 10)
        self.assertEqual(len(rects), 10)
        self.assertTrue(all(rect[2] <= 45 for rect in rects))
