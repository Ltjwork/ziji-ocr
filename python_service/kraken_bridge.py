"""服务 ↔ Kraken 环境的桥接。

kraken 及 CHAT 模型装在独立的 conda 环境（见 install_kraken.bat），主服务
通过常驻子进程 kraken_worker.py（daemon 模式）与之通信，避免两套
torch 依赖互相污染，也避免每次识别重付进程启动 + 模型加载。
本模块只依赖标准库。

集成架构：版面/行/字框由 YOLO 自训模型或 OpenCV 投影切分给出，全部
识别文本用 Kraken CHAT 模型（混合模式）。
"""
# 本文件是门面（facade）：实现已按职责拆分到 kraken_proc, kraken_boxes，此处 re-export 保持既有 import 面不变。
from __future__ import annotations
import json
import os
import queue
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path
import numpy as np
from kraken_proc import log





def text_direction(orientation: str, horizontal_dir: str) -> str:
    if orientation == "horizontal":
        return "horizontal-rl" if horizontal_dir == "rtl" else "horizontal-lr"
    return "vertical-rl" if horizontal_dir == "rtl" else "vertical-lr"



class _KrakenEngineAdapter:
    """识别引擎适配器（kraken 默认实现，paddle 见 paddle_bridge）。

    识别管线（apply_recognition / segment_line_core）里所有"读字"的引擎
    触点集中在这一个对象上：整行序列读法（含横/竖排可达性）、逐字框读法、
    序列字框兜底来源与结果标记。kraken 路径不传 adapter 时用本类，行为与
    单引擎时代逐字节一致（read_lines/read_char_boxes 就是本模块原函数）。"""

    name = "kraken"
    ocr_tag = "kraken+chat_rec"
    char_source = "kraken+chat_rec"
    # 兜底字框来源标记：像素切分失败/不可信时改用整行读法附带的字框几何
    # （kraken 是 cuts 切位条带，paddle 是阅读轴均分条带）。
    cuts_src = "kraken-cuts"
    horizontal_line_read = False  # CHAT 无横排域：横排跳过整行序列读法
    vertical_line_read = True
    strip_read = False  # 竖排整行可直接读，无需"字框拼条"第二路
    skip_note = "CHAT 无横排域"

    def read_lines(
        self,
        image_path: str,
        line_rects: list[dict],
        orientation: str = "vertical",
        horizontal_dir: str = "rtl",
    ) -> list[dict]:
        return recognize_lines(
            image_path, line_rects, orientation, horizontal_dir
        )

    def read_char_boxes(
        self,
        image_path: str,
        boxes: list[tuple[int, int, int, int]],
        orientation: str,
        horizontal_dir: str,
        pad: bool = True,
    ) -> list[dict]:
        return _recognize_char_boxes(
            image_path, boxes, orientation, horizontal_dir, pad=pad
        )

    def read_strip_chars(
        self,
        image_path: str,
        rect: dict,
        boxes: list[tuple[int, int, int, int]],
        orientation: str,
        horizontal_dir: str,
    ) -> list[dict]:
        # strip_read=False 的引擎不会走到这里（竖排整行读法直接可得）。
        raise NotImplementedError("kraken 整行读法无需字框拼条")

    def read_line_full(
        self,
        image_path: str,
        rect: dict,
        orientation: str = "vertical",
        horizontal_dir: str = "rtl",
        vertical_dir: str = "ttb",
    ) -> dict:
        """整行全文直读（全文对照用）：单行框直接走与标注识别相同的逐行
        预处理+识别，不经字框切分——标点等没有字框的字符也会被读出。
        返回 {text, conf}。池未就绪时抛错（对照是增强路，调用方静默跳过；
        绝不在这里懒起池——单元测试/未预热环境不该被拖起 daemon）。"""
        pool = _pool
        if pool is None or pool.size <= 0:
            raise RuntimeError("kraken 池未就绪，跳过全文对照")
        return pool.request(
            "read_line",
            {
                "image_path": image_path,
                "rect": rect,
                "text_direction": text_direction(orientation, horizontal_dir),
            },
        )

    def pool_size(self) -> int:
        return pool_size()


_KRAKEN_ADAPTER = _KrakenEngineAdapter()




def recognize_lines(
    image_path: str,
    line_rects: list[dict],
    orientation: str = "vertical",
    horizontal_dir: str = "rtl",
    scale: float = 2.0,
    per_line: bool = True,
) -> list[dict]:
    """对给定行框列表做识别，返回与输入同序的行结果（kraken 引擎）。

    每项：{x,y,w,h,text,conf,chars:[{x,y,w,h,text,conf}]}（原图绝对坐标）。
    scale 是下限：按最窄行自适应提高放大倍数，保证放大后列宽 ≥100px
    （CHAT 模型要求 >90px，窄标题列固定 2 倍不够，会识别为空）。
    per_line=True（行级识别的默认）：每行独立裁剪+定倍+局部二值化后
    识别，与"重新识别本行单字"完全同路径——整页一次 nlbin 时边框/
    污渍/邻列墨迹会干扰局部阈值，行级读法与逐行二值化不同。False
    （逐字框批量请求）：全部框一次裁剪、统一倍数、一次 nlbin。

    横排同走 kraken（text_direction=horizontal-lr/rl）：字框像素切分、
    逐框读法、候选生成与竖排完全同链路。此前横排曾分流到 paddle_engine
    （按行宽均分的合成槽位框、跳过逐框读法），槽位与真实字形可整体错
    一格，已停用——古籍横排（刻本大字标题等）正是 chat_rec 的字形域。

    池内有多个 daemon 且 per_line=True 多行时，按行拆成单行请求并行
    分发（_recognize_lines_sharded）；单行结果与整批请求逐字节一致
    （worker 对 per_line 请求本来就是逐行独立处理），只是并行执行。
    KRAKEN_LINE_SHARD=0 关闭分片（对比/调试用）。"""
    if not line_rects:
        return []
    min_w = min(r["w"] for r in line_rects)
    # per-line 模式下倍数由 worker 按每行自身宽度定（≥100px 列宽），
    # 这里只传下限——不得用"全批最窄行"抬倍数，否则与该行单独请求
    # （本行宽度定倍数）不一致，行级读法会差出字数。
    effective_scale = (
        scale
        if per_line
        else min(4.0, max(scale, 100.0 / max(1, min_w)))
    )
    direction = text_direction(orientation, horizontal_dir)
    pool = _ensure_pool()
    shard = (
        per_line
        and len(line_rects) > 1
        and pool.size > 1
        and os.environ.get("KRAKEN_LINE_SHARD", "1") != "0"
    )
    log(
        f"recognize {len(line_rects)} lines "
        f"{'per-line' if per_line else 'batch'}"
        + (f" ×{min(len(line_rects), pool.size)} shards" if shard else "")
        + f" scale={effective_scale:.2f} (min_w={min_w})"
    )
    t0 = time.time()
    if shard:
        lines = _recognize_lines_sharded(
            pool, image_path, line_rects, effective_scale, direction
        )
    else:
        payload = {
            "image_path": image_path,
            "scale": effective_scale,
            "text_direction": direction,
            "per_line": per_line,
            "lines": [
                {"x": int(r["x"]), "y": int(r["y"]), "w": int(r["w"]), "h": int(r["h"])}
                for r in line_rects
            ],
        }
        result = pool.request("recognize", payload)
        lines = result.get("lines", [])
    log(f"kraken done: {len(lines)} lines in {time.time() - t0:.1f}s")
    return lines




def _recognize_lines_sharded(
    pool: _DaemonPool,
    image_path: str,
    line_rects: list[dict],
    effective_scale: float,
    direction: str,
) -> list[dict]:
    """per-line 请求按行拆成单行请求并行分发到池成员。

    worker 对 per_line 请求逐行独立处理（每行自定倍数/局部二值化，见
    kraken_worker._prepare_line），行间无共享状态，因此「一次请求 N 行」
    与「N 次单行请求」结果一致；拆单行还让池成员负载均衡（行长不一）。
    响应缺行按空行兜底，与串行版 record None 的语义一致。按输入顺序归并。"""
    import concurrent.futures

    def _one(rect: dict) -> dict:
        payload = {
            "image_path": image_path,
            "scale": effective_scale,
            "text_direction": direction,
            "per_line": True,
            "lines": [
                {
                    "x": int(rect["x"]), "y": int(rect["y"]),
                    "w": int(rect["w"]), "h": int(rect["h"]),
                }
            ],
        }
        result = pool.request("recognize", payload)
        out = result.get("lines", [])
        if out:
            return out[0]
        return {
            "x": int(rect["x"]), "y": int(rect["y"]),
            "w": int(rect["w"]), "h": int(rect["h"]),
            "text": "", "conf": 0.0, "chars": [],
        }

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=min(len(line_rects), pool.size)
    ) as executor:
        return list(executor.map(_one, line_rects))




def recognize_char(
    image_path: str,
    rect: tuple[int, int, int, int],
    orientation: str,
    horizontal_dir: str,
) -> dict:
    """单字框识别：把该框当作独立的"单字列"交给 Kraken，返回 {text, conf}。

    供编辑器在用户新画/调整单字框后取回框内文字；框内读法与整行序列
    无关，保证"框里是什么字，识别就是什么字"。手画框自带边距、几何
    权威，不做读字外扩。
    """
    results = _recognize_char_boxes(
        image_path, [rect], orientation, horizontal_dir, pad=False
    )
    if not results:
        return {"text": "", "conf": 0.0}
    return {
        "text": (results[0].get("text") or "").strip(),
        "conf": float(results[0].get("conf") or 0.0),
    }




def read_page_text(
    image_path: str,
    orientation: str,
    horizontal_dir: str,
    vertical_dir: str = "ttb",
) -> dict:
    """整页直读（kraken：blla 分行 + rpred 读字），不走标注切分管线。

    worker 返回未排序行列表，阅读序由 page_text 按方向参数重排后拼接。"""
    from page_text import lines_to_page_text

    pool = _ensure_pool()
    # text_direction 同识别管线口径（竖排列旋转后进识别网络），blla 的
    # 行朝向判定与 rpred 的竖排处理都依赖它。
    direction = text_direction(orientation, horizontal_dir)
    result = pool.request(
        "read_page",
        {"image_path": image_path, "text_direction": direction},
    )
    lines = result.get("lines", [])
    text, ordered = lines_to_page_text(
        lines, orientation, horizontal_dir, vertical_dir
    )
    return {
        "text": text,
        "lines": ordered,
        "engine": "kraken",
        "ocr": "kraken+chat_rec",
    }



def _detect_pairing_offset(crop_texts: list[str], seq_texts: list[str]) -> int:
    """检测逐框读法与整行序列的错位格数 d：使 crop[i] == seq[i+d] 首字
    吻合率最高、且显著优于 0 偏移的 d（只考虑 -1/0/+1）。

    像素切分框在行首混入行外组件、行尾并字补数时，字框数恰好等于字数
    但整体相对序列偏一格——表现为"每个字的候选恰好是上一字"。此时
    d≠0，调用方应弃用这批切分框改用 Kraken cuts 重建。保守门槛：错位
    偏移需足够可比对（≥2）、过半吻合、且比 0 偏移高出 0.3 以上。"""

    def rate_for(d: int) -> tuple[float, int]:
        comparable = matches = 0
        for i, crop in enumerate(crop_texts):
            j = i + d
            if not crop or not (0 <= j < len(seq_texts)):
                continue
            seq1 = (seq_texts[j] or "").strip()[:1]
            if not seq1:
                continue
            comparable += 1
            if crop == seq1:
                matches += 1
        return ((matches / comparable) if comparable else 0.0), comparable

    rate0, _ = rate_for(0)
    best_d = 0
    best_rate = rate0
    for d in (-1, 1):
        rated, nd = rate_for(d)
        if nd >= 2 and rated >= 0.5 and rated - rate0 >= 0.3 and rated > best_rate:
            best_d, best_rate = d, rated
    return best_d




def _pair_boxes_with_seq(
    image_path: str,
    boxes: list[tuple[int, int, int, int]],
    boxes_src: str,
    kchars: list[dict],
    char_recs: list[dict],
    orientation: str,
    horizontal_dir: str,
    ctx: str,
    allow_offset_fix: bool = True,
    adapter=None,
) -> tuple[str, list[tuple[int, int, int, int]], list[dict], list[str], str]:
    """构建逐框读法并检测字框↔整行序列错位；错位（像素切分框偏了一
    格，crop[i] 稳定等于 seq[i±1]）时改用整行读法附带的字框几何（kraken
    cuts / paddle 均分条带，见 adapter.cuts_src）重建字框并重新逐框识
    别，使字框几何、框内读法与序列三方重新对齐。
    allow_offset_fix=False 用于刚做过标点拆分的行：行首拆出标点框后
    字框数比序列多一，逐位对照形似 -1 错位，会误触"弃用拆分框、重建
    cuts"——拆分框已锚定真实墨迹段，跳过错位重建。
    返回 (boxes_src, boxes, box_results, crop_texts, primary)。"""
    adapter = adapter or _KRAKEN_ADAPTER
    from segmenter import line_alignment_primary

    def _align_sequence_entries(
        source: list[dict], target_boxes: list[tuple[int, int, int, int]]
    ) -> list[dict]:
        """Keep Kraken text attached to its spatial box after noise removal.

        Ruling-fragment filtering can remove a cuts cell from the middle of a
        row.  Indexing ``kchars`` by position after that would shift every
        following character onto the wrong box.  Match by reading-axis center
        instead and leave an empty entry for a newly split punctuation box.
        """
        if len(source) == len(target_boxes):
            return list(source)
        vertical = orientation != "horizontal"
        # Vertical rows are already returned in their page reading direction
        # by the segmentation layer; horizontal rows use horizontal_dir for
        # their x-axis order.
        reverse = (not vertical) and horizontal_dir == "rtl"

        def center(b: dict | tuple[int, int, int, int]) -> float:
            if isinstance(b, dict):
                x, y, w, h = (
                    float(b.get("x", 0)), float(b.get("y", 0)),
                    float(b.get("w", 0)), float(b.get("h", 0)),
                )
            else:
                x, y, w, h = (float(v) for v in b)
            return (y + h / 2.0) if vertical else (x + w / 2.0)

        ordered = sorted(
            enumerate(source),
            key=lambda item: center(item[1]),
            reverse=reverse,
        )
        unused = set(range(len(ordered)))
        aligned: list[dict] = []
        for box in target_boxes:
            if not unused:
                aligned.append({})
                continue
            best = min(
                unused,
                key=lambda oi: abs(center(ordered[oi][1]) - center(box)),
            )
            unused.remove(best)
            aligned.append(ordered[best][1])
        return aligned

    aligned_kchars = _align_sequence_entries(kchars, boxes)

    def build(
        boxes_: list[tuple[int, int, int, int]], recs_: list[dict]
    ) -> tuple[list[dict], list[str]]:
        results = []
        crops = []
        for order in range(len(boxes_)):
            cr = recs_[order] if order < len(recs_) else {}
            fb = aligned_kchars[order] if order < len(aligned_kchars) else {}
            crops.append((cr.get("text") or "").strip()[:1])
            results.append(
                _char_text_from_box(cr, fb.get("text", ""), fb.get("conf", 0.0))
            )
        return results, crops

    seq_texts = [
        (aligned_kchars[o].get("text") or "") if o < len(aligned_kchars) else ""
        for o in range(len(boxes))
    ]
    box_results, crop_texts = build(boxes, char_recs)
    # 错位检测的前提是"字框数=序列字数"（_detect_pairing_offset 的设计
    # 场景：行首混入行外组件、行尾并字补数，框数恰好等于字数）。框数
    # 更多时（良性差额保留的标点/部件碎块框），标点位无序列字、逐位
    # 对照天然差一格，会把几何正确的框误判成整体错位——实测整行读法
    # 38 字、良性保留 40 框（含 、/， 标点框）被误弃、cuts 重建（该
    # 路径无标点拆分）后标点全部失去字框，用户所见"漏字"。
    offset = (
        _detect_pairing_offset(crop_texts, seq_texts)
        if allow_offset_fix and len(boxes) == len(kchars)
        else 0
    )
    if offset != 0 and aligned_kchars:
        kept_kchars = [c for c in aligned_kchars if c]
        new_boxes = [
            (int(c["x"]), int(c["y"]), int(c["w"]), int(c["h"]))
            for c in kept_kchars
        ]
        new_boxes = _tighten_boxes_to_ink(image_path, new_boxes, orientation)
        log(
            f"[line-rec] {ctx} pairing offset={offset:+d}: 字框相对整行读法"
            f"错位一格（候选=上一字/下一字的根因），弃用 {boxes_src} 框，"
            f"改用 {adapter.cuts_src} 重建字框并重新逐框识别"
        )
        boxes, boxes_src = new_boxes, f"{adapter.cuts_src}(offset-fix)"
        # 收紧可能删格（栏线碎片过滤）、空序列项已过滤——新框与序列项
        # 重新按中心对齐后再 build，否则按新框索引旧列表会整体错一位，
        # 每个框挂上邻字的序列文本。
        aligned_kchars = _align_sequence_entries(kept_kchars, new_boxes)
        seq_texts = [
            (aligned_kchars[o].get("text") or "") if o < len(aligned_kchars) else ""
            for o in range(len(boxes))
        ]
        recs = adapter.read_char_boxes(
            image_path, boxes, orientation, horizontal_dir
        )
        box_results, crop_texts = build(boxes, recs)
    primary = line_alignment_primary(
        [r[0] for r in box_results], seq_texts,
        # 逐框读法只在与字形锚定的字框（像素切分/用户手画）上可信；
        # cuts 条带框/兜底槽位框可整体错半格，分歧时信整行读法
        boxes_trusted=boxes_src.startswith(("pixel-split", "user")),
    )
    return boxes_src, boxes, box_results, crop_texts, primary




def _recognize_char_boxes(
    image_path: str,
    boxes: list[tuple[int, int, int, int]],
    orientation: str,
    horizontal_dir: str,
    pad: bool = True,
) -> list[dict]:
    """第二阶段：把每个单字框当作独立的"单字列"逐个识别（本批一次
    请求：行内所有框统一放大倍数、一次局部二值化）。

    整行识别的文本按阅读序铺到字框上，标点/错漏字时会整体错位一格；
    逐框识别保证"框里是什么字，文本就是什么字"。与输入同序返回。
    pad=True（自动切分框）：先外扩 ~15% 边距再读（紧致框读法实测
    差得多）；pad=False（编辑器手画框）：用户画的框自带边距、几何
    权威，直读。

    单字框一律按竖排（vertical-rl/lr）当"单字列"喂给引擎，与行方向
    无关：CHAT 模型只认"竖排矫形后躺倒的字形"（kraken 对竖排行先旋
    转 90° 再进网络），横排行以 horizontal-lr 直喂时直立字形完全在
    模型分布外——实测横排标题"斗數命盤基本賦性"逐字 8 字全错（○/
    口/拂/加/草…，conf 0.1~0.5），同一批字框改按 vertical-rl 喂 8
    字全对（conf 0.88~0.9998）。单字框内没有阅读方向，orientation
    只影响外扩边距的取向。"""
    if not boxes:
        return []
    read_boxes = _pad_boxes_for_reading(boxes, orientation) if pad else boxes
    rects = [
        {"x": int(b[0]), "y": int(b[1]), "w": int(b[2]), "h": int(b[3])}
        for b in read_boxes
    ]
    t0 = time.time()
    results = recognize_lines(
        image_path, rects, "vertical", horizontal_dir, per_line=False
    )
    log(f"per-char recognition: {len(rects)} boxes in {time.time() - t0:.1f}s")
    return results




def _char_text_from_box(
    box_rec: dict,
    fallback_text: str,
    fallback_conf: float,
) -> tuple[str, float, list[dict]]:
    """单字框文本（混合模式）：框内识别非空取首字为正文；识别为空时正文
    回退序列字。返回 (text, conf, candidates)。

    序列字不再作为逐位候选挂回：本函数的候选只在两路读法大面积不一致
    （primary=box）时被采用，而那种局面要么是序列错位（标点/漏字）、要么
    是字框错位——无论哪种，序列字挂到当前位都会变成"候选=邻字"的错位
    候选（实测一册书 1.5 万字中招）。序列读法的纠错价值只在两路对齐
    （primary=seq）时成立，那条路径的候选由调用方另行挂载。"""
    crop_text = (box_rec.get("text") or "").strip()
    seq_text = (fallback_text or "").strip()
    if crop_text:
        # multi：框内读出不止一个字（crop 吃进邻字/一字被拆读），此时
        # 首字往往属于邻字或只是本字的部件——调用方不得把它当候选或
        # 翻转正文（"候选=前一个字"的来源）。
        return (
            crop_text[:1],
            float(box_rec.get("conf", 0.0)),
            [],
            len(crop_text) > 1,
        )
    return seq_text[:1], float(fallback_conf or 0.0), [], False




def _log_line_decisions(
    ctx: str,
    n: int,
    primary: str,
    seq_texts: list[str],
    crop_texts: list[str],
    final_texts: list[str],
    flips: list[tuple[int, str, str]],
    agrees: list[str] | None = None,
) -> None:
    """逐字决策日志：整行序列读法(seq) / 字框框内读法(crop) / 最终正文
    (final) 的逐字对照，· 表示空。复读翻转单独列出（#序号 seq→crop）。
    后端控制台据此可直接分辨三类问题：seq 复读（seq 串重复而 crop 正
    确）、字框错位（crop 串整体偏移一格）、模型误读（两路同错）。"""
    def _s(cells: list[str]) -> str:
        return "".join(((c or "").strip()[:1]) or "·" for c in cells)

    log(
        f"[line-rec] {ctx} n={n} primary={primary} "
        f"seq={_s(seq_texts)!r} crop={_s(crop_texts)!r} final={_s(final_texts)!r}"
    )
    if agrees:
        counts: dict[str, int] = {}
        for a in agrees:
            counts[a] = counts.get(a, 0) + 1
        log(
            f"[line-rec] {ctx} dual-read: "
            + " ".join(f"{k}×{v}" for k, v in counts.items())
        )
    if flips:
        log(
            f"[line-rec] {ctx} repeat-flip: "
            + ", ".join(f"#{i} {s!r}->{c!r}" for i, s, c in flips)
        )




def _align_seq_to_boxes(
    seq_texts: list[str], crop_texts: list[str]
) -> list[int | None]:
    """整行序列字 ↔ 逐框读法的顺序对齐：返回每个框位对应的序列索引。

    逐位 zip 在序列中间多/少一个字（标点、漏识别）时会把后续全部错开
    一格——正文与候选挂到邻字上的根源。difflib 顺序对齐容忍插入/删除，
    把每个字框配到正确的序列字上；配不上（None）= 序列没读出这个位置
    （序列少字/框多），由调用方按单路读法处理。"""
    from difflib import SequenceMatcher

    def norm(s: str) -> str:
        return (s or "").strip()[:1] or "\x00"

    seq = [norm(s) for s in seq_texts]
    box = [norm(s) for s in crop_texts]
    pair: list[int | None] = [None] * len(box)
    if not seq or not box:
        return pair
    for tag, i1, i2, j1, j2 in SequenceMatcher(None, seq, box).get_opcodes():
        if tag in ("equal", "replace"):
            for k in range(min(i2 - i1, j2 - j1)):
                pair[j1 + k] = i1 + k
    return pair




# 不可信字框（kraken cuts 条带框/兜底槽位框）上两路读法分歧时的策略开关：
# True = 信整行序列（cuts 框按序列切位构造、框 i ↔ 序列字 i，数量一致时
# 按位置配对；逐框读的是错位切片，实测整行乱码而序列正确）。
_UNTRUSTED_BOXES_PREFER_SEQ = True




def _fuse_line_chars(
    kchars: list[dict],
    boxes: list[tuple[int, int, int, int]],
    box_results: list[tuple],
    crop_texts: list[str],
    primary: str,
    id_prefix: str,
    col: int,
    line_id: str,
    boxes_trusted: bool = True,
    char_source: str = "kraken+chat_rec",
) -> tuple[list[dict], list[tuple], list[str]]:
    """整行读法与逐框读法的逐字融合（整页/单行两条识别路径共用）。

    正文策略以对齐关系取代历史的位置对应：
    - primary=seq：本框有对齐序列字 → 取序列字（语境读法更准）；没有
      （序列漏读/框多）→ 取框内读法。位置位序列字不再参与正文——序列
      因标点/漏字整体错开时位置位是邻字，正是"正文/候选=邻字"的来源。
    - primary=box：正文取框内读法，框内为空回退对齐序列字。
    - 复读翻转（对齐序列把本位读成与上位同字、框内读法不同 → 以框内
      为正文、序列字降为候选）保持原语义；框内读出多字（multi）时框内
      读法不可信，不翻转。

    每字新增 agree 状态，两路合作对编辑器可见：
      both      两路读法一致（最可信）
      conflict  两路各读出一个不同的字——另一路读法挂为末位候选供人工
                裁决（此前逐位互挂候选实测全是噪声，但那是在无对齐、
                "分歧"大量混入邻位字的前提下；对齐后的真分歧正是最该
                人工复核的位置）
      seq/box   只有一路读出（另一路空/无对齐位）
      box_multi 框内读出多字（吃邻字/拆字，框内读法不可信）
      none      两路皆空

    返回 (chars, flips, agrees)，与 boxes 同序。
    """
    seq_texts = [(c.get("text") or "") for c in kchars]
    pair = _align_seq_to_boxes(seq_texts, crop_texts)
    # 不可信字框（cuts/兜底槽位）且框数=序列字数：cuts 框按序列切位构造，
    # 框 i ↔ 序列字 i 是构造性对应——文字对齐在逐框读法乱码时配不上位
    # （落空位回退乱码 crop，实测"前半乱码后半正确"的混搭），按位置
    # 配对直接取序列字。
    if (
        _UNTRUSTED_BOXES_PREFER_SEQ
        and not boxes_trusted
        and primary == "seq"
        and len(boxes) == len(seq_texts)
        and any((t or "").strip() for t in seq_texts)
    ):
        pair = list(range(len(boxes)))
    # 分歧位挂候选的护栏：行内要有两路一致的锚点（长行 ≥2 个，短行
    # ≥1 个）。整行完全不吻合（对齐全是 replace）大概率是系统性错位而
    # 非逐字分歧，逐位互挂只会重现"候选=邻字"的噪声（更新日志 1.0.0+1
    # 的实测教训）。
    equal_pairs = sum(
        1
        for j, ai in enumerate(pair)
        if ai is not None
        and ai < len(kchars)
        and (kchars[ai].get("text") or "").strip()[:1]
        == (crop_texts[j] if j < len(crop_texts) else "")
    )
    attach_alt = equal_pairs >= 2 or (equal_pairs >= 1 and len(boxes) <= 3)

    chars: list[dict] = []
    flips: list[tuple[int, str, str]] = []
    agrees: list[str] = []
    prev_al_char = ""
    for order, b in enumerate(boxes):
        box_text, box_conf, box_cands, box_multi = (
            box_results[order] if order < len(box_results) else ("", 0.0, [], False)
        )
        raw_box = crop_texts[order] if order < len(crop_texts) else ""
        raw_conf = float(box_conf) if raw_box else 0.0
        ai = pair[order] if order < len(pair) else None
        aligned = kchars[ai] if ai is not None and ai < len(kchars) else {}
        al_char = (aligned.get("text") or "").strip()[:1]
        al_conf = float(aligned.get("conf", 0.0) or 0.0)

        cands: list[dict] = list(box_cands or [])
        if primary == "seq":
            text, conf = (al_char, al_conf) if al_char else (raw_box, raw_conf)
        else:
            text, conf = (raw_box, raw_conf) if raw_box else (al_char, al_conf)
        # 复读疑点：对齐序列把本位读成与上位同字（叠字式复读的典型误读）
        # 而框内读法给出不同的字 → 以框内为正文，序列字降为候选。
        if (
            primary == "seq"
            and al_char
            and raw_box
            and raw_box != al_char
            and not box_multi
            and al_char == prev_al_char
        ):
            text, conf = raw_box, raw_conf
            cands.append({"text": al_char, "score": round(al_conf, 4)})
            flips.append((order, al_char, raw_box))
        prev_al_char = al_char

        if al_char and raw_box:
            if box_multi:
                agree = "box_multi"
            elif al_char == raw_box:
                agree = "both"
            else:
                agree = "conflict"
        elif al_char:
            agree = "seq"
        elif raw_box:
            agree = "box"
        else:
            agree = "none"

        if agree == "conflict" and attach_alt:
            # 另一路读法挂为末位候选（复读翻转已挂的不重复）
            if text == al_char:
                alt_char, alt_conf = raw_box, raw_conf
            else:
                alt_char, alt_conf = al_char, al_conf
            if alt_char and not any(
                c.get("text") == alt_char for c in cands
            ):
                cands.append({"text": alt_char, "score": round(float(alt_conf or 0.0), 4)})

        agrees.append(agree)
        chars.append(
            {
                "id": f"{id_prefix}{order}",
                "x": int(b[0]),
                "y": int(b[1]),
                "w": int(b[2]),
                "h": int(b[3]),
                "col": col,
                "order": order,
                "type": "main_text",
                "confirmed": False,
                "text": text,
                "source": char_source,
                "line_id": line_id,
                "conf": conf,
                "agree": agree,
                "candidates": cands,
            }
        )
    return chars, flips, agrees




def _align_full_text(full_text: str, char_texts: list[str]) -> tuple[list[str], list[bool]]:
    """全文读法 vs 单字识别的序列对齐（全文对照的纯函数核心）。

    返回 (extras, diff_flags)：
    - extras：全文有而单字序列没有的字符（保序）——通常是标点等没有
      字框、像素切分天然丢掉的字符；
    - diff_flags：与对位全文字符不一致的单字标记（opcodes 的 replace
      段；单字有而全文没有的 insert 段不标——融合层候选已覆盖分歧）。"""
    import difflib

    a = [ch for ch in str(full_text or "") if not ch.isspace()]
    b = [str(t or "") for t in char_texts]
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    extras: list[str] = []
    diff = [False] * len(b)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "delete":
            extras.extend(a[i1:i2])
        elif tag == "replace":
            for j in range(j1, j2):
                diff[j] = True
    return extras, diff


def _match_page_ref_line(ref_lines: list, rect: dict):
    """行框 ↔ 整页直读行按 IoU 最优匹配（≥0.3 才算命中）。

    det 定行后标注行与直读行同源（都是 PP-OCR det 的框，标注行仅沿
    阅读轴墨迹外扩 ±25%），IoU 天然高；列间无重叠不会串列。"""
    best = None
    best_iou = 0.3
    x, y = int(rect.get("x", 0)), int(rect.get("y", 0))
    w, h = int(rect.get("w", 0)), int(rect.get("h", 0))
    if w <= 0 or h <= 0:
        return None
    for ref in ref_lines or []:
        if not isinstance(ref, dict):
            continue
        try:
            rx, ry = int(ref.get("x", 0)), int(ref.get("y", 0))
            rw, rh = int(ref.get("w", 0)), int(ref.get("h", 0))
        except (TypeError, ValueError):
            continue
        if rw <= 0 or rh <= 0:
            continue
        ix = min(x + w, rx + rw) - max(x, rx)
        iy = min(y + h, ry + rh) - max(y, ry)
        if ix <= 0 or iy <= 0:
            continue
        inter = ix * iy
        union = w * h + rw * rh - inter
        iou = inter / union if union > 0 else 0.0
        if iou > best_iou:
            best, best_iou = ref, iou
    return best


def _apply_full_text_check(
    adapter,
    image_path: str,
    rect: dict | None,
    orientation: str,
    horizontal_dir: str,
    vertical_dir: str,
    line: dict,
    chars: list[dict],
) -> None:
    """全文对照（默认识别流程的附加路）：整页/整行全文直读（不经字框
    切分）与单字识别序列对齐——全文多出的字符记 line["full_extras"]
    （客户端以无框字片展示在识别栏），与对位全文字符不一致的单字标
    full_diff（客户端特殊颜色）。对照是增强路：任何失败静默跳过，绝不
    影响识别主流程；FULL_TEXT_CHECK=0 关闭。

    参照优先级：① 整页直读行文本（adapter.page_text_lines，paddle 桥接
    层挂载——与文本视图同一模型同一读法，VL 选择时带标点，按行框 IoU
    匹配）；② 行框裁图整行直读（read_line_full，旧参照路径，页读不可
    用/该行没匹配上时兜底）。"""
    if os.environ.get("FULL_TEXT_CHECK", "1") == "0":
        return
    if not rect or not chars:
        return
    text = ""
    source = ""
    ref_lines = getattr(adapter, "page_text_lines", None)
    if ref_lines:
        ref = _match_page_ref_line(ref_lines, rect)
        if ref is not None:
            text = str(ref.get("text") or "")
            source = "page"
    if not text.strip():
        try:
            full = adapter.read_line_full(
                image_path, rect, orientation, horizontal_dir, vertical_dir
            )
        except Exception as exc:
            log(f"[full-check] 全文直读失败（跳过对照）: {exc}")
            return
        text = str((full or {}).get("text") or "")
        source = "line"
    if not text.strip():
        return
    extras, diffs = _align_full_text(text, [c.get("text") or "" for c in chars])
    line["full_text"] = text
    line["full_extras"] = extras
    for c, d in zip(chars, diffs):
        if d:
            c["full_diff"] = True
    if extras or any(diffs):
        log(
            f"[full-check] 全文对照({source}): extras={len(extras)} "
            f"({''.join(extras)[:16]}), diff={sum(diffs)}"
        )


def apply_recognition(
    result: dict,
    image_path: str,
    orientation: str,
    horizontal_dir: str,
    char_splitter=None,
    adapter=None,
    vertical_dir: str = "ttb",
) -> dict:
    """/segment 结果后处理（引擎无关核心）：版面保持不变，行内单字文本与
    字框全部来自所选识别引擎（默认 kraken；paddle 见 paddle_bridge，
    char.source = adapter.char_source）。

    流程：① 整行识别得到字数与阅读序列——引擎无该方向整行域时跳过
    （CHAT 无横排域；PP-OCR 无竖排域，后者在 ② 得到字框后经
    adapter.read_strip_chars 用"字框拼横条"补读序列，与逐字读法仍构成
    独立两路）；② 字框几何取像素切分框（char_splitter，连通域紧致框），
    失败回退整行读法附带的字框几何（kraken cuts 条带 / 阅读轴均分条带，
    见 adapter.cuts_src）；③ 每个字框单独识别框内文字（错位免疫）；
    ④ 两路读法顺序对齐后逐字融合（_fuse_line_chars）：正文优先取对齐
    序列字，序列漏读处取框内读法，分歧位挂另一路读法为候选并标记
    agree 状态。
    """
    adapter = adapter or _KRAKEN_ADAPTER
    lines = result.get("lines") or []
    # 行框沿阅读轴外扩到本行连续墨迹（与单行重识别一致）：整页检测的
    # 行框取自字框包围/条带收紧，检测漏字的列会把整段行文留在框外
    # （实测註五列 1421px 连续墨迹只框住中段 581px、少读 4 字）。行框
    # 几何本身不变，识别与切字用扩后框。
    try:
        from segmenter import (
            _text_mask_for_refinement,
            expand_line_rect_to_neighbor_ink,
        )

        ink_mask = _text_mask_for_refinement(image_path)
    except Exception as exc:
        log(f"[line-rec] page line expand skipped: {exc}")
        ink_mask = None
    split_rects: list[dict] = []
    rects: list[dict] = []
    for line in lines:
        base_rect = {
            "x": line.get("x", 0), "y": line.get("y", 0),
            "w": line.get("w", 0), "h": line.get("h", 0),
        }
        read_rect = dict(base_rect)
        if (
            ink_mask is not None
            and base_rect["w"] > 0
            and base_rect["h"] > 0
            and not line.get("double_col_split")
        ):
            try:
                mask_h, mask_w = ink_mask.shape[:2]
                line_orientation = line.get("orientation") or orientation
                expanded = expand_line_rect_to_neighbor_ink(
                    (base_rect["x"], base_rect["y"], base_rect["w"], base_rect["h"]),
                    ink_mask, mask_w, mask_h, line_orientation,
                )
                # 整页检测已提供字框覆盖范围时（YOLO 行）与 det 行
                # （PP-OCR 检测定行，chars 为空）同样适用：墨迹扩展只用于
                # 找回边缘少量漏墨。栏线/邻列墨迹可能让旧算法一路扩到
                # 整页高度，随后把空白切成大量小框；超过 25% 的扩展不
                # 再视为“缺边”，保留检测到的列框几何。上限取 25%：20%
                # 实测会把检测少框了几个字的列（1706px 列底漏 5 字，
                # 扩展 +346px = 20.3%）以 5px 之差误拒——整页只用短框
                # 识别，列底字全部丢失，后续 AI 修复单行重识别虽然补
                # 回字框，但行框仍是短的（合回只换字框），字全部落在
                # 行框外（用户所见“没有画进单行识别框”）；病态扩展
                # （欄線链拉到整页，>100%）仍远超上限被挡。
                if line_orientation != "horizontal":
                    base_axis = max(1, int(base_rect["h"]))
                    expanded_axis = max(1, int(expanded[3]))
                    growth = expanded_axis - base_axis
                    max_growth = max(32, int(base_axis * 0.25))
                    if growth > max_growth:
                        log(
                            f"[line-rec] line {line.get('id', '?')} expansion "
                            f"{growth}px exceeds {max_growth}px; keep YOLO box"
                        )
                        expanded = (
                            base_rect["x"], base_rect["y"],
                            base_rect["w"], base_rect["h"],
                        )
                if expanded != (
                    base_rect["x"], base_rect["y"], base_rect["w"], base_rect["h"],
                ):
                    read_rect = {
                        "x": expanded[0], "y": expanded[1],
                        "w": expanded[2], "h": expanded[3],
                    }
                    # 行框几何同步为外扩后的实际识别范围：否则编辑器里
                    # 行框仍是检测时的一小段，而字框铺满整列，视觉割裂
                    # （"日志显示了全部文字、框却只裁了一小块"的来源）。
                    line["x"], line["y"] = expanded[0], expanded[1]
                    line["w"], line["h"] = expanded[2], expanded[3]
            except Exception as exc:
                log(f"[line-rec] line {line.get('id')} expand failed: {exc}")
        split_rects.append(read_rect)
        rects.append(read_rect)
    line_read_direct = (
        adapter.horizontal_line_read
        if orientation == "horizontal"
        else adapter.vertical_line_read
    )
    if not line_read_direct:
        # 整行序列读法对该方向不可达：CHAT 横排直喂/旋转喂都出乱码，还会
        # 用乱码字数污染切分数量校验（见单行路径同款注释）；PP-OCR 竖排
        # 旋转会把直立字形放倒。跳过整行阶段，正文与候选全部来自逐字读
        # 法；融合层对空序列有既有降级路径（primary=box、agree=box），
        # 字框几何由像素切分独立给出（期望字数未知）。strip_read 引擎
        # （PP-OCR）的字框拼条序列读法在 _line_task 拿到字框后补上。
        seq_lines = [
            {"text": "", "conf": 0.0, "chars": []} for _ in rects
        ]
        log(
            f"[line-rec] {orientation}：{len(rects)} 行跳过整行序列读法"
            f"（{adapter.name}：{adapter.skip_note}），正文走逐字读法"
        )
    else:
        seq_lines = adapter.read_lines(
            image_path, rects, orientation, horizontal_dir
        )

    # ── 行级任务链（进程内流水线）─────────────────────────────────────
    # 行与行之间零数据依赖；行内链路「像素切分→标点后检→逐框补读→对齐
    # 融合」串行不变。多行任务在线程池并行执行：主进程的 CPU 段（切分/
    # 融合）与 daemon 池的推理段持续重叠。每行的请求内容与串行版完全
    # 一致，结果逐字节相同；KRAKEN_LINE_TASKS=0 或池只有 1 个成员时
    # 退回串行执行（同一任务函数，保证单一代码路径）。
    stamp = int(time.time() * 1000)
    splitter_lock = threading.Lock() if char_splitter is not None else None

    def _line_task(idx: int) -> list[dict]:
        line = lines[idx]
        kl = seq_lines[idx]
        line["text"] = kl.get("text", "")
        kchars = kl.get("chars", [])
        n_expected = len(kchars)
        # 切分 + 立即读 last_method 必须是临界区：切分器闭包每次切分后
        # 覆写 splitter.last_method，并行行共享实例会读到别行的方法，
        # 导致误弃用/误信任切分框（_split_trusted 的判定依据）。
        boxes = None
        trusted = True
        method = "?"
        if char_splitter is not None:
            with splitter_lock:
                boxes = _split_boxes_or_none(
                    char_splitter, split_rects[idx], n_expected, f"line {idx}"
                )
                trusted = _split_trusted(char_splitter)
                method = getattr(char_splitter, "last_method", "?")
        src = "pixel-split"
        if boxes is not None and n_expected > 0 and not trusted:
            # 兜底切分（网格/等分）的槽位框与真实字形可整体错一格，
            # 逐框读法会读进邻字——直接弃用，改用与整行读法构造性
            # 对齐的 Kraken cuts 条带框。（n_expected=0 的横排不适用：
            # 期望数未知时切分器只会走连通域或整行单框，无合成槽位。）
            log(
                f"[line-rec] line#{idx} pixel split fallback "
                f"({method}): 弃用合成槽位框，改用 kraken cuts"
            )
            boxes = None
        if boxes is None:
            if kchars:
                boxes = [
                    (int(c["x"]), int(c["y"]), int(c["w"]), int(c["h"])) for c in kchars
                ]
                boxes = _tighten_boxes_to_ink(image_path, boxes, orientation)
                src = adapter.cuts_src
            else:
                # 无整行序列（横排 CHAT / 竖排 PP-OCR 首遍）且切分器不可
                # 用：整行单框兜底，逐字读法至少读出一个字（与孤立标点列
                # 的占位语义一致）。
                r = split_rects[idx]
                boxes = [
                    (int(r["x"]), int(r["y"]), int(r["w"]), int(r["h"]))
                ]
                src = "line-rect-fallback"

        # 超高字框后检拆分：字+标点被画进同一框时按本行中位字高检出并按
        # 墨迹拆开（标点独立成框）。放在逐框识别之前，拆分框的框内读法
        # 由下方统一的识别批次自然覆盖。横排同样处理（拆分/合并的判据沿
        # 阅读轴自适应：竖排看框高、横排看框宽，rtl 时按降序插回）。
        # 单行调用与原整批调用对该行行为一致（批版内部就是逐行循环）。
        line_boxes = [boxes]
        punct_flags = _split_punct_merged_line_boxes(
            image_path, line_boxes, orientation, horizontal_dir
        )
        boxes = line_boxes[0]
        boxes = _filter_pixel_noise_boxes(
            image_path, boxes, split_rects[idx], orientation,
        )
        punct_split = punct_flags[0]
        if punct_split:
            src += "+punct-split"

        # 序列补读（strip_read 引擎，如 PP-OCR 竖排）：整行读法对该方向
        # 不可达、首遍以 n=0 切分出字框后，用"字框裁剪→等高拼横条"整条
        # 读回序列文本（与逐字读法互相独立的两路）。合成 kchars 的字框
        # 几何为阅读轴均分（仅供对齐/兜底），字数此刻已知但不回写切分
        # ——切分已按期望数未知完成，重切反而引入抖动。
        if (
            not kchars
            and adapter.strip_read
            and len(boxes) >= 2
        ):
            try:
                kchars = adapter.read_strip_chars(
                    image_path, split_rects[idx], boxes,
                    orientation, horizontal_dir,
                )
                if kchars:
                    log(
                        f"[line-rec] line#{idx} strip 序列补读："
                        f"{len(kchars)} 字（字框 {len(boxes)}）"
                    )
            except Exception as exc:
                log(f"[line-rec] line#{idx} strip 序列补读失败（按无序列走）: {exc}")
                kchars = []

        # 阶段二：本行全部字框一次批量补读（行内统一参数——与"本行单独
        # 重识别"完全同路径）。
        box_recs = adapter.read_char_boxes(
            image_path, boxes, orientation, horizontal_dir
        )

        # 阶段三：字框↔序列对齐（错位时弃用偏移框、序列字框重建并重新
        # 逐框识别）+ 两路读法逐字融合。刚拆过标点的行跳过错位重建：行首
        # 标点框会被逐位对照误判为 -1 错位。
        boxes_src, boxes, box_results, crop_texts, primary = _pair_boxes_with_seq(
            image_path,
            boxes,
            src,
            kchars,
            box_recs,
            orientation,
            horizontal_dir,
            f"line#{idx}",
            allow_offset_fix=not punct_split,
            adapter=adapter,
        )
        seq_entries = [kchars[o] if o < len(kchars) else {} for o in range(len(boxes))]
        chars, flips, agrees = _fuse_line_chars(
            kchars,
            boxes,
            box_results,
            crop_texts,
            primary,
            id_prefix=f"k_{stamp}_{idx}_",
            col=line.get("line_no", idx),
            line_id=line.get("id", ""),
            boxes_trusted=boxes_src.startswith(("pixel-split", "user")),
            char_source=adapter.char_source,
        )
        line["chars"] = chars
        line["text"] = "".join(c["text"] for c in chars)
        _log_line_decisions(
            f"line#{idx} id={line.get('id', '?')} boxes={boxes_src}",
            len(boxes),
            primary,
            [(e.get("text") or "") for e in seq_entries],
            crop_texts,
            [c["text"] for c in chars],
            flips,
            agrees,
        )
        # 全文对照（增强路）：整行全文直读 vs 单字识别，标点等无框字符
        # 与不一致字回填到 line/chars（失败静默，见 _apply_full_text_check）。
        _apply_full_text_check(
            adapter,
            image_path,
            split_rects[idx],
            orientation,
            horizontal_dir,
            vertical_dir,
            line,
            chars,
        )
        return chars

    use_task_threads = (
        len(lines) > 1
        and adapter.pool_size() > 1
        and os.environ.get("KRAKEN_LINE_TASKS", "1") != "0"
    )
    if use_task_threads:
        import concurrent.futures
        import contextvars

        workers = max(2, pool_size() or 2)
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(len(lines), workers)
        ) as executor:
            futures = []
            for idx in range(len(lines)):
                # 每个任务拷贝当前上下文：debug_trace 等请求级 ContextVar
                # 在任务线程里可见（各拷贝持有同一 trace list 的引用）。
                task_ctx = contextvars.copy_context()
                futures.append(executor.submit(task_ctx.run, _line_task, idx))
            per_line_chars = [f.result() for f in futures]  # 按行序取，异常上抛
    else:
        per_line_chars = [_line_task(idx) for idx in range(len(lines))]

    blocks: list[dict] = []
    for chars in per_line_chars:
        blocks.extend(chars)
    result["blocks"] = blocks
    result["ocr"] = adapter.ocr_tag
    result["recognition_engine"] = adapter.name
    log(f"applied {adapter.name} recognition: {len(blocks)} chars on {len(lines)} lines")
    return result



def apply_kraken_recognition(
    result: dict,
    image_path: str,
    orientation: str,
    horizontal_dir: str,
    char_splitter=None,
    vertical_dir: str = "ttb",
) -> dict:
    """apply_recognition 的 kraken 薄包装（历史入口，import 面保持不变）。"""
    return apply_recognition(
        result, image_path, orientation, horizontal_dir, char_splitter,
        vertical_dir=vertical_dir,
    )




def kraken_segment_rect(
    image_path: str,
    rect: dict,
    line_id: str,
    line_no: int,
    orientation: str,
    horizontal_dir: str,
    char_boxes: list[tuple[int, int, int, int]] | None = None,
    char_splitter=None,
    vertical_dir: str = "ttb",
    strict_char_boxes: bool = False,
    expected_char_count: int | None = None,
    expand: bool = True,
    adapter=None,
) -> list[dict]:
    """行框级识别入口：检出并排子列（夹注/旁注）结构时拆成多行识别。

    先把行框沿阅读轴外扩到连续墨迹，再检"通栏上段 + 左右窄子列"结构
    （_double_column_sub_rects，allow_short=True：单行识别是用户明确
    指向该行的场景，两行小注也拆，误拆当场可见可撤）：命中时逐个子框
    走与整页/单行完全相同的识别链路（kraken_segment_line），返回按阅
    读序排列的行列表（1 个子框时也走同一返回形状）。字框（编辑器保留
    的人工框）按中心点分配到对应子行。拆分行框已收紧到各自墨迹，子链
    路不再外扩——上段通栏框一旦沿阅读轴外扩会顺着连续墨迹吃进下方双
    列段。

    strict_char_boxes：严格保留 char_boxes 的框几何（只重填文字），
    透传给子链路——见 kraken_segment_line。

    expected_char_count：调用方已知的该行真实字数（AI 框检查按几何/
    视觉模型推算），透传给像素切分器做数量校验——Kraken 序列读法漏读/
    粘读时其字数不可信，切分器据此能选对连通域合并/细切策略。

    expand：False 时行框不外扩，识别/切分范围即传入行框。小字注释列
    被拆成多段单行时（app 检出该行与其它行共享列带即传 False），外扩
    会顺着小注列的连续墨迹吞掉整列，段图上叠满整列字框。"""
    from segmenter import _double_column_sub_rects, double_column_roles

    read_rect = (
        _expand_line_rect_for_reading(image_path, rect, line_id, orientation)
        if expand
        else dict(rect)
    )
    # 子列检测在外扩后的行框上做：用户框可能只框住整列中段，先扩到
    # 连续墨迹两端再检，短框也能拆出完整双列；子框已贴各自墨迹，子
    # 链路不再外扩（上段通栏框一旦外扩会顺连续墨迹吃进下方双列段）。
    subs = _double_column_sub_rects(
        (
            int(read_rect["x"]), int(read_rect["y"]),
            int(read_rect["w"]), int(read_rect["h"]),
        ),
        _safe_text_mask(image_path), orientation, horizontal_dir, vertical_dir,
        allow_short=True,
    )
    if len(subs) <= 1:
        line = segment_line_core(
            image_path,
            read_rect,
            line_id,
            line_no,
            orientation,
            horizontal_dir,
            char_boxes=char_boxes,
            char_splitter=char_splitter,
            strict_char_boxes=strict_char_boxes,
            expected_char_count=expected_char_count,
            expand=expand,
            adapter=adapter,
            vertical_dir=vertical_dir,
        )
        line.setdefault("layout_role", "body")
        line.setdefault("column_group", "")
        line.setdefault("parent_line_id", "")
        line.setdefault("layout_confidence", 0.0)
        return _clamp_lines_to_image([line], image_path)

    boxes_by_sub: list[list[tuple[int, int, int, int]]] = [
        [] for _ in subs
    ]
    for b in char_boxes or []:
        cx = b[0] + b[2] / 2.0
        cy = b[1] + b[3] / 2.0
        # 就近归属（不要求严格落入）：跨子列的粘连旧框中心可能落在
        # 缝隙/边界上，首-match 会把字框整批丢掉。
        best, best_d = 0, float("inf")
        for si, (sx, sy, sw, sh) in enumerate(subs):
            dx = max(sx - cx, 0.0, cx - (sx + sw))
            dy = max(sy - cy, 0.0, cy - (sy + sh))
            d = dx * dx + dy * dy
            if d < best_d:
                best_d, best = d, si
        boxes_by_sub[best].append(b)
    lines: list[dict] = []
    roles = double_column_roles(subs, orientation)
    for si, (sx, sy, sw, sh) in enumerate(subs):
        sub_id = line_id if len(subs) == 1 else f"{line_id}_d{si}"
        lines.append(
            segment_line_core(
                image_path,
                {"x": sx, "y": sy, "w": sw, "h": sh},
                sub_id,
                line_no,
                orientation,
                horizontal_dir,
                char_boxes=boxes_by_sub[si] or None,
                char_splitter=char_splitter,
                strict_char_boxes=strict_char_boxes,
                expand=False,
                adapter=adapter,
                vertical_dir=vertical_dir,
            )
        )
        # Keep the same layout metadata as full-page segmentation so manual
        # resegmentation cannot lose正文/夹注 column identity.
        if len(subs) > 1:
            lines[-1]["layout_role"] = roles[si]
            lines[-1]["double_col_split"] = True
            if roles[si] == 'annotation':
                for char in lines[-1].get('chars', []):
                    if char.get('type') != 'ignore':
                        char['type'] = 'annotation'
            lines[-1]["column_group"] = f"dc_{line_id}"
            lines[-1]["parent_line_id"] = line_id
            lines[-1]["layout_confidence"] = 0.92
        else:
            lines[-1].setdefault("layout_role", "body")
            lines[-1].setdefault("column_group", "")
            lines[-1].setdefault("parent_line_id", "")
            lines[-1].setdefault("layout_confidence", 0.0)
    log(
        f"[line-rec] {line_id} 双列结构拆为 {len(subs)} 行识别："
        + " ".join(
            f"({s[0]},{s[1]},{s[2]},{s[3]})" for s in subs
        )
    )
    return _clamp_lines_to_image(lines, image_path)




def segment_line_core(
    image_path: str,
    rect: dict,
    line_id: str,
    line_no: int,
    orientation: str,
    horizontal_dir: str,
    char_boxes: list[tuple[int, int, int, int]] | None = None,
    char_splitter=None,
    expand: bool = True,
    strict_char_boxes: bool = False,
    expected_char_count: int | None = None,
    adapter=None,
    vertical_dir: str = "ttb",
) -> dict:
    """单行识别核心（引擎无关），返回与整页识别同构的 line dict（含 chars）。

    字框几何：编辑器有人工画的非均分框且数量一致时保留人工框，否则用
    像素切分框（char_splitter，连通域紧致框），切分失败回退整行读法附带
    的字框几何（kraken cuts 条带 / 阅读轴均分条带）。strict_char_boxes=
    True 时无条件保留传入框（数量与读法不一致也不弃用——「重新识别本
    行」/「识别填字」的人工框是校对成果，只重填文字），并跳过字框↔序列
    错位重建。文本：整行序列与逐框读法顺序对齐后逐字融合
    （_fuse_line_chars）——正文优先取对齐序列字，序列漏读处取框内读法，
    分歧位挂另一路读法为候选并标记 agree 状态。行框几何为外扩后的实际
    识别范围（扩不动时即传入原值）；横排不外扩（原因见下方 read_rect 处
    注释）；expand=False 跳过外扩（拆分子行框已贴墨迹，外扩会越界吃进
    相邻结构）。
    """
    adapter = adapter or _KRAKEN_ADAPTER
    # 行框沿阅读轴外扩到本行墨迹的连续段两端：偏短的行框（人工画的
    # 行框、历史上切短的自动行框）把行外的字整段留在框外，识别与切分
    # 都看不到 → "识别不全"。扩展以行框的横向范围（竖排）为窗，见
    # _expand_line_rect_for_reading。
    read_rect = (
        _expand_line_rect_for_reading(image_path, rect, line_id, orientation)
        if expand
        else dict(rect)
    )

    line_read_direct = (
        adapter.horizontal_line_read
        if orientation == "horizontal"
        else adapter.vertical_line_read
    )
    synthetic_placeholder = False
    if not line_read_direct:
        # 整行序列读法对该方向不可达（CHAT 无横排域；PP-OCR 无竖排域，
        # 后者的序列由下方字框拼条 read_strip_chars 补读）：跳过整行阶
        # 段，正文与候选全部来自逐字读法（融合层空序列降级），字框来自
        # 编辑器传入框或像素切分（期望字数未知 → 纯连通域路径）。
        kl = {"text": "", "conf": 0.0, "chars": []}
        log(
            f"[line-rec] {line_id} {orientation}：跳过整行序列读法"
            f"（{adapter.name}：{adapter.skip_note}），正文走逐字读法"
        )
    else:
        seq_lines = adapter.read_lines(
            image_path, [read_rect], orientation, horizontal_dir
        )
        kl = seq_lines[0] if seq_lines else {"text": "", "chars": []}

        if not kl.get("chars"):
            # Kraken 行读法为空：整行只有一个标点（。，、）时常见——孤立
            # 小墨迹的行识别输出空文本，此前整行直接报错，人工框选的标点
            # 列永远建不起来（实测"整列一个句号"画框后报"识别结果为空"）。
            # 行框内确实有墨迹时改走兜底：合成一个覆盖行框的占位字符交给
            # 正常管线——字框随后被收紧到墨迹、逐框识别再试一次读法，
            # 正文可能直接读出标点。完全无墨迹仍是异常输入/模型失败，保持
            # 报错让编辑器保留原行数据，而不是把这一行清成 0 个字。
            # 占位字符只作管线占位，不代表"本行 1 字"的真实读法：切分
            # 期望字数按未知（n=0 纯连通域，与整页路径/横排同款）走，
            # 否则数量校验会把整列连通域字框判为不匹配、n<=1 的网格
            # 兜底退回整行一框（超长列整行读法失败后推倒重切永远拆不开）。
            has_ink = _line_rect_has_ink(image_path, read_rect)
            if not has_ink:
                raise RuntimeError(
                    f"{adapter.name} 对该行识别结果为空 rect=({rect['x']},{rect['y']},{rect['w']},{rect['h']})"
                )
            log(
                f"[line-rec] {line_id} {adapter.name} 读法为空但行框内有墨迹"
                f"（孤立标点列/整行读法失败）：合成整行占位字符，"
                f"切分按期望字数未知（n=0 纯连通域）走"
            )
            kl = {
                "text": "",
                "chars": [{
                    "x": int(read_rect["x"]), "y": int(read_rect["y"]),
                    "w": int(read_rect["w"]), "h": int(read_rect["h"]),
                    "text": "",
                }],
            }
            synthetic_placeholder = True

    kchars = kl.get("chars", [])
    n = len(kchars)
    user_boxes = list(char_boxes or [])
    boxes_src = adapter.cuts_src
    # strict_char_boxes（「重新识别本行」/「识别填字」）：无条件保留
    # 传入框——字框数与整行读法不一致（人工删过/画过框后是常态）、或
    # 框形似均分合成框时，旧逻辑会整批弃用人工框走自动重切（实测 23
    # 个手工框被 1 个 cuts 框替换），违背"只重填文字不改框"的语义。
    strict_keep = strict_char_boxes and bool(user_boxes)
    # n=0（横排无整行序列）时编辑器传入框不受"数量与读法一致"约束——
    # 没有读法可对齐，只要非均分合成框就保留人工几何。
    use_user_boxes = strict_keep or (
        bool(user_boxes)
        and (n == 0 or len(user_boxes) == n)
        and not _is_even_split(user_boxes, rect, orientation)
    )
    if strict_keep:
        if len(user_boxes) != n and n > 0:
            log(
                f"[line-rec] {line_id} strict：传入 {len(user_boxes)} 框与读法 "
                f"{n} 字不一致，仍保留人工框只重填文字"
            )
    elif use_user_boxes and orientation == "horizontal":
        reject = _horizontal_user_boxes_reject_reason(user_boxes, rect)
        if reject is not None:
            log(
                f"[line-rec] {line_id} 弃用传入字框（{reject}），"
                f"走像素切分重建字框"
            )
            use_user_boxes = False
    if use_user_boxes:
        boxes = user_boxes
        boxes_src = "user(strict)" if strict_keep else "user"
    else:
        # 无编辑器字框、数量不一致、或现有框是"精确均分"的合成框（数据修复/
        # 自动均分的产物，不代表真实字形位置）时，采用像素切分框（连通域
        # 紧致框，用外扩后的行框，行首尾贴边字也在内）；切分失败回退
        # Kraken 按字符切分位置重建的条带框。横排同链路（切分器内部按
        # 行的长宽比转置后切字，此前横排走 paddle 均分槽位框，槽位与
        # 真实字形可整体错一格，已停用）。
        # 期望字数：调用方已知真实字数（AI 框检查推算）时优先于 Kraken
        # 序列字数——序列漏读/粘读时 n 不可信；横排 n=0（无序列）时给出
        # 期望字数还能让切分器启用数量校验路径。
        split_n = n
        if synthetic_placeholder:
            # 空读法兜底的占位字符不是真实读法，n=1 会把数量校验带偏：
            # 连通域对整列拆出的十几个字框 vs 期望 1 判为不匹配 → 网格
            # 兜底 n<=1 直接整行一框，"推倒重切"永远拆不开。按期望字数
            # 未知（n=0 纯连通域，与整页路径对空读法行的处理一致）走，
            # 字数交给逐框读法补齐。
            split_n = 0
        if expected_char_count is not None and expected_char_count > 0:
            if split_n != expected_char_count:
                log(
                    f"[line-rec] {line_id} 期望字数 {expected_char_count} "
                    f"覆盖序列字数 {split_n}"
                )
            split_n = expected_char_count
        split = _split_boxes_or_none(char_splitter, read_rect, split_n, f"line {line_id}")
        if split is not None and n > 0 and not _split_trusted(char_splitter):
            # 兜底切分（网格/等分）的槽位框与真实字形可整体错一格，
            # 逐框读法会读进邻字——直接弃用，改用整行读法附带字框。
            log(
                f"[line-rec] line={line_id} pixel split fallback "
                f"({getattr(char_splitter, 'last_method', '?')}): "
                f"弃用合成槽位框，改用 {adapter.cuts_src}"
            )
            split = None
        if split:
            boxes = split
            boxes_src = "pixel-split"
        elif kchars:
            boxes = [
                (int(c["x"]), int(c["y"]), int(c["w"]), int(c["h"])) for c in kchars
            ]
            boxes = _tighten_boxes_to_ink(image_path, boxes, orientation)
        else:
            # 无整行序列且切分器不可用：行框内无墨迹按异常保护
            # 报错（编辑器保留原行数据）；有墨迹则整行单框兜底，逐字
            # 读法至少读出一个字（与孤立标点列的占位语义一致）。
            if not _line_rect_has_ink(image_path, read_rect):
                raise RuntimeError(
                    f"{adapter.name} 对该行识别结果为空 rect=({rect['x']},{rect['y']},{rect['w']},{rect['h']})"
                )
            boxes = [(
                int(read_rect["x"]), int(read_rect["y"]),
                int(read_rect["w"]), int(read_rect["h"]),
            )]
            boxes_src = "line-rect-fallback"

    # 超高字框后检拆分：字+标点同框按本行字高基线检出并拆开。行重识别
    # 传入的既有字框同样要拆——"保留框几何"要保留的是人工校对的成果，
    # 不该把上一轮自动切分的合并错误（字+标点同框）代代相传。框里只有
    # 一个字形时没有可拆的标点，自然保持原几何。横排同链路（判据沿
    # 阅读轴自适应，此前横排跳过是 paddle 均分框时代的规避，已不适用）。
    boxes_split = False
    wrapped = [boxes]
    boxes_split = _split_punct_merged_line_boxes(
        image_path, wrapped, orientation, horizontal_dir
    )[0]
    if boxes_split:
        boxes = wrapped[0]
        boxes_src += "+punct-split"
    boxes = _filter_pixel_noise_boxes(image_path, boxes, read_rect, orientation)

    # 序列补读（strip_read 引擎，如 PP-OCR 竖排）：整行读法对该方向不可
    # 达、上面以 n=0 切分出字框后，用"字框裁剪→等高拼横条"整条读回序列
    # 文本（与逐字读法互相独立的两路）。合成 kchars 的字框几何为阅读轴
    # 均分（仅供对齐/兜底）。
    if (
        not kchars
        and adapter.strip_read
        and len(boxes) >= 2
    ):
        try:
            kchars = adapter.read_strip_chars(
                image_path, read_rect, boxes, orientation, horizontal_dir,
            )
            if kchars:
                log(
                    f"[line-rec] {line_id} strip 序列补读："
                    f"{len(kchars)} 字（字框 {len(boxes)}）"
                )
        except Exception as exc:
            log(f"[line-rec] {line_id} strip 序列补读失败（按无序列走）: {exc}")
            kchars = []

    # 第二阶段：逐框识别框内文字作为对齐校验信号；检测字框↔序列错位
    # （错位时弃用偏移框、改用序列字框重建并重新逐框识别）。刚拆
    # 过标点的行跳过错位重建：行首标点框会被逐位对照误判为 -1 错位。
    char_recs = adapter.read_char_boxes(image_path, boxes, orientation, horizontal_dir)
    boxes_src, boxes, box_results, crop_texts, primary = _pair_boxes_with_seq(
        image_path,
        boxes,
        boxes_src,
        kchars,
        char_recs,
        orientation,
        horizontal_dir,
        f"line={line_id}",
        # strict 人工框不做错位重建（重建=弃用人工框改序列字框条带）
        allow_offset_fix=not boxes_split and not strict_keep,
        adapter=adapter,
    )

    seq_entries = [kchars[o] if o < len(kchars) else {} for o in range(len(boxes))]
    stamp = int(time.time() * 1000)
    chars, flips, agrees = _fuse_line_chars(
        kchars,
        boxes,
        box_results,
        crop_texts,
        primary,
        id_prefix=f"k_{stamp}_",
        col=line_no,
        line_id=line_id,
        boxes_trusted=boxes_src.startswith(("pixel-split", "user")),
        char_source=adapter.char_source,
    )
    line = {
        "id": line_id,
        "x": int(read_rect["x"]),
        "y": int(read_rect["y"]),
        "w": int(read_rect["w"]),
        "h": int(read_rect["h"]),
        "line_no": int(line_no),
        "orientation": orientation,
        "text": "".join(c["text"] for c in chars),
        "chars": chars,
    }
    _log_line_decisions(
        f"line={line_id} boxes={boxes_src} rect=({rect['x']},{rect['y']},{rect['w']},{rect['h']})",
        len(boxes),
        primary,
        [(e.get("text") or "") for e in seq_entries],
        crop_texts,
        [c["text"] for c in chars],
        flips,
        agrees,
    )
    log(f"{adapter.name}_segment_line {line_id}: {len(chars)} chars")
    # 全文对照（增强路，见 _apply_full_text_check）。
    _apply_full_text_check(
        adapter,
        image_path,
        read_rect,
        orientation,
        horizontal_dir,
        vertical_dir,
        line,
        chars,
    )
    return line



def kraken_segment_line(
    image_path: str,
    rect: dict,
    line_id: str,
    line_no: int,
    orientation: str,
    horizontal_dir: str,
    char_boxes: list[tuple[int, int, int, int]] | None = None,
    char_splitter=None,
    expand: bool = True,
    strict_char_boxes: bool = False,
    expected_char_count: int | None = None,
    vertical_dir: str = "ttb",
) -> dict:
    """segment_line_core 的 kraken 薄包装（历史入口，import 面保持不变）。"""
    return segment_line_core(
        image_path,
        rect,
        line_id,
        line_no,
        orientation,
        horizontal_dir,
        char_boxes=char_boxes,
        char_splitter=char_splitter,
        expand=expand,
        strict_char_boxes=strict_char_boxes,
        expected_char_count=expected_char_count,
        vertical_dir=vertical_dir,
    )


from kraken_proc import (  # noqa: E402,F401
    SCRIPT_DIR,
    WORKER,
    MODEL_DIR,
    REC_MODEL,
    CHAT_RAW,
    REQUEST_TIMEOUT,
    PREWARM_PING_TIMEOUT,
    log,
    WorkerFailure,
    _candidate_pythons,
    _python_cache,
    kraken_python,
    ensure_models,
    _KrakenDaemon,
    _DaemonPool,
    _spawn_daemon,
    _pool,
    _pool_build_lock,
    _prewarm_guard,
    _prewarm_pool,
    _prewarm_pool_inner,
    _ensure_pool,
    pool_size,
    pool_planned,
    pool_busy,
    resize_pool,
    prewarm,
    shutdown,
)

from kraken_boxes import (  # noqa: E402,F401
    _split_boxes_or_none,
    _split_punct_merged_line_boxes,
    _split_trusted,
    _tighten_boxes_to_ink,
    _filter_pixel_noise_boxes,
    _pad_boxes_for_reading,
    _is_even_split,
    _horizontal_user_boxes_reject_reason,
    _line_rect_has_ink,
    _expand_line_rect_for_reading,
    _clamp_lines_to_image,
    _safe_text_mask,
)
