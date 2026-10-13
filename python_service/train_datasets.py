# -*- coding: utf-8 -*-
"""训练数据集生成（从 training_service 拆出）：detect/char_cls 写盘、
generate_datasets、数据集统计与目录定位。training_service.py 仍为门面。

数据集是全局共享资产：所有书籍的样本合并写入 datasets/_global/<layer>/，
样本文件名带 <书籍ID>_ 前缀区分归属；对某本书重新生成只替换该书自己的
文件，其他书的贡献原样保留。模型产物与注册表（models/）本就是全局的，
数据集与其对齐——在任何书籍项目里看到的都是同一份训练数据。
旧版按书目录（datasets/<书籍ID>/）在首次访问时自动迁移进全局目录
（原目录移入 datasets/_legacy/ 保留备份）。
"""
import json
import os
import shutil
import threading
import time
from typing import Any
import cv2

import registry_io
import train_data
from train_data import (LAYER_INFO, LAYERS,
    DATASET_SCHEMA_VERSION, _log, _imread,
    _image_size, _infer_vertical_paragraphs, _book_dirs_under, all_book_dirs,
    library_root_of, global_layer_dir,
    _load_book, _load_book_pages, _is_confirmed,
    _box_confirmed, _page_confirmed, _page_split, _training_readiness)
from train_registry import _load_registry, _run_base_tier

# 首次访问时的旧目录迁移只做一次（进程内）。
_MIGRATE_LOCK = threading.Lock()
_MIGRATED = False



def _meta_path() -> str:
    return os.path.join(train_data.global_root(), "_meta.json")



def _load_meta() -> dict:
    """全局数据集元数据：books.<书籍ID>.layers.<layer> = 该书该层的生成统计。"""
    meta: dict = {}
    try:
        with open(_meta_path(), encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded.get("books"), dict):
            meta = loaded
    except Exception:
        meta = {}
    meta.setdefault("schema_version", 3)
    meta.setdefault("books", {})
    return meta



def _save_meta(meta: dict) -> None:
    registry_io.save_registry(meta, _meta_path())



def _purge_book_files(out_dir: str, book_id: str, layer: str) -> None:
    """删除某本书在全局数据集里的旧样本（重新生成前调用）。

    只删 <书籍ID>_ 前缀的文件，其他书的样本不动。char_cls 清理后顺手
    删掉空类目录：目录式分类数据集的类名即目录名，空类会让分类器学到
    一个没有任何样本的类。
    """
    prefix = book_id + "_"
    if layer == "char_cls":
        for split in ("train", "val"):
            split_dir = os.path.join(out_dir, split)
            if not os.path.isdir(split_dir):
                continue
            for cls_name in os.listdir(split_dir):
                cls_dir = os.path.join(split_dir, cls_name)
                if not os.path.isdir(cls_dir):
                    continue
                for name in os.listdir(cls_dir):
                    if name.startswith(prefix):
                        os.remove(os.path.join(cls_dir, name))
                if not os.listdir(cls_dir):
                    shutil.rmtree(cls_dir)
        return
    # detect 层：train|val 下 images/labels 平铺
    for split in ("train", "val"):
        for kind in ("images", "labels"):
            d = os.path.join(out_dir, split, kind)
            if not os.path.isdir(d):
                continue
            for name in os.listdir(d):
                if name.startswith(prefix):
                    os.remove(os.path.join(d, name))



def _dataset_ready(out_dir: str, layer: str) -> bool:
    """该层全局数据集是否可直接用于训练。"""
    if layer == "char_cls":
        return os.path.isdir(os.path.join(out_dir, "train"))
    return os.path.exists(os.path.join(out_dir, "data.yaml"))


# 导出素材处理：训练/推理都在 imgsz=1280 尺度进行，超长边素材入库前先
# 降到 MAX_EXPORT_SIDE（YOLO 标注是归一化坐标，缩放不影响标签），
# 统一存 JPG（q95）压磁盘；已是合规尺寸的 JPG 原文件直接复用，避免
# 二次有损压缩。
MAX_EXPORT_SIDE = 2560
EXPORT_JPEG_QUALITY = 95
_STALE_IMAGE_EXTS = (".png", ".jpeg", ".bmp", ".tif", ".tiff", ".webp")


def write_detect_image(image_path: str, images_dir: str, base: str) -> None:
    """检测层页面素材入库：过大降采样 + 统一 JPG（q95）。

    同 base 重写时先清掉其他扩展名的旧文件（从 PNG 时代换格式后不清
    会让同一页双样本）；解码失败退回原样拷贝（保留源扩展名，训练侧
    自行容错）。
    """
    os.makedirs(images_dir, exist_ok=True)
    for ext in _STALE_IMAGE_EXTS:
        stale = os.path.join(images_dir, base + ext)
        if os.path.exists(stale):
            os.remove(stale)
    img_out = os.path.join(images_dir, base + ".jpg")
    size = _image_size(image_path)
    src_ext = os.path.splitext(image_path)[1].lower()
    if (size and src_ext in (".jpg", ".jpeg")
            and max(size) <= MAX_EXPORT_SIDE):
        shutil.copyfile(image_path, img_out)
        return
    img = _imread(image_path)
    if img is None:
        shutil.copyfile(
            image_path, os.path.join(images_dir, base + (src_ext or ".png")))
        return
    h, w = img.shape[:2]
    if max(h, w) > MAX_EXPORT_SIDE:
        scale = MAX_EXPORT_SIDE / max(h, w)
        img = cv2.resize(
            img, (max(1, round(w * scale)), max(1, round(h * scale))),
            interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(
        ".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), EXPORT_JPEG_QUALITY])
    if not ok:
        shutil.copyfile(image_path, img_out)
        return
    buf.tofile(img_out)


def purge_char_cls_page_files(out_dir: str, book_id: str,
                              page_id: str) -> None:
    """删除某页在分类数据集里的旧样本（重写该页前调用）。

    类目录式布局按 `<书>_<页>_` 前缀跨 train/val、全类目录清理：换 JPG
    格式重写、行内序号变化都会留旧文件，不清会让同页样本翻倍/错位。
    """
    prefix = f"{book_id}_{page_id}_"
    for split in ("train", "val"):
        split_dir = os.path.join(out_dir, split)
        if not os.path.isdir(split_dir):
            continue
        for cls_name in os.listdir(split_dir):
            cls_dir = os.path.join(split_dir, cls_name)
            if not os.path.isdir(cls_dir):
                continue
            for name in os.listdir(cls_dir):
                if name.startswith(prefix):
                    os.remove(os.path.join(cls_dir, name))



def _write_detect_dataset(
    pages: list[dict],
    out_dir: str,
    label_fn,
    class_names: list[str],
    train_ratio: float,
    seed: int,
    book_id: str,
) -> dict:
    """detect 层按书写盘：样本文件名 <书籍ID>_<页ID>，只写本书的样本。"""
    page_splits = _page_split(pages, train_ratio, seed)
    subdirs = [
        os.path.join(out_dir, split, kind)
        for split in ("train", "val")
        for kind in ("images", "labels")
    ]
    for d in subdirs:
        os.makedirs(d, exist_ok=True)

    train_pages = val_pages = train_inst = val_inst = 0
    skipped = {"unconfirmed_page": 0, "missing_image": 0, "invalid_box": 0,
               "unknown_class": 0, "empty": 0}
    for ann in pages:
        if not _page_confirmed(ann):
            skipped["unconfirmed_page"] += 1
            continue
        image_path = ann.get("image_path", "")
        if not image_path or not os.path.exists(image_path):
            skipped["missing_image"] += 1
            continue
        size = _image_size(image_path)
        if not size:
            continue
        img_w, img_h = size
        labels = []
        for x, y, w, h, cls in label_fn(ann):
            if not isinstance(cls, int) or not (0 <= cls < len(class_names)):
                # 类别 id 越界（如 label 不在当前词表）：写盘会让 ultralytics
                # 训练直接失败，跳过并计数让统计可见。
                skipped["unknown_class"] += 1
                continue
            if w <= 0 or h <= 0:
                skipped["invalid_box"] += 1
                continue
            cx = (x + w / 2) / img_w
            cy = (y + h / 2) / img_h
            nw = w / img_w
            nh = h / img_h
            if not (0 < cx < 1 and 0 < cy < 1 and 0 < nw <= 1 and 0 < nh <= 1):
                skipped["invalid_box"] += 1
                continue
            labels.append(f"{cls} {cx:.6f} {cy:.6f} {nw:.6f} {nh:.6f}")
        if not labels:
            skipped["empty"] += 1
            continue
        page_id = str(ann.get("page_id") or ann.get("id") or "page")
        split = page_splits.get(page_id, "train")
        base = f"{book_id}_{page_id}"
        lbl_out = os.path.join(out_dir, split, "labels", base + ".txt")
        write_detect_image(image_path,
                           os.path.join(out_dir, split, "images"), base)
        with open(lbl_out, "w", encoding="utf-8") as f:
            f.write("\n".join(labels) + "\n")
        if split == "train":
            train_pages += 1
            train_inst += len(labels)
        else:
            val_pages += 1
            val_inst += len(labels)

    return {
        "train_pages": train_pages,
        "val_pages": val_pages,
        "train_instances": train_inst,
        "val_instances": val_inst,
        "classes": class_names,
        "skipped": skipped,
        "split_pages": page_splits,
    }



_INVALID_FS_CHARS = set(':\\/*?"<>|')





def _safe_class_name(ch: str) -> str:
    """类目录名的文件系统转义：Windows 非法字符/控制字符转 _uXXXX，
    推理侧 segmenter._cls_name_to_char 对称还原。"""
    if ch in _INVALID_FS_CHARS or ord(ch) < 32:
        return f"_u{ord(ch):04X}"
    return ch



def _write_char_cls_dataset(
    pages: list[dict], out_dir: str, train_ratio: float, seed: int,
    book_id: str,
) -> dict:
    """目录式分类数据集：train|val/<字>/<书籍ID>_<页>_<行>_<i>.jpg

    按书写盘（样本文件名带书籍前缀，重生成互不覆盖）；classes.txt 与
    metadata 汇总在 _finalize_char_cls_dataset / metadata_<书籍ID>.json。
    """
    # 划分只对"真正产出样本的页"计算：标注库常见"页级已确认但行/字还
    # 没确认"的中间状态（第五册 96 页页级全确认、只有 14 页有确认字），
    # 若按全部页划分，val 键可能全落在不产出样本的页上——val 目录为
    # 空，ultralytics 分类训练直接失败。产出样本的页集合 = class_pages
    # 里出现过的页（确认行里确认单字所在页）。
    page_splits: dict[str, str] = {}
    # Keep every validation class learnable whenever page-level splitting
    # permits it. Moving a whole page preserves the no-page-leak invariant.
    class_pages: dict[str, list[str]] = {}
    for ann in pages:
        if not _page_confirmed(ann):
            continue
        pid = str(ann.get("page_id") or "page")
        for ln in ann.get("lines", []):
            if not _is_confirmed(ln):
                continue
            for c in ln.get("chars", []):
                if not _is_confirmed(c):
                    continue
                label = (c.get("text") or "").strip()
                if len(label) == 1 and c.get("type") != "ignore":
                    class_pages.setdefault(label, []).append(pid)
    sample_pages = sorted({pid for pids in class_pages.values()
                           for pid in pids})
    page_splits = _page_split([{"page_id": p} for p in sample_pages],
                              train_ratio, seed)
    original_splits = dict(page_splits)
    for label, pids in class_pages.items():
        if any(page_splits.get(pid) == "train" for pid in pids):
            continue
        for pid in pids:
            if page_splits.get(pid) == "val":
                page_splits[pid] = "train"
                break
    # 稀疏类兜底：字类多而页少时（第五册 609 类/96 页），逐类认领会把
    # val 页全部挪空——ultralytics 分类训练要求 val 非空。此时恢复原
    # 划分，改为把这些"val 独有类"的样本复制一份进 train（罕见类
    # train/val 同源、指标略乐观，好过整库无法训练）。
    val_only_labels: set[str] = set()
    if not any(s == "val" for s in page_splits.values()):
        page_splits = original_splits
        val_only_labels = {
            label for label, pids in class_pages.items()
            if not any(original_splits.get(pid) == "train" for pid in pids)}
    per_class: dict[str, int] = {"train": {}, "val": {}}
    metadata: list[dict[str, Any]] = []
    skipped = {"unconfirmed_page": 0, "missing_image": 0, "decode_failed": 0, "unconfirmed_char": 0, "invalid_box": 0}
    total = 0
    for ann in pages:
        if not _page_confirmed(ann):
            skipped["unconfirmed_page"] += 1
            continue
        image_path = ann.get("image_path", "")
        if not image_path or not os.path.exists(image_path):
            skipped["missing_image"] += 1
            continue
        img = _imread(image_path)
        if img is None:
            skipped["decode_failed"] += 1
            continue
        ih, iw = img.shape[:2]
        for line in ann.get("lines", []):
            # 分类标签的门槛与统计/编辑器同口径：行与字都已确认（行未
            # 确认时其字的文本校对状态不可信——实测部分编辑状态下字被
            # 单独确认而行仍是 proposed）。
            if not _is_confirmed(line):
                continue
            for i, c in enumerate(line.get("chars", [])):
                text = (c.get("text") or "").strip()
                if not _is_confirmed(c):
                    skipped["unconfirmed_char"] += 1
                    continue
                if not text or len(text) != 1 or c.get("type") == "ignore":
                    continue
                x, y, w, h = c["x"], c["y"], c["w"], c["h"]
                if w <= 0 or h <= 0:
                    skipped["invalid_box"] += 1
                    continue
                # 注意：此裁剪 padding 公式与推理侧 segmenter.get_char_
                # candidates 必须保持一致，改动任一侧都会造成训练/推理
                # 分布漂移（候选分类质量下降）。
                pad = max(2, min(iw, ih) // 400)
                x1, y1 = max(0, x - pad), max(0, y - pad)
                x2, y2 = min(iw, x + w + pad), min(ih, y + h + pad)
                if x2 - x1 < 6 or y2 - y1 < 6:
                    continue
                crop = img[y1:y2, x1:x2]
                page_id = str(ann.get("page_id") or ann.get("page")
                              or "page")
                split = page_splits.get(page_id, "train")
                ok, buf = cv2.imencode(
                    ".jpg", crop,
                    [int(cv2.IMWRITE_JPEG_QUALITY), EXPORT_JPEG_QUALITY])
                if not ok:
                    continue
                # 类目录名做文件系统转义：确认字里存在 Windows 非法字符
                # （实测第五册确认字含 "/" ":" "\"），目录式数据集的类名
                # 即目录名。推理侧 segmenter._cls_name_to_char 负责还原。
                base_name = f"{book_id}_{page_id}_{line.get('id', 'l')}_{i}"
                targets = [split]
                if split == "val" and text in val_only_labels:
                    targets = ["val", "train"]  # 稀疏兜底：罕见类复制进 train
                for target in targets:
                    cls_dir = os.path.join(out_dir, target,
                                           _safe_class_name(text))
                    os.makedirs(cls_dir, exist_ok=True)
                    suffix = "_dup" if (target == "train"
                                        and len(targets) > 1) else ""
                    buf.tofile(os.path.join(cls_dir, f"{base_name}{suffix}.jpg"))
                    per_class[target][text] = per_class[target].get(text, 0) + 1
                metadata.append({
                    "path": os.path.join(split, _safe_class_name(text),
                                         f"{base_name}.jpg"),
                    "label": text,
                    "page_id": page_id,
                    "book_id": book_id,
                    "line_id": line.get("id", ""),
                    "source_uid": c.get("stable_uid") or c.get("char_uid") or c.get("id", ""),
                    "bbox": [x, y, w, h],
                    "status": "confirmed",
                })
                total += 1

    # 样本清单按书分文件（metadata_<书籍ID>.json）：全局目录被多本书
    # 合并写入，单一 metadata.json 会被后写的书整份覆盖。
    with open(os.path.join(out_dir, f"metadata_{book_id}.json"), "w",
              encoding="utf-8") as f:
        json.dump({"schema_version": DATASET_SCHEMA_VERSION,
                   "book_id": book_id, "samples": metadata},
                  f, ensure_ascii=False, indent=2)
    return {
        "train_instances": sum(per_class["train"].values()),
        "val_instances": sum(per_class["val"].values()),
        "classes": len(per_class["train"]),
        "skipped": skipped,
        "split_pages": page_splits,
    }



def confirmed_excluded_regions(ann: dict) -> list[dict]:
    """已确认的排除类版面区（页眉/页脚/页码/图/表）——用户规则：页眉
    页脚只作为版面标注（region_det 训练）用，不参与段落/行/单字框的
    识别与训练。proposed 候选不排除（未过目不能挡数据）；无此类区时
    返回空，页面内容照旧全量。

    Dart 侧 PageAnnotation.centerInConfirmedExcluded 是同一协议的另一半
    （编辑器本书计数与这里同口径），两侧判定必须保持一致：框中心点
    落在已确认排除类区内即排除。"""
    from seg_layout import REGION_EXCLUDED_LABELS, region_label

    return [
        r for r in (ann.get("main_regions") or [])
        if region_label(r) in REGION_EXCLUDED_LABELS and _box_confirmed(r)
    ]


def _center_in_any(item: dict, regions: list[dict]) -> bool:
    if not regions:
        return False
    cx = item.get("x", 0) + item.get("w", 0) / 2
    cy = item.get("y", 0) + item.get("h", 0) / 2
    for r in regions:
        if (r.get("x", 0) <= cx <= r.get("x", 0) + r.get("w", 0)
                and r.get("y", 0) <= cy <= r.get("y", 0) + r.get("h", 0)):
            return True
    return False


def page_labels(layer: str, ann: dict, h_dir: str = "ltr"):
    """单页的 detect 层标签元组 [(x, y, w, h, cls)]——四层标签语义的唯一
    实现，_write_layer_for_book（按书整写）与 train_export（页级增量导出）
    共用，两侧行为永不漂移。

    cls 语义：char_det 恒 0；line_det 0=普通行/1=夹注行；paragraph_det
    恒 0（段落缺省时按行推断外接矩形）；region_det 按 label 映射词表下标
    （未知 label → -1，由写盘侧跳过计数）。无有效标注返回 []。

    内容层（char/line/paragraph）排除已确认排除类区（页眉/页脚/页码/
    图/表）内的框——那些区域只作 region_det 标注；region_det 层本身
    照常收录全部已确认区（页眉页脚正是它的训练样本）。
    """
    if layer == "char_det":
        # box_confirmed：「确认识别框」只确认了框几何——检测训练只关心框。
        excluded = confirmed_excluded_regions(ann)
        return [
            (b["x"], b["y"], b["w"], b["h"], 0)
            for b in ann.get("blocks", [])
            if _box_confirmed(b) and b.get("type") != "ignore"
            and not _center_in_any(b, excluded)
        ]
    if layer == "line_det":
        excluded = confirmed_excluded_regions(ann)
        out = []
        for ln in ann.get("lines", []):
            if not _box_confirmed(ln):
                continue
            if _center_in_any(ln, excluded):
                continue
            chars = ln.get("chars", [])
            is_anno = bool(chars) and all(
                c.get("type") == "annotation" for c in chars)
            out.append((ln["x"], ln["y"], ln["w"], ln["h"], 1 if is_anno else 0))
        return out
    if layer == "paragraph_det":
        # 确认段落是 dict（直接取矩形）；缺省时按行推断外接矩形
        #（推断结果是行 dict 的列表）。旧实现对确认段落也按"行列表"
        # 迭代（dict 迭代出字符串键）会崩——真实标注一旦确认段落即触发，
        # 此前测试只走推断路径没暴露。
        excluded = confirmed_excluded_regions(ann)
        confirmed_paras = [p for p in (ann.get("paragraphs") or [])
                           if _box_confirmed(p)
                           and not _center_in_any(p, excluded)]
        if confirmed_paras:
            return [
                (p["x"], p["y"], p["w"], p["h"], 0)
                for p in confirmed_paras
                if p.get("w", 0) > 0 and p.get("h", 0) > 0
            ]
        segs = _infer_vertical_paragraphs(
            [ln for ln in ann.get("lines", [])
             if _box_confirmed(ln) and not _center_in_any(ln, excluded)],
            h_dir,
        )
        return [
            (
                min(l["x"] for l in seg),
                min(l["y"] for l in seg),
                max(l["x"] + l["w"] for l in seg) - min(l["x"] for l in seg),
                max(l["y"] + l["h"] for l in seg) - min(l["y"] for l in seg),
                0,
            )
            for seg in segs
        ]
    if layer == "region_det":
        # 类别来自 main_regions[].label；旧标注无 label 缺省 main_text，
        # 未知 label → -1 由写盘侧跳过计数。
        name_index = {n: i for i, n in enumerate(
            LAYER_INFO["region_det"]["names"])}
        return [
            (r["x"], r["y"], r["w"], r["h"],
             name_index.get(r.get("label") or "main_text", -1))
            for r in ann.get("main_regions", [])
            if _box_confirmed(r)
        ]
    return []


def char_cls_page_items(ann: dict) -> list[dict]:
    """单页的分类样本条目（行与字都已确认的单字）——增量导出与按书整写
    共用的提取口径。返回 [{x,y,w,h,text,line_id,index,source_uid}]。
    已确认排除类区（页眉/页脚等）内的行不产分类样本（与 detect 层的
    排除同口径：页眉页脚只作 region_det 标注）。"""
    items = []
    excluded = confirmed_excluded_regions(ann)
    for line in ann.get("lines", []):
        # 分类标签的门槛与统计/编辑器同口径：行与字都已确认。
        if not _is_confirmed(line):
            continue
        if _center_in_any(line, excluded):
            continue
        for i, c in enumerate(line.get("chars", [])):
            text = (c.get("text") or "").strip()
            if not _is_confirmed(c):
                continue
            if not text or len(text) != 1 or c.get("type") == "ignore":
                continue
            x, y, w, h = c["x"], c["y"], c["w"], c["h"]
            if w <= 0 or h <= 0:
                continue
            items.append({
                "x": x, "y": y, "w": w, "h": h, "text": text,
                "line_id": line.get("id", "l"), "index": i,
                "source_uid": c.get("stable_uid") or c.get("char_uid")
                or c.get("id", ""),
            })
    return items


def write_char_cls_crop(img, item: dict, out_dir: str, split: str,
                        book_id: str, page_id: str, dup: bool = False):
    """裁剪并写盘一个分类样本，返回 (相对路径, metadata 条目)；无效 None。

    裁剪 padding 公式与推理侧 segmenter.get_char_candidates 必须保持
    一致（改动任一侧都会造成训练/推理分布漂移）。
    """
    ih, iw = img.shape[:2]
    x, y, w, h = item["x"], item["y"], item["w"], item["h"]
    pad = max(2, min(iw, ih) // 400)
    x1, y1 = max(0, x - pad), max(0, y - pad)
    x2, y2 = min(iw, x + w + pad), min(ih, y + h + pad)
    if x2 - x1 < 6 or y2 - y1 < 6:
        return None
    crop = img[y1:y2, x1:x2]
    ok, buf = cv2.imencode(
        ".jpg", crop,
        [int(cv2.IMWRITE_JPEG_QUALITY), EXPORT_JPEG_QUALITY])
    if not ok:
        return None
    base_name = f"{book_id}_{page_id}_{item['line_id']}_{item['index']}"
    rel = os.path.join(split, _safe_class_name(item["text"]),
                       base_name + ("_dup" if dup else "") + ".jpg")
    path = os.path.join(out_dir, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    buf.tofile(path)
    meta = {
        "path": rel.replace(chr(92), "/"),
        "label": item["text"],
        "page_id": page_id,
        "book_id": book_id,
        "line_id": item["line_id"],
        "source_uid": item["source_uid"],
        "bbox": [x, y, w, h],
        "status": "confirmed",
    }
    return rel, meta


def _write_layer_for_book(
    layer: str, pages: list[dict], h_by_page: dict[int, str],
    out_dir: str, book_id: str, train_ratio: float, seed: int,
) -> dict:
    if layer in ("char_det", "line_det", "paragraph_det", "region_det"):
        # 四层 detect 统一走 page_labels（标签语义唯一来源）
        return _write_detect_dataset(
            pages, out_dir,
            label_fn=lambda a: page_labels(
                layer, a, h_by_page.get(id(a), "ltr")),
            class_names=list(LAYER_INFO[layer]["names"]),
            train_ratio=train_ratio, seed=seed, book_id=book_id,
        )
    if layer == "char_cls":
        return _write_char_cls_dataset(
            pages, out_dir, train_ratio, seed, book_id)
    raise ValueError(f"unknown layer: {layer}")



def _finalize_detect_dataset(out_dir: str, strict: bool = True) -> None:
    """detect 层全局目录收尾：清训练缓存、data.yaml、val 非空兜底。

    val 兜底看的是整个全局目录（多本书合并后通常已有其他书的 val 样本），
    只有全局 val 为空时才挪一页——比旧版按书兜底少动数据。[strict]=False
    （迁移旧数据用）时样本不足只记日志不抛错：小体量贡献并入后，其他书
    的样本会补足 val，不该因为单独不成集就丢弃这本书的数据。
    """
    for split in ("train", "val"):
        for kind in ("images", "labels"):
            os.makedirs(os.path.join(out_dir, split, kind), exist_ok=True)
        # ultralytics 的标签缓存按"标签文件清单哈希"失效，新增样本会自动
        # 重扫；这里顺手删掉，避免旧缓存里残留已删除文件的极端情况。
        cache = os.path.join(out_dir, split, "labels.cache")
        if os.path.exists(cache):
            os.remove(cache)
    train_dir = os.path.join(out_dir, "train", "images")
    val_dir = os.path.join(out_dir, "val", "images")
    train_imgs = sorted(os.listdir(train_dir))
    val_imgs = os.listdir(val_dir)
    if not val_imgs:
        if len(train_imgs) < 2:
            msg = (f"可训练页面不足：至少需要 2 个整页已确认且有标注的页面"
                   f"才能划分训练/验证集（当前有效页面 {len(train_imgs)} 个）。")
            if strict:
                raise ValueError(msg)
            _log(f"[dataset] {out_dir}: {msg}")
        else:
            victim = train_imgs[-1]
            stem = os.path.splitext(victim)[0]
            os.replace(os.path.join(train_dir, victim), os.path.join(val_dir, victim))
            os.replace(os.path.join(out_dir, "train", "labels", stem + ".txt"),
                       os.path.join(out_dir, "val", "labels", stem + ".txt"))
    # yaml 路径必须与实际布局（<out>/<split>/images、<out>/<split>/labels）
    # 对齐：ultralytics 对每个图片路径做 images -> labels 替换找标签文件。
    names = LAYER_INFO.get(os.path.basename(out_dir), {}).get("names") or ["char"]
    with open(os.path.join(out_dir, "data.yaml"), "w", encoding="utf-8") as f:
        f.write(f"path: {out_dir.replace(chr(92), '/')}\ntrain: train/images\nval: val/images\nnames:\n")
        for i, name in enumerate(names):
            f.write(f"  {i}: {name}\n")



def _cls_disk_stats(out_dir: str) -> dict:
    """从磁盘统计分类数据集（全局合并后的真实口径，不依赖各书统计相加）。"""
    per_class: dict[str, dict[str, int]] = {"train": {}, "val": {}}
    for split in ("train", "val"):
        split_dir = os.path.join(out_dir, split)
        if not os.path.isdir(split_dir):
            continue
        for cls_name in os.listdir(split_dir):
            cls_dir = os.path.join(split_dir, cls_name)
            if os.path.isdir(cls_dir):
                n = len(os.listdir(cls_dir))
                if n:
                    per_class[split][cls_name] = n
    counts = per_class["train"]
    only_val = set(per_class["val"]) - set(counts)
    return {
        "train_instances": sum(counts.values()),
        "val_instances": sum(per_class["val"].values()),
        "classes": len(counts),
        "low_sample_classes": sorted(k for k, v in counts.items() if v < 3),
        "val_only_classes": sorted(only_val),
        "top_classes": sorted(counts.items(), key=lambda kv: -kv[1])[:10],
    }



def _finalize_char_cls_dataset(out_dir: str, strict: bool = True) -> dict:
    """char_cls 全局目录收尾：清缓存、按 train 目录重建 classes.txt、
    val 非空兜底，返回磁盘口径的合并统计。[strict]=False（迁移旧数据用）
    时样本不足只记日志不抛错（同 _finalize_detect_dataset 的宽容语义）。"""
    os.makedirs(os.path.join(out_dir, "train"), exist_ok=True)
    os.makedirs(os.path.join(out_dir, "val"), exist_ok=True)
    for name in os.listdir(out_dir):
        if name.endswith(".cache"):
            os.remove(os.path.join(out_dir, name))
    val_files = [n for d in os.listdir(os.path.join(out_dir, "val"))
                 if os.path.isdir(os.path.join(out_dir, "val", d))
                 for n in os.listdir(os.path.join(out_dir, "val", d))]
    if not val_files:
        # 全局 val 为空：从 train 复制一个样本进 val 兜底（同图双份，指标
        # 略乐观，好过 ultralytics 分类训练直接失败）。
        copied = False
        train_dir = os.path.join(out_dir, "train")
        for cls_name in sorted(os.listdir(train_dir)):
            src_dir = os.path.join(train_dir, cls_name)
            if not os.path.isdir(src_dir) or not os.listdir(src_dir):
                continue
            for name in os.listdir(src_dir):
                dst_dir = os.path.join(out_dir, "val", cls_name)
                os.makedirs(dst_dir, exist_ok=True)
                shutil.copyfile(os.path.join(src_dir, name),
                                os.path.join(dst_dir, name))
                copied = True
                break
            if copied:
                break
        if not copied:
            msg = ("可训练单字样本不足：没有已确认的单字标签"
                   "（需要行与字都确认并保存）。")
            if strict:
                raise ValueError(msg)
            _log(f"[dataset] {out_dir}: {msg}")
    stats = _cls_disk_stats(out_dir)
    with open(os.path.join(out_dir, "classes.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(k for k in sorted(os.listdir(os.path.join(out_dir, "train")))
                          if os.path.isdir(os.path.join(out_dir, "train", k))) + "\n")
    return stats



def _accumulate_layer_stats(total: dict | None, stats: dict) -> dict:
    """detect 层跨书累加（instances/pages/skipped 求和，split 合并）。"""
    if total is None:
        return dict(stats)
    for key in ("train_pages", "val_pages", "train_instances", "val_instances"):
        total[key] = total.get(key, 0) + stats.get(key, 0)
    skipped = dict(total.get("skipped") or {})
    for key, v in (stats.get("skipped") or {}).items():
        skipped[key] = skipped.get(key, 0) + v
    total["skipped"] = skipped
    total.setdefault("split_pages", {}).update(stats.get("split_pages") or {})
    return total



def generate_datasets(
    project_dir: str,
    layers: list[str] | None = None,
    force: bool = False,
    train_ratio: float = 0.8,
    seed: int = 42,
) -> dict[str, Any]:
    """从项目标注生成指定层的数据集（全局共享，按书合并），返回聚合统计。

    [project_dir] 为单本书目录时只刷新该书自己的样本；为库根目录时刷新
    全部书籍。无论传入哪种，其他书已生成的样本都保持不动——数据集是
    全局资产，逐书累计。
    """
    _migrate_legacy_datasets()
    books = _book_dirs_under(project_dir)
    if not books:
        raise ValueError(f"没有找到书籍项目：{project_dir}")
    book_pages: dict[str, tuple[str, list[dict], dict[int, str]]] = {}
    total_pages = 0
    for book_dir in books:
        pages, h_by_page = _load_book_pages([book_dir])
        bid = os.path.basename(os.path.normpath(book_dir))
        book_pages[bid] = (book_dir, pages, h_by_page)
        total_pages += len(pages)
    if not total_pages:
        raise ValueError(f"项目没有标注数据：{project_dir}")

    meta = _load_meta()
    layers = layers or LAYERS
    result: dict[str, Any] = {
        "schema_version": DATASET_SCHEMA_VERSION,
        "project_id": train_data.GLOBAL_DATASET_DIR,
        "books": sorted(book_pages),
        "pages": total_pages,
        "layers": {},
    }

    for layer in layers:
        if layer not in LAYER_INFO:
            continue
        out_dir = global_layer_dir(layer)
        os.makedirs(out_dir, exist_ok=True)
        # detect 层的类集指纹：_meta.json 条目里存着生成时的 classes 列表，
        # 与当前 LAYER_INFO 不符（词表扩类/改类）视为 dirty 自动重建——
        # 否则旧 data.yaml 的 nc 与新标签 cls 越界会毁掉训练。char_cls 的
        # classes 是数量（int），不适用指纹。
        layer_names = (LAYER_INFO[layer].get("names")
                       if LAYER_INFO[layer].get("task") == "detect" else None)
        agg: dict | None = None
        dirty = False
        for bid, (book_dir, pages, h_by_page) in book_pages.items():
            book_meta = meta["books"].get(bid) or {}
            cached_entry = (book_meta.get("layers") or {}).get(layer)
            names_match = (layer_names is None
                           or cached_entry is None
                           or cached_entry.get("classes") == layer_names)
            if (not force and cached_entry is not None and names_match
                    and _dataset_ready(out_dir, layer)):
                # 该书该层已生成过且全局目录完好：复用（文件还在全局目录里）
                stats = dict(book_meta["layers"][layer])
                stats["cached"] = True
                _log(f"[{layer}] {bid} 数据集已存在，复用: {out_dir}")
            else:
                _purge_book_files(out_dir, bid, layer)
                stats = _write_layer_for_book(
                    layer, pages, h_by_page, out_dir, bid,
                    train_ratio=train_ratio, seed=seed)
                stats["cached"] = False
                entry = meta["books"].setdefault(bid, {"layers": {}})
                entry["generated_at"] = time.time()
                entry["pages"] = len(pages)
                entry["settings"] = _load_book(book_dir).get("settings") or {}
                entry["layers"][layer] = {
                    k: v for k, v in stats.items() if k != "cached"}
                dirty = True
                _log(
                    f"[{layer}] {bid} 数据集生成完成: "
                    f"train={stats.get('train_instances')} "
                    f"val={stats.get('val_instances')}"
                )
            if layer != "char_cls":
                # cls 的合并统计由 _finalize/_cls_disk_stats 按磁盘口径给出
                agg = _accumulate_layer_stats(agg, stats)
        if dirty:
            # 只有真正写过盘才收尾：清缓存/重建 data.yaml 与 classes.txt、
            # val 非空兜底。全缓存命中时目录已处于一致状态，不再动它。
            if layer == "char_cls":
                agg = _finalize_char_cls_dataset(out_dir)
                agg["cached"] = False
            else:
                _finalize_detect_dataset(out_dir)
                agg["cached"] = False
        elif layer == "char_cls":
            agg = _cls_disk_stats(out_dir)
            agg["cached"] = True
        else:
            agg["cached"] = True
        result["layers"][layer] = agg

    _save_meta(meta)
    return result



def dataset_stats(project_dir: str) -> dict:
    """已导出口径的各层统计（manifest）+ 书库待导出量（pending）。

    统计 = 已导出数据（<dataset_root>/manifest.json）——书籍任务从书库
    删除不影响数字；pending = 书库中已确认但未导出/内容有变化的页数
    （训练页"自动增量导出"的触发依据）。char_cls 的字类覆盖数是磁盘
    口径（同类跨书去重只有扫目录能算）。
    """
    try:
        # 升级后第一次访问：把旧版按书数据集并进全局目录（幂等，失败不
        # 影响统计本身）
        _migrate_legacy_datasets()
    except Exception as exc:
        _log(f"[stats] 旧数据集迁移失败: {exc}")
    books = all_book_dirs(project_dir)
    pages, h_by_page = _load_book_pages(books)
    # 书库为空（书全删了/库根没书）时统计仍从 manifest 出——已导出数据
    # 与统计不随书籍任务消失；pending 扫描在空书库上自然为 0。
    import train_export
    import train_manifest as tm

    manifest = tm.ensure_manifest_baseline()
    pending = train_export.scan_pending(project_dir).get("pending", {})
    layers: dict[str, dict] = {}
    for layer in LAYERS:
        totals = train_export.layer_totals(manifest, layer)
        layer_stats = {
            "instances": totals["instances"],
            "pages": totals["pages"],
            "pending": pending.get(layer, {"pages": 0, "books": 0}),
        }
        if layer == "region_det":
            # 多类分布（哪一类样本不足训练页可见）
            layer_stats["per_class"] = totals["per_class"]
        if layer == "char_cls":
            out_dir = global_layer_dir(layer)
            layer_stats["classes"] = (_cls_disk_stats(out_dir).get("classes", 0)
                                      if os.path.isdir(os.path.join(out_dir, "train"))
                                      else 0)
        layers[layer] = layer_stats
    stats = {
        "pages": len(pages),
        "project_id": train_data.GLOBAL_DATASET_DIR,
        "scope": "all_books",
        "manifest_books": len(manifest.get("books", {})),
        "dataset_root": train_data.datasets_root(),
        "layers": layers,
    }
    registry_layers = _load_registry().get("layers", {})
    for layer, layer_stats in stats["layers"].items():
        runs = (registry_layers.get(layer) or {}).get("runs", []) or []
        # 每个档位成功训练过的次数（数据要求按轮数进阶）。旧注册表条目
        # 没记录 base_model，按该层历史默认档位归档。
        rounds_by_model: dict[str, int] = {}
        trained_runs = 0
        for run in runs:
            if not (run.get("best") and os.path.exists(run["best"])):
                continue
            trained_runs += 1
            tier = _run_base_tier(layer, run)
            rounds_by_model[tier] = rounds_by_model.get(tier, 0) + 1
        layer_stats["trained_runs"] = trained_runs
        layer_stats["readiness"] = _training_readiness(
            layer, layer_stats["instances"], layer_stats.get("classes", 0),
            rounds_by_model=rounds_by_model,
        )
        # 数据集目录（统一可配置根）；前端用它提供"打开数据集文件夹"入口
        layer_stats["dataset_dir"] = global_layer_dir(layer)
        layer_stats["dataset_dir_exists"] = _dataset_ready(
            layer_stats["dataset_dir"], layer)
    return stats



def dataset_dir(project_dir: str, layer: str) -> str | None:
    """定位某层数据集目录（全局共享，供训练启动用）。

    不存在时按整个书库自动生成——训练从任何一本书发起，用的都是全部
    书籍累计出来的同一份数据。
    """
    _migrate_legacy_datasets()
    out_dir = global_layer_dir(layer)
    if not _dataset_ready(out_dir, layer):
        import train_export

        train_export.export_datasets(library_root_of(project_dir), [layer])
    if not _dataset_ready(out_dir, layer):
        return None
    return out_dir



# ────────────────── 旧版按书数据集迁移 ──────────────────



def _move_to_legacy(book_dir: str) -> None:
    legacy_root = os.path.join(train_data.datasets_root(),
                               train_data.LEGACY_DATASET_DIR)
    os.makedirs(legacy_root, exist_ok=True)
    target = os.path.join(legacy_root, os.path.basename(book_dir))
    if os.path.isdir(target):
        shutil.rmtree(target)
    os.replace(book_dir, target)



def _migrate_legacy_book(book_dir: str, pid: str, meta: dict) -> None:
    """把旧版 datasets/<pid>/<layer>/ 合并进全局目录（文件加 <pid>_ 前缀）。

    verify_pair 层委托 verify_training 迁移（它有自己的 manifest 结构）。
    迁移完成后旧目录移入 datasets/_legacy/ 保留备份。
    """
    import verify_training  # 延迟导入：verify_training → 门面 → 本模块

    legacy_meta: dict = {}
    try:
        with open(os.path.join(book_dir, "_meta.json"), encoding="utf-8") as f:
            legacy_meta = json.load(f)
    except Exception:
        legacy_meta = {}
    migrated_layers: dict[str, Any] = {}
    for layer in sorted(os.listdir(book_dir)):
        src = os.path.join(book_dir, layer)
        if not os.path.isdir(src):
            continue
        if layer == "verify_pair":
            verify_training._migrate_legacy_layer(src, pid)
            migrated_layers[layer] = {"migrated": True}
            continue
        if layer not in LAYER_INFO:
            _log(f"[migrate] 跳过未知层 {pid}/{layer}")
            continue
        dst = global_layer_dir(layer)
        if layer == "char_cls":
            for split in ("train", "val"):
                split_src = os.path.join(src, split)
                if not os.path.isdir(split_src):
                    continue
                for cls_name in os.listdir(split_src):
                    cls_src = os.path.join(split_src, cls_name)
                    if not os.path.isdir(cls_src):
                        continue
                    for name in os.listdir(cls_src):
                        os.makedirs(os.path.join(dst, split, cls_name),
                                    exist_ok=True)
                        shutil.copyfile(
                            os.path.join(cls_src, name),
                            os.path.join(dst, split, cls_name, f"{pid}_{name}"))
            # 旧版单一 metadata.json 改名为按书分文件，样本路径补前缀
            old_meta = os.path.join(src, "metadata.json")
            if os.path.exists(old_meta):
                try:
                    with open(old_meta, encoding="utf-8") as f:
                        doc = json.load(f)
                    for sample in doc.get("samples", []):
                        path = sample.get("path") or ""
                        head, _, fname = path.rpartition("/")
                        sample["path"] = f"{head}/{pid}_{fname}" if head else f"{pid}_{fname}"
                        sample.setdefault("book_id", pid)
                    with open(os.path.join(dst, f"metadata_{pid}.json"), "w",
                              encoding="utf-8") as f:
                        json.dump({"schema_version": doc.get("schema_version") or DATASET_SCHEMA_VERSION,
                                   "book_id": pid,
                                   "samples": doc.get("samples", [])},
                                  f, ensure_ascii=False, indent=2)
                except Exception as exc:
                    _log(f"[migrate] {pid}/char_cls metadata 迁移失败: {exc}")
            _finalize_char_cls_dataset(dst, strict=False)
        else:
            for split in ("train", "val"):
                for kind in ("images", "labels"):
                    src_kind = os.path.join(src, split, kind)
                    if not os.path.isdir(src_kind):
                        continue
                    os.makedirs(os.path.join(dst, split, kind), exist_ok=True)
                    for name in os.listdir(src_kind):
                        shutil.copyfile(
                            os.path.join(src_kind, name),
                            os.path.join(dst, split, kind, f"{pid}_{name}"))
            _finalize_detect_dataset(dst, strict=False)
        old_stats = (legacy_meta.get("layers") or {}).get(layer) or {}
        migrated_layers[layer] = old_stats or {"migrated": True}
    if migrated_layers:
        entry = meta["books"].setdefault(pid, {"layers": {}})
        entry["generated_at"] = legacy_meta.get("generated_at") or time.time()
        entry["pages"] = legacy_meta.get("pages") or 0
        entry["settings"] = legacy_meta.get("settings") or {}
        entry["migrated"] = True
        entry["layers"].update(migrated_layers)
        _log(f"[migrate] 旧数据集已并入全局目录: {pid} -> {sorted(migrated_layers)}")
    _move_to_legacy(book_dir)



def _migrate_legacy_datasets() -> None:
    """旧版按书数据集（datasets/<书籍ID>/）一次性合并进全局目录。

    幂等：已登记进全局 _meta.json 的书只清理残留目录，不重复拷贝。
    单本书失败只跳过该书，不影响其他书与服务启动。
    """
    global _MIGRATED
    if _MIGRATED:
        return
    with _MIGRATE_LOCK:
        if _MIGRATED:
            return
        try:
            root = train_data.datasets_root()
            if os.path.isdir(root):
                meta = _load_meta()
                names = [n for n in sorted(os.listdir(root))
                         if n not in (train_data.GLOBAL_DATASET_DIR,
                                      train_data.LEGACY_DATASET_DIR)
                         and os.path.isdir(os.path.join(root, n))]
                for pid in names:
                    book_dir = os.path.join(root, pid)
                    try:
                        _migrate_legacy_book(book_dir, pid, meta)
                    except Exception as exc:
                        _log(f"[migrate] 跳过旧数据集 {pid}: {exc}")
                if names:
                    _save_meta(meta)
        except Exception as exc:
            _log(f"[migrate] 旧数据集迁移失败（下次访问重试）: {exc}")
        _MIGRATED = True
