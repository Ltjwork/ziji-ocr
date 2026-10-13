# -*- coding: utf-8 -*-
"""模型注册表层（从 training_service 拆出）：registry.json 读写经
registry_io（原子写）、run 登记、list/activate/deactivate。
训练完成只登记不自动替换（README 标注与训练规则）。
training_service.py 仍为门面。"""
import json
import hashlib
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import time
from typing import Any
import cv2
import numpy as np
import imaging
import registry_io
from train_data import (LAYER_INFO, LAYERS, SERVICE_DIR,
    TRAINING_REQUIREMENTS, _layer_default_model, _log, trained_root_dir)



REGISTRY_PATH = registry_io.REGISTRY_PATH




def _run_base_tier(layer: str, run: dict) -> str:
    """确定一次成功训练使用的档位（数据要求按档位轮数进阶的前提）。

    优先注册表记录的 base_model；早期训练没记录时从 run_dir/train_log.txt
    的 worker 启动行解析（如 "base=yolov8n.pt"）；都取不到按该层历史
    默认档位归档。
    """

    def _tier_of(model_file: str) -> str:
        key = os.path.splitext(os.path.basename(model_file))[0]
        if layer == "char_cls":
            key = key.removesuffix("-cls")
        return key if key in TRAINING_REQUIREMENTS.get(layer, {}) else ""

    tier = _tier_of(str(run.get("base_model") or ""))
    if tier:
        return tier
    log_path = os.path.join(str(run.get("run_dir") or ""), "train_log.txt")
    try:
        with open(log_path, encoding="utf-8", errors="replace") as f:
            for _ in range(10):
                line = f.readline()
                if not line:
                    break
                if "base=" in line:
                    match = re.search(r"base=([^\s]+\.pt)", line)
                    if match:
                        tier = _tier_of(match.group(1))
                    break
    except OSError:
        pass
    return tier or _layer_default_model(layer)




# ────────────────────────── 模型注册表 ──────────────────────────


def _load_registry() -> dict:
    return registry_io.load_registry(REGISTRY_PATH)




def _save_registry(reg: dict) -> None:
    registry_io.save_registry(reg, REGISTRY_PATH)




def scan_layer_runs(layer: str) -> list[str]:
    """磁盘上的训练 run 目录（trained_root/<layer>/run_*，有 results.csv
    才算数——排除启动失败/手动清空的残目录）。"""
    root = os.path.join(trained_root_dir(), layer)
    if not os.path.isdir(root):
        return []
    out = []
    for name in sorted(os.listdir(root)):
        d = os.path.join(root, name)
        if not name.startswith("run_") or not os.path.isdir(d):
            continue
        if (os.path.exists(os.path.join(d, "train", "results.csv"))
                or os.path.exists(os.path.join(d, "results.csv"))):
            out.append(d)
    return out


def _better_run(a: dict, b: dict) -> dict:
    """同一 run_dir 的两条记录取一：有训练结果（metrics/epochs）的优先，
    都没有则 started 更新的优先。"""
    if (a.get("metrics") is None) != (b.get("metrics") is None):
        return b if a.get("metrics") is None else a
    return b if (b.get("started") or 0) >= (a.get("started") or 0) else a


def reconcile_disk_runs() -> int:
    """磁盘对账：训练正常完成但没登记进注册表的孤儿 run 补登记。

    实测发生过 _monitor 的注册异常把成功训练吞成 failed 且不登记
    （CLEANUP_PLAN 记录过 342MB 孤儿 run）——曲线入口只认注册表 run_dir，
    漏登记直接表现为"训练完看不到曲线"。以磁盘为真相源补齐。返回补登记数。

    顺带修复历史双条：训练进行中 reconcile 补过占位条目、完成登记又
    append 一条，同一 run_dir 出现两条（同 best 路径）——客户端模型下拉
    会因重复 value 触发断言崩溃，这里合并为一条（保留信息更全的）。
    """
    reg = _load_registry()
    added = 0
    deduped = False
    for layer in LAYERS:
        entry = reg["layers"].setdefault(layer, {"active": None, "runs": []})
        runs = entry.get("runs", [])
        merged: dict[str, dict] = {}
        for r in runs:
            key = os.path.normcase(os.path.abspath(str(r.get("run_dir") or "")))
            merged[key] = _better_run(merged[key], r) if key in merged else r
        if len(merged) != len(runs):
            entry["runs"] = list(merged.values())
            deduped = True
        known = set(merged)
        for run_dir in scan_layer_runs(layer):
            if os.path.normcase(os.path.abspath(run_dir)) in known:
                continue
            record = {
                "run_dir": run_dir,
                "best": None,
                "metrics": None,
                "epochs": None,
                "base_model": None,
                "started": os.path.getmtime(run_dir),
                "reconciled": True,
            }
            best = os.path.join(run_dir, "train", "weights", "best.pt")
            if os.path.exists(best):
                record["best"] = best
            try:
                with open(os.path.join(run_dir, "done.json"),
                          encoding="utf-8") as f:
                    done = json.load(f)
                record["metrics"] = done.get("metrics")
                record["epochs"] = done.get("epochs")
            except Exception:
                pass
            entry.setdefault("runs", []).append(record)
            added += 1
    if added or deduped:
        _save_registry(reg)
        _log(f"[registry] 磁盘对账补登记 {added} 个孤儿 run"
             f"{'，合并重复条目' if deduped else ''}")
    return added


def list_models() -> dict:
    reg = _load_registry()
    try:
        reconcile_disk_runs()
        reg = _load_registry()
    except Exception as exc:
        _log(f"[registry] 磁盘对账失败（不影响列表）: {exc}")
    out = {}
    for layer in LAYERS:
        entry = reg.get("layers", {}).get(layer, {})
        active = entry.get("active")
        runs = entry.get("runs", [])

        def _same_path(a, b) -> bool:
            return bool(a) and bool(b) and os.path.normcase(
                os.path.abspath(a)
            ) == os.path.normcase(os.path.abspath(b))

        active_source = entry.get("active_source")
        active_run = next(
            (r for r in runs
             if (active_source and _same_path(r.get("best"), active_source))
             or (not active_source and _same_path(r.get("best"), active))),
            None,
        )
        # 旧注册表：active 是稳定副本路径（active_<layer>.pt），与 run 的
        # best 路径不一致——只有一个 run 时按它回填。
        if active and active_run is None and len(runs) == 1:
            active_run = runs[0]
        try:
            from model_registry import resolve_model_path

            default_path = resolve_model_path(layer)
        except Exception:
            default_path = ""
        out[layer] = {
            "active": active,
            # 启用模型溯源：来自哪个 run 的哪个 .pt（曲线检查点行的
            # "当前启用"标记与模型管理的来源展示用；旧条目无此字段为 None）
            "active_source": active_source,
            "active_exists": bool(active and os.path.exists(active)),
            "metrics": entry.get("active_metrics")
            or (active_run or {}).get("metrics"),
            "runs": runs,  # 全量：曲线入口与模型管理都需要完整历史
            "default": default_path,
            "active_started": entry.get("active_started")
            or (active_run or {}).get("started"),
        }
    # Kraken 整行识别引擎（"单字识别"）：当前 chat_rec.mlmodel 是否为
    # 微调版（与官方底座备份不一致即微调过）。
    try:
        import filecmp

        import kraken_training

        base_exists = os.path.exists(kraken_training.BASE_REC_MODEL)
        finetuned = (
            base_exists
            and os.path.exists(kraken_training.BACKUP_REC_MODEL)
            and not filecmp.cmp(
                kraken_training.BASE_REC_MODEL,
                kraken_training.BACKUP_REC_MODEL,
                shallow=False,
            )
        )
        out["kraken_rec"] = {
            "active": kraken_training.BASE_REC_MODEL if base_exists else None,
            "active_exists": base_exists,
            "finetuned": finetuned,
            "title": "单字识别（Kraken 整行引擎）",
        }
    except Exception:
        pass
    return out




def activate_model(layer: str, model_path: str | None = None) -> dict:
    """启用某层的已训练模型。

    [model_path] 为空时启用最近一次成功训练的 best.pt；也可以指定任意一次
    训练产出的 best.pt 路径（须真实存在），便于回退到旧版本模型。
    """
    if layer not in LAYER_INFO:
        raise ValueError(f"unknown layer: {layer}")
    reg = _load_registry()
    entry = reg.get("layers", {}).get(layer, {})
    runs = [r for r in entry.get("runs", []) if r.get("best") and os.path.exists(r["best"])]
    best_run = None
    if model_path:
        if not os.path.exists(model_path):
            raise ValueError(f"model file not found: {model_path}")
        source = model_path
        best_run = next((r for r in runs if r.get("best") == model_path), None)
    else:
        if not runs:
            raise ValueError(f"{layer} 没有可用的已训练模型")
        best_run = runs[-1]
        source = best_run["best"]
    # 复制到稳定路径，避免 run 目录被清理后失效
    stable_dir = os.path.join(SERVICE_DIR, "models")
    os.makedirs(stable_dir, exist_ok=True)
    stable_path = os.path.join(stable_dir, f"active_{layer}.pt")
    shutil.copyfile(source, stable_path)

    entry["active"] = stable_path
    # 溯源：稳定副本来自哪个 run 的 best（删除该 run 时据此自动停用）
    entry["active_source"] = source
    entry["active_metrics"] = best_run.get("metrics")
    entry["active_started"] = best_run.get("started")
    entry["active_since"] = time.time()
    reg.setdefault("layers", {})[layer] = entry
    _save_registry(reg)
    _log(f"activated {layer}: {stable_path}")

    # 单字检测层沿用现有引擎入口路径
    if layer == "char_det":
        char_path = os.path.join(SERVICE_DIR, "models", "yolo_char.pt")
        shutil.copyfile(stable_path, char_path)
        _log(f"char_det -> {char_path}")

    from segmenter import reset_custom_models

    reset_custom_models()
    return list_models().get(layer, {})




def deactivate_model(layer: str) -> dict:
    reg = _load_registry()
    entry = reg.get("layers", {}).get(layer, {})
    entry["active"] = None
    entry["active_source"] = None
    reg.setdefault("layers", {})[layer] = entry
    _save_registry(reg)
    if layer == "char_det":
        char_path = os.path.join(SERVICE_DIR, "models", "yolo_char.pt")
        if os.path.exists(char_path):
            os.remove(char_path)
    from segmenter import reset_custom_models

    reset_custom_models()
    return list_models().get(layer, {})




def active_model_path(layer: str) -> str | None:
    """供 segmenter 反哺查询：某层当前启用的模型文件路径。"""
    entry = _load_registry().get("layers", {}).get(layer, {})
    active = entry.get("active")
    if active and os.path.exists(active):
        return active
    return None


def delete_run(layer: str, run_dir: str) -> dict:
    """删除一次训练的 run 目录并同步注册表条目。

    安全边界：run_dir 必须落在当前训练根（trained_root/<layer>/run_*）
    之内，拒绝越界删除；该 run 的 best 是当前启用模型时先自动停用再删。
    返回删除的条目摘要。
    """
    layer_root = os.path.join(trained_root_dir(), layer)
    target = os.path.normcase(os.path.normpath(os.path.abspath(run_dir)))
    if not target.startswith(
            os.path.normcase(os.path.abspath(layer_root)) + os.sep):
        raise ValueError(f"run_dir 不在 {layer} 的训练目录内：{run_dir}")
    if not os.path.isdir(target):
        raise ValueError(f"run 目录不存在：{run_dir}")

    reg = _load_registry()
    entry = reg.get("layers", {}).get(layer, {})
    active = entry.get("active")

    def _same(p: str) -> bool:
        return bool(p) and os.path.normcase(os.path.normpath(
            os.path.abspath(p))) == target

    runs = entry.get("runs", [])
    record = next((r for r in runs if _same(str(r.get("run_dir") or ""))), None)
    if record is None:
        raise ValueError("该 run 未登记（注册表中找不到）")

    # 启用中的模型来自这个 run → 先停用（否则推理侧悬空指向被删文件）。
    # active 是稳定副本路径（models/active_<layer>.pt），来源靠 activate
    # 记录的 active_source；旧条目没有该字段时按"唯一有 best 的 run"启发
    # （与 list_models 的旧版回填同口径）。
    def _nc(path) -> str:
        return os.path.normcase(os.path.normpath(os.path.abspath(str(path))))

    active_source = entry.get("active_source")
    best = record.get("best")
    from_active_source = bool(
        active and best and active_source
        and _nc(active_source) == _nc(best))
    legacy_single = bool(
        active and best and not active_source
        and len([r for r in entry.get("runs", []) if r.get("best")]) == 1)
    if from_active_source or legacy_single:
        deactivate_model(layer)
        reg = _load_registry()
        entry = reg.get("layers", {}).get(layer, {})

    shutil.rmtree(target, ignore_errors=False)
    entry["runs"] = [r for r in entry.get("runs", [])
                     if not _same(str(r.get("run_dir") or ""))]
    _save_registry(reg)
    _log(f"[registry] 已删除 {layer} run：{target}")
    return {"layer": layer, "run_dir": target, "deactivated": bool(active)}


def run_dir_size_mb(run_dir: str) -> float:
    """run 目录磁盘占用（MB，模型管理删除确认框展示用）。"""
    total = 0
    for root_dir, _dirs, files in os.walk(run_dir):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root_dir, name))
            except OSError:
                pass
    return total / (1024 * 1024)
