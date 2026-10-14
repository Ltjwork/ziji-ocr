# -*- coding: utf-8 -*-
"""PaddleOCR daemon 进程与池管理：paddleocr 环境探测、模型清单、懒建池。

与 kraken_proc 同款协议/池模型（复用其 _KrakenDaemon/_DaemonPool，daemon
本体已引擎无关），差异：
- 池按识别模型绑定（PP-OCRv6 tiny/small/medium 三档，见 PP_OCRV6_MODELS），
  换模型 = 关旧池重建（ensure_pool 内自动处理，同 kraken 激活语义）；
- 懒启动：服务启动时不预热（kraken 仍是默认引擎，未选 PaddleOCR 的用户
  不该为它付进程与显存），首个 engine=paddle 请求 / /paddle/probe 才建池；
- 默认 1 个成员（OCR_PADDLE_WORKERS 覆写，钳 1..4）：PP-OCR 识别模型远
  小于 CHAT，多成员收益有限，保守起步。

worker：paddle_worker.py（paddleocr 环境内常驻，stdin/stdout 单行 JSON）。
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import threading
import time
from pathlib import Path

from kraken_proc import (
    REQUEST_TIMEOUT,
    _DaemonPool,
    _KrakenDaemon,
    log,
)


SCRIPT_DIR = Path(__file__).resolve().parent

WORKER = SCRIPT_DIR / "paddle_worker.py"

ENV_NAME = "paddleocr"

WORKERS_ENV = "OCR_PADDLE_WORKERS"

WORKERS_MIN = 1

WORKERS_MAX = 4

# 首成员 ping 超时：首次加载含官方模型下载（small 20.4MB / medium 73.3MB，
# 视网速数分钟），比 kraken 的预热窗口宽得多。
FIRST_PING_TIMEOUT = 900.0

# VL 直读的单请求超时：VL 0.9B 首次推理含权重编译，且常与 kraken 池
# 共享显存（每个 kraken daemon 都占一份 CUDA 上下文）——显存吃紧时
# VL 会退到 CPU 或排队，300s 默认超时不够（实测被杀重启、直读 500）。
READ_TIMEOUT_VL = float(os.environ.get("PADDLE_VL_READ_TIMEOUT", "900"))


def read_timeout() -> float:
    """read_page 的单请求超时；VL 模型返回放宽档。"""
    return READ_TIMEOUT_VL

# PP-OCR 识别模型目录（检测由本项目自训 YOLO 负责，只需识别模型）。
# requirement 是给用户选型看的配置要求文案，客户端模型下拉原样展示。
# 除 PP-OCRv6 三档外：PP-OCRv3 老一代轻量档（横排/对照测试）；PaddleOCR-VL
# 视觉语言模型（0.9B，整页直读专用——古籍竖排/标点/复杂版式显著更强，
# 但行/字识别 op 不支持，worker 会明确拒绝）。
PP_OCRV6_MODELS: list[dict] = [
    {
        "name": "PP-OCRv6_tiny_rec",
        "size_mb": 4.4,
        "label": "极轻量 4.4MB",
        "requirement": "CPU 即可运行，无独立显卡/低配电脑可用；速度最快、精度最低",
    },
    {
        "name": "PP-OCRv6_small_rec",
        "size_mb": 20.4,
        "label": "小模型（蒸馏）20.4MB · 默认",
        "requirement": "CPU 可运行（速度较慢）；入门独立显卡（显存 ≥2GB）即流畅；精度与速度均衡，古籍识别推荐起点",
    },
    {
        "name": "PP-OCRv6_medium_rec",
        "size_mb": 73.3,
        "label": "中等 73.3MB",
        "requirement": "建议 NVIDIA 独立显卡（显存 ≥4GB）+ GPU 版 paddlepaddle；精度最高、最慢",
    },
    {
        "name": "PP-OCRv3_mobile_rec",
        "size_mb": 9.8,
        "label": "v3 轻量 9.8MB",
        "requirement": "CPU 即可运行；老一代模型（2022），精度低于 v5/v6；整页直读不支持竖排（v5 起原生支持），适合横排书籍或引擎对照",
    },
    {
        "name": "PaddleOCR-VL-1.6",
        "size_mb": 1900,
        "label": "视觉语言模型 0.9B · 古籍最强",
        "requirement": "需 NVIDIA 独立显卡（建议显存 ≥8GB）+ GPU 版 paddlepaddle，首次下载约 1.9GB；古籍竖排、标点、复杂版式显著更强；CPU 极慢不建议；仅整页直读（文本视图）可用，行/字识别请选 PP-OCR 系模型",
    },
]

_MODEL_NAMES = {m["name"] for m in PP_OCRV6_MODELS}

DEFAULT_MODEL = "PP-OCRv6_small_rec"


def normalize_model(name: str | None) -> str:
    """模型名归一：空白/未知名回落默认档（防止请求里传错名打死池）。"""
    cleaned = (name or "").strip()
    return cleaned if cleaned in _MODEL_NAMES else DEFAULT_MODEL


def model_info(name: str | None = None) -> dict:
    model = normalize_model(name)
    for entry in PP_OCRV6_MODELS:
        if entry["name"] == model:
            return entry
    return PP_OCRV6_MODELS[1]


def line_model(name: str | None) -> str:
    """行/字识别可用的模型名：PaddleOCR-VL 仅支持整页直读（文本视图），
    行/字请求自动回退默认档 PP-OCRv6_small_rec——客户端保持 VL 选择
    （直读仍用 VL），行重识别/单字识别不再报"仅支持整页直读"。"""
    cleaned = normalize_model(name)
    return DEFAULT_MODEL if cleaned.startswith("PaddleOCR-VL") else cleaned


def _candidate_pythons() -> list[Path]:
    env_override = os.environ.get("PADDLE_PYTHON")
    candidates: list[Path] = []
    if env_override:
        candidates.append(Path(env_override))
    # 服务自身的 conda env 与 paddleocr env 是兄弟目录（envs/<service>/ 与
    # envs/paddleocr/），与 kraken 环境的发现方式同款。
    candidates.append(Path(sys.prefix).parent / ENV_NAME / "python.exe")
    candidates.append(Path(sys.prefix).parent / ENV_NAME / "bin" / "python")
    candidates.append(Path.home() / ".conda" / "envs" / ENV_NAME / "python.exe")
    conda_exe = os.environ.get("CONDA_EXE")
    if conda_exe:
        base = Path(conda_exe).parent.parent
        candidates.append(base / "envs" / ENV_NAME / "python.exe")
    return candidates


_python_cache: str | None = None


def paddle_python() -> str:
    """定位 paddleocr 环境的 python，找不到抛带安装指引的异常。"""
    global _python_cache
    if _python_cache:
        return _python_cache
    for candidate in _candidate_pythons():
        if candidate.exists():
            _python_cache = str(candidate)
            log(f"paddle python: {_python_cache}")
            return _python_cache
    raise RuntimeError(
        "未找到 paddleocr 环境（识别引擎 PaddleOCR 需要独立环境）。"
        "请先运行 python_service\\install_paddleocr.bat 安装，"
        "或在环境变量 PADDLE_PYTHON 中指定其 python.exe 路径。"
    )


def paddle_env_ready() -> bool:
    try:
        paddle_python()
        return True
    except Exception:
        return False


def _planned_workers() -> int:
    raw = (os.environ.get(WORKERS_ENV) or "").strip()
    if raw.isdigit():
        return max(WORKERS_MIN, min(WORKERS_MAX, int(raw)))
    return 1


def _model_cache_roots() -> list[Path]:
    """paddleocr 官方模型的本地缓存根目录候选（含环境覆写与旧布局）。"""
    roots: list[Path] = []
    override = os.environ.get("PADDLE_PDX_CACHE_HOME", "").strip()
    if override:
        roots.append(Path(override))
    roots.append(Path.home() / ".paddlex")
    roots.append(Path.home() / ".paddleocr")
    return roots


def _cache_dir_valid(entry: Path) -> bool:
    """模型目录有效 = 带模型配置文件（inference.yml）。

    中断的下载会留下空目录/半截目录——paddlex 见目录存在就不再重新
    下载、加载时直接报"无有效模型文件"（实测踩坑：1 月一次失败的
    PaddleOCR-VL 下载留下空壳，之后 VL 一直起不来）。这类目录识别为
    未下载；download_model 会先删掉它让加载走全新下载。"""
    try:
        return (entry / "inference.yml").is_file()
    except OSError:
        return False


def downloaded_models() -> set[str]:
    """已下载到本地官方缓存的识别模型名集合。

    paddleocr（paddlex 内核）把官方模型物化在
    <缓存根>/official_models/<模型名>/ 目录（默认 ~/.paddlex）。目录存在
    且带模型配置（见 _cache_dir_valid）即视为已下载——只做磁盘检查，
    不起 daemon，环境未装/池未起也能回答"哪些档已就位"。"""
    downloaded: set[str] = set()
    for root in _model_cache_roots():
        official = root / "official_models"
        try:
            if not official.is_dir():
                continue
            for entry in official.iterdir():
                if not entry.is_dir():
                    continue
                if _cache_dir_valid(entry):
                    downloaded.add(entry.name)
        except OSError:
            continue
    return downloaded


# ── VL 解析配置（PaddleOCR-VL 直读管线开关，官网演示同款）──────────────
# VL 管线构造器参数；默认全关 + merge_blocks 开 = v193 以来的现行为。
# 书级设置（project.json settings.vl_*），随 /read_page_text 传入；池按
# （模型+VL配置）共同绑定——改配置 = 换池重建（与换模型同语义）。
VL_CONFIG_KEYS = (
    "use_doc_orientation_classify",  # 文档方向分类
    "use_doc_unwarping",  # 文档矫正
    "use_layout_detection",  # 版面检测（开=按版面块输出，古籍竖排推荐关）
    "use_chart_recognition",  # 图表识别
    "use_seal_recognition",  # 印章识别
    "use_ocr_for_image_block",  # 图片块 OCR
    "merge_layout_blocks",  # 合并版面块
)


def normalize_vl_config(cfg: dict | None) -> dict:
    """VL 配置归一：只收白名单键，bool 归一，缺省取现行为默认值。"""
    src = cfg if isinstance(cfg, dict) else {}
    out = {}
    for key in VL_CONFIG_KEYS:
        val = src.get(key)
        if key == "merge_layout_blocks":
            out[key] = bool(val) if val is not None else True
        else:
            out[key] = bool(val)
    return out


def _vl_config_signature(cfg: dict | None) -> str:
    """VL 配置的池绑定签名（稳定排序的紧凑串）。"""
    norm = normalize_vl_config(cfg)
    return ",".join(f"{k}={int(norm[k])}" for k in VL_CONFIG_KEYS)


def _spawn_daemon(tag: str, model: str, vl_config: dict | None = None) -> _KrakenDaemon:
    env_extra: dict[str, str] = {"PADDLE_REC_MODEL": model}
    if model.startswith("PaddleOCR-VL"):
        env_extra["PADDLE_VL_CONFIG"] = json.dumps(
            normalize_vl_config(vl_config), ensure_ascii=False
        )
    if tag:
        env_extra["PADDLE_WORKER_ID"] = tag
    return _KrakenDaemon(
        paddle_python(),
        str(WORKER),
        tag=tag,
        env_extra=env_extra,
        label="PaddleOCR",
    )


# ── 池单例（按模型绑定）──────────────────────────────────────────────
# 与 kraken_proc 相同的懒建守卫：懒建（首个请求）与 probe/resize 两条路径
# 并发时只建一个池；_pool_model 记录当前池绑定的模型，换模型先关旧池。

_pool: _DaemonPool | None = None
_pool_model: str = ""
_pool_vl_sig: str = ""

_pool_build_lock = threading.Lock()


def _prewarm_pool(pool: _DaemonPool, model: str, vl_sig: str = "",
                  vl_config: dict | None = None) -> None:
    try:
        _prewarm_pool_inner(pool, model, vl_sig=vl_sig, vl_config=vl_config)
    except Exception as exc:
        # 典型场景：paddleocr 环境未安装（paddle_python 抛带安装指引的异常）。
        # 池保持空：首个请求会在 acquire 超时后拿到同样清晰的报错。
        log(f"paddle daemon 池预热失败: {exc}")


def _prewarm_pool_inner(pool: _DaemonPool, model: str, vl_sig: str = "",
                        vl_config: dict | None = None) -> None:
    count = _planned_workers()
    pool.planned = count
    pool.decided = True
    pool.decision_why = f"PaddleOCR 固定规模（{WORKERS_ENV} 可覆写）"

    def _start_one(index: int, first: bool) -> None:
        tag = f"p{index}"
        daemon = _spawn_daemon(tag, model, vl_config)
        try:
            # 首成员宽超时：模型首载含官方源下载（见 FIRST_PING_TIMEOUT）。
            daemon.request(
                "ping", timeout=FIRST_PING_TIMEOUT if first else REQUEST_TIMEOUT
            )
            pool.add_daemon(daemon)
            log(f"paddle daemon {tag} ready（模型 {model}，池内 {pool.size}/{count}）")
        except Exception as exc:
            log(f"paddle daemon {tag} 启动失败: {exc}")
            daemon.shutdown()

    started = time.time()
    _start_one(1, first=True)  # 首成员同步起：调用方（首个识别请求）等它就绪
    log(f"paddle daemon p1 prewarmed in {time.time() - started:.1f}s")
    for index in range(2, count + 1):
        threading.Thread(
            target=_start_one, args=(index, False), daemon=True
        ).start()


def ensure_pool(model: str | None = None, vl_config: dict | None = None) -> _DaemonPool:
    """取绑定指定模型（+VL 解析配置）的池；没有/绑定不同则重建（懒建 +
    后台预热）。

    首个请求阻塞等第一个成员就绪（含首载模型下载），与 kraken 懒启动的
    冷启动行为一致。旧池的关停放后台线程：换模型不该被旧池的排空/成员
    关闭拖住（成员正在加载模型时其关停要等锁/超时，同步等会把切换卡出
    几十秒——实测 14:49 那次换池被在载 small 的 daemon 卡了 ~70s）。
    VL 模型时池按（模型+VL 配置签名）共同绑定：改配置 = 换池重建。"""
    global _pool, _pool_model, _pool_vl_sig
    wanted = normalize_model(model)
    vl_sig = (
        _vl_config_signature(vl_config) if wanted.startswith("PaddleOCR-VL") else ""
    )
    if _pool is not None and _pool_model == wanted and _pool_vl_sig == vl_sig:
        return _pool
    with _pool_build_lock:
        if _pool is None or _pool_model != wanted or _pool_vl_sig != vl_sig:
            old = _pool
            if old is not None:
                log(
                    f"paddle 模型/配置切换 {_pool_model}[{_pool_vl_sig}] → "
                    f"{wanted}[{vl_sig}]：后台关闭旧池并重建"
                )
                # 只在确有旧池时后台关闭：首次建池 old=None，无保护地取
                # old.shutdown 会在首个 paddle 请求上抛 'NoneType' object
                # has no attribute 'shutdown'（v200 回归，用户实测 500）。
                threading.Thread(target=old.shutdown, daemon=True).start()
            pool = _DaemonPool(label="PaddleOCR")
            _pool = pool
            _pool_model = wanted
            _pool_vl_sig = vl_sig
            threading.Thread(
                target=_prewarm_pool, args=(pool, wanted, vl_sig, vl_config),
                daemon=True,
            ).start()
    return _pool


def current_model() -> str:
    """当前池绑定的模型（池未建时为默认档）。"""
    return _pool_model or DEFAULT_MODEL


def pool_size() -> int:
    pool = _pool
    return pool.size if pool is not None else 0


def pool_busy() -> int:
    pool = _pool
    return pool.busy if pool is not None else 0


def probe(model: str | None = None) -> dict:
    """探测环境并加载（含首载下载）指定模型：建/换池 + ping。

    客户端"下载/测试"按钮的后端；返回实际设备（gpu/cpu）与耗时。"""
    wanted = normalize_model(model)
    started = time.time()
    pool = ensure_pool(wanted)
    pong = pool.request("ping", timeout=FIRST_PING_TIMEOUT)
    return {
        "ok": True,
        "model": wanted,
        "device": str(pong.get("device") or ""),
        "elapsed_s": round(time.time() - started, 1),
        "pool_size": pool.size,
        "pool_planned": pool.planned,
    }


def download_model(model: str | None = None) -> dict:
    """下载/校验指定模型，**不动现有池**（设置页逐档下载用）。

    与 probe 的区别：probe 会把池重绑到该模型（切走正在用的档位），
    本函数用一次性临时 daemon 加载该模型（首载自动下载到官方缓存），
    ping 就绪即关，池当前绑定的模型不受影响。已下载时是一次加载自检
    （数秒），缺档时含下载（视网速数分钟）。"""
    wanted = normalize_model(model)
    # 半截缓存自愈：目录存在但缺模型配置（中断的下载）时 paddlex 不会
    # 重新下载——先删掉这个模型自己的坏目录，让下方加载走全新下载。
    # 只删 requested 模型目录，ignore_errors 兜底 ACL 异常目录。
    for root in _model_cache_roots():
        bad = root / "official_models" / wanted
        try:
            if bad.is_dir() and not _cache_dir_valid(bad):
                shutil.rmtree(bad, ignore_errors=True)
                log(f"paddle model {wanted}: 清掉半截缓存目录后重新下载")
        except OSError:
            pass
    already = wanted in downloaded_models()
    started = time.time()
    daemon = _spawn_daemon("dl", wanted)
    try:
        pong = daemon.request("ping", timeout=FIRST_PING_TIMEOUT)
        device = str(pong.get("device") or "")
    finally:
        daemon.shutdown()
    log(
        f"paddle model {wanted} ready（device={device}，"
        f"{'已在本机缓存' if already else '本次新下载'}，"
        f"{time.time() - started:.1f}s）"
    )
    return {
        "ok": True,
        "model": wanted,
        "device": device,
        "was_cached": already,
        "elapsed_s": round(time.time() - started, 1),
    }


def resize(workers: int | None) -> dict:
    """按给定并行数重建池（/paddle/pool/resize）。None = 清除覆写回默认 1。

    池按当前模型原样重建；调用方须保证池空闲（端点以 pool_busy 把关）。"""
    if workers is None:
        os.environ.pop(WORKERS_ENV, None)
    else:
        os.environ[WORKERS_ENV] = str(
            max(WORKERS_MIN, min(WORKERS_MAX, int(workers)))
        )
    global _pool, _pool_model
    model = current_model()
    with _pool_build_lock:
        old, _pool = _pool, None
        _pool_model = ""
        if old is not None:
            old.shutdown()
    pool = ensure_pool(model)
    deadline = time.time() + FIRST_PING_TIMEOUT
    while time.time() < deadline and pool.size < pool.planned:
        time.sleep(0.5)
    return {
        "size": pool.size,
        "planned": pool.planned,
        "model": model,
        "why": pool.decision_why,
    }


def shutdown() -> None:
    """服务退出时调用：排空在途请求并关闭全部 paddle daemon。"""
    global _pool, _pool_model
    pool, _pool = _pool, None
    _pool_model = ""
    if pool is not None:
        pool.shutdown()
