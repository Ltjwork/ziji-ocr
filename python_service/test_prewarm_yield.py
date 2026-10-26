# -*- coding: utf-8 -*-
"""启动预热扩容让路测试：识别在途时 kraken 池扩容等待闸门放空。

背景：启动预热（k1 就绪 → 按配置后台并发拉起其余 daemon）与在途识别
并发时，多个 CUDA 模型加载抢同一块 GPU——实测预热扩容窗口撞上 VL 整页
直读，直读被挤到分钟级。本套件锁定两件事：
1. api_base 在途端点计数（recognition_in_flight）的记账正确性
  （同线程 acquire/release 配对、同端点多路、独占、端点互不串账）；
2. kraken_proc._wait_recognition_idle 的让路行为：空闲立即返回、
   在途等到放空、到上限照常放行、探测不可用按无识别降级。
不真拉 daemon（扩容线程本身不起，只测等待函数与记账）。
"""
import sys
import threading
import time
import unittest
from unittest.mock import patch

from fastapi import HTTPException

import kraken_proc
from api_base import (
    _acquire_recognition_slot,
    _release_recognition_slot,
    recognition_in_flight,
)


class RecognitionInFlightTest(unittest.TestCase):
    def tearDown(self):
        # 兜底：任何用例失败后不留悬空槽位污染后续用例（同线程配对）。
        held = getattr(api_base_held(), "held", None) or []
        while held:
            _release_recognition_slot()

    def test_single_endpoint_accounting(self):
        self.assertFalse(recognition_in_flight())
        _acquire_recognition_slot("read_page_text")
        try:
            self.assertTrue(recognition_in_flight())
            self.assertTrue(recognition_in_flight("read_page_text"))
            self.assertFalse(recognition_in_flight("segment"))
        finally:
            _release_recognition_slot()
        self.assertFalse(recognition_in_flight())
        self.assertFalse(recognition_in_flight("read_page_text"))

    def test_two_same_endpoint_release_one_by_one(self):
        _acquire_recognition_slot("segment")
        _acquire_recognition_slot("segment")
        try:
            _release_recognition_slot()
            self.assertTrue(recognition_in_flight("segment"))
        finally:
            _release_recognition_slot()
        self.assertFalse(recognition_in_flight("segment"))

    def test_endpoints_tracked_independently(self):
        _acquire_recognition_slot("read_page_text")
        _acquire_recognition_slot("segment")
        try:
            _release_recognition_slot()  # LIFO 弹出 segment
            self.assertFalse(recognition_in_flight("segment"))
            self.assertTrue(recognition_in_flight("read_page_text"))
        finally:
            _release_recognition_slot()  # 弹出 read_page_text
        self.assertFalse(recognition_in_flight())

    def test_exclusive_accounting_and_409(self):
        _acquire_recognition_slot("segment", exclusive=True)
        try:
            self.assertTrue(recognition_in_flight())
            self.assertTrue(recognition_in_flight("segment"))
            with self.assertRaises(HTTPException):
                _acquire_recognition_slot("read_page_text")
        finally:
            _release_recognition_slot(exclusive=True)
        self.assertFalse(recognition_in_flight())


class WaitRecognitionIdleTest(unittest.TestCase):
    def test_idle_returns_immediately(self):
        t0 = time.time()
        kraken_proc._wait_recognition_idle()
        self.assertLess(time.time() - t0, 1.0)

    def test_busy_waits_until_gate_released(self):
        acquired = threading.Event()

        def hold_request():
            _acquire_recognition_slot("read_page_text")
            acquired.set()
            time.sleep(0.4)
            _release_recognition_slot()

        threading.Thread(target=hold_request, daemon=True).start()
        self.assertTrue(acquired.wait(timeout=2))
        t0 = time.time()
        kraken_proc._wait_recognition_idle()
        elapsed = time.time() - t0
        self.assertGreaterEqual(elapsed, 0.2)
        self.assertFalse(recognition_in_flight())

    def test_busy_capped_by_yield_cap(self):
        _acquire_recognition_slot("read_page_text")
        try:
            with patch.object(kraken_proc, "PREWARM_YIELD_CAP_S", 0.1), patch.object(
                kraken_proc, "PREWARM_YIELD_POLL_S", 0.02
            ):
                t0 = time.time()
                kraken_proc._wait_recognition_idle()
                elapsed = time.time() - t0
            self.assertGreaterEqual(elapsed, 0.05)
            self.assertLess(elapsed, 2.0)
        finally:
            _release_recognition_slot()

    def test_missing_api_base_falls_back_to_no_wait(self):
        with patch.dict(sys.modules, {"api_base": None}):
            t0 = time.time()
            kraken_proc._wait_recognition_idle()
            self.assertLess(time.time() - t0, 1.0)


def api_base_held():
    from api_base import _recognition_held_local

    return _recognition_held_local


if __name__ == "__main__":
    unittest.main()
