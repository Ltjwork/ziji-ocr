# -*- coding: utf-8 -*-
"""smart_merge 单测：构型几何纯逻辑 + 合成图上端到端扫描。

模板=手工合并前的两框（上「I」下「H」的竖排拆分对）。合成目标页里放：
同形对（应命中）、异形对（HOG 拒）、同形但间距悬殊（几何拒）、同形但
已确认（保护拒）、三连同形（贪心互斥只合并一次）。运行：pytest 或
python test_smart_merge.py。
"""

import os
import tempfile
import unittest

import cv2
import numpy as np

import smart_merge


class _Block:
    def __init__(self, bid, x, y, w, h, confirmed=False, box_confirmed=False):
        self.id = bid
        self.x, self.y, self.w, self.h = x, y, w, h
        self.confirmed = confirmed
        self.box_confirmed = box_confirmed


class _Line:
    def __init__(self, direction, blocks):
        self.dir = direction
        self.blocks = blocks


class _Page:
    def __init__(self, page_id, image_path, lines):
        self.page_id = page_id
        self.image_path = image_path
        self.lines = lines


_CELL = 112  # 字框边长（含边距），与聚类测试同口径


def _draw_glyph(img, ch, x, y):
    """在 (x, y) 起始的单元格画黑字，返回字框 (x-6, y-6, 112, 112)。"""
    cv2.putText(
        img, ch, (x, y + 80), cv2.FONT_HERSHEY_SIMPLEX, 3.0, 0, 12, cv2.LINE_AA
    )
    return (x - 6, y - 6, _CELL, _CELL)


def _make_page(path, pairs, seed=7):
    """pairs: [(block_top_id, block_bottom_id, top_ch, bottom_ch, gap, confirmed)]，
    每对占一列网格。返回 lines（每对一个 ttb 行，阅读序 top→bottom）。"""
    rng = np.random.default_rng(seed)
    img = np.full((1000, 800), 255, dtype=np.uint8)
    lines = []
    for col, (tid, bid, top_ch, bot_ch, gap, confirmed) in enumerate(pairs):
        x = 40 + col * 180 + int(rng.integers(-4, 4))
        y = 60 + int(rng.integers(-4, 4))
        r1 = _draw_glyph(img, top_ch, x, y)
        r2 = _draw_glyph(img, bot_ch, x, y + _CELL + gap)
        lines.append(
            _Line(
                "ttb",
                [
                    _Block(tid, *r1, confirmed=confirmed),
                    _Block(bid, *r2, box_confirmed=confirmed),
                ],
            )
        )
    cv2.imwrite(path, img)
    return lines


def _template(path, gap=8):
    """模板页：一处「I / H」竖排拆分对。"""
    img = np.full((400, 400), 255, dtype=np.uint8)
    r1 = _draw_glyph(img, "I", 100, 60)
    r2 = _draw_glyph(img, "H", 100, 60 + _CELL + gap)
    cv2.imwrite(path, img)
    return r1, r2


class PairGeometryTests(unittest.TestCase):
    def test_ttb_gap_and_overlap(self):
        a = _Block("a", 100, 0, 20, 30)
        b = _Block("b", 102, 34, 20, 30)
        g = smart_merge.pair_geometry(a, b, "ttb")
        self.assertAlmostEqual(g["overlap"], 18 / 20)  # 交叠 18px / min(w)=20
        self.assertAlmostEqual(g["gap"], 4 / 30)
        self.assertAlmostEqual(g["read_ratio"], 1.0)
        self.assertAlmostEqual(g["cross_ratio"], 1.0)

    def test_rtl_first_is_right(self):
        # rtl：first 在右，阅读轴向左；gap = first.x - (second 右缘)
        a = _Block("a", 200, 10, 30, 20)  # 在右
        b = _Block("b", 160, 10, 30, 20)  # 在左
        g = smart_merge.pair_geometry(a, b, "rtl")
        self.assertAlmostEqual(g["gap"], 10 / 30)
        self.assertAlmostEqual(g["overlap"], 1.0)

    def test_degenerate_returns_none(self):
        a = _Block("a", 0, 0, 0, 30)
        self.assertIsNone(smart_merge.pair_geometry(a, a, "ttb"))

    def test_geometry_matches_tolerances(self):
        t = {"overlap": 1.0, "gap": 0.1, "read_ratio": 1.0, "cross_ratio": 1.0}
        ok = {"overlap": 0.9, "gap": 0.3, "read_ratio": 1.5, "cross_ratio": 0.8}
        self.assertTrue(smart_merge.geometry_matches(t, ok))
        far = {"overlap": 0.9, "gap": 0.8, "read_ratio": 1.0, "cross_ratio": 1.0}
        self.assertFalse(smart_merge.geometry_matches(t, far))  # 间距悬殊
        offset = {"overlap": 0.3, "gap": 0.1, "read_ratio": 1.0, "cross_ratio": 1.0}
        self.assertFalse(smart_merge.geometry_matches(t, offset))  # 不同列
        huge = {"overlap": 0.9, "gap": 0.1, "read_ratio": 3.0, "cross_ratio": 1.0}
        self.assertFalse(smart_merge.geometry_matches(t, huge))  # 尺寸比悬殊


class ScanTests(unittest.TestCase):
    def test_scan_finds_similar_and_skips_protected(self):
        with tempfile.TemporaryDirectory() as tmp:
            tpath = os.path.join(tmp, "tpl.png")
            r1, r2 = _template(tpath)
            p1 = os.path.join(tmp, "p1.png")
            lines = _make_page(
                p1,
                [
                    ("t1", "b1", "I", "H", 8, False),  # 同形同距：命中
                    ("t2", "b2", "O", "Z", 8, False),  # 异形：HOG 拒
                    ("t3", "b3", "I", "H", 140, False),  # 同形远距：几何拒
                    ("t4", "b4", "I", "H", 8, True),  # 同形但已确认：保护拒
                ],
            )
            result = smart_merge.scan_smart_merge(
                tpath, [r1, r2], "ttb", [_Page("p1", p1, lines)]
            )
            self.assertEqual(result["failed_pages"], [])
            ids = {m["first_id"] for m in result["matches"]}
            self.assertEqual(ids, {"t1"})
            m = result["matches"][0]
            self.assertEqual(m["second_id"], "b1")
            self.assertLessEqual(m["score"], 0.18)
            # 合并矩形 = 命中对的并集（坐标带随机抖动，从行数据推导期望）
            hit = lines[0].blocks
            self.assertEqual(
                tuple(m["merged"]),
                (
                    min(hit[0].x, hit[1].x),
                    min(hit[0].y, hit[1].y),
                    max(hit[0].x + hit[0].w, hit[1].x + hit[1].w)
                    - min(hit[0].x, hit[1].x),
                    max(hit[0].y + hit[0].h, hit[1].y + hit[1].h)
                    - min(hit[0].y, hit[1].y),
                ),
            )

    def test_template_order_independent(self):
        with tempfile.TemporaryDirectory() as tmp:
            tpath = os.path.join(tmp, "tpl.png")
            r1, r2 = _template(tpath)
            p1 = os.path.join(tmp, "p1.png")
            lines = _make_page(p1, [("t1", "b1", "I", "H", 8, False)])
            a = smart_merge.scan_smart_merge(
                tpath, [r1, r2], "ttb", [_Page("p1", p1, lines)]
            )
            b = smart_merge.scan_smart_merge(
                tpath, [r2, r1], "ttb", [_Page("p1", p1, lines)]
            )
            self.assertEqual(a["matches"], b["matches"])  # 传入顺序不影响

    def test_triple_stack_merges_once(self):
        # 三连同形：相邻对 (a,b)/(b,c) 都满足 → 贪心互斥只保留一个
        with tempfile.TemporaryDirectory() as tmp:
            tpath = os.path.join(tmp, "tpl.png")
            img = np.full((400, 400), 255, dtype=np.uint8)
            rt1 = _draw_glyph(img, "I", 100, 40)
            rt2 = _draw_glyph(img, "I", 100, 40 + _CELL + 8)
            cv2.imwrite(tpath, img)

            p1 = os.path.join(tmp, "p1.png")
            img = np.full((700, 400), 255, dtype=np.uint8)
            ra = _draw_glyph(img, "I", 100, 40)
            rb = _draw_glyph(img, "I", 100, 40 + _CELL + 8)
            rc = _draw_glyph(img, "I", 100, 40 + (_CELL + 8) * 2)
            cv2.imwrite(p1, img)
            line = _Line(
                "ttb", [_Block("a", *ra), _Block("b", *rb), _Block("c", *rc)]
            )
            result = smart_merge.scan_smart_merge(
                tpath, [rt1, rt2], "ttb", [_Page("p1", p1, [line])]
            )
            self.assertEqual(len(result["matches"]), 1)
            used = {
                result["matches"][0]["first_id"],
                result["matches"][0]["second_id"],
            }
            self.assertNotEqual(used, {"a", "b", "c"})
            self.assertEqual(len(used), 2)

    def test_dir_mismatch_skipped(self):
        # 模板 ttb、目标行 ltr：构型不可比，不匹配
        with tempfile.TemporaryDirectory() as tmp:
            tpath = os.path.join(tmp, "tpl.png")
            r1, r2 = _template(tpath)
            p1 = os.path.join(tmp, "p1.png")
            lines = _make_page(p1, [("t1", "b1", "I", "H", 8, False)])
            lines[0].dir = "ltr"
            result = smart_merge.scan_smart_merge(
                tpath, [r1, r2], "ttb", [_Page("p1", p1, lines)]
            )
            self.assertEqual(result["matches"], [])


class SplitScanTests(unittest.TestCase):
    @staticmethod
    def _stack_box(img, top_ch, bot_ch, x, y, gap=8):
        """画"两字叠一框"（Alt 拆分的模板形态），返回整框矩形。"""
        _draw_glyph(img, top_ch, x, y)
        _draw_glyph(img, bot_ch, x, y + _CELL + gap)
        return (x - 6, y - 6, _CELL, _CELL * 2 + gap)

    @staticmethod
    def _single_box(img, ch, x, y):
        _draw_glyph(img, ch, x, y)
        return (x - 6, y - 6, _CELL, _CELL)

    def _make_page(self, path, items, seed=11):
        """items: [(block_id, (top_ch, bot_ch|None), confirmed)]，每个一列。"""
        rng = np.random.default_rng(seed)
        img = np.full((900, 800), 255, dtype=np.uint8)
        lines = []
        for col, (bid, chars, confirmed) in enumerate(items):
            x = 40 + col * 180 + int(rng.integers(-4, 4))
            y = 60 + int(rng.integers(-4, 4))
            if chars[1] is None:
                r = self._single_box(img, chars[0], x, y)
            else:
                r = self._stack_box(img, chars[0], chars[1], x, y)
            lines.append(
                _Line("ttb", [_Block(bid, *r, confirmed=confirmed)])
            )
        cv2.imwrite(path, img)
        return lines

    def test_split_finds_similar_stack_and_skips_protected(self):
        with tempfile.TemporaryDirectory() as tmp:
            tpath = os.path.join(tmp, "tpl.png")
            timg = np.full((600, 400), 255, dtype=np.uint8)
            trect = self._stack_box(timg, "I", "H", 100, 60)
            cv2.imwrite(tpath, timg)

            p1 = os.path.join(tmp, "p1.png")
            lines = self._make_page(
                p1,
                [
                    ("d1", ("I", "H"), False),  # 同形叠字框：命中
                    ("s1", ("O", None), False),  # 普通单字框：HOG 拒
                    ("d2", ("I", "H"), True),  # 同形但已确认：保护拒
                ],
            )
            result = smart_merge.scan_smart_split(
                tpath, trect, [_Page("p1", p1, lines)]
            )
            self.assertEqual(result["failed_pages"], [])
            self.assertEqual(len(result["matches"]), 1)
            m = result["matches"][0]
            self.assertEqual((m["page_id"], m["block_id"]), ("p1", "d1"))
            self.assertLessEqual(m["score"], 0.18)

    def test_split_blank_template_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            blank = os.path.join(tmp, "blank.png")
            cv2.imwrite(blank, np.full((200, 200), 255, dtype=np.uint8))
            with self.assertRaises(ValueError):
                smart_merge.scan_smart_split(
                    blank, (10, 10, 50, 50), []
                )


if __name__ == "__main__":
    unittest.main()
