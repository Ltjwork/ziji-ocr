# -*- coding: utf-8 -*-
"""识别进程池控制测试：resize_pool 的环境变量写入/清除与等待语义、
pool_busy 透传、压测探针的行框构造。不真起 daemon（全 stub）。"""
import os

import api_kraken
import kraken_proc


class _FakePool:
    def __init__(self, size, planned, decided=True):
        self.size = size
        self.planned = planned
        self.decided = decided
        # 与真实池同语义：决策未完成时理由为空（resize_pool 才会兜底）
        self.decision_why = "测试决策" if decided else ""
        self.busy = 0


def test_resize_pool_sets_env_and_returns_actual(monkeypatch):
    written = {}

    def fake_shutdown():
        written["shutdown"] = True

    pool = _FakePool(size=3, planned=3)

    def fake_ensure():
        return pool

    monkeypatch.setattr(kraken_proc, "shutdown", fake_shutdown)
    monkeypatch.setattr(kraken_proc, "_ensure_pool", fake_ensure)
    monkeypatch.delenv("OCR_KRAKEN_WORKERS", raising=False)

    info = kraken_proc.resize_pool(3, timeout=2.0)
    assert written.get("shutdown") is True
    assert os.environ.get("OCR_KRAKEN_WORKERS") == "3"
    assert info["size"] == 3 and info["planned"] == 3
    assert info["why"] == "测试决策"


def test_resize_pool_none_clears_env(monkeypatch):
    monkeypatch.setenv("OCR_KRAKEN_WORKERS", "6")
    monkeypatch.setattr(kraken_proc, "shutdown", lambda: None)
    monkeypatch.setattr(kraken_proc, "_ensure_pool",
                        lambda: _FakePool(2, 2))
    info = kraken_proc.resize_pool(None, timeout=2.0)
    assert "OCR_KRAKEN_WORKERS" not in os.environ
    assert info["planned"] == 2


def test_resize_pool_clamps_and_timeout_reports_actual(monkeypatch):
    # 决策未完成（decided=False）时等到超时，返回实际规模而非挂死
    monkeypatch.setattr(kraken_proc, "shutdown", lambda: None)
    monkeypatch.setattr(kraken_proc, "_ensure_pool",
                        lambda: _FakePool(1, 12, decided=False))
    info = kraken_proc.resize_pool(99, timeout=1.0)
    assert os.environ.get("OCR_KRAKEN_WORKERS") == "12"  # 钳到 WORKERS_MAX
    assert info["size"] == 1 and info["planned"] == 12
    assert "决策未完成" in info["why"]


def test_pool_busy_mirrors_pool(monkeypatch):
    assert kraken_proc.pool_busy() == 0
    pool = _FakePool(2, 2)
    pool.busy = 2
    monkeypatch.setattr(kraken_proc, "_pool", pool)
    assert kraken_proc.pool_busy() == 2


def test_probe_line_rect_vertical_and_horizontal():
    v = api_kraken._probe_line_rect(2000, 3000, "vertical-rl")
    assert v["w"] == 250 and v["h"] == 3000  # 纵向带：1/8 宽、通高
    assert 0 <= v["x"] and v["x"] + v["w"] <= 2000
    h = api_kraken._probe_line_rect(2000, 3000, "horizontal-lr")
    assert h["w"] == 2000 and h["h"] == 375  # 横向带：通宽、1/8 高
    # 小图：带不小于 48px 且不越界
    s = api_kraken._probe_line_rect(100, 100, "vertical-rl")
    assert s["w"] == 48 and s["x"] + s["w"] <= 100
