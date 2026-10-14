# -*- coding: utf-8 -*-
"""engine=paddle 行框来源切换为 PP-OCR det 的单元测试。

覆盖：worker 端 det 结果解析（dt_polys 实测形态/轴对齐通道键/坏值）、
det 框→管线行结构（钳制/退化丢弃/竖排页横排行方向放行/阅读序重排）、
segment_image_with_metadata 的 det 注入与失败回退、paddle_bridge.
detect_page_lines 的池请求与 kill-switch、/segment 的 engine 分发注入。
"""
import json
import os
import unittest
from pathlib import Path as FsPath
from tempfile import TemporaryDirectory
from unittest.mock import patch

import cv2
import numpy as np

import api_segment
import kraken_bridge
import paddle_bridge
import paddle_proc
import seg_pipeline
from api_segment import SegmentRegionRequest, SegmentRequest
from kraken_bridge import _apply_full_text_check, _match_page_ref_line
from paddle_bridge import attach_page_text_ref, detect_page_lines
from paddle_worker import _det_rects_from_result
from seg_pipeline import (
    _det_line_position_label,
    _lines_from_det_rects,
    _type_det_lines,
    segment_image_with_metadata,
)


class DetRectsParsingTests(unittest.TestCase):
    """paddle_worker._det_rects_from_result：多通道结果键 → 轴对齐框。

    实测 paddleocr 3.7 TextDetection 输出 dt_polys(N,4,2)；det_boxes/
    rec_boxes 轴对齐与 det_polys 管线通道一并兼容。"""

    def test_dt_polys_outer_rect(self):
        data = {
            "dt_polys": [
                [[10, 20], [30, 25], [30, 80], [10, 75]],   # 斜框→外接
                [[100, 0], [130, 4], [128, 60], [98, 56]],
            ],
            "dt_scores": [0.9, 0.8],
        }
        rects = _det_rects_from_result(data)
        self.assertEqual(2, len(rects))
        self.assertEqual((10, 20, 20, 60), tuple(int(v) for v in rects[0].values()))

    def test_axis_aligned_keys_preferred(self):
        data = {
            "det_boxes": [[5, 6, 25, 40]],
            "dt_polys": [[[0, 0], [9, 9], [9, 9], [0, 0]]],
        }
        rects = _det_rects_from_result(data)
        self.assertEqual(1, len(rects))
        self.assertEqual((5, 6, 20, 34), tuple(int(v) for v in rects[0].values()))

    def test_empty_and_junk_return_empty(self):
        self.assertEqual([], _det_rects_from_result({}))
        self.assertEqual([], _det_rects_from_result({"input_path": "x.png"}))
        # 坏值（字符串假装 polys）不炸、不产出框
        self.assertEqual([], _det_rects_from_result({"dt_polys": "oops"}))
        self.assertEqual([], _det_rects_from_result({"dt_polys": [["ab"]]}))


class LinesFromDetRectsTests(unittest.TestCase):
    """det 框 → 管线行：钳制、退化丢弃、竖排页上的横排行放行。"""

    def test_vertical_columns_stay_vertical(self):
        lines = _lines_from_det_rects(
            [(30, 10, 20, 180), (60, 10, 20, 180)], 100, 200, "vertical"
        )
        self.assertEqual(["det_l_000", "det_l_001"], [l["id"] for l in lines])
        self.assertTrue(all(l["orientation"] == "vertical" for l in lines))
        self.assertTrue(all(l["chars"] == [] for l in lines))

    def test_wide_box_on_vertical_page_becomes_horizontal(self):
        lines = _lines_from_det_rects(
            [(10, 150, 80, 20)], 100, 200, "vertical"
        )
        self.assertEqual("horizontal", lines[0]["orientation"])

    def test_tall_box_on_horizontal_page_becomes_vertical(self):
        lines = _lines_from_det_rects(
            [(10, 10, 20, 80)], 100, 200, "horizontal"
        )
        self.assertEqual("vertical", lines[0]["orientation"])

    def test_clamps_and_drops_degenerate(self):
        lines = _lines_from_det_rects(
            [
                (95, 0, 20, 100),   # 越界钳回
                (0, 0, 2, 100),     # 宽 <3 丢弃
                (0, 0, 20, 5),      # 高 <6 丢弃
            ],
            100,
            200,
            "vertical",
        )
        self.assertEqual(1, len(lines))
        line = lines[0]
        self.assertEqual(5, line["w"])  # 95+20 → 100 钳到图宽
        self.assertEqual((95, 0, 5, 100), (line["x"], line["y"], line["w"], line["h"]))


class SegmentDetSourceTests(unittest.TestCase):
    """segment_image_with_metadata：line_detector 注入 det 行框优先，
    失败/空产出回退既有 YOLO 链路。"""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image = str(FsPath(self.tmp.name) / "page.png")
        cv2.imwrite(self.image, np.full((200, 100, 3), 255, dtype=np.uint8))
        # 区域门控/模型层级走真实图像会拉起 YOLO——det 路径不依赖它们，
        # 全部 mock 掉，只测 det 分支本身。
        self._patches = [
            patch.object(seg_pipeline, "detect_main_regions", return_value=[]),
            patch.object(seg_pipeline, "build_body_gated_image", return_value=None),
            patch.object(seg_pipeline, "dispose_body_gated_image", lambda p: None),
            patch.object(
                seg_pipeline,
                "_augment_with_model_hierarchy",
                side_effect=lambda payload, *a, **k: payload,
            ),
        ]
        for p in self._patches:
            p.start()
            self.addCleanup(p.stop)

    def test_det_lines_used_and_sorted_rtl(self):
        def detector(path):
            # 右起两列（y 10..130）+ 页底横排落款（y 160..180，跨轴不与
            # 列重叠、不并入通栏带）：rtl 阅读序应为 60 → 35 → 落款最后
            return [(60, 10, 20, 120), (35, 10, 20, 120), (10, 160, 20, 10)]

        result = segment_image_with_metadata(
            self.image,
            orientation="vertical",
            horizontal_dir="rtl",
            line_detector=detector,
        )
        self.assertEqual("paddle-det", result["engine"])
        self.assertEqual("paddle-det", result["model_version"])
        self.assertEqual([], result["blocks"])  # 字框由识别阶段逐行产出
        xs = [l["x"] for l in result["lines"]]
        self.assertEqual([60, 35, 10], xs)
        self.assertEqual("horizontal", result["lines"][2]["orientation"])
        self.assertTrue(
            all(l["chars"] == [] for l in result["lines"])
        )

    def test_detector_failure_falls_back(self):
        def detector(path):
            raise RuntimeError("paddle env missing")

        with patch.object(
            seg_pipeline,
            "_segment_with_yolo_chars",
            return_value=([], []),
        ):
            result = segment_image_with_metadata(
                self.image, line_detector=detector
            )
        # 空白页无墨迹 → opencv 兜底也产出 0 行；关键是不再是 paddle-det
        self.assertEqual("opencv", result["engine"])

    def test_empty_detection_falls_back(self):
        calls = []

        def detector(path):
            calls.append(path)
            return []

        with patch.object(
            seg_pipeline,
            "_segment_with_yolo_chars",
            return_value=([], []),
        ):
            result = segment_image_with_metadata(
                self.image, line_detector=detector
            )
        self.assertEqual([self.image], calls)
        self.assertNotEqual("paddle-det", result["engine"])


class _FakePool:
    def __init__(self, response):
        self.response = response
        self.calls = []
        self.size = 1

    def request(self, op, payload=None, timeout=None):
        self.calls.append((op, payload))
        return self.response


class DetectPageLinesTests(unittest.TestCase):
    """paddle_bridge.detect_page_lines：池请求构造与 kill-switch。"""

    def test_requests_detect_lines_and_parses_rects(self):
        pool = _FakePool(
            {"lines": [
                {"x": 10, "y": 20, "w": 30, "h": 40},
                {"x": "50", "y": "60", "w": "5", "h": "6"},
            ]}
        )
        with patch.object(paddle_proc, "ensure_pool", return_value=pool) as mk:
            rects = detect_page_lines("page.png", model="PP-OCRv6_medium_rec")
        mk.assert_called_once_with("PP-OCRv6_medium_rec")
        self.assertEqual(("detect_lines", {"image_path": "page.png"}), pool.calls[0])
        self.assertEqual([(10, 20, 30, 40), (50, 60, 5, 6)], rects)

    def test_vl_model_falls_back_to_small_pool(self):
        pool = _FakePool({"lines": []})
        with patch.object(paddle_proc, "ensure_pool", return_value=pool) as mk:
            detect_page_lines("page.png", model="PaddleOCR-VL-1.6")
        mk.assert_called_once_with("PP-OCRv6_small_rec")

    def test_kill_switch_skips_pool(self):
        with patch.object(paddle_proc, "ensure_pool") as mk:
            with patch.dict(os.environ, {"OCR_PADDLE_DET_LINES": "0"}):
                self.assertEqual([], detect_page_lines("page.png"))
        mk.assert_not_called()


class SegmentDispatchDetTests(unittest.TestCase):
    """/segment：engine=paddle 注入 line_detector（带 paddle_model），
    kraken 不注入（历史行为不变）。"""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image = os.path.join(self.tmp.name, "p.png")
        with open(self.image, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n")

    def _segment(self, req: SegmentRequest):
        from test_paddle_engine import _fake_seg_result

        with patch.object(
            api_segment,
            "segment_image_with_metadata",
            return_value=_fake_seg_result(),
        ) as seg, patch.object(
            api_segment, "make_kraken_char_splitter", return_value=None
        ), patch.object(api_segment, "_acquire_recognition_slot"), patch.object(
            api_segment, "_release_recognition_slot"
        ), patch(
            "kraken_bridge.apply_kraken_recognition",
            side_effect=lambda result, *a, **k: dict(result, recognition_engine="kraken"),
        ), patch(
            "paddle_bridge.apply_paddle_recognition",
            side_effect=lambda result, *a, **k: dict(result, recognition_engine="paddle"),
        ):
            out = api_segment.segment(req)
        return out, seg

    def test_paddle_engine_injects_detector(self):
        _out, seg = self._segment(
            SegmentRequest(
                image_path=self.image,
                engine="paddle",
                paddle_model="PP-OCRv6_medium_rec",
            )
        )
        detector = seg.call_args.kwargs.get("line_detector")
        self.assertIsNotNone(detector)
        # partial 绑定的 model 透传：detector(path) 走 small/medium 档池
        with patch.object(paddle_proc, "ensure_pool", return_value=_FakePool({"lines": []})) as mk:
            detector("page.png")
        mk.assert_called_once_with("PP-OCRv6_medium_rec")

    def test_kraken_engine_has_no_detector(self):
        _out, seg = self._segment(SegmentRequest(image_path=self.image))
        self.assertIsNone(seg.call_args.kwargs.get("line_detector"))


class DetLineTypingTests(unittest.TestCase):
    """det 行类型化：门控区归属优先，几何兜底（页眉/页脚/页码），
    正文主列永不误标。"""

    def _line(self, x, y, w, h, orientation="vertical"):
        return {
            "id": f"l_{x}_{y}", "x": x, "y": y, "w": w, "h": h,
            "orientation": orientation, "text": "", "chars": [],
        }

    def test_region_containment_wins(self):
        lines = [self._line(10, 5, 20, 15), self._line(50, 100, 20, 80)]
        regions = [
            {"x": 0, "y": 0, "w": 100, "h": 20, "label": "header"},
        ]
        _type_det_lines(lines, 100, 200, regions)
        self.assertEqual("header", lines[0]["region_label"])
        self.assertEqual("annotation", lines[0]["layout_role"])
        self.assertNotIn("region_label", lines[1])

    def test_rejected_region_ignored(self):
        # 页面中部短行（几何不判型），仅被已拒绝的页眉区覆盖 → 不打标
        lines = [self._line(10, 90, 10, 20)]
        regions = [
            {"x": 0, "y": 0, "w": 100, "h": 200, "label": "header",
             "status": "rejected"},
        ]
        _type_det_lines(lines, 100, 200, regions)
        self.assertNotIn("region_label", lines[0])
        # 同区改为已确认 → 归属生效
        regions[0]["status"] = "confirmed"
        _type_det_lines(lines, 100, 200, regions)
        self.assertEqual("header", lines[0]["region_label"])

    def test_geometry_header_footer_page_number(self):
        # 100×200 竖排页：顶部带短行=页眉；底部带极短行=页码；
        # 底部带多字短行=页脚；高主列永不标。
        self.assertEqual(
            "header", _det_line_position_label(self._line(40, 5, 20, 15), 100, 200)
        )
        self.assertEqual(
            "page_number",
            _det_line_position_label(self._line(10, 180, 20, 15), 100, 200),
        )
        self.assertEqual(
            "footer",
            _det_line_position_label(self._line(10, 175, 8, 46), 100, 200),
        )
        self.assertEqual(
            "", _det_line_position_label(self._line(30, 10, 20, 170), 100, 200)
        )
        # 页面中部短行（眉批候选）不猜
        self.assertEqual(
            "", _det_line_position_label(self._line(0, 90, 10, 20), 100, 200)
        )

    def test_typed_via_segment_pipeline(self):
        with TemporaryDirectory() as tmp:
            image = str(FsPath(tmp) / "p.png")
            cv2.imwrite(image, np.full((200, 100, 3), 255, dtype=np.uint8))
            with patch.object(
                seg_pipeline, "detect_main_regions", return_value=[]
            ), patch.object(
                seg_pipeline, "build_body_gated_image", return_value=None
            ), patch.object(
                seg_pipeline, "dispose_body_gated_image", lambda p: None
            ), patch.object(
                seg_pipeline,
                "_augment_with_model_hierarchy",
                side_effect=lambda payload, *a, **k: payload,
            ):
                result = segment_image_with_metadata(
                    image,
                    orientation="vertical",
                    horizontal_dir="rtl",
                    line_detector=lambda path: [
                        (40, 10, 20, 170),   # 主列
                        (40, 5, 20, 15),     # 顶部短行 → 页眉
                        (10, 180, 20, 15),   # 底部极短行 → 页码
                    ],
                )
            by_label = {
                ln.get("region_label", ""): ln for ln in result["lines"]
            }
            self.assertIn("header", by_label)
            self.assertIn("page_number", by_label)
            self.assertNotIn("region_label", by_label.get("", {}))
            self.assertEqual(1, len([l for l in result["lines"] if not l.get("region_label")]))


class _FakeFullAdapter:
    """全文对照测试假适配器：可挂页读参照，逐行直读计数。"""

    def __init__(self, page_lines=None, line_text=""):
        if page_lines is not None:
            self.page_text_lines = page_lines
        self.line_text = line_text
        self.line_calls = 0

    def read_line_full(self, image_path, rect, orientation, horizontal_dir,
                       vertical_dir):
        self.line_calls += 1
        return {"text": self.line_text, "conf": 0.9}


class MatchPageRefTests(unittest.TestCase):
    def test_exact_and_partial_match(self):
        refs = [{"x": 0, "y": 0, "w": 10, "h": 100, "text": "甲"}]
        self.assertIsNotNone(_match_page_ref_line(refs, {"x": 0, "y": 0, "w": 10, "h": 100}))
        self.assertIsNotNone(_match_page_ref_line(refs, {"x": 0, "y": 20, "w": 10, "h": 100}))
        self.assertIsNone(_match_page_ref_line(refs, {"x": 50, "y": 50, "w": 10, "h": 10}))

    def test_bad_ref_entries_ignored(self):
        refs = [{"x": "x", "y": 0, "w": 10, "h": 10}, None]
        self.assertIsNone(_match_page_ref_line(refs, {"x": 0, "y": 0, "w": 10, "h": 10}))


class FullTextCheckPageRefTests(unittest.TestCase):
    """整页直读作全文对照参照：命中行用页读文本，未命中回退逐行。"""

    def _run(self, adapter, chars):
        line = {"id": "l0"}
        _apply_full_text_check(
            adapter, "img.png", {"x": 0, "y": 0, "w": 10, "h": 100},
            "vertical", "ltr", "ttb", line, chars,
        )
        return line

    @staticmethod
    def _char(text):
        return {"text": text}

    def test_page_ref_marks_extras_and_diff(self):
        # 页读文本多出的标点 → extras；同位替换的字 → full_diff
        adapter = _FakeFullAdapter(
            page_lines=[{"x": 0, "y": 0, "w": 10, "h": 100, "text": "甲乙，丙"}],
        )
        chars = [self._char("甲"), self._char("乙"), self._char("丙")]
        line = self._run(adapter, chars)
        self.assertEqual("甲乙，丙", line["full_text"])
        self.assertEqual(["，"], line["full_extras"])
        # 实现只对命中位写 full_diff=True，未命中位无键
        self.assertEqual(
            [False, False, False],
            [c.get("full_diff") is True for c in chars],
        )
        self.assertEqual(0, adapter.line_calls)  # 命中页读不再逐行直读

        adapter2 = _FakeFullAdapter(
            page_lines=[{"x": 0, "y": 0, "w": 10, "h": 100, "text": "甲乙X丁"}],
        )
        chars2 = [self._char("甲"), self._char("乙"), self._char("丙"), self._char("丁")]
        line2 = self._run(adapter2, chars2)
        self.assertEqual([], line2["full_extras"])
        self.assertEqual(
            [False, False, True, False],
            [c.get("full_diff") is True for c in chars2],
        )

    def test_unmatched_rect_falls_back_to_line_read(self):
        adapter = _FakeFullAdapter(
            page_lines=[{"x": 900, "y": 0, "w": 10, "h": 100, "text": "無關"}],
            line_text="甲乙",
        )
        line = self._run(adapter, [self._char("甲")])
        self.assertEqual("甲乙", line["full_text"])
        self.assertEqual(1, adapter.line_calls)

    def test_no_page_attr_keeps_line_read(self):
        adapter = _FakeFullAdapter(line_text="甲乙")
        line = self._run(adapter, [self._char("甲")])
        self.assertEqual("甲乙", line["full_text"])
        self.assertEqual(1, adapter.line_calls)


class SidecarPageRefTests(unittest.TestCase):
    """整页参照读 direct_text 侧车（line_records）：零推理，缺位静默。"""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image = str(FsPath(self.tmp.name) / "page_005.png")
        with open(self.image, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n")

    def _write_meta(self, payload: str):
        meta_dir = FsPath(self.tmp.name) / "direct_text"
        meta_dir.mkdir(exist_ok=True)
        (meta_dir / "page_005.meta.json").write_text(payload, encoding="utf-8")

    def test_attaches_line_records(self):
        self._write_meta(
            '{"engine":"paddle","lines":2,"line_records":['
            '{"x":1,"y":2,"w":30,"h":40,"text":"甲，乙"},'
            '{"x":5,"y":"9","w":20,"h":30,"text":"丙"}'
            "]}"
        )
        adapter = _FakeFullAdapter()
        attach_page_text_ref(adapter, self.image)
        self.assertEqual(2, len(adapter.page_text_lines))
        self.assertEqual("甲，乙", adapter.page_text_lines[0]["text"])
        self.assertEqual(9, adapter.page_text_lines[1]["y"])  # 数值容错

    def test_no_sidecar_or_no_records_not_attached(self):
        # 无侧车 / 旧版侧车（只有行数计数）/ 坏 JSON：都不挂，静默
        for payload in (None, '{"engine":"paddle","lines":22}', "{oops"):
            if payload is not None:
                self._write_meta(payload)
            adapter = _FakeFullAdapter()
            attach_page_text_ref(adapter, self.image)
            self.assertFalse(hasattr(adapter, "page_text_lines"))
            (FsPath(self.tmp.name) / "direct_text" / "page_005.meta.json").unlink(
                missing_ok=True
            )

    def test_degenerate_records_filtered(self):
        self._write_meta(
            '{"line_records":[{"x":0,"y":0,"w":0,"h":10,"text":"壞"},'
            '{"x":1,"y":1,"w":10,"h":10,"text":"好"}]}'
        )
        adapter = _FakeFullAdapter()
        attach_page_text_ref(adapter, self.image)
        self.assertEqual(1, len(adapter.page_text_lines))
        self.assertEqual("好", adapter.page_text_lines[0]["text"])

    def test_kill_switch_env(self):
        self._write_meta('{"line_records":[{"x":1,"y":1,"w":5,"h":5,"text":"甲"}]}')
        adapter = _FakeFullAdapter()
        with patch.dict(os.environ, {"FULL_TEXT_CHECK": "0"}):
            attach_page_text_ref(adapter, self.image)
        self.assertFalse(hasattr(adapter, "page_text_lines"))


class RegionLabelPassthroughTests(unittest.TestCase):
    def test_request_defaults(self):
        req = SegmentRequest(image_path="x.png")
        self.assertEqual("kraken", req.engine)
        self.assertIsNone(req.paddle_model)
        region = SegmentRegionRequest(
            image_path="x.png", x=0, y=0, w=1, h=1, line_id="l0"
        )
        self.assertEqual("", region.region_label)
        self.assertEqual("kraken", region.engine)


class RefreshFullTextCheckTests(unittest.TestCase):
    """/refresh_full_text_check：直读后按最新侧车行记录重算标注对照
    标记（纯 CPU，不跑模型）。"""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image = str(FsPath(self.tmp.name) / "page_001.png")
        with open(self.image, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n")
        meta_dir = FsPath(self.tmp.name) / "direct_text"
        meta_dir.mkdir(exist_ok=True)
        (meta_dir / "page_001.meta.json").write_text(
            json.dumps(
                {"line_records": [
                    {"x": 100, "y": 10, "w": 20, "h": 200, "text": "甲乙，丙"},
                    {"x": 60, "y": 10, "w": 20, "h": 200, "text": "子丑寅X辰"},
                ]},
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )

    def _call(self, lines):
        return api_segment.refresh_full_text_check(
            api_segment.RefreshFullTextCheckRequest(
                image_path=self.image,
                lines=[
                    api_segment.RefreshFullTextLine(**ln) for ln in lines
                ],
            )
        )

    def test_computes_extras_and_diff_indices(self):
        resp = self._call([
            {"id": "l0", "x": 100, "y": 10, "w": 20, "h": 200,
             "char_texts": ["甲", "乙", "丙"]},
            {"id": "l1", "x": 60, "y": 10, "w": 20, "h": 200,
             "char_texts": ["子", "丑", "寅", "卯", "辰"]},
        ])
        self.assertEqual(2, resp["ref_lines"])
        by_id = {u["id"]: u for u in resp["updates"]}
        self.assertEqual("甲乙，丙", by_id["l0"]["full_text"])
        self.assertEqual(["，"], by_id["l0"]["full_extras"])
        self.assertEqual([], by_id["l0"]["diff_indices"])
        self.assertEqual([3], by_id["l1"]["diff_indices"])

    def test_unmatched_line_is_cleared(self):
        resp = self._call([
            {"id": "far", "x": 900, "y": 900, "w": 20, "h": 200,
             "char_texts": ["舊", "標", "記"]},
        ])
        u = resp["updates"][0]
        self.assertEqual("", u["full_text"])
        self.assertEqual([], u["full_extras"])
        self.assertEqual([], u["diff_indices"])

    def test_no_sidecar_returns_empty_refs(self):
        (FsPath(self.tmp.name) / "direct_text" / "page_001.meta.json").unlink()
        resp = self._call([
            {"id": "l0", "x": 100, "y": 10, "w": 20, "h": 200,
             "char_texts": ["甲"]},
        ])
        self.assertEqual(0, resp["ref_lines"])
        self.assertEqual("", resp["updates"][0]["full_text"])

    def test_kill_switch(self):
        with patch.dict(os.environ, {"FULL_TEXT_CHECK": "0"}):
            resp = self._call([])
        self.assertEqual([], resp["updates"])
        self.assertTrue(resp["disabled"])

    def test_stamp_region_label(self):
        lines = [{"id": "l0", "chars": []}]
        api_segment._stamp_region_label(lines, "footer")
        self.assertEqual("footer", lines[0]["region_label"])
        self.assertEqual("annotation", lines[0]["layout_role"])
        # 空标签不回盖
        lines2 = [{"id": "l1"}]
        api_segment._stamp_region_label(lines2, "")
        self.assertNotIn("region_label", lines2[0])


if __name__ == "__main__":
    unittest.main()
