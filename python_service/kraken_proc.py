# -*- coding: utf-8 -*-
"""Kraken daemon 进程与池管理（从 kraken_bridge 拆出）：python/conda 环境探测、
模型就位检查、_KrakenDaemon/_DaemonPool 常驻子进程池、预热与关闭。
kraken_bridge.py 仍为门面，外部 import 面不变。"""
from __future__ import annotations
import json
import os
import queue
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path
import numpy as np




SCRIPT_DIR = Path(__file__).resolve().parent


WORKER = SCRIPT_DIR / "kraken_worker.py"


MODEL_DIR = SCRIPT_DIR / "kraken_models"


REC_MODEL = MODEL_DIR / "chat_rec.mlmodel"



CHAT_RAW = "https://raw.githubusercontent.com/colibrisson/CHAT_models/main/models"


# 单请求超时：正常识别 0.1~45s；显存吃紧（WDDM 共享内存换页）时单请求可
# 劣化数十倍。300s 覆盖 ~7 倍劣化，且短于 App 端 10 分钟的整页超时——
# 到点杀 daemon 重启、请求按失败上抛让客户端重试，整条流水线才能继续
# 推进（900s 时代一次卡死请求要干磨 15 分钟，期间零日志、零进展）。
REQUEST_TIMEOUT = 300


PREWARM_PING_TIMEOUT = 300


# 致命（粘性）CUDA 错误标记：illegal memory access / device-side assert
# 一旦发生，该进程的 CUDA 上下文即告损坏，此后一切 CUDA 调用都返回同
# 一错误，只有重启进程才能恢复。识别到这些标记时杀掉 daemon 让下次
# 请求惰性重启，否则坏 daemon 被放回空闲队列、后续页面反复撞死在它
# 身上（用户实测整书识别报"Kraken worker 失败: CUDA error: an illegal
# memory access"后重试也失败）。CUDA OOM 是瞬态错误（换个请求/释放
# 缓存即恢复），显式排除，避免无谓的进程重启。
_FATAL_CUDA_MARKERS = (
    "cuda error",
    "illegal memory access",
    "cudaerrorillegaladdress",
    "device-side assert",
)


def is_fatal_cuda_error(text: str) -> bool:
    lowered = (text or "").lower()
    if "out of memory" in lowered:
        return False
    return any(marker in lowered for marker in _FATAL_CUDA_MARKERS)


class WorkerFailure(RuntimeError):
    """worker 侧识别失败（daemon 把 {ok:false} 翻译成它）。

    池的重试逻辑按类型识别（曾按错误文案 "Kraken worker 失败" 匹配，
    引入 PaddleOCR 复用同款池后文案随引擎变化，类型判定与文案解耦；
    文本本身保持各引擎原文，向用户展示不受影响）。"""




def log(msg: str) -> None:
    print(f"[kraken-bridge] {msg}", flush=True)
    # 汇入调试日志：/segment、/segment_region 返回的 debug_trace 与
    # /debug_char_split 的切分日志里能看到识别链路的决策，失败可追溯。
    try:
        import segmenter

        segmenter.append_debug_trace(f"[kraken-bridge] {msg}")
    except Exception:
        pass




def _candidate_pythons() -> list[Path]:
    env_override = os.environ.get("KRAKEN_PYTHON")
    candidates: list[Path] = []
    if env_override:
        candidates.append(Path(env_override))
    # 服务自身的 conda env 与 kraken env 是兄弟目录（envs/<service>/ 与 envs/kraken/）
    candidates.append(Path(sys.prefix).parent / "kraken" / "python.exe")
    candidates.append(Path(sys.prefix).parent / "kraken" / "bin" / "python")
    candidates.append(Path.home() / ".conda" / "envs" / "kraken" / "python.exe")
    conda_exe = os.environ.get("CONDA_EXE")
    if conda_exe:
        base = Path(conda_exe).parent.parent
        candidates.append(base / "envs" / "kraken" / "python.exe")
    return candidates




_python_cache: str | None = None




def kraken_python() -> str:
    """定位 kraken 环境的 python 可执行文件，找不到则抛出带安装指引的异常。"""
    global _python_cache
    if _python_cache:
        return _python_cache
    for candidate in _candidate_pythons():
        if candidate.exists():
            _python_cache = str(candidate)
            log(f"kraken python: {_python_cache}")
            return _python_cache
    raise RuntimeError(
        "未找到 kraken 环境（识别引擎 Kraken 需要独立环境）。"
        "请先运行 python_service\\install_kraken.bat 安装，"
        "或在环境变量 KRAKEN_PYTHON 中指定其 python.exe 路径。"
    )




def _resolve_rec_model() -> Path | None:
    """识别模型路径：散文件 kraken_models/ 优先，缺失（用户机安装形态）
    时回落 .zjpack 发行包的物化文件；两者皆无返回 None。"""
    try:
        if REC_MODEL.exists() and REC_MODEL.stat().st_size > 1024:
            return REC_MODEL
    except OSError:
        pass
    try:
        import model_store

        packed = model_store.resolve("kraken_rec")
        if packed:
            return Path(packed)
    except Exception:
        pass
    return None



def ensure_models() -> None:
    """识别模型缺失时自动从 CHAT_models 下载（约 42MB）。
    散文件与发行包物化文件任一存在即视为就位。"""
    if _resolve_rec_model() is not None:
        return
    MODEL_DIR.mkdir(exist_ok=True)
    url = f"{CHAT_RAW}/chat_rec.mlmodel"
    log(f"downloading {REC_MODEL.name} ...")
    tmp = REC_MODEL.with_suffix(REC_MODEL.suffix + ".part")
    with urllib.request.urlopen(url) as resp, open(tmp, "wb") as f:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    tmp.rename(REC_MODEL)
    log(f"model saved ({REC_MODEL.stat().st_size / 1e6:.1f} MB)")




class _KrakenDaemon:
    """常驻 kraken worker 的进程管理：单例、按需启动、崩溃/超时后自动重启。

    协议见 kraken_worker.py 模块注释（stdin/stdout 单行 JSON）。worker 的
    stderr（tlog 逐行进度日志）由常驻读线程收取后原样 print 透传——service
    的 stdout 落盘管道会让它同时出现在控制台与 service_console.log（此前
    stderr 直接继承原生控制台句柄，日志文件与日志跟随窗口都看不到，显存
    吃紧时的长等待无法与卡死区分）。stdout 用一个常驻读线程 + 队列收取，
    按 id 匹配请求；无法解析的行当噪音记日志跳过（个别库可能向 stdout
    打印非协议内容，不能让协议错位）。
    """

    def __init__(
        self,
        python: str,
        worker_script: str,
        request_timeout: float = REQUEST_TIMEOUT,
        tag: str = "",
        env_extra: dict[str, str] | None = None,
        label: str = "Kraken",
    ):
        self._python = python
        self._worker_script = worker_script
        self._request_timeout = request_timeout
        self._tag = tag
        # 引擎专属环境变量（模型路径/worker 标签等）由各引擎的 spawn 处
        # 计算后注入，daemon 本体保持引擎无关（PaddleOCR 池复用同一实现）。
        self._env_extra = dict(env_extra or {})
        self._label = label
        self._proc: subprocess.Popen | None = None
        self._lines: "queue.Queue[str | None]" = queue.Queue()
        self._lock = threading.Lock()
        self._req_id = 0

    # ── 进程生命周期 ──

    def _alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    @property
    def pid(self) -> int | None:
        proc = self._proc
        return proc.pid if proc is not None else None

    def _start(self) -> None:
        env = {**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"}
        if self._env_extra:
            env.update(self._env_extra)
        # 引擎专属 env（如 KRAKEN_REC_MODEL 的散文件/发行包解析）在构造
        # 处（各引擎 _spawn_daemon）算好传入——重启同一 daemon 实例时模型
        # 不会变，换模型走"关池重建新实例"，见 kraken_bridge.shutdown 语义。
        tag = f"[{self._tag}] " if self._tag else ""
        log(f"{tag}starting daemon: {self._python} {Path(self._worker_script).name}")
        self._proc = subprocess.Popen(
            [self._python, self._worker_script, "--daemon"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            # 必须 PIPE：下方 _stderr_reader 透传线程读 proc.stderr 把
            # worker 的 tlog 进度日志 print 进服务 stdout（_Tee 落盘 +
            # 应用后端控制台可见）。此前误为 None（继承父进程句柄）——
            # proc.stderr 为 None，读线程首行即 AttributeError 静默死掉，
            # worker 日志（含直读标点诊断 mark stats）全部不可见。
            stderr=subprocess.PIPE,
            env=env,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        self._lines = queue.Queue()

        def _reader(proc: subprocess.Popen, out: "queue.Queue[str | None]") -> None:
            try:
                for line in iter(proc.stdout.readline, ""):
                    out.put(line)
            except Exception:
                pass
            out.put(None)  # EOF/崩溃哨兵

        threading.Thread(target=_reader, args=(self._proc, self._lines), daemon=True).start()

        def _stderr_reader(proc: subprocess.Popen) -> None:
            # worker 的 tlog 进度日志原样透传进服务 stdout（_Tee 会同步
            # 落盘 service_console.log 并保持控制台输出），worker 自带的
            # [kraken-worker:tag] 前缀足以区分实例，不再叠加桥接前缀。
            try:
                for line in iter(proc.stderr.readline, ""):
                    text = line.strip()
                    if text:
                        print(text, flush=True)
            except Exception:
                pass

        threading.Thread(target=_stderr_reader, args=(self._proc,), daemon=True).start()

    def _kill(self) -> None:
        proc, self._proc = self._proc, None
        if proc is None:
            return
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass

    # ── 请求 ──

    def request(self, op: str, payload: dict | None = None, timeout: float | None = None) -> dict:
        timeout = self._request_timeout if timeout is None else timeout
        with self._lock:
            if not self._alive():
                self._start()
            self._req_id += 1
            rid = self._req_id
            req = json.dumps({"id": rid, "op": op, "payload": payload or {}}, ensure_ascii=False)
            try:
                assert self._proc is not None and self._proc.stdin is not None
                self._proc.stdin.write(req + "\n")
                self._proc.stdin.flush()
            except (BrokenPipeError, OSError) as exc:
                self._kill()
                raise RuntimeError(
                    f"{self._label} daemon 管道已断（{exc}），下次请求将自动重启"
                ) from exc

            deadline = time.time() + timeout
            wait_t0 = time.time()
            next_beat = 30.0
            who = f"[{self._tag}] " if self._tag else ""
            while True:
                remaining = deadline - time.time()
                if remaining <= 0:
                    self._kill()
                    raise RuntimeError(
                        f"{self._label} daemon 响应超时（>{timeout:.0f}s），已重启"
                    )
                try:
                    line = self._lines.get(timeout=remaining)
                except queue.Empty:
                    # 心跳：等待期零日志会被当成"后端卡死无输出"（显存打满
                    # 时单请求静默等数分钟是常态而非异常）。
                    waited = time.time() - wait_t0
                    if waited >= next_beat:
                        log(
                            f"{who}等待 {op} 响应已 {waited:.0f}s"
                            f"（>{timeout:.0f}s 将重启 daemon）"
                        )
                        next_beat += 30.0
                    continue
                if line is None:
                    self._kill()
                    raise RuntimeError(
                        f"{self._label} daemon 意外退出"
                        f"（详见 [{self._label.lower()}-worker] 日志）"
                    )
                text = line.strip()
                if not text:
                    continue
                try:
                    obj = json.loads(text)
                except ValueError:
                    log(f"daemon stdout noise: {text[:200]}")
                    continue
                if obj.get("id") != rid:
                    log(f"daemon stray response (id={obj.get('id')}), ignore")
                    continue
                if not obj.get("ok"):
                    err = str(obj.get("error") or "")
                    # worker 响应自带的 traceback 落进服务日志（worker 侧
                    # stderr 只有单行错误文本）：CUDA/驱动类故障的定位线索
                    # 只在这里，不落盘就只剩 App 弹窗里的一句错误。
                    tb = str(obj.get("traceback") or "").strip()
                    if tb:
                        log(f"{who}worker 失败 traceback：\n{tb[-1600:]}")
                    if is_fatal_cuda_error(err):
                        # 粘性 CUDA 错误：上下文已损坏，进程留着只会让后续
                        # 请求重复失败。杀掉，下次请求惰性重启新进程。
                        log(
                            f"{who}致命 CUDA 错误，daemon 进程已终止"
                            f"（下次请求自动重启）：{err[:200]}"
                        )
                        self._kill()
                    raise WorkerFailure(
                        f"{self._label} worker 失败: {obj.get('error')}"
                    )
                return obj.get("result") or {}

    def shutdown(self) -> None:
        # 正在加载模型/长请求的 daemon 其 request() 全程持锁（ping 首载
        # 含模型下载，可达数分钟）——优雅关闭等锁会把池重建/换模型卡到
        # 加载结束。限时拿锁，拿不到直接强杀：加载中途被杀无害（该进程
        # 不再接客，池重建的新成员会重新加载），在途请求由调用方按失败
        # 处理。
        if not self._lock.acquire(timeout=15):
            self._kill()
            return
        try:
            if not self._alive():
                return
            try:
                assert self._proc is not None and self._proc.stdin is not None
                req = json.dumps({"id": 0, "op": "shutdown", "payload": {}})
                self._proc.stdin.write(req + "\n")
                self._proc.stdin.flush()
                self._proc.stdin.close()
                try:
                    self._proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self._kill()
                    return
            except Exception:
                pass
            self._kill()
        finally:
            self._lock.release()




class _DaemonPool:
    """N 个 _KrakenDaemon 的并行池。

    成员逐个「ping 就绪后入池」（add_daemon），prewarm 未全部完成时池也
    能用已就绪的成员服务，request 阻塞等第一个成员就绪（与单 daemon
    懒启动等冷启动行为一致）。成员死亡由 _KrakenDaemon.request 自身的
    惰性重启兜底，池只负责调度与计数。shutdown 先拒新请求、等在途归零
    再统一关闭（模型热切换语义）。
    """

    def __init__(self, label: str = "Kraken") -> None:
        self._label = label
        self._idle: "queue.Queue[_KrakenDaemon]" = queue.Queue()
        self._members: list[_KrakenDaemon] = []
        self._busy_members: set[_KrakenDaemon] = set()
        self._lock = threading.Lock()
        self._drained = threading.Condition(self._lock)
        self._ready = threading.Condition(self._lock)
        self._busy = 0
        self._closing = False
        # 计划并行数（prewarm 决策后写入；仅用于 /process_stats 展示，
        # 成员起失败时成员数会小于它）。
        self.planned = 1
        # 决策是否完成及理由（resize_pool 等待就绪与端点展示用）；
        # k1 预热失败等早退路径不置位。
        self.decided = False
        self.decision_why = ""

    # ── 成员管理 ──

    def add_daemon(self, daemon: _KrakenDaemon) -> None:
        """ping 就绪的成员入池：登记成员并放入空闲队列供 acquire 取用。"""
        with self._lock:
            if self._closing:
                daemon.shutdown()
                return
            self._members.append(daemon)
            self._ready.notify_all()
        self._idle.put(daemon)

    @property
    def size(self) -> int:
        with self._lock:
            return len(self._members)

    @property
    def busy(self) -> int:
        with self._lock:
            return self._busy

    def wait_ready(self, count: int = 1, timeout: float | None = None) -> bool:
        """等至少 count 个成员就绪；超时返回 False。"""
        deadline = None if timeout is None else time.time() + timeout
        with self._ready:
            while len(self._members) < count:
                if deadline is None:
                    self._ready.wait(0.5)
                else:
                    remaining = deadline - time.time()
                    if remaining <= 0:
                        return False
                    self._ready.wait(min(remaining, 0.5))
        return True

    # ── 请求调度 ──

    def acquire(self, max_wait: float = REQUEST_TIMEOUT) -> _KrakenDaemon:
        """取一个空闲成员并计入在途；无空闲时轮询等待。

        池尚未就绪（prewarm 进行中）时等同冷启动等待——最多 max_wait，
        与单 daemon 懒启动的等待上限一致。closing 后拒绝新请求。"""
        deadline = time.time() + max_wait
        wait_t0 = time.time()
        next_beat = 15.0
        while True:
            try:
                daemon = self._idle.get(timeout=0.5)
            except queue.Empty:
                with self._lock:
                    if self._closing:
                        raise RuntimeError(f"{self._label} daemon 池已关闭")
                if time.time() >= deadline:
                    raise RuntimeError(f"等待空闲 {self._label} daemon 超时")
                waited = time.time() - wait_t0
                if waited >= next_beat:
                    log(
                        f"等待空闲 daemon 已 {waited:.0f}s"
                        f"（在途 {self._busy}/{len(self._members)}，"
                        f">{max_wait:.0f}s 报错）"
                    )
                    next_beat += 15.0
                continue
            with self._lock:
                if self._closing:
                    self._idle.put(daemon)
                    raise RuntimeError(f"{self._label} daemon 池已关闭")
                self._busy += 1
                self._busy_members.add(daemon)
                return daemon

    def _release(self, daemon: _KrakenDaemon) -> None:
        with self._lock:
            self._busy -= 1
            self._busy_members.discard(daemon)
            closing = self._closing
            if not closing:
                self._idle.put(daemon)
            self._drained.notify_all()
        if closing:
            daemon.shutdown()

    def request(
        self, op: str, payload: dict | None = None, timeout: float | None = None
    ) -> dict:
        daemon = self.acquire()
        try:
            try:
                return daemon.request(op, payload, timeout)
            except RuntimeError as exc:
                # 致命 CUDA 错误已由 _KrakenDaemon.request 杀掉坏进程；本页
                # 在（重启后的）新进程上重试一次，整书识别不因单次 CUDA
                # 崩溃整页失败。其余错误原样上抛。
                if not isinstance(exc, WorkerFailure) or not is_fatal_cuda_error(
                    str(exc)
                ):
                    raise
                log(
                    f"[fatal-cuda] {op} 命中致命 CUDA 错误，换新 daemon 重试一次"
                    f"：{str(exc)[:200]}"
                )
        finally:
            self._release(daemon)
        daemon = self.acquire()
        try:
            return daemon.request(op, payload, timeout)
        finally:
            self._release(daemon)

    # ── 关闭 ──

    def shutdown(self, drain_timeout: float = 30.0) -> None:
        """拒新请求 → 等在途归零（最多 drain_timeout）→ 关闭全部成员。

        超时仍有在途请求时直接 kill 成员（在途请求会收到管道断裂异常，
        由其调用方按识别失败处理）。"""
        with self._lock:
            if self._closing:
                return
            self._closing = True
        with self._drained:
            deadline = time.time() + drain_timeout
            while self._busy > 0:
                remaining = deadline - time.time()
                if remaining <= 0:
                    break
                self._drained.wait(min(remaining, 0.5))
        with self._lock:
            members, self._members = list(self._members), []
            stuck = set(self._busy_members)
            self._busy_members.clear()
        for member in members:
            if member in stuck:
                # 优雅 shutdown 会阻塞在成员锁上（在途请求持锁）——强杀，
                # 在途请求收到管道断裂/意外退出异常，由调用方按失败处理。
                member._kill()
            else:
                member.shutdown()




def _spawn_daemon(tag: str) -> _KrakenDaemon:
    env_extra: dict[str, str] = {}
    if tag:
        env_extra["KRAKEN_WORKER_ID"] = tag
    # 识别模型路径在父进程解析一次（散文件 ?? .zjpack 物化），env 传给
    # worker——worker 不 import model_store，kraken 子进程保持轻依赖。
    rec = _resolve_rec_model()
    if rec is not None and str(rec) != str(REC_MODEL):
        env_extra["KRAKEN_REC_MODEL"] = str(rec)
    return _KrakenDaemon(
        kraken_python(), str(WORKER), tag=tag, env_extra=env_extra
    )




# 池单例与构建守卫：懒建（首个请求）与服务预热（lifespan）两条路径并发
# 时只建一个池、只跑一次预热流程。
_pool: _DaemonPool | None = None


_pool_build_lock = threading.Lock()


_prewarm_guard = threading.Lock()




def _prewarm_pool(pool: _DaemonPool) -> None:
    """按硬件决策建池：① 起 daemon#1（ping 即模型加载完成）→ 实测其显存
    与 CUDA 可用性 → ② daemon_sizing 决定并行数 → ③ 后台并行起齐剩余
    成员，各自 ping 就绪后入池；个别成员起失败只缩容不报错（请求照跑）。

    幂等守卫：prewarm 与请求触发的懒建可能并发，_prewarm_guard 保证只
    执行一次；ensure_models 的固定 .part 临时文件也因此不会互踩。"""
    try:
        _prewarm_pool_inner(pool)
    except Exception as exc:
        # 典型场景：kraken 环境未安装（kraken_python 抛带安装指引的异常）。
        # 池保持空：首个请求会在 acquire 超时后拿到同样清晰的报错。
        log(f"daemon 池预热失败: {exc}")




def _prewarm_pool_inner(pool: _DaemonPool) -> None:
    with _prewarm_guard:
        try:
            ensure_models()
        except Exception as exc:
            log(f"模型下载/校验失败: {exc}（daemon 起不来时请求会显式报错）")
        started = time.time()
        first = _spawn_daemon("k1")
        device = ""
        try:
            pong = first.request("ping", timeout=PREWARM_PING_TIMEOUT)
            device = str(pong.get("device") or "")
            pool.add_daemon(first)
        except Exception as exc:
            log(f"daemon k1 预热失败: {exc}（首个请求将重试冷启动）")
            pool.add_daemon(first)  # 仍入池：成员自身的惰性重启会再试
            return
        log(f"daemon k1 prewarmed in {time.time() - started:.1f}s (device={device})")

        # 决策输入：CPU/内存直接探测；显存总量与空闲来自 torch/nvidia-smi；
        # 单 daemon 空载占用按 k1 的 pid 实测（WDDM 下走性能计数器），
        # daemon_sizing 内部乘负载系数放大为峰值估计再进预算。
        try:
            import daemon_sizing

            mem = daemon_sizing.cuda_mem_info()
            vram_free, vram_total = mem if mem else (None, None)
            pid = first.pid
            per_daemon = (
                daemon_sizing.per_process_vram({pid}) if pid else None
            )
            count, why = daemon_sizing.decide_worker_count(
                cpu_phys=daemon_sizing.cpu_physical_count(),
                ram_available=daemon_sizing.available_ram(),
                cuda=(device == "cuda") or mem is not None,
                vram_free=vram_free,
                vram_total=vram_total,
                per_daemon_vram=per_daemon,
            )
        except Exception as exc:
            count, why = 1, f"硬件决策异常，保守只开 1 个: {exc}"
        pool.planned = count
        pool.decided = True
        pool.decision_why = why
        log(f"daemon pool: {count} workers（{why}）")

        if count <= 1:
            return

        def _start_extra(index: int) -> None:
            tag = f"k{index}"
            extra = _spawn_daemon(tag)
            try:
                extra.request("ping", timeout=PREWARM_PING_TIMEOUT)
                pool.add_daemon(extra)
                log(f"daemon {tag} ready（池内 {pool.size}/{count}）")
            except Exception as exc:
                log(f"daemon {tag} 启动失败，缩容继续: {exc}")
                extra.shutdown()

        for index in range(2, count + 1):
            threading.Thread(
                target=_start_extra, args=(index,), daemon=True
            ).start()




def _ensure_pool() -> _DaemonPool:
    """取当前池；没有则新建并后台预热（首个请求阻塞等第一个成员就绪，
    与旧单 daemon 懒启动的冷启动行为一致）。"""
    global _pool
    if _pool is not None:
        return _pool
    with _pool_build_lock:
        if _pool is None:
            pool = _DaemonPool()
            _pool = pool
            threading.Thread(
                target=_prewarm_pool, args=(pool,), daemon=True
            ).start()
    return _pool




def pool_size() -> int:
    """当前池的成员数（就绪的 daemon 数；prewarm 未完成时偏小）。"""
    pool = _pool
    return pool.size if pool is not None else 0




def pool_planned() -> int:
    pool = _pool
    return pool.planned if pool is not None else 0




def pool_busy() -> int:
    """当前在途请求数（识别进行中 >0；resize 端点据此拒绝重建）。"""
    pool = _pool
    return pool.busy if pool is not None else 0




RESIZE_WAIT_TIMEOUT = 240.0


def resize_pool(
    workers: int | None, timeout: float = RESIZE_WAIT_TIMEOUT
) -> dict:
    """按给定并行数重建 daemon 池（设置页"识别进程数"的立即生效路径）。

    [workers] None = 清除覆盖、回到硬件自动决策。写入 OCR_KRAKEN_WORKERS
    （decide_worker_count 决策时读取，钳 1..WORKERS_MAX）→ 排空并关闭旧
    池 → 懒建新池，等决策完成且成员起齐（或超时返回实际规模）。调用方
    须保证池空闲（端点以 pool_busy 把关）；重建期间请求会等新池首个成员。
    """
    import daemon_sizing

    if workers is None:
        os.environ.pop(daemon_sizing.WORKERS_ENV, None)
    else:
        os.environ[daemon_sizing.WORKERS_ENV] = str(
            max(daemon_sizing.WORKERS_MIN,
                min(daemon_sizing.WORKERS_MAX, int(workers)))
        )
    shutdown()
    pool = _ensure_pool()
    started = time.time()
    deadline = started + timeout
    while time.time() < deadline:
        if pool.decided and pool.size >= pool.planned:
            break
        time.sleep(0.5)
    why = pool.decision_why or "决策未完成（首个 daemon 预热失败或仍在进行）"
    log(f"daemon pool resized: {pool.size}/{pool.planned} "
        f"in {time.time() - started:.1f}s")
    return {"size": pool.size, "planned": pool.planned, "why": why}




def prewarm(timeout: float = PREWARM_PING_TIMEOUT) -> None:
    """预热线：建池并等第一个 daemon 就绪（ping 返回即模型已加载）。

    在后台线程调用，首次用户请求到达时模型已在显存里；其余成员在后台
    继续拉起，不阻塞这里。"""
    pool = _ensure_pool()
    started = time.time()
    ok = pool.wait_ready(1, timeout=timeout)
    if ok:
        log(f"pool prewarmed (1 ready) in {time.time() - started:.1f}s")
    else:
        log(f"pool prewarm 等待超时（>{timeout:.0f}s），首请求将重试冷启动")




def shutdown() -> None:
    """服务退出/模型热切换时调用：排空在途请求并关闭全部 daemon。

    关闭后 _pool 置空，下次请求会懒建新池（重新加载模型文件——热切换
    后正是新模型）。"""
    global _pool
    pool, _pool = _pool, None
    if pool is not None:
        pool.shutdown()
