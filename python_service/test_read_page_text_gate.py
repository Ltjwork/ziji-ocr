# -*- coding: utf-8 -*-
"""文本视图「排除页眉页脚」门控测试（/read_page_text 整页直读）。

覆盖两块：
1. seg_layout.filter_page_text_lines：行中心落在排除类区（页眉/页脚/
   页码/插图/表格/卦图）内的行整行剔除、眉批区不排除、rejected 区
   不参与、无区/None 原样返回（无安全边界不强切）；
2. /read_page_text 路由：exclude_header_footer 开关的输入组装——人工
   确认区优先于 region_det 预检、模型不可用退回不过滤、开关关闭不
   跑任何检测；回包携带 excluded_lines / excluded_regions 门控元信息。
"""
import os
import unittest
from tempfile import TemporaryDirectory
from unittest.mock import patch

import cv2
import numpy as np

import api_page_text
from api_page_text import GateRegion, ReadPageTextRequest
from seg_layout import filter_page_text_lines


def _line(x, y, w, h, text=""):
    return {"x": x, "y": y, "w": w, "h": h, "text": text}


class FilterPageTextLinesTest(unittest.TestCase):
    def test_lines_inside_excluded_region_dropped(self):
        lines = [
            _line(90, 10, 20, 20, "页眉字"),  # 中心 (100,20) 在页眉区内
            _line(90, 100, 20, 60, "正文一"),
            _line(90, 180, 20, 60, "正文二"),
        ]
        regions = [{"x": 0, "y": 0, "w": 200, "h": 40, "label": "header"}]
        kept, dropped = filter_page_text_lines(lines, regions)
        self.assertEqual(dropped, 1)
        self.assertEqual([ln["text"] for ln in kept], ["正文一", "正文二"])

    def test_center_on_region_edge_counts_inside(self):
        # 中心恰在区底边（y=40）：归属判定用闭区间，与标注管线一致。
        lines = [_line(90, 20, 20, 40, "边线行")]
        regions = [{"x": 0, "y": 0, "w": 200, "h": 40, "label": "header"}]
        kept, dropped = filter_page_text_lines(lines, regions)
        self.assertEqual((len(kept), dropped), (0, 1))

    def test_margin_note_region_does_not_exclude(self):
        # 眉批是正文宿主类：内容有价值，直读不剔除。
        lines = [_line(90, 10, 20, 20, "眉批")]
        regions = [{"x": 0, "y": 0, "w": 200, "h": 40, "label": "margin_note"}]
        kept, dropped = filter_page_text_lines(lines, regions)
        self.assertEqual((len(kept), dropped), (1, 0))

    def test_rejected_region_ignored(self):
        lines = [_line(90, 10, 20, 20, "正文")]
        regions = [
            {"x": 0, "y": 0, "w": 200, "h": 40, "label": "header", "status": "rejected"}
        ]
        kept, dropped = filter_page_text_lines(lines, regions)
        self.assertEqual((len(kept), dropped), (1, 0))

    def test_no_regions_passthrough(self):
        lines = [_line(0, 0, 10, 10, "a")]
        for regions in (None, []):
            kept, dropped = filter_page_text_lines(lines, regions)
            self.assertIs(kept, lines)
            self.assertEqual(dropped, 0)

    def test_empty_lines_noop(self):
        kept, dropped = filter_page_text_lines(
            [], [{"x": 0, "y": 0, "w": 10, "h": 10, "label": "header"}]
        )
        self.assertEqual((kept, dropped), ([], 0))


class ReadPageTextGateRouteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image_path = os.path.join(self.tmp.name, "page.png")
        cv2.imwrite(
            self.image_path, np.full((240, 180, 3), 240, dtype=np.uint8)
        )

    @staticmethod
    def _request(**kw):
        base = dict(image_path="", orientation="vertical", engine="kraken")
        base.update(kw)
        return ReadPageTextRequest(**base)

    @staticmethod
    def _bridge_result(excluded_lines=0):
        return {
            "text": "正文",
            "lines": [_line(90, 100, 20, 60, "正文")],
            "engine": "kraken",
            "ocr": "kraken+chat_rec",
            "excluded_lines": excluded_lines,
        }

    def test_gate_off_no_detection_and_no_filter(self):
        req = self._request(image_path=self.image_path)
        with patch(
            "kraken_bridge.read_page_text",
            return_value=self._bridge_result(),
        ) as mock, patch.object(api_page_text, "detect_main_regions") as det:
            result = api_page_text.read_page_text(req)
        mock.assert_called_once()
        self.assertIsNone(mock.call_args.kwargs["gate_regions"])
        det.assert_not_called()
        self.assertEqual(result["excluded_lines"], 0)
        self.assertEqual(result["excluded_regions"], 0)

    def test_human_gate_regions_take_precedence(self):
        gate = GateRegion(x=0, y=0, w=200, h=40, label="header")
        req = self._request(
            image_path=self.image_path,
            exclude_header_footer=True,
            gate_regions=[gate],
        )
        with patch(
            "kraken_bridge.read_page_text",
            return_value=self._bridge_result(excluded_lines=2),
        ) as mock, patch.object(
            api_page_text, "detect_main_regions"
        ) as det:
            result = api_page_text.read_page_text(req)
        det.assert_not_called()
        passed = mock.call_args.kwargs["gate_regions"]
        self.assertEqual(len(passed), 1)
        self.assertEqual(passed[0]["label"], "header")
        self.assertEqual(result["excluded_lines"], 2)
        self.assertEqual(result["excluded_regions"], 1)

    def test_region_detector_used_without_human_regions(self):
        req = self._request(image_path=self.image_path, exclude_header_footer=True)
        detected = [{"x": 0, "y": 0, "w": 200, "h": 40, "label": "header"}]
        with patch(
            "kraken_bridge.read_page_text",
            return_value=self._bridge_result(excluded_lines=1),
        ) as mock, patch.object(
            api_page_text, "detect_main_regions", return_value=detected
        ) as det:
            result = api_page_text.read_page_text(req)
        det.assert_called_once()
        self.assertEqual(mock.call_args.kwargs["gate_regions"], detected)
        self.assertEqual(result["excluded_lines"], 1)
        self.assertEqual(result["excluded_regions"], 1)

    def test_detector_unavailable_falls_back_to_no_filter(self):
        # region_det 不可用（模型缺失）：无安全边界不强切，退回整页直读。
        req = self._request(image_path=self.image_path, exclude_header_footer=True)
        with patch(
            "kraken_bridge.read_page_text",
            return_value=self._bridge_result(),
        ) as mock, patch.object(
            api_page_text, "detect_main_regions", return_value=None
        ):
            result = api_page_text.read_page_text(req)
        self.assertIsNone(mock.call_args.kwargs["gate_regions"])
        self.assertEqual(result["excluded_lines"], 0)
        self.assertEqual(result["excluded_regions"], 0)

    def test_empty_detected_regions_report_zero(self):
        # 模型可用但整页无排除类区（无页眉页脚的页面）：开关生效但无可剔。
        req = self._request(image_path=self.image_path, exclude_header_footer=True)
        with patch(
            "kraken_bridge.read_page_text",
            return_value=self._bridge_result(),
        ), patch.object(api_page_text, "detect_main_regions", return_value=[]):
            result = api_page_text.read_page_text(req)
        self.assertEqual(result["excluded_lines"], 0)
        self.assertEqual(result["excluded_regions"], 0)


if __name__ == "__main__":
    unittest.main()
