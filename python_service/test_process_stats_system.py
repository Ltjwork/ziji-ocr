"""process_stats 的整机 system 块（BACKEND_BUILD v102 新增）。

不真跑 nvidia-smi/psutil：monkeypatch 注入假 subprocess 输出与假 psutil
模块，锁住字段结构与容错。跨语言格式基准声明在 api_base._system_stats
的 docstring；Dart 侧镜像见 flutter_app 的 ServiceStats.fromJson。"""

import subprocess
import sys
import types

import api_base


def _fake_run(stdout=""):
    def _run(*_args, **_kwargs):
        return types.SimpleNamespace(stdout=stdout, stderr="")

    return _run


def test_nvidia_gpu_stats_parses_first_card(monkeypatch):
    monkeypatch.setattr(
        subprocess,
        "run",
        _fake_run(" 45, 6000, 12288\n 0, 100, 4096\n"),
    )
    stats = api_base._nvidia_gpu_stats()
    assert stats["gpu_util_percent"] == 45.0
    assert stats["vram_used_bytes"] == 6000 * 1024 * 1024
    assert stats["vram_total_bytes"] == 12288 * 1024 * 1024


def test_nvidia_gpu_stats_skips_malformed_lines(monkeypatch):
    # WDDM 下 utilization 可能是 "[N/A]" 之类的非数字 → 该行跳过。
    monkeypatch.setattr(subprocess, "run", _fake_run(" [N/A], [N/A], [N/A]\n"))
    assert api_base._nvidia_gpu_stats() == {
        "gpu_util_percent": None,
        "vram_used_bytes": None,
        "vram_total_bytes": None,
    }


def test_nvidia_gpu_stats_swallow_exception(monkeypatch):
    def _boom(*_args, **_kwargs):
        raise FileNotFoundError("no nvidia-smi")

    monkeypatch.setattr(subprocess, "run", _boom)
    stats = api_base._nvidia_gpu_stats()
    assert stats["gpu_util_percent"] is None
    assert stats["vram_used_bytes"] is None


def _install_fake_psutil(monkeypatch):
    fake = types.SimpleNamespace(
        cpu_percent=lambda interval=None: 37.5,
        virtual_memory=lambda: types.SimpleNamespace(
            total=32 * 1024**3, available=8 * 1024**3
        ),
    )
    monkeypatch.setitem(sys.modules, "psutil", fake)


def test_system_stats_task_manager_semantics(monkeypatch):
    _install_fake_psutil(monkeypatch)
    monkeypatch.setattr(
        api_base,
        "_nvidia_gpu_stats",
        lambda: {
            "gpu_util_percent": 12.0,
            "vram_used_bytes": 5,
            "vram_total_bytes": 10,
        },
    )
    stats = api_base._system_stats()
    assert stats["cpu_percent"] == 37.5
    # 任务管理器口径：used = total − available。
    assert stats["memory_used_bytes"] == 24 * 1024**3
    assert stats["memory_total_bytes"] == 32 * 1024**3
    assert stats["gpu_util_percent"] == 12.0
    assert stats["vram_total_bytes"] == 10


def test_system_stats_none_without_psutil(monkeypatch):
    monkeypatch.setitem(sys.modules, "psutil", None)  # import 即抛 ImportError
    assert api_base._system_stats() is None


def test_process_stats_endpoint_carries_system_block(monkeypatch):
    monkeypatch.setattr(api_base, "_collect_process_stats", lambda: {"cpu_percent": 1.0})
    monkeypatch.setattr(api_base.kraken_bridge, "pool_planned", lambda: 2)
    monkeypatch.setattr(api_base.kraken_bridge, "pool_size", lambda: 1)
    monkeypatch.setattr(
        api_base,
        "_system_stats",
        lambda: {"cpu_percent": 9.0, "memory_used_bytes": 1, "memory_total_bytes": 2},
    )
    # 清掉 TTL 缓存，确保拿到本次注入而非上一测试的残留。
    monkeypatch.setattr(api_base, "_process_stats_cache", {"ts": 0.0, "data": None})
    result = api_base.process_stats()
    assert result["available"] is True
    assert result["cpu_percent"] == 1.0
    assert result["workers"] == {"total": 2, "ready": 1}
    assert result["system"]["cpu_percent"] == 9.0
    assert result["system"]["memory_total_bytes"] == 2
