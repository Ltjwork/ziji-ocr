"""Regression tests for the CPU layout repair endpoint."""

import os
import sys
import unittest
from tempfile import TemporaryDirectory

import cv2
import numpy as np
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import main  # noqa: E402


class LayoutAnalysisTest(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image_path = os.path.join(self.tmp.name, "page.png")
        image = np.full((180, 140, 3), 235, dtype=np.uint8)
        for y in range(42, 138, 18):
            cv2.rectangle(image, (48, y), (72, y + 10), (25, 25, 25), -1)
        cv2.imwrite(self.image_path, image)
        self.client = TestClient(main.app)

    def test_blank_and_ink_bounds_produce_structured_repairs(self):
        response = self.client.post(
            "/analyze_layout",
            json={
                "image_path": self.image_path,
                "orientation": "vertical",
                "horizontal_dir": "rtl",
                "vertical_dir": "ttb",
                "lines": [
                    {"id": "ink", "x": 0, "y": 0, "w": 130, "h": 175},
                    {"id": "blank", "x": 90, "y": 0, "w": 35, "h": 175},
                ],
            },
        )
        self.assertEqual(response.status_code, 200, response.text)
        payload = response.json()
        actions = {item["target_id"]: item["action"] for item in payload["repairs"]}
        self.assertIn(actions.get("ink"), {"tighten", "expand"})
        self.assertEqual(actions.get("blank"), "remove_blank")
        self.assertEqual(payload["diagnostics"]["blank_regions"], 1)
        self.assertIn("overlaps_before", payload["diagnostics"])
        self.assertIn("overlaps_after", payload["diagnostics"])
        rect = next(item["rects"][0] for item in payload["repairs"] if item["target_id"] == "ink")
        self.assertLessEqual(rect[0], 48)
        self.assertLessEqual(rect[1], 42)
        self.assertGreaterEqual(rect[0] + rect[2], 72)
        self.assertGreater(rect[1] + rect[3], 138)

    def test_narrow_detector_bleed_is_reported_as_dedupe_without_trimming_owner(self):
        image = np.full((500, 100, 3), 245, dtype=np.uint8)
        owner_chars = []
        fragment_chars = []
        for index, y in enumerate(range(20, 420, 50)):
            cv2.rectangle(image, (48, y), (57, y + 30), (15, 15, 15), -1)
            # Both detector streams boxed the same glyph centers and strokes.
            owner_chars.append({'id': f'o{index}', 'x': 46, 'y': y, 'w': 16, 'h': 34, 'text': '字'})
            fragment_chars.append({'id': f'f{index}', 'x': 44, 'y': y, 'w': 18, 'h': 34, 'text': '字'})
        cv2.imwrite(self.image_path, image)
        response = self.client.post(
            '/analyze_layout',
            json={
                'image_path': self.image_path,
                'orientation': 'vertical',
                'horizontal_dir': 'rtl',
                'vertical_dir': 'ttb',
                'lines': [
                    {'id': 'owner', 'x': 46, 'y': 0, 'w': 40, 'h': 450, 'chars': owner_chars},
                    {'id': 'fragment', 'x': 44, 'y': 0, 'w': 18, 'h': 450, 'chars': fragment_chars},
                ],
            },
        )
        self.assertEqual(response.status_code, 200, response.text)
        payload = response.json()
        self.assertTrue(any(
            item['target_id'] == 'fragment' and item['action'] == 'dedupe'
            for item in payload['repairs']
        ))
        owner = next(line for line in payload['lines'] if line['id'] == 'owner')
        self.assertGreaterEqual(owner['w'], 40)


if __name__ == "__main__":
    unittest.main()
