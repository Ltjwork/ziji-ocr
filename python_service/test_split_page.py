"""跨页拆分 /split_page 端点测试：中缝取整、两侧裁剪尺寸、中文路径写盘。"""

import os
import unittest
from tempfile import TemporaryDirectory

import cv2
import numpy as np
from fastapi.testclient import TestClient

from main import app


def _read_unicode(path: str):
    """cv2.imread 不支持非 ASCII 路径，与写盘侧 imencode+tofile 对称地读。"""
    return cv2.imdecode(np.fromfile(path, dtype=np.uint8), cv2.IMREAD_COLOR)


class SplitPageEndpointTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = self._tmp.name

    def _write_image(self, name: str, w: int, h: int) -> str:
        path = os.path.join(self.root, name)
        img = np.full((h, w, 3), 240, dtype=np.uint8)
        img[:, : w // 2] = 120  # 左半涂深色便于区分
        self.assertTrue(cv2.imwrite(path, img))
        return path

    def test_split_writes_both_halves_with_int_pixel_spine(self):
        src = self._write_image("spread.png", 101, 40)
        left = os.path.join(self.root, "out", "page_000.png")
        right = os.path.join(self.root, "out", "page_001.png")

        resp = self.client.post(
            "/split_page",
            json={
                "image_path": src,
                "spine_ratio": 0.5,
                "left_path": left,
                "right_path": right,
            },
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        data = resp.json()
        self.assertEqual(data["w"], 101)
        self.assertEqual(data["h"], 40)
        self.assertEqual(data["spine_x"], 50)  # round(101*0.5)=50（银行家舍入）
        self.assertEqual(data["left_w"], 50)
        self.assertEqual(data["right_w"], 51)

        left_img = _read_unicode(left)
        right_img = _read_unicode(right)
        self.assertEqual(left_img.shape, (40, 50, 3))
        self.assertEqual(right_img.shape, (40, 51, 3))
        # 左半深色、右半浅色：裁剪边界与涂色一致
        self.assertEqual(int(left_img[:, :, 0].mean()), 120)
        self.assertEqual(int(right_img[:, :, 0].mean()), 240)

    def test_split_allows_omitting_one_side(self):
        src = self._write_image("spread2.png", 60, 30)
        right = os.path.join(self.root, "only_right.png")
        resp = self.client.post(
            "/split_page",
            json={"image_path": src, "spine_ratio": 0.5, "right_path": right},
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        data = resp.json()
        self.assertEqual(data["spine_x"], 30)
        self.assertFalse(os.path.exists(os.path.join(self.root, "only_left.png")))
        self.assertEqual(_read_unicode(right).shape, (30, 30, 3))

    def test_split_rejects_bad_ratio_and_missing_image(self):
        src = self._write_image("spread3.png", 60, 30)
        resp = self.client.post(
            "/split_page",
            json={"image_path": src, "spine_ratio": 1.5},
        )
        self.assertEqual(resp.status_code, 400)
        resp = self.client.post(
            "/split_page",
            json={"image_path": os.path.join(self.root, "nope.png"), "spine_ratio": 0.5},
        )
        self.assertEqual(resp.status_code, 400)

    def test_split_writes_unicode_path(self):
        # cv2.imwrite 对非 ASCII 路径会静默失败（历史 bug），这里与
        # /transform_page 同一口径：中文目录必须真实落盘。
        src = self._write_image("spread4.png", 40, 20)
        out_dir = os.path.join(self.root, "识字", "split")
        left = os.path.join(out_dir, "page_000.png")
        resp = self.client.post(
            "/split_page",
            json={"image_path": src, "spine_ratio": 0.5, "left_path": left},
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertTrue(os.path.exists(left))
        self.assertEqual(_read_unicode(left).shape, (20, 20, 3))


if __name__ == "__main__":
    unittest.main()
