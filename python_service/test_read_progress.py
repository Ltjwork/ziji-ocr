# -*- coding: utf-8 -*-
"""整页直读进度登记测试（/read_page_text progress_token + /read_page_progress）。

覆盖三块：
1. read_progress 注册表生命周期：start→get（stage/detail/engine/elapsed）、
   set_stage 推进与未知阶段不覆盖、finish 清除、空 token 全链路 no-op；
2. TTL 惰性清理：异常退出的泄漏条目在写入时被扫掉；
3. 全链路：kraken 桥按 preparing→reading→assembling 打点（mock 池）；
   /read_page_text 带 token 识别完成后登记清除，轮询端点 active=false。
"""
import os
import unittest
from tempfile import TemporaryDirectory
from unittest.mock import patch

import cv2
import numpy as np

import api_page_text
import kraken_bridge
import read_progress
from read_progress import finish, get, set_stage, start


class RegistryLifecycleTest(unittest.TestCase):
    def test_start_get_stage_finish(self):
        self.assertEqual(get("t1"), {"active": False})
        start("t1", engine="paddle", detail="准备…")
        try:
            info = get("t1")
            self.assertTrue(info["active"])
            self.assertEqual(info["stage"], "preparing")
            self.assertEqual(info["engine"], "paddle")
            self.assertGreaterEqual(info["elapsed_s"], 0.0)
            set_stage("t1", "reading", "读字中…")
            info = get("t1")
            self.assertEqual(info["stage"], "reading")
            self.assertEqual(info["detail"], "读字中…")
        finally:
            finish("t1")
        self.assertEqual(get("t1"), {"active": False})

    def test_unknown_stage_does_not_overwrite(self):
        start("t2")
        try:
            set_stage("t2", "reading")
            set_stage("t2", "bogus_stage", "只更新说明不覆盖阶段")
            info = get("t2")
            self.assertEqual(info["stage"], "reading")
            self.assertEqual(info["detail"], "只更新说明不覆盖阶段")
        finally:
            finish("t2")

    def test_empty_token_noop(self):
        start("")
        set_stage("", "reading")
        finish("")
        self.assertEqual(get(""), {"active": False})

    def test_start_overwrites_previous_entry(self):
        # 同 token 重复开始（客户端重试复用）= 以最新一次为准。
        start("t3", detail="第一次")
        set_stage("t3", "reading")
        start("t3", detail="第二次")
        try:
            info = get("t3")
            self.assertEqual(info["stage"], "preparing")
            self.assertEqual(info["detail"], "第二次")
        finally:
            finish("t3")

    def test_ttl_sweep_on_write(self):
        start("t4")
        set_stage("t4", "reading")
        with patch.object(read_progress, "_TTL_S", 0.01):
            import time

            time.sleep(0.03)
            start("t5")
            try:
                # 超期条目被惰性清扫；本次写入的条目照常在册。
                self.assertEqual(get("t4"), {"active": False})
                self.assertTrue(get("t5")["active"])
            finally:
                finish("t5")


class _FakePool:
    def __init__(self):
        self.stages_at_request = None

    def request(self, op, payload, **kw):
        self.stages_at_request = get("kt")
        return {"lines": [{"x": 0, "y": 0, "w": 10, "h": 10, "text": "字"}]}


class BridgeStageFlowTest(unittest.TestCase):
    def test_kraken_bridge_reports_stages(self):
        start("kt", engine="kraken")
        fake = _FakePool()
        try:
            with patch.object(kraken_bridge, "_ensure_pool", return_value=fake):
                result = kraken_bridge.read_page_text(
                    "whatever.png",
                    "vertical",
                    "rtl",
                    "ttb",
                    progress_token="kt",
                )
            self.assertEqual(result["engine"], "kraken")
            # 推理进行中处于 reading 阶段；桥返回后已推进到 assembling。
            self.assertEqual(fake.stages_at_request["stage"], "reading")
            self.assertEqual(get("kt")["stage"], "assembling")
        finally:
            finish("kt")


class RouteTokenFlowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image_path = os.path.join(self.tmp.name, "page.png")
        cv2.imwrite(
            self.image_path, np.full((240, 180, 3), 240, dtype=np.uint8)
        )

    def test_route_clears_entry_and_endpoint_reports(self):
        req = api_page_text.ReadPageTextRequest(
            image_path=self.image_path,
            engine="kraken",
            progress_token="rt",
        )
        with patch(
            "kraken_bridge.read_page_text",
            return_value={
                "text": "正文",
                "lines": [],
                "engine": "kraken",
                "ocr": "kraken+chat_rec",
                "excluded_lines": 0,
            },
        ):
            result = api_page_text.read_page_text(req)
        self.assertIn("elapsed_s", result)
        # 识别结束（成败都）登记清除：轮询端点拿到 active=false。
        self.assertEqual(api_page_text.read_page_progress("rt"), {"active": False})

    def test_progress_endpoint_reports_active_entry(self):
        start("ep", engine="kraken", detail="准备 Kraken 引擎池")
        try:
            info = api_page_text.read_page_progress("ep")
            self.assertTrue(info["active"])
            self.assertEqual(info["detail"], "准备 Kraken 引擎池")
            self.assertEqual(
                api_page_text.read_page_progress("unknown"), {"active": False}
            )
        finally:
            finish("ep")


if __name__ == "__main__":
    unittest.main()
