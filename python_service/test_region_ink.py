# -*- coding: utf-8 -*-
"""/region_ink 的矩形墨迹检测测试（主区快设「按参考页适配」判空依据）。

覆盖：
1. 有内容的页眉框 → ink 明显高于阈值；空白带（无页眉的页）→ ink ≈ 0；
2. 界格细线不算墨迹（结构性过滤）；
3. 坏图整批 ok=false（前端保守保留框）；
4. 空列表、超上限 400。

运行：conda run -n paddle python -m pytest test_region_ink.py -q
"""
import os
import sys
import unittest
from tempfile import TemporaryDirectory

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402


def _page_with_header(path, w=800, h=1200):
    """画一页：顶部一条页眉文字带（y∈[30,70] 的墨块行），下方大面积留白，
    左侧一条 4px 界格线贯穿整页。"""
    img = np.full((h, w, 3), 235, dtype=np.uint8)
    for k in range(8):
        x = 200 + k * 60
        cv2.rectangle(img, (x, 32), (x + 36, 70), (30, 30, 30), -1)
    cv2.rectangle(img, (98, 0), (102, h), (120, 120, 120), -1)
    cv2.imwrite(path, img)
    return img


class RegionInkTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.img_path = os.path.join(self.tmp.name, "page.png")
        _page_with_header(self.img_path)

    def _post(self, image_path, rects):
        r = self.client.post("/region_ink",
                             json={"image_path": image_path, "rects": rects})
        self.assertEqual(r.status_code, 200)
        return r.json()["results"]

    def test_header_rect_ink_high_blank_band_near_zero(self):
        res = self._post(self.img_path, [
            # 页眉框：罩住顶部文字带
            {"x": 190, "y": 20, "w": 500, "h": 70},
            # "页眉位置"但落在空白正文区（该页无第二条页眉带）
            {"x": 190, "y": 900, "w": 500, "h": 70},
        ])
        self.assertTrue(res[0]["ok"])
        self.assertTrue(res[1]["ok"])
        self.assertGreater(res[0]["ink"], 0.05)
        self.assertLess(res[1]["ink"], 0.02)

    def test_rule_line_not_counted_as_ink(self):
        # 框完全罩在 4px 界格线上 → 结构过滤后 ≈0（不是"有页眉"）
        res = self._post(self.img_path, [{"x": 90, "y": 20, "w": 20, "h": 70}])
        self.assertTrue(res[0]["ok"])
        self.assertLess(res[0]["ink"], 0.02)

    def test_bad_image_returns_ok_false_for_all(self):
        res = self._post(os.path.join(self.tmp.name, "nope.png"),
                         [{"x": 0, "y": 0, "w": 100, "h": 50}] * 2)
        self.assertEqual(len(res), 2)
        self.assertFalse(res[0]["ok"])
        self.assertFalse(res[1]["ok"])

    def test_empty_rects(self):
        self.assertEqual(self._post(self.img_path, []), [])

    def test_too_many_rects_400(self):
        r = self.client.post("/region_ink", json={
            "image_path": self.img_path,
            "rects": [{"x": 0, "y": 0, "w": 10, "h": 10}] * 65,
        })
        self.assertEqual(r.status_code, 400)


if __name__ == "__main__":
    unittest.main()
