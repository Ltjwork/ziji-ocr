# -*- coding: utf-8 -*-
"""诊断产物清理：崩溃转储（crash_dumps/*.dmp）与运行日志（logs/*.log）。

只清理"可再生的诊断产物"，不碰数据集/模型/标注等用户数据。三个入口：

1. startup_cleanup()——服务启动时（main.py 在 install_console_log 之后
   调用；轮转部分 rotate_big_logs 必须在打开日志文件之前单独先调）：
   - 日志超过 LOG_ROTATE_SIZE 轮转为 .old（替换旧 .old）；
   - 崩溃转储按 DUMP_MAX_AGE_DAYS / DUMP_MAX_TOTAL 清理；
   - .old 日志超过 OLD_LOG_MAX_AGE_DAYS 删除。
2. periodic_cleanup()——运行期每 6h 巡检（api_base lifespan 起线程）：
   转储清理同上；当前日志超过 LOG_TRIM_SIZE 时保尾截断（活动句柄
   经注册表拿，写与截断共用一把锁防交错）。
3. HTTP 接口（api_cleanup.py）——手动清理：删全部转储（可选保留最新
   N 份）、删 .old、清空当前日志。

背景：2026-10 排查发现 crash_dumps 因 WER 全量转储累积 5 份 × 8GB =
38GB，service_console.log 两周 210MB——本模块即该结论的落地。
"""
from __future__ import annotations

import os
import threading
import time
from pathlib import Path

SERVICE_DIR = Path(__file__).resolve().parent
LOGS_DIR = SERVICE_DIR / "logs"
DUMPS_DIR = SERVICE_DIR.parent / "crash_dumps"

MB = 1024 * 1024
GB = 1024 * 1024 * 1024

# 启动轮转阈值：当前日志超过该大小改名为 .old（换新文件从头写）。
LOG_ROTATE_SIZE = 50 * MB
# 运行期截断阈值与保尾量：单次会话跑数天时日志仍会涨（识别高峰约
# 1-2MB/min），超阈值保尾截断，最近的诊断行不丢。
LOG_TRIM_SIZE = 200 * MB
LOG_TRIM_KEEP = 20 * MB
# 崩溃转储：单份 7-8GB（WER DumpType=2 全量转储），保留价值随时间
# 衰减；超龄或总量超额时清理，超额时留最新 DUMP_KEEP_WHEN_OVER 份。
DUMP_MAX_AGE_DAYS = 14
DUMP_MAX_TOTAL = 10 * GB
DUMP_KEEP_WHEN_OVER = 2
# 轮转出的 .old 日志保留天数。
OLD_LOG_MAX_AGE_DAYS = 14

# 活动日志句柄注册表：{规范路径: 文本句柄}。install_console_log 与
# main.py 的 faulthandler 句柄注册进来；写方（_Tee.write）与截断方
# 共用 console_write_lock，避免截断瞬间写入交错产生稀疏洞。
_active_logs: dict[str, object] = {}
console_write_lock = threading.Lock()


def register_active_log(path: os.PathLike | str, handle) -> None:
    with console_write_lock:
        _active_logs[str(Path(path).resolve())] = handle


def _dump_files() -> list[Path]:
    if not DUMPS_DIR.is_dir():
        return []
    return sorted(
        (f for f in DUMPS_DIR.glob("*.dmp") if f.is_file()),
        key=lambda f: f.stat().st_mtime,
    )


def _log_files() -> list[Path]:
    if not LOGS_DIR.is_dir():
        return []
    return sorted(f for f in LOGS_DIR.glob("*.log") if f.is_file())


def _old_log_files() -> list[Path]:
    if not LOGS_DIR.is_dir():
        return []
    return sorted(f for f in LOGS_DIR.glob("*.old") if f.is_file())


def scan_status() -> dict:
    """清理面板数据：各目标文件数/字节数/可回收总量。"""
    dumps = [
        {
            "name": f.name,
            "bytes": f.stat().st_size,
            "mtime": f.stat().st_mtime,
        }
        for f in _dump_files()
    ]
    logs = [
        {"name": f.name, "bytes": f.stat().st_size}
        for f in _log_files() + _old_log_files()
    ]
    dump_bytes = sum(d["bytes"] for d in dumps)
    old_paths = _old_log_files()
    old_bytes = sum(f.stat().st_size for f in old_paths)
    log_bytes = sum(l["bytes"] for l in logs)
    return {
        "dumps_dir": str(DUMPS_DIR),
        "logs_dir": str(LOGS_DIR),
        "dumps": {"files": dumps, "count": len(dumps), "bytes": dump_bytes},
        "logs": {"files": logs, "count": len(logs), "bytes": log_bytes},
        "old_logs": {"count": len(_old_log_files()), "bytes": old_bytes},
        "total_bytes": dump_bytes + log_bytes,
        # 自动策略快照（面板展示"自动清理都做什么"用真实配置）。
        "policy": {
            "rotate_size_mb": LOG_ROTATE_SIZE // MB,
            "trim_size_mb": LOG_TRIM_SIZE // MB,
            "dump_max_age_days": DUMP_MAX_AGE_DAYS,
            "dump_max_total_gb": round(DUMP_MAX_TOTAL / GB, 1),
            "dump_keep_when_over": DUMP_KEEP_WHEN_OVER,
            "old_log_max_age_days": OLD_LOG_MAX_AGE_DAYS,
        },
    }


def delete_dumps(keep_last: int = 0) -> dict:
    """删除崩溃转储，保留最新 keep_last 份。返回 {freed, kept, failed}。"""
    files = _dump_files()
    doomed = files[: len(files) - keep_last] if keep_last > 0 else files
    freed = 0
    failed: list[str] = []
    for f in doomed:
        try:
            size = f.stat().st_size
            f.unlink()
            freed += size
        except OSError:
            failed.append(f.name)
    return {"freed": freed, "kept": max(0, len(files) - len(doomed)), "failed": failed}


def delete_old_logs() -> dict:
    freed = 0
    failed: list[str] = []
    for f in _old_log_files():
        try:
            size = f.stat().st_size
            f.unlink()
            freed += size
        except OSError:
            failed.append(f.name)
    return {"freed": freed, "failed": failed}


def truncate_logs() -> dict:
    """清空当前日志内容（保留文件本身）。

    活动句柄（service_console.log）经注册表用同一句柄 truncate——
    Windows 上跨句柄清空他人持有的文件不可靠，自己的句柄则安全。
    未注册句柄的日志（app_console.log 由前端逐行开合写、
    faulthandler.log 由 C 层持有）用 r+ 打开截断，失败如实上报。
    """
    results: dict[str, dict] = {}
    for f in _log_files():
        key = str(f.resolve())
        try:
            size_before = f.stat().st_size
            handle = _active_logs.get(key)
            if handle is not None:
                with console_write_lock:
                    handle.flush()
                    handle.truncate(0)
            else:
                with open(f, "r+", encoding="utf-8", errors="replace") as fh:
                    fh.truncate(0)
            results[f.name] = {"ok": True, "freed": size_before}
        except OSError as exc:
            results[f.name] = {"ok": False, "error": str(exc)}
    return {
        "files": results,
        "freed": sum(r.get("freed", 0) for r in results.values() if r.get("ok")),
    }


def rotate_big_logs() -> dict:
    """超过 LOG_ROTATE_SIZE 的日志改名 .old（必须在该文件被打开前调用，
    Windows 不允许改名打开中的文件）。替换已有 .old。"""
    freed = 0
    rotated: list[str] = []
    for f in _log_files():
        try:
            if f.stat().st_size < LOG_ROTATE_SIZE:
                continue
            old = f.with_suffix(f.suffix + ".old")
            if old.exists():
                freed += old.stat().st_size
                old.unlink()
            f.rename(old)
            rotated.append(f.name)
        except OSError:
            continue
    return {"rotated": rotated, "freed": freed}


def _prune_dumps(now: float) -> dict:
    """自动策略：超龄删除；总量超额时只留最新 DUMP_KEEP_WHEN_OVER 份。"""
    files = _dump_files()
    keep = [f for f in files if now - f.stat().st_mtime <= DUMP_MAX_AGE_DAYS * 86400]
    total = sum(f.stat().st_size for f in keep)
    if total > DUMP_MAX_TOTAL:
        keep = keep[-DUMP_KEEP_WHEN_OVER:]
    keep_last = len(keep)
    return delete_dumps(keep_last=keep_last) if keep_last < len(files) else {"freed": 0}


def _prune_old_logs(now: float) -> dict:
    freed = 0
    for f in _old_log_files():
        try:
            if now - f.stat().st_mtime > OLD_LOG_MAX_AGE_DAYS * 86400:
                freed += f.stat().st_size
                f.unlink()
        except OSError:
            continue
    return {"freed": freed}


def _trim_big_logs() -> dict:
    """运行期保尾截断：超过 LOG_TRIM_SIZE 的当前日志只留末尾 LOG_TRIM_KEEP。

    活动句柄：锁内 flush → 读尾部 → truncate(0) → 回写尾部（'a' 模式
    的写总是落文件末尾，truncate 后末尾即 0，写回即头部）。未注册句柄
    的日志：另开 r+ 复制尾部到 .tail.tmp 再截断回写，失败跳过。
    """
    results: dict[str, int] = {}
    for f in _log_files():
        try:
            size = f.stat().st_size
            if size < LOG_TRIM_SIZE:
                continue
            key = str(f.resolve())
            handle = _active_logs.get(key)
            if handle is not None:
                with console_write_lock:
                    handle.flush()
                    handle.seek(max(0, size - LOG_TRIM_KEEP))
                    tail = handle.read() or ""
                    handle.truncate(0)
                    if tail:
                        handle.write(tail)
                        handle.flush()
            else:
                with open(f, "rb") as src:
                    src.seek(max(0, size - LOG_TRIM_KEEP))
                    tail = src.read()
                with open(f, "r+b") as dst:
                    dst.truncate(0)
                    dst.write(tail)
                    dst.flush()
            results[f.name] = size - min(size, LOG_TRIM_KEEP)
        except OSError:
            continue
    return {"trimmed": results, "freed": sum(results.values())}


def startup_cleanup() -> dict:
    """启动期自动清理（rotate_big_logs 之后的第二步）。"""
    now = time.time()
    return {
        "dumps": _prune_dumps(now),
        "old_logs": _prune_old_logs(now),
    }


def periodic_cleanup() -> dict:
    """运行期巡检（每 6h）：转储/旧日志自动策略 + 超大日志保尾截断。"""
    now = time.time()
    return {
        "dumps": _prune_dumps(now),
        "old_logs": _prune_old_logs(now),
        "trim": _trim_big_logs(),
    }
