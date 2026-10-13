# -*- coding: utf-8 -*-
"""PaddleOCR 引擎接入的单元测试。

覆盖：模型清单与归一（paddle_proc）、整行读法→合成 kchars 与 worker
请求构造（paddle_bridge）、适配器引擎能力标记、请求模型 engine/
paddle_model 字段默认值（老客户端不带字段 = kraken，行为不变）、
/segment 与 /recognize_char 的 engine 分发。
"""
import os
import pathlib
import unittest
from tempfile import TemporaryDirectory
from unittest.mock import patch

import api_recognize
import api_segment
from api_recognize import RecognizeCharRequest
from api_segment import (
    SegmentLinesInRegionRequest,
    SegmentRegionRequest,
    SegmentRequest,
)
import paddle_proc
from paddle_bridge import PaddleEngineAdapter, _synthesize_seq_chars

class ModelCatalogTests(unittest.TestCase):
    def test_default_is_small_distilled(self):
        # 用户指定的默认档：PP-OCRv6_small_rec（20.4MB 蒸馏小模型）。
        self.assertEqual(paddle_proc.DEFAULT_MODEL, "PP-OCRv6_small_rec")
        self.assertEqual(paddle_proc.normalize_model(None), "PP-OCRv6_small_rec")
        self.assertEqual(paddle_proc.normalize_model(""), "PP-OCRv6_small_rec")

    def test_unknown_model_falls_back_to_default(self):
        # 请求里传错名不能打死池：归一到默认档。
        self.assertEqual(
            paddle_proc.normalize_model("PP-OCRv9_xx"), "PP-OCRv6_small_rec"
        )

    def test_all_three_tiers_accepted(self):
        for name in (
            "PP-OCRv6_tiny_rec",
            "PP-OCRv6_small_rec",
            "PP-OCRv6_medium_rec",
        ):
            self.assertEqual(paddle_proc.normalize_model(name), name)

    def test_catalog_entries_carry_requirement_text(self):
        # 清单是给用户选型看的：每档必须有配置要求文案与体积。
        self.assertEqual(len(paddle_proc.PP_OCRV6_MODELS), 3)
        for entry in paddle_proc.PP_OCRV6_MODELS:
            self.assertIn("name", entry)
            self.assertGreater(entry["size_mb"], 0)
            self.assertTrue(entry.get("requirement"))
        self.assertIn("默认", paddle_proc.model_info(None)["label"])


class SynthesizeSeqCharsTests(unittest.TestCase):
    def test_vertical_even_division(self):
        chars = _synthesize_seq_chars(
            {"x": 10, "y": 100, "w": 40, "h": 300}, "天地人", 0.9, "vertical"
        )
        self.assertEqual([c["text"] for c in chars], ["天", "地", "人"])
        self.assertEqual(chars[0]["y"], 100)
        self.assertEqual(chars[0]["h"], 100)
        self.assertEqual(chars[2]["y"], 300)
        # 字框沿阅读轴覆盖整行（几何仅供对齐/兜底，均分即可）
        self.assertEqual(chars[0]["x"], 10)
        self.assertEqual(chars[0]["w"], 40)

    def test_horizontal_even_division(self):
        chars = _synthesize_seq_chars(
            {"x": 0, "y": 5, "w": 300, "h": 40}, "甲乙", 0.5, "horizontal"
        )
        self.assertEqual([c["text"] for c in chars], ["甲", "乙"])
        self.assertEqual(chars[0]["w"], 150)
        self.assertEqual(chars[1]["x"], 150)
        self.assertEqual(chars[0]["h"], 40)

    def test_empty_text_returns_empty(self):
        self.assertEqual(
            _synthesize_seq_chars({"x": 0, "y": 0, "w": 9, "h": 9}, "", 0.9, "vertical"),
            [],
        )


class _FakePool:
    """记录请求的假池：按 op 返回预制结果。"""

    size = 1
    planned = 1

    def __init__(self, results: dict):
        self.results = results
        self.requests: list[tuple[str, dict]] = []

    def request(self, op, payload=None, timeout=None):
        self.requests.append((op, payload or {}))
        return self.results.get(op, {})


class _FakeDaemon:
    """download_model 用的一次性假 daemon：ping 即就绪，shutdown 记录。"""

    def __init__(self):
        self.requests: list[str] = []
        self.shutdown_count = 0

    def request(self, op, payload=None, timeout=None):
        self.requests.append(op)
        return {"pong": True, "device": "cpu", "model": "fake"}

    def shutdown(self):
        self.shutdown_count += 1


class DownloadedModelsTests(unittest.TestCase):
    def test_official_models_dir_scan(self):
        # 官方缓存 <根>/official_models/<模型名>/：非空目录=已下载，
        # 空目录/杂名不算。
        with TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "cache")
            small = os.path.join(root, "official_models", "PP-OCRv6_small_rec")
            tiny = os.path.join(root, "official_models", "PP-OCRv6_tiny_rec")
            os.makedirs(small)
            os.makedirs(tiny)
            with open(os.path.join(small, "inference.pdiparams"), "wb") as f:
                f.write(b"x" * 16)
            with patch.object(paddle_proc, "_model_cache_roots",
                              return_value=[pathlib.Path(root)]):
                downloaded = paddle_proc.downloaded_models()
            self.assertEqual(downloaded, {"PP-OCRv6_small_rec"})

    def test_cache_roots_cover_env_override_and_default_home(self):
        with patch.dict(os.environ, {"PADDLE_PDX_CACHE_HOME": r"D:\pdx"}):
            roots = [str(r) for r in paddle_proc._model_cache_roots()]
        self.assertIn(r"D:\pdx", roots)
        self.assertTrue(any(r.endswith(".paddlex") for r in roots))


class DownloadModelTests(unittest.TestCase):
    def test_download_uses_temp_daemon_without_touching_pool(self):
        # 逐档下载不动现有池：spawn 一次性 daemon，ping（含下载）后即关。
        daemon = _FakeDaemon()
        spawn_args: list[tuple[str, str]] = []

        def fake_spawn(tag: str, model: str):
            spawn_args.append((tag, model))
            return daemon

        with patch.object(paddle_proc, "_spawn_daemon",
                          side_effect=fake_spawn), \
             patch.object(paddle_proc, "downloaded_models",
                          return_value=set()) as cached:
            result = paddle_proc.download_model("PP-OCRv6_medium_rec")
        self.assertTrue(result["ok"])
        self.assertEqual(result["model"], "PP-OCRv6_medium_rec")
        self.assertEqual(result["device"], "cpu")
        self.assertFalse(result["was_cached"])
        self.assertEqual(spawn_args, [("dl", "PP-OCRv6_medium_rec")])
        self.assertEqual(daemon.requests, ["ping"])
        self.assertEqual(daemon.shutdown_count, 1)
        cached.assert_called_once()

    def test_download_unknown_model_normalizes(self):
        daemon = _FakeDaemon()
        with patch.object(paddle_proc, "_spawn_daemon",
                          return_value=daemon), \
             patch.object(paddle_proc, "downloaded_models",
                          return_value={"PP-OCRv6_small_rec"}):
            result = paddle_proc.download_model("not-a-model")
        self.assertEqual(result["model"], "PP-OCRv6_small_rec")
        self.assertTrue(result["was_cached"])
        self.assertEqual(daemon.shutdown_count, 1)


class AdapterTests(unittest.TestCase):
    def test_capability_flags(self):
        # PP-OCR：横排可直读；竖排无域 → 整行读法跳过、由字框拼条补读。
        adapter = PaddleEngineAdapter(None)
        self.assertEqual(adapter.name, "paddle")
        self.assertTrue(adapter.horizontal_line_read)
        self.assertFalse(adapter.vertical_line_read)
        self.assertTrue(adapter.strip_read)
        self.assertEqual(adapter.cuts_src, "paddle-even-strips")
        self.assertEqual(adapter.ocr_tag, "paddle+PP-OCRv6_small_rec")
        self.assertEqual(adapter.char_source, adapter.ocr_tag)

    def test_model_binding_and_normalization(self):
        adapter = PaddleEngineAdapter("PP-OCRv6_medium_rec")
        self.assertEqual(adapter.ocr_tag, "paddle+PP-OCRv6_medium_rec")
        self.assertEqual(
            PaddleEngineAdapter("not-a-model").model, "PP-OCRv6_small_rec"
        )

    def test_read_lines_synthesizes_kchars_from_worker_text(self):
        # 横排直读：worker 只回整行文本，适配器按均分合成 chars。
        pool = _FakePool(
            {
                "recognize": {
                    "lines": [
                        {"x": 0, "y": 0, "w": 300, "h": 40, "text": "斗數", "conf": 0.9}
                    ]
                }
            }
        )
        adapter = PaddleEngineAdapter(None)
        with patch.object(paddle_proc, "ensure_pool", return_value=pool):
            lines = adapter.read_lines("img.png", [{"x": 0, "y": 0, "w": 300, "h": 40}],
                                       "horizontal", "ltr")
        self.assertEqual(len(lines), 1)
        self.assertEqual([c["text"] for c in lines[0]["chars"]], ["斗", "數"])

    def test_read_char_boxes_pads_and_sends_boxes(self):
        pool = _FakePool(
            {
                "read_boxes": {
                    "lines": [
                        {"x": 1, "y": 2, "w": 10, "h": 10, "text": "天", "conf": 0.8}
                    ]
                }
            }
        )
        adapter = PaddleEngineAdapter(None)
        with patch.object(paddle_proc, "ensure_pool", return_value=pool):
            out = adapter.read_char_boxes("img.png", [(1, 2, 10, 10)], "vertical", "rtl")
        self.assertEqual(out[0]["text"], "天")
        op, payload = pool.requests[0]
        self.assertEqual(op, "read_boxes")
        # pad=True（自动切分框）：先外扩 ~15% 边距再读（kraken 同语义）
        sent = payload["boxes"][0]
        self.assertLessEqual(sent["x"], 1)
        self.assertGreaterEqual(sent["w"], 10)
        self.assertGreaterEqual(sent["h"], 10)
        # pad=False（编辑器手画框，几何权威）：原样直读
        with patch.object(paddle_proc, "ensure_pool", return_value=pool):
            adapter.read_char_boxes(
                "img.png", [(1, 2, 10, 10)], "vertical", "rtl", pad=False
            )
        _, payload2 = pool.requests[1]
        self.assertEqual(payload2["boxes"][0], {"x": 1, "y": 2, "w": 10, "h": 10})

    def test_read_strip_chars_sends_rect_and_boxes(self):
        pool = _FakePool({"read_strip": {"text": "天地玄", "conf": 0.93}})
        adapter = PaddleEngineAdapter(None)
        rect = {"x": 5, "y": 0, "w": 30, "h": 90}
        boxes = [(5, 0, 30, 30), (5, 30, 30, 30), (5, 60, 30, 30)]
        with patch.object(paddle_proc, "ensure_pool", return_value=pool):
            kchars = adapter.read_strip_chars("img.png", rect, boxes, "vertical", "rtl")
        op, payload = pool.requests[0]
        self.assertEqual(op, "read_strip")
        self.assertEqual(payload["rect"], {"x": 5, "y": 0, "w": 30, "h": 90})
        self.assertEqual(len(payload["boxes"]), 3)
        self.assertEqual([c["text"] for c in kchars], ["天", "地", "玄"])


class RequestModelTests(unittest.TestCase):
    """engine/paddle_model 只追加字段：不带 = kraken，老客户端行为不变。"""

    def test_segment_request_defaults_to_kraken(self):
        req = SegmentRequest(image_path="x.png")
        self.assertEqual(req.engine, "kraken")
        self.assertIsNone(req.paddle_model)

    def test_paddle_fields_roundtrip(self):
        req = SegmentRequest(
            image_path="x.png", engine="paddle", paddle_model="PP-OCRv6_tiny_rec"
        )
        self.assertEqual(req.engine, "paddle")
        self.assertEqual(req.paddle_model, "PP-OCRv6_tiny_rec")

    def test_region_and_char_requests_have_engine(self):
        self.assertEqual(
            SegmentRegionRequest(
                image_path="x.png", x=0, y=0, w=1, h=1, line_id="l0"
            ).engine,
            "kraken",
        )
        self.assertEqual(
            SegmentLinesInRegionRequest(
                image_path="x.png", x=0, y=0, w=1, h=1
            ).engine,
            "kraken",
        )
        self.assertEqual(
            RecognizeCharRequest(image_path="x.png", x=0, y=0, w=1, h=1).engine,
            "kraken",
        )


def _fake_seg_result():
    return {
        "lines": [],
        "blocks": [],
        "engine": "yolo-fake",
        "ocr": "fake",
        "converter": "",
        "recognition_engine": "fake",
    }


class SegmentDispatchTests(unittest.TestCase):
    """/segment 按 engine 分发：paddle 走 paddle_bridge（带模型），kraken
    走 kraken_bridge（不带新参数，行为不变）。"""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image = os.path.join(self.tmp.name, "p.png")
        with open(self.image, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n")

    def _segment(self, req: SegmentRequest):
        with patch.object(api_segment, "segment_image_with_metadata",
                          return_value=_fake_seg_result()), \
             patch.object(api_segment, "make_kraken_char_splitter",
                          return_value=None), \
             patch.object(api_segment, "_acquire_recognition_slot"), \
             patch.object(api_segment, "_release_recognition_slot"), \
             patch("kraken_bridge.apply_kraken_recognition",
                   side_effect=lambda result, *a, **k: dict(
                       result, ocr="kraken+chat_rec", recognition_engine="kraken")) as kr, \
             patch("paddle_bridge.apply_paddle_recognition",
                   side_effect=lambda result, *a, **k: dict(
                       result, ocr=f"paddle+{k.get('model') or 'PP-OCRv6_small_rec'}",
                       recognition_engine="paddle")) as pd:
            out = api_segment.segment(req)
        return out, kr, pd

    def test_default_engine_calls_kraken_only(self):
        out, kr, pd = self._segment(SegmentRequest(image_path=self.image))
        self.assertEqual(out["recognition_engine"], "kraken")
        kr.assert_called_once()
        pd.assert_not_called()
        # kraken 分支不新增关键字参数（历史调用面不变）
        self.assertNotIn("model", kr.call_args.kwargs)

    def test_paddle_engine_calls_paddle_with_model(self):
        out, kr, pd = self._segment(
            SegmentRequest(
                image_path=self.image,
                engine="paddle",
                paddle_model="PP-OCRv6_medium_rec",
            )
        )
        self.assertEqual(out["recognition_engine"], "paddle")
        self.assertEqual(out["ocr"], "paddle+PP-OCRv6_medium_rec")
        pd.assert_called_once()
        self.assertEqual(pd.call_args.kwargs.get("model"), "PP-OCRv6_medium_rec")
        kr.assert_not_called()


class RecognizeCharDispatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image = os.path.join(self.tmp.name, "c.png")
        with open(self.image, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n")

    def _recognize(self, req: RecognizeCharRequest):
        with patch.object(api_recognize, "get_char_candidates",
                          return_value=[]), \
             patch.object(api_recognize, "begin_debug_trace"), \
             patch.object(api_recognize, "debug_trace_snapshot",
                          return_value=[]), \
             patch("kraken_bridge.recognize_char",
                   return_value={"text": "天", "conf": 0.9}) as kr, \
             patch("paddle_bridge.paddle_recognize_char",
                   return_value={"text": "地", "conf": 0.8}) as pd:
            out = api_recognize.recognize_char.__wrapped__(req)
        return out, kr, pd

    def test_dispatch(self):
        # 默认 kraken
        out, kr, pd = self._recognize(
            RecognizeCharRequest(image_path=self.image, x=0, y=0, w=9, h=9)
        )
        self.assertEqual(out["text"], "天")
        kr.assert_called_once()
        pd.assert_not_called()
        # engine=paddle 带模型
        out, kr, pd = self._recognize(
            RecognizeCharRequest(
                image_path=self.image, x=0, y=0, w=9, h=9,
                engine="paddle", paddle_model="PP-OCRv6_tiny_rec",
            )
        )
        self.assertEqual(out["text"], "地")
        pd.assert_called_once()
        self.assertEqual(pd.call_args.kwargs.get("model"), "PP-OCRv6_tiny_rec")
        kr.assert_not_called()


if __name__ == "__main__":
    unittest.main()
