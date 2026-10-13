"""daemon_sizing 表驱动单测（纯函数，不起任何进程）。

覆盖两套并行度决策：Kraken daemon（decide_worker_count，显存/CUDA）
与批量摆正 worker 池（decide_dewarp_workers，纯 CPU/内存）。"""

import daemon_sizing
from daemon_sizing import GB, MB, decide_dewarp_workers, decide_worker_count


def _decide(monkeypatch, env="", **kw):
    monkeypatch.setenv("OCR_KRAKEN_WORKERS", env)
    args = {
        "cpu_phys": 16,
        "ram_available": 32 * GB,
        "cuda": True,
        "vram_free": 6 * GB + int(0.5 * GB),
        "vram_total": 8 * GB,
        "per_daemon_vram": int(1.2 * GB),
    }
    args.update(kw)
    return decide_worker_count(**args)


def test_env_override_wins(monkeypatch):
    n, why = _decide(monkeypatch, env="6")
    assert n == 6
    assert "OCR_KRAKEN_WORKERS=6" in why


def test_env_override_clamped(monkeypatch):
    assert _decide(monkeypatch, env="99")[0] == daemon_sizing.WORKERS_MAX
    assert _decide(monkeypatch, env="0")[0] == daemon_sizing.WORKERS_MIN
    assert _decide(monkeypatch, env="-3")[0] == daemon_sizing.WORKERS_MIN


def test_env_garbage_falls_back_to_auto(monkeypatch):
    n, why = _decide(monkeypatch, env="abc")
    assert n > 1 and "显存" in why  # 走了 CUDA 自动决策而不是崩


def test_cuda_budget_math(monkeypatch):
    # total=16GB → reserve=max(1.5, 4.0)=4.0GB；free=10GB → budget=6.0GB；
    # per=2GB 空载实测 ×2 负载系数 = 4GB 峰值 → extra=1 → 1+1=2；
    # cpu_cap=8 不再裁。容量必须按峰值算：按空载值开满池，各 daemon 涨到
    # 峰值后会打穿整卡（显存停摆事故的根因）。
    n, why = _decide(
        monkeypatch,
        vram_total=16 * GB,
        vram_free=10 * GB,
        per_daemon_vram=2 * GB,
    )
    assert n == 2
    assert "峰值估" in why
    assert "空载实测 2048MB × 负载系数2" in why


def test_cuda_cpu_cap_applies(monkeypatch):
    # 预算够开很多（free 15GB − 预留 4GB = 11GB，每 daemon 峰值估 3GB
    # → 可开 4），但物理核只有 4 → cap=3。
    n, _ = _decide(
        monkeypatch,
        cpu_phys=4,
        vram_total=16 * GB,
        vram_free=15 * GB,
    )
    assert n == 3


def test_cuda_single_core_machine(monkeypatch):
    # 双核机器 cap=1，显存再多也只开 1 个。
    assert _decide(monkeypatch, cpu_phys=2)[0] == 1


def test_cuda_per_daemon_floor_when_unmeasured(monkeypatch):
    # WDDM 测不到 → 空载按 1500MB 下限兜底、×2 = 3GB 峰值：
    # total=4GB, free=2.6GB, reserve=1.5GB, budget=1.1GB → extra=0 → 1。
    n, why = _decide(
        monkeypatch,
        vram_total=4 * GB,
        vram_free=int(2.6 * GB),
        per_daemon_vram=None,
    )
    assert n == 1
    assert "按空载下限估" in why


def test_cuda_small_card(monkeypatch):
    # 2GB 小卡：reserve=max(1.5, 0.5)=1.5GB，free 1.2GB < reserve → 1。
    assert (
        _decide(
            monkeypatch,
            vram_total=2 * GB,
            vram_free=int(1.2 * GB),
            per_daemon_vram=700 * MB,
        )[0]
        == 1
    )


def test_cuda_rounding_down_only(monkeypatch):
    # total=24GB → reserve=6GB；峰值估 = 空载 1.6GB ×2 = 3.2GB；预算恰好
    # 2.9 个峰值 → 向下取整 2 个 → n=3。
    per_idle = int(1.6 * GB)
    per_peak = per_idle * 2
    budget = per_peak * 2 + int(0.9 * per_peak)  # 2.9 × 峰值
    free = int(24 * GB * 0.25) + budget  # reserve + budget
    n, _ = _decide(
        monkeypatch,
        vram_total=24 * GB,
        vram_free=free,
        per_daemon_vram=per_idle,
    )
    assert n == 3  # 1 + 2（不是 1+3）


def test_no_cuda_uses_cpu_formula(monkeypatch):
    n, why = _decide(monkeypatch, cuda=False)
    assert n == 4  # min(4, 16//2, 32GB//2GB=16)
    assert "无可用 CUDA" in why


def test_no_cuda_ram_bound(monkeypatch):
    # 可用内存只够 1 个 daemon（<4GB）。
    assert _decide(monkeypatch, cuda=False, ram_available=3 * GB)[0] == 1


def test_no_cuda_core_bound(monkeypatch):
    # 6 核 → 6//2=3。
    assert _decide(monkeypatch, cuda=False, cpu_phys=6)[0] == 3


def test_missing_vram_info_falls_back_to_cpu_formula(monkeypatch):
    # cuda=True 但 nvidia-smi/torch 都拿不到显存 → CPU 公式兜底。
    n, why = _decide(monkeypatch, vram_free=None, vram_total=None)
    assert "无可用 CUDA" in why
    assert n == 4


def test_per_process_vram_empty_pids():
    assert daemon_sizing.per_process_vram(set()) is None


# ── decide_dewarp_workers：批量摆正（纯 CPU OpenCV）并行数 ──


def _dewarp(monkeypatch, env="", **kw):
    monkeypatch.setenv("OCR_DEWARP_WORKERS", env)
    args = {"cpu_phys": 16, "ram_available": 32 * GB}
    args.update(kw)
    return decide_dewarp_workers(**args)


def test_dewarp_env_override_wins(monkeypatch):
    n, why = _dewarp(monkeypatch, env="3")
    assert n == 3
    assert "OCR_DEWARP_WORKERS=3" in why


def test_dewarp_env_override_clamped(monkeypatch):
    assert _dewarp(monkeypatch, env="99")[0] == daemon_sizing.DEWARP_WORKERS_CAP
    assert _dewarp(monkeypatch, env="0")[0] == 1
    assert _dewarp(monkeypatch, env="-2")[0] == 1


def test_dewarp_env_garbage_falls_back_to_auto(monkeypatch):
    n, why = _dewarp(monkeypatch, env="abc")
    assert n > 1 and "物理核" in why  # 走了自动决策而不是崩


def test_dewarp_cpu_cap_leaves_one_core(monkeypatch):
    # 4 物理核 → 留 1 核给系统 → CPU 上限 3。
    n, why = _dewarp(monkeypatch, cpu_phys=4)
    assert n == 3
    assert "CPU 上限 3" in why


def test_dewarp_single_core_machine(monkeypatch):
    # 1-2 物理核的机器至少也开 1 个。
    assert _dewarp(monkeypatch, cpu_phys=1)[0] == 1
    assert _dewarp(monkeypatch, cpu_phys=2)[0] == 1


def test_dewarp_hard_cap(monkeypatch):
    # 32 核 + 大内存 → 收敛到硬上限 6。
    n, why = _dewarp(monkeypatch, cpu_phys=32, ram_available=64 * GB)
    assert n == daemon_sizing.DEWARP_WORKERS_CAP
    assert "硬上限 6" in why


def test_dewarp_ram_bound(monkeypatch):
    # 可用内存 1GB：int(0.6GB // 384MB) = 1 → 内存受限只开 1 个。
    n, why = _dewarp(monkeypatch, ram_available=1 * GB)
    assert n == 1
    assert "内存上限 1" in why


def test_dewarp_ram_budget_fraction(monkeypatch):
    # 可用 8GB × 60% = 4.8GB ÷ 384MB = 12 → 内存不卡，CPU 15、硬上限 6 → 6。
    assert _dewarp(monkeypatch, ram_available=8 * GB)[0] == 6
