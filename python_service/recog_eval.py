# -*- coding: utf-8 -*-
"""识别消融评测：冻结评测集（人工确认行）+ A/B/C 三档对比。

回答"最终识别准确率里，训练的模型和链路里的代码各贡献了多少"：

- A 裸模型·整行读法：确认行框直接喂 Kraken 整行序列读法，不过任何
  切分/修正代码——模型的"纯血"能力。
- B 像素切分+逐框读法：纯连通域切框（n=0，不做数量校验/网格兜底）
  后逐框识别，不做标点拆分、错位修复与融合仲裁——切分+喂法的贡献
  （读法外扩属于喂法，保留）。
- C 现状全链路：kraken_segment_line 单行全链路（行框外扩+切分+标点
  拆分+错位修复+融合仲裁）——现状能力。

读数：A−B = 切分+逐框喂法的贡献；B−C = 修正代码的贡献（负数 = 代码
在帮倒忙）。三档共用同一批 GT 行框、同一个当前启用的 Kraken 模型——
变量只有链路代码；版面/行检测层的对比由模型对比页既有 IoU 模式承担。

评测集从书库中"人工完全确认"的行冻结抽样（models/eval_set.json），
跨训练轮次可比，重建需显式触发；每次运行结果存 models/eval_runs/。
"""
import difflib
import json
import os
import time
from collections import Counter
from typing import Any

SERVICE_DIR = os.path.dirname(os.path.abspath(__file__))
EVAL_SET_PATH = os.path.join(SERVICE_DIR, "models", "eval_set.json")
EVAL_RUNS_DIR = os.path.join(SERVICE_DIR, "models", "eval_runs")

TIER_LABELS = {
    "a": "A 裸模型·整行读法",
    "b": "B 像素切分+逐框读法",
    "c": "C 全链路（现状）",
}

# 标点/句读符号：这些字符上的替换/漏字/多字单独计数（不收 ○——它同时
# 是古籍圈点又是常见的"未识别占位"，收进来会把两类错误混在一起）。
_PUNCT_CHARS = set(
    "、。，；：？！…—·～「」『』《》〈〉（）【】〔〕"
    ".,;:?!\"'()[]{}"
)


def _is_punct(ch: str) -> bool:
    return ch in _PUNCT_CHARS


def _log(msg: str) -> None:
    # [model-use] 前缀会被模型对比页的过程日志面板按关键字捕获。
    print(f"[model-use] {msg}", flush=True)


# ---------------------------------------------------------------------------
# 指标纯函数
# ---------------------------------------------------------------------------

def align_errors(gt: str, pred: str) -> dict[str, Any]:
    """GT 与预测的差异明细：替换/漏字/多字计数 + 错字对（混淆）计数。

    difflib 对齐（autojunk=False，避免重复文本被折叠出怪对齐）；
    replace 块内按下标配对、多出部分计为漏/多。edits = sub+del+ins，
    cer 由调用方按 edits / len(gt) 计算——同一个口径，逐行与聚合一致。
    标点错误：替换对任一侧、漏字/多字的涉事字符落在标点集合即计一次。
    """
    sub = dele = ins = punct = 0
    confusions: Counter = Counter()
    matcher = difflib.SequenceMatcher(None, gt, pred, autojunk=False)
    for op, i1, i2, j1, j2 in matcher.get_opcodes():
        if op == "equal":
            continue
        if op == "replace":
            n_pair = min(i2 - i1, j2 - j1)
            for k in range(n_pair):
                g, p = gt[i1 + k], pred[j1 + k]
                confusions[(g, p)] += 1
                if _is_punct(g) or _is_punct(p):
                    punct += 1
            sub += n_pair
            dele += (i2 - i1) - n_pair
            ins += (j2 - j1) - n_pair
            punct += sum(1 for ch in gt[i1 + n_pair:i2] if _is_punct(ch))
            punct += sum(1 for ch in pred[j1 + n_pair:j2] if _is_punct(ch))
        elif op == "delete":
            dele += i2 - i1
            punct += sum(1 for ch in gt[i1:i2] if _is_punct(ch))
        elif op == "insert":
            ins += j2 - j1
            punct += sum(1 for ch in pred[j1:j2] if _is_punct(ch))
    return {
        "sub": sub,
        "del": dele,
        "ins": ins,
        "edits": sub + dele + ins,
        "punct_errors": punct,
        "confusions": confusions,
    }


def cer_for(gt: str, pred: str) -> float | None:
    """单行字错误率：edits / len(gt)；GT 为空返回 None（不计入）。"""
    if not gt:
        return None
    return align_errors(gt, pred)["edits"] / len(gt)


def _tier_summary(label: str, results: list[dict], elapsed_s: float) -> dict:
    """聚合一档的全部行结果 {"gt","pred"} → 指标摘要。"""
    total_chars = sum(len(r["gt"]) for r in results)
    sub = dele = ins = punct = 0
    confusions: Counter = Counter()
    for r in results:
        e = align_errors(r["gt"], r["pred"])
        sub += e["sub"]
        dele += e["del"]
        ins += e["ins"]
        punct += e["punct_errors"]
        confusions.update(e["confusions"])
    edits = sub + dele + ins
    cer = (edits / total_chars) if total_chars else 0.0
    return {
        "label": label,
        "lines": len(results),
        "chars": total_chars,
        "sub": sub,
        "del": dele,
        "ins": ins,
        "edits": edits,
        "cer": round(cer, 4),
        "accuracy": round(max(0.0, 1.0 - cer), 4),
        "punct_errors": punct,
        "elapsed_s": round(elapsed_s, 1),
        "confusions": [
            {"gt": g, "pred": p, "count": c}
            for (g, p), c in confusions.most_common(10)
        ],
    }


def _delta(before: dict, after: dict, name: str) -> dict:
    """两档之间的差值：准确率升了多少（正=后一档更好）。"""
    return {
        "name": name,
        "cer_before": before["cer"],
        "cer_after": after["cer"],
        "cer_drop": round(before["cer"] - after["cer"], 4),
        "accuracy_gain": round(after["accuracy"] - before["accuracy"], 4),
        "punct_errors_before": before["punct_errors"],
        "punct_errors_after": after["punct_errors"],
    }


# ---------------------------------------------------------------------------
# 冻结评测集
# ---------------------------------------------------------------------------

def _book_settings(book_dir: str) -> dict:
    """书籍排版设置：orientation/horizontal_dir（缺省竖排/从左到右，
    与 Flutter 端 BookSettings 的默认一致）。"""
    try:
        with open(
            os.path.join(book_dir, "project.json"), "r", encoding="utf-8"
        ) as f:
            settings = json.load(f).get("settings") or {}
    except Exception:
        settings = {}
    return {
        "orientation": settings.get("orientation") or "vertical",
        "horizontal_dir": settings.get("horizontal_dir") or "ltr",
    }


def build_eval_set(project_dir: str, limit: int = 100) -> dict:
    """从书库确认行冻结抽样构建评测集，写入 models/eval_set.json。

    确认行复用 Kraken 训练导出同一取数口径（完全确认才算）；按
    (image_path, y, x) 稳定排序后均匀抽样——同一书库状态下重复构建
    得到同一批行，评测跨训练轮次可比。
    """
    import kraken_training

    books = kraken_training._all_book_dirs(project_dir)
    if not books:
        raise ValueError("书库中没有书籍（目录下需要 project.json）")
    rows: list[dict[str, Any]] = []
    total_confirmed = 0
    for book in books:
        lines = kraken_training._confirmed_lines(book)
        total_confirmed += len(lines)
        settings = _book_settings(book)
        for ln in lines:
            rows.append({**ln, "book_dir": book, **settings})
    if not rows:
        raise ValueError(
            "书库中没有人工完全确认的行——请先在编辑器里校对并「确认并保存」"
        )
    rows.sort(key=lambda r: (r["image_path"], r["y"], r["x"]))
    sampled = rows
    limit = max(1, int(limit))
    if len(rows) > limit:
        step = len(rows) / limit
        sampled = [rows[int(i * step)] for i in range(limit)]
    payload = {
        "built_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "total_confirmed": total_confirmed,
        "limit": limit,
        "books": sorted({os.path.basename(r["book_dir"]) for r in sampled}),
        "lines": sampled,
    }
    os.makedirs(os.path.dirname(EVAL_SET_PATH), exist_ok=True)
    with open(EVAL_SET_PATH, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    _log(
        f"recog_eval 评测集已冻结：{len(sampled)} 行"
        f"（确认行共 {total_confirmed}，来自 {len(payload['books'])} 本书）"
    )
    return payload


def load_eval_set() -> dict | None:
    """读取已冻结的评测集；不存在或为空返回 None。"""
    try:
        with open(EVAL_SET_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if data.get("lines") else None
    except Exception:
        return None


def eval_set_summary(data: dict) -> dict:
    return {
        "built_at": data.get("built_at"),
        "total_confirmed": data.get("total_confirmed"),
        "limit": data.get("limit"),
        "size": len(data.get("lines") or []),
        "books": data.get("books") or [],
    }


# ---------------------------------------------------------------------------
# 三档消融执行
# ---------------------------------------------------------------------------

def run_ablation(eval_set: dict) -> dict:
    """对冻结评测集逐行跑 A/B/C 三档并聚合指标（调用方持有识别串行门）。"""
    import kraken_bridge
    from segmenter import make_kraken_char_splitter

    items = eval_set.get("lines") or []
    if not items:
        raise ValueError("评测集为空——请先构建评测集")

    # 切分器按图缓存：mask 整页只算一次，同页多行复用。
    splitters: dict[str, Any] = {}

    def splitter_for(image_path: str, orientation: str, horizontal_dir: str):
        if image_path not in splitters:
            splitters[image_path] = make_kraken_char_splitter(
                image_path, orientation, horizontal_dir
            )
        return splitters[image_path]

    results: dict[str, list[dict]] = {"a": [], "b": [], "c": []}
    details: list[dict[str, Any]] = []
    elapsed = {"a": 0.0, "b": 0.0, "c": 0.0}
    skipped = 0
    n = len(items)
    for index, item in enumerate(items):
        if index % 10 == 0:
            _log(f"recog_eval 评测进度 {index + 1}/{n}")
        image_path = item.get("image_path") or ""
        gt = (item.get("text") or "").strip()
        if not os.path.exists(image_path) or not gt:
            skipped += 1
            continue
        rect = {
            "x": int(item["x"]),
            "y": int(item["y"]),
            "w": int(item["w"]),
            "h": int(item["h"]),
        }
        orientation = item.get("orientation") or "vertical"
        horizontal_dir = item.get("horizontal_dir") or "ltr"
        splitter = splitter_for(image_path, orientation, horizontal_dir)

        # A：裸模型整行读法——确认行框直喂，不外扩、不收紧、不切分。
        t0 = time.time()
        try:
            seq = kraken_bridge.recognize_lines(
                image_path, [rect], orientation, horizontal_dir
            )
            pred_a = (seq[0].get("text") or "").strip() if seq else ""
        except Exception as exc:
            _log(f"recog_eval A 档失败 index={index}: {exc}")
            pred_a = ""
        elapsed["a"] += time.time() - t0

        # B：纯连通域切框（n=0）+ 逐框读法，无标点拆分/错位修复/融合；
        # 切分失败（mask 不可用）如实计空文本——那就是"只有切分"的能力。
        t0 = time.time()
        try:
            boxes = splitter(rect, 0)
            if boxes:
                recs = kraken_bridge._recognize_char_boxes(
                    image_path, boxes, orientation, horizontal_dir
                )
                pred_b = "".join((r.get("text") or "").strip() for r in recs)
            else:
                pred_b = ""
        except Exception as exc:
            _log(f"recog_eval B 档失败 index={index}: {exc}")
            pred_b = ""
        elapsed["b"] += time.time() - t0

        # C：单行全链路（外扩+切分+标点拆分+错位修复+融合仲裁）。
        t0 = time.time()
        try:
            line = kraken_bridge.kraken_segment_line(
                image_path, rect, f"eval-{index}", index,
                orientation, horizontal_dir, None, splitter,
            )
            pred_c = (line.get("text") or "").strip()
        except Exception as exc:
            _log(f"recog_eval C 档失败 index={index}: {exc}")
            pred_c = ""
        elapsed["c"] += time.time() - t0

        for tier, pred in (("a", pred_a), ("b", pred_b), ("c", pred_c)):
            results[tier].append({"gt": gt, "pred": pred})
        details.append({
            "index": index,
            "image_path": image_path,
            "char_count": len(gt),
            "gt": gt,
            "preds": {"a": pred_a, "b": pred_b, "c": pred_c},
            "cer": {
                tier: cer_for(gt, pred)
                for tier, pred in (("a", pred_a), ("b", pred_b), ("c", pred_c))
            },
        })

    tiers = {
        tier: _tier_summary(TIER_LABELS[tier], results[tier], elapsed[tier])
        for tier in ("a", "b", "c")
    }
    output = {
        "tier_labels": TIER_LABELS,
        "eval_set": eval_set_summary(eval_set),
        "tiers": tiers,
        "deltas": {
            "a_to_b": _delta(tiers["a"], tiers["b"], "切分+逐框喂法"),
            "b_to_c": _delta(tiers["b"], tiers["c"], "修正代码"),
        },
        "skipped": skipped,
        "details": details,
        "elapsed_s": round(sum(elapsed.values()), 1),
    }
    _save_run(output)
    return output


def _save_run(result: dict) -> None:
    """运行结果留档 models/eval_runs/<时间戳>.json（跨训练轮次对比用）。"""
    try:
        os.makedirs(EVAL_RUNS_DIR, exist_ok=True)
        path = os.path.join(
            EVAL_RUNS_DIR, time.strftime("%Y%m%d_%H%M%S") + ".json"
        )
        with open(path, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False)
        result["run_path"] = path
    except Exception as exc:
        _log(f"recog_eval 运行结果留档失败: {exc}")


def last_run_summary() -> dict | None:
    """最近一次运行的关键指标（不含逐行明细）。"""
    try:
        names = sorted(n for n in os.listdir(EVAL_RUNS_DIR) if n.endswith(".json"))
    except Exception:
        return None
    for name in reversed(names):
        try:
            with open(
                os.path.join(EVAL_RUNS_DIR, name), "r", encoding="utf-8"
            ) as f:
                data = json.load(f)
        except Exception:
            continue
        tiers = data.get("tiers") or {}
        return {
            "saved_at": name[:-5],
            "eval_set": data.get("eval_set"),
            "tiers": {
                tier: {
                    key: t.get(key)
                    for key in ("lines", "chars", "cer", "accuracy",
                                "punct_errors", "elapsed_s")
                }
                for tier, t in tiers.items()
            },
        }
    return None
