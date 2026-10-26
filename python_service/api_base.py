# -*- coding: utf-8 -*-
"""FastAPI 应用基座（从 main.py 拆出）：app 工厂与 lifespan、控制台日志、识别并发闸门、进程/显存统计与健康路由。各路由域模块 `from api_base import app` 注册路由；main.py 仍为 uvicorn 入口门面。"""
import base64
import functools
import importlib
import os
import sys
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import List, Optional
import cv2
import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import kraken_bridge
import segmenter
import char_cluster
import char_verify
import daemon_sizing
import page_dewarp
from imaging import imwrite_unicode
from layout_refinement import normalize_layout
from segmenter import (
    begin_debug_trace,
    debug_trace_snapshot,
    segment_image_with_metadata,
    segment_lines_in_region,
    get_char_candidates,
    make_kraken_char_splitter,
    mask_polarity_info,
    split_punct_merged_boxes,
    _imread,
    _text_mask_for_refinement,
    _split_chars_in_region,
    expand_line_rect_to_neighbor_ink,
)




BACKEND_BUILD = "text-progress-2026-10-25-v170"




def install_console_log(log_path: Path) -> None:
    """把 stdout/stderr 同步追加到日志文件（独立 CMD 日志窗口的数据源）。

    原输出保持不变（Flutter 管道照常接收），额外落盘一份：端口选择、
    模型加载、uvicorn 访问日志、识别过程与全部诊断日志都在内，排障
    时可在独立窗口实时查看（Get-Content -Wait）或直接发整份文件。"""
    import cleanup_service

    log_path.parent.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")

    class _Tee:
        def __init__(self, original, handle, prefix=""):
            self._original = original
            self._handle = handle
            self._prefix = prefix

        def write(self, text):
            try:
                # 落盘行统一加时间戳（管道原样输出不变）：uvicorn 访问日志
                # 与业务 print 都无时间，排查"进程死在哪个时刻"必须能和
                # 应用端日志对齐。空行不加戳，避免刷屏。
                stamp = time.strftime("%Y-%m-%d %H:%M:%S")
                # 写与清理截断共用一把锁：保尾截断（周期巡检/手动清理）
                # 读尾部→truncate→回写必须是原子段，否则并发写会在
                # 文件里留下稀疏洞或交错行。
                with cleanup_service.console_write_lock:
                    for line in text.splitlines() or [""]:
                        if line:
                            self._handle.write(f"[{stamp}] {self._prefix}{line}\n")
                        else:
                            self._handle.write("\n")
                    self._handle.flush()
            except Exception:
                pass
            # 控制台/管道写失败绝不向业务传播：App 侧管道消费端异常时
            # write/flush 抛 OSError（实测 Errno 22 Invalid argument，
            # 从端点里的 print(flush=True) 一路炸穿成纯文本 500
            # "Internal Server Error"，识别根本没开始就失败）——控制台
            # 输出丢了无所谓，业务不能陪葬。
            try:
                return self._original.write(text)
            except Exception:
                return len(text)

        def flush(self):
            try:
                self._handle.flush()
            except Exception:
                pass
            try:
                self._original.flush()
            except Exception:
                pass

        def isatty(self):
            return False

    handle = open(log_path, "a", encoding="utf-8", errors="replace")
    cleanup_service.register_active_log(log_path, handle)
    handle.write(
        f"\n===== 服务启动 {stamp} build={BACKEND_BUILD} pid={os.getpid()} =====\n"
    )
    handle.flush()
    sys.stdout = _Tee(sys.stdout, handle)
    # stderr 落盘带前缀（管道/控制台输出保持原样）：应用端跟随日志文件
    # 时据此区分来源着色，并喂给启动失败诊断。
    sys.stderr = _Tee(sys.stderr, handle, prefix="[stderr] ")




def _quiet_connection_lost(loop, context) -> None:
    """asyncio 异常处理器：静默 Windows Proactor 的良性断连噪音。

    客户端断开连接时 _ProactorBasePipeTransport._call_connection_lost 对
    已关闭的 socket 再 shutdown 会抛 WinError 10022（CPython 已知问题，
    无害），asyncio 默认处理器把它整段 traceback 打到 stderr——App 端
    每个轮询连接关闭都触发一次（7 行栈 × 每 3 秒），后端控制台被刷屏、
    有用的日志（worker mark stats 等）被淹没。只静默这一类，其余仍走
    默认处理器（真实异常照常报告）。
    """
    handle = str(context.get("handle") or "")
    exc = context.get("exception")
    if (
        "_call_connection_lost" in handle
        and isinstance(exc, OSError)
        and getattr(exc, "winerror", None) == 10022
    ):
        return
    loop.default_exception_handler(context)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # 装在 uvicorn 服务所用的循环上（lifespan 在该循环内运行）：
    # 见 _quiet_connection_lost 注释。
    import asyncio

    asyncio.get_running_loop().set_exception_handler(_quiet_connection_lost)

    # 后台预热线：启动常驻 Kraken daemon 并加载模型（GPU 繁忙时也要几十
    # 秒），用户首次识别不必再等冷启动。
    def _prewarm() -> None:
        try:
            kraken_bridge.prewarm()
        except Exception as exc:
            print(f"[prewarm] kraken daemon 预热失败: {exc}", flush=True)

    threading.Thread(target=_prewarm, daemon=True).start()

    # torch/ultralytics 冷导入要几十秒且长时间占 GIL：训练前检测此前在
    # 请求线程里 import，会把进程内其他接口一起拖慢（训练页轮询因此
    # 超时）。挪到启动后台预热，首次检测/首次识别不再撞上冷导入。
    def _prewarm_import() -> None:
        for name in ("torch", "ultralytics"):
            try:
                importlib.import_module(name)
            except Exception as exc:
                print(f"[prewarm] import {name} 失败: {exc}", flush=True)

    threading.Thread(target=_prewarm_import, daemon=True).start()

    # 诊断产物巡检：每 6h 清一次超龄/超额崩溃转储，并把超大的当前
    # 日志保尾截断（单次会话连跑数天时 service_console.log 仍会涨到
    # GB 级）。启动时的轮转/清理在 main.py（必须在打开日志前轮转）。
    import cleanup_service

    def _cleanup_loop() -> None:
        while True:
            time.sleep(6 * 3600)
            try:
                r = cleanup_service.periodic_cleanup()
                freed = (r.get("dumps") or {}).get("freed", 0) + (
                    r.get("old_logs") or {}
                ).get("freed", 0) + (r.get("trim") or {}).get("freed", 0)
                if freed:
                    print(f"[cleanup] 周期巡检回收 {freed / (1 << 20):.0f}MB", flush=True)
            except Exception as exc:
                print(f"[cleanup] 周期巡检失败: {exc}", flush=True)

    threading.Thread(target=_cleanup_loop, daemon=True).start()
    yield
    try:
        kraken_bridge.shutdown()
    except Exception as exc:
        print(f"[shutdown] kraken daemon 关闭异常: {exc}", flush=True)




app = FastAPI(lifespan=lifespan)


app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])



# ── 识别并发门：四槽 + 独占模式 ─────────────────────────────────────
# 旧实现是单把锁（同时只允许 1 个识别请求在途）。页间流水线上线后改为
# 双槽；按主区拆分批量任务（无 AI 时）把窗口放宽到 4 页后升到四槽：
# 整书队列仍 2 页在途，拆分队列无 AI 时 4 页在途——页 N 的 Kraken 识别
# （daemon 池内并行）与页 N+1 的版面检测（主进程 YOLO）跨页重叠；GPU
# 实际并发由 daemon 池的成员数自然约束，这里只限制"同时在途的识别
# 请求数"。超出的请求仍然立刻 409（不排队拖垮 GPU），客户端忙等沿用。
# 模型对比/基线评测（use_models=False / test_layer）会临时改写 segmenter
# 的全局模型状态，必须独占：等全部槽位排空后执行，期间其他请求 409
# 让路（带内互检，独占者不会被连续页流饿死）。
_RECOGNITION_SLOTS = 4
_recognition_slots = threading.BoundedSemaphore(_RECOGNITION_SLOTS)


_recognition_exclusive = threading.Lock()


_EXCLUSIVE_DRAIN_TIMEOUT = 300.0  # 独占等在途请求排空的上限（秒）

# 在途识别的端点计数（acquire/release 同线程配对，线程本地记录回退量）。
# 供后台预热/扩容让路判断（recognition_in_flight）：识别在途时再往同一
# 块 GPU 压新的模型加载，会与在途推理抢显存/算力——实测启动预热扩容
# 窗口（k1 就绪后并发拉起其余 daemon）撞上 VL 整页直读，直读被挤到
# 分钟级。
_recognition_inflight_lock = threading.Lock()
_recognition_inflight: dict[str, int] = {}
_recognition_held_local = threading.local()




def recognition_in_flight(endpoint: str | None = None) -> bool:
    """是否有识别请求在途；endpoint 给定时只查该端点。

    后台预热/扩容（kraken_proc）据此让路：等在途识别完成再拉起新的
    CUDA daemon，避免模型加载与在途推理抢同一块 GPU。"""
    with _recognition_inflight_lock:
        if endpoint is not None:
            return _recognition_inflight.get(endpoint, 0) > 0
        return any(v > 0 for v in _recognition_inflight.values())




def _record_inflight(endpoint: str, n: int) -> None:
    """槽位获取成功后记账：端点计数 +N，线程本地存回退量（release 用）。"""
    with _recognition_inflight_lock:
        _recognition_inflight[endpoint] = _recognition_inflight.get(endpoint, 0) + n
    held = getattr(_recognition_held_local, "held", None) or []
    held.append((endpoint, n))
    _recognition_held_local.held = held




def _forget_inflight(exclusive: bool) -> None:
    """释放前回退本线程最近一次获取的端点计数（无配对记录时静默跳过
    ——跨线程误用只退化记账精度，不影响槽位信号量本身）。"""
    held = getattr(_recognition_held_local, "held", None) or []
    if not held:
        return
    endpoint, n = held.pop()
    _recognition_held_local.held = held
    with _recognition_inflight_lock:
        remaining = _recognition_inflight.get(endpoint, 0) - n
        if remaining > 0:
            _recognition_inflight[endpoint] = remaining
        else:
            _recognition_inflight.pop(endpoint, None)




def _acquire_recognition_slot(endpoint: str, exclusive: bool = False) -> None:
    """占一个识别槽位，忙则抛 409。exclusive=True 独占两个槽位。"""
    if exclusive:
        if not _recognition_exclusive.acquire(blocking=False):
            print(
                f"[{endpoint}] busy: exclusive recognition already running",
                flush=True,
            )
            raise HTTPException(
                status_code=409,
                detail="模型对比/基线评测正在进行中，请等它完成后再试",
            )
        try:
            acquired = 0
            for _ in range(_RECOGNITION_SLOTS):
                if not _recognition_slots.acquire(
                    timeout=_EXCLUSIVE_DRAIN_TIMEOUT
                ):
                    raise HTTPException(
                        status_code=409,
                        detail="等待在途识别排空超时，请稍后再试",
                    )
                acquired += 1
        except BaseException:
            for _ in range(acquired):
                _recognition_slots.release()
            _recognition_exclusive.release()
            raise
        _record_inflight(endpoint, _RECOGNITION_SLOTS)
        return
    if _recognition_exclusive.locked():
        # 有人正在（或正在等）独占——常规请求让路，避免独占者被饿死。
        raise HTTPException(
            status_code=409,
            detail="模型对比/基线评测正在进行中，请等它完成后再试",
        )
    if not _recognition_slots.acquire(blocking=False):
        print(
            f"[{endpoint}] busy: recognition slots full (2 in flight)",
            flush=True,
        )
        raise HTTPException(
            status_code=409,
            detail="已有识别任务正在进行中，请等它完成后再试",
        )
    _record_inflight(endpoint, 1)




def _release_recognition_slot(exclusive: bool = False) -> None:
    _forget_inflight(exclusive)
    if exclusive:
        for _ in range(_RECOGNITION_SLOTS):
            _recognition_slots.release()
        _recognition_exclusive.release()
    else:
        _recognition_slots.release()




def _gated_recognition(endpoint: str):
    """识别类端点的并发门装饰器（常规单槽；语义见 _acquire_recognition_slot）。

    /segment 的独占与否取决于请求体（use_models/test_layer），不走本
    装饰器，改在 handler 内显式调 _acquire/_release_recognition_slot。"""

    def decorator(fn):
        # functools.wraps 保留原函数签名（__wrapped__）：FastAPI 按签名解析
        # 请求体模型，没有它 wrapper(*args, **kwargs) 会被当成必填 query
        # 参数 args/kwargs，所有请求直接 422。
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            _acquire_recognition_slot(endpoint)
            started = time.time()
            try:
                return fn(*args, **kwargs)
            finally:
                _release_recognition_slot()
                print(
                    f"[{endpoint}] finished in {time.time() - started:.1f}s",
                    flush=True,
                )

        return wrapper

    return decorator




class Block(BaseModel):
    id: str
    x: int
    y: int
    w: int
    h: int
    col: int
    order: int
    type: str
    confirmed: bool
    text: str = ""
    source: str = ""
    line_id: str = ""




@app.get("/health")
def health():
    return {"status": "ok", "build": BACKEND_BUILD}




# ── 识别服务资源占用（CPU / 内存 / 显存）──────────────────────────────────
# 供首页轮询展示"当前功能占了多少资源"。统计对象是后端自身进程树
# （uvicorn 服务进程 + 常驻 Kraken daemon 子进程），显存按这些 pid 在
# nvidia-smi 的 compute apps 里匹配，匹配不到（部分 WDDM 驱动不给
# per-process 显存）时回退为整卡已用显存。同端点还附整机口径的 system
# 块（`_system_stats`，识别监控悬浮窗曲线用）。

_process_stats_lock = threading.Lock()


_process_stats_cache: dict = {"ts": 0.0, "data": None}


_PROCESS_STATS_TTL = 1.5  # 秒；首页约 3s 轮询一次，缓存避免并发重复采样




def _nvidia_vram_bytes(pids: set) -> Optional[int]:
    """按进程汇总显存。三级策略：nvidia-smi 按进程（TCC/Linux 可用）→
    Windows WDDM 的 GPU Process Memory 性能计数器（本机实测可用，
    nvidia-smi 在 WDDM 下对所有进程都报 [N/A]）→ 整卡已用显存兜底。"""
    if not pids:
        return None
    try:
        import subprocess

        out = subprocess.run(
            [
                "nvidia-smi",
                "--query-compute-apps=pid,used_memory",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=6,
        ).stdout
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
            return total * 1024 * 1024  # MiB → bytes

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
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command", script],
            capture_output=True,
            text=True,
            timeout=8,
        ).stdout.strip()
        if out:
            try:
                return int(float(out.splitlines()[-1].strip()))
            except ValueError:
                pass

        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            timeout=6,
        ).stdout.strip()
        if out.isdigit():
            return int(float(out)) * 1024 * 1024
    except Exception:
        pass
    return None




def _collect_process_stats() -> Optional[dict]:
    try:
        import psutil
    except Exception:
        return None

    me = psutil.Process(os.getpid())
    try:
        procs = [me, *me.children(recursive=True)]
    except Exception:
        procs = [me]

    alive = []
    for p in procs:
        try:
            p.cpu_percent(None)  # 第一次调用只做基线，返回值无意义
            alive.append(p)
        except Exception:
            pass
    time.sleep(0.3)  # 采样窗口
    cpu = 0.0
    mem = 0
    pids = set()
    for p in alive:
        try:
            cpu += p.cpu_percent(None)
            mem += p.memory_info().rss
            pids.add(p.pid)
        except Exception:
            pass
    # psutil 的进程 CPU 口径是"100% = 跑满一个核心"，服务 + Kraken 两个进程
    # 相加动辄 120%/200%，和任务管理器（100% = 全部核心）对不上。
    # 按逻辑核心数归一化，展示口径与任务管理器一致。
    ncpu = psutil.cpu_count(logical=True) or 1
    return {
        "cpu_percent": round(cpu / ncpu, 1),
        "memory_bytes": mem,
        "vram_bytes": _nvidia_vram_bytes(pids),
    }




def _nvidia_gpu_stats() -> dict:
    """整卡 GPU 三值（利用率/已用显存/总显存），取第 0 张卡——与
    `_nvidia_vram_bytes` 的整卡兜底同口径（识别机基本都是单 N 卡）。无
    nvidia-smi 或解析失败时各值为 None，客户端（悬浮窗显存行）显示"不可用"。
    仅供 `_system_stats` 整机监控用；进程树口径的显存仍走 `_nvidia_vram_bytes`。"""
    import subprocess

    empty = {
        "gpu_util_percent": None,
        "vram_used_bytes": None,
        "vram_total_bytes": None,
    }
    try:
        out = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=utilization.gpu,memory.used,memory.total",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=6,
        ).stdout
        for line in out.splitlines():
            parts = [x.strip() for x in line.split(",")]
            if len(parts) != 3:
                continue
            try:
                util = float(parts[0])
                used_mib = float(parts[1])
                total_mib = float(parts[2])
            except ValueError:
                continue
            return {
                "gpu_util_percent": util,
                "vram_used_bytes": int(used_mib * 1024 * 1024),
                "vram_total_bytes": int(total_mib * 1024 * 1024),
            }
    except Exception:
        pass
    return empty


def _system_stats() -> Optional[dict]:
    """整机资源占用（CPU/内存/整卡 GPU），供识别监控悬浮窗画曲线。与
    `_collect_process_stats`（识别服务进程树口径，首页统计条用）是两个
    口径：system = 任务管理器视角的整机占用。CPU 用 0.25s 阻塞采样——
    /process_stats 是同步端点，本就跑在线程池里，不挡事件循环。"""
    try:
        import psutil
    except Exception:
        return None
    try:
        vm = psutil.virtual_memory()
        stats = {
            "cpu_percent": psutil.cpu_percent(interval=0.25),
            # Windows 任务管理器"已使用"= total − available（而非 total − free）
            "memory_used_bytes": vm.total - vm.available,
            "memory_total_bytes": vm.total,
        }
    except Exception:
        return None
    stats.update(_nvidia_gpu_stats())
    return stats


@app.get("/process_stats")
def process_stats():
    now = time.time()
    with _process_stats_lock:
        cached = _process_stats_cache
        if cached["data"] is not None and now - cached["ts"] < _PROCESS_STATS_TTL:
            return cached["data"]
        data = _collect_process_stats()
        result = {"available": data is not None, **(data or {})}
        # Kraken daemon 池的并行规模（首页"并行 N 路"展示）：total 是硬件
        # 决策的计划数，ready 是已就绪成员数（预热未完成时偏小）。
        result["workers"] = {
            "total": kraken_bridge.pool_planned(),
            "ready": kraken_bridge.pool_size(),
        }
        # 整机口径（悬浮窗曲线）：与进程树统计同享本端点的 1.5s TTL 缓存。
        # 跨语言格式基准：system 块字段（cpu_percent / memory_used_bytes /
        # memory_total_bytes / gpu_util_percent / vram_used_bytes /
        # vram_total_bytes）以本函数为准，Dart 侧 ServiceStats.fromJson
        # （flutter_app/lib/services/python_service.dart）镜像解析；只追加
        # 字段不改名，与 region 词表同一纪律。
        result["system"] = _system_stats()
        _process_stats_cache["ts"] = now
        _process_stats_cache["data"] = result
        return result
