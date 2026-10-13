# -*- coding: utf-8 -*-
"""版面区预标注测试：规则建议（顶底条带/孤立短列/跨页同位重复/只填空）、
区域几何精修（钳制/墨迹收紧/词表校验/近重复）、VLM 素材图。"""
import json
import os
import shutil
import tempfile
import unittest

import cv2
import numpy as np

import region_prelabel
from region_prelabel import (prelabel_page_image, refine_regions,
                             suggest_regions)


def _make_page(root: str, book: str, page_id: str, *, header=True,
               header_text="", pageno=True, body=True, margin_note=False,
               existing_regions=None, header_repeat=False):
    """合成书页：天头页眉带 / 天头眉批小字列 / 中部正文列 / 地脚页码块。

    返回 (book_dir, image_path)。header_repeat=True 时页眉文字在相邻页
    同位置重复（跨页同位信号）。"""
    book_dir = os.path.join(root, book)
    ann_dir = os.path.join(book_dir, "annotations")
    os.makedirs(ann_dir, exist_ok=True)
    if not os.path.exists(os.path.join(book_dir, "project.json")):
        with open(os.path.join(book_dir, "project.json"), "w",
                  encoding="utf-8") as f:
            json.dump({"id": book, "settings": {}}, f, ensure_ascii=False)
    gray = np.full((400, 300), 255, dtype=np.uint8)
    lines = []

    def _draw_words(x, y, w, h, n, text):
        """在 (x,y,w,h) 内画 n 个字块，并生成对应行标注。
        墨迹用小字块而非实心大块：_remove_ruling_lines 会把 ≥h/4 的
        长实心条当栏线清除，实心块合成页过不了墨迹 mask。"""
        for i in range(n):
            cx = x + i * (w // max(1, n))
            cw = max(6, w // max(1, n) - 3)
            cv2.rectangle(gray, (cx, y), (cx + cw, y + h), 0, -1)
        lines.append({"id": f"l_{y}", "x": x, "y": y, "w": w, "h": h,
                      "chars": [{"x": x, "y": y, "w": w, "h": h,
                                 "text": text}]})

    if margin_note:
        # 天头两列小字（眉批）：列高低、多簇
        _draw_words(30, 8, 60, 14, 3, "批注甲")
        _draw_words(120, 8, 60, 14, 3, "批注乙")
    elif header:
        # 顶部页眉带（单簇，宽度较窄）
        _draw_words(100, 10, 100, 22, 4, header_text or "礼记卷第一")
    if body:
        # 中部正文列：一列小字块（y 100~320，行高高）× 8
        for i in range(8):
            _draw_words(120, 100 + i * 27, 60, 22, 1, "正")
    if pageno:
        # 底部页码短块
        _draw_words(140, 370, 24, 20, 1, "三")
    img_path = os.path.join(book_dir, f"{page_id}.png")
    cv2.imwrite(img_path, gray)
    ann = {"page_id": page_id, "image_path": img_path,
           "main_regions": existing_regions or [], "lines": lines,
           "paragraphs": [], "blocks": []}
    with open(os.path.join(ann_dir, f"{page_id}.json"), "w",
              encoding="utf-8") as f:
        json.dump(ann, f, ensure_ascii=False)
    return book_dir, img_path


class SuggestRegionsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="prelabel_")

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_top_band_suggests_header_and_bottom_short_block_page_number(self):
        _make_page(self._tmp, "bookA", "page_000")
        result = suggest_regions(os.path.join(self._tmp, "bookA"), "page_000")
        labels = [s["label"] for s in result["suggestions"]]
        self.assertIn("header", labels)
        self.assertIn("page_number", labels)
        header = next(s for s in result["suggestions"] if s["label"] == "header")
        # 页眉建议框应贴着顶部条带（y 在顶部 15% 内）
        self.assertLessEqual(header["y"] + header["h"], 400 * 0.15 + 1)

    def test_cross_page_repeat_boosts_confidence(self):
        _make_page(self._tmp, "bookB", "page_000", header_text="礼记卷第一")
        _make_page(self._tmp, "bookB", "page_001", header_text="礼记卷第一")
        result = suggest_regions(os.path.join(self._tmp, "bookB"), "page_001")
        header = next(s for s in result["suggestions"] if s["label"] == "header")
        self.assertIn("跨页同位重复", header["reason"])
        self.assertGreaterEqual(header["confidence"], 0.7)

    def test_margin_note_multi_cluster_low_band(self):
        _make_page(self._tmp, "bookC", "page_000", header=False,
                   margin_note=True)
        result = suggest_regions(os.path.join(self._tmp, "bookC"), "page_000")
        notes = [s for s in result["suggestions"]
                 if s["label"] == "margin_note"]
        self.assertTrue(notes)
        self.assertLess(notes[0]["confidence"], 0.6)  # 低置信，等人工确认

    def test_existing_regions_are_not_duplicated(self):
        # 已有 header 区覆盖顶部条带 → 不再建议（只填空）
        _make_page(self._tmp, "bookD", "page_000",
                   existing_regions=[{"id": "mr1", "x": 90, "y": 5, "w": 120,
                                      "h": 30, "label": "header",
                                      "status": "confirmed"}])
        result = suggest_regions(os.path.join(self._tmp, "bookD"), "page_000")
        self.assertNotIn("header",
                         [s["label"] for s in result["suggestions"]])

    def test_body_band_touching_strip_is_not_header(self):
        # 正文带顶到条带边缘（高条带）→ 不误报页眉
        book_dir = os.path.join(self._tmp, "bookE")
        os.makedirs(os.path.join(book_dir, "annotations"), exist_ok=True)
        with open(os.path.join(book_dir, "project.json"), "w",
                  encoding="utf-8") as f:
            json.dump({"id": "bookE", "settings": {}}, f, ensure_ascii=False)
        gray = np.full((400, 300), 255, dtype=np.uint8)
        # 一根从 y=10 到 y=300 的大墨迹柱（正文，不是页眉）
        cv2.rectangle(gray, (120, 10), (180, 300), 0, -1)
        img_path = os.path.join(book_dir, "page_000.png")
        cv2.imwrite(img_path, gray)
        ann = {"page_id": "page_000", "image_path": img_path,
               "main_regions": [], "lines": [], "paragraphs": [], "blocks": []}
        with open(os.path.join(book_dir, "annotations", "page_000.json"),
                  "w", encoding="utf-8") as f:
            json.dump(ann, f, ensure_ascii=False)
        result = suggest_regions(book_dir, "page_000")
        self.assertEqual(result["suggestions"], [])

    def test_missing_page_raises_value_error(self):
        _make_page(self._tmp, "bookF", "page_000")
        with self.assertRaises(ValueError):
            suggest_regions(os.path.join(self._tmp, "bookF"), "page_999")


class RefineRegionsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="refine_")
        gray = np.full((200, 200), 255, dtype=np.uint8)
        # 真实墨迹簇：2×2 小字块群，包围盒 (60,60)-(120,120)
        for bx in (60, 92):
            for by in (60, 92):
                cv2.rectangle(gray, (bx, by), (bx + 28, by + 28), 0, -1)
        self._img = os.path.join(self._tmp, "page.png")
        cv2.imwrite(self._img, gray)

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_tightens_to_ink_and_clamps_bounds(self):
        result = refine_regions(self._img, [
            {"x": 10, "y": 10, "w": 500, "h": 500, "label": "main_text"},
        ])
        self.assertEqual(len(result["regions"]), 1)
        r = result["regions"][0]
        # 收紧到墨迹包围盒（ink_rect 有 ≤3px 上下文余量）
        self.assertAlmostEqual(r["x"], 60, delta=6)
        self.assertAlmostEqual(r["y"], 60, delta=6)
        self.assertAlmostEqual(r["w"], 61, delta=8)
        self.assertAlmostEqual(r["h"], 61, delta=8)

    def test_blank_region_dropped(self):
        result = refine_regions(self._img, [
            {"x": 150, "y": 150, "w": 40, "h": 40, "label": "header"},
        ])
        self.assertEqual(result["regions"], [])
        self.assertIn("无结构性墨迹", result["dropped"][0]["reason"])

    def test_unknown_label_dropped(self):
        result = refine_regions(self._img, [
            {"x": 60, "y": 60, "w": 61, "h": 61, "label": " Marginalia "},
        ])
        self.assertEqual(result["regions"], [])
        self.assertIn("类别不在词表", result["dropped"][0]["reason"])

    def test_near_duplicate_same_label_removed(self):
        base = {"x": 55, "y": 55, "w": 70, "h": 70}
        result = refine_regions(self._img, [
            {**base, "label": "main_text", "confidence": 0.6},
            {**base, "label": "main_text", "confidence": 0.9},
        ])
        self.assertEqual(len(result["regions"]), 1)
        self.assertEqual(result["regions"][0]["confidence"], 0.9)
        self.assertEqual(len(result["dropped"]), 1)


class PagePrelabelImageTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="preimg_")
        gray = np.full((1000, 800), 255, dtype=np.uint8)
        cv2.rectangle(gray, (100, 100), (700, 900), 0, -1)
        self._img = os.path.join(self._tmp, "page.png")
        cv2.imwrite(self._img, gray)

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_downscales_and_reports_grid(self):
        result = prelabel_page_image(self._img, [], max_side=400)
        self.assertLessEqual(max(result["width"], result["height"]), 400)
        self.assertEqual(result["grid"], {"cols": 8, "rows": 8})
        self.assertGreater(len(result["image_base64"]), 100)
        self.assertEqual(result["orig_width"], 800)

    def test_existing_regions_accepted_without_error(self):
        result = prelabel_page_image(self._img, [
            {"x": 100, "y": 100, "w": 600, "h": 800, "label": "main_text"},
            {"x": 0, "y": 0, "w": 800, "h": 60, "label": "header"},
        ], max_side=300)
        self.assertTrue(result["image_base64"])

    def test_missing_image_raises(self):
        with self.assertRaises(ValueError):
            prelabel_page_image(os.path.join(self._tmp, "nope.png"), [])


class VerticalPageTests(unittest.TestCase):
    """竖排书页：正文列几乎每行都有墨，_y_bands 聚不出"条带 vs 正文"的
    层次——书耳/天头眉批列/边栏书名/版心题名叶码这些竖排短列此前要么
    空转、要么被横排规则并成一个横向大框（用户实测"识别的都是横向的"）。
    """

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="prelabel_v_")

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _vertical_page(self, book, page_id, *, body_xs=(95, 135, 175, 215),
                       header_xs=(), header_text="禮記卷第一",
                       pageno_x=None, pageno_text="三", side_x=None,
                       side_text="禮記", spine=False):
        """合成竖排书页（300×400）：正文列 8 字块/列（y 90~321），可选
        天头书眉竖列（y 8~53）、地脚叶码竖列（y 368~389）、边栏书名竖列
        （y 150~218，页面中部、不落在顶/底条带、明显矮于正文列）、版心
        题名+叶码（x=139，页面中线，y 70~107 / 300~321）。"""
        book_dir = os.path.join(self._tmp, book)
        os.makedirs(os.path.join(book_dir, "annotations"), exist_ok=True)
        if not os.path.exists(os.path.join(book_dir, "project.json")):
            with open(os.path.join(book_dir, "project.json"), "w",
                      encoding="utf-8") as f:
                json.dump({"id": book, "settings": {}}, f, ensure_ascii=False)
        gray = np.full((400, 300), 255, dtype=np.uint8)
        lines = []

        def _column(x, y0, n, block_h, pitch, text=""):
            for i in range(n):
                y = y0 + i * pitch
                cv2.rectangle(gray, (x, y), (x + 21, y + block_h - 1), 0, -1)
            if text:
                h = (n - 1) * pitch + block_h
                lines.append({"id": f"l_{page_id}_{x}_{y0}", "x": x, "y": y0,
                              "w": 22, "h": h,
                              "chars": [{"x": x, "y": y0, "w": 22, "h": h,
                                         "text": text}]})

        for bx in body_xs:
            _column(bx, 90, 8, 22, 30)
        for i, hx in enumerate(header_xs):
            _column(hx, 8, 3, 14, 16, text=header_text if i == 0 else "批注")
        if pageno_x is not None:
            _column(pageno_x, 368, 1, 22, 22, text=pageno_text)
        if side_x is not None:
            _column(side_x, 150, 4, 14, 17, text=side_text)
        if spine:
            _column(139, 70, 2, 18, 20, text="禮記")   # 版心题名（上半）
            _column(139, 300, 1, 22, 22, text="三")    # 版心叶码（下半）
        img_path = os.path.join(book_dir, f"{page_id}.png")
        cv2.imwrite(img_path, gray)
        ann = {"page_id": page_id, "image_path": img_path,
               "image_width": 300, "image_height": 400,
               "main_regions": [], "lines": lines,
               "paragraphs": [], "blocks": []}
        with open(os.path.join(book_dir, "annotations", f"{page_id}.json"),
                  "w", encoding="utf-8") as f:
            json.dump(ann, f, ensure_ascii=False)
        return book_dir

    def test_header_and_pageno_columns_above_below_body(self):
        # 书眉列在正文列正上方、叶码列在正文列正下方（同 x）——横排条带
        # 路径靠空行带碰巧兜住，竖排路径逐列出同款框且不重复。
        book = self._vertical_page("bookV1", "page_000",
                                   header_xs=(135,), pageno_x=175)
        result = suggest_regions(book, "page_000")
        headers = [s for s in result["suggestions"]
                   if s["label"] == "header" and s["y"] < 60]
        pagenos = [s for s in result["suggestions"]
                   if s["label"] == "page_number"]
        self.assertEqual(len(headers), 1)
        self.assertEqual(len(pagenos), 1)
        self.assertAlmostEqual(headers[0]["x"], 135, delta=2)
        self.assertGreater(pagenos[0]["y"], 340)
        self.assertAlmostEqual(pagenos[0]["x"], 175, delta=2)

    def test_multi_top_columns_not_merged_into_wide_box(self):
        # 天头两列小字：旧横排规则并成一个 ~150px 宽的横向大框，竖排路径
        # 必须逐列出框（每框宽 ≤ 80）。
        book = self._vertical_page("bookV2", "page_000",
                                   header_xs=(30, 215))
        result = suggest_regions(book, "page_000")
        tops = [s for s in result["suggestions"] if s["y"] < 60]
        self.assertGreaterEqual(len(tops), 2)
        for s in tops:
            self.assertLessEqual(s["w"], 80)

    def test_side_column_mid_height_suggested(self):
        # 边栏书名竖列（页面中部、左右边条内）——不在顶/底条带，横排规则
        # 完全看不到；竖排路径按边栏短列报 margin_note。
        book = self._vertical_page("bookV3", "page_000", side_x=262)
        result = suggest_regions(book, "page_000")
        sides = [s for s in result["suggestions"] if s["x"] >= 255]
        self.assertTrue(sides)
        self.assertEqual(sides[0]["label"], "margin_note")
        self.assertIn("边栏", sides[0]["reason"])

    def test_spine_title_and_leaf_number_suggested(self):
        # 版心题名（上半）+叶码（下半）：夹在左右半叶正文之间，横排规则
        # 看不到；竖排路径按版心短列报 header / page_number。
        book = self._vertical_page("bookV4", "page_000", spine=True,
                                   body_xs=(60, 100, 200, 240))
        result = suggest_regions(book, "page_000")
        labels = [(s["label"], s["reason"]) for s in result["suggestions"]]
        self.assertTrue(any(l == "header" and "版心" in r for l, r in labels))
        self.assertTrue(any(l == "page_number" and "版心" in r
                            for l, r in labels))

    def test_cross_page_repeat_boosts_vertical_column(self):
        # 相邻页同 x 位置同文字的书眉列 → 跨页同位重复加权（比 x，不比 y）。
        for pid in ("page_000", "page_001"):
            self._vertical_page("bookV5", pid, header_xs=(95,))
        result = suggest_regions(os.path.join(self._tmp, "bookV5"),
                                 "page_001")
        header = next(s for s in result["suggestions"]
                      if s["label"] == "header")
        self.assertIn("跨页同位重复", header["reason"])
        self.assertGreaterEqual(header["confidence"], 0.7)

    def test_body_columns_alone_produce_nothing(self):
        # 只有正文列的竖排页：不因新路径误报（版心容差覆盖中线列，但正文
        # 列整簇贯穿中部、过不了"短列"高度关）。
        book = self._vertical_page("bookV6", "page_000")
        result = suggest_regions(book, "page_000")
        self.assertEqual(result["suggestions"], [])


class RegionPrelabelEndpointTests(unittest.TestCase):
    """/region_prelabel HTTP 层回归：纯函数测试覆盖不到路由挂载与
    模块名遮蔽这类端点级错误（曾因处理函数与模块同名 def 遮蔽 import，
    端点每次调用 500 而纯函数测试全绿）。"""

    def setUp(self):
        from fastapi.testclient import TestClient

        from main import app

        self.client = TestClient(app)
        self._tmp = tempfile.mkdtemp(prefix="prelabel_api_")
        self.addCleanup(shutil.rmtree, self._tmp, ignore_errors=True)

    def test_endpoint_returns_suggestions(self):
        _make_page(self._tmp, "bookAPI", "page_000")
        r = self.client.post("/region_prelabel", json={
            "project_dir": os.path.join(self._tmp, "bookAPI"),
            "page_id": "page_000",
        })
        self.assertEqual(r.status_code, 200)
        labels = [s["label"] for s in r.json()["suggestions"]]
        self.assertIn("header", labels)

    def test_endpoint_missing_page_is_400_not_500(self):
        _make_page(self._tmp, "bookAPI2", "page_000")
        r = self.client.post("/region_prelabel", json={
            "project_dir": os.path.join(self._tmp, "bookAPI2"),
            "page_id": "page_404",
        })
        self.assertEqual(r.status_code, 400)
        self.assertIn("page_404", r.json()["detail"])


if __name__ == "__main__":
    unittest.main()
