# -*- coding: utf-8 -*-
"""校验 build_casia_datasets 的输出（只读）。

用法：
  python -I verify_casia_datasets.py <输出目录> <抽样图保存路径> [--n 12]

检查：
  1. YOLO 标签：每行 5 列、class=0、坐标全部在 [0, 1]
  2. 图片与标签一一对应（单字页、整页行检测）
  3. 识别 labels.txt 与 rec_line/images 一一对应
  4. 作者防泄漏：train 与 val 的作者编号交集为空（图片名 / 字图目录）
  5. 抽样画框，保存拼图供目视检查
"""
import argparse
import os
import random
import re
from glob import glob

from PIL import Image, ImageDraw

WRITER_RE = re.compile(r"^(?:gnt_|HWDB2\.\d_)(\d+)-")
DET_SETS = [
    ("char_det", "yolo_handwriting_char"),
    ("det_line", os.path.join("handwritten_notes", "det_line")),
]


def check_yolo_labels(lbl_dir):
    rows, bad = 0, 0
    for path in glob(os.path.join(lbl_dir, "*.txt")):
        with open(path, encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if not parts:
                    continue
                rows += 1
                ok = len(parts) == 5 and parts[0] == "0" and all(0.0 <= float(v) <= 1.0 for v in parts[1:])
                if not ok:
                    bad += 1
    return rows, bad


def writer_ids(names):
    ids = set()
    for name in names:
        m = WRITER_RE.match(name)
        if m:
            ids.add(int(m.group(1)))
    return ids


def draw_samples(out, pairs, n, sheet_path):
    rng = random.Random(0)
    picks = rng.sample(pairs, min(n, len(pairs)))
    tiles = []
    for img_path, lbl_path in picks:
        im = Image.open(img_path).convert("RGB")
        W, H = im.size
        draw = ImageDraw.Draw(im)
        with open(lbl_path, encoding="utf-8") as f:
            for line in f:
                _, cx, cy, w, h = map(float, line.split())
                x0, y0 = (cx - w / 2) * W, (cy - h / 2) * H
                x1, y1 = (cx + w / 2) * W, (cy + h / 2) * H
                draw.rectangle([x0, y0, x1, y1], outline=(255, 0, 0), width=max(2, W // 400))
        im.thumbnail((512, 512))
        tiles.append(im)
    cols = 4
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * 512, rows * 512), (80, 80, 80))
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % cols) * 512, (i // cols) * 512))
    sheet.save(sheet_path, quality=90)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("sheet")
    ap.add_argument("--n", type=int, default=12)
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    problems = []
    pairs_all = []

    for label, rel in DET_SETS:
        base = os.path.join(out, rel)
        train_names, val_names = {}, {}
        for split in ("train", "val"):
            img_dir = os.path.join(base, "images", split)
            lbl_dir = os.path.join(base, "labels", split)
            if not os.path.isdir(img_dir):
                continue
            imgs = sorted(os.listdir(img_dir))
            lbls = {os.path.splitext(f)[0] for f in os.listdir(lbl_dir)}
            stems = {os.path.splitext(f)[0] for f in imgs}
            if stems != lbls:
                problems.append(f"{label}/{split}: 图片与标签不一致 img={len(stems)} lbl={len(lbls)}")
            rows, bad = check_yolo_labels(lbl_dir)
            print(f"[{label}/{split}] images={len(imgs)} labels={len(lbls)} boxes={rows} bad_rows={bad}")
            if bad:
                problems.append(f"{label}/{split}: {bad} 行标签不合法")
            (train_names if split == "train" else val_names)[split] = imgs
            pairs_all += [(os.path.join(img_dir, f), os.path.join(lbl_dir, os.path.splitext(f)[0] + ".txt"))
                          for f in imgs[:50]]
        overlap = writer_ids(train_names.get("train", [])) & writer_ids(val_names.get("val", []))
        print(f"[{label}] train/val 作者交集: {sorted(overlap)[:10]} (共 {len(overlap)})")
        if overlap:
            problems.append(f"{label}: train/val 作者交集非空")

    # char_cls 防泄漏：目录名不含作者，用文件名检查
    cls_train, cls_val = set(), set()
    for split, bucket in (("train", cls_train), ("val", cls_val)):
        for path in glob(os.path.join(out, "char_cls", split, "*", "*.png")):
            m = WRITER_RE.match(os.path.basename(path))
            if m:
                bucket.add(int(m.group(1)))
    overlap = cls_train & cls_val
    print(f"[char_cls] train/val 作者交集: {len(overlap)}")
    if overlap:
        problems.append("char_cls: train/val 作者交集非空")

    # 识别：labels.txt 与图片一一对应
    for split in ("train", "val"):
        rec = os.path.join(out, "handwritten_notes", "rec_line", split)
        if not os.path.isdir(rec):
            continue
        with open(os.path.join(rec, "labels.txt"), encoding="utf-8") as f:
            entries = [line.rstrip("\n").split("\t", 1) for line in f if line.strip()]
        names = {e[0] for e in entries}
        img_dir = os.path.join(rec, "images")
        files = set(os.listdir(img_dir)) if os.path.isdir(img_dir) else set()
        empty = sum(1 for e in entries if len(e) != 2 or not e[1])
        print(f"[rec_line/{split}] labels={len(entries)} images={len(files)} empty_text={empty}")
        if names != files or empty:
            problems.append(f"rec_line/{split}: 标签与图片不一致或文本为空 ({empty})")

    draw_samples(out, pairs_all, args.n, args.sheet)
    print(f"[sheet] {args.sheet}")
    print("PROBLEMS:" if problems else "ALL CHECKS PASSED", *problems, sep="\n  ")


if __name__ == "__main__":
    main()
