# -*- coding: utf-8 -*-
"""独立训练进程：由 training_service / verify_training 以子进程方式启动。

用法:
  python train_worker.py --task detect   --data <data.yaml> --base yolov8s.pt ...
  python train_worker.py --task classify --data <dataset_dir> --base yolov8n-cls.pt ...
  python train_worker.py --task siamese  --data <verify_pair 数据集目录> ...

产物:
  detect/classify: <run_dir>/train/weights/best.pt（ultralytics）
  siamese:         <run_dir>/best.pt（纯 torch 双塔，见 verify_model）
  <run_dir>/done.json               {best, metrics, epochs, checkpoints}
  stdout/stderr → <run_dir>/train_log.txt（由父进程重定向）
"""
import argparse
import csv
import json
import os
import re
import sys
import traceback


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--task", choices=["detect", "classify", "siamese"],
                        required=True)
    parser.add_argument("--data", required=True)
    parser.add_argument("--base", default="yolov8s.pt")
    parser.add_argument("--epochs", type=int, default=150)
    parser.add_argument("--imgsz", type=int, default=1280)
    parser.add_argument("--batch", type=int, default=-1)
    parser.add_argument(
        "--device",
        default="auto",
        help="训练设备：auto（有 GPU 自动用）| cpu | cuda",
    )
    parser.add_argument(
        "--save-period",
        type=int,
        default=0,
        help="每 N 轮保存一次中间检查点 epoch{N}.pt（0=不保存），"
             "供按曲线挑中间模型/判别过拟合",
    )
    parser.add_argument("--run-dir", required=True)
    args = parser.parse_args()

    # Windows 下先注册 CUDA DLL 目录（与识别服务同环境）
    service_dir = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, service_dir)
    import segmenter  # noqa: F401

    segmenter._preload_torch_for_windows()
    import torch

    # 显式选择训练设备；选了 cuda 但环境不支持（CPU 版 torch / 无显卡 /
    # 驱动异常）时给出可读错误，而不是 ultralytics 深处的栈回溯。
    device = None
    if args.device == "cpu":
        device = "cpu"
    elif args.device == "cuda":
        if not torch.cuda.is_available():
            print(
                f"[worker] 错误：选择了 CUDA 训练，但当前 PyTorch（{torch.__version__}）"
                "不支持 GPU。请确认识别服务环境已安装 CUDA 版 torch 且显卡驱动正常。",
                flush=True,
            )
            return 1
    elif args.device == "auto" and torch.cuda.is_available():
        device = 0

    if args.task == "siamese":
        return run_siamese(args, torch, device)

    from ultralytics import YOLO

    print(f"[worker] task={args.task} data={args.data} base={args.base} "
          f"epochs={args.epochs} imgsz={args.imgsz} batch={args.batch} "
          f"device={args.device} torch={torch.__version__}", flush=True)

    model = YOLO(args.base)
    train_kwargs = dict(
        data=args.data,
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        project=args.run_dir,
        name="train",
        exist_ok=True,
        verbose=True,
        plots=False,
    )
    if device is not None:
        train_kwargs["device"] = device
    if args.save_period > 0:
        # ultralytics 语义：>0 时每 N 轮向 weights/ 写一个独立 epoch{N}.pt
        train_kwargs["save_period"] = args.save_period
    if args.task == "detect":
        # 古籍适配：拼图/翻转会制造不存在的版面，关闭
        train_kwargs.update(mosaic=0.0, flipud=0.0, fliplr=0.0, degrees=0.5, scale=0.1)
    else:
        train_kwargs.update(mosaic=0.0, erasing=0.0)

    model.train(**train_kwargs)

    best = os.path.join(args.run_dir, "train", "weights", "best.pt")
    metrics = _read_metrics(os.path.join(args.run_dir, "train", "results.csv"))
    done = {"best": best if os.path.exists(best) else None,
            "metrics": metrics, "epochs": args.epochs,
            "checkpoints": list_checkpoints(
                os.path.join(args.run_dir, "train", "weights"))}
    with open(os.path.join(args.run_dir, "done.json"), "w", encoding="utf-8") as f:
        json.dump(done, f, ensure_ascii=False, indent=2)
    print(f"[worker] done: {done}", flush=True)
    return 0 if done["best"] else 1


def run_siamese(args, torch, device) -> int:
    """墨迹比对模型（双塔）训练：正/负图对 → 余弦相似度 BCE。

    在线增强只作用于墨迹侧（推理时墨迹才有风格差异；字形侧是参照）：
    微旋转 ±4°、等比缩放 0.94-1.06、平移 ±3px、笔宽抖动（膨胀/腐蚀）。
    逐 epoch 写 results.csv（epoch,train_loss,val_loss,val_auc）供进度
    轮询；val AUC 最优的权重存 <run_dir>/best.pt。"""
    import cv2
    import numpy as np
    from verify_model import PairEncoder

    torch.manual_seed(42)
    np.random.seed(42)

    data_dir = args.data
    with open(os.path.join(data_dir, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    pairs = manifest["pairs"]
    train_pairs = [p for p in pairs if p["split"] == "train"]
    val_pairs = [p for p in pairs if p["split"] == "val"]
    if not train_pairs or not val_pairs:
        print(f"[siamese] train/val 必须非空（train={len(train_pairs)} "
              f"val={len(val_pairs)}），拒绝训练", flush=True)
        return 1
    print(f"[siamese] data={data_dir} pairs train={len(train_pairs)} "
          f"val={len(val_pairs)} epochs={args.epochs} batch={args.batch} "
          f"device={device} torch={torch.__version__}", flush=True)

    def load_img(rel: str) -> np.ndarray:
        arr = cv2.imdecode(
            np.fromfile(os.path.join(data_dir, rel), dtype=np.uint8),
            cv2.IMREAD_GRAYSCALE)
        return (arr > 0).astype(np.float32)

    cache: dict[str, np.ndarray] = {}

    def cached(rel: str) -> np.ndarray:
        if rel not in cache:
            cache[rel] = load_img(rel)
        return cache[rel]

    def augment(img: np.ndarray) -> np.ndarray:
        # 温和增强：首版用 ±4°/±3px/3×3 方核宽抖动，过强（3×3 核对 4px
        # 笔画宽改变 ±50%、腐蚀可断细笔），模型只能死记实例（val AUC
        # 0.66）；v2 收敛到 ±3°/±2px/十字单像素核、低概率宽抖动。
        h, w = img.shape
        m = cv2.getRotationMatrix2D(
            (w / 2, h / 2),
            float(np.random.uniform(-3.0, 3.0)),
            float(np.random.uniform(0.95, 1.05)))
        m[0, 2] += float(np.random.uniform(-2.0, 2.0))
        m[1, 2] += float(np.random.uniform(-2.0, 2.0))
        out = cv2.warpAffine(img, m, (w, h), flags=cv2.INTER_NEAREST)
        cross = np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]], np.uint8)
        r = np.random.rand()
        if r < 0.12:
            out = cv2.dilate(out, cross)
        elif r < 0.24:
            out = cv2.erode(out, cross)
        return out

    model = PairEncoder()
    if device is not None:
        model = model.to(device)
    opt = torch.optim.Adam(model.parameters(), lr=5e-4, weight_decay=1e-4)
    n_pos = sum(1 for p in train_pairs if p["label"] == 1)
    n_neg = max(1, len(train_pairs) - n_pos)
    pos_weight = torch.tensor(min(4.0, n_neg / max(1, n_pos)),
                              dtype=torch.float32,
                              device=device if device is not None else "cpu")
    bce = torch.nn.BCEWithLogitsLoss(pos_weight=pos_weight)
    LOGIT_SCALE = 5.0  # 余弦 ∈ [-1,1] 拉伸为 logit 尺度（±1 → ±5）

    def to_batch(imgs, glyphs):
        ink = np.stack(imgs)[:, None, :, :]
        gl = np.stack(glyphs)[:, None, :, :]
        t_ink = torch.from_numpy(ink)
        t_gl = torch.from_numpy(gl)
        if device is not None:
            t_ink, t_gl = t_ink.to(device), t_gl.to(device)
        return t_ink, t_gl

    def run_set(batch_pairs, train: bool):
        model.train(train)
        total_loss, sims, labels = 0.0, [], []
        order = np.random.permutation(len(batch_pairs)) if train \
            else np.arange(len(batch_pairs))
        bs = max(16, args.batch)
        for s in range(0, len(order), bs):
            chunk = [batch_pairs[k] for k in order[s:s + bs]]
            ink, gl, y = [], [], []
            for p in chunk:
                img = cached(p["ink"])
                ink.append(augment(img) if train else img)
                gl.append(cached(p["glyph"]))
                y.append(float(p["label"]))
            t_ink, t_gl = to_batch(ink, gl)
            sim = (model(t_ink) * model(t_gl)).sum(dim=1)
            logit = sim * LOGIT_SCALE
            target = torch.tensor(y, dtype=torch.float32,
                                  device=logit.device)
            loss = bce(logit, target)
            if train:
                opt.zero_grad()
                loss.backward()
                opt.step()
            total_loss += float(loss) * len(chunk)
            sims.extend(sim.detach().cpu().numpy().tolist())
            labels.extend(y)
        return total_loss / max(1, len(order)), np.array(sims), \
            np.array(labels)

    def auc(sims, labels) -> float:
        pos = sims[labels == 1]
        neg = sims[labels == 0]
        if not len(pos) or not len(neg):
            return 0.5
        order = np.argsort(sims)
        ranks = np.empty_like(order, dtype=np.float64)
        ranks[order] = np.arange(1, len(sims) + 1)
        # 同分取平均秩（简并：二值相似度下同分大量存在）
        rp = ranks[labels == 1].sum()
        return float((rp - len(pos) * (len(pos) + 1) / 2.0)
                     / (len(pos) * len(neg)))

    csv_path = os.path.join(args.run_dir, "results.csv")
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        f.write("epoch,train_loss,val_loss,val_auc\n")
    best_auc, best_path = -1.0, None
    for epoch in range(1, args.epochs + 1):
        tr_loss, _, _ = run_set(train_pairs, train=True)
        with torch.no_grad():
            va_loss, sims, labels = run_set(val_pairs, train=False)
        va_auc = auc(sims, labels)
        with open(csv_path, "a", encoding="utf-8", newline="") as f:
            f.write(f"{epoch},{tr_loss:.4f},{va_loss:.4f},{va_auc:.4f}\n")
        print(f"[siamese] epoch {epoch}/{args.epochs} "
              f"train_loss={tr_loss:.4f} val_loss={va_loss:.4f} "
              f"val_auc={va_auc:.4f}", flush=True)
        if va_auc > best_auc:
            best_auc = va_auc
            best_path = os.path.join(args.run_dir, "best.pt")
            torch.save(model, best_path)
    done = {"best": best_path,
            "metrics": {"val_auc": round(best_auc, 4)},
            "epochs": args.epochs}
    with open(os.path.join(args.run_dir, "done.json"), "w",
              encoding="utf-8") as f:
        json.dump(done, f, ensure_ascii=False, indent=2)
    print(f"[siamese] done: {done}", flush=True)
    return 0 if best_path else 1


def list_checkpoints(weights_dir: str) -> list:
    """扫描 weights 目录：best/last + save_period 存的 epoch{N}.pt。

    返回按 epoch 升序（best/last 排最后）的
    [{name, epoch, path, size, mtime}]，epoch 为 None 表示非轮数检查点。
    训练 worker 写 done.json 与 /train/curve 接口共用这份清单。"""
    out = []
    if not os.path.isdir(weights_dir):
        return out
    for name in os.listdir(weights_dir):
        if not name.endswith(".pt"):
            continue
        match = re.fullmatch(r"epoch(\d+)\.pt", name)
        if match:
            epoch: int | None = int(match.group(1))
        elif name in ("best.pt", "last.pt"):
            epoch = None
        else:
            continue
        path = os.path.join(weights_dir, name)
        try:
            out.append({"name": name, "epoch": epoch, "path": path,
                        "size": os.path.getsize(path),
                        "mtime": os.path.getmtime(path)})
        except OSError:
            continue
    out.sort(key=lambda c: (c["epoch"] is None, c["epoch"] or 0, c["name"]))
    return out


def _read_metrics(csv_path: str) -> dict:
    """从 results.csv 最后一行取关键指标。"""
    if not os.path.exists(csv_path):
        return {}
    try:
        with open(csv_path, encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        if not rows:
            return {}
        last = rows[-1]
        picked = {}
        for key, value in last.items():
            key = (key or "").strip()
            if key in (
                "metrics/mAP50(B)", "metrics/mAP50-95(B)",
                "metrics/precision(B)", "metrics/recall(B)",
                "metrics/accuracy_top1", "metrics/accuracy_top5",
            ):
                try:
                    picked[key] = round(float(value), 4)
                except (TypeError, ValueError):
                    pass
        return picked
    except Exception:
        return {}


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(2)
