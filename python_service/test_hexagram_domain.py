# -*- coding: utf-8 -*-
"""hexagram_domain 领域规则测试：文王卦序表完整性、已知卦体、爻名、
干支配对、京房纳甲定表、记录校验（两路互证）、SVG 重绘。"""
from __future__ import annotations

import unittest

from hexagram_domain import (
    KING_WEN,
    TRIGRAM_BITS,
    GANZHI_CHARS,
    hexagram_info,
    is_valid_ganzhi_pair,
    najia_for_bits,
    render_svg,
    validate_record,
    yao_name,
)


def _line(pos: int, yang: bool, left: str = "", right: str = "") -> dict:
    return {
        "pos": pos,
        "yang": yang,
        "left": [{"text": ch} for ch in left],
        "right": [{"text": ch} for ch in right],
    }


class KingWenTableTests(unittest.TestCase):
    def test_table_complete_and_unique(self):
        self.assertEqual(len(KING_WEN), 64)
        names = [name for name, _u, _l in KING_WEN]
        self.assertEqual(len(set(names)), 64)
        # 全部 64 种阴阳组合恰好覆盖一次
        combos = {
            TRIGRAM_BITS[lower] + TRIGRAM_BITS[upper]
            for _n, upper, lower in KING_WEN
        }
        self.assertEqual(len(combos), 64)

    def test_known_hexagrams(self):
        cases = {
            "111111": (1, "乾", "乾为天", "䷀", "U+4DC0"),
            "000000": (2, "坤", "坤为地", "䷁", "U+4DC1"),
            "100000": (24, "复", "地雷复", "䷗", "U+4DD7"),
            "011111": (44, "姤", "天风姤", "䷫", "U+4DEB"),
            "110000": (19, "临", "地泽临", "䷒", "U+4DD2"),
            "101010": (63, "既济", "水火既济", "䷾", "U+4DFE"),
            "010101": (64, "未济", "火水未济", "䷿", "U+4DFF"),
        }
        for bits, (num, name, full, glyph, cp) in cases.items():
            info = hexagram_info(bits)
            self.assertEqual(info["king_wen"], num, bits)
            self.assertEqual(info["name"], name, bits)
            self.assertEqual(info["full_name"], full, bits)
            self.assertEqual(info["unicode"], glyph, bits)
            self.assertEqual(info["unicode_cp"], cp, bits)

    def test_bits_order_is_bottom_up(self):
        # 复卦只有初爻是阳：自下而上 100000（若顺序反了会变成 000001=姤）
        info = hexagram_info("100000")
        self.assertEqual(info["name"], "复")
        self.assertEqual(info["yao_names"][0], "初九")
        self.assertEqual(info["yao_names"][1], "六二")

    def test_yao_names(self):
        self.assertEqual(yao_name(1, True), "初九")
        self.assertEqual(yao_name(1, False), "初六")
        self.assertEqual(yao_name(2, True), "九二")
        self.assertEqual(yao_name(5, False), "六五")
        self.assertEqual(yao_name(6, True), "上九")
        self.assertEqual(yao_name(6, False), "上六")


class GanzhiTests(unittest.TestCase):
    def test_pair_validity(self):
        self.assertTrue(is_valid_ganzhi_pair("甲子"))
        self.assertTrue(is_valid_ganzhi_pair("乙丑"))
        self.assertTrue(is_valid_ganzhi_pair("癸亥"))
        # 奇偶不配（六十甲子表外）
        self.assertFalse(is_valid_ganzhi_pair("甲丑"))
        self.assertFalse(is_valid_ganzhi_pair("乙子"))
        # 支前干后 / 长度不符
        self.assertFalse(is_valid_ganzhi_pair("子甲"))
        self.assertFalse(is_valid_ganzhi_pair("甲子寅"))
        self.assertFalse(is_valid_ganzhi_pair("子"))

    def test_vocabulary_closed(self):
        self.assertEqual(len(GANZHI_CHARS), 22)
        for ch in "甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥":
            self.assertIn(ch, GANZHI_CHARS)


class NajiaTests(unittest.TestCase):
    def test_qian(self):
        # 乾金甲子外壬午：初爻甲子、二爻甲寅、三爻甲辰、四爻壬午、五爻壬申、上爻壬戌
        self.assertEqual(
            najia_for_bits("111111"),
            ["甲子", "甲寅", "甲辰", "壬午", "壬申", "壬戌"],
        )

    def test_kun(self):
        # 坤土乙未外癸丑（阴支逆行）
        self.assertEqual(
            najia_for_bits("000000"),
            ["乙未", "乙巳", "乙卯", "癸丑", "癸亥", "癸酉"],
        )

    def test_lin_composes_from_trigrams(self):
        # 地泽临：下兑内纳丁（巳卯丑）、上坤外纳癸（丑亥酉）
        self.assertEqual(
            najia_for_bits("110000"),
            ["丁巳", "丁卯", "丁丑", "癸丑", "癸亥", "癸酉"],
        )


class ValidateRecordTests(unittest.TestCase):
    def _qian_with_branches(self, branches: list[str]) -> list[dict]:
        return [
            _line(pos, True, right=branches[pos - 1]) for pos in range(1, 7)
        ]

    def test_najia_match(self):
        lines = self._qian_with_branches(["子", "寅", "辰", "午", "申", "戌"])
        v = validate_record(lines)
        self.assertTrue(v["ok"], v)
        self.assertEqual(v["najia"]["verdict"], "match")
        self.assertEqual(v["najia"]["matches"], 6)

    def test_unknown_char_is_error(self):
        lines = self._qian_with_branches(["子", "李", "辰", "午", "申", "戌"])
        v = validate_record(lines)
        self.assertFalse(v["ok"])
        self.assertTrue(any("李" in e for e in v["errors"]), v["errors"])

    def test_illegal_pair_is_error(self):
        lines = self._qian_with_branches(["甲丑", "寅", "辰", "午", "申", "戌"])
        v = validate_record(lines)
        self.assertFalse(v["ok"])
        self.assertTrue(any("甲丑" in e for e in v["errors"]), v["errors"])

    def test_known_extra_char_only_warns(self):
        # 五行附注（如乾卦初爻甲子水的"水"）不该算硬错误
        lines = self._qian_with_branches(["子", "寅", "辰", "午", "申", "水"])
        v = validate_record(lines)
        self.assertTrue(v["ok"], v["errors"])
        self.assertTrue(any("水" in w for w in v["warnings"]), v["warnings"])

    def test_najia_mismatch_is_warning_not_error(self):
        # 干支全合法但配属与纳甲不符（本书或用爻辰/时辰寄爻）：提示非错误
        lines = self._qian_with_branches(["丑", "卯", "未", "酉", "亥", "巳"])
        v = validate_record(lines)
        self.assertTrue(v["ok"], v["errors"])
        self.assertEqual(v["najia"]["verdict"], "mismatch")
        self.assertTrue(any("纳甲" in w for w in v["warnings"]))

    def test_wrong_line_count(self):
        v = validate_record([_line(1, True)])
        self.assertFalse(v["ok"])
        self.assertIn("爻数", v["errors"][0])

    def test_overlong_annotation_warns(self):
        lines = self._qian_with_branches(
            ["子", "寅", "辰", "午", "申", "戌"])
        lines[0]["right"] = [{"text": ch} for ch in "甲子水金"]
        v = validate_record(lines)
        self.assertTrue(v["ok"], v["errors"])
        self.assertTrue(any("超过两字" in w for w in v["warnings"]))


class RenderSvgTests(unittest.TestCase):
    def test_renders_bars_marks_and_caption(self):
        lines = [
            _line(1, True, right="子"),
            _line(2, True, right="寅"),
            _line(3, True, right="辰"),
            _line(4, True, right="午"),
            _line(5, True, right="申"),
            _line(6, True, right="戌"),
        ]
        svg = render_svg(lines, hexagram_info("111111"))
        self.assertTrue(svg.startswith("<svg"))
        # 6 根阳爻条 + 纸底 + 框 ≥ 8 个 rect
        self.assertGreaterEqual(svg.count("<rect"), 8)
        self.assertIn("乾为天", svg)
        self.assertIn("䷀", svg)
        self.assertIn("子", svg)
        # 阴爻两段
        lines[0]["yang"] = False
        svg2 = render_svg(lines, hexagram_info("011111"))
        self.assertGreater(svg2.count("<rect"), svg.count("<rect"))


if __name__ == "__main__":
    unittest.main()
