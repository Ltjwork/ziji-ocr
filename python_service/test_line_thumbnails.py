"""AI 框检查的后端支撑测试：

1. /line_thumbnails：纵横比保持、pad 钳回图内、字框叠加、坏项 None、
   max_side 缩放；
2. /segment_region 的 expected_char_count 透传（仅在不带 char_boxes 时）。

运行：conda run -n paddle python -m pytest test_line_thumbnails.py -q
"""

import base64
import os
import sys
import unittest
from tempfile import TemporaryDirectory
from unittest.mock import patch

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402


def _write_img(path, w, h, value=235):
    img = np.full((h, w, 3), value, dtype=np.uint8)
    # 行位置画一条深色竖排墨迹带，保证裁图非空且有内容。
    cv2.rectangle(img, (w // 2 - 6, 10), (w // 2 + 6, h - 10), (40, 40, 40), -1)
    cv2.imwrite(path, img)
    return img


class LineThumbnailsTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.img_path = os.path.join(self.tmp.name, "page.png")
        self.img = _write_img(self.img_path, 400, 1200)

    def _thumb(self, item_overrides=None, **req_overrides):
        item = {
            "image_path": self.img_path,
            "x": 180,
            "y": 50,
            "w": 40,
            "h": 900,
            "orientation": "vertical",
        }
        item.update(item_overrides or {})
        r = self.client.post(
            "/line_thumbnails", json={"items": [item], **req_overrides}
        )
        self.assertEqual(r.status_code, 200)
        raw = r.json()["thumbs"][0]
        self.assertIsNotNone(raw)
        buf = np.frombuffer(base64.b64decode(raw), dtype=np.uint8)
        return cv2.imdecode(buf, cv2.IMREAD_UNCHANGED)

    def test_aspect_ratio_preserved(self):
        # 竖排行 40x900（加 pad 后约 175x1035）→ 输出应仍远高於宽，
        # 不做正方形 letterbox。
        out = self._thumb(max_side=640)
        self.assertGreater(out.shape[0], out.shape[1] * 3)

    def test_max_side_scales_long_edge(self):
        out = self._thumb(max_side=320)
        self.assertLessEqual(max(out.shape[0], out.shape[1]), 320)
        self.assertGreater(max(out.shape[0], out.shape[1]), 200)

    def test_max_side_capped_at_2048(self):
        # 超大请求被钳到 2048（AI 行条图清晰度上限；竖排长行单字大小
        # 由调用方的 maxSide 决定，服务端只防超大图）。
        tall = os.path.join(self.tmp.name, "tall.png")
        _write_img(tall, 400, 3000)
        out = self._thumb(
            item_overrides={
                "image_path": tall,
                "x": 180,
                "y": 50,
                "w": 40,
                "h": 2800,
            },
            max_side=9999,
        )
        self.assertLessEqual(max(out.shape[0], out.shape[1]), 2048)
        self.assertGreater(max(out.shape[0], out.shape[1]), 1500)

    def test_max_side_allows_1536(self):
        # AI 辅助识别行条图的请求档位（单字辅助/整行裁决）：此前 768
        # 上限会把竖排长行的单字压到 ~38px，1536 档不再被钳。
        _write_img(os.path.join(self.tmp.name, "tall2.png"), 400, 2400)
        item = {
            "image_path": os.path.join(self.tmp.name, "tall2.png"),
            "x": 180,
            "y": 50,
            "w": 40,
            "h": 2300,
            "orientation": "vertical",
        }
        r = self.client.post(
            "/line_thumbnails", json={"items": [item], "max_side": 1536}
        )
        self.assertEqual(r.status_code, 200)
        raw = r.json()["thumbs"][0]
        self.assertIsNotNone(raw)
        buf = np.frombuffer(base64.b64decode(raw), dtype=np.uint8)
        out = cv2.imdecode(buf, cv2.IMREAD_UNCHANGED)
        self.assertGreater(max(out.shape[0], out.shape[1]), 1200)

    def test_padding_clamped_to_image(self):
        # 行框贴图左上角，pad 不得把裁图推出图外（不崩、尺寸合法）。
        out = self._thumb(item_overrides={"x": 0, "y": 0, "w": 60, "h": 300})
        self.assertGreaterEqual(out.shape[0], 4)
        self.assertGreaterEqual(out.shape[1], 4)

    def test_boxes_overlay_changes_output(self):
        plain = self._thumb()
        with_boxes = self._thumb(
            item_overrides={
                "boxes": [
                    {"x": 185, "y": 100, "w": 30, "h": 60},
                    {"x": 185, "y": 200, "w": 30, "h": 60},
                ]
            }
        )
        self.assertFalse(np.array_equal(plain, with_boxes))

    def test_box_marking_does_not_hide_glyph(self):
        # 标注三原则回归：框内是 25% 半透明高亮（黑字仍暗，不实心遮字），
        # 序号白块在框外（竖排行 = 框左侧），不压框内字形。
        _write_img(self.img_path, 400, 1200)
        box = {"x": 190, "y": 400, "w": 20, "h": 40}  # 框中心在墨迹带上
        with_box = self._thumb(item_overrides={"boxes": [box]})
        # 框中心（墨迹 40 灰度混 25% 橙后仍应 < 120；实心橙约 133+）
        cy, cx = with_box.shape[0] // 2, with_box.shape[1] // 2
        center = with_box[max(0, cy - 5):cy + 5, max(0, cx - 4):cx + 4]
        self.assertLess(float(center.mean()), 120)
        # 白块应在框左侧：框左边 x=190 → 缩放后白块中心在框左 8px 外
        # （图 400x1200、行 40x900 → 缩放约 640/1035；这里只验证框左侧
        # 比框内部更亮，即序号没压在字上）。
        scale = with_box.shape[1] / 400.0
        inside = with_box[max(0, cy - 5):cy + 5,
                          int(198 * scale):int(202 * scale)]
        outside = with_box[max(0, cy - 5):cy + 5,
                           int((190 - 12) * scale):int((190 - 2) * scale)]
        self.assertGreater(float(outside.mean()), float(inside.mean()))

    def test_bad_item_returns_none_not_error(self):
        r = self.client.post(
            "/line_thumbnails",
            json={
                "items": [
                    {"image_path": os.path.join(self.tmp.name, "nope.png"),
                     "x": 0, "y": 0, "w": 40, "h": 200},
                    {"image_path": self.img_path,
                     "x": 180, "y": 50, "w": 40, "h": 200},
                ]
            },
        )
        self.assertEqual(r.status_code, 200)
        thumbs = r.json()["thumbs"]
        self.assertIsNone(thumbs[0])
        self.assertIsNotNone(thumbs[1])

    def test_rejects_too_many_items(self):
        r = self.client.post(
            "/line_thumbnails",
            json={
                "items": [
                    {"image_path": self.img_path, "x": 0, "y": 0, "w": 10, "h": 10}
                ] * 201
            },
        )
        self.assertEqual(r.status_code, 400)


class SegmentRegionExpectedCountTest(unittest.TestCase):
    """/segment_region 的 expected_char_count 透传契约。"""

    def setUp(self):
        self.client = TestClient(main.app)
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.img_path = os.path.join(self.tmp.name, "page.png")
        _write_img(self.img_path, 400, 1200)

    def _post(self, body):
        return self.client.post("/segment_region", json=body)

    def test_expected_count_passed_when_no_char_boxes(self):
        captured = {}

        def fake_rect(image_path, rect, line_id, line_no, orientation,
                      horizontal_dir, **kwargs):
            captured.update(kwargs)
            return [{
                "id": line_id, "x": rect["x"], "y": rect["y"],
                "w": rect["w"], "h": rect["h"], "line_no": line_no,
                "orientation": orientation, "text": "",
                "chars": [{"x": 0, "y": 0, "w": 10, "h": 10, "text": "字"}],
            }]

        with patch.object(main.kraken_bridge, "kraken_segment_rect", fake_rect), \
             patch.object(
                 main, "make_kraken_char_splitter", lambda *a, **k: None):
            r = self._post({
                "image_path": self.img_path,
                "x": 0, "y": 0, "w": 40, "h": 400,
                "line_id": "l1", "line_no": 0,
                "expected_char_count": 12,
            })
        self.assertEqual(r.status_code, 200)
        self.assertEqual(captured.get("expected_char_count"), 12)

    def test_expected_count_ignored_with_char_boxes(self):
        captured = {}

        def fake_rect(image_path, rect, line_id, line_no, orientation,
                      horizontal_dir, **kwargs):
            captured.update(kwargs)
            return [{
                "id": line_id, "x": rect["x"], "y": rect["y"],
                "w": rect["w"], "h": rect["h"], "line_no": line_no,
                "orientation": orientation, "text": "",
                "chars": [{"x": 0, "y": 0, "w": 10, "h": 10, "text": "字"}],
            }]

        with patch.object(main.kraken_bridge, "kraken_segment_rect", fake_rect), \
             patch.object(
                 main, "make_kraken_char_splitter", lambda *a, **k: None):
            r = self._post({
                "image_path": self.img_path,
                "x": 0, "y": 0, "w": 40, "h": 400,
                "line_id": "l1", "line_no": 0,
                "expected_char_count": 12,
                "char_boxes": [{"x": 0, "y": 0, "w": 20, "h": 40}],
            })
        self.assertEqual(r.status_code, 200)
        self.assertIsNone(captured.get("expected_char_count"))


if __name__ == "__main__":
    unittest.main()
