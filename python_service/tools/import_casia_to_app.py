# -*- coding: utf-8 -*-
"""把 build_casia_datasets 的单字产物导入应用的全局训练数据集（只增不删，可重跑）。

用法：
  python -I import_casia_to_app.py <build 输出目录>

导入内容：
  char_det  yolo_handwriting_char/{images,labels}/{train,val}
            → datasets/_global/char_det/{train,val}/{images,labels}（文件名已带 gnt_ 前缀）
  char_cls  char_cls/{train,val}/U码位/
            → datasets/_global/char_cls/{train,val}/<字>/（类目录名规则同 _class_dir_name）
  manifest  books["casia_gnt"] 记录两层统计（与 train_manifest.record_book_layer 同口径），
            训练页的实例数据随之更新。原 manifest 先备份为 manifest.json.bak-<时间戳>。

数据集根目录由 train_paths.dataset_root() 决定，不在脚本里写死。
已存在且大小一致的文件跳过，重跑不会重复复制。
"""
import argparse
import json
import os
import shutil
import sys
import time

SERVICE_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, SERVICE_DIR)
import train_data  # noqa: E402
import train_datasets  # noqa: E402
import train_manifest  # noqa: E402
import train_paths  # noqa: E402

BOOK_KEY = "casia_gnt"
SPLITS = ("train", "val")


def _class_dir_name(ch):
    """与 train_datasets._safe_class_name 同规则（Windows 非法字符 → _uXXXX）；
    另转义 '.'：单独的 '.' 不能作为 Windows 目录名。推理侧 _cls_name_to_char 会还原。"""
    if ch in '\\/:*?"<>|' or ord(ch) < 32 or ch == ".":
        return f"_u{ord(ch):04X}"
    return ch


def _copy_new(src, dst):
    """目标已存在且大小一致则跳过。返回是否实际复制。"""
    if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src):
        return False
    shutil.copyfile(src, dst)
    return True


def import_char_det(build, dst_root):
    stats = {}
    for split in SPLITS:
        label_dir = os.path.join(build, "yolo_handwriting_char", "labels", split)
        image_dir = os.path.join(build, "yolo_handwriting_char", "images", split)
        dst_img = os.path.join(dst_root, split, "images")
        dst_lbl = os.path.join(dst_root, split, "labels")
        os.makedirs(dst_img, exist_ok=True)
        os.makedirs(dst_lbl, exist_ok=True)
        pages = instances = 0
        for name in sorted(os.listdir(label_dir)):
            with open(os.path.join(label_dir, name), encoding="utf-8") as f:
                instances += sum(1 for line in f if line.strip())
            pages += 1
            _copy_new(os.path.join(label_dir, name), os.path.join(dst_lbl, name))
        for name in os.listdir(image_dir):
            _copy_new(os.path.join(image_dir, name), os.path.join(dst_img, name))
        stats[split] = {"pages": pages, "instances": instances}
        print(f"[char_det/{split}] pages={pages} instances={instances}", flush=True)
    return stats


def import_char_cls(build, dst_root):
    with open(os.path.join(build, "char_cls", "classes.json"), encoding="utf-8") as f:
        classes = json.load(f)  # U码位 → 字符
    stats = {}
    for split in SPLITS:
        src_split = os.path.join(build, "char_cls", split)
        n = 0
        for code in sorted(os.listdir(src_split)):
            dst_dir = os.path.join(dst_root, split, _class_dir_name(classes[code]))
            os.makedirs(dst_dir, exist_ok=True)
            for name in os.listdir(os.path.join(src_split, code)):
                _copy_new(os.path.join(src_split, code, name), os.path.join(dst_dir, name))
                n += 1
        stats[split] = n
        print(f"[char_cls/{split}] files={n} classes={len(os.listdir(src_split))}", flush=True)
    # 与应用导出一致：清 .cache、按 train 目录重建 classes.txt
    train_datasets._finalize_char_cls_dataset(dst_root, strict=False)
    return stats


def gnt_source_pages(build):
    """GNT 源文件按切分计数（char_cls 的 pages 口径：来源文件数）。"""
    with open(os.path.join(build, "manifest.json"), encoding="utf-8") as f:
        files = json.load(f)["files"]
    pages = {s: 0 for s in SPLITS}
    for rel, v in files.items():
        if rel.startswith("Gnt/") and v.get("status") == "ok":
            pages[v["split"]] += 1
    return pages


def update_manifest(det_stats, cls_stats, cls_pages):
    path = train_manifest.manifest_path()
    if os.path.exists(path):
        backup = f"{path}.bak-{int(time.time())}"
        shutil.copyfile(path, backup)
        print(f"[manifest] 已备份 {backup}", flush=True)
    manifest = train_manifest.load_manifest()
    manifest["books"][BOOK_KEY] = {
        "exported_at": time.time(),
        "source": "CASIA 手写数据集 Gnt（tools/build_casia_datasets.py 产出，tools/import_casia_to_app.py 导入）",
        "layers": {
            "char_det": {
                "train_pages": det_stats["train"]["pages"],
                "val_pages": det_stats["val"]["pages"],
                "train_instances": det_stats["train"]["instances"],
                "val_instances": det_stats["val"]["instances"],
                "skipped": {},
            },
            "char_cls": {
                "train_pages": cls_pages["train"],
                "val_pages": cls_pages["val"],
                "train_instances": cls_stats["train"],
                "val_instances": cls_stats["val"],
                "skipped": {},
            },
        },
    }
    train_manifest.save_manifest(manifest)
    print("[manifest] 已写入 books[%s]" % BOOK_KEY, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("build", help="build_casia_datasets 的输出目录")
    ap.add_argument("--dataset-root", help="导入到指定数据集根目录（只作用于本进程，不改 train_paths.json）")
    args = ap.parse_args()
    build = os.path.abspath(args.build)
    if args.dataset_root:
        # train_paths 的进程内缓存：之后所有 datasets_root() 都指向这里
        train_paths._cache = {**train_paths.defaults(),
                              "dataset_root": os.path.abspath(args.dataset_root)}
    print(f"[root] datasets_root={train_paths.dataset_root()}", flush=True)
    print(f"[root] char_det={train_data.global_layer_dir('char_det')}", flush=True)
    print(f"[root] char_cls={train_data.global_layer_dir('char_cls')}", flush=True)

    det_stats = import_char_det(build, train_data.global_layer_dir("char_det"))
    cls_stats = import_char_cls(build, train_data.global_layer_dir("char_cls"))
    cls_pages = gnt_source_pages(build)
    update_manifest(det_stats, cls_stats, cls_pages)
    print("[done]", flush=True)


if __name__ == "__main__":
    main()
