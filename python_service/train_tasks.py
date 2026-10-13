# -*- coding: utf-8 -*-
"""训练任务生命周期（从 training_service 拆出）：_Task/_monitor 子进程
监控、start/stop/status、evaluate_char_cls 与日志读取。
training_service.py 仍为门面。"""
import csv
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
from train_data import (LAYER_INFO, SERVICE_DIR, WORKER_PATH, trained_root_dir,
    _layer_default_model, _log, _annotation_pages, _is_confirmed, h_dir)
from train_registry import (active_model_path, list_models,
    _load_registry, _save_registry)
from train_worker import list_checkpoints





# ────────────────────────── 训练任务 ──────────────────────────


class _Task:
    def __init__(self, task_id: str, layer: str, epochs: int, run_dir: str, base_model: str = ""):
        self.id = task_id
        self.layer = layer
        self.epochs = epochs
        self.run_dir = run_dir
        self.base_model = base_model
        self.started = time.time()
        self.proc: subprocess.Popen | None = None
        self.status = "starting"  # starting | training | done | failed | stopped
        self.result: dict | None = None

    def to_dict(self) -> dict:
        progress = self._progress()
        return {
            "id": self.id,
            "layer": self.layer,
            "status": self.status,
            "progress": progress,
            "epochs": self.epochs,
            "base_model": self.base_model,
            "started": self.started,
            "elapsed": round(time.time() - self.started, 1),
            "run_dir": self.run_dir,
            "result": self.result,
            "log_tail": self._log_tail(),
        }

    def _progress(self) -> float:
        if self.status in ("done", "failed", "stopped"):
            return 1.0 if self.status == "done" else self._csv_progress()
        return self._csv_progress()

    def _csv_progress(self) -> float:
        csv_path = os.path.join(self.run_dir, "train", "results.csv")
        if not os.path.exists(csv_path):
            return 0.0
        try:
            with open(csv_path, encoding="utf-8") as f:
                rows = sum(1 for _ in f) - 1
            return min(1.0, max(0.0, rows / max(1, self.epochs)))
        except Exception:
            return 0.0

    def _log_tail(self, n: int = 30) -> list[str]:
        log_path = os.path.join(self.run_dir, "train_log.txt")
        if not os.path.exists(log_path):
            return []
        try:
            with open(log_path, encoding="utf-8", errors="replace") as f:
                return f.readlines()[-n:]
        except Exception:
            return []




_TASKS: dict[str, _Task] = {}


_TASK_LOCK = threading.Lock()


_TASK_COUNTER = 0




def _monitor(task: _Task) -> None:
    """轮询子进程状态，结束后读 done.json 判定成败并登记注册表。"""
    assert task.proc is not None
    while task.proc.poll() is None:
        if task.status == "starting" and task._csv_progress() > 0:
            task.status = "training"
        time.sleep(2.0)
    done_path = os.path.join(task.run_dir, "done.json")
    if os.path.exists(done_path):
        try:
            with open(done_path, encoding="utf-8") as f:
                task.result = json.load(f)
            task.status = "done"
        except Exception as exc:
            task.status = "failed"
            task.result = {"error": str(exc)}
        # 注册失败不再吞掉成功训练（实测发生过：注册表写入异常 → 状态被
        # 改成 failed 且 run 不登记 → 曲线入口消失。产物在磁盘上，训练
        # 就是成功的；漏登记由 list_models 的磁盘对账兜底补上）。
        if task.status == "done":
            try:
                _register_run(task)
            except Exception as exc:
                _log(f"[train] 注册表登记失败（训练产物完好）: {exc}")
    else:
        task.status = "stopped" if task.status == "stopped" else "failed"




def start_training(
    layer: str,
    data_path: str,
    base_model: str = "yolov8s.pt",
    epochs: int = 150,
    imgsz: int = 1280,
    batch: int = -1,
    device: str = "auto",
    save_period: int = 0,
) -> dict:
    """启动训练子进程，返回任务信息。"""
    global _TASK_COUNTER
    if layer not in LAYER_INFO:
        raise ValueError(f"unknown layer: {layer}")
    # 分类任务先规范化基础模型（强制 -cls 检查点），再创建任务对象——
    # 注册表按这里最终传入的 base_model 归档轮数。
    task_kind = LAYER_INFO[layer]["task"]
    if task_kind == "classify":
        base_model = base_model if base_model.endswith("-cls.pt") else "yolov8n-cls.pt"
        imgsz = min(imgsz, 96)
    with _TASK_LOCK:
        running = [t for t in _TASKS.values() if t.status in ("starting", "training")]
        if running:
            raise RuntimeError(f"已有训练任务在进行中: {running[0].id} ({running[0].layer})")
        _TASK_COUNTER += 1
        task_id = f"train_{int(time.time())}_{_TASK_COUNTER}"
        # 目录名带日期时间，便于肉眼区分每次训练；同秒冲突时追加序号，
        # 永不覆盖旧的训练产物。
        stamp = time.strftime("%Y%m%d_%H%M%S")
        run_dir = os.path.join(trained_root_dir(), layer, f"run_{stamp}")
        suffix = 2
        while os.path.exists(run_dir):
            run_dir = os.path.join(trained_root_dir(), layer, f"run_{stamp}_{suffix}")
            suffix += 1
        os.makedirs(run_dir, exist_ok=True)
        task = _Task(task_id, layer, epochs, run_dir, base_model=base_model)
        _TASKS[task_id] = task

    cmd = [
        sys.executable,
        WORKER_PATH,
        "--task", task_kind,
        "--data", data_path,
        "--base", base_model,
        "--epochs", str(epochs),
        "--imgsz", str(imgsz),
        "--batch", str(batch),
        "--device", device,
        "--save-period", str(max(0, int(save_period))),
        "--run-dir", run_dir,
    ]
    log_file = open(os.path.join(run_dir, "train_log.txt"), "w", encoding="utf-8")
    _log(f"start training {layer}: {' '.join(cmd)}")
    task.proc = subprocess.Popen(
        cmd,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        cwd=SERVICE_DIR,
    )
    log_file.close()
    threading.Thread(target=_monitor, args=(task,), daemon=True).start()
    return task.to_dict()




def stop_training(task_id: str) -> dict:
    with _TASK_LOCK:
        task = _TASKS.get(task_id)
    if task is None:
        raise ValueError(f"no such task: {task_id}")
    task.status = "stopped"
    if task.proc and task.proc.poll() is None:
        task.proc.terminate()
    return task.to_dict()




def training_status() -> list[dict]:
    with _TASK_LOCK:
        tasks = list(_TASKS.values())
    return [t.to_dict() for t in tasks]




def evaluate_char_cls(
    project_dir: str,
    image_path: str,
    use_models: bool = True,
    test_model_path: str | None = None,
    limit: int = 100,
    chars: list[dict[str, Any]] | None = None,
) -> dict:
    """单字候选分类模型的对比评测。

    以单字文字为标准答案（[chars] 显式传入，或读取该页人工确认过的单字），
    对每个字取 top-10 候选，统计正确字排进前 1/3/5/10 的命中率与平均排名。
    [use_models]=False 时禁用自训模型（基线：无候选字分类器，返回空候选）。
    """
    import segmenter

    if not use_models:
        segmenter.set_models_disabled(True)
    if test_model_path:
        segmenter.set_model_test("char_cls", test_model_path)
    try:
        items: list[tuple[str, int, int, int, int]] = []
        if chars:
            for c in chars:
                text = str(c.get("text", "")).strip()
                if len(text) != 1:
                    continue
                items.append((
                    text,
                    int(c.get("x", 0)),
                    int(c.get("y", 0)),
                    int(c.get("w", 0)),
                    int(c.get("h", 0)),
                ))
        else:
            pages = _annotation_pages(project_dir)
            page = next(
                (pg for pg in pages if pg.get("image_path") == image_path), None
            )
            if page is None:
                raise ValueError("该图片没有对应的标注文件（请先在编辑器中识别并保存）")
            for ln in page.get("lines", []):
                if not _is_confirmed(ln):
                    continue
                for c in ln.get("chars", []):
                    if not _is_confirmed(c):
                        continue
                    text = (c.get("text") or "").strip()
                    if len(text) != 1 or c.get("type") == "ignore":
                        continue
                    items.append((text, c["x"], c["y"], c["w"], c["h"]))
        if not items:
            raise ValueError(
                "没有可用于评测的单字（该页既没有人工确认的单字，"
                "自动识别也未得到可用单字）"
            )
        # 限量评测（默认 100 字，避免整页大书评测过久）；超出时均匀抽样。
        if len(items) > limit:
            step = len(items) / limit
            items = [items[int(i * step)] for i in range(limit)]

        image = segmenter._imread(image_path)
        if image is None:
            raise ValueError(f"无法读取页面图片：{image_path}")

        top1 = top3 = top5 = top10 = 0
        ranks: list[int] = []
        details: list[dict[str, Any]] = []
        n = len(items)
        for index, (text, x, y, w, h) in enumerate(items):
            if index % 10 == 0:
                _log(
                    f"[model-use] char_cls 评测进度 {index + 1}/{n} "
                    f"(model={'指定' if test_model_path else '当前启用'})"
                )
            candidates = segmenter.get_char_candidates(
                image_path, (x, y, w, h), top_k=10, image=image
            )
            texts = [
                (c.get("text") or "").strip() for c in candidates
            ]
            rank = next(
                (r for r, t in enumerate(texts) if t == text), None
            )
            if rank is not None:
                ranks.append(rank)
                if rank == 0:
                    top1 += 1
                if rank < 3:
                    top3 += 1
                if rank < 5:
                    top5 += 1
                if rank < 10:
                    top10 += 1
            details.append({
                "index": index,
                "text": text,
                "rank": rank,  # None = 未进前 10
                "candidates": texts[:3],
            })

        not_in_top10 = n - top10

        def pct(v: int) -> float:
            return round(v * 100.0 / n, 1) if n else 0.0

        return {
            "total": n,
            "top1": top1,
            "top3": top3,
            "top5": top5,
            "top10": top10,
            "top1_pct": pct(top1),
            "top3_pct": pct(top3),
            "top5_pct": pct(top5),
            "top10_pct": pct(top10),
            "not_in_top10": not_in_top10,
            "avg_rank": (round(sum(ranks) / len(ranks), 2) if ranks else None),
            "details": details,
        }
    finally:
        segmenter.set_models_disabled(False)
        segmenter.set_model_test(None, None)




def training_log(task_id: str | None = None) -> dict:
    """返回某个训练任务的完整日志文本；不给 task_id 时取最近启动的任务。

    完整日志由 train_worker 整份写入 run_dir/train_log.txt（status 接口
    只带最后 30 行的 log_tail），前端"查看完整日志"读这份文件即可。
    """
    with _TASK_LOCK:
        tasks = list(_TASKS.values())
    if not tasks:
        raise ValueError("no training task")
    task = None
    if task_id:
        task = next((t for t in tasks if t.id == task_id), None)
        if task is None:
            raise ValueError(f"no such task: {task_id}")
    else:
        task = max(tasks, key=lambda t: t.started)
    log_path = os.path.join(task.run_dir, "train_log.txt")
    text = ""
    if os.path.exists(log_path):
        try:
            with open(log_path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except Exception as exc:
            raise ValueError(f"read log failed: {exc}") from exc
    return {
        "task_id": task.id,
        "layer": task.layer,
        "run_dir": task.run_dir,
        "log": text,
    }




def training_curve(run_dir: str) -> dict:
    """训练曲线数据：逐 epoch 指标/损失（results.csv）+ 已存检查点清单。

    run_dir 既接受进行中/本次会话的任务目录，也接受注册表里的历史 run
    （任务表在服务重启后清空，但 run_dir 下的产物一直在磁盘上）。
    detect/classify 的 CSV 在 <run_dir>/train/results.csv（ultralytics 写），
    siamese 在 <run_dir>/results.csv（train_worker 自写），kind 按列名区分。
    """
    run_dir = os.path.abspath(run_dir)
    if not os.path.isdir(run_dir):
        raise ValueError(f"run_dir 不存在: {run_dir}")
    yolo_csv = os.path.join(run_dir, "train", "results.csv")
    if os.path.exists(yolo_csv):
        csv_path = yolo_csv
        kind = None  # 按列名再细分 detect / classify
    elif os.path.exists(os.path.join(run_dir, "results.csv")):
        csv_path = os.path.join(run_dir, "results.csv")
        kind = "siamese"
    else:
        raise ValueError("该 run 目录还没有 results.csv（训练尚未开始写出）")

    columns, rows = _read_curve_csv(csv_path)
    if kind is None:
        if "metrics/accuracy_top1" in columns:
            kind = "classify"
        elif any(c.startswith("metrics/") for c in columns):
            kind = "detect"
        else:
            kind = "unknown"

    weights_dir = os.path.join(run_dir, "train", "weights")
    checkpoints = list_checkpoints(weights_dir)
    if kind == "siamese":
        # 双塔产物在 run 根目录（best.pt，val AUC 最优），不在 weights/
        best = os.path.join(run_dir, "best.pt")
        last = None
        if os.path.exists(best):
            try:
                checkpoints = [{
                    "name": "best.pt", "epoch": None, "path": best,
                    "size": os.path.getsize(best),
                    "mtime": os.path.getmtime(best),
                }] + checkpoints
            except OSError:
                pass
    else:
        best = os.path.join(weights_dir, "best.pt")
        last = os.path.join(weights_dir, "last.pt")
    done = None
    done_path = os.path.join(run_dir, "done.json")
    if os.path.exists(done_path):
        try:
            with open(done_path, encoding="utf-8") as f:
                done = json.load(f)
        except Exception:
            done = None
    return {
        "run_dir": run_dir,
        "kind": kind,
        "columns": columns,
        "rows": rows,
        "checkpoints": checkpoints,
        "best": best if best and os.path.exists(best) else None,
        "last": last if last and os.path.exists(last) else None,
        "done": done,
    }


def _read_curve_csv(csv_path: str) -> tuple[list[str], list[dict]]:
    """解析 results.csv → (列名, 行列表)。

    ultralytics 部分版本列名带前导空格，键统一 strip；值尽量转 float
    （转换失败或空单元格存 None，前端按断点处理）。"""
    with open(csv_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        columns = [(k or "").strip() for k in (reader.fieldnames or [])]
        rows: list[dict] = []
        for raw in reader:
            row: dict = {}
            for key, value in raw.items():
                key = (key or "").strip()
                if not key:
                    continue
                try:
                    row[key] = float(value)
                except (TypeError, ValueError):
                    row[key] = None
            rows.append(row)
    return columns, rows


def _register_run(task: _Task) -> None:
    reg = _load_registry()
    layers = reg.setdefault("layers", {})
    entry = layers.setdefault(task.layer, {"active": None, "runs": []})
    runs = entry.setdefault("runs", [])
    # 同一 run_dir 只留一条：训练进行中 reconcile 可能已按磁盘补登记过
    # 占位条目（无 metrics），完成登记替换而不是追加——追加会产生同
    # best 路径的双条，客户端模型下拉因重复 value 直接断言崩溃。
    key = os.path.normcase(os.path.abspath(str(task.run_dir)))
    runs[:] = [
        r for r in runs
        if os.path.normcase(os.path.abspath(str(r.get("run_dir") or ""))) != key
    ]
    runs.append(
        {
            "run_dir": task.run_dir,
            "best": task.result.get("best") if task.result else None,
            "metrics": task.result.get("metrics") if task.result else None,
            "epochs": task.epochs,
            # 记录本次训练的基础档位（如 yolov8s.pt），数据要求按档位轮数进阶
            "base_model": task.base_model or None,
            # 本次训练的类别词表快照（region_det 已多类化；注册表无版本
            # 字段，凭此区分单类/多类 run，激活与展示时不会张冠李戴）
            "names": list(LAYER_INFO.get(task.layer, {}).get("names") or []),
            "started": task.started,
        }
    )
    _save_registry(reg)
