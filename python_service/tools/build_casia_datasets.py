# -*- coding: utf-8 -*-
"""CASIA 手写数据 → 训练数据集（一次性批处理，可断点续跑）。

用法（在任意目录运行，数据目录只读）：
  python -I build_casia_datasets.py <数据根目录> <输出目录> [--limit N]

输出：
  yolo_handwriting_char/        单字检测（class 0 = char）：GNT 单字贴到合成纸面
  char_cls/<split>/<U码位>/      单字分类：GNT 单字原图；classes.json 记录目录名→字符
  handwritten_notes/det_line/   行检测（class 0 = line）：DGRL 行按页面坐标合成整页
  handwritten_notes/rec_line/<split>/   行识别：images/ + labels.txt（文件名\t文本）
  manifest.json                 每个源文件的处理结果；重跑时跳过 ok 的文件

切分：按作者编号整体划分 train / val；三个数据源的编号统一计入（偏保守，
同号视为同一人）。不处理 WPTT（在线笔迹轨迹，不是图像）。
"""
import argparse
import json
import os
import random
import sys
import zlib
from glob import glob

import numpy as np
from PIL import Image

# 数据目录与脚本目录不同，python -I 不会把脚本目录加入 sys.path，手动加上。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import casia_parsers as cp  # noqa: E402

SEED = 20261020
VAL_RATIO = 0.15
CHAR_PAGE = 1024        # 单字合成页边长（像素）
CHAR_CELL = 128         # 网格单元边长，8×8 格
CHAR_GRID = CHAR_PAGE // CHAR_CELL
CHARS_PER_PAGE = 40
GLYPH_SIDE = (50, 110)  # 单字缩放后的最长边范围（必须 < CHAR_CELL）
LINE_MAX_SIDE = 2560    # 整页 JPEG 长边上限（与应用导出一致）
JPEG_Q = 95
SERIES = ("HWDB2.0", "HWDB2.1", "HWDB2.2")


def yolo_line(cls, x0, y0, w, h, img_w, img_h):
    return (f"{cls} {(x0 + w / 2) / img_w:.6f} {(y0 + h / 2) / img_h:.6f} "
            f"{w / img_w:.6f} {h / img_h:.6f}")


def writer_splits(paths):
    """作者编号 → split。固定 seed 打乱后取前 VAL_RATIO 为 val。"""
    writers = sorted({cp.writer_id(p) for p in paths})
    shuffled = list(writers)
    random.Random(SEED).shuffle(shuffled)
    val = set(shuffled[:max(1, round(len(shuffled) * VAL_RATIO))])
    return {w: ("val" if w in val else "train") for w in writers}


_made_dirs = set()


def ensure_dir(path):
    if path not in _made_dirs:
        os.makedirs(path, exist_ok=True)
        _made_dirs.add(path)
    return path


def process_gnt(path, split, out, classes):
    stem = os.path.splitext(os.path.basename(path))[0]
    tag = f"gnt_{stem}"
    samples = list(cp.read_gnt(path))  # 先整体读完，解析失败时不写半截输出

    for i, (label, bmp) in enumerate(samples):
        code = f"U{ord(label):04X}"
        classes[code] = label
        cls_dir = ensure_dir(os.path.join(out, "char_cls", split, code))
        Image.fromarray(bmp).save(os.path.join(cls_dir, f"{tag}_{i:04d}.png"))

    img_dir = ensure_dir(os.path.join(out, "yolo_handwriting_char", "images", split))
    lbl_dir = ensure_dir(os.path.join(out, "yolo_handwriting_char", "labels", split))
    rng = random.Random(SEED ^ zlib.crc32(tag.encode("utf-8")))
    order = list(range(len(samples)))
    rng.shuffle(order)

    pages = 0
    for start in range(0, len(order), CHARS_PER_PAGE):
        idxs = order[start:start + CHARS_PER_PAGE]
        name = f"{tag}_p{pages:04d}"
        canvas = np.full((CHAR_PAGE, CHAR_PAGE), rng.randint(235, 250), dtype=np.uint8)
        cells = rng.sample(range(CHAR_GRID * CHAR_GRID), len(idxs))
        label_lines = []
        for cell, si in zip(cells, idxs):
            bmp = samples[si][1]
            h, w = bmp.shape
            scale = rng.uniform(*GLYPH_SIDE) / max(h, w)
            nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
            glyph = np.asarray(Image.fromarray(bmp).resize((nw, nh), Image.LANCZOS))
            gy, gx = divmod(cell, CHAR_GRID)
            mx = max(0, (CHAR_CELL - nw) // 2 - 4)
            my = max(0, (CHAR_CELL - nh) // 2 - 4)
            x0 = gx * CHAR_CELL + (CHAR_CELL - nw) // 2 + rng.randint(-mx, mx)
            y0 = gy * CHAR_CELL + (CHAR_CELL - nh) // 2 + rng.randint(-my, my)
            region = canvas[y0:y0 + nh, x0:x0 + nw]
            np.minimum(region, glyph, out=region)  # 白底黑字，取较深值即为叠加
            label_lines.append(yolo_line(0, x0, y0, nw, nh, CHAR_PAGE, CHAR_PAGE))
        Image.fromarray(canvas).save(os.path.join(img_dir, name + ".jpg"), quality=JPEG_Q)
        with open(os.path.join(lbl_dir, name + ".txt"), "w", encoding="utf-8") as f:
            f.write("\n".join(label_lines) + "\n")
        pages += 1
    return {"samples": len(samples), "pages": pages}


def place_line(canvas, bmp, row, col):
    """把行图按 (row, col) 画到整页上，伸出页边的部分裁掉；返回页内框 (x0, y0, w, h)。"""
    H, W = canvas.shape
    h, w = bmp.shape
    x0, y0 = max(0, col), max(0, row)
    x1, y1 = min(W, col + w), min(H, row + h)
    if x1 <= x0 or y1 <= y0:
        raise ValueError(f"行图整体在页外: row={row} col={col} h={h} w={w}")
    region = canvas[y0:y1, x0:x1]
    np.minimum(region, bmp[y0 - row:y1 - row, x0 - col:x1 - col], out=region)
    return x0, y0, x1 - x0, y1 - y0


def process_dgrl(path, series, split, out):
    page = cp.read_dgrl(path)
    if any(not ln.text for ln in page.lines):
        raise ValueError(f"存在空行: {path}")  # 先整体检查，失败时不留下半截行图
    stem = f"{series}_{os.path.splitext(os.path.basename(path))[0]}"
    canvas = np.full((page.rows, page.cols), 255, dtype=np.uint8)
    det_lines, rec_lines, rec_skipped = [], [], 0
    rec_img_dir = ensure_dir(os.path.join(out, "handwritten_notes", "rec_line", split, "images"))

    for i, ln in enumerate(page.lines):
        x0, y0, w, h = place_line(canvas, ln.bitmap, ln.row, ln.col)
        det_lines.append(yolo_line(0, x0, y0, w, h, page.cols, page.rows))
        if cp.UNKNOWN_CHAR in ln.text:
            # 含未知编码的行：页面上有字形、框保留，但文本不可靠，不进入识别集
            rec_skipped += 1
            continue
        name = f"{stem}_l{i:02d}.png"
        Image.fromarray(ln.bitmap).save(os.path.join(rec_img_dir, name))
        rec_lines.append(f"{name}\t{ln.text}")

    scale = min(1.0, LINE_MAX_SIDE / max(page.rows, page.cols))
    img = Image.fromarray(canvas)
    if scale < 1.0:
        img = img.resize((round(page.cols * scale), round(page.rows * scale)), Image.LANCZOS)
    img_dir = ensure_dir(os.path.join(out, "handwritten_notes", "det_line", "images", split))
    lbl_dir = ensure_dir(os.path.join(out, "handwritten_notes", "det_line", "labels", split))
    img.save(os.path.join(img_dir, stem + ".jpg"), quality=JPEG_Q)
    with open(os.path.join(lbl_dir, stem + ".txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(det_lines) + "\n")
    # 识别标签旁路写入：整文件成功后才落盘，合并步骤据此生成 labels.txt。
    rec_lbl_dir = ensure_dir(os.path.join(out, "handwritten_notes", "rec_line", split, "labels"))
    with open(os.path.join(rec_lbl_dir, stem + ".txt"), "w", encoding="utf-8") as f:
        f.write("".join(line + "\n" for line in rec_lines))  # 无可用行时写空文件，合并时不产生空行
    return {"lines": len(page.lines), "rec_skipped": rec_skipped}


def load_manifest(path, params):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            m = json.load(f)
        if m.get("params") != params:
            raise SystemExit(f"manifest 参数与当前不一致，请换输出目录或删除 {path}")
        return m
    return {"params": params, "files": {}, "classes": {}}


def save_manifest(path, m):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(m, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def write_yaml(path, root, names):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [f"path: {root.replace(os.sep, '/')}", "train: images/train", "val: images/val", "names:"]
    lines += [f"  {i}: {n}" for i, n in enumerate(names)]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def finalize(out, manifest):
    """合并识别标签、写 classes.json 与 data.yaml（可重复执行）。"""
    for split in ("train", "val"):
        rec_dir = ensure_dir(os.path.join(out, "handwritten_notes", "rec_line", split))
        parts = sorted(glob(os.path.join(rec_dir, "labels", "*.txt")))
        with open(os.path.join(rec_dir, "labels.txt"), "w", encoding="utf-8") as dst:
            for p in parts:
                with open(p, encoding="utf-8") as src:
                    dst.write(src.read())
    with open(os.path.join(out, "char_cls", "classes.json"), "w", encoding="utf-8") as f:
        json.dump(dict(sorted(manifest["classes"].items())), f, ensure_ascii=False, indent=1)
    write_yaml(os.path.join(out, "yolo_handwriting_char", "data.yaml"),
               os.path.join(out, "yolo_handwriting_char"), ["char"])
    write_yaml(os.path.join(out, "handwritten_notes", "det_line", "data.yaml"),
               os.path.join(out, "handwritten_notes", "det_line"), ["line"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--limit", type=int, default=0, help="只处理前 N 个源文件（试跑）")
    args = ap.parse_args()
    src, out = os.path.abspath(args.src), os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    gnt = sorted(glob(os.path.join(src, "Gnt", "*.gnt")))
    dgrl = [(s, p) for s in SERIES for p in sorted(glob(os.path.join(src, s, "*.dgrl")))]
    splits = writer_splits(gnt + [p for _, p in dgrl])
    params = {"seed": SEED, "val_ratio": VAL_RATIO, "chars_per_page": CHARS_PER_PAGE,
              "char_page": CHAR_PAGE, "line_max_side": LINE_MAX_SIDE}
    manifest_path = os.path.join(out, "manifest.json")
    manifest = load_manifest(manifest_path, params)

    jobs = [("gnt", None, p) for p in gnt] + [("dgrl", s, p) for s, p in dgrl]
    done = 0
    for kind, series, path in jobs:
        rel = os.path.relpath(path, src).replace("\\", "/")
        if manifest["files"].get(rel, {}).get("status") == "ok":
            continue
        split = splits[cp.writer_id(path)]
        try:
            if kind == "gnt":
                info = process_gnt(path, split, out, manifest["classes"])
            else:
                info = process_dgrl(path, series, split, out)
            manifest["files"][rel] = {"status": "ok", "split": split, **info}
        except Exception as exc:  # 单文件失败不中断整批，记录后继续
            manifest["files"][rel] = {"status": "error", "split": split,
                                      "error": f"{type(exc).__name__}: {exc}"}
            print(f"[error] {rel}: {exc}", flush=True)
        done += 1
        if done % 50 == 0:
            save_manifest(manifest_path, manifest)
            print(f"[progress] {done} files, last={rel}", flush=True)
        if args.limit and done >= args.limit:
            break

    save_manifest(manifest_path, manifest)
    finalize(out, manifest)
    ok = sum(1 for v in manifest["files"].values() if v["status"] == "ok")
    err = sum(1 for v in manifest["files"].values() if v["status"] == "error")
    print(f"[done] ok={ok} error={err} classes={len(manifest['classes'])}", flush=True)


if __name__ == "__main__":
    main()
