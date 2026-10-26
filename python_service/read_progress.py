# -*- coding: utf-8 -*-
"""整页直读进度登记（进程内注册表）：桥在引擎准备/读字/拼接各阶段打点，
客户端凭 progress_token 轮询 /read_page_progress，识别中实时展示
"已用时 + 当前卡在哪一步"。

单机桌面工具，无需持久化/跨进程共享；token 由客户端每次识别随机生成、
随请求传入。识别结束（成败都）由路由 finally 清除条目；异常退出的泄漏
条目靠写入时 TTL 惰性清理兜底。VL 直读是"一整页一次推理"，没有逐行
百分比可报——进度粒度就是阶段 + 已用时。"""
import threading
import time

_lock = threading.Lock()
_entries: dict[str, dict] = {}

# 泄漏条目 TTL：正常路径识别返回即清除，30 分钟足够覆盖最慢的首读。
_TTL_S = 1800.0

# 阶段词表（打点方白名单，未知值不覆盖旧阶段）：
# preparing=引擎池启动/模型加载；reading=引擎读字推理；gating=版面区
# 检测与排除过滤；assembling=阅读序拼接与整页文本组装。
STAGES = frozenset({"preparing", "reading", "gating", "assembling"})


def _sweep_locked(now: float) -> None:
    stale = [k for k, v in _entries.items() if now - v["updated_at"] > _TTL_S]
    for k in stale:
        _entries.pop(k, None)


def start(token: str, engine: str = "", detail: str = "") -> None:
    """登记一次识别的开始（token 为空 = 客户端未启用进度，全链路静默）。"""
    if not token:
        return
    now = time.time()
    with _lock:
        _sweep_locked(now)
        _entries[token] = {
            "stage": "preparing",
            "detail": detail,
            "engine": engine,
            "started_at": now,
            "updated_at": now,
        }


def set_stage(token: str, stage: str, detail: str = "") -> None:
    """推进到某阶段（detail 为面向用户的中文说明，客户端原样展示）。"""
    if not token:
        return
    now = time.time()
    with _lock:
        entry = _entries.get(token)
        if entry is None:
            return
        if stage in STAGES:
            entry["stage"] = stage
        if detail:
            entry["detail"] = detail
        entry["updated_at"] = now


def finish(token: str) -> None:
    """识别结束（成败都）清除条目；客户端下次轮询拿到 active=false。"""
    if not token:
        return
    with _lock:
        _entries.pop(token, None)


def get(token: str) -> dict:
    """查询进度：未知/已结束 token 返回 {"active": false}。"""
    with _lock:
        entry = _entries.get(token)
        if entry is None:
            return {"active": False}
        return {
            "active": True,
            "stage": entry["stage"],
            "detail": entry["detail"],
            "engine": entry["engine"],
            "elapsed_s": round(time.time() - entry["started_at"], 1),
        }
