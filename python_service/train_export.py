# -*- coding: utf-8 -*-
"""页级增量数据集导出（/train/export 的实现）。

设计要点：
- **manifest 是对外账本**（<dataset_root>/manifest.json，与数据同住、随
  数据集文件夹跨机迁移）：记录每书每层已导出的页、每页样本数与内容
  摘要（digest）。书籍任务从书库删除不影响 manifest 与已导出样本——
  统计口径 = 已导出数据。
- **增量语义**：只写新增/内容有变化的页（同文件名覆盖重写）；**确认被
  撤销/标注清空（该页不再产出任何样本）的页在每次导出时清理**——样本
  文件删除、manifest 记账回退，统计随之下降；不在书库里的书、书里已
  不存在的页完全不碰（"不影响旧数据"）。
  [force]=True 时重写书库内全部有效页（仍不碰书库外的书）。
- **region_det 全量导出**：凡有已确认版面区（box_confirmed，任意类别——
  主区快设「确认并下一页」/编辑器确认/预标注后人工确认）的页全部进入
  region_det，与整本识别是否完成解耦（版面区是纯几何成果）；页级增量
  + digest 保证只写新增/变化的页。历史上曾是"识别完成的书一次性抽 8
  页"（同书页眉页脚高度重复、抽样求稳），按用户口径改为全量——已导出
  的旧样本不动，此前被抽样挡掉的页在下次导出自动补齐。
- 标签语义与按书整写（train_datasets._write_layer_for_book）共用
  page_labels / char_cls_page_items，行为永不漂移。
"""
from __future__ import annotations

import hashlib
import json
import os
import random
import threading
from typing import Any

import train_manifest as tm
from train_data import (LAYER_INFO, LAYERS, _image_size, _load_book_pages,
                        _book_dirs_under, library_root_of,
                        global_layer_dir, _log)
from train_datasets import (_finalize_char_cls_dataset, _finalize_detect_dataset,
                            _write_detect_dataset, char_cls_page_items,
                            page_labels, write_char_cls_crop, _imread,
                            purge_char_cls_page_files, write_detect_image)
import train_datasets


def _stable_split(page_id: str, ratio: float, seed: int) -> str:
    """页级稳定 train/val 划分：同一页永远落同一集合（按书整写时的
    _page_split 随页集合变化，增量导出必须页级稳定）。"""
    rng = random.Random(f"{seed}:{page_id}")
    return "train" if rng.random() < ratio else "val"


def _digest(payload: Any) -> str:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True,
                         separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()[:16]


def _page_id(ann: dict) -> str:
    return str(ann.get("page_id") or ann.get("id") or "page")


def _book_pages_entry(manifest: dict, book_id: str, layer: str) -> dict:
    entry = manifest["books"].setdefault(
        book_id, {"exported_at": 0.0, "layers": {}})
    return entry["layers"].setdefault(layer, {"pages": {}})


def _region_page_ids(pages: list[dict]) -> set[str]:
    """region_det 本次可导的页集合（train_manifest.region_eligible_pages
    的全量口径，export 与 scan_pending 共用同一裁决，永不漂移）。"""
    return set(tm.region_eligible_pages(pages))


# 导出互斥：确认后的自动增量导出（TrainExportScheduler，防抖触发）与
# 训练页打开时的自动导出/手动导出可能并发——manifest 是读改写账本，并发
# 会互相丢更新。第二次调用阻塞排队，digest 比对后通常只是空转一次。
_EXPORT_LOCK = threading.Lock()


def export_datasets(project_dir: str, layers: list[str] | None = None,
                    force: bool = False, train_ratio: float = 0.8,
                    seed: int = 42) -> dict[str, Any]:
    """增量导出书库标注到统一数据集目录，返回本次导出报告。"""
    with _EXPORT_LOCK:
        return _export_datasets_locked(project_dir, layers, force,
                                       train_ratio, seed)


def _export_datasets_locked(project_dir: str, layers: list[str] | None,
                            force: bool, train_ratio: float,
                            seed: int) -> dict[str, Any]:
    train_datasets._migrate_legacy_datasets()
    books = _book_dirs_under(project_dir)

    def _noop_report(reason: str) -> dict:
        manifest = tm.ensure_manifest_baseline()
        return {
            "schema_version": tm.MANIFEST_SCHEMA_VERSION,
            "dataset_root": os.path.dirname(tm.manifest_path()),
            "manifest_path": tm.manifest_path(),
            "books": [],
            "reason": reason,
            "layers": {
                layer: {"new_pages": 0, "updated_pages": 0, "pruned_pages": 0,
                        "written": False,
                        "manifest": layer_totals(manifest, layer)}
                for layer in (layers or [])
            },
        }

    if not books:
        # 书库为空（书已全删/路径无效）：不导出也不报错——训练页的自动
        # 增量导出会反复调用，已导出数据与统计保持现状。
        return _noop_report("no_books")

    book_data: dict[str, tuple[str, list[dict], dict[int, str]]] = {}
    total_pages = 0
    for book_dir in books:
        pages, h_by_page = _load_book_pages([book_dir])
        bid = os.path.basename(os.path.normpath(book_dir))
        book_data[bid] = (book_dir, pages, h_by_page)
        total_pages += len(pages)
    if not total_pages:
        return _noop_report("no_annotations")

    manifest = tm.ensure_manifest_baseline()
    layers = [l for l in (layers or LAYERS) if l in LAYER_INFO]
    report: dict[str, Any] = {
        "schema_version": tm.MANIFEST_SCHEMA_VERSION,
        "dataset_root": os.path.dirname(tm.manifest_path()),
        "manifest_path": tm.manifest_path(),
        "books": sorted(book_data),
        "layers": {},
    }

    for layer in layers:
        out_dir = global_layer_dir(layer)
        os.makedirs(out_dir, exist_ok=True)
        layer_report = {"new_pages": 0, "updated_pages": 0, "pruned_pages": 0,
                        "written": False}
        for bid, (book_dir, pages, h_by_page) in book_data.items():
            pages_entry = _book_pages_entry(manifest, bid, layer)
            exported_pages = pages_entry.setdefault("pages", {})

            allowed: set[str] | None = None
            if layer == "region_det":
                allowed = _region_page_ids(pages)

            # 清理：manifest 已登记、但该页标注已不再产出样本的页（确认
            # 被撤销——「改回未保存」/取消确认后 box_confirmed 全清）。删
            # 样本文件 + 回退记账，训练统计随之下降；书里已不存在的页
            # （跨页拆分/删页）与书库外的书仍保留旧数据不动。
            pruned = _prune_stale_pages(layer, out_dir, bid, pages,
                                        exported_pages, allowed, h_by_page)
            if pruned:
                layer_report["pruned_pages"] += pruned
                layer_report["written"] = True  # 触发收尾（labels.cache 等）
                book_touched = True

            if layer == "region_det" and not allowed:
                continue  # 本书没有任何已确认版面区：不导 region_det

            book_touched = False
            for ann in pages:
                pid = _page_id(ann)
                if layer == "region_det" and pid not in allowed:
                    continue
                if layer == "char_cls":
                    items = char_cls_page_items(ann)
                    if not items:
                        continue
                    payload = [[i["x"], i["y"], i["w"], i["h"], i["text"]]
                               for i in items]
                    digest = _digest(payload)
                    old = exported_pages.get(pid)
                    if old and old.get("d") == digest and not force:
                        continue
                    image_path = ann.get("image_path", "")
                    if not image_path or not os.path.exists(image_path):
                        continue
                    img = _imread(image_path)
                    if img is None:
                        continue
                    split = _stable_split(pid, train_ratio, seed)
                    # 重写该页前清掉旧样本：换 JPG 格式与行内序号变化
                    # 都会留旧文件，不清会让同页样本翻倍/错位。
                    purge_char_cls_page_files(out_dir, bid, pid)
                    written = 0
                    for item in items:
                        result = write_char_cls_crop(
                            img, item, out_dir, split, bid, pid)
                        if result is not None:
                            written += 1
                    if written:
                        per_label: dict[str, int] = {}
                        for item in items:
                            per_label[item["text"]] = per_label.get(
                                item["text"], 0) + 1
                        exported_pages[pid] = {"n": written, "d": digest,
                                               "c": per_label}
                        _bump(exported_pages, old, layer_report, pid,
                              pages_entry)
                        book_touched = True
                    continue

                # detect 层
                labels = page_labels(layer, ann, h_by_page.get(id(ann), "ltr"))
                if not labels:
                    continue  # 无有效标注（已登记旧页由 _prune_stale_pages 清理）
                digest = _digest([list(t) for t in labels])
                old = exported_pages.get(pid)
                if old and old.get("d") == digest and not force:
                    continue
                image_path = ann.get("image_path") or ""
                if not image_path or not os.path.exists(image_path):
                    continue
                size = _image_size(image_path)
                if not size:
                    continue
                img_w, img_h = size
                _write_detect_page(out_dir, layer, ann, labels, bid, pid,
                                   _stable_split(pid, train_ratio, seed),
                                   img_w, img_h)
                if layer == "region_det":
                    names = LAYER_INFO[layer]["names"]
                    per_label = {}
                    for _, _, _, _, cls in labels:
                        if 0 <= cls < len(names):
                            name = names[cls]
                            per_label[name] = per_label.get(name, 0) + 1
                    exported_pages[pid] = {"n": len(labels), "d": digest,
                                           "c": per_label}
                else:
                    exported_pages[pid] = {"n": len(labels), "d": digest}
                _bump(exported_pages, old, layer_report, pid, pages_entry)
                book_touched = True

            if book_touched:
                entry = manifest["books"][bid]
                entry["exported_at"] = entry.get("exported_at") or _now()
                entry.pop("baseline", None)
                if layer == "char_cls":
                    _rewrite_char_cls_metadata(
                        out_dir, bid, pages, exported_pages,
                        train_ratio, seed)

        if layer_report["written"]:
            try:
                if layer == "char_cls":
                    _finalize_char_cls_dataset(out_dir)
                else:
                    _finalize_detect_dataset(out_dir)
            except ValueError as exc:
                # 页级增量的早期可能只有 1 个有效页（val 兜底要求 ≥2）：
                # 样本已安全落盘，收尾失败只记日志，下次导出补页后自然成集。
                _log(f"[export] {layer} 收尾暂缓：{exc}")
        layer_report["manifest"] = layer_totals(manifest, layer)
        report["layers"][layer] = layer_report

    tm.save_manifest(manifest)
    return report


def _now() -> float:
    import time

    return time.time()


def _bump(exported_pages: dict, old: dict | None, layer_report: dict,
          pid: str, pages_entry: dict) -> None:
    """更新本次报告的新增/变更计数（写盘成功后调用）。"""
    if old is None:
        layer_report["new_pages"] += 1
    else:
        layer_report["updated_pages"] += 1
    layer_report["written"] = True


def _purge_detect_page_files(out_dir: str, book_id: str, page_id: str) -> None:
    """删除某页在 detect 层数据集里的样本（图片+标签，train/val 双侧）。

    detect 层是 `<book>_<page>` 命名的扁平文件（标签覆盖写、图片由
    write_detect_image 管理扩展名），重写路径靠覆盖自洽，但"这页不再导
    出"时没有覆盖者——必须显式删除，否则统计回退后样本文件变成孤儿。
    """
    base = f"{book_id}_{page_id}"
    deletable_exts = {".jpg"} | set(train_datasets._STALE_IMAGE_EXTS)
    for split in ("train", "val"):
        lbl = os.path.join(out_dir, split, "labels", base + ".txt")
        if os.path.exists(lbl):
            os.remove(lbl)
        img_dir = os.path.join(out_dir, split, "images")
        if not os.path.isdir(img_dir):
            continue
        for name in os.listdir(img_dir):
            stem, ext = os.path.splitext(name)
            if stem == base and ext.lower() in deletable_exts:
                os.remove(os.path.join(img_dir, name))


def _prune_stale_pages(layer: str, out_dir: str, book_id: str,
                       pages: list[dict], exported_pages: dict,
                       region_allowed: "set[str] | None",
                       h_by_page: dict[int, str]) -> int:
    """manifest 已登记、但该页标注已不再产出样本的页：删文件+回退记账。

    判定与写入路径共用同一套标签语义（page_labels / char_cls_page_items /
    region_eligible_pages），永不漂移。返回清理页数（0 = 无事发生）。
    页已不在本书页清单（跨页拆分/删页）的保留不动——与"删书不影响
    已导出数据"的宽容口径一致。
    """
    if not exported_pages:
        return 0
    current = {_page_id(ann): ann for ann in pages}
    stale: list[str] = []
    for pid in exported_pages:
        ann = current.get(pid)
        if ann is None:
            continue
        if layer == "region_det":
            if pid not in (region_allowed or set()):
                stale.append(pid)
        elif layer == "char_cls":
            if not char_cls_page_items(ann):
                stale.append(pid)
        else:
            if not page_labels(layer, ann, h_by_page.get(id(ann), "ltr")):
                stale.append(pid)
    for pid in stale:
        if layer == "char_cls":
            purge_char_cls_page_files(out_dir, book_id, pid)
        else:
            _purge_detect_page_files(out_dir, book_id, pid)
        exported_pages.pop(pid, None)
        _log(f"[export] {layer} 清理 {book_id}/{pid}"
             "（标注已不再产出样本：样本删除、统计回退）")
    return len(stale)


def _write_detect_page(out_dir: str, layer: str, ann: dict, labels: list,
                       book_id: str, page_id: str, split: str,
                       img_w: int, img_h: int) -> None:
    """写单页的图片+标签文件（文件名与按书整写一致，覆盖即重写）。

    图片经 write_detect_image 统一处理：过长边降采样 + JPG（q95），
    同页其他扩展名旧文件一并清理。
    """
    image_path = ann.get("image_path", "")
    base = f"{book_id}_{page_id}"
    lbl_out = os.path.join(out_dir, split, "labels", base + ".txt")
    os.makedirs(os.path.dirname(lbl_out), exist_ok=True)
    write_detect_image(image_path,
                       os.path.join(out_dir, split, "images"), base)
    lines = []
    names = LAYER_INFO[layer]["names"]
    for x, y, w, h, cls in labels:
        if not isinstance(cls, int) or not (0 <= cls < len(names)):
            continue
        cx = (x + w / 2) / img_w
        cy = (y + h / 2) / img_h
        nw = w / img_w
        nh = h / img_h
        if not (0 < cx < 1 and 0 < cy < 1 and 0 < nw <= 1 and 0 < nh <= 1):
            continue
        lines.append(f"{cls} {cx:.6f} {cy:.6f} {nw:.6f} {nh:.6f}")
    if not lines:
        return
    with open(lbl_out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def layer_totals(manifest: dict, layer: str) -> dict:
    """manifest 口径的该层累计统计（实例/页数/每类分布）。"""
    instances = 0
    page_count = 0
    per_class: dict[str, int] = {}
    for entry in manifest.get("books", {}).values():
        layer_entry = (entry.get("layers") or {}).get(layer) or {}
        pages = layer_entry.get("pages") or {}
        page_count += len(pages)
        for p in pages.values():
            instances += int(p.get("n") or 0)
            for label, n in (p.get("c") or {}).items():
                per_class[label] = per_class.get(label, 0) + int(n)
        # 兼容 baseline 条目（无 pages 明细，只有整书统计）
        if not pages:
            instances += int(layer_entry.get("train_instances") or 0)
            instances += int(layer_entry.get("val_instances") or 0)
            page_count += int(layer_entry.get("train_pages") or 0)
            page_count += int(layer_entry.get("val_pages") or 0)
            for label, n in (layer_entry.get("per_class") or {}).items():
                per_class[label] = per_class.get(label, 0) + int(n)
    return {"instances": instances, "pages": page_count, "per_class": per_class}


def scan_pending(project_dir: str, layers: list[str] | None = None,
                 train_ratio: float = 0.8, seed: int = 42) -> dict[str, Any]:
    """只读扫描：书库中还有多少"已确认但未导出/已变化"的页（不写盘）。

    训练页打开时的自动检查用它判断是否需要增量导出（pending>0 → 自动
    导出），也作为徽标数据源。
    """
    train_datasets._migrate_legacy_datasets()
    books = _book_dirs_under(project_dir)
    manifest = tm.ensure_manifest_baseline()
    layers = [l for l in (layers or LAYERS) if l in LAYER_INFO]
    pending: dict[str, Any] = {layer: {"pages": 0, "books": 0} for layer in layers}
    for book_dir in books:
        pages, h_by_page = _load_book_pages([book_dir])
        if not pages:
            continue
        bid = os.path.basename(os.path.normpath(book_dir))
        book_pending: set[str] = set()
        for layer in layers:
            layer_entry = ((manifest.get("books", {}).get(bid) or {})
                           .get("layers") or {}).get(layer) or {}
            exported_pages = layer_entry.get("pages") or {}
            if layer == "region_det":
                allowed = _region_page_ids(pages)
                if not allowed:
                    continue
            for ann in pages:
                pid = _page_id(ann)
                if layer == "region_det" and pid not in allowed:
                    continue
                if layer == "char_cls":
                    items = char_cls_page_items(ann)
                    if not items:
                        continue
                    payload = [[i["x"], i["y"], i["w"], i["h"], i["text"]]
                               for i in items]
                    digest = _digest(payload)
                else:
                    labels = page_labels(
                        layer, ann, h_by_page.get(id(ann), "ltr"))
                    if not labels:
                        continue
                    digest = _digest([list(t) for t in labels])
                old = exported_pages.get(pid)
                if old and old.get("d") == digest:
                    continue
                pending[layer]["pages"] += 1
                book_pending.add(layer)
        for layer in book_pending:
            pending[layer]["books"] += 1
    return {"pending": pending}


def _rewrite_char_cls_metadata(out_dir: str, book_id: str, pages: list[dict],
                               exported_pages: dict, train_ratio: float,
                               seed: int) -> None:
    """重写 metadata_<书>.json：该书全部已导出页的样本清单（增量页与旧页
    统一入账；路径规则与 write_char_cls_crop 完全一致，不重复裁剪写盘）。"""
    from train_data import DATASET_SCHEMA_VERSION
    from train_datasets import _safe_class_name

    samples = []
    for ann in pages:
        pid = _page_id(ann)
        if pid not in exported_pages:
            continue
        split = _stable_split(pid, train_ratio, seed)
        for item in char_cls_page_items(ann):
            base_name = f"{book_id}_{pid}_{item['line_id']}_{item['index']}"
            rel = f"{split}/{_safe_class_name(item['text'])}/{base_name}.jpg"
            samples.append({
                "path": rel,
                "label": item["text"],
                "page_id": pid,
                "book_id": book_id,
                "line_id": item["line_id"],
                "source_uid": item["source_uid"],
                "bbox": [item["x"], item["y"], item["w"], item["h"]],
                "status": "confirmed",
            })
    with open(os.path.join(out_dir, f"metadata_{book_id}.json"), "w",
              encoding="utf-8") as f:
        json.dump({"schema_version": DATASET_SCHEMA_VERSION,
                   "book_id": book_id, "samples": samples},
                  f, ensure_ascii=False, indent=2)
