# -*- coding: utf-8 -*-
"""墨迹比对模型（siamese）的训练设施：数据导出 + 易混字挖掘 + 训练任务
管理 + 注册/激活。

数据口径与推理完全同管线（char_verify）：墨迹侧走 OTSU mask →
_crop_ink 净化 → _prepare(收细到字形笔宽) 的 128 画布二值图，字形侧走
_render_glyph → _prepare。训练=推理同分布是硬要求（char_cls 曾因训练/
推理裁剪 padding 漂移导致候选被邻字主导，见 CHANGELOG）。

样本：
  正样本 label=1 —— 页级确认页上确认行里的确认单字（墨迹, 正确字）；
  硬负样本 label=0 —— ①"改过首选"：确认字但 text != 候选首选（被否决
  的识别首选是真实错读，字形按首选渲染）；②字形库内易混字：对全书
  出现过的字做字形骨架两两 Chamfer，为每个字取最相似的 top-k 异字。
划分：只对"会产生样本的页"做页级 train/val（与 training_service 的
char_cls 数据集同修复：对全部页划分时 val 键可能全落在不写入的页上）。

任务管理仿 kraken_training：子进程跑 train_worker --task siamese（纯
torch 双塔，在线增强），进度按 results.csv 行数/epochs，产物
best.pt + done.json（val AUC）。注册表写 models/registry.json 的
verify_pair 层（与 YOLO 层同构），激活 = 复制到
models/active_verify_pair.pt（char_verify 惰性加载、路径变化自动重载）。
"""

import json
import os
import shutil
import subprocess
import sys
import threading
import time

import cv2
import numpy as np

import char_verify
import training_service as ts
import imaging
import registry_io
from training_service import (REGISTRY_PATH, trained_root_dir,
                              WORKER_PATH, _is_confirmed, _page_confirmed,
                              _page_split)

CONFUSE_K = 3            # 每个字挖掘的易混异字数（字形骨架 Chamfer top-k）
CONFUSE_SIM_MIN = 0.55   # 低于此相似度的"易混字"没有训练价值，不挖
CONFUSE_SIM_MAX = 0.90   # 高于此相似度的近孪生字对（：/ :、人/入、問/間，
                          # 首版挖掘实测 76% 负样本落在 0.85-0.92、3% 超过
                          # 0.92）在 128px 二值图上几乎不可分——当负样本只
                          # 会变成标签噪声，把 val AUC 锁死在 0.66（首版
                          # 回测教训）；放弃这一段，交给拓扑层/人工兜底
MIN_POSITIVES = 300      # 正样本门槛（低于此不建议训练）
DEFAULT_EPOCHS = 60
LAYER = "verify_pair"
ACTIVE_NAME = "active_verify_pair.pt"

_models_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "models")
ACTIVE_PATH = os.path.join(_models_dir, ACTIVE_NAME)

# --- 数据状态与导出 ---------------------------------------------------------


def _iter_confirmed_chars(pages):
    """产出 (page_id, rect, text, rejected_first) —— 确认页/确认行/确认
    单字；rejected_first 为被否决的识别首选（无则 None）。口径与
    training_service._write_char_cls_dataset 一致（行未确认的字不可信）。"""
    for ann in pages:
        if not _page_confirmed(ann):
            continue
        pid = str(ann.get("page_id") or "page")
        for line in ann.get("lines", []):
            if not _is_confirmed(line):
                continue
            for i, c in enumerate(line.get("chars", [])):
                text = (c.get("text") or "").strip()
                if not _is_confirmed(c):
                    continue
                if len(text) != 1 or c.get("type") == "ignore":
                    continue
                if c.get("w", 0) <= 0 or c.get("h", 0) <= 0:
                    continue
                cands = c.get("candidates") or []
                rejected = None
                if cands and text != (cands[0].get("text") or "").strip():
                    first = (cands[0].get("text") or "").strip()
                    if len(first) == 1:
                        rejected = first
                yield pid, i, (c["x"], c["y"], c["w"], c["h"]), text, rejected


def data_status(project_dir: str) -> dict:
    """可训练数据概况（全局口径：聚合 project_dir 所在书库的全部书籍）。

    模型与数据集都是全局资产，从任何一本书进入训练页看到的都是同一份
    累计数据：确认单字（正样本）/改过首选（硬负）/页数。
    """
    books = ts.all_book_dirs(project_dir)
    if not books:
        raise ValueError(f"没有找到书籍项目：{project_dir}")
    pages, _ = ts._load_book_pages(books)
    positives, rejected = 0, 0
    page_ids = set()
    charset = set()
    for pid, _i, _rect, text, rej in _iter_confirmed_chars(pages):
        positives += 1
        page_ids.add(pid)
        charset.add(text)
        if rej:
            rejected += 1
            charset.add(rej)
    return {
        "pages": len(page_ids),
        "positives": positives,
        "rejected_first": rejected,
        "charset": len(charset),
        "min_positives": MIN_POSITIVES,
        "ready": positives >= MIN_POSITIVES,
        "dataset_dir": dataset_dir(project_dir),
    }


def dataset_dir(project_dir: str) -> str:
    """墨迹比对数据集目录（全局共享，任何书籍项目里都是同一路径）。"""
    return ts.global_layer_dir(LAYER)


def _confusable_map(charset: list[str], cache_path: str) -> dict[str, list]:
    """字形骨架两两 Chamfer 挖掘易混字（结果缓存，字形缓存由 char_verify
    全局持有）。只保留相似度 >= CONFUSE_SIM_MIN 的 top-k。"""
    if os.path.exists(cache_path):
        try:
            with open(cache_path, encoding="utf-8") as f:
                cached = json.load(f)
            if set(cached.keys()) == set(charset):
                return cached
        except Exception:
            pass
    feats = {}
    for ch in charset:
        glyph = char_verify._glyph_features(ch)
        if glyph is not None:
            feats[ch] = glyph[1]  # 骨架
    chars = sorted(feats)
    out: dict[str, list] = {ch: [] for ch in charset}
    for a in range(len(chars)):
        cha = chars[a]
        best = []
        for b in range(len(chars)):
            if a == b:
                continue
            s = char_verify._shape_score(feats[cha], feats[chars[b]])
            if CONFUSE_SIM_MIN <= s < CONFUSE_SIM_MAX:
                best.append((round(float(s), 4), chars[b]))
        best.sort(reverse=True)
        out[cha] = [c for _s, c in best[:CONFUSE_K]]
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)
    return out


def export_dataset(project_dir: str, force: bool = False) -> dict:
    """导出图对数据集（全局共享，按书合并进 datasets/_global/verify_pair）。

    [project_dir] 为单本书时只刷新该书自己的样本；为库根目录时刷新全部
    书籍。每本书的样本与统计存在独立数据块（_books/<书籍ID>.json），
    manifest.json 由全部数据块合并重建——任何一本书重新导出只替换自己
    的样本，其他书的贡献不动。

    墨迹/字形 canvas 与推理同管线：_crop_ink 净化 + _prepare（含按字形
    笔宽收细）的 128 画布二值图。"""
    ts._migrate_legacy_datasets()
    books = ts._book_dirs_under(project_dir)
    if not books:
        raise ValueError(f"没有找到书籍项目：{project_dir}")
    out_dir = dataset_dir(project_dir)
    chunks_dir = os.path.join(out_dir, "_books")
    os.makedirs(chunks_dir, exist_ok=True)
    manifest_path = os.path.join(out_dir, "manifest.json")

    all_cached = os.path.exists(manifest_path)
    for book_dir in books:
        bid = os.path.basename(os.path.normpath(book_dir))
        chunk_path = os.path.join(chunks_dir, f"{bid}.json")
        if not force and all_cached and os.path.exists(chunk_path):
            continue
        all_cached = False
        _export_book(book_dir, bid, out_dir, chunks_dir)
    stats = _rebuild_manifest(out_dir)
    if all_cached:
        stats = {"cached": True, **stats}
    return stats



def _export_book(book_dir: str, bid: str, out_dir: str, chunks_dir: str) -> dict:
    """导出单本书的图对样本（文件名 <书籍ID>_<页>_<序号>）并写数据块。"""
    pages, _ = ts._load_book_pages([book_dir])
    samples = list(_iter_confirmed_chars(pages))
    if not samples:
        raise ValueError(f"{bid} 没有确认单字（需要先在编辑器确认标注）")

    # 划分只对"会产生样本的页"做页级 train/val（与 char_cls 数据集同修复：
    # 对全部页划分时 val 键可能全落在不写入的页上）。
    writable_pages = sorted({pid for pid, *_ in samples})
    page_splits = _page_split(
        [{"page_id": p} for p in writable_pages], 0.8, 42)

    # 清掉本书旧样本（重新导出），其他书的样本不动
    prefix = bid + "_"
    for split in ("train", "val"):
        for sub in ("ink", "glyph"):
            d = os.path.join(out_dir, split, sub)
            if os.path.isdir(d):
                for name in os.listdir(d):
                    if name.startswith(prefix):
                        os.remove(os.path.join(d, name))
            os.makedirs(d, exist_ok=True)

    charset = sorted({t for _pid, _i, _r, t, _j in samples} |
                     {j for _pid, _i, _r, _t, j in samples if j})
    confuse = _confusable_map(charset, os.path.join(chunks_dir, f"{bid}_confuse.json"))

    stats = {"positives": 0, "rejected_negatives": 0,
             "confuse_negatives": 0}
    pairs = []
    mask_cache: dict[str, np.ndarray | None] = {}

    def ink_canvas(image_path, rect):
        if image_path not in mask_cache:
            mask_cache[image_path] = char_verify._text_mask_for_refinement(
                image_path)
        mask = mask_cache[image_path]
        if mask is None:
            return None
        ink, _reason = char_verify._crop_ink(mask, rect)
        if ink is None:
            return None
        return ink

    def write_pair(split, name, ink, text, neg_text, kind):
        glyph = char_verify._glyph_features(neg_text or text)
        if glyph is None:
            return False
        ink_prepared = char_verify._prepare(
            ink.copy(), target_w=glyph[4])
        glyph_prepared = glyph[0]
        for sub, arr in (("ink", ink_prepared), ("glyph", glyph_prepared)):
            path = os.path.join(out_dir, split, sub, f"{name}.png")
            imaging.imwrite_unicode(path, arr)
        pairs.append({
            "name": name, "split": split, "label": 1 if neg_text is None
            else 0, "kind": kind, "text": text,
            "neg": neg_text or "",
            "ink": f"{split}/ink/{name}.png",
            "glyph": f"{split}/glyph/{name}.png",
        })
        return True

    counts = {"train": 0, "val": 0}
    by_page = {str(ann.get("page_id") or "page"): ann for ann in pages}
    for pid, i, rect, text, rejected in samples:
        ann = by_page.get(pid)
        if ann is None:
            continue
        image_path = ann.get("image_path", "")
        if not image_path or not os.path.exists(image_path):
            continue
        ink = ink_canvas(image_path, rect)
        if ink is None:
            continue
        split = page_splits.get(pid, "train")
        base = f"{prefix}{pid}_{i}"
        if write_pair(split, base, ink, text, None, "pos"):
            stats["positives"] += 1
            counts[split] += 1
        if rejected:
            if write_pair(split, f"{base}_rej", ink, text, rejected, "rej"):
                stats["rejected_negatives"] += 1
                counts[split] += 1

    # 易混负样本：复用已写盘的墨迹（同 ink 不同字形），不重复抠图
    for pair in [p for p in pairs if p["kind"] == "pos"]:
        for k, neg in enumerate(confuse.get(pair["text"], [])[:CONFUSE_K]):
            if neg == pair["text"]:
                continue
            ink_path = os.path.join(out_dir, pair["ink"])
            ink = cv2.imdecode(
                np.fromfile(ink_path, dtype=np.uint8), cv2.IMREAD_GRAYSCALE)
            if ink is None:
                continue
            if write_pair(pair["split"], f"{pair['name']}_cf{k}", ink,
                          pair["text"], neg, "confuse"):
                stats["confuse_negatives"] += 1
                counts[pair["split"]] += 1

    stats["train_pairs"] = counts["train"]
    stats["val_pairs"] = counts["val"]
    stats["charset"] = len(charset)
    stats["charset_list"] = charset
    with open(os.path.join(chunks_dir, f"{bid}.json"), "w",
              encoding="utf-8") as f:
        json.dump({"generated_at": time.time(), "book_id": bid,
                   "pages": len(pages), "stats": stats,
                   "pairs": pairs, "confuse": confuse},
                  f, ensure_ascii=False, indent=1)
    return stats



def _rebuild_manifest(out_dir: str) -> dict:
    """合并全部书籍数据块，重建 manifest.json（siamese 训练的读取入口）。"""
    chunks = []
    chunks_dir = os.path.join(out_dir, "_books")
    if os.path.isdir(chunks_dir):
        for name in sorted(os.listdir(chunks_dir)):
            if not name.endswith(".json") or name.endswith("_confuse.json"):
                continue
            try:
                with open(os.path.join(chunks_dir, name), encoding="utf-8") as f:
                    chunks.append(json.load(f))
            except Exception as exc:
                _log(f"[verify] 跳过损坏的数据块 {name}: {exc}")
    pairs = [dict(p) for c in chunks for p in c.get("pairs", [])]
    train_pairs = [p for p in pairs if p.get("split") == "train"]
    val_pairs = [p for p in pairs if p.get("split") == "val"]
    if not pairs:
        raise ValueError("没有确认单字（需要先在编辑器确认标注）")
    if not val_pairs:
        # 兜底：全局 val 为空时复制一个 train 样本对过去（同图双份，指标
        # 略乐观，好过 siamese 训练拒绝启动）。
        donor = train_pairs[0]
        clone = dict(donor, split="val",
                     ink=f"val/ink/{os.path.basename(donor['ink'])}",
                     glyph=f"val/glyph/{os.path.basename(donor['glyph'])}")
        for sub in ("ink", "glyph"):
            src = os.path.join(out_dir, donor[sub])
            dst = os.path.join(out_dir, clone[sub])
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
        pairs.append(clone)
        val_pairs = [clone]
    stats = {
        "positives": sum((c.get("stats") or {}).get("positives", 0) for c in chunks),
        "rejected_negatives": sum((c.get("stats") or {}).get("rejected_negatives", 0) for c in chunks),
        "confuse_negatives": sum((c.get("stats") or {}).get("confuse_negatives", 0) for c in chunks),
        "charset": len({ch for c in chunks
                        for ch in (c.get("stats") or {}).get("charset_list", [])}),
        "train_pairs": len(train_pairs),
        "val_pairs": len(val_pairs),
    }
    confuse: dict = {}
    for c in chunks:
        confuse.update(c.get("confuse") or {})
    with open(os.path.join(out_dir, "manifest.json"), "w",
              encoding="utf-8") as f:
        json.dump({"schema_version": 1, "canvas": char_verify.CANVAS,
                   "stats": stats, "pairs": pairs, "confuse": confuse},
                  f, ensure_ascii=False, indent=1)
    return stats



def _migrate_legacy_layer(src_dir: str, pid: str) -> None:
    """旧版按书 verify_pair 数据集（datasets/<pid>/verify_pair）合并进全局
    目录：图对文件加 <pid>_ 前缀，manifest 转为按书数据块后重建总表。
    由 train_datasets._migrate_legacy_book 调用。"""
    out_dir = dataset_dir("")
    prefix = pid + "_"
    for split in ("train", "val"):
        for sub in ("ink", "glyph"):
            src = os.path.join(src_dir, split, sub)
            if not os.path.isdir(src):
                continue
            os.makedirs(os.path.join(out_dir, split, sub), exist_ok=True)
            for name in os.listdir(src):
                if name.startswith(prefix):
                    continue  # 幂等：此前迁移过
                shutil.copyfile(os.path.join(src, name),
                                os.path.join(out_dir, split, sub, f"{prefix}{name}"))
    old_manifest = os.path.join(src_dir, "manifest.json")
    if os.path.exists(old_manifest):
        try:
            with open(old_manifest, encoding="utf-8") as f:
                doc = json.load(f)

            def _prefixed(rel: str) -> str:
                head, _, fname = (rel or "").rpartition("/")
                return f"{head}/{prefix}{fname}" if head else prefix + fname

            pairs = []
            for p in doc.get("pairs", []):
                q = dict(p)
                q["name"] = prefix + (p.get("name") or "")
                q["ink"] = _prefixed(p.get("ink"))
                q["glyph"] = _prefixed(p.get("glyph"))
                pairs.append(q)
            charset = sorted({p.get("text", "") for p in pairs if p.get("text")} |
                             {p.get("neg", "") for p in pairs if p.get("neg")})
            stats = dict(doc.get("stats") or {})
            stats["charset"] = len(charset)
            stats["charset_list"] = charset
            chunks_dir = os.path.join(out_dir, "_books")
            os.makedirs(chunks_dir, exist_ok=True)
            with open(os.path.join(chunks_dir, f"{pid}.json"), "w",
                      encoding="utf-8") as f:
                json.dump({"generated_at": time.time(), "book_id": pid,
                           "stats": stats, "pairs": pairs,
                           "confuse": doc.get("confuse") or {}},
                          f, ensure_ascii=False)
        except Exception as exc:
            _log(f"[migrate] {pid}/verify_pair manifest 迁移失败: {exc}")
    _rebuild_manifest(out_dir)


# --- 训练任务管理（仿 kraken_training：子进程 + 2s 监视线程） --------------

_TASKS: dict[str, dict] = {}
_TASK_LOCK = threading.Lock()
_TASK_COUNTER = 0


def _log(message: str) -> None:
    print(f"[verify-train] {message}", flush=True)


def start_training(data_path: str, epochs: int = DEFAULT_EPOCHS,
                   device: str = "auto") -> dict:
    """启动训练子进程（train_worker --task siamese），返回任务信息。"""
    global _TASK_COUNTER
    if not os.path.isdir(data_path):
        raise ValueError(f"数据集不存在，请先导出：{data_path}")
    with _TASK_LOCK:
        running = [t for t in _TASKS.values()
                   if t["status"] in ("starting", "training")]
        if running:
            raise RuntimeError(
                f"已有比对模型训练任务在进行中: {running[0]['id']}")
        _TASK_COUNTER += 1
        task_id = f"verify_{int(time.time())}_{_TASK_COUNTER}"
        stamp = time.strftime("%Y%m%d_%H%M%S")
        run_dir = os.path.join(trained_root_dir(), LAYER, f"run_{stamp}")
        suffix = 2
        while os.path.exists(run_dir):
            run_dir = os.path.join(trained_root_dir(), LAYER,
                                   f"run_{stamp}_{suffix}")
            suffix += 1
        os.makedirs(run_dir, exist_ok=True)
        task = {"id": task_id, "layer": LAYER, "epochs": int(epochs),
                "run_dir": run_dir, "data_path": data_path,
                "device": device, "status": "starting", "progress": 0.0,
                "started": time.time(), "proc": None, "log_tail": []}
        _TASKS[task_id] = task
    cmd = [sys.executable, WORKER_PATH, "--task", "siamese",
           "--data", data_path, "--base", "none", "--epochs", str(epochs),
           "--imgsz", "128", "--batch", "64", "--device", device,
           "--run-dir", run_dir]
    log_file = open(os.path.join(run_dir, "train_log.txt"), "w",
                    encoding="utf-8")
    _log(f"start: {' '.join(cmd)}")
    task["proc"] = subprocess.Popen(cmd, stdout=log_file,
                                    stderr=subprocess.STDOUT,
                                    cwd=os.path.dirname(WORKER_PATH))
    log_file.close()
    threading.Thread(target=_monitor, args=(task,), daemon=True).start()
    return _task_dict(task)


def _csv_progress(run_dir: str, epochs: int) -> float:
    try:
        with open(os.path.join(run_dir, "results.csv"), encoding="utf-8") as f:
            done = max(0, sum(1 for _ in f) - 1)
        return round(min(1.0, done / max(1, epochs)), 4)
    except Exception:
        return 0.0


def _read_done(run_dir: str) -> dict | None:
    try:
        with open(os.path.join(run_dir, "done.json"), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _tail(run_dir: str, n: int = 30) -> list[str]:
    try:
        with open(os.path.join(run_dir, "train_log.txt"), encoding="utf-8",
                  errors="replace") as f:
            return f.read().splitlines()[-n:]
    except Exception:
        return []


def _task_dict(task: dict) -> dict:
    return {k: v for k, v in task.items() if k != "proc"}


def _monitor(task: dict) -> None:
    proc = task["proc"]
    while proc.poll() is None:
        task["progress"] = _csv_progress(task["run_dir"], task["epochs"])
        task["log_tail"] = _tail(task["run_dir"])
        time.sleep(2)
    done = _read_done(task["run_dir"])
    if done and done.get("best") and os.path.exists(done["best"]):
        task["status"] = "done"
        task["progress"] = 1.0
        _register_run(task, done)
    else:
        task["status"] = "failed"
    task["log_tail"] = _tail(task["run_dir"])
    _log(f"task {task['id']} -> {task['status']}")


def _register_run(task: dict, done: dict) -> None:
    with _TASK_LOCK:
        reg = _load_registry()
        layer = reg["layers"].setdefault(LAYER, {"active": None, "runs": []})
        layer["runs"] = (layer.get("runs") or [])[-9:] + [{
            "run_dir": task["run_dir"], "best": done["best"],
            "metrics": done.get("metrics") or {},
            "epochs": done.get("epochs") or task["epochs"],
            "base_model": "siamese-pair-v1", "started": task["started"]}]
        _save_registry(reg)


def _load_registry() -> dict:
    return registry_io.load_registry(REGISTRY_PATH)


def _save_registry(reg: dict) -> None:
    registry_io.save_registry(reg, REGISTRY_PATH)


def training_status() -> list[dict]:
    with _TASK_LOCK:
        return [_task_dict(t) for t in _TASKS.values()]


def stop_training(task_id: str) -> dict:
    with _TASK_LOCK:
        task = _TASKS.get(task_id)
    if task is None:
        raise ValueError(f"no such task: {task_id}")
    task["status"] = "stopped"
    if task["proc"] and task["proc"].poll() is None:
        task["proc"].terminate()
    return _task_dict(task)


def list_models() -> dict:
    reg = _load_registry()
    layer = reg["layers"].get(LAYER) or {"active": None, "runs": []}
    active = layer.get("active")
    return {
        "active": active,
        "active_exists": bool(active and os.path.exists(active)),
        "active_metrics": layer.get("active_metrics") or {},
        "runs": (layer.get("runs") or [])[-10:],
    }


def activate_model(run_dir: str | None = None) -> dict:
    """激活：优先给定 run 的 best.pt，否则最新一次完成训练的；复制到
    models/active_verify_pair.pt 并写注册表。char_verify 按路径惰性加载，
    无需重启后端。"""
    reg = _load_registry()
    layer = reg["layers"].setdefault(LAYER, {"active": None, "runs": []})
    best = None
    if run_dir:
        best = os.path.join(run_dir, "best.pt")
    else:
        for run in reversed(layer.get("runs") or []):
            if os.path.exists(run.get("best") or ""):
                best = run["best"]
                break
    if not best or not os.path.exists(best):
        raise ValueError("没有可激活的模型（先完成一次训练）")
    shutil.copyfile(best, ACTIVE_PATH)
    layer["active"] = ACTIVE_PATH
    for run in layer.get("runs") or []:
        if os.path.abspath(run.get("best") or "") == os.path.abspath(best):
            layer["active_metrics"] = run.get("metrics") or {}
    layer["active_since"] = time.time()
    _save_registry(reg)
    _log(f"activated {best} -> {ACTIVE_PATH}")
    return list_models()


def deactivate_model() -> dict:
    reg = _load_registry()
    layer = reg["layers"].setdefault(LAYER, {"active": None, "runs": []})
    layer["active"] = None
    layer["active_metrics"] = {}
    _save_registry(reg)
    if os.path.exists(ACTIVE_PATH):
        os.remove(ACTIVE_PATH)
    return list_models()
