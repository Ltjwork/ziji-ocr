# -*- coding: utf-8 -*-
"""朝代基准评测：固定古籍样张（先秦简→明清写本）× 当前识别管线的跨时期测试。

测试集放在仓库 `test_images/periods/`：样张图片 + `gt/*.json` 基准释文
（每个时期的原件书影一份，制作口径见该目录 README.md）。识别本身由
Flutter 端走既有整页识别链路（`PythonService.segmentWithSettings` =
/segment 版面+Kraken，与整本识别完全同路径）完成，并按阅读顺序拼好
文字后提交；本模块只做三件事：

1. 载入基准：读 `gt/*.json`，units 按序拼接为 gt_text。
2. 对齐评测：复用 `recog_eval.align_errors` 的口径（difflib 对齐，
   sub/del/ins + 混淆对）。评测前把两侧的空白与标点剥掉——基准释文
   无标点，预测里混入的标点/空白不应计为识别错误。
3. 落盘历史：`runs/run_<时间戳>.json`（含 BACKEND_BUILD、识别模型、
   每张样张的 GT/预测/指标），供下次测试时任选两次对比。

跨语言分工（互指声明，改格式需两边同步）：识别执行、阅读顺序与文字
拼接在 Dart 侧（dynasty_bench_page.dart 复用 ReadingOrderCalculator，
与编辑器/导出同源）；指标计算与历史落盘在 Python 侧（与 recog_eval
消融评测同源）。两边都不重复实现对方的职责。run 记录 JSON 的字段
基准以本文件为准（Dart 侧只读不写）。
"""
import hashlib
import json
import os
import re
import time
from typing import Any

import recog_eval
from api_base import BACKEND_BUILD
from kraken_proc import REC_MODEL
from registry_io import SERVICE_DIR

# 基准目录的仓库默认位置（Flutter 端从可执行文件向上探测同一相对路径，
# 探测不到时让用户手选；两边探测规则保持一致）。
DEFAULT_BENCH_DIR = os.path.normpath(
    os.path.join(SERVICE_DIR, "..", "test_images", "periods")
)

_WS_RE = re.compile(r"[\s\u3000]+")


def _normalize(text: str) -> str:
    """评测用归一：剥空白与标点（标点集合与 recog_eval 同源，不另立口径）。"""
    text = _WS_RE.sub("", text or "")
    return "".join(ch for ch in text if ch not in recog_eval._PUNCT_CHARS)


def load_cases(bench_dir: str) -> list[dict[str, Any]]:
    """读取 gt/*.json 基准样张清单，按 id 升序（01 先秦 → 05 明清）。"""
    gt_dir = os.path.join(bench_dir, "gt")
    if not os.path.isdir(gt_dir):
        raise FileNotFoundError(f"基准目录不存在或缺少 gt/ 子目录：{bench_dir}")
    cases = []
    for name in sorted(os.listdir(gt_dir)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(gt_dir, name), encoding="utf-8") as fh:
            data = json.load(fh)
        units = data.get("units") or []
        gt_text = "".join(u.get("text", "") for u in units)
        image = data.get("image", "")
        image_path = image if os.path.isabs(image) else os.path.join(bench_dir, image)
        cases.append(
            {
                "id": data.get("id", name[:-5]),
                "era": data.get("era", ""),
                "book": data.get("book", ""),
                "image": image,
                "image_path": image_path,
                "reading_order": data.get("reading_order", {})
                or {"orientation": "vertical", "horizontal_dir": "rtl", "vertical_dir": "ttb"},
                "units": units,
                "gt_text": gt_text,
                "gt_notes": data.get("gt_notes", ""),
                "gt_confidence": data.get("gt_confidence", ""),
                "punctuation_included": bool(data.get("punctuation_included", False)),
            }
        )
    return cases


def _file_stamp(path: str) -> dict[str, Any]:
    """模型的身份指纹：大小 + mtime + 首尾 64KB 哈希（够区分训练轮次，读取快）。"""
    try:
        st = os.stat(path)
        with open(path, "rb") as fh:
            head = fh.read(65536)
            fh.seek(max(0, st.st_size - 65536))
            tail = fh.read()
        digest = hashlib.sha1(head + b"|" + tail).hexdigest()[:16]
        return {
            "path": path,
            "size": st.st_size,
            "mtime": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(st.st_mtime)),
            "sha1_headtail": digest,
        }
    except OSError:
        return {"path": path, "missing": True}


def _model_info() -> dict[str, Any]:
    """本次运行背后的识别模型指纹：Kraken 识别模型 + 自训 YOLO 各层 active。"""
    info: dict[str, Any] = {"kraken_rec": _file_stamp(str(REC_MODEL))}
    registry_path = os.path.join(SERVICE_DIR, "models", "registry.json")
    try:
        with open(registry_path, encoding="utf-8") as fh:
            layers = (json.load(fh).get("layers") or {})
        for layer in ("line_det", "char_det", "char_cls"):
            if layers.get(layer, {}).get("active"):
                info[layer] = _file_stamp(layers[layer]["active"])
    except (OSError, ValueError):
        pass
    return info


def _case_report(case: dict[str, Any], pred: dict[str, Any]) -> dict[str, Any]:
    gt_norm = _normalize(case["gt_text"])
    pred_norm = _normalize(pred.get("pred_text", ""))
    if pred.get("error"):
        # 识别失败（超时/后端不可达/管线异常）：计入运行记录但不算指标，
        # 聚合里跳过该样张并显式标出，避免把故障错当 0 分。
        return {
            "id": case["id"],
            "era": case["era"],
            "book": case["book"],
            "image": case["image"],
            "gt_len": len(gt_norm),
            "pred_len": 0,
            "sub": 0,
            "del": 0,
            "ins": 0,
            "edits": 0,
            "cer": None,
            "accuracy": None,
            "line_count": pred.get("line_count"),
            "duration_ms": pred.get("duration_ms"),
            "top_confusions": [],
            "pred_text": "",
            "error": pred["error"],
        }
    errs = recog_eval.align_errors(gt_norm, pred_norm)
    edits = errs["sub"] + errs["del"] + errs["ins"]
    cer = edits / len(gt_norm) if gt_norm else None
    confusions = [
        [g, p, n]
        for (g, p), n in errs["confusions"].most_common(10)
    ]
    return {
        "id": case["id"],
        "era": case["era"],
        "book": case["book"],
        "image": case["image"],
        "gt_len": len(gt_norm),
        "pred_len": len(pred_norm),
        "sub": errs["sub"],
        "del": errs["del"],
        "ins": errs["ins"],
        "edits": edits,
        "cer": cer,
        "accuracy": (1.0 - cer) if cer is not None else None,
        "line_count": pred.get("line_count"),
        "duration_ms": pred.get("duration_ms"),
        "top_confusions": confusions,
        "pred_text": pred_norm,
        "error": None,
        # 人工查看用的字框明细（行框/字框/逐字置信度），格式基准在
        # Dart 侧（dynasty_bench_page._recognizeCase 产、
        # dynasty_bench_detail_page 消费），Python 只原样存档不解释。
        "lines": pred.get("lines"),
        # 管线元信息（engine/fallback_reason/converter/yolo 诊断 +
        # ai_assist 状态），见 api_bench.BenchPredItem 字段注释。
        "engine": pred.get("engine"),
        "fallback_reason": pred.get("fallback_reason"),
        "converter": pred.get("converter"),
        "yolo": pred.get("yolo"),
        "ai_assist": pred.get("ai_assist"),
    }


def evaluate(bench_dir: str, preds: list[dict[str, Any]]) -> dict[str, Any]:
    """对齐评测并落盘一次运行记录；preds 每项 {id, pred_text, line_count,
    duration_ms, error?}。返回完整运行记录（与落盘内容一致）。"""
    bench_dir = os.path.abspath(bench_dir)
    cases = {c["id"]: c for c in load_cases(bench_dir)}
    reports = []
    for pred in preds:
        case = cases.get(pred.get("id", ""))
        if case is None:
            raise KeyError(f"未知的样张 id：{pred.get('id')!r}（基准目录里没有对应 gt/*.json）")
        reports.append(_case_report(case, pred))

    scored = [r for r in reports if r["error"] is None]
    gt_total = sum(r["gt_len"] for r in scored)
    edit_total = sum(r["edits"] for r in scored)
    micro_cer = edit_total / gt_total if gt_total else None
    run_id = time.strftime("run_%Y%m%d_%H%M%S")
    record = {
        "run_id": run_id,
        "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
        "backend_build": BACKEND_BUILD,
        "bench_dir": bench_dir,
        "models": _model_info(),
        "cases": reports,
        "aggregate": {
            "cases_total": len(reports),
            "cases_scored": len(scored),
            "cases_failed": len(reports) - len(scored),
            "gt_len": gt_total,
            "edits": edit_total,
            # micro=按字数加权（整体水平），macro=样张等权（跨时期平均水位）。
            "cer": micro_cer,
            "accuracy": (1.0 - micro_cer) if micro_cer is not None else None,
            "macro_accuracy": (
                sum(r["accuracy"] for r in scored) / len(scored) if scored else None
            ),
            "duration_ms": sum(r.get("duration_ms") or 0 for r in reports),
        },
    }
    runs_dir = os.path.join(bench_dir, "runs")
    os.makedirs(runs_dir, exist_ok=True)
    out_path = os.path.join(runs_dir, f"{run_id}.json")
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(record, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, out_path)
    record["run_path"] = out_path
    return record


def list_runs(bench_dir: str, limit: int = 50) -> list[dict[str, Any]]:
    """历史运行摘要（新→旧），供对比选择；完整记录直接读 runs/*.json。"""
    runs_dir = os.path.join(bench_dir, "runs")
    if not os.path.isdir(runs_dir):
        return []
    out = []
    names = sorted(
        (n for n in os.listdir(runs_dir) if n.startswith("run_") and n.endswith(".json")),
        reverse=True,
    )[:limit]
    for name in names:
        try:
            with open(os.path.join(runs_dir, name), encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            continue
        out.append(
            {
                "run_id": rec.get("run_id", name[:-5]),
                "ts": rec.get("ts", ""),
                "backend_build": rec.get("backend_build", ""),
                "accuracy": rec.get("aggregate", {}).get("accuracy"),
                "macro_accuracy": rec.get("aggregate", {}).get("macro_accuracy"),
                "per_case": {
                    c.get("id"): {
                        "accuracy": c.get("accuracy"),
                        "error": c.get("error"),
                    }
                    for c in rec.get("cases", [])
                },
                "path": os.path.join(runs_dir, name),
            }
        )
    return out
