# -*- coding: utf-8 -*-
"""发行模型包（.zjpack）加载器：验签、按需物化、散文件缺失时兜底。

优先级与散文件体系一致——pack 是发布时刻的冻结快照，永远垫底：
  env 覆写 > 注册表激活 / 散文件基线 > 本包
pack 任何问题（缺失/坏签名/条目损坏）都只记日志并按"无 pack"降级，
绝不抛异常影响识别。物化缓存在包文件同目录的 .model_cache/<包sha8>/
下，换包后 sha 变化、旧缓存目录自然弃用（安装到用户目录，写权限无虞）。
"""
from __future__ import annotations

import os
import threading

import zjpack

SERVICE_DIR = os.path.dirname(os.path.abspath(__file__))
PACK_PATH = os.path.join(SERVICE_DIR, "models_release.zjpack")

# 发布公钥（hex）。私钥只存在于管理员机 release_keys/zjpack_ed25519，
# 生成/轮换：python tool_pack_models.py --init-key，把打印的公钥贴到这里。
PUBLIC_KEY = bytes.fromhex(
    "34246659c4f4d2a03406f0e24aa7b35d6fae258edd24e335a63832e5688e1629")


def log(msg: str) -> None:
    print(f"[model-store] {msg}", flush=True)


def _pack_path() -> str:
    return os.environ.get("OCR_ZJPACK", "") or PACK_PATH


_lock = threading.Lock()
_pack: zjpack.PackFile | None = None
_pack_state: tuple | None = None   # 已加载包的 (mtime_ns, size) 指纹
_broken_state: tuple | None = None  # 验签失败包的指纹：同指纹不重复验（整包哈希不便宜）


def _current() -> zjpack.PackFile | None:
    global _pack, _pack_state, _broken_state
    path = _pack_path()
    try:
        st = os.stat(path)
    except OSError:
        if _pack is not None:
            log("发行包已移除，回落散文件")
        _pack = None
        _pack_state = None
        _broken_state = None
        return None
    state = (st.st_mtime_ns, st.st_size)
    if _pack is not None and state == _pack_state:
        return _pack
    if _broken_state == state:
        return None
    with _lock:
        if _pack is not None and state == _pack_state:
            return _pack
        if _broken_state == state:
            return None
        try:
            pack = zjpack.open_pack(path, PUBLIC_KEY)
        except Exception as exc:
            log(f"发行包不可用（按无 pack 降级）: {exc}")
            _pack = None
            _pack_state = None
            _broken_state = state
            return None
        _pack = pack
        _pack_state = state
        _broken_state = None
        log(f"发行包已加载: v{pack.index.get('pack_version', '?')}，"
            f"{len(pack.index.get('entries', []))} 个条目")
        return pack


def resolve(kind: str) -> str | None:
    """按条目 kind（如 "yolo_char_det"、"kraken_rec"）取物化后的磁盘
    路径；无 pack / 无该条目 / 物化失败一律返回 None，由调用方回落。"""
    pack = _current()
    if pack is None:
        return None
    entry = pack.entry_by_kind(kind)
    if entry is None:
        return None
    cache_root = os.path.join(os.path.dirname(pack.path), ".model_cache", pack.sha8)
    try:
        return pack.materialize(entry, cache_root)
    except Exception as exc:
        log(f"条目 {kind} 物化失败: {exc}")
        return None
