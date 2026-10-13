# -*- coding: utf-8 -*-
"""墨迹校验真实标注回测：用书库里已人工校对的页面统计误报率与命中率。

走 verify_chars_batch（整页批量 + 同字同伴互证），与编辑器「校验本页」
同一链路。分组口径（标注里没有"识别原始值"的历史，用代理信号）：
  A 应通过：status=confirmed 且 text 非空——人工看过并确认，当前文字
    无论机器读的还是改过的都应与墨迹匹配；此组标红比例即误报率。
  B 应拦截：candidates 非空且 text != 候选首选——人工选了非首选/手输，
    说明识别首选是错的；此组（按首选字校验）标红比例即命中率。
  C 参考：conf < 0.6 的字（低置信识别，供对照，无绝对真值）。

默认不传 status 给后端（模拟"整页尚未人工确认"的生产常态，同伴互证
只靠多数簇）；--with-status 传入 status（A 组字成为同伴锚，衡量"页面
已有部分人工确认"时的上限收益）。B 组恒不作为锚（其校验文字是被否决
的识别首选，不是人工确认的真值）。

用法：
  conda run -n paddle python tool_verify_backtest.py [项目目录] [最大页数]
      [--with-status] [--dump 目录]
不传项目目录时回测书库下全部有标注的项目（每项目抽样 max_pages 页）。
"""

import argparse
import json
import os
import time
from collections import Counter

import numpy as np

import char_verify

LIB_ROOT = r"C:\Users\LLLL\Documents\GujiBT"
MAX_PAGES_DEFAULT = 40


class _Blk:
    """tool 侧字块：属性访问与 main.VerifyCharItem 同形。"""

    def __init__(self, d: dict, status: str | None):
        self.id = d.get("uid") or d.get("id") or f"{d['x']}_{d['y']}"
        self.x, self.y, self.w, self.h = d["x"], d["y"], d["w"], d["h"]
        self.text = d.get("text") or ""
        self.conf = d.get("conf")
        self.status = status


def load_blocks(page_json_path: str):
    try:
        with open(page_json_path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as exc:
        print(f"  [skip] {os.path.basename(page_json_path)}: {exc}")
        return None
    image_path = data.get("image_path") or ""
    if not image_path or not os.path.exists(image_path):
        print(f"  [skip] {os.path.basename(page_json_path)}: image missing")
        return None
    return image_path, data.get("blocks", [])


def classify(block: dict) -> str | None:
    """A=应通过(confirmed) B=应拦截(改过首选) C=低置信参考。"""
    text = (block.get("text") or "").strip()
    if block.get("type") != "main_text":
        return None
    candidates = block.get("candidates") or []
    if block.get("status") == "confirmed" and text:
        return "A"
    if candidates and text and text != candidates[0].get("text"):
        return "B"
    conf = block.get("conf")
    if conf is not None and conf < 0.6 and text:
        return "C"
    return None


def backtest_project(project_dir: str, max_pages: int,
                     with_status: bool = False,
                     dump_root: str | None = None,
                     use_templates: bool = False) -> dict:
    ann_dir = os.path.join(project_dir, "annotations")
    if not os.path.isdir(ann_dir):
        return {}
    pages = sorted(
        f for f in os.listdir(ann_dir)
        if f.startswith("page_") and f.endswith(".json"))
    if len(pages) > max_pages:
        step = len(pages) / max_pages
        pages = [pages[int(i * step)] for i in range(max_pages)]
    stats = {"A": Counter(), "B": Counter(), "C": Counter()}
    adjusted = Counter()
    samples = {"A": [], "B": []}
    dumped = {"A": 0, "B": 0}
    total, started = 0, time.time()

    # 模板评测（leave-one-page-out）：各页确认字的模板先全部算好，校验
    # 某页时只挂"其他页"的模板——同页模板会把"已确认字应通过"测成恒真
    # （生产首刷页本来就没有本页确认字，这才是要测的口径）。
    page_templates: dict[str, list] = {}
    if use_templates:
        import verify_templates as vt
        for name in pages:
            loaded = load_blocks(os.path.join(ann_dir, name))
            if loaded is None:
                continue
            image_path, blocks = loaded
            mask = char_verify._text_mask_for_refinement(image_path)
            if mask is None:
                continue
            entries = []
            for d in blocks:
                t = (d.get("text") or "").strip()
                if (d.get("status") != "confirmed" or len(t) != 1
                        or d.get("type") != "main_text"):
                    continue
                glyph = char_verify._glyph_features(t)
                if glyph is None:
                    continue
                ink, _r = char_verify._crop_ink(
                    mask, (d["x"], d["y"], d["w"], d["h"]))
                if ink is None:
                    continue
                entries.append(
                    (t, char_verify._prepare(ink, target_w=glyph[4])))
            page_templates[name] = entries
        real_load = vt.load

        def _patched_load(_project_dir, _cache={}):
            return _cache.get("lib") or {}

    for name in pages:
        loaded = load_blocks(os.path.join(ann_dir, name))
        if loaded is None:
            continue
        image_path, blocks = loaded
        classify_map, send = {}, []
        for d in blocks:
            group = classify(d)
            if group is None:
                continue
            # B 组按"被否决的识别首选"校验（那才是识别错误的字）；
            # B 组不作为同伴锚（校验文字非人工真值），A 组默认也不传
            # （生产常态），--with-status 时 A 组作为锚。
            verify_text = (
                (d.get("candidates") or [{}])[0].get("text", "")
                if group == "B" else (d.get("text") or ""))
            blk = _Blk({**d, "text": verify_text},
                       d.get("status") if (with_status and group == "A")
                       else None)
            send.append(blk)
            classify_map[blk.id] = (group, d)
        if not send:
            continue
        lib_cache = {}
        if use_templates:
            entries = [e for other, lst in page_templates.items()
                       if other != name for e in lst]
            lib = {}
            for ch, canvas in entries:
                arr = (canvas > 0).astype(np.uint8) * 255
                e = lib.setdefault(ch, {"canvas": [], "skel": []})
                e["canvas"].append(arr)
                e["skel"].append(char_verify._skeleton(arr))
            lib_cache["lib"] = {
                ch: {"canvas": np.stack(v["canvas"]),
                     "skel": np.stack(v["skel"])}
                for ch, v in lib.items()}
            vt.load = lambda pd: _patched_load(pd, lib_cache)
        try:
            out = char_verify.verify_chars_batch(
                image_path, send, project_dir=project_dir)
        except Exception as exc:
            print(f"  [skip] {name}: batch failed: {exc}")
            continue
        finally:
            if use_templates:
                vt.load = real_load
        for bid, res in out.get("results", {}).items():
            group, d = classify_map.get(bid, (None, None))
            if group is None:
                continue
            level = res["level"]
            stats[group][level] += 1
            total += 1
            peer = res.get("peer") or {}
            if peer.get("adjusted"):
                adjusted[f"{group}:{peer['adjusted']}"] += 1
            flagged = level in ("mismatch", "suspect")
            if (group == "A" and not flagged
                    and len(samples["A"]) < 5):
                samples["A"].append(("LOWEST-PASS", res.get("text"),
                                     res["score"]))
            if (group == "B" and len(samples["B"]) < 8):
                samples["B"].append(
                    ("HIT" if flagged else "MISS",
                     f'{res.get("text")}->{(d.get("text") or "").strip()}',
                     res["score"]))
            if (dump_root and bid in out.get("errors", {})):
                continue
            if (dump_root and dumped[group] < 15 and (
                    (group == "A" and flagged)
                    or (group == "B" and not flagged))):
                try:
                    dbg = char_verify.verify_char(
                        image_path,
                        (classify_map[bid][1]["x"], classify_map[bid][1]["y"],
                         classify_map[bid][1]["w"], classify_map[bid][1]["h"]),
                        res.get("text") or "", debug=True)
                    img = dbg.get("debug_image_b64")
                    if img:
                        import base64
                        tag = "FP" if group == "A" else "MISS"
                        path = os.path.join(
                            dump_root,
                            f"{tag}_{name}_{bid}_{res.get('text')}"
                            f"_{res['score']}.png")
                        with open(path, "wb") as f:
                            f.write(base64.b64decode(img))
                        dumped[group] += 1
                except Exception:
                    pass
    elapsed = time.time() - started
    return {
        "pages": len(pages), "chars": total, "stats": stats,
        "adjusted": adjusted, "samples": samples,
        "elapsed_s": round(elapsed, 1),
    }


def report(name: str, result: dict) -> None:
    if not result:
        return
    print(f"\n===== {name} =====")
    print(f"pages={result['pages']} chars={result['chars']} "
          f"elapsed={result['elapsed_s']}s")
    for group, label in (("A", "A 应通过(confirmed)"),
                         ("B", "B 应拦截(改过首选)"),
                         ("C", "C 参考(conf<0.6)")):
        c = result["stats"][group]
        total = sum(c.values())
        if not total:
            continue
        flagged = c["mismatch"] + c["suspect"]
        rate = flagged / total * 100
        extra = (f" 误报率={rate:.1f}%" if group == "A"
                 else f" 命中率={rate:.1f}%" if group == "B"
                 else f" 标红比例={rate:.1f}%")
        print(f"{label}: n={total} {dict(c)}{extra}")
    if result["adjusted"]:
        print(f"  同伴调整: {dict(result['adjusted'])}")
    for tag, s in result["samples"].items():
        if s:
            print(f"  样本[{tag}]: {s}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("project", nargs="?", default=None)
    ap.add_argument("max_pages", nargs="?", type=int,
                    default=MAX_PAGES_DEFAULT)
    ap.add_argument("--with-status", action="store_true",
                    help="A 组字作为同伴锚（衡量有人工确认时的上限）")
    ap.add_argument("--dump", default=None,
                    help="误判样本（A 组标红/B 组漏网）四联图导出目录")
    ap.add_argument("--mismatch", type=float, default=None,
                    help="覆盖 MISMATCH_SCORE（标定扫描用）")
    ap.add_argument("--suspect", type=float, default=None,
                    help="覆盖 SUSPECT_SCORE（标定扫描用）")
    ap.add_argument("--peer-vs", type=float, default=None,
                    help="覆盖 PEER_VERY_STRONG（标定扫描用）")
    ap.add_argument("--cls-shift", type=float, default=None,
                    help="覆盖 CLS_SHIFT（0=关闭 char_cls 融合）")
    ap.add_argument("--pair-weight", type=float, default=None,
                    help="覆盖 W_PAIR（0=关闭 learned 比对层）")
    ap.add_argument("--templates", action="store_true",
                    help="启用跨页模板互证评测（leave-one-page-out 口径）")
    ap.add_argument("--tpl-strong", type=float, default=None,
                    help="覆盖 TEMPLATE_STRONG（模板救回门槛扫描）")
    ap.add_argument("--learned-high", type=float, default=None,
                    help="覆盖 LEARNED_HIGH（非对称救回线扫描）")
    args = ap.parse_args()
    if args.mismatch is not None:
        char_verify.MISMATCH_SCORE = args.mismatch
    if args.suspect is not None:
        char_verify.SUSPECT_SCORE = args.suspect
    if args.peer_vs is not None:
        char_verify.PEER_VERY_STRONG = args.peer_vs
    if args.cls_shift is not None:
        char_verify.CLS_SHIFT = args.cls_shift
    if args.pair_weight is not None:
        char_verify.W_PAIR = args.pair_weight
    if args.tpl_strong is not None:
        char_verify.TEMPLATE_STRONG = args.tpl_strong
    if args.learned_high is not None:
        char_verify.LEARNED_HIGH = args.learned_high
    if args.project and os.path.isdir(args.project):
        projects = [args.project]
    else:
        projects = [
            os.path.join(LIB_ROOT, d) for d in sorted(os.listdir(LIB_ROOT))
            if os.path.isdir(os.path.join(LIB_ROOT, d, "annotations"))]
    for project_dir in projects:
        with open(os.path.join(project_dir, "project.json"),
                  encoding="utf-8") as f:
            name = json.load(f).get("name", os.path.basename(project_dir))
        result = backtest_project(project_dir, args.max_pages,
                                  with_status=args.with_status,
                                  dump_root=args.dump,
                                  use_templates=args.templates)
        report(name, result)


if __name__ == "__main__":
    main()
