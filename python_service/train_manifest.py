# -*- coding: utf-8 -*-
"""数据集导出清单（manifest）：增量导出的跨机账本。

manifest 与数据集同住（<dataset_root>/manifest.json）——拷整个数据集
文件夹到另一台电脑，统计与"哪些书已导出/已抽样"的记录一并带走；书籍
任务从书库删除不影响 manifest 与已导出的样本（统计口径 = 已导出数据，
而非书库现状）。

与 _meta.json 的分工：_meta.json 是 generate/export 过程的按书缓存账本
（防重算，位于 _global 内、跟随实现细节）；manifest 是对外口径（用户
看到的实例数、就绪度都出自它）。首次访问时把 _meta.json 的存量转换成
manifest 基线，旧统计不丢。
"""
from __future__ import annotations

import os
import time
from typing import Any

import registry_io
import train_data

MANIFEST_SCHEMA_VERSION = 1


def manifest_path() -> str:
    return os.path.join(train_data.datasets_root(), "manifest.json")


def load_manifest() -> dict:
    """读 manifest；缺失/损坏返回空骨架。"""
    manifest: dict = {}
    try:
        with open(manifest_path(), encoding="utf-8") as f:
            import json

            loaded = json.load(f)
        if isinstance(loaded.get("books"), dict):
            manifest = loaded
    except Exception:
        manifest = {}
    manifest.setdefault("schema_version", MANIFEST_SCHEMA_VERSION)
    manifest.setdefault("books", {})
    # 旧 manifest 里的 region_sampled（一次性抽样时代的记录）：已无读取方，
    # 留在文件里无害，不主动清理。
    return manifest


def save_manifest(manifest: dict) -> None:
    registry_io.save_registry(manifest, manifest_path())


def _meta_path() -> str:
    # train_datasets._meta_path 位于 _global 内；这里只读它的 books 统计
    import json

    return os.path.join(train_data.global_root(), "_meta.json")


def ensure_manifest_baseline() -> dict:
    """首次升级：manifest 不存在而 _meta.json 有存量 → 转换为基线。

    基线条目只保留统计字段（train/val pages+instances、classes、skipped），
    丢弃 split_pages（体积大且属于生成期细节）。已导出的旧书从此走
    "已导出跳过"的增量语义。
    """
    manifest = load_manifest()
    if manifest["books"]:
        return manifest
    meta_path = _meta_path()
    if not os.path.exists(meta_path):
        return manifest
    try:
        import json

        with open(meta_path, encoding="utf-8") as f:
            meta = json.load(f)
        books = meta.get("books")
        if not isinstance(books, dict):
            return manifest
        for bid, entry in books.items():
            layers_in = entry.get("layers") if isinstance(entry, dict) else None
            if not isinstance(layers_in, dict):
                continue
            layers_out: dict[str, Any] = {}
            for layer, stats in layers_in.items():
                if not isinstance(stats, dict):
                    continue
                layers_out[layer] = {
                    k: stats.get(k) for k in (
                        "train_pages", "val_pages", "train_instances",
                        "val_instances", "classes", "skipped", "per_class")
                    if stats.get(k) is not None
                }
            if layers_out:
                manifest["books"][str(bid)] = {
                    "exported_at": entry.get("generated_at") or time.time(),
                    "baseline": True,
                    "layers": layers_out,
                }
        save_manifest(manifest)
    except Exception:
        pass
    return manifest


def is_book_exported(manifest: dict, book_id: str, layer: str) -> bool:
    return layer in ((manifest.get("books", {}).get(book_id) or {})
                     .get("layers") or {})


def record_book_layer(manifest: dict, book_id: str, layer: str,
                      stats: dict[str, Any]) -> None:
    entry = manifest["books"].setdefault(
        book_id, {"exported_at": time.time(), "layers": {}})
    entry["exported_at"] = time.time()
    entry.pop("baseline", None)
    entry["layers"][layer] = {
        k: stats.get(k) for k in (
            "train_pages", "val_pages", "train_instances", "val_instances",
            "classes", "skipped", "per_class")
        if stats.get(k) is not None
    }


def region_eligible_pages(pages: list[dict]) -> list[str]:
    """region_det 的可导出页：有任一已确认版面区（box_confirmed/confirmed，
    任意类别）的页，全量返回。

    不抽样、不看整本识别是否完成——主区快设确认的版面区是纯几何成果，
    与识别流程解耦；页级增量 + digest（train_export）保证只写新增/变化
    的页。历史上这里是"识别完成的书一次性抽 8 页"（同书页眉页脚高度重
    复），按用户口径改为全量：所有确认过的版面区都进训练数据。"""
    from train_datasets import _box_confirmed

    out = [
        str(p.get("page_id") or p.get("id") or "")
        for p in pages
        if any(_box_confirmed(r) for r in p.get("main_regions") or [])
    ]
    return [pid for pid in out if pid]


def aggregate_layer_stats(manifest: dict) -> dict[str, dict[str, Any]]:
    """从 manifest 聚合各层统计（训练页/闸门的"已导出口径"）。"""
    totals: dict[str, dict[str, Any]] = {}
    for entry in manifest.get("books", {}).values():
        for layer, stats in (entry.get("layers") or {}).items():
            total = totals.setdefault(
                layer, {"instances": 0, "pages": 0, "per_class": {}})
            total["instances"] += int(stats.get("train_instances") or 0)
            total["instances"] += int(stats.get("val_instances") or 0)
            total["pages"] += int(stats.get("train_pages") or 0)
            total["pages"] += int(stats.get("val_pages") or 0)
            for label, n in (stats.get("per_class") or {}).items():
                pc = total["per_class"]
                pc[label] = pc.get(label, 0) + int(n)
    return totals
