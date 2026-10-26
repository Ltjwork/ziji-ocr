# -*- coding: utf-8 -*-
"""hexagram_chart 几何检测测试：合成卦画图（cv2 画六爻条堆 + 标注块），
覆盖：区域解析（阴阳分类/左右字框归属）、整页候选（正文/表格不误报）、
失败路径（图缺失/区域过小/无卦画）。"""
from __future__ import annotations

import os
import tempfile
import unittest

import cv2
import numpy as np

from hexagram_chart import analyze_hexagram_region, detect_hexagrams_in_page


def _save_page(canvas: np.ndarray, directory: str, name: str = "page.png") -> str:
    path = os.path.join(directory, name)
    cv2.imwrite(path, canvas)
    return path


def _white_page(w: int = 900, h: int = 700) -> np.ndarray:
    return np.full((h, w, 3), 255, dtype=np.uint8)


def _draw_stack(
    canvas: np.ndarray,
    x: int,
    y_top: int,
    pitch: int,
    bar_w: int,
    thick: int,
    bits_bottom_up: str,
    color: tuple[int, int, int] = (0, 0, 0),
) -> None:
    """画六爻卦画：自上而下第 i 行对应 pos 6-i；阳爻整条、阴爻两段。"""
    for i in range(6):
        pos = 6 - i
        yy = y_top + i * pitch
        if bits_bottom_up[pos - 1] == "1":
            cv2.rectangle(
                canvas, (x, yy), (x + bar_w, yy + thick - 1), color, -1)
        else:
            half = int(bar_w * 0.42)
            cv2.rectangle(
                canvas, (x, yy), (x + half, yy + thick - 1), color, -1)
            cv2.rectangle(
                canvas, (x + bar_w - half, yy),
                (x + bar_w, yy + thick - 1), color, -1)


def _draw_mark(
    canvas: np.ndarray,
    cx: int,
    cy: int,
    size: int = 24,
    color: tuple[int, int, int] = (0, 0, 0),
) -> None:
    """画标注字块（检测只看几何，方块即字）。"""
    half = size // 2
    cv2.rectangle(
        canvas, (cx - half, cy - half), (cx + half, cy + half), color, -1)


# 标准测试卦画参数：临卦（自下而上 110000），页 900×700，卦画在 (100, 80)。
_PITCH, _BAR_W, _THICK = 40, 120, 5
_BITS = "110000"


def _band_center(y_top: int, pos: int, pitch: int = _PITCH,
                 thick: int = _THICK) -> int:
    """pos 爻（1..6）条带的中心 y。"""
    return y_top + (6 - pos) * pitch + thick // 2


class AnalyzeRegionTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def _lin_page(self) -> np.ndarray:
        canvas = _white_page()
        _draw_stack(canvas, 100, 80, _PITCH, _BAR_W, _THICK, _BITS)
        return canvas

    def test_yin_yang_classification(self):
        canvas = self._lin_page()
        path = _save_page(canvas, self._tmp.name)
        result = analyze_hexagram_region(path, 20, 20, 280, 340)
        self.assertTrue(result["ok"], result)
        lines = result["lines"]
        self.assertEqual([ln["pos"] for ln in lines], [1, 2, 3, 4, 5, 6])
        # 临卦：初爻/二爻阳，三至上阴
        self.assertEqual(
            [ln["yang"] for ln in lines],
            [True, True, False, False, False, False],
        )
        # 卦体几何：条堆外接框
        self.assertAlmostEqual(result["stack"]["x"], 100, delta=3)
        self.assertAlmostEqual(result["stack"]["w"], _BAR_W, delta=4)
        self.assertAlmostEqual(result["pitch"], _PITCH, delta=2)

    def test_left_right_marks_assigned_by_yao(self):
        canvas = self._lin_page()
        # 三爻左侧标"字"（中心对准三爻条带），五爻右侧标"字"
        _draw_mark(canvas, 100 - 60, _band_center(80, 3))
        _draw_mark(canvas, 100 + _BAR_W + 40, _band_center(80, 5))
        path = _save_page(canvas, self._tmp.name)
        result = analyze_hexagram_region(path, 20, 20, 280, 340)
        self.assertTrue(result["ok"], result)
        by_pos = {ln["pos"]: ln for ln in result["lines"]}
        self.assertEqual(len(by_pos[3]["left"]), 1)
        self.assertEqual(len(by_pos[3]["right"]), 0)
        self.assertEqual(len(by_pos[5]["right"]), 1)
        self.assertEqual(len(by_pos[5]["left"]), 0)
        # 其余爻无标注
        self.assertEqual(len(by_pos[1]["left"]) + len(by_pos[1]["right"]), 0)

    def test_no_chart_in_region(self):
        # 只有文字块（竖排小方块列），无卦画
        canvas = _white_page()
        for r in range(10):
            _draw_mark(canvas, 150, 60 + r * 55, size=26)
        path = _save_page(canvas, self._tmp.name)
        result = analyze_hexagram_region(path, 60, 30, 240, 600)
        self.assertFalse(result["ok"])
        self.assertIn("未检测到", result["reason"])

    def test_region_too_small(self):
        path = _save_page(_white_page(), self._tmp.name)
        result = analyze_hexagram_region(path, 0, 0, 20, 20)
        self.assertFalse(result["ok"])
        self.assertEqual(result["reason"], "region too small")

    def test_missing_image(self):
        result = analyze_hexagram_region(
            os.path.join(self._tmp.name, "none.png"), 0, 0, 100, 100)
        self.assertFalse(result["ok"])
        self.assertEqual(result["reason"], "image not found")

    def test_broken_bar_bridged(self):
        # 阳爻整条带 4px 印刷断口（两段各 58px，长于开运算核）：闭运算
        # 应桥接回一段，仍判阳爻
        canvas = self._lin_page()
        yy = 80 + 4 * _PITCH  # 五爻（pos 5-1=4 行）是阳爻
        cv2.rectangle(
            canvas, (100, yy), (100 + _BAR_W // 2 - 2, yy + _THICK - 1),
            (255, 255, 255), -1)  # 抹掉整条
        cv2.rectangle(
            canvas, (100, yy), (100 + _BAR_W // 2 - 2, yy + _THICK - 1),
            (0, 0, 0), -1)
        cv2.rectangle(
            canvas, (100 + _BAR_W // 2 + 2, yy), (100 + _BAR_W, yy + _THICK - 1),
            (0, 0, 0), -1)
        path = _save_page(canvas, self._tmp.name)
        result = analyze_hexagram_region(path, 20, 20, 280, 340)
        self.assertTrue(result["ok"], result)
        self.assertEqual(
            [ln["yang"] for ln in result["lines"]],
            [True, True, False, False, False, False],
        )


class DetectInPageTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def test_finds_stack_skips_text(self):
        canvas = _white_page(w=1400, h=900)
        _draw_stack(canvas, 620, 150, _PITCH, _BAR_W, _THICK, "010101")
        # 左半页：竖排文字列（方块字，20×20）
        for col in range(4):
            for r in range(14):
                _draw_mark(
                    canvas, 120 + col * 90, 80 + r * 55, size=20)
        path = _save_page(canvas, self._tmp.name)
        found = detect_hexagrams_in_page(path)
        self.assertEqual(len(found), 1, found)
        self.assertAlmostEqual(found[0]["x"], 620 - _BAR_W, delta=8)
        self.assertAlmostEqual(found[0]["y"], 150 - 36, delta=8)

    def test_table_lines_not_mistaken(self):
        # 表格横线（间距规则、宽度远超爻距）不该被当卦画
        canvas = _white_page(w=1400, h=900)
        for i in range(7):
            y = 120 + i * 40
            cv2.line(canvas, (900, y), (1300, y), (0, 0, 0), 2)
        cv2.line(canvas, (900, 120), (900, 360), (0, 0, 0), 2)
        cv2.line(canvas, (1300, 120), (1300, 360), (0, 0, 0), 2)
        path = _save_page(canvas, self._tmp.name)
        self.assertEqual(detect_hexagrams_in_page(path), [])

    def test_text_only_no_false_positive(self):
        canvas = _white_page(w=1400, h=900)
        for col in range(8):
            for r in range(16):
                _draw_mark(canvas, 100 + col * 150, 80 + r * 50, size=24)
        path = _save_page(canvas, self._tmp.name)
        self.assertEqual(detect_hexagrams_in_page(path), [])

    def test_two_stacks_both_found(self):
        canvas = _white_page(w=1400, h=900)
        _draw_stack(canvas, 300, 120, _PITCH, _BAR_W, _THICK, "111111")
        _draw_stack(canvas, 800, 120, _PITCH, _BAR_W, _THICK, "000000")
        path = _save_page(canvas, self._tmp.name)
        found = detect_hexagrams_in_page(path)
        self.assertEqual(len(found), 2, found)
        self.assertLess(found[0]["x"], found[1]["x"])

    def test_missing_image(self):
        self.assertEqual(
            detect_hexagrams_in_page(
                os.path.join(self._tmp.name, "none.png")),
            [],
        )


class RobustnessTests(unittest.TestCase):
    """真实扫描件加固：斜切页、小卦画、卦画外框横线混入爻带。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def test_skewed_page_detected(self):
        # 手机拍照常见的 ~3° 斜切：斜条变厚块/阴爻两段 y 错位，直接检测
        # 会挂；应先估计斜切角转正再检出。
        canvas = _white_page(w=1400, h=900)
        _draw_stack(canvas, 620, 150, _PITCH, _BAR_W, _THICK, "010101")
        M = cv2.getRotationMatrix2D((700, 450), 3.0, 1.0)
        skewed = cv2.warpAffine(
            canvas, M, (1400, 900), flags=cv2.INTER_LINEAR,
            borderValue=(255, 255, 255),
        )
        path = _save_page(skewed, self._tmp.name)
        found = detect_hexagrams_in_page(path)
        self.assertEqual(len(found), 1, found)

    def test_small_hexagram_detected(self):
        # 小卦画（条宽 38、阴爻半段 16、条距 26）：大核会把半段吃掉，
        # 多档核的小核档应救回来。
        canvas = _white_page(w=1000, h=1200)
        _draw_stack(canvas, 420, 300, 26, 38, 3, "110000")
        path = _save_page(canvas, self._tmp.name)
        found = detect_hexagrams_in_page(path)
        self.assertEqual(len(found), 1, found)
        self.assertAlmostEqual(found[0]["pitch"], 26, delta=2)

    def test_frame_line_merged_into_bands(self):
        # 卦画外框横线贴着爻带（竖向空隙 2px、y 中心差 ≤6px 落进聚带
        # 容差）：框线比爻条长得多，外物丢弃逻辑应丢框线保爻段，卦画
        # 照常检出、阴阳不串。
        canvas = _white_page()
        _draw_stack(canvas, 100, 80, _PITCH, _BAR_W, _THICK, _BITS)
        # 框线 1：y 76-77（第 6 爻阴爻条带 y 80..84，中心差 5.5px）
        cv2.line(canvas, (86, 76), (234, 76), (0, 0, 0), 2)
        # 框线 2：y 246-247（第 2 爻阴爻条带 y 240..244，中心差 4.5px）
        cv2.line(canvas, (86, 246), (234, 246), (0, 0, 0), 2)
        path = _save_page(canvas, self._tmp.name)
        result = analyze_hexagram_region(path, 20, 20, 280, 340)
        self.assertTrue(result["ok"], result)
        self.assertEqual(
            [ln["yang"] for ln in result["lines"]],
            [True, True, False, False, False, False],
        )


class RegionToleranceTests(unittest.TestCase):
    """区域解析恢复阶梯（2026-10-24 用户页 page_042 识别 422 后）：
    上爻贴得近（首间距 ~0.57×爻距）、右侧干支笔画贴着爻带混进 x 组
    （撑爆带跨度）——两者叠加时严格等距+原始带全被拒，恢复阶梯应救回。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    @staticmethod
    def _draw_tight_stack(canvas, x0, y_top, annotations=False):
        """画首间距 79、其余爻距 ~140 的六爻（自下而上 阳阳阳阴阳阳，
        复刻 page_042 几何）；annotations=True 再画右侧干支笔画列
        （w=57、贴着两条爻带 + 三条自成带——污染 x 组）。"""
        ycs = [y_top + 27, y_top + 106, y_top + 245.5,
               y_top + 394, y_top + 541, y_top + 681]
        for i, yc in enumerate(ycs):
            y = int(yc - 6)
            if i == 2:  # 四爻阴：两段 55、断口 44
                cv2.rectangle(canvas, (x0, y), (x0 + 54, y + 10),
                              (0, 0, 0), -1)
                cv2.rectangle(canvas, (x0 + 99, y), (x0 + 153, y + 10),
                              (0, 0, 0), -1)
            else:
                cv2.rectangle(canvas, (x0, y), (x0 + 153, y + 11),
                              (0, 0, 0), -1)
        if annotations:
            ax = x0 + 154 + 22  # 紧贴爻条右端（阴爻断口条款会把它并进组）
            for ay in (544, 555, 657, 671, 686):  # 相对 y_top 的偏移
                cv2.rectangle(canvas, (ax, y_top + ay),
                              (ax + 56, y_top + ay + 4),
                              (0, 0, 0), -1)

    def test_tight_top_gap_still_recognized(self):
        # 上爻贴得近（首间距 0.56×爻距）：严格等距拒、宽松异距档应过，
        # 阴阳不串。
        canvas = _white_page(w=900, h=1200)
        self._draw_tight_stack(canvas, 266, 100)
        path = _save_page(canvas, self._tmp.name)
        result = analyze_hexagram_region(path, 200, 100, 315, 734)
        self.assertTrue(result["ok"], result)
        self.assertEqual(
            [ln["yang"] for ln in result["lines"]],
            [True, True, True, False, True, True],
        )
        self.assertAlmostEqual(result["pitch"], 140, delta=4)

    def test_side_annotations_and_tight_gap_recognized(self):
        # page_042 结构复刻：干支笔画污染爻带（跨度撑爆）+ 上爻贴近，
        # 需要"宽松异距 + 剔旁挂段"叠加档。
        canvas = _white_page(w=900, h=1200)
        self._draw_tight_stack(canvas, 266, 100, annotations=True)
        path = _save_page(canvas, self._tmp.name)
        result = analyze_hexagram_region(path, 200, 100, 315, 734)
        self.assertTrue(result["ok"], result)
        self.assertEqual(
            [ln["yang"] for ln in result["lines"]],
            [True, True, True, False, True, True],
        )

    def test_five_bars_hint_to_expand_box(self):
        # 框选裁掉初爻（只剩 5 条等距横条）：应给出"扩大框选"的可操作
        # 提示而不是笼统的"未检测到"。
        canvas = _white_page(w=900, h=1200)
        for i in range(5):
            y = 120 + i * 140
            cv2.rectangle(canvas, (266, y), (266 + 153, y + 11),
                          (0, 0, 0), -1)
        path = _save_page(canvas, self._tmp.name)
        result = analyze_hexagram_region(path, 200, 100, 315, 734)
        self.assertFalse(result["ok"])
        self.assertIn("5 条横条", result["reason"])
        self.assertIn("扩大", result["reason"])

    def test_page_scan_still_strict_on_odd_gap(self):
        # 同样的"上爻贴近"卦画在整页自动扫里不进任何恢复档：等距闸门
        # 照拒（自动扫无用户框选先验，宁可漏报不可误报）。
        canvas = _white_page(w=1400, h=900)
        self._draw_tight_stack(canvas, 620, 120)
        path = _save_page(canvas, self._tmp.name)
        self.assertEqual(detect_hexagrams_in_page(path), [])


if __name__ == "__main__":
    unittest.main()
