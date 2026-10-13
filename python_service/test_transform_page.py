# -*- coding: utf-8 -*-
"""transform_page 盘上链路回归：多次混合旋转后文件必须无损——尺寸按
90° 置换、像素与 cv2.rotate 参考链逐位一致（校对摆正"旋转后原图被裁切"
排查时锁定：前端显示曾裁切，盘上链路必须持续证明无辜）。"""
import os
import unittest
from tempfile import TemporaryDirectory

import cv2
import numpy as np
from fastapi.testclient import TestClient

from main import app


def _quad_img(w, h):
    """四象限异色图，任一像素错位立刻暴露。"""
    img = np.zeros((h, w, 3), dtype=np.uint8)
    img[: h // 2, : w // 2] = (255, 0, 0)
    img[: h // 2, w // 2 :] = (0, 255, 0)
    img[h // 2 :, w // 2 :] = (0, 0, 255)
    img[h // 2 :, : w // 2] = (0, 255, 255)
    return img


class TransformPageChainTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)
        self.tmp = TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "page.png")
        cv2.imencode(".png", _quad_img(400, 600))[1].tofile(self.path)
        self.original = self._read()

    def tearDown(self):
        self.tmp.cleanup()

    def _read(self):
        return cv2.imdecode(
            np.fromfile(self.path, dtype=np.uint8), cv2.IMREAD_COLOR
        )

    def _rotate(self, op, cv_op, ref):
        r = self.client.post(
            "/transform_page", json={"image_path": self.path, "op": op}
        )
        self.assertEqual(r.status_code, 200, r.text)
        disk = self._read()
        ref = cv2.rotate(ref, cv_op)
        self.assertEqual(
            disk.shape, ref.shape, f"{op} 后尺寸被改：{disk.shape} != {ref.shape}"
        )
        self.assertTrue(np.array_equal(disk, ref), f"{op} 后像素被改动")
        return ref

    def test_mixed_rotations_preserve_disk_pixels(self):
        """任意混合序列逐步对账：每步盘上像素 = 参考链（净角度可回收）。"""
        ref = self.original
        ref = self._rotate("rotate_cw", cv2.ROTATE_90_CLOCKWISE, ref)
        ref = self._rotate("rotate_ccw", cv2.ROTATE_90_COUNTERCLOCKWISE, ref)
        ref = self._rotate("rotate_ccw", cv2.ROTATE_90_COUNTERCLOCKWISE, ref)
        ref = self._rotate("rotate_cw", cv2.ROTATE_90_CLOCKWISE, ref)
        ref = self._rotate("rotate_ccw", cv2.ROTATE_90_COUNTERCLOCKWISE, ref)
        ref = self._rotate("rotate_ccw", cv2.ROTATE_90_COUNTERCLOCKWISE, ref)
        # 净 2×CCW = 180°：尺寸不变，内容为原图转 180°。
        self.assertEqual(ref.shape, self.original.shape)
        self.assertTrue(np.array_equal(self._read(), ref))

    def test_cw_x4_returns_to_identity(self):
        """净 0°：连续 4 次顺时针后盘上像素与原图逐位一致。"""
        ref = self.original
        for _ in range(4):
            ref = self._rotate("rotate_cw", cv2.ROTATE_90_CLOCKWISE, ref)
        self.assertTrue(np.array_equal(self._read(), self.original))


if __name__ == "__main__":
    unittest.main()
