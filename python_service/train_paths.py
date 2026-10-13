# -*- coding: utf-8 -*-
"""训练路径配置：数据集根目录与训练模型根目录可配置（机器本地）。

配置文件 train_paths.json 与应用同目录——路径本身是机器相关的，不随
数据迁移；数据集的跨机迁移靠 <dataset_root>/manifest.json（与数据同住，
拷整个数据集文件夹即带走全部统计，见 train_datasets 的增量导出）。
缺省值保持历史位置，未配置时行为与旧版完全一致。
"""
from __future__ import annotations

import os
import threading

import registry_io

SERVICE_DIR = registry_io.SERVICE_DIR

_CONFIG_PATH = os.path.join(SERVICE_DIR, "train_paths.json")
_LOCK = threading.Lock()

_DEFAULTS = {
    # 历史位置：datasets/_global 的父目录
    "dataset_root": os.path.join(SERVICE_DIR, "datasets"),
    # 历史位置：models/trained
    "trained_root": os.path.join(SERVICE_DIR, "models", "trained"),
}
_cache: dict | None = None


def _normalize(path: str) -> str:
    return os.path.normpath(os.path.abspath(os.path.expanduser(path.strip())))


def load_paths() -> dict:
    """读配置（进程内缓存）；缺失/损坏回默认值，绝不抛错。"""
    global _cache
    with _LOCK:
        if _cache is not None:
            return dict(_cache)
        cfg = dict(_DEFAULTS)
        try:
            import json

            with open(_CONFIG_PATH, encoding="utf-8") as f:
                loaded = json.load(f)
            if isinstance(loaded, dict):
                for key in _DEFAULTS:
                    value = loaded.get(key)
                    if isinstance(value, str) and value.strip():
                        cfg[key] = _normalize(value)
        except Exception:
            pass
        _cache = dict(cfg)
        return dict(cfg)


def save_paths(dataset_root: str = "", trained_root: str = "") -> dict:
    """写配置并热生效（刷新内存缓存）。只更新非空字段，其余保留。"""
    global _cache
    with _LOCK:
        cfg = dict(_cache) if _cache is not None else dict(_DEFAULTS)
        if isinstance(dataset_root, str) and dataset_root.strip():
            cfg["dataset_root"] = _normalize(dataset_root)
        if isinstance(trained_root, str) and trained_root.strip():
            cfg["trained_root"] = _normalize(trained_root)
        registry_io.save_registry(cfg, _CONFIG_PATH)
        _cache = dict(cfg)
    return dict(cfg)


def reset_cache() -> None:
    """测试缝：清内存缓存（外部改动配置文件后强制重读）。"""
    global _cache
    with _LOCK:
        _cache = None


def config_path() -> str:
    return _CONFIG_PATH


def defaults() -> dict:
    return dict(_DEFAULTS)


def dataset_root() -> str:
    return load_paths()["dataset_root"]


def trained_root() -> str:
    return load_paths()["trained_root"]
