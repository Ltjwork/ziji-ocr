"""excalidraw_export v2：区域 → Excalidraw 场景（分层图形检测 + 文字）。

build_excalidraw_scene 只吃识别好的 lines（注入，无需起 Kraken daemon），
形状检测用合成图逐类断言：格面还原（网格→宫格矩形）、独立框、椭圆、
直线/虚线、箭头、填充块、取色、底图嵌入、设置项开关、墨迹覆盖率。
"""

import unittest
from pathlib import Path as FsPath
from tempfile import TemporaryDirectory

import cv2
import numpy as np

import excalidraw_export
import excalidraw_scene
from excalidraw_export import build_excalidraw_scene, region_to_excalidraw


def _write_image(path, width, height):
    img = np.full((height, width, 3), 255, dtype=np.uint8)
    cv2.imwrite(str(path), img)
    return img


class ExcalidrawSceneTests(unittest.TestCase):
    def _scene(self, tmp, draw, width=400, height=300, ocr_lines=None,
               region=None, settings=None, text_boxes=None,
               debug_images=False):
        image_path = FsPath(tmp) / "page.png"
        img = np.full((height, width, 3), 255, dtype=np.uint8)
        draw(img)
        cv2.imwrite(str(image_path), img)
        return build_excalidraw_scene(
            str(image_path), region or (0, 0, width, height), ocr_lines or [],
            settings=settings, text_boxes=text_boxes,
            debug_images=debug_images,
        )

    # ── 基础形状 ──

    def test_rect_ellipse_and_lines_detected(self):
        def draw(img):
            # 方框（描边）、圆环、横线、竖线、斜线各一（互不相交——
            # 相交笔画会连成一个轮廓，那是折线兜底路径的行为）
            cv2.rectangle(img, (30, 40), (220, 180), (0, 0, 0), 2)
            cv2.circle(img, (320, 90), 45, (0, 0, 0), 2)
            cv2.line(img, (30, 250), (200, 250), (0, 0, 0), 2)
            cv2.line(img, (235, 30), (235, 285), (0, 0, 0), 2)
            cv2.line(img, (255, 270), (390, 170), (0, 0, 0), 2)

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(tmp, draw)
        self.assertEqual(scene["type"], "excalidraw")
        self.assertEqual(scene["version"], 2)

        rects = [e for e in scene["elements"] if e["type"] == "rectangle"]
        ellipses = [e for e in scene["elements"] if e["type"] == "ellipse"]
        lines = [e for e in scene["elements"] if e["type"] == "line"]

        # 矩形 ≈ (30,40,190,140)
        self.assertEqual(len(rects), 1, [e["x"] for e in rects])
        r = rects[0]
        self.assertAlmostEqual(r["x"], 30, delta=4)
        self.assertAlmostEqual(r["y"], 40, delta=4)
        self.assertAlmostEqual(r["width"], 190, delta=6)
        self.assertAlmostEqual(r["height"], 140, delta=6)
        self.assertEqual(r["backgroundColor"], "transparent")

        # 圆环 → 单个椭圆（内外缘去重）≈ 中心 (320,90) 半径 45
        self.assertEqual(len(ellipses), 1, ellipses)
        e = ellipses[0]
        self.assertAlmostEqual(e["x"] + e["width"] / 2, 320, delta=6)
        self.assertAlmostEqual(e["y"] + e["height"] / 2, 90, delta=6)
        self.assertAlmostEqual(e["width"], 90, delta=8)
        self.assertAlmostEqual(e["height"], 90, delta=8)

        # 横线 y≈250、竖线 x≈235、斜线 (255,270)→(390,170) 各一条
        def seg(el):
            (x1, y1), (x2, y2) = el["points"][0], el["points"][-1]
            return (
                el["x"] + x1, el["y"] + y1,
                el["x"] + x2, el["y"] + y2,
            )

        segs = list(map(seg, lines))
        h = [s for s in segs if abs(s[1] - s[3]) <= 4 and abs(s[1] - 250) <= 5]
        v = [s for s in segs if abs(s[0] - s[2]) <= 4 and abs(s[0] - 235) <= 5]
        d = [
            s for s in segs
            if abs(s[0] - s[2]) > 4 and abs(s[1] - s[3]) > 4
        ]
        self.assertEqual(len(h), 1, segs)
        self.assertAlmostEqual(h[0][0], 30, delta=6)
        self.assertAlmostEqual(h[0][2], 200, delta=6)
        self.assertEqual(len(v), 1, segs)
        self.assertAlmostEqual(v[0][1], 30, delta=8)
        self.assertAlmostEqual(v[0][3], 285, delta=8)
        self.assertGreaterEqual(len(d), 1)

        self.assertEqual(stats["rectangles"], 1)
        self.assertEqual(stats["ellipses"], 1)
        self.assertGreaterEqual(stats["lines"], 3)
        self.assertTrue(0.0 <= stats["ink_coverage"] <= 1.0)

    def test_text_boxes_are_masked_out_of_shape_detection(self):
        """已识别文字的字框从墨迹掩膜抠除：字形不再被当成图形。"""
        def draw(img):
            # 一个实心方块（模拟字形墨迹）+ 一条横线
            cv2.rectangle(img, (60, 60), (100, 100), (0, 0, 0), -1)
            cv2.line(img, (20, 200), (380, 200), (0, 0, 0), 2)

        ocr = [{
            "orientation": "vertical",
            "chars": [
                {"x": 58, "y": 58, "w": 44, "h": 44, "text": "斗"},
            ],
        }]
        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(tmp, draw, ocr_lines=ocr)
        # 方块被文字字框抠掉：只剩 1 条横线，没有矩形/椭圆
        self.assertEqual(stats["rectangles"], 0, scene["elements"])
        self.assertEqual(stats["ellipses"], 0)
        texts = [e for e in scene["elements"] if e["type"] == "text"]
        self.assertEqual(len(texts), 1)
        self.assertEqual(texts[0]["text"], "斗")
        self.assertAlmostEqual(texts[0]["x"], 58, delta=3)
        self.assertAlmostEqual(texts[0]["y"], 58, delta=3)
        self.assertGreater(texts[0]["fontSize"], 20)

    def test_vertical_chars_stacked_horizontal_line_joined(self):
        """竖排行逐字成元素（位置=字框）；横排行整行合并为一个元素。"""
        def draw(img):
            for cy in (20, 70, 120):
                cv2.rectangle(img, (30, cy), (70, cy + 40), (0, 0, 0), -1)
            for cx in (200, 250, 300):
                cv2.rectangle(img, (cx, 30), (cx + 40, 70), (0, 0, 0), -1)

        ocr = [
            {
                "orientation": "vertical",
                "chars": [
                    {"x": 28, "y": 18, "w": 44, "h": 44, "text": "斗"},
                    {"x": 28, "y": 68, "w": 44, "h": 44, "text": "數"},
                    {"x": 28, "y": 118, "w": 44, "h": 44, "text": "命"},
                ],
            },
            {
                "orientation": "horizontal",
                "chars": [
                    {"x": 198, "y": 28, "w": 44, "h": 44, "text": "盤"},
                    {"x": 248, "y": 28, "w": 44, "h": 44, "text": "局"},
                    {"x": 298, "y": 28, "w": 44, "h": 44, "text": "圖"},
                ],
            },
        ]
        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(tmp, draw, ocr_lines=ocr)
        texts = [e for e in scene["elements"] if e["type"] == "text"]
        joined = [t["text"] for t in texts]
        self.assertIn("盤局圖", joined)  # 横排整行一个元素
        self.assertEqual(sorted(joined[:3] + joined[3:]),
                         sorted(["斗", "數", "命", "盤局圖"]))
        # 竖排逐字位置=字框
        dou = next(t for t in texts if t["text"] == "斗")
        self.assertAlmostEqual(dou["x"], 28, delta=3)
        self.assertAlmostEqual(dou["y"], 18, delta=3)
        self.assertEqual(stats["chars"], 6)
        self.assertEqual(stats["text_elements"], 4)

    def test_region_offset_and_scale(self):
        """坐标相对区域左上角，scale 生效。"""
        def draw(img):
            cv2.rectangle(img, (110, 60), (200, 150), (0, 0, 0), 2)

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(
                tmp, draw, width=400, height=300,
                region=(100, 50, 200, 200), settings={"scale": 0.5},
            )
        rects = [e for e in scene["elements"] if e["type"] == "rectangle"]
        self.assertEqual(len(rects), 1)
        r = rects[0]
        self.assertAlmostEqual(r["x"], (110 - 100) * 0.5, delta=3)
        self.assertAlmostEqual(r["y"], (60 - 50) * 0.5, delta=3)
        self.assertAlmostEqual(r["width"], 90 * 0.5, delta=4)

    def test_element_schema_fields(self):
        """元素字段齐备（Obsidian Excalidraw 插件直接可开）。"""
        def draw(img):
            cv2.rectangle(img, (30, 40), (220, 180), (0, 0, 0), 2)

        with TemporaryDirectory() as tmp:
            scene, _ = self._scene(tmp, draw, ocr_lines=[{
                "orientation": "horizontal",
                "chars": [{"x": 40, "y": 60, "w": 30, "h": 30, "text": "盤"}],
            }])
        ids = set()
        for el in scene["elements"]:
            for field in (
                "id", "type", "x", "y", "width", "height", "angle",
                "strokeColor", "backgroundColor", "fillStyle", "strokeWidth",
                "strokeStyle", "roughness", "opacity", "groupIds", "seed",
                "version", "versionNonce", "isDeleted", "updated",
            ):
                self.assertIn(field, el, f"{el['type']} 缺 {field}")
            self.assertNotIn(el["id"], ids)
            ids.add(el["id"])
            if el["type"] == "text":
                self.assertIn("originalText", el)
                self.assertIn("fontSize", el)
                self.assertIn("baseline", el)
                self.assertIn("lineHeight", el)
            if el["type"] == "line":
                self.assertIn("points", el)
                self.assertGreaterEqual(len(el["points"]), 2)
        self.assertIn("appState", scene)
        self.assertIn("files", scene)

    # ── v2：格面还原 ──

    def test_grid_becomes_cells(self):
        """网格 → 宫格矩形（墙被格面覆盖不出重复线段），无折线混乱。"""
        def draw(img):
            for i in range(4):
                p = 30 + i * 100
                cv2.line(img, (30, p), (330, p), (0, 0, 0), 2)
                cv2.line(img, (p, 30), (p, 330), (0, 0, 0), 2)

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(tmp, draw, width=400, height=400)
        rects = [e for e in scene["elements"] if e["type"] == "rectangle"]
        lines = [e for e in scene["elements"] if e["type"] == "line"]
        curves = [e for e in scene["elements"] if e["type"] == "line"
                  and len(e["points"]) > 2]
        # 3×3 宫格：9 个矩形，墙全部被消耗（无残留线段）
        self.assertEqual(len(rects), 9, [(r["x"], r["y"]) for r in rects])
        self.assertEqual(len(lines), 0, [e["points"] for e in lines])
        self.assertEqual(len(curves), 0)
        first = sorted(rects, key=lambda r: (r["y"], r["x"]))[0]
        self.assertAlmostEqual(first["x"], 30, delta=4)
        self.assertAlmostEqual(first["y"], 30, delta=4)
        self.assertAlmostEqual(first["width"], 100, delta=5)

    def test_grid_without_rect_detection_keeps_lines(self):
        """detect_rects=False → 格面还原关闭，格线保留为线段。"""
        def draw(img):
            for i in range(4):
                p = 30 + i * 100
                cv2.line(img, (30, p), (330, p), (0, 0, 0), 2)
                cv2.line(img, (p, 30), (p, 330), (0, 0, 0), 2)

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(
                tmp, draw, width=400, height=400,
                settings={"detect_rects": False},
            )
        self.assertEqual(stats["rectangles"], 0)
        self.assertEqual(stats["lines"], 8, stats["lines"])
        self.assertEqual(stats["curves"], 0)

    # ── v2：填充 / 箭头 / 虚线 ──

    def test_filled_block_becomes_filled_rect(self):
        def draw(img):
            cv2.rectangle(img, (50, 50), (130, 110), (0, 0, 0), -1)

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(tmp, draw)
        rects = [e for e in scene["elements"] if e["type"] == "rectangle"]
        self.assertEqual(len(rects), 1)
        self.assertNotEqual(rects[0]["backgroundColor"], "transparent")
        self.assertAlmostEqual(rects[0]["x"], 50, delta=4)
        self.assertAlmostEqual(rects[0]["width"], 80, delta=5)

    def test_arrowhead_attached_to_line(self):
        def draw(img):
            cv2.line(img, (40, 150), (240, 150), (0, 0, 0), 3)
            tri = np.array([[245, 138], [267, 150], [245, 162]], dtype=np.int32)
            cv2.fillPoly(img, [tri], (0, 0, 0))

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(tmp, draw)
        lines = [e for e in scene["elements"] if e["type"] == "line"]
        rects = [e for e in scene["elements"] if e["type"] == "rectangle"]
        self.assertEqual(len(rects), 0, "箭头块不应再出独立矩形")
        self.assertEqual(stats["arrows"], 1)
        arrowed = [e for e in lines if e.get("endArrowhead") == "arrow"]
        self.assertEqual(len(arrowed), 1)
        # 箭头线本体 ≈ (40,150)-(240,150)
        el = arrowed[0]
        (x1, y1), (x2, y2) = el["points"][0], el["points"][-1]
        self.assertAlmostEqual(el["x"] + x1, 40, delta=6)
        self.assertAlmostEqual(el["y"] + y1, 150, delta=5)
        self.assertAlmostEqual(el["x"] + x2, 240, delta=10)

    def test_dashed_line_detected(self):
        def draw(img):
            x = 30
            while x < 330:
                cv2.line(img, (x, 100), (min(x + 12, 330), 100), (0, 0, 0), 3)
                x += 22

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(tmp, draw)
        lines = [e for e in scene["elements"] if e["type"] == "line"]
        self.assertEqual(len(lines), 1, [e["points"] for e in lines])
        self.assertEqual(lines[0]["strokeStyle"], "dashed")
        self.assertEqual(stats["dashed"], 1)

    # ── v2：取色 ──

    def test_color_detection_and_mono_mode(self):
        def draw(img):
            cv2.rectangle(img, (40, 40), (240, 160), (181, 54, 156), 3)  # 紫

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(tmp, draw)
        rects = [e for e in scene["elements"] if e["type"] == "rectangle"]
        self.assertEqual(len(rects), 1)
        self.assertEqual(rects[0]["strokeColor"], "#9c36b5")
        self.assertEqual(stats["colored"], 1)

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(
                tmp, draw, settings={"color_mode": "mono"},
            )
        rects = [e for e in scene["elements"] if e["type"] == "rectangle"]
        self.assertEqual(rects[0]["strokeColor"], "#1e1e1e")

    # ── v2：底图嵌入 / 数据注入 ──

    def test_embed_image(self):
        def draw(img):
            cv2.rectangle(img, (30, 40), (220, 180), (0, 0, 0), 2)

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(
                tmp, draw, settings={"embed_image": True},
            )
        self.assertTrue(scene["files"])
        first = scene["elements"][0]
        self.assertEqual(first["type"], "image")
        self.assertAlmostEqual(first["width"], 400, delta=1)
        self.assertAlmostEqual(first["height"], 300, delta=1)
        self.assertTrue(first["locked"])
        entry = next(iter(scene["files"].values()))
        self.assertTrue(entry["dataURL"].startswith("data:image/png;base64,"))

    def test_injected_lines_skip_recognition(self):
        """注入 ocr_lines 时不触发区域重识别（_recognize_region 不被调用）。"""
        def draw(img):
            cv2.rectangle(img, (30, 40), (220, 180), (0, 0, 0), 2)

        original = excalidraw_scene._recognize_region

        def _boom(*args, **kwargs):
            raise AssertionError("注入数据时不应触发区域重识别")

        excalidraw_scene._recognize_region = _boom
        try:
            with TemporaryDirectory() as tmp:
                image_path = FsPath(tmp) / "page.png"
                img = np.full((300, 400, 3), 255, dtype=np.uint8)
                cv2.rectangle(img, (30, 40), (220, 180), (0, 0, 0), 2)
                cv2.imwrite(str(image_path), img)
                scene, stats = region_to_excalidraw(
                    str(image_path), (0, 0, 400, 300),
                    ocr_lines=[{
                        "orientation": "vertical",
                        "chars": [
                            {"x": 40, "y": 50, "w": 30, "h": 30, "text": "盤"},
                        ],
                    }],
                )
        finally:
            excalidraw_scene._recognize_region = original
        texts = [e for e in scene["elements"] if e["type"] == "text"]
        self.assertEqual(len(texts), 1)
        self.assertEqual(stats["rectangles"], 1)

    # ── v2：设置项 ──

    def test_min_char_conf_filters_low_confidence_chars(self):
        def draw(img):
            for cx in (50, 150):
                cv2.rectangle(img, (cx, 50), (cx + 40, 90), (0, 0, 0), -1)

        ocr = [{
            "orientation": "horizontal",
            "chars": [
                {"x": 48, "y": 48, "w": 44, "h": 44, "text": "斗", "conf": 0.2},
                {"x": 148, "y": 48, "w": 44, "h": 44, "text": "數", "conf": 0.9},
            ],
        }]
        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(
                tmp, draw, ocr_lines=ocr, settings={"min_char_conf": 0.5},
            )
        texts = [e for e in scene["elements"] if e["type"] == "text"]
        self.assertEqual([t["text"] for t in texts], ["數"])
        # 低置信字的墨迹仍被抠掉（不出图形）
        self.assertEqual(stats["rectangles"], 0)

    def test_ink_coverage_reflects_text_masking(self):
        """纯文字 + 字框掩膜 → 覆盖率高（文字墨迹被字框覆盖）。"""
        def draw(img):
            cv2.rectangle(img, (50, 50), (94, 94), (0, 0, 0), -1)

        ocr = [{
            "orientation": "vertical",
            "chars": [
                {"x": 48, "y": 48, "w": 48, "h": 48, "text": "斗"},
            ],
        }]
        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(tmp, draw, ocr_lines=ocr)
        self.assertGreaterEqual(stats["ink_coverage"], 0.9)

    # ── v3：手画文字框 / 文字元数据 / 过程图 ──

    def test_text_box_marks_zone_as_text(self):
        """手画文字框：框内墨迹按文字处理（无既有字 → 按框单独识别）。"""
        def draw(img):
            # 一个"文字"墨块 + 一条横线
            cv2.rectangle(img, (100, 50), (140, 90), (0, 0, 0), -1)
            cv2.line(img, (20, 200), (380, 200), (0, 0, 0), 2)

        original = excalidraw_scene._recognize_region

        def fake_recognize(path, rect, *args, **kwargs):
            x, y, w, h = rect
            return [{
                "orientation": "vertical",
                "chars": [{
                    "x": x + 2, "y": y + 2, "w": w - 4, "h": h - 4,
                    "text": "註", "conf": 0.9,
                }],
            }]

        excalidraw_scene._recognize_region = fake_recognize
        try:
            with TemporaryDirectory() as tmp:
                image_path = FsPath(tmp) / "page.png"
                img = np.full((300, 400, 3), 255, dtype=np.uint8)
                draw(img)
                cv2.imwrite(str(image_path), img)
                scene, stats = region_to_excalidraw(
                    str(image_path), (0, 0, 400, 300),
                    ocr_lines=[],
                    text_boxes=[{"x": 98, "y": 48, "w": 44, "h": 44}],
                )
        finally:
            excalidraw_scene._recognize_region = original
        texts = [e for e in scene["elements"] if e["type"] == "text"]
        self.assertEqual([t["text"] for t in texts], ["註"])
        # 框内墨迹已按文字抠除：不出现填充矩形
        self.assertEqual(stats["rectangles"], 0, stats["rectangles"])
        # 文字元数据与场景 text 元素同序
        self.assertEqual(len(stats["text_meta"]), 1)
        self.assertEqual(stats["text_meta"][0]["kind"], "char")
        self.assertEqual(stats["text_meta"][0]["conf"], 0.9)

    def test_text_box_reuses_existing_chars(self):
        """框内已有识别字 → 不触发按框重识别（_recognize_region 不被调）。"""
        def draw(img):
            cv2.rectangle(img, (100, 50), (140, 90), (0, 0, 0), -1)

        def _boom(*args, **kwargs):
            raise AssertionError("框内已有字时不应按框重识别")

        original = excalidraw_scene._recognize_region
        excalidraw_scene._recognize_region = _boom
        try:
            with TemporaryDirectory() as tmp:
                scene, stats = self._scene(
                    tmp, draw,
                    ocr_lines=[{
                        "orientation": "vertical",
                        "chars": [{
                            "x": 98, "y": 48, "w": 44, "h": 44,
                            "text": "斗", "conf": 0.9,
                        }],
                    }],
                    text_boxes=[{"x": 90, "y": 40, "w": 70, "h": 70}],
                )
        finally:
            excalidraw_scene._recognize_region = original
        texts = [e for e in scene["elements"] if e["type"] == "text"]
        self.assertEqual([t["text"] for t in texts], ["斗"])

    def test_debug_images_returned(self):
        def draw(img):
            cv2.rectangle(img, (30, 40), (220, 180), (0, 0, 0), 2)

        with TemporaryDirectory() as tmp:
            scene, stats = self._scene(
                tmp, draw, debug_images=True,
            )
        imgs = stats.get("debug_images")
        self.assertIsNotNone(imgs)
        self.assertEqual(len(imgs), 4)
        for item in imgs:
            self.assertTrue(item["data_url"].startswith("data:image/png;base64,"))
            self.assertTrue(item["name"])


if __name__ == "__main__":
    unittest.main()
