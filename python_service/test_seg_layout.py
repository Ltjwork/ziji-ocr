# -*- coding: utf-8 -*-
"""版面相关测试（从 test_segmenter 拆出）：横排版式、摆正坐标映射、双栏拆分、层级包含。"""
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





class HorizontalLayoutTests(unittest.TestCase):
    """横排（orientation="horizontal"）：条带投影/字框归组/OpenCV 兜底
    都按水平行切分，行 orientation 取用户声明值。"""

    @staticmethod
    def _write_page(path, width, height, blobs):
        img = np.full((height, width, 3), 255, dtype=np.uint8)
        for x1, y1, x2, y2 in blobs:
            cv2.rectangle(img, (x1, y1), (x2, y2), (0, 0, 0), -1)
        cv2.imwrite(str(path), img)

    @staticmethod
    def _horizontal_body_blobs(rows=3, chars=10):
        # 竖排 _body_blobs 的转置版：3 条水平行、行内 10 字、字间有隙。
        blobs = []
        for ri in range(rows):
            ry = 300 - ri * 100
            for i in range(chars):
                x = 20 + i * 40 + (i % 2)
                jy = (i * 3) % 7 - 3
                jw = 22 + (i % 4) * 2
                jh = 24 + (i % 3) * 3
                blobs.append((x, ry + jy, x + jw, ry + jy + jh))
        return blobs

    def test_horizontal_strips_cut_rows(self):
        # 横排条带 = 水平行：3 条条带的 y 落在 3 条文字行的 y 附近。
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "page.png"
            self._write_page(image_path, 400, 640, self._horizontal_body_blobs())
            strips = _vertical_line_strips(str(image_path), 400, 640, orientation="horizontal")
            self.assertEqual(len(strips), 3, strips)
            strip_ys = sorted(sy for sy, _sh in strips)
            for expected_y, got_y in zip((100, 200, 300), strip_ys):
                self.assertTrue(abs(got_y - expected_y) <= 10, strips)

    def test_horizontal_grouping_by_rows(self):
        # 横排归组：字框按中心 y 归入所在行，行间不串。
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "page.png"
            self._write_page(image_path, 400, 640, self._horizontal_body_blobs())
            char_rects = [
                (x, 300 + (i * 3) % 7 - 3, 24, 26)
                for i, x in enumerate(range(24, 400, 40))
            ]
            char_rects.append((24, 104, 24, 26))  # 最下一行（y≈100）的字
            grouped = _group_yolo_char_rects_into_lines(
                char_rects, 400, 640,
                image_path=str(image_path), orientation="horizontal",
            )
            # 3 条行条带：y≈100（1 字）、y≈200（无字 → 墨迹紧致行框）、
            # y≈300（10 字）。无字条带构造出的是横向紧致框（宽 >> 高）。
            groups_by_row = sorted(grouped, key=lambda g: g[0][1])
            self.assertEqual(len(groups_by_row), 3, grouped)
            self.assertEqual(len(groups_by_row[0]), 1, grouped)
            self.assertEqual(len(groups_by_row[2]), 10, grouped)
            self.assertEqual(len(groups_by_row[1]), 1, grouped)
            self.assertGreater(groups_by_row[1][0][2], groups_by_row[1][0][3] * 5, grouped)

    def test_opencv_horizontal_cuts_rows(self):
        # OpenCV 兜底横排：行框宽 > 高、行 orientation 取声明值。
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "page.png"
            self._write_page(image_path, 400, 640, self._horizontal_body_blobs())
            lines, blocks = _segment_with_opencv(
                str(image_path), orientation="horizontal",
            )
            self.assertEqual(len(lines), 3, lines)
            for line in lines:
                self.assertEqual(line["orientation"], "horizontal", line)
                self.assertGreater(line["w"], line["h"] * 2, line)
            self.assertGreater(len(blocks), 20, blocks)




class TransformPageMappingTests(unittest.TestCase):
    """页面旋转/镜像：后端像素映射（cv2）与编辑器矩形换算公式逐点一致
    （/transform_page 改像素、PageAnnotation.transformGeometry 改标注，
    两侧映射不同步框就错位）。"""

    def _dark_bbox(self, img):
        dark = np.argwhere(img.max(axis=2) < 128)
        return (
            dark[:, 1].min(), dark[:, 0].min(),   # x, y
            dark[:, 1].max() - dark[:, 1].min() + 1,
            dark[:, 0].max() - dark[:, 0].min() + 1,
        )

    def _image_with_rect(self, w, h, rx, ry, rw, rh):
        img = np.full((h, w, 3), 255, dtype=np.uint8)
        img[ry:ry + rh, rx:rx + rw] = 0
        return img

    def test_rotate_cw(self):
        img = self._image_with_rect(120, 80, 30, 40, 20, 10)
        out = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
        # Dart 公式：(newW-(y+h), x, h, w)，newW=旧高
        self.assertEqual(self._dark_bbox(out), (80 - 50, 30, 10, 20))

    def test_rotate_ccw(self):
        img = self._image_with_rect(120, 80, 30, 40, 20, 10)
        out = cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)
        # Dart 公式：(y, newH-(x+w), h, w)，newH=旧宽
        self.assertEqual(self._dark_bbox(out), (40, 120 - 50, 10, 20))

    def test_flip_h(self):
        img = self._image_with_rect(120, 80, 30, 40, 20, 10)
        out = cv2.flip(img, 1)
        # Dart 公式：(newW-(x+w), y, w, h)
        self.assertEqual(self._dark_bbox(out), (120 - 50, 40, 20, 10))

    def test_flip_v(self):
        img = self._image_with_rect(120, 80, 30, 40, 20, 10)
        out = cv2.flip(img, 0)
        # Dart 公式：(x, newH-(y+h), w, h)
        self.assertEqual(self._dark_bbox(out), (30, 80 - 50, 20, 10))




class DoubleColumnSplitTests(unittest.TestCase):
    """并排子列（夹注/旁注）行拆分：检测、行级拆分与排序保持。"""

    @staticmethod
    def _write_image(path, width, height, blobs, solid_blobs=()):
        # 描边而非实心：实心块在窄幅测试图上墨量过半，会触发
        # _text_mask_for_refinement 的极性自检把整图反转
        img = np.full((height, width, 3), 255, dtype=np.uint8)
        for x1, y1, x2, y2 in blobs:
            cv2.rectangle(img, (x1, y1), (x2, y2), (0, 0, 0), 3)
        for x1, y1, x2, y2 in solid_blobs:
            cv2.rectangle(img, (x1, y1), (x2, y2), (0, 0, 0), -1)
        cv2.imwrite(str(path), img)

    @staticmethod
    def _sample_layout_blobs():
        """通栏上段 2 字 + 下方左右子列各 4 字（子列字比正文小，列间留
        白 15px）。返回 (描边块, 实心块)。

        通栏字里各加一枚跨缝实心小方块：通栏描边框的横向长边（90px）
        会被 _remove_ruling_lines 当界栏删掉，跨缝桥接墨迹须短于栏线阈
        值且实体过缝（描边框的左右边缘恰在缝隙带外，只剩上下边 3 行算
        不出桥）。子列字高（45）须明显小于通栏字高（85）——拆分判据要
        求夹注字小于正文。"""
        blobs = [
            # 通栏上段：两字横跨整宽（含子列间空隙）
            (15, 10, 105, 90),
            (15, 110, 105, 190),
        ]
        solid = [
            (50, 30, 70, 66),
            (50, 130, 70, 166),
        ]
        for i in range(4):
            top = 210 + i * 70
            blobs.append((10, top, 50, top + 45))   # 左子列（小字）
            blobs.append((70, top, 110, top + 45))  # 右子列（小字）
        return blobs, solid

    def test_sub_rects_splits_head_and_two_sub_columns(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs, solid = self._sample_layout_blobs()
            self._write_image(image_path, 120, 600, blobs, solid)
            mask = _text_mask_for_refinement(str(image_path))
            subs = _double_column_sub_rects((0, 0, 120, 600), mask)
            self.assertEqual(len(subs), 3, subs)
            head, right, left = subs
            # 阅读序：通栏上段 → 右子列 → 左子列（竖排 rtl）
            self.assertLess(head[1], right[1])
            self.assertLess(head[1], left[1])
            self.assertTrue(right[0] > left[0], subs)
            self.assertAlmostEqual(right[1], left[1], delta=8)
            # 上段横向覆盖整宽，子列各占一侧
            self.assertGreater(head[2], right[2] + left[2])

    def test_sub_rects_pure_double_column_without_head(self):
        # 纯双列、上方无通栏字：缺"通栏桥接"证据，不拆——条带投影本就
        # 会把这种两条窄列切成两个条带；行内拆分只处理"通栏段下方并排
        # 双列"的结构，避免对无桥接证据的并排墨迹误判。
        blobs = []
        for i in range(5):
            top = 10 + i * 90
            blobs.append((10, top, 50, top + 70))
            blobs.append((62, top, 102, top + 70))
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            self._write_image(image_path, 112, 470, blobs)
            mask = _text_mask_for_refinement(str(image_path))
            subs = _double_column_sub_rects((0, 0, 112, 470), mask)
            self.assertEqual(len(subs), 1, subs)

    def test_sub_rects_keeps_single_column_intact(self):
        # 单列：字宽窄不一、左右错落，不存在贯穿 ≥2 字高的持久空白带
        blobs = [
            (20, 10, 70, 80),
            (10, 95, 45, 165),
            (35, 180, 75, 250),
            (15, 265, 60, 335),
            (25, 350, 72, 420),
        ]
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            self._write_image(image_path, 90, 440, blobs)
            mask = _text_mask_for_refinement(str(image_path))
            subs = _double_column_sub_rects((0, 0, 90, 440), mask)
            self.assertEqual(len(subs), 1, subs)

    def test_split_lines_orders_head_right_left_and_distributes_chars(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs, solid = self._sample_layout_blobs()
            self._write_image(image_path, 120, 600, blobs, solid)
            mask = _text_mask_for_refinement(str(image_path))
            chars = [
                {"id": f"c{i}", "x": x1, "y": y1, "w": x2 - x1, "h": y2 - y1,
                 "text": "", "candidates": []}
                for i, (x1, y1, x2, y2) in enumerate(blobs)
            ]
            line = {
                "id": "l_7", "x": 0, "y": 0, "w": 120, "h": 600,
                "line_no": 0, "orientation": "vertical", "text": "",
                "chars": list(chars),
            }
            out = split_double_column_lines(
                [line], mask, "vertical", "rtl", "ttb"
            )
            self.assertEqual(len(out), 3)
            self.assertEqual(
                [ln["id"] for ln in out], ["l_7_d0", "l_7_d1", "l_7_d2"]
            )
            head, right, left = out
            # 通栏 2 字框（桥接块是画布墨迹、不建字框）；左右子列各 4 框
            self.assertEqual([len(ln["chars"]) for ln in out], [2, 4, 4])
            # 字框按中心归入拆分行，无丢失无重复
            self.assertEqual(
                sum(len(ln["chars"]) for ln in out), len(chars)
            )
            # 阅读序与编号
            self.assertLess(head["y"], right["y"])
            self.assertGreater(right["x"], left["x"])
            self.assertEqual([ln["line_no"] for ln in out], [0, 1, 2])
            for i, ln in enumerate(out):
                for j, c in enumerate(ln["chars"]):
                    self.assertEqual(c["col"], i)
                    self.assertEqual(c["order"], j)
                    self.assertEqual(c["line_id"], ln["id"])
            # 拆分行带标记：后续行框外扩跳过
            self.assertTrue(all(ln.get("double_col_split") for ln in out))

    def test_split_lines_noop_without_structure(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs = [(20, 10, 70, 80), (22, 100, 72, 170)]
            self._write_image(image_path, 90, 190, blobs)
            mask = _text_mask_for_refinement(str(image_path))
            line = {
                "id": "l_1", "x": 0, "y": 0, "w": 90, "h": 190,
                "line_no": 0, "orientation": "vertical", "text": "",
                "chars": [
                    {"id": "c0", "x": 20, "y": 10, "w": 50, "h": 70},
                    {"id": "c1", "x": 22, "y": 100, "w": 50, "h": 70},
                ],
            }
            out = split_double_column_lines(
                [line], mask, "vertical", "rtl", "ttb"
            )
            self.assertEqual(len(out), 1)
            self.assertIs(out[0], line)

    def test_narrow_spurious_split_collapses_to_parent(self):
        # A detector bleed strip beside a real note column must not become a
        # third child line. The conservative post-filter collapses the split.
        mask = np.zeros((300, 150), dtype=np.uint8)
        for y in range(20, 280, 45):
            cv2.rectangle(mask, (20, y), (80, y + 24), 255, -1)
            cv2.rectangle(mask, (98, y), (130, y + 16), 255, -1)
        subs = [(20, 0, 60, 300), (82, 0, 5, 300), (98, 0, 32, 300)]
        from segmenter import _filter_spurious_double_column_parts
        self.assertEqual(
            len(_filter_spurious_double_column_parts(subs, mask, 'vertical')),
            1,
        )

    def test_two_piece_bleed_split_does_not_create_extra_narrow_column(self):
        # The page-84 failure is often emitted as only two children: a normal
        # body column and a thin neighbouring bleed strip.  It must collapse
        # back to the parent so the body column keeps its full recognition
        # width.  A dense, wider note column remains eligible for splitting.
        mask = np.zeros((300, 150), dtype=np.uint8)
        for y in range(20, 280, 45):
            cv2.rectangle(mask, (20, y), (80, y + 24), 255, -1)
            cv2.rectangle(mask, (88, y), (99, y + 12), 255, -1)
        subs = [(20, 0, 60, 300), (82, 0, 12, 300)]
        from segmenter import _filter_spurious_double_column_parts
        filtered = _filter_spurious_double_column_parts(subs, mask, 'vertical')
        self.assertEqual(len(filtered), 1, filtered)
        self.assertEqual(filtered[0], (20, 0, 74, 300))

    def test_page84_thin_bleed_split_collapses_without_narrowing_main_column(self):
        # Page 84: a 19px strip next to a 66px body column is not a real second
        # column. The post-filter must return the complete wider parent region.
        mask = np.zeros((500, 100), dtype=np.uint8)
        for y in range(20, 480, 70):
            cv2.rectangle(mask, (15, y), (78, y + 36), 255, -1)
            cv2.rectangle(mask, (63, y + 6), (79, y + 28), 255, -1)
        subs = [(10, 0, 66, 500), (57, 0, 19, 500)]
        from segmenter import _filter_spurious_double_column_parts

        filtered = _filter_spurious_double_column_parts(subs, mask, 'vertical')
        self.assertEqual(filtered, [(10, 0, 66, 500)])

    def test_duplicate_fragment_requires_matching_ink_not_only_box_overlap(self):
        from segmenter import drop_duplicate_fragment_lines

        mask = np.zeros((500, 100), dtype=np.uint8)
        fragment_chars = []
        owner_chars = []
        for y in range(10, 410, 50):
            # Adjacent glyph strokes occupy different sides of overlapping
            # boxes. Geometry sees aligned boxes, but ink is independent.
            cv2.rectangle(mask, (42, y), (49, y + 28), 255, -1)
            cv2.rectangle(mask, (50, y), (58, y + 28), 255, -1)
            fragment_chars.append({'x': 42, 'y': y, 'w': 12, 'h': 30})
            owner_chars.append({'x': 49, 'y': y, 'w': 12, 'h': 30})
        fragment = {
            'id': 'fragment', 'x': 42, 'y': 0, 'w': 12, 'h': 420,
            'chars': fragment_chars,
        }
        owner = {
            'id': 'owner', 'x': 49, 'y': 0, 'w': 35, 'h': 420,
            'chars': owner_chars,
        }
        kept, removed = drop_duplicate_fragment_lines([fragment, owner], 'vertical', mask)
        self.assertFalse(removed)
        self.assertEqual([line['id'] for line in kept], ['fragment', 'owner'])

    def test_duplicate_fragment_with_same_ink_is_removed_without_changing_owner(self):
        from segmenter import drop_duplicate_fragment_lines

        mask = np.zeros((500, 100), dtype=np.uint8)
        fragment_chars = []
        owner_chars = []
        for y in range(10, 410, 50):
            cv2.rectangle(mask, (48, y), (56, y + 28), 255, -1)
            fragment_chars.append({'x': 47, 'y': y, 'w': 14, 'h': 30})
            owner_chars.append({'x': 48, 'y': y, 'w': 20, 'h': 30})
        fragment = {
            'id': 'fragment', 'x': 45, 'y': 0, 'w': 18, 'h': 420,
            'chars': fragment_chars,
        }
        owner = {
            'id': 'owner', 'x': 48, 'y': 0, 'w': 35, 'h': 420,
            'chars': owner_chars,
        }
        original_owner_rect = tuple(owner[k] for k in ('x', 'y', 'w', 'h'))
        kept, removed = drop_duplicate_fragment_lines([fragment, owner], 'vertical', mask)
        self.assertEqual([line['id'] for line in removed], ['fragment'])
        self.assertEqual([line['id'] for line in kept], ['owner'])
        self.assertEqual(tuple(kept[0][k] for k in ('x', 'y', 'w', 'h')), original_owner_rect)

    def test_overlapping_adjacent_line_boxes_keep_full_width(self):
        from segmenter import _resolve_overlapping_line_boxes
        boxes = [(60, 0, 55, 280), (100, 0, 45, 280)]
        resolved = _resolve_overlapping_line_boxes(boxes, 'vertical')
        self.assertEqual(len(resolved), 2)
        self.assertEqual(sorted(r[2] for r in resolved), [45, 55])

    def test_narrow_detector_fragment_merges_but_margin_overlap_stays_separate(self):
        fragment_a = {
            "id": "fragment", "x": 745, "y": 0, "w": 23, "h": 640,
            "layout_role": "body", "chars": [{"id": "a"}],
        }
        main_part = {
            "id": "main", "x": 771, "y": 0, "w": 53, "h": 640,
            "layout_role": "body", "chars": [{"id": "b"}],
        }
        merged = _merge_adjacent_line_fragments(
            [fragment_a, main_part], "vertical"
        )
        self.assertEqual(len(merged), 1)
        self.assertEqual((merged[0]["x"], merged[0]["w"]), (745, 79))
        self.assertEqual(len(merged[0]["chars"]), 2)

        # A real neighbouring column with a safety-margin overlap is kept as a
        # separate line; deleting its overlap would make that column too thin.
        overlap_a = dict(fragment_a, id="overlap-a", x=1092, w=147)
        overlap_b = dict(main_part, id="overlap-b", x=1220, w=73)
        kept = _merge_adjacent_line_fragments([overlap_a, overlap_b], "vertical")
        self.assertEqual(len(kept), 2)

        # A zero-width seam is still a detector fragment and should merge;
        # only a true safety-margin overlap (negative gap) is preserved.
        touching_a = dict(fragment_a, id="touch-a", x=500, w=23)
        touching_b = dict(main_part, id="touch-b", x=523, w=53)
        touching = _merge_adjacent_line_fragments(
            [touching_a, touching_b], "vertical"
        )
        self.assertEqual(len(touching), 1)
        self.assertEqual((touching[0]["x"], touching[0]["w"]), (500, 76))

    def test_apply_sort_keeps_head_before_parallel_sub_columns(self):
        lines = [
            {"id": "head", "x": 0, "y": 0, "w": 120, "h": 200, "orientation": "vertical", "chars": []},
            {"id": "right", "x": 65, "y": 210, "w": 45, "h": 380, "orientation": "vertical", "chars": []},
            {"id": "left", "x": 10, "y": 210, "w": 45, "h": 380, "orientation": "vertical", "chars": []},
        ]
        blocks = []
        _apply_sort_and_renumber(lines, blocks, "rtl", "ttb", "vertical")
        self.assertEqual([ln["id"] for ln in lines], ["head", "right", "left"])

        lines_ltr = [
            {"id": "head", "x": 0, "y": 0, "w": 120, "h": 200, "orientation": "vertical", "chars": []},
            {"id": "right", "x": 65, "y": 210, "w": 45, "h": 380, "orientation": "vertical", "chars": []},
            {"id": "left", "x": 10, "y": 210, "w": 45, "h": 380, "orientation": "vertical", "chars": []},
        ]
        _apply_sort_and_renumber(lines_ltr, [], "ltr", "ttb", "vertical")
        self.assertEqual(
            [ln["id"] for ln in lines_ltr], ["head", "left", "right"]
        )

    def test_apply_sort_plain_columns_unchanged(self):
        lines = [
            {"id": "c1", "x": 100, "y": 0, "w": 40, "h": 600, "orientation": "vertical", "chars": []},
            {"id": "c2", "x": 50, "y": 0, "w": 40, "h": 600, "orientation": "vertical", "chars": []},
            {"id": "c3", "x": 0, "y": 0, "w": 40, "h": 600, "orientation": "vertical", "chars": []},
        ]
        _apply_sort_and_renumber(lines, [], "rtl", "ttb", "vertical")
        self.assertEqual([ln["id"] for ln in lines], ["c1", "c2", "c3"])

    def test_region_extend_skips_double_col_split_lines(self):
        # 拆分行框已贴各自子带墨迹：区域墨迹扩展必须跳过，否则上段
        # 通栏框沿阅读轴外扩会吃进下方双列段
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs, solid = self._sample_layout_blobs()
            self._write_image(image_path, 120, 600, blobs, solid)
            mask = _text_mask_for_refinement(str(image_path))
            head = {
                "id": "l_d0", "x": 8, "y": 8, "w": 100, "h": 180,
                "orientation": "vertical", "chars": [],
                "double_col_split": True,
            }
            result = {"lines": [head]}
            extend_lines_to_region_ink(
                result, (0, 0, 120, 600), mask, "vertical"
            )
            self.assertEqual(
                (head["x"], head["y"], head["w"], head["h"]),
                (8, 8, 100, 180),
            )
            # 未标记的行照常外扩（把 head 当普通行时应被撑到双列段）
            head2 = {
                "id": "l_plain", "x": 8, "y": 8, "w": 100, "h": 180,
                "orientation": "vertical", "chars": [],
            }
            result2 = {"lines": [head2]}
            extend_lines_to_region_ink(
                result2, (0, 0, 120, 600), mask, "vertical"
            )
            self.assertGreater(head2["y"] + head2["h"], 188)

    def test_real_sample_fixture_splits_head_and_sub_columns(self):
        """真实古籍样张（通栏"清顯至三公"下并排"次之丙戌人主困|甲癸人
        合恪丁巳人"，88×785 缩略级裁片）：合成图太干净，纸张噪声、栏线
        残留与粘连笔画只有真实样张能压出来。缩略级分辨率下头部大字的
        字带粘连、字距估计失真，检测器**不拆**（低分辨率宁可不拆，正例
        由 765px 木刻页夹具 test_two_tier_short_note_fixture 承担）；
        真实书页（≥765px）上该版式正常拆分。夹具位于 test_fixtures/。"""
        fixture = FsPath(__file__).parent / "test_fixtures" / "jiazhu_double_column.png"
        if not fixture.exists():
            self.skipTest("缺少真实样张夹具")
        mask = _text_mask_for_refinement(str(fixture))
        h, w = mask.shape[:2]
        subs = _double_column_sub_rects((0, 0, w, h), mask)
        self.assertEqual(len(subs), 1, subs)

    def test_two_tier_short_note_fixture(self):
        """真实木刻页夹具（含"媼+姚即|星天"两行短注与"刑傷+刼空傷|
        在內合斷"长注）：整页自动识别（allow_short=False）与单行识别
        （allow_short=True）两类注都拆——两行短注每侧仅两字、整段只有
        ~2.9×根字高，经 _two_char_note_span 按段内小字尺度（实测
        3.2×）放行；阅读序先右列（即天）后左列（姚星）。长注段边界
        外扩到被缝隙墨迹截断的末字（斷/使墨迹至 ~308），不再切进末字、
        不与下段正文行重叠。"""
        fixture = (
            FsPath(__file__).parent / "test_fixtures"
            / "xingnan_shang_annotation_page.png"
        )
        if not fixture.exists():
            self.skipTest("缺少真实样张夹具")
        mask = _text_mask_for_refinement(str(fixture))
        yao_rect = (238, 10, 55, 1216)   # 媼 + 姚即|星天 两行短注列
        xing_rect = (460, 13, 57, 1146)  # 刑傷 + 刼空傷|在內合斷 长注列

        strict_yao = _double_column_sub_rects(yao_rect, mask)
        self.assertEqual(len(strict_yao), 4, strict_yao)
        head, right, left, tail = strict_yao
        # 阅读序：上段 → 右子列（即天）→ 左子列（姚星）→ 下段
        self.assertLess(head[1] + head[3], right[1] + 5)
        self.assertTrue(right[0] > left[0], strict_yao)
        self.assertGreaterEqual(tail[1], right[1] + right[3] - 5)

        # 单行识别与整页识别对该列给出同一拆分（差异只剩 min_seg 主门槛）
        short = _double_column_sub_rects(yao_rect, mask, allow_short=True)
        self.assertEqual(short, strict_yao)

        strict_xing = _double_column_sub_rects(xing_rect, mask)
        self.assertEqual(len(strict_xing), 4, strict_xing)
        self.assertEqual(strict_xing[0][1] + strict_xing[0][3], 102)
        # 末字（斷 y..308 / 使 y..306）墨迹必须完整落在子列段内，
        # 下段正文行从注释墨迹结束后才开始（旧行为：段止于 287，斷
        # 的字框被就近分进正文行、正文行框上沿压住注释行）。
        self.assertGreaterEqual(strict_xing[1][1] + strict_xing[1][3], 305)
        self.assertGreaterEqual(strict_xing[2][1] + strict_xing[2][3], 305)
        self.assertGreaterEqual(strict_xing[3][1], 308)

    def test_page287_truncated_note_edge_and_two_char_note(self):
        """用户样张（GujiBT 1790460224098 第 287 页）两处实测回归：
        1) 第 4 列长注"刼空傷使|在內合斷"：斷/使 笔画跨进缝隙带把空白
           跑截断在 496，段边界外扩后子列覆盖到墨迹底 537，下段正文行
           从 537 之后开始，注释末字不再落进正文行、行框不再重叠；
        2) 第 10 列两行短注"即天|姚星"：整段 222px ≈ 2.86×根字高，
           旧的 3× 门槛在候选阶段静默丢弃，现按段内小字尺度放行拆分。
        夹具为原页两条列的裁片（行框相对裁片原点平移）。"""
        fixtures = FsPath(__file__).parent / "test_fixtures"
        col4 = fixtures / "guji1790_287_col4_long_note.png"
        col10 = fixtures / "guji1790_287_col10_short_note.png"
        if not (col4.exists() and col10.exists()):
            self.skipTest("缺少真实样张夹具")

        m4 = _text_mask_for_refinement(str(col4))
        subs = _double_column_sub_rects((10, 16, 125, 2111), m4)
        self.assertEqual(len(subs), 4, subs)
        head, right, left, tail = subs
        # 通栏"刑傷"（墨迹 16..192）留在上段，注释子列覆盖 196..537
        self.assertLessEqual(head[1] + head[3], 192, subs)
        self.assertGreaterEqual(right[1] + right[3], 530, subs)
        self.assertGreaterEqual(left[1] + left[3], 530, subs)
        # 正文（墨迹自 553 起）行框不与注释行重叠
        self.assertGreaterEqual(tail[1], 535, subs)
        self.assertTrue(right[0] > left[0], subs)

        m10 = _text_mask_for_refinement(str(col10))
        subs10 = _double_column_sub_rects((9, 11, 127, 2116), m10)
        self.assertEqual(len(subs10), 4, subs10)
        h10, r10, l10, t10 = subs10
        # 注释两字（墨迹 1488..1652）都在子列段 1462..1684 内
        self.assertLessEqual(h10[1] + h10[3], 1466, subs10)
        for part in (r10, l10):
            self.assertLessEqual(part[1], 1488, subs10)
            self.assertGreaterEqual(part[1] + part[3], 1652, subs10)
        self.assertGreaterEqual(t10[1], 1680, subs10)

    def test_kraken_segment_rect_returns_split_lines_in_reading_order(self):
        with TemporaryDirectory() as tmp:
            image_path = FsPath(tmp) / "col.png"
            blobs, solid = self._sample_layout_blobs()
            self._write_image(image_path, 120, 600, blobs, solid)

            def fake_line(text, x, y, w, h):
                n = max(1, len(text))
                strips = [
                    {"x": x, "y": y + int(i * (h - 10) / n), "w": w,
                     "h": int((h - 10) / n), "text": ch, "conf": 0.99}
                    for i, ch in enumerate(text)
                ]
                return [{"x": x, "y": y, "w": w, "h": h, "text": text, "chars": strips}]

            # 子行顺序 [head, right, left]，每行两阶段（整行读法 + 逐框读法）
            with patch(
                "kraken_bridge.recognize_lines",
                side_effect=[
                    fake_line("清顯", 15, 10, 90, 180),
                    self._fake_char_recs(["清", "顯"]),
                    fake_line("甲癸", 65, 210, 45, 380),
                    self._fake_char_recs(["甲", "癸"]),
                    fake_line("次之", 10, 210, 45, 380),
                    self._fake_char_recs(["次", "之"]),
                ],
            ):
                lines = kraken_segment_rect(
                    str(image_path), {"x": 0, "y": 0, "w": 120, "h": 600},
                    "l_1", 1, "vertical", "rtl",
                )
            self.assertEqual(len(lines), 3)
            self.assertEqual(
                [ln["text"] for ln in lines], ["清顯", "甲癸", "次之"]
            )
            self.assertEqual(
                [ln["id"] for ln in lines], ["l_1_d0", "l_1_d1", "l_1_d2"]
            )
            self.assertEqual(lines[0]["layout_role"], "body")
            self.assertEqual(lines[1]["layout_role"], "annotation")
            self.assertEqual(lines[2]["layout_role"], "body")
            self.assertEqual(lines[1]["parent_line_id"], "l_1")
            self.assertEqual(lines[1]["column_group"], "dc_l_1")
            # 子行框不越界：上段通栏不吃进下方双列
            self.assertLess(lines[0]["y"] + lines[0]["h"], lines[1]["y"] + 30)

    def _fake_char_recs(self, texts):
        return [{"text": t, "conf": 0.95} for t in texts]




class HierarchyContainmentTests(unittest.TestCase):
    """层级包含（用户规则）：行框 ⊆ 段落框 ⊆ 主区框。"""

    def test_line_center_in_region_clamped_into_region(self):
        result = {
            "main_regions": [
                {"id": "mr_001", "x": 100, "y": 100, "w": 400, "h": 800}
            ],
            # 行框上下各伸出主区（标点墨迹外扩情景），中心在区内
            "lines": [{"id": "l_1", "x": 120, "y": 90, "w": 80, "h": 830}],
            "blocks": [],
        }
        _enforce_hierarchy_containment(result)
        ln = result["lines"][0]
        self.assertEqual([ln["x"], ln["y"], ln["w"], ln["h"]], [120, 100, 80, 800])

    def test_line_center_outside_regions_untouched(self):
        result = {
            "main_regions": [
                {"id": "mr_001", "x": 100, "y": 100, "w": 400, "h": 800}
            ],
            # 版面边缘小注列：中心在主区外，不钳制
            "lines": [{"id": "l_1", "x": 600, "y": 200, "w": 60, "h": 300}],
            "blocks": [],
        }
        _enforce_hierarchy_containment(result)
        ln = result["lines"][0]
        self.assertEqual([ln["x"], ln["y"], ln["w"], ln["h"]], [600, 200, 60, 300])

    def test_paragraph_expands_to_members_then_clamps_to_region(self):
        result = {
            "main_regions": [
                {"id": "mr_001", "x": 100, "y": 100, "w": 400, "h": 800}
            ],
            "lines": [{"id": "l_1", "x": 120, "y": 90, "w": 80, "h": 830}],
            # 模型段框只盖住中段，比成员行框小
            "paragraphs": [
                {
                    "id": "mp_001",
                    "x": 120,
                    "y": 200,
                    "w": 80,
                    "h": 300,
                    "line_ids": ["l_1"],
                }
            ],
        }
        _enforce_hierarchy_containment(result)
        ln = result["lines"][0]
        # 行框先钳进主区
        self.assertEqual([ln["x"], ln["y"], ln["w"], ln["h"]], [120, 100, 80, 800])
        p = result["paragraphs"][0]
        # 段落框扩到包住行框，再钳进主区；回填主区归属
        self.assertEqual([p["x"], p["y"], p["w"], p["h"]], [120, 100, 80, 800])
        self.assertEqual(p["main_region_id"], "mr_001")

    def test_paragraph_without_regions_still_contains_members(self):
        result = {
            "lines": [{"id": "l_1", "x": 120, "y": 90, "w": 80, "h": 830}],
            "paragraphs": [
                {
                    "id": "mp_001",
                    "x": 120,
                    "y": 200,
                    "w": 80,
                    "h": 300,
                    "line_ids": ["l_1"],
                }
            ],
        }
        _enforce_hierarchy_containment(result)
        p = result["paragraphs"][0]
        self.assertEqual([p["x"], p["y"], p["w"], p["h"]], [120, 90, 80, 830])

    def test_member_line_outside_clamped_paragraph_untouched(self):
        result = {
            "main_regions": [
                {"id": "mr_001", "x": 100, "y": 100, "w": 400, "h": 800}
            ],
            "lines": [
                {"id": "l_1", "x": 120, "y": 120, "w": 80, "h": 700},
                # 跨区列：中心在区内、大半在段落钳制范围外
                {"id": "l_2", "x": 380, "y": 120, "w": 240, "h": 700},
            ],
            "paragraphs": [
                {
                    "id": "mp_001",
                    "x": 120,
                    "y": 120,
                    "w": 500,
                    "h": 700,
                    "line_ids": ["l_1", "l_2"],
                }
            ],
        }
        _enforce_hierarchy_containment(result)
        p = result["paragraphs"][0]
        # 段落框钳进主区（x 收到 500）
        self.assertEqual([p["x"], p["y"], p["w"], p["h"]], [120, 120, 380, 700])
        l2 = result["lines"][1]
        # l_2 与钳后段落框仍有交集的部分保留（x 钳到段落框右缘 500）
        self.assertEqual([l2["x"], l2["w"]], [380, 120])
        l1 = result["lines"][0]
        # 界内成员行原样
        self.assertEqual([l1["x"], l1["w"]], [120, 80])


class AugmentModelHierarchyMultiClassTests(unittest.TestCase):
    """region_det 多类化后 _augment 的 cls→label 映射与 confidence 附加。"""

    def test_model_class_ids_map_to_labels(self):
        from segmenter import _augment_with_model_hierarchy

        boxes = [
            ((0, 40, 200, 140), 0.91, 0),   # main_text
            ((0, 0, 200, 20), 0.82, 1),     # header
            ((0, 180, 200, 20), 0.77, 2),   # footer
            ((90, 180, 20, 20), 0.66, 3),   # page_number
            ((0, 0, 200, 10), 0.55, 4),     # margin_note
        ]
        with patch("seg_layout._predict_detection_layer", return_value=boxes), \
             patch("seg_layout.detection_layer_names",
                   return_value={0: "main_text", 1: "header", 2: "footer",
                                 3: "page_number", 4: "margin_note"}):
            result = _augment_with_model_hierarchy(
                {"lines": []}, "unused.png", 200, 200)
        labels = [r["label"] for r in result["main_regions"]]
        self.assertEqual(
            labels, ["main_text", "header", "footer", "page_number",
                     "margin_note"])
        self.assertEqual(result["main_regions"][0]["confidence"], 0.91)
        # 排除类区不作为层级宿主：无行时无钳制，但函数不应报错

    def test_checkpoint_names_win_over_current_vocab(self):
        # 旧单类模型：names 只有 {0: main_text}，cls 恒 0 → 全部 main_text
        from segmenter import _augment_with_model_hierarchy

        boxes = [((0, 40, 200, 140), 0.9, 0), ((0, 0, 200, 20), 0.8, 0)]
        with patch("seg_layout._predict_detection_layer", return_value=boxes), \
             patch("seg_layout.detection_layer_names",
                   return_value={0: "main_text"}):
            result = _augment_with_model_hierarchy(
                {"lines": []}, "unused.png", 200, 200)
        self.assertEqual([r["label"] for r in result["main_regions"]],
                         ["main_text", "main_text"])

    def test_missing_names_fall_back_to_vocab_index(self):
        # names 拿不到（异常/旧缓存）时按当前词表下标兜底，cls 1 → header
        from segmenter import _augment_with_model_hierarchy

        boxes = [((0, 0, 200, 20), 0.8, 1)]
        with patch("seg_layout._predict_detection_layer", return_value=boxes), \
             patch("seg_layout.detection_layer_names", return_value=None):
            result = _augment_with_model_hierarchy(
                {"lines": []}, "unused.png", 200, 200)
        self.assertEqual(result["main_regions"][0]["label"], "header")
