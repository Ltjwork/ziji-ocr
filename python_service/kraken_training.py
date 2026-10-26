"""Kraken 识别模型（整行识别引擎 chat_rec）微调：数据导出 + 训练 + 启用。

与 YOLO 训练（training_service）并列的第二套训练任务。数据为 ketos
`path` 格式：每个"人工确认过的行"导出一张行图 + 一个 .gt.txt 文本对；
训练命令用 kraken 环境的 ketos，并以官方 chat_rec.mlmodel 为底座微调。

任务状态在内存中登记（/kraken/status），完整日志在 run_dir/ketos_log.txt。
"""
from __future__ import annotations

import glob
import json
import os
import re
import shutil
import subprocess
import threading
import time
from typing import Any

import imaging
from train_data import all_book_dirs

SERVICE_DIR = os.path.dirname(os.path.abspath(__file__))
KRAKEN_TRAIN_ROOT = os.path.join(SERVICE_DIR, "kraken_training")
BASE_REC_MODEL = os.path.join(SERVICE_DIR, "kraken_models", "chat_rec.mlmodel")
BACKUP_REC_MODEL = os.path.join(SERVICE_DIR, "kraken_models", "chat_rec_base_backup.mlmodel")

_TASKS: dict[str, "_KrakenTask"] = {}
_TASK_LOCK = threading.Lock()
_TASK_COUNTER = 0


def _log(msg: str) -> None:
    print(f"[kraken-train] {msg}", flush=True)


def _kraken_env_dir() -> str:
    """kraken 环境目录（复用 kraken_bridge 的探测逻辑）。"""
    import kraken_bridge

    return str(Path := __import__("pathlib").Path(kraken_bridge.kraken_python()).parent)


def _ketos_exe() -> str:
    env_dir = _kraken_env_dir()
    candidates = [
        os.path.join(env_dir, "Scripts", "ketos.exe"),
        os.path.join(env_dir, "bin", "ketos"),
        os.path.join(env_dir, "ketos"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return "ketos"


def _all_book_dirs(project_dir: str) -> list[str]:
    """本库（GujiBT）下的全部书籍目录：Kraken 为全局引擎，数据跨书汇总。

    project_dir 可能是单本书目录（库根 = 其父目录），也可能是库根目录本身
    （训练页"全部书籍（汇总）"传入的形态）；后者不能再取父目录，否则会
    把 Documents 当成库根而找不到任何书籍。
    """
    return all_book_dirs(project_dir)


def _confirmed_lines(project_dir: str) -> list[dict[str, Any]]:
    """收集某本书"人工确认过"的行：[(image_path, x, y, w, h, text)]。"""
    from training_service import _annotation_pages, _is_confirmed

    items: list[dict[str, Any]] = []
    for page in _annotation_pages(project_dir):
        image_path = page.get("image_path")
        if not image_path or not os.path.exists(image_path):
            continue
        for ln in page.get("lines", []):
            if not _is_confirmed(ln):
                continue
            text = (ln.get("text") or "").strip()
            if not text:
                # 行文本缺失时回退为已确认单字顺序拼接
                chars = [
                    (c.get("text") or "").strip()
                    for c in ln.get("chars", [])
                    if _is_confirmed(c)
                ]
                text = "".join(chars)
            if not text:
                continue
            items.append({
                "image_path": image_path,
                "x": ln["x"],
                "y": ln["y"],
                "w": ln["w"],
                "h": ln["h"],
                "text": text,
            })
    return items


def _has_model_artifacts(run_dir: str) -> bool:
    """该次训练是否真正产出过模型文件（失败的尝试不算一代）。"""
    for dirpath, _dirnames, filenames in os.walk(run_dir):
        for name in filenames:
            if name.endswith((".mlmodel", ".safetensors")):
                return True
    return False


def generation() -> int:
    """微调代数：真正产出过模型的训练次数 + 1（失败的尝试不算一代）。"""
    if not os.path.isdir(KRAKEN_TRAIN_ROOT):
        return 1
    runs = 0
    for d in os.listdir(KRAKEN_TRAIN_ROOT):
        run_dir = os.path.join(KRAKEN_TRAIN_ROOT, d)
        if d.startswith("run_") and os.path.isdir(run_dir) and _has_model_artifacts(run_dir):
            runs += 1
    return runs + 1


def required_lines(generation: int) -> int:
    """第 k 代微调需要至少 100*k 行确认行：模型版本越新，要求数据越多，
    避免拿同一小批数据反复微调刷版本。"""
    return 100 * max(1, generation)


def data_status(project_dir: str) -> dict:
    """Kraken 微调的数据就绪状态（确认行数 vs 当前代数需求）。

    Kraken 识别模型是全局引擎，统计范围为本库下全部书籍的确认行。
    """
    confirmed = sum(len(_confirmed_lines(b)) for b in _all_book_dirs(project_dir))
    gen = generation()
    required = required_lines(gen)
    return {
        "confirmed": confirmed,
        "required": required,
        "generation": gen,
        "ready": confirmed >= required,
        "missing": max(0, required - confirmed),
    }


def export_dataset(project_dirs: list[str], out_dir: str | None = None, max_lines: int | None = None) -> dict:
    """导出确认行为 ketos `path` 格式：<out>/lines/<n>.png + <n>.gt.txt。

    不指定 [out_dir] 时导出到全局目录 kraken_training/datasets/_global/
    （每次全量重建），与"训练数据跨书共享"的口径一致。"""
    import cv2
    import numpy as np

    from segmenter import _imread

    lines = []
    for project_dir in project_dirs:
        lines.extend(_confirmed_lines(project_dir))
    if len(lines) < 10:
        raise ValueError(
            f"可用确认行太少（{len(lines)} 行）：Kraken 微调建议至少几十行，"
            "请先在编辑器中多确认并保存一些页面。"
        )
    if max_lines and len(lines) > max_lines:
        step = len(lines) / max_lines
        lines = [lines[int(i * step)] for i in range(max_lines)]

    if out_dir is None:
        out_dir = os.path.join(KRAKEN_TRAIN_ROOT, "datasets", "_global")
        shutil.rmtree(out_dir, ignore_errors=True)
    lines_dir = os.path.join(out_dir, "lines")
    os.makedirs(lines_dir, exist_ok=True)

    image_cache: dict[str, Any] = {}
    written = 0
    filelist: list[str] = []
    for i, item in enumerate(lines):
        image_path = item["image_path"]
        if image_path not in image_cache:
            image_cache = {image_path: _imread(image_path)}
        img = image_cache.get(image_path)
        if img is None:
            continue
        pad = 2
        x1 = max(0, item["x"] - pad)
        y1 = max(0, item["y"] - pad)
        x2 = item["x"] + item["w"] + pad
        y2 = item["y"] + item["h"] + pad
        crop = img[y1:y2, x1:x2]
        if crop.size == 0:
            continue
        base = f"{i:05d}"
        img_path = os.path.join(lines_dir, base + ".png")
        if not imaging.imwrite_unicode(img_path, crop):
            continue
        with open(os.path.join(lines_dir, base + ".gt.txt"), "w", encoding="utf-8") as f:
            f.write(item["text"] + "\n")
        filelist.append(img_path)
        written += 1
        if written >= 3000:
            break

    with open(os.path.join(out_dir, "training_files.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(filelist))
    return {"out_dir": out_dir, "lines": written, "filelist": os.path.join(out_dir, "training_files.txt")}


class _KrakenTask:
    def __init__(
        self, task_id: str, project_dir: str, epochs: int, run_dir: str,
        generation: int = 1,
    ):
        self.id = task_id
        self.project_dir = project_dir
        self.epochs = epochs
        self.run_dir = run_dir
        self.generation = generation
        self.started = time.time()
        self.status = "starting"
        self.proc: subprocess.Popen | None = None
        self.result: dict[str, Any] = {}

    def _epoch_done(self) -> int:
        """从 ketos 日志解析已完成的最大 epoch 数。"""
        log_path = os.path.join(self.run_dir, "ketos_log.txt")
        if not os.path.exists(log_path):
            return 0
        try:
            with open(log_path, encoding="utf-8", errors="replace") as f:
                best = 0
                for m in re.finditer(r"(?i)epoch\s+(\d+)", f.read()):
                    best = max(best, int(m.group(1)))
            return best
        except Exception:
            return 0

    def _progress(self) -> float:
        """从 ketos 日志解析已完成的 epoch 数估算进度。"""
        if self.status == "done":
            return 1.0
        return min(1.0, self._epoch_done() / max(1, self.epochs))

    def _eta_seconds(self) -> float | None:
        """预计剩余秒数（按总耗时比例外推；ketos 日志只有轮界信息，
        早期估算含装载开销、偏保守）。"""
        if self.status not in ("starting", "training"):
            return None
        progress = self._progress()
        if progress <= 0.005:
            return None
        elapsed = time.time() - self.started
        return round(elapsed / progress * (1.0 - progress), 1)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "layer": "kraken_rec",
            "project_dir": self.project_dir,
            "epochs": self.epochs,
            "started": self.started,
            "elapsed": round(time.time() - self.started, 1),
            "run_dir": self.run_dir,
            "status": self.status,
            "progress": round(self._progress(), 3),
            "epoch": min(self._epoch_done(), self.epochs),
            "eta_seconds": self._eta_seconds(),
            "generation": self.generation,
            "log_tail": self._log_tail(),
        }

    def _log_tail(self, n: int = 30) -> list[str]:
        log_path = os.path.join(self.run_dir, "ketos_log.txt")
        if not os.path.exists(log_path):
            return []
        try:
            with open(log_path, encoding="utf-8", errors="replace") as f:
                return f.readlines()[-n:]
        except Exception:
            return []

    def _find_best_model(self) -> str | None:
        """ketos 产物：run_dir 下 model_best.* / model_*.mlmodel 等。"""
        candidates: list[tuple[float, str]] = []
        for name in sorted(os.listdir(self.run_dir)):
            lp = os.path.join(self.run_dir, name)
            if not os.path.isfile(lp):
                continue
            if name.endswith((".mlmodel", ".safetensors")) and "best" in name:
                candidates.append((os.path.getmtime(lp), lp))
        if not candidates:
            for name in sorted(os.listdir(self.run_dir)):
                lp = os.path.join(self.run_dir, name)
                if os.path.isfile(lp) and name.endswith((".mlmodel", ".safetensors")):
                    candidates.append((os.path.getmtime(lp), lp))
        return max(candidates)[1] if candidates else None


_TASK_LOCK = threading.Lock()


def start_training(
    project_dir: str,
    epochs: int = 30,
    base_model: str | None = None,
    max_lines: int | None = 2000,
) -> dict:
    """导出数据并启动 ketos 微调子进程。

    数据导出发生在任务注册之前：导出失败（确认行不足等）时不登记任务，
    用户修正数据后可直接重试，不会留下"进行中"的死任务。
    """
    global _TASK_COUNTER
    with _TASK_LOCK:
        running = [
            t for t in _TASKS.values() if t.status in ("starting", "training")
        ]
        if running:
            raise RuntimeError(f"已有 Kraken 微调任务在进行中: {running[0].id}")

    base = base_model or BASE_REC_MODEL
    if not os.path.exists(base):
        raise ValueError(f"底座识别模型不存在：{base}")

    # 数据需求随微调代数自动增加：第 1 代 100 行，第 2 代 200 行……
    gen = generation()
    required = required_lines(gen)
    books = _all_book_dirs(project_dir)
    confirmed = sum(len(_confirmed_lines(b)) for b in books)
    if confirmed < required:
        raise ValueError(
            f"训练数据不足：本次为第 {gen} 代微调，需要全部书籍共 {required} 行确认行，"
            f"当前 {confirmed} 行，还差 {required - confirmed} 行。"
            "请先在编辑器中多确认几页后再试。"
        )

    stamp = time.strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(KRAKEN_TRAIN_ROOT, f"run_{stamp}")
    suffix = 2
    while os.path.exists(run_dir):
        run_dir = os.path.join(KRAKEN_TRAIN_ROOT, f"run_{stamp}_{suffix}")
        suffix += 1
    os.makedirs(run_dir, exist_ok=True)
    export = export_dataset(books, out_dir=os.path.join(run_dir, "lines"), max_lines=max_lines)
    _log(f"exported {export['lines']} lines -> {export['out_dir']}")
    filelist = export["filelist"]
    if export["lines"] < 10:
        shutil.rmtree(run_dir, ignore_errors=True)
        raise ValueError(
            f"可用确认行太少（{export['lines']} 行），Kraken 微调建议至少几十行。"
            "请先在编辑器中多确认并保存几页。"
        )

    with _TASK_LOCK:
        # 导出耗时期间可能又启动了任务，双检
        running = [
            t for t in _TASKS.values() if t.status in ("starting", "training")
        ]
        if running:
            shutil.rmtree(run_dir, ignore_errors=True)
            raise RuntimeError(f"已有 Kraken 微调任务在进行中: {running[0].id}")
        _TASK_COUNTER += 1
        task_id = f"kraken_{stamp}_{_TASK_COUNTER}"
        task = _KrakenTask(task_id, project_dir, epochs, run_dir, generation=gen)
        _TASKS[task_id] = task

    ketos = _ketos_exe()
    cmd = [
        ketos,
        "train",
        "-f", "path",
        "-t", filelist,
        "--load", base,
        "--resize", "union",
        "-q", "fixed",
        "-N", str(epochs),
        "-B", "1",
        "-o", run_dir,
    ]
    _log("start ketos: " + " ".join(cmd))
    log_path = os.path.join(run_dir, "ketos_log.txt")
    with open(log_path, "w", encoding="utf-8") as lf:
        task.proc = subprocess.Popen(
            cmd,
            stdout=lf,
            stderr=subprocess.STDOUT,
            cwd=run_dir,
        )

    def _monitor(task: _KrakenTask, proc: subprocess.Popen) -> None:
        while proc.poll() is None:
            time.sleep(2.0)
        task.status = "done" if proc.returncode == 0 else "failed"
        best = task._find_best_model()
        task.result = {"best": best, "returncode": proc.returncode}
        _log(f"kraken task {task.id} finished: {task.status}, best={best}")

    threading.Thread(target=_monitor, args=(task, task.proc), daemon=True).start()
    return task.to_dict()


def kraken_status() -> list[dict]:
    with _TASK_LOCK:
        tasks = list(_TASKS.values())
    return [t.to_dict() for t in tasks]


def kraken_stop(task_id: str) -> dict:
    with _TASK_LOCK:
        task = _TASKS.get(task_id)
    if task is None:
        raise ValueError(f"no such task: {task_id}")
    if task.proc and task.proc.poll() is None:
        task.proc.terminate()
    task.status = "stopped"
    with _TASK_LOCK:
        # 停止即从登记表移除：即使任务从未真正启动过（卡在 starting），
        # 用户也能通过"停止"清理掉，然后重新开始。
        _TASKS.pop(task_id, None)
    return task.to_dict()


def latest_kraken_model() -> str | None:
    """最近一次成功微调产出的模型文件（done 标记或目录内最新权重）。"""
    root = KRAKEN_TRAIN_ROOT
    newest: tuple[float, str] | None = None
    if not os.path.isdir(root):
        return None
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if not name.endswith((".mlmodel", ".safetensors")):
                continue
            lp = os.path.join(dirpath, name)
            mt = os.path.getmtime(lp)
            if newest is None or mt > newest[0]:
                newest = (mt, lp)
    return newest[1] if newest else None


def activate_kraken_model(model_path: str | None = None) -> dict:
    """启用微调模型：备份官方底座（仅首次）→ 覆盖识别引擎模型 → 重启引擎。"""
    if model_path is None:
        model_path = latest_kraken_model()
    if not model_path or not os.path.exists(model_path):
        raise ValueError("没有可启用的微调模型文件")
    if not os.path.exists(BACKUP_REC_MODEL):
        shutil.copyfile(BASE_REC_MODEL, BACKUP_REC_MODEL)
    shutil.copyfile(model_path, BASE_REC_MODEL)
    # 识别守护进程在内存中持有旧模型；重启它后下一次识别自动加载新模型。
    import kraken_bridge

    kraken_bridge.shutdown()
    _log(f"activated kraken rec model: {model_path}")
    return {"active": BASE_REC_MODEL, "backup": BACKUP_REC_MODEL}


def deactivate_kraken_model() -> dict:
    """停用微调模型：恢复官方底座模型。"""
    if not os.path.exists(BACKUP_REC_MODEL):
        raise ValueError("没有备份的官方模型可恢复")
    shutil.copyfile(BACKUP_REC_MODEL, BASE_REC_MODEL)
    import kraken_bridge

    kraken_bridge.shutdown()
    _log("kraken rec model restored to official base model")
    return {"active": BASE_REC_MODEL, "backup": BACKUP_REC_MODEL}
