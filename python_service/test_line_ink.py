"""AI 框检查判空支撑测试：/line_ink 的结构性墨迹测量。

覆盖：
1. 真文字行（字框内有笔画）→ char_ink_median 明显高于空白行；
2. 空白行（字框落在纯底 + 一条细界格线上）→ char_ink_median ≈ 0，
   blank_chars 全数；
3. 界格线（贯穿行高的细竖线）被结构性过滤剔除，不计入墨迹；
4. 坏图返回 ok=false 不中断整批；
5. 不带 chars 时按行框整体测。

运行：conda run -n paddle python -m pytest test_line_ink.py -q
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


def _page_with_column(path, w=400, h=1200):
    """画一页：右半区一条真文字列（每 100px 一个 40x40 墨字），左侧只
    画一条 4px 界格线，其余留白。"""
    img = np.full((h, w, 3), 235, dtype=np.uint8)
    # 真文字列：x∈[220,280]
    for k in range(10):
        y = 30 + k * 110
        cv2.rectangle(img, (230, y), (270, y + 55), (30, 30, 30), -1)
    # 界格线：x=100，贯穿整页
    cv2.rectangle(img, (98, 0), (102, h), (120, 120, 120), -1)
    cv2.imwrite(path, img)
    return img


class LineInkTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.img_path = os.path.join(self.tmp.name, "page.png")
        _page_with_column(self.img_path)

    def _post(self, items):
        r = self.client.post("/line_ink", json={"items": items})
        self.assertEqual(r.status_code, 200)
        return r.json()["results"]

    def test_text_line_has_high_ink_blank_line_near_zero(self):
        text_chars = [
            {"x": 225, "y": 30 + k * 110, "w": 50, "h": 65} for k in range(10)
        ]
        blank_chars = [
            {"x": 82, "y": 30 + k * 110, "w": 36, "h": 65} for k in range(10)
        ]
        res = self._post([
            {"image_path": self.img_path, "x": 220, "y": 20,
             "w": 60, "h": 1100, "chars": text_chars},
            {"image_path": self.img_path, "x": 82, "y": 20,
             "w": 36, "h": 1100, "chars": blank_chars},
        ])
        self.assertTrue(res[0]["ok"])
        self.assertTrue(res[1]["ok"])
        self.assertGreater(res[0]["char_ink_median"], 0.15)
        self.assertLess(res[1]["char_ink_median"], 0.05)
        self.assertEqual(res[1]["blank_chars"], 10)
        self.assertEqual(res[0]["char_count"], 10)

    def test_rule_line_excluded_from_ink(self):
        # 字框完全罩在界格线上（4px 宽灰线）→ 结构过滤后墨迹≈0。
        res = self._post([{
            "image_path": self.img_path, "x": 90, "y": 0, "w": 20, "h": 1200,
            "chars": [{"x": 90, "y": 100 + k * 150, "w": 20, "h": 60}
                      for k in range(7)],
        }])
        self.assertTrue(res[0]["ok"])
        self.assertLess(res[0]["char_ink_median"], 0.05)

    def test_line_rect_used_when_no_chars(self):
        # 不带 chars → 按行框核心区测：真列高、空白列≈0。
        res = self._post([
            {"image_path": self.img_path, "x": 220, "y": 20, "w": 60, "h": 1100},
            {"image_path": self.img_path, "x": 60, "y": 20, "w": 36, "h": 1100},
        ])
        self.assertGreater(res[0]["char_ink_median"], 0.1)
        self.assertLess(res[1]["char_ink_median"], 0.05)

    def test_bad_image_returns_ok_false(self):
        res = self._post([
            {"image_path": os.path.join(self.tmp.name, "nope.png"),
             "x": 0, "y": 0, "w": 40, "h": 200},
            {"image_path": self.img_path, "x": 220, "y": 20, "w": 60, "h": 200},
        ])
        self.assertFalse(res[0]["ok"])
        self.assertTrue(res[1]["ok"])

    def test_empty_items(self):
        self.assertEqual(self._post([]), [])


if __name__ == "__main__":
    unittest.main()
