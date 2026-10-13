"""Kraken daemon 并行数的硬件探测与决策。

并行数不写死：由 CPU 物理核数、可用内存、CUDA 显存（总量 / 空闲 /
单个 daemon 峰值占用）共同决定，环境变量 OCR_KRAKEN_WORKERS 可直接
覆盖（钳制在 1..12）。标准预留策略：显存至少留 max(1.5GB, 25%)，
CPU 至少留 1 个物理核给主服务与系统，硬上限 8（收益递减 + 内存上界）。

单 daemon 显存必须按峰值预算（不能拿空载值直接除）：caching allocator
只增不减，跑过几页大请求后每个 daemon 会从空载的 ~1.5GB 涨到 2.5~3.4GB，
按空载值开满池会把整卡打满——WDDM 转用共享内存换页、吞吐塌缩，全书
识别"显存到顶就停摆"（2026-09-29 事故的根因，详见更新日志 1.0.0+31）。

本模块只做一次性探测与纯函数决策，不持有常驻状态。
"""

from __future__ import annotations

import os
import subprocess

MB = 1024 * 1024
GB = 1024 * 1024 * 1024

WORKERS_ENV = "OCR_KRAKEN_WORKERS"
WORKERS_MIN = 1
WORKERS_MAX = 12
CPU_CAP = 8

DEWARP_WORKERS_ENV = "OCR_DEWARP_WORKERS"
DEWARP_WORKERS_CAP = 6
# CPU 预留：至少留 1 个物理核给主服务/系统/GUI。
DEWARP_CPU_RESERVE = 1
# 200DPI 页（约 1650×2350 RGB ≈ 11MB）拉平单 worker 的内存峰值估计：
# 读入原图 + 输出图 + remap 浮点坐标图 ×2 + 中间拷贝与 PNG 编码缓冲。
PER_WORKER_RAM = 384 * MB
# 可用内存只敢动六成（同机还有 GUI、识别等其他负载）。
DEWARP_RAM_FRACTION = 0.6

VRAM_RESERVE_MIN = int(1.5 * GB)
VRAM_RESERVE_RATIO = 0.25
# 空载占用下限（模型 42MB + CUDA 上下文 + 基础激活，实测 ~1.5GB）；
# 测不到 per-daemon 显存时拿它兜底。
PER_DAEMON_VRAM_FLOOR = int(1500 * MB)
# 空载 → 满载峰值的放大系数：推理期激活被 caching allocator 缓存后不归还，
# daemon 显存只增不减（实测空载 1.55GB 的机器，连续识别后各进程 1.6~3.4GB，
# 即 1.1~2.2 倍）。容量预算按峰值算，叠加量才不会吃穿预留。
PER_DAEMON_LOAD_FACTOR = 2.0
# 纯 CPU 模式：模型与行图像全在内存，按每 daemon 2GB 估。
PER_DAEMON_RAM_CPU = 2 * GB
CPU_MODE_CAP = 4


def _run(cmd: list[str], timeout: float) -> str | None:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        ).stdout
    except Exception:
        return None


def cuda_mem_info() -> tuple[int, int] | None:
    """(free_bytes, total_bytes)；torch 优先，nvidia-smi 兜底，都不通返回 None。

    多卡取显存最大的一张（daemon 全部跑在同一卡上，nvidia-smi 不指定
    GPU 时行为亦如此）。free 含其他进程已占的部分——决策时据此扣留。"""
    try:
        import torch

        if torch.cuda.is_available():
            free, total = torch.cuda.mem_get_info()
            return int(free), int(total)
    except Exception:
        pass
    out = _run(
        [
            "nvidia-smi",
            "--query-gpu=memory.total,memory.used",
            "--format=csv,noheader,nounits",
        ],
        6,
    )
    if not out:
        return None
    best: tuple[int, int] | None = None
    for line in out.splitlines():
        parts = [x.strip() for x in line.split(",")]
        if len(parts) != 2:
            continue
        try:
            total_mib = float(parts[0])
            used_mib = float(parts[1])
        except ValueError:
            continue
        free = int((total_mib - used_mib) * MB)
        total = int(total_mib * MB)
        if best is None or total > best[1]:
            best = (free, total)
    return best


def per_process_vram(pids: set) -> int | None:
    """给定进程集合的显存占用（字节），测不到返回 None。

    两级策略（与 main.py 的 _nvidia_vram_bytes 同源，去掉整卡兜底）：
    nvidia-smi compute-apps（TCC / Linux）→ Windows WDDM 性能计数器。
    决策场景不能把别的进程占的显存算到 daemon 头上（会低估可开数量），
    测不到时由调用方回落保守下限。"""
    if not pids:
        return None
    out = _run(
        [
            "nvidia-smi",
            "--query-compute-apps=pid,used_memory",
            "--format=csv,noheader,nounits",
        ],
        6,
    )
    if out:
        total = 0
        matched = False
        for line in out.splitlines():
            parts = [x.strip() for x in line.split(",")]
            if len(parts) != 2 or not parts[0].isdigit():
                continue
            try:
                mib = float(parts[1])
            except ValueError:
                continue  # WDDM 下是 [N/A]
            if int(parts[0]) in pids:
                matched = True
                total += int(mib)
        if matched:
            return total * MB
    # WDDM：按 pid 查性能计数器（Dedicated Usage 单位是字节）
    paths = ",".join(
        f"'\\GPU Process Memory(pid_{pid}*)\\Dedicated Usage'"
        for pid in sorted(pids)
    )
    script = (
        "$s = Get-Counter @(" + paths + ") -ErrorAction SilentlyContinue; "
        "if ($s) { "
        "$sum = ($s.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum; "
        "if ($sum -ne $null) { Write-Output $sum } }"
    )
    out = _run(["powershell", "-NoProfile", "-Command", script], 8)
    if out:
        try:
            return int(float(out.splitlines()[-1].strip()))
        except ValueError:
            pass
    return None


def cpu_physical_count() -> int:
    try:
        import psutil

        n = psutil.cpu_count(logical=False)
        if n:
            return n
        return psutil.cpu_count(logical=True) or 4
    except Exception:
        return os.cpu_count() or 4


def available_ram() -> int:
    try:
        import psutil

        return int(psutil.virtual_memory().available)
    except Exception:
        return 4 * GB


def decide_worker_count(
    cpu_phys: int,
    ram_available: int,
    cuda: bool,
    vram_free: int | None,
    vram_total: int | None,
    per_daemon_vram: int | None,
) -> tuple[int, str]:
    """返回 (并行 daemon 数, 决策理由)。理由字符串进日志，可解释"为什么是 N"。

    约定 vram_free 是"第一个 daemon 已加载完后"的空闲显存，因此
    CUDA 路径的结果 = 1 + 预算内还能再开几个。per_daemon_vram 是首
    daemon 的**空载**实测（ping 即模型加载完、尚未跑推理），这里乘
    PER_DAEMON_LOAD_FACTOR 放大为峰值估计再进预算——按空载值开满池，
    各 daemon 涨到峰值后叠加会打穿整卡（2026-09-29 事故）。"""
    env = os.environ.get(WORKERS_ENV, "").strip()
    if env:
        try:
            n = max(WORKERS_MIN, min(WORKERS_MAX, int(env)))
            return n, f"环境变量 {WORKERS_ENV}={env} → {n}（覆盖自动决策）"
        except ValueError:
            pass  # 坏值当未设置，走自动决策

    cpu_cap = min(max(1, cpu_phys - 1), CPU_CAP)
    if not cuda or not vram_total or not vram_free or vram_free <= 0:
        by_ram = int(ram_available // PER_DAEMON_RAM_CPU)
        n = max(1, min(CPU_MODE_CAP, cpu_phys // 2, by_ram))
        why = (
            f"无可用 CUDA：物理核 {cpu_phys}、可用内存 "
            f"{ram_available / GB:.0f}GB、每 daemon 估 {PER_DAEMON_RAM_CPU // GB}GB"
            f" → {n}（上限 {CPU_MODE_CAP}）"
        )
        return n, why

    per_daemon = int(
        max(per_daemon_vram or 0, PER_DAEMON_VRAM_FLOOR) * PER_DAEMON_LOAD_FACTOR
    )
    reserve = max(VRAM_RESERVE_MIN, int(vram_total * VRAM_RESERVE_RATIO))
    budget = vram_free - reserve
    extra = int(budget // per_daemon) if budget > 0 else 0
    n = max(1, min(1 + extra, cpu_cap))
    src = (
        f"空载实测 {per_daemon_vram / MB:.0f}MB × 负载系数"
        f"{PER_DAEMON_LOAD_FACTOR:g}"
        if per_daemon_vram
        else "无实测，按空载下限估"
    )
    why = (
        f"显存总量 {vram_total / GB:.1f}GB、首 daemon 后空闲 {vram_free / GB:.1f}GB、"
        f"单 daemon 峰值估 {per_daemon / MB:.0f}MB（{src}）、预留 "
        f"{reserve / GB:.1f}GB；CPU 物理核 {cpu_phys}（上限 {cpu_cap}）→ {n}"
    )
    return n, why


def decide_dewarp_workers(cpu_phys: int, ram_available: int) -> tuple[int, str]:
    """批量摆正（纯 CPU OpenCV，大运算释放 GIL）的并行 worker 数决策。

    与 Kraken daemon 不同：这里无常驻模型、不占显存，瓶颈是物理核与
    内存。环境变量 OCR_DEWARP_WORKERS 可直接覆盖（钳制 1..6）。"""
    env = os.environ.get(DEWARP_WORKERS_ENV, "").strip()
    if env:
        try:
            n = max(1, min(DEWARP_WORKERS_CAP, int(env)))
            return n, f"环境变量 {DEWARP_WORKERS_ENV}={env} → {n}（覆盖自动决策）"
        except ValueError:
            pass  # 坏值当未设置，走自动决策

    cpu_cap = max(1, cpu_phys - DEWARP_CPU_RESERVE)
    ram_budget = int(ram_available * DEWARP_RAM_FRACTION)
    by_ram = max(1, ram_budget // PER_WORKER_RAM)
    n = max(1, min(cpu_cap, by_ram, DEWARP_WORKERS_CAP))
    why = (
        f"物理核 {cpu_phys}（留 {DEWARP_CPU_RESERVE} 核给系统 → CPU 上限 "
        f"{cpu_cap}）、可用内存 {ram_available / GB:.0f}GB × "
        f"{DEWARP_RAM_FRACTION:.0%} ÷ 每 worker 约 {PER_WORKER_RAM // MB}MB → "
        f"内存上限 {by_ram}、硬上限 {DEWARP_WORKERS_CAP} → 并行 {n}"
    )
    return n, why
