# -*- coding: utf-8 -*-
"""区域门控测试（用户规则：只有正文区域进行段落/行/单字划分与识别，
页眉/页脚/页码止步于版面区检测；训练与标注仍覆盖全部区域类型）。

覆盖三块：
1. build_body_gated_image：排除类区抹成页面底色、正文墨迹保留、
   无排除类区/无区域时退回原图（None）、深底页面按边框中值取色；
2. _augment_with_model_hierarchy：管线预置 main_regions 后跳过
   region_det 重复推理（段落模型照常）；
3. regions_from_boxes：cls→label 映射（checkpoint names 优先、
   词表外回落 main_text）。
"""
import os
import unittest
from tempfile import TemporaryDirectory
from unittest.mock import patch

import cv2
import numpy as np

import seg_layout
from segmenter import (
    _augment_with_model_hierarchy,
    build_body_gated_image,
    dispose_body_gated_image,
    regions_from_boxes,
)


def _page_with_header(tmp: str) -> str:
    """白底竖排页：顶部 0-18 行为页眉墨迹，中部 60-220 为正文列。"""
    path = os.path.join(tmp, "page.png")
    image = np.full((240, 180, 3), 240, dtype=np.uint8)
    # 页眉：顶部一条墨带（书名）。
    cv2.rectangle(image, (30, 6), (150, 18), (30, 30, 30), -1)
    # 正文：两列墨块。
    for x in (40, 100):
        for y in range(60, 216, 16):
            cv2.rectangle(image, (x, y), (x + 16, y + 10), (40, 40, 40), -1)
    cv2.imwrite(path, image)
    return path


class BuildBodyGatedImageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image_path = _page_with_header(self.tmp.name)

    def test_excluded_regions_masked_to_background(self):
        regions = [
            {"x": 20, "y": 0, "w": 140, "h": 24, "label": "header"},
            {"x": 30, "y": 50, "w": 100, "h": 170, "label": "main_text"},
        ]
        gated = build_body_gated_image(self.image_path, regions)
        self.assertIsNotNone(gated)
        self.addCleanup(dispose_body_gated_image, gated)
        masked = cv2.imread(gated)
        original = cv2.imread(self.image_path)
        # 页眉墨迹（原为深色）被抹成纸底色（变白），正文列原样保留。
        self.assertGreater(int(masked[10, 90, 0]), 200)
        self.assertLess(int(original[10, 90, 0]), 60)
        self.assertEqual(masked[65, 45, 0], original[65, 45, 0])
        self.assertEqual(masked[200, 105, 0], original[200, 105, 0])
        # 尺寸不变（几何坐标系不动）。
        self.assertEqual(masked.shape, original.shape)

    def test_no_excluded_regions_returns_none(self):
        regions = [
            {"x": 30, "y": 50, "w": 100, "h": 170, "label": "main_text"},
            {"x": 0, "y": 30, "w": 60, "h": 30, "label": "margin_note"},
        ]
        self.assertIsNone(build_body_gated_image(self.image_path, regions))

    def test_no_regions_returns_none(self):
        self.assertIsNone(build_body_gated_image(self.image_path, None))
        self.assertIsNone(build_body_gated_image(self.image_path, []))

    def test_rejected_excluded_region_ignored(self):
        regions = [
            {"x": 20, "y": 0, "w": 140, "h": 24, "label": "header",
             "status": "rejected"},
        ]
        self.assertIsNone(build_body_gated_image(self.image_path, regions))

    def test_dark_page_masks_with_dark_background(self):
        path = os.path.join(self.tmp.name, "dark.png")
        image = np.full((240, 180, 3), 20, dtype=np.uint8)
        cv2.rectangle(image, (30, 6), (150, 18), (220, 220, 220), -1)
        for x in (40, 100):
            for y in range(60, 216, 16):
                cv2.rectangle(image, (x, y), (x + 16, y + 10), (210, 210, 210), -1)
        cv2.imwrite(path, image)
        gated = build_body_gated_image(
            path, [{"x": 20, "y": 0, "w": 140, "h": 24, "label": "header"}],
        )
        self.assertIsNotNone(gated)
        self.addCleanup(dispose_body_gated_image, gated)
        masked = cv2.imread(gated)
        # 黑底页：页眉白墨被抹成深底色，正文白墨保留。
        self.assertLess(int(masked[10, 90, 0]), 60)
        self.assertGreater(int(masked[65, 45, 0]), 180)


class AugmentReusePreseededRegionsTest(unittest.TestCase):
    def test_preseeded_main_regions_skip_region_det(self):
        calls = []

        def fake_predict(layer, image_path, w, h):
            calls.append(layer)
            return []

        result = {
            "lines": [],
            "main_regions": [
                {"x": 0, "y": 50, "w": 100, "h": 170, "label": "main_text"},
            ],
        }
        with patch.object(
            seg_layout, "_predict_detection_layer", fake_predict
        ):
            out = _augment_with_model_hierarchy(result, "unused.png", 100, 240)
        self.assertNotIn("region_det", calls)
        self.assertEqual(len(out["main_regions"]), 1)
        # 段落模型照常尝试（未启用返回空，不添加字段）。
        self.assertIn("paragraph_det", calls)

    def test_without_preseed_runs_region_det(self):
        calls = []

        def fake_predict(layer, image_path, w, h):
            calls.append(layer)
            if layer == "region_det":
                return [([10, 20, 30, 40], 0.9, 0)]
            return []

        with patch.object(
            seg_layout, "_predict_detection_layer", fake_predict
        ):
            out = _augment_with_model_hierarchy(
                {"lines": []}, "unused.png", 100, 240
            )
        self.assertIn("region_det", calls)
        self.assertEqual(out["main_regions"][0]["label"], "main_text")


class RegionsFromBoxesTest(unittest.TestCase):
    def test_checkpoint_names_take_priority(self):
        regions = regions_from_boxes(
            [([0, 0, 10, 10], 0.8, 1)], {1: "footer"}
        )
        self.assertEqual(regions[0]["label"], "footer")
        self.assertEqual(regions[0]["confidence"], 0.8)

    def test_unknown_cls_falls_back_to_main_text(self):
        regions = regions_from_boxes([([0, 0, 10, 10], 0.5, 99)], {})
        self.assertEqual(regions[0]["label"], "main_text")


if __name__ == "__main__":
    unittest.main()
