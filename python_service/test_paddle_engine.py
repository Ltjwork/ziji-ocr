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
            "PP-OCRv3_mobile_rec",
            "PaddleOCR-VL-1.6",
        ):
            self.assertEqual(paddle_proc.normalize_model(name), name)

    def test_catalog_entries_carry_requirement_text(self):
        # 清单是给用户选型看的：每档必须有配置要求文案与体积。
        # v6 三档 + v3 轻量档 + VL 视觉语言模型（仅整页直读）。
        self.assertEqual(len(paddle_proc.PP_OCRV6_MODELS), 5)
        for entry in paddle_proc.PP_OCRV6_MODELS:
            self.assertIn("name", entry)
            self.assertGreater(entry["size_mb"], 0)
            self.assertTrue(entry.get("requirement"))
        self.assertIn("默认", paddle_proc.model_info(None)["label"])
        vl = paddle_proc.model_info("PaddleOCR-VL-1.6")
        self.assertIn("仅整页直读", vl["requirement"])


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
        # 官方缓存 <根>/official_models/<模型名>/：带模型配置(inference.yml)
        # 才算已下载；空目录/半截目录（中断的下载，缺配置）/杂名不算。
        with TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "cache")
            small = os.path.join(root, "official_models", "PP-OCRv6_small_rec")
            tiny = os.path.join(root, "official_models", "PP-OCRv6_tiny_rec")
            partial = os.path.join(root, "official_models", "PP-OCRv3_mobile_rec")
            os.makedirs(small)
            os.makedirs(tiny)
            os.makedirs(partial)
            with open(os.path.join(small, "inference.yml"), "w") as f:
                f.write("model_name: PP-OCRv6_small_rec\n")
            with open(os.path.join(partial, "inference.pdiparams"), "wb") as f:
                f.write(b"x" * 16)  # 半截：有权重没配置
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


class VlMergeTextsTests(unittest.TestCase):
    """VL 直读混合对齐（paddle_worker._vl_merge_texts）：VL 行文本（带
    标点）换装到 PP-OCR 行框（几何准、无标点）上。"""

    @staticmethod
    def _line(x, text):
        return {"x": x, "y": 0, "w": 10, "h": 100, "text": text,
                "conf": 0.9, "chars": []}

    def test_punctuated_vl_text_replaces_geo_text(self):
        import paddle_worker

        geo = [self._line(0, "甲乙丙丁")]
        out = paddle_worker._vl_merge_texts(
            geo, ["甲乙，丙丁。"]
        )
        self.assertEqual(out[0]["text"], "甲乙，丙丁。")
        self.assertGreater(out[0]["conf"], 0.55)

    def test_unmatched_geo_lines_keep_own_text(self):
        import paddle_worker

        geo = [self._line(0, "正文一行"), self._line(1, "8")]
        out = paddle_worker._vl_merge_texts(geo, ["正文一行，"])
        self.assertEqual(out[0]["text"], "正文一行，")
        self.assertEqual(out[1]["text"], "8")  # 页码噪声：VL 没读它

    def test_unmatched_vl_line_appended_not_lost(self):
        import paddle_worker

        geo = [self._line(0, "甲乙")]
        out = paddle_worker._vl_merge_texts(
            geo, ["甲乙，", "完全对不上的新行"]
        )
        texts = [l["text"] for l in out]
        self.assertIn("完全对不上的新行", texts)

    def test_no_geo_lines_falls_back_to_zero_box(self):
        import paddle_worker

        out = paddle_worker._vl_merge_texts([], ["第一行", "第二行"])
        self.assertEqual([l["text"] for l in out], ["第一行", "第二行"])
        self.assertTrue(all(l["w"] == 0 for l in out))


class VlParagraphMergeTests(unittest.TestCase):
    """版面分析开启时 VL 块=整段段落（几十上百字），逐行相似度全部
    落空——段落切片路径按阅读序把段落切回行，标点落回各行（用户实测
    失败形态：22 行全用无标点 PP 文本、整段带标点文本堆在零框行）。
    段落判据：纯文本长度 > max(48, 2×行中位字数)，测试数据按真实
    规模构造。"""

    CH = "甲乙丙丁戊己庚辛壬癸子丑寅卯" * 4   # 56 字 → 4 行×14 字

    @classmethod
    def _geo(cls):
        def line(x, i):
            return {"x": x, "y": 0, "w": 10, "h": 100,
                    "text": cls.CH[i * 14:(i + 1) * 14],
                    "conf": 0.9, "chars": []}
        # 阅读序 rtl：x 大在前
        return [line(50, 0), line(35, 1), line(20, 2), line(5, 3)]

    def test_paragraph_slices_back_to_lines_with_punct(self):
        import paddle_worker

        geo = self._geo()
        parts = [g["text"] for g in geo]
        para = "，".join(parts) + "矣。"   # 56 字 + 标点 > 段落门槛 48
        self.assertGreater(
            len(paddle_worker._plain_chars(para)),
            max(48, 14 * 2),
        )
        out = paddle_worker._vl_merge_texts(
            geo, [para], "vertical", "rtl", "ttb"
        )
        self.assertEqual(parts[0] + "，", out[0]["text"])
        self.assertEqual(parts[1] + "，", out[1]["text"])
        self.assertEqual(parts[2] + "，", out[2]["text"])
        self.assertEqual(parts[3] + "矣。", out[3]["text"])
        # 不再产生零框兜底副本
        self.assertEqual(4, len(out))
        self.assertTrue(all(l["w"] > 0 for l in out))

    def test_paragraph_slice_keeps_unmatched_geo_text(self):
        import paddle_worker

        geo = self._geo() + [
            {"x": 70, "y": 0, "w": 10, "h": 100, "text": "頁碼",
             "conf": 0.9, "chars": []},
        ]
        parts = [g["text"] for g in geo[:4]]
        para = "，".join(parts) + "矣。"
        out = paddle_worker._vl_merge_texts(
            geo, [para], "vertical", "rtl", "ttb"
        )
        by_text = {l["text"]: l for l in out}
        self.assertIn(parts[0] + "，", by_text)
        self.assertIn("頁碼", by_text)   # 段落里没有：保留原文
        self.assertIn(parts[3] + "矣。", by_text)

    def test_unmatchable_paragraph_not_lost(self):
        import paddle_worker

        geo = self._geo()
        para = "完全无关的一整段文字，与行内容毫无重叠。" * 3
        out = paddle_worker._vl_merge_texts(
            geo, [para], "vertical", "rtl", "ttb",
        )
        texts = [l["text"] for l in out]
        self.assertIn(para, texts)

    def test_line_scale_texts_still_match_directly(self):
        import paddle_worker

        # 混合形态：一条行级（直接换装）+ 一条段落级（切片），各得其所
        geo = self._geo()[:2]
        para = "，".join(g["text"] for g in geo) + "矣。" \
            + "再補一段：" + "乾坤震巽坎艮離" * 3 + "。"
        out = paddle_worker._vl_merge_texts(
            geo, [geo[0]["text"] + "，", para],
            "vertical", "rtl", "ttb",
        )
        self.assertEqual(self.CH[0:14] + "，", out[0]["text"])
        self.assertTrue(out[1]["text"].endswith("。"))
        self.assertEqual(2, len(out))


class ReadPageTextPayloadTests(unittest.TestCase):
    """read_page_text 请求体带方向参数（段落切片阅读序依赖）。"""

    def test_payload_carries_orientation(self):
        import paddle_bridge

        class _Pool:
            def __init__(self):
                self.calls = []
                self.size = 1

            def request(self, op, payload=None, timeout=None):
                self.calls.append((op, payload))
                return {"lines": []}

        pool = _Pool()
        with patch.object(paddle_proc, "ensure_pool", return_value=pool):
            paddle_bridge.read_page_text(
                "p.png", "vertical", "rtl", "btt", model="PP-OCRv6_small_rec"
            )
        op, payload = pool.calls[0]
        self.assertEqual("read_page", op)
        self.assertEqual("vertical", payload["orientation"])
        self.assertEqual("rtl", payload["horizontal_dir"])
        self.assertEqual("btt", payload["vertical_dir"])


class SmallMarkCountTests(unittest.TestCase):
    """直读标点诊断（paddle_worker._small_mark_count）：只读统计、
    依赖缺失降级返回 None，绝不影响识别路径。"""

    def test_small_marks_counted_between_chars(self):
        # 合成竖排列裁图：8 个 100×100 "字" + 3 个 40×40 "标点" 夹在字间
        # 空隙 → 小墨块统计应报 3（古籍小标点检测的合成复现）。
        try:
            import cv2  # noqa: F401
            import numpy as np  # noqa: F401
        except ImportError:
            self.skipTest("cv2/numpy 不可用（诊断统计依赖）")
        from PIL import Image

        import paddle_worker

        arr = np.full((1200, 200), 255, dtype=np.uint8)
        for i in range(8):
            y = 10 + 150 * i
            arr[y : y + 100, 50:150] = 0
        # 标点放在字间空隙正中（上下各留 5px 白边——与字紧贴的标点会被
        # 8 连通并进字块，真实古籍标点与字也总有空隙）。
        for y in (115, 415, 865):
            arr[y : y + 40, 85:125] = 0
        stats = paddle_worker._small_mark_count(Image.fromarray(arr, mode="L"))
        self.assertIsNotNone(stats)
        small, comps = stats
        self.assertEqual(small, 3)
        self.assertEqual(comps, 11)

    def test_too_small_image_returns_none(self):
        # 过小裁图（碎片行/噪声框）不诊断：None 而非异常。
        from PIL import Image

        import paddle_worker

        self.assertIsNone(
            paddle_worker._small_mark_count(Image.new("L", (8, 8), 255))
        )

    def test_punct_set_covers_common_marks(self):
        # 诊断口径覆盖常见中文标点。
        import paddle_worker

        for ch in "，。、；：！？…—·「」（）《》":
            self.assertIn(ch, paddle_worker._PUNCT_CHARS)


class LineModelFallbackTests(unittest.TestCase):
    """VL 行/字自动回退：line_model 把 VL 选择映射为默认 small 档
    （直读 read_page_text 不经此映射、仍用 VL）。"""

    def test_vl_falls_back_to_small(self):
        self.assertEqual(paddle_proc.line_model("PaddleOCR-VL-1.6"),
                         paddle_proc.DEFAULT_MODEL)
        self.assertEqual(paddle_proc.line_model(None),
                         paddle_proc.DEFAULT_MODEL)

    def test_ppocr_models_keep_own_name(self):
        for name in ("PP-OCRv6_tiny_rec", "PP-OCRv6_small_rec",
                     "PP-OCRv6_medium_rec", "PP-OCRv3_mobile_rec"):
            self.assertEqual(paddle_proc.line_model(name), name)

    def test_read_timeout_vl_window(self):
        # VL 直读超时放宽档（默认 900s，可用环境变量覆写）。
        self.assertGreaterEqual(paddle_proc.read_timeout(), 300.0)


class VlConfigTests(unittest.TestCase):
    """VL 解析配置（官网演示同款开关）：归一（白名单+默认值）与池签名。"""

    def test_normalize_defaults_match_historical_behavior(self):
        cfg = paddle_proc.normalize_vl_config(None)
        self.assertFalse(cfg["use_layout_detection"])
        self.assertFalse(cfg["use_doc_orientation_classify"])
        self.assertFalse(cfg["use_doc_unwarping"])
        self.assertFalse(cfg["use_chart_recognition"])
        self.assertFalse(cfg["use_seal_recognition"])
        self.assertFalse(cfg["use_ocr_for_image_block"])
        self.assertTrue(cfg["merge_layout_blocks"])  # 历史行为默认开

    def test_normalize_whitelist_and_bool(self):
        cfg = paddle_proc.normalize_vl_config({
            "use_layout_detection": True,
            "unknown_key": True,  # 白名单外丢弃
            "merge_layout_blocks": 0,  # 归一 bool
        })
        self.assertTrue(cfg["use_layout_detection"])
        self.assertFalse(cfg["merge_layout_blocks"])  # bool(0) = False
        self.assertNotIn("unknown_key", cfg)

    def test_pool_signature_changes_with_config(self):
        a = paddle_proc._vl_config_signature({"use_layout_detection": False})
        b = paddle_proc._vl_config_signature({"use_layout_detection": True})
        self.assertNotEqual(a, b)
        # 未给配置（None）与全默认同签名：池不无故重建。
        self.assertEqual(
            a, paddle_proc._vl_config_signature(None)
        )


class EnsurePoolFirstBuildTests(unittest.TestCase):
    """ensure_pool 首次建池不抛（v200 回归：后台关旧池线程移出 None 保护，
    首个 paddle 请求即 'NoneType' has no attribute 'shutdown'）。"""

    def test_first_build_with_no_pool(self):
        import paddle_proc

        with patch.object(paddle_proc, "_prewarm_pool"):
            paddle_proc._pool = None
            paddle_proc._pool_model = ""
            paddle_proc._pool_vl_sig = ""
            try:
                pool = paddle_proc.ensure_pool("PP-OCRv6_small_rec")
                self.assertIsNotNone(pool)
            finally:
                if paddle_proc._pool is not None:
                    paddle_proc._pool = None
                    paddle_proc._pool_model = ""
                    paddle_proc._pool_vl_sig = ""


if __name__ == "__main__":
    unittest.main()


class GateRegionIdTests(unittest.TestCase):
    """门控区回显带 id：GateRegion 透传 + seg_pipeline 对缺失 id 补
    mr_gate_NNN（客户端 MainRegion.fromJson 对缺失 id 抛 type cast，
    实测"重新识别当前页"type 'Null' 错误的根因）。"""

    def test_gate_region_carries_id(self):
        from api_segment import GateRegion

        g = GateRegion(x=1, y=2, w=3, h=4, id="mr_model_000")
        self.assertEqual(g.model_dump()["id"], "mr_model_000")
        # 不带 id 时 None（由 seg_pipeline 补）
        self.assertIsNone(GateRegion(x=1, y=2, w=3, h=4).model_dump()["id"])


if __name__ == "__main__":
    unittest.main()


class VlPredictKwargsTests(unittest.TestCase):
    """VL predict 级参数归一（paddle_worker._vl_predict_kwargs）。"""

    def test_whitelist_and_types(self):
        import paddle_worker

        out = paddle_worker._vl_predict_kwargs({
            "prompt_label": "Spotting",
            "repetition_penalty": 1.2,
            "temperature": 0.1,
            "top_p": 0.9,
            "min_pixels": 147384,
            "max_pixels": 1000000,
            "max_new_tokens": 4096,
            "bad_key": 1,
            "prompt_bad": "nope",
        })
        self.assertEqual(out["prompt_label"], "spotting")
        self.assertEqual(out["repetition_penalty"], 1.2)
        self.assertEqual(out["min_pixels"], 147384)
        self.assertNotIn("bad_key", out)
        self.assertNotIn("prompt_bad", out)

    def test_empty_ignore_list_is_valid(self):
        import paddle_worker

        out = paddle_worker._vl_predict_kwargs({"markdown_ignore_labels": []})
        # 空清单 = 辅助内容全部恢复解析，必须透传。
        self.assertEqual(out.get("markdown_ignore_labels"), [])

    def test_ignore_list_filtered_to_known_labels(self):
        import paddle_worker

        out = paddle_worker._vl_predict_kwargs({
            "markdown_ignore_labels": ["header", "bogus", "footer"],
        })
        self.assertEqual(out["markdown_ignore_labels"], ["header", "footer"])


if __name__ == "__main__":
    unittest.main()
