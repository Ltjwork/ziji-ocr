# -*- coding: utf-8 -*-
"""训练任务生命周期（从 training_service 拆出）：_Task/_monitor 子进程
监控、start/stop/status、evaluate_char_cls 与日志读取。
training_service.py 仍为门面。"""
import csv
import json
import hashlib
import math
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
from train_registry import (active_model_path, list_models, read_run_meta,
    _load_registry, _save_registry)
from train_worker import list_checkpoints





# ────────────────────────── 训练任务 ──────────────────────────

# ultralytics 训练进度行（verbose 写进 train_log.txt，tqdm 刷新带 ESC[K）：
#   ...      1/150      6.49G     0.2683 ...      79       1280: 50% ━━━━── 2291/4572 8.4it/s
#   ↑ epoch/epochs   GPU 显存    各项损失      实例数  imgsz:  进度条   batch/总数
# 一条正则同时抓 epoch 与本轮 batch 进度（取日志尾部最后一次匹配）。
_YOLO_STEP_RE = re.compile(
    r"(\d+)/(\d+)\s+[\d.]+[MG]\s[^\n:]{0,200}:\s*\d+%[^\d]*?(\d+)/(\d+)")


def _parse_yolo_steps(text: str) -> tuple[int, int, int, int] | None:
    """从日志文本解析最近一次进度行 → (epoch, epochs, batch, batches)。

    匹配不到（启动阶段/分类任务早期/日志尚未写出）返回 None。"""
    match = None
    for match in _YOLO_STEP_RE.finditer(text):
        pass
    if match is None:
        return None
    epoch, epochs, batch, batches = (int(g) for g in match.groups())
    if epochs <= 0 or batches <= 0 or batch > batches or epoch > epochs:
        return None  # 防御畸形行（如初始化阶段的占位输出）
    return epoch, epochs, batch, batches


def _read_log_tail(path: str, max_bytes: int = 16384) -> str:
    """读日志尾部一段文本（进度行每条 ~150B，16KB 覆盖最近上百次刷新）。"""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - max_bytes))
            return f.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


class _Task:
    def __init__(self, task_id: str, layer: str, epochs: int, run_dir: str,
                 base_model: str = "", resumed: bool = False):
        self.id = task_id
        self.layer = layer
        self.epochs = epochs
        self.run_dir = run_dir
        self.base_model = base_model
        self.started = time.time()
        self.proc: subprocess.Popen | None = None
        self.status = "starting"  # starting | training | done | failed | stopped
        self.result: dict | None = None
        # 断点续训：任务起点已完成的轮数（ETA 按本次续训新练的轮数估算，
        # 否则 3 秒/119 轮 会算出"还剩 8 秒"的荒谬预计）。
        self.resumed = resumed
        self._base_done = 0
        # 已完成轮数的时间戳采样（(时刻, 完成轮数)，最新在后）：估每轮
        # 耗时与剩余时间用；由 _monitor 每 2s 轮询时追加，最多留 8 个。
        self._epoch_marks: list[tuple[float, int]] = []

    def to_dict(self) -> dict:
        detail = self._progress_detail()
        return {
            "id": self.id,
            "layer": self.layer,
            "status": self.status,
            "progress": detail["overall"],
            "epochs": self.epochs,
            "base_model": self.base_model,
            "started": self.started,
            "elapsed": round(time.time() - self.started, 1),
            "run_dir": self.run_dir,
            "result": self.result,
            "log_tail": self._log_tail(),
            "resumed": self.resumed,
            # ── 训练进度明细（前端显示"本轮进度 + 预计完成时间"用）──
            "epoch": detail["epoch"],
            "epoch_progress": detail["epoch_progress"],  # 本轮内 0..1，None=未知
            "batch": detail["batch"],  # {"cur": n, "total": m}，None=未知
            "sec_per_epoch": detail["sec_per_epoch"],
            "eta_seconds": detail["eta_seconds"],
            # 最近一个已落盘的存档轮（epoch{N}.pt；写完静置才算，防读到半截），
            # 前端据此触发"存档轮测试页识别"。
            "checkpoint_epoch": self._checkpoint_epoch(),
        }

    def _csv_rows(self) -> int:
        """results.csv 已写出的轮数（每完成一轮追加一行）。"""
        csv_path = os.path.join(self.run_dir, "train", "results.csv")
        if not os.path.exists(csv_path):
            return 0
        try:
            with open(csv_path, encoding="utf-8") as f:
                return max(0, sum(1 for _ in f) - 1)
        except OSError:
            return 0

    def _progress_detail(self) -> dict:
        """进度明细：总体/当前轮/每轮耗时/预计剩余。

        总体进度 = (已完成轮数 + 本轮内 batch 进度) / 总轮数——比只数
        CSV 行（上一版）更平滑，轮内也能看到推进。"""
        done = self._csv_rows()
        finished = self.status in ("done", "failed", "stopped")
        steps = None
        if not finished:
            steps = _parse_yolo_steps(
                _read_log_tail(os.path.join(self.run_dir, "train_log.txt")))
        if steps is not None:
            epoch, _, batch, batches = steps
            batch_frac = batch / batches
            # 日志轮数是 1 基"正在训练第 N 轮"；已完成 = N-1+本轮内进度。
            # 与 CSV 行数取大：CSV 在验证结束才落行，日志略超前。
            done = max(done, min(epoch - 1 + batch_frac, self.epochs))
            epoch_progress = batch_frac
            batch_info = {"cur": batch, "total": batches}
            cur_epoch = min(epoch, self.epochs)
        else:
            epoch_progress = None
            batch_info = None
            cur_epoch = min(done + (0 if finished else 1), self.epochs) or None
        overall = 1.0 if self.status == "done" else min(1.0, done / max(1, self.epochs))

        sec_per_epoch = None
        marks = self._epoch_marks
        if len(marks) >= 2 and marks[-1][1] > marks[0][1]:
            span = marks[-1][0] - marks[0][0]
            rows = marks[-1][1] - marks[0][1]
            if span > 0 and rows > 0:
                sec_per_epoch = span / rows
        eta = None
        if not finished and overall > 0.005:
            remaining = self.epochs - done
            if sec_per_epoch is not None and remaining > 0:
                eta = sec_per_epoch * remaining
            else:
                # 还没攒够两个轮界采样：按本次任务已新练的轮数平均耗时外推
                # （续训任务从基线轮数起算——否则启动 1 分钟/已"完成"119 轮
                # 会算出荒谬的预计；练得还不够看时先不给预计）。
                progressed = done - self._base_done
                if progressed > 0.05 and remaining > 0:
                    eta = (time.time() - self.started) / progressed * remaining
        return {
            "overall": round(max(0.0, min(1.0, overall)), 4),
            "epoch": cur_epoch,
            "epoch_progress": (round(epoch_progress, 4)
                               if epoch_progress is not None else None),
            "batch": batch_info,
            "sec_per_epoch": (round(sec_per_epoch, 1)
                              if sec_per_epoch is not None else None),
            "eta_seconds": (round(eta, 1) if eta is not None else None),
        }

    def _checkpoint_epoch(self) -> int | None:
        """最新存档轮号（epoch{N}.pt 落盘且静置 ≥5s——torch.save 写大文件
        需要数秒，避免前端立刻拿去加载读到半截文件）。"""
        weights = os.path.join(self.run_dir, "train", "weights")
        best: tuple[int, float] | None = None
        try:
            names = os.listdir(weights)
        except OSError:
            return None
        now = time.time()
        for name in names:
            m = re.fullmatch(r"epoch(\d+)\.pt", name)
            if not m:
                continue
            path = os.path.join(weights, name)
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            if now - mtime < 5.0:
                continue  # 可能仍在写入
            epoch = int(m.group(1))
            if best is None or epoch > best[0]:
                best = (epoch, mtime)
        return best[0] if best else None

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
    last_rows = -1
    while task.proc.poll() is None:
        rows = task._csv_rows()
        if rows > 0:
            # 只从 starting 推进（stop 置的 stopped 不被覆盖回 training）
            if task.status == "starting":
                task.status = "training"
            if rows != last_rows:
                # 轮界采样：估每轮耗时/剩余时间的依据（见 _progress_detail）
                task._epoch_marks.append((time.time(), rows))
                del task._epoch_marks[:-8]
                last_rows = rows
        time.sleep(2.0)
    done_path = os.path.join(task.run_dir, "done.json")
    if os.path.exists(done_path):
        try:
            with open(done_path, encoding="utf-8") as f:
                task.result = _json_safe(json.load(f))
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




def resume_training(layer: str, run_dir: str, device: str = "auto") -> dict:
    """断点续训：从 <run_dir>/train/weights/last.pt 继续上次中断的训练。

    总轮数/数据集/增强/保存目录以检查点内保存的原始参数为准
    （ultralytics resume 语义：check_resume 用 ckpt_args 整体替换参数，
    只有 device 等白名单项可覆写），产物继续写回原 run 目录，曲线/注册表
    按同一 run 累计。第 1 轮结束前中断（还没有 last.pt）或已正常完成
    （done.json 存在）的 run 不可续训。
    """
    global _TASK_COUNTER
    if layer not in LAYER_INFO:
        raise ValueError(f"unknown layer: {layer}")
    if LAYER_INFO[layer]["task"] == "siamese":
        raise ValueError("墨迹比对模型不支持断点续训")
    run_dir = os.path.abspath(run_dir)
    last_pt = os.path.join(run_dir, "train", "weights", "last.pt")
    if not os.path.isfile(last_pt):
        raise ValueError(
            "该训练还没有可续训的检查点（last.pt 不存在——第 1 轮结束前"
            "中断的只能重新开始）"
        )
    if os.path.exists(os.path.join(run_dir, "done.json")):
        raise ValueError("该训练已正常完成，无需续训（可直接启用或重新训练）")
    meta = read_run_meta(run_dir)
    try:
        epochs = int(meta.get("epochs") or 0)
    except ValueError:
        epochs = 0
    if epochs <= 0:
        raise ValueError("无法读取原训练的总轮数（train/args.yaml 缺失），不能续训")
    data_hint = meta.get("data") or ""
    base_hint = meta.get("model") or ""
    task_kind = LAYER_INFO[layer]["task"]
    with _TASK_LOCK:
        running = [t for t in _TASKS.values() if t.status in ("starting", "training")]
        if running:
            raise RuntimeError(f"已有训练任务在进行中: {running[0].id} ({running[0].layer})")
        _TASK_COUNTER += 1
        task_id = f"train_{int(time.time())}_{_TASK_COUNTER}"
        task = _Task(task_id, layer, epochs, run_dir,
                     base_model=base_hint, resumed=True)
        # ETA 基线：续训前已完成的轮数（本次耗时只对新增轮数计）
        task._base_done = task._csv_rows()
        _TASKS[task_id] = task

    cmd = [
        sys.executable,
        WORKER_PATH,
        "--task", task_kind,
        "--base", last_pt,
        "--resume",
        "--device", device,
        "--run-dir", run_dir,
    ]
    if data_hint:
        cmd += ["--data", data_hint]
    # 续训练志接在原日志后面（"w" 会把上次中断前的日志清掉）
    log_file = open(os.path.join(run_dir, "train_log.txt"), "a", encoding="utf-8")
    _log(f"resume training {layer}: {' '.join(cmd)}")
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
                done = _json_safe(json.load(f))
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
    （转换失败或空单元格存 None，前端按断点处理）。nan/inf 也降级为
    None：训练早期 val 列常是 nan，而 JSON 不允许非有限浮点，漏一个
    整个 /train/curve 就 500（连接被中途掐断，前端还会误报"后端不可达"）。"""
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
                    num = float(value)
                except (TypeError, ValueError):
                    row[key] = None
                    continue
                row[key] = num if math.isfinite(num) else None
            rows.append(row)
    return columns, rows


def _json_safe(obj: Any) -> Any:
    """递归把非有限浮点（nan/inf）换成 None，保证响应可 JSON 序列化。"""
    if isinstance(obj, float):
        return obj if math.isfinite(obj) else None
    if isinstance(obj, dict):
        return {k: _json_safe(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_json_safe(v) for v in obj]
    return obj


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
