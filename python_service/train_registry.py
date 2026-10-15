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
import csv
import math
from train_data import (LAYER_INFO, LAYERS, SERVICE_DIR,
    TRAINING_REQUIREMENTS, _layer_default_model, _log, trained_root_dir)
from train_worker import list_checkpoints



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


# 各任务类型的主指标列（管理页检查点行与曲线弹窗同口径展示）。
_PRIMARY_METRIC_BY_TASK = {
    "detect": ("metrics/mAP50-95(B)", "mAP50-95"),
    "classify": ("metrics/accuracy_top1", "top1"),
}


def _epoch_primary_metrics(csv_path: str, metric_col: str) -> dict[int, float]:
    """results.csv → {epoch: 主指标值}（列缺失/解析失败返回空表）。"""
    out: dict[int, float] = {}
    try:
        with open(csv_path, encoding="utf-8") as f:
            reader = csv.DictReader(f)
            fields = {(k or "").strip() for k in (reader.fieldnames or [])}
            if metric_col not in fields or "epoch" not in fields:
                return out
            for raw in reader:
                try:
                    epoch = int(float(raw.get("epoch") or ""))
                    value = float(raw.get(metric_col) or "")
                except (TypeError, ValueError):
                    continue
                # nan/inf 不进响应（JSON 不允许非有限浮点，与
                # /train/curve 的降级口径一致）
                if math.isfinite(value):
                    out[epoch] = value
    except OSError:
        pass
    return out


def _run_checkpoint_list(layer: str, run: dict) -> list[dict]:
    """run 的检查点清单（含每轮主指标）：管理页展开行直接渲染，不用
    再逐 run 拉 /train/curve。best 行指标取注册表登记值，epoch 行取
    results.csv，last 行取 CSV 末轮；读不到就是 None（前端留空）。"""
    run_dir = str(run.get("run_dir") or "")
    if not run_dir:
        return []
    weights = os.path.join(run_dir, "train", "weights")
    items = list_checkpoints(weights)
    if not items:
        return []
    metric_col, _label = _PRIMARY_METRIC_BY_TASK.get(
        LAYER_INFO.get(layer, {}).get("task", ""), (None, None))
    by_epoch: dict[int, float] = {}
    if metric_col:
        by_epoch = _epoch_primary_metrics(
            os.path.join(run_dir, "train", "results.csv"), metric_col)
    reg_metrics = run.get("metrics") if isinstance(run.get("metrics"), dict) else {}
    out = []
    for c in items:
        metric = None
        if c["name"] == "best.pt" and metric_col:
            metric = reg_metrics.get(metric_col)
        elif c["epoch"] is not None:
            metric = by_epoch.get(c["epoch"])
        elif c["name"] == "last.pt" and by_epoch:
            metric = by_epoch.get(max(by_epoch))
        try:
            if metric is not None and math.isfinite(metric):
                metric = round(float(metric), 6)
            else:
                metric = None
        except (TypeError, ValueError):
            metric = None
        out.append({"name": c["name"], "epoch": c["epoch"],
                    "path": c["path"], "size": c["size"], "metric": metric})
    return out


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
        for r in runs:
            try:
                r["checkpoints"] = _run_checkpoint_list(layer, r)
            except Exception as exc:
                r["checkpoints"] = []
                _log(f"[registry] 检查点清单读取失败（{layer} run 条目仍返回）: {exc}")
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
    训练产出的模型文件路径（best.pt 或中间轮 epoch{N}.pt，须真实存在），
    便于回退旧版本或按轮启用（训练曲线弹窗的检查点行）。
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
        if best_run is None:
            # 中间轮检查点（epoch{N}.pt）不等于任何 run 的 best：按所在
            # run 目录归属（训练曲线弹窗"按轮启用"走的就是这种路径），
            # 指标/时间取该 run 的登记值做展示兜底。
            nc = os.path.normcase(os.path.normpath(os.path.abspath(model_path)))
            best_run = next(
                (r for r in runs if str(r.get("run_dir") or "") and nc.startswith(
                    os.path.normcase(os.path.normpath(
                        os.path.abspath(str(r["run_dir"])))) + os.sep)),
                None)
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
    # 溯源：稳定副本来自哪个 run 的哪个 .pt（删除该 run 时据此自动停用）
    entry["active_source"] = source
    entry["active_metrics"] = (best_run or {}).get("metrics")
    entry["active_started"] = (best_run or {}).get("started")
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


def delete_checkpoint(layer: str, path: str) -> dict:
    """删除 run 里的一个模型文件（best.pt / last.pt / epoch{N}.pt）。

    每个版本都可单独删除（用户按需留档释放磁盘）；唯一硬保护是当前
    启用模型的来源（active_source）不可删——运行中模型是稳定副本
    （models/active_<layer>.pt），删其他源文件不影响推理。删 best 时
    同步清掉注册表里该 run 的 best 标记（run 仍登记，剩余轮数与训练
    曲线入口保留）。安全边界与 delete_run 同口径：只允许当前训练根
    <layer>/run_*/train/weights/ 下的这三类文件名。
    """
    if layer not in LAYER_INFO:
        raise ValueError(f"unknown layer: {layer}")
    layer_root = os.path.normcase(os.path.normpath(
        os.path.abspath(os.path.join(trained_root_dir(), layer))))
    full = os.path.normcase(os.path.normpath(os.path.abspath(path)))
    if not full.startswith(layer_root + os.sep):
        raise ValueError(f"路径不在 {layer} 的训练目录内")
    weights_dir = os.path.dirname(full)
    name = os.path.basename(full)
    if (os.path.basename(weights_dir) != "weights"
            or os.path.basename(os.path.dirname(weights_dir)) != "train"
            or not re.fullmatch(r"(epoch\d+|best|last)\.pt", name)):
        raise ValueError(
            "只能删除 run 检查点（…/train/weights/ 下 的 best.pt / "
            "last.pt / epochN.pt）")
    if not os.path.exists(full):
        raise ValueError(f"文件不存在：{path}")

    reg = _load_registry()
    entry = reg.get("layers", {}).get(layer, {})
    active_source = entry.get("active_source")
    if active_source and os.path.normcase(os.path.normpath(
            os.path.abspath(str(active_source)))) == full:
        raise ValueError("该文件是当前启用模型的来源；请先启用其他版本再删除")

    size = os.path.getsize(full)
    os.remove(full)
    if name == "best.pt":
        # 该 run 失去 best 标记（仍登记；list_models 照常返回，
        # 客户端按 run_dir + 剩余检查点渲染）
        changed = False
        for r in entry.get("runs", []):
            if r.get("best") and os.path.normcase(os.path.normpath(
                    os.path.abspath(str(r["best"])))) == full:
                r["best"] = None
                changed = True
        if changed:
            _save_registry(reg)
    _log(f"[registry] 已删除 {layer} 检查点：{full}（{size} 字节）")
    return {"layer": layer, "path": full, "size": size}


def import_model(layer: str, path: str) -> dict:
    """导入外部 .pt 模型为该层的一个 run（复制进训练根并登记）。

    用于把别处训练/拷贝来的模型纳入统一管理：可启用、可删除、可进
    对比测试与按轮启用（无训练历史，曲线弹窗会提示没有 results.csv）。
    返回新 run 的注册表条目。
    """
    if layer not in LAYER_INFO:
        raise ValueError(f"unknown layer: {layer}")
    if not path.lower().endswith(".pt"):
        raise ValueError("只支持导入 .pt 模型文件")
    if not os.path.isfile(path):
        raise ValueError(f"文件不存在：{path}")
    stamp = time.strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(trained_root_dir(), layer, f"run_import_{stamp}")
    suffix = 2
    while os.path.exists(run_dir):
        run_dir = os.path.join(trained_root_dir(), layer,
                               f"run_import_{stamp}_{suffix}")
        suffix += 1
    weights = os.path.join(run_dir, "train", "weights")
    os.makedirs(weights, exist_ok=True)
    best = os.path.join(weights, "best.pt")
    shutil.copyfile(path, best)
    with open(os.path.join(run_dir, "done.json"), "w", encoding="utf-8") as f:
        json.dump({"best": best, "metrics": None, "epochs": None,
                   "imported": True, "source": os.path.abspath(path)},
                  f, ensure_ascii=False, indent=1)
    reg = _load_registry()
    entry = reg.setdefault("layers", {}).setdefault(
        layer, {"active": None, "runs": []})
    record = {
        "run_dir": run_dir,
        "best": best,
        "metrics": None,
        "epochs": None,
        "base_model": f"导入自 {os.path.abspath(path)}",
        "started": time.time(),
        "imported": True,
    }
    entry.setdefault("runs", []).append(record)
    _save_registry(reg)
    _log(f"[registry] 已导入 {layer} 模型：{path} -> {best}")
    return record


def cleanup_scan() -> dict:
    """扫描训练模型根目录：每个 run 的磁盘占用与状态（清理页数据源）。

    registered=注册表可查（曲线/对比/按轮入口可用）；finished=训练正常
    完成（有 done.json）；trained=有训练曲线（results.csv）。三者皆无的
    是启动失败/手动中断的残目录，清理页可整删。best_mb 含 best/last，
    epochs_mb 是全部中间轮（epochN.pt）。
    """
    root = trained_root_dir()
    reg = _load_registry()
    known = set()
    for entry in reg.get("layers", {}).values():
        for r in entry.get("runs", []):
            d = str(r.get("run_dir") or "")
            if d:
                known.add(os.path.normcase(os.path.normpath(
                    os.path.abspath(d))))
    runs_out = []
    if os.path.isdir(root):
        for layer in sorted(os.listdir(root)):
            layer_dir = os.path.join(root, layer)
            if layer.startswith(".") or not os.path.isdir(layer_dir):
                continue
            for name in sorted(os.listdir(layer_dir)):
                run_dir = os.path.join(layer_dir, name)
                if not name.startswith("run_") or not os.path.isdir(run_dir):
                    continue
                key = os.path.normcase(os.path.normpath(
                    os.path.abspath(run_dir)))
                weights = os.path.join(run_dir, "train", "weights")
                epochs_count = 0
                epochs_mb = 0.0
                best_mb = 0.0
                if os.path.isdir(weights):
                    for f in os.listdir(weights):
                        fp = os.path.join(weights, f)
                        if not os.path.isfile(fp):
                            continue
                        try:
                            mb = os.path.getsize(fp) / 1024 / 1024
                        except OSError:
                            continue
                        if re.fullmatch(r"epoch\d+\.pt", f):
                            epochs_count += 1
                            epochs_mb += mb
                        elif f in ("best.pt", "last.pt"):
                            best_mb += mb
                runs_out.append({
                    "layer": layer,
                    "run_dir": run_dir,
                    "name": name,
                    "registered": key in known,
                    "finished": os.path.exists(
                        os.path.join(run_dir, "done.json")),
                    "trained": os.path.exists(
                        os.path.join(run_dir, "train", "results.csv"))
                    or os.path.exists(os.path.join(run_dir, "results.csv")),
                    "epochs_count": epochs_count,
                    "epochs_mb": round(epochs_mb, 1),
                    "best_mb": round(best_mb, 1),
                    "size_mb": round(epochs_mb + best_mb, 1),
                })
    return {"root": root, "total_mb": round(sum(r["size_mb"] for r in runs_out), 1),
            "runs": runs_out}


def cleanup_run(layer: str, run_dir: str, action: str) -> dict:
    """清理一个 run：action='epochs' 删全部中间轮检查点（保留 best/last
    与当前启用来源）；action='dir' 整删未登记的残目录（注册过的 run 走
    /models/delete_run——那里有停用与注册表同步）。"""
    if layer not in LAYER_INFO:
        raise ValueError(f"unknown layer: {layer}")
    layer_root = os.path.normcase(os.path.normpath(
        os.path.abspath(os.path.join(trained_root_dir(), layer))))
    target = os.path.normcase(os.path.normpath(os.path.abspath(run_dir)))
    if not target.startswith(layer_root + os.sep):
        raise ValueError(f"run_dir 不在 {layer} 的训练目录内")
    if not os.path.isdir(target):
        raise ValueError(f"run 目录不存在：{run_dir}")

    if action == "dir":
        reg = _load_registry()
        entry = reg.get("layers", {}).get(layer, {})
        known = any(os.path.normcase(os.path.normpath(
            os.path.abspath(str(r.get("run_dir") or "")))) == target
            for r in entry.get("runs", []))
        if known:
            raise ValueError(
                "该 run 已登记，请在模型管理里删除（会同步停用与注册表）")
        shutil.rmtree(target, ignore_errors=False)
        _log(f"[registry] 已清理 {layer} 残目录：{target}")
        return {"layer": layer, "run_dir": target, "action": "dir",
                "deleted": 0, "skipped_active": 0, "freed_mb": 0.0}

    if action != "epochs":
        raise ValueError(f"unknown action: {action}")
    weights = os.path.join(target, "train", "weights")
    if not os.path.isdir(weights):
        raise ValueError("该 run 没有 weights 目录（没有可清理的检查点）")
    reg = _load_registry()
    entry = reg.get("layers", {}).get(layer, {})
    active_source = entry.get("active_source")
    active_nc = (os.path.normcase(os.path.normpath(
        os.path.abspath(str(active_source)))) if active_source else None)
    freed = 0
    deleted = 0
    skipped = 0
    for f in os.listdir(weights):
        if not re.fullmatch(r"epoch\d+\.pt", f):
            continue
        fp = os.path.join(weights, f)
        if (active_nc and os.path.normcase(os.path.normpath(
                os.path.abspath(fp))) == active_nc):
            skipped += 1
            continue
        try:
            freed += os.path.getsize(fp)
        except OSError:
            continue
        os.remove(fp)
        deleted += 1
    _log(f"[registry] 已清理 {layer} 中间轮 {deleted} 个"
         f"（跳过启用中 {skipped} 个）：{target}")
    return {"layer": layer, "run_dir": target, "action": "epochs",
            "deleted": deleted, "skipped_active": skipped,
            "freed_mb": round(freed / 1024 / 1024, 1)}


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
