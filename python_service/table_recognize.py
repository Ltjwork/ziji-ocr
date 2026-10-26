# -*- coding: utf-8 -*-
"""表格单元格文字识别编排（+83 表格识别）。

table_grid 出网格几何，本模块往每格里填文字：格内连通域切字（去栏线
墨迹 mask 上直接取连通域——make_kraken_char_splitter 是为"单列行"
设计的，把整格当一条行会按格高估字尺寸、膨胀粘字，不适合多行/多列
的格子）+ 引擎逐字读（复用引擎适配器的 read_char_boxes，与编辑器
单字框补读同一条路径；kraken / paddle 同接口）。全表字框合成一批一
次 daemon 请求（逐字读同批统一放大倍数，40 格的表一次往返）。

语境增强（+161 引擎接入）：格内字框按阅读单元分组（竖排列 / 横排行），
每组再做一次**序列读法**——paddle 引擎整行/拼条读有语境（PP-OCR 对
单字裁片的读法弱于序列），kraken 竖排整行直读同源。逐字读（框里是
什么字，文本就是什么字）与序列读（语境更准）按行装配同款吻合率规则
融合（line_alignment_primary）：吻合率高信序列，错位（标点/漏字）
回落逐字读。序列读失败不阻塞表格（回落逐字读）。

格内阅读方向自动判定：瘦高格竖排、扁格横排、方形格跟随页面方向
（古籍表格的表头/备注格常与正文方向不同，横竖版书页都会出现表格，
判定只看格子几何，与页面方向无关地对称）。
"""
from __future__ import annotations

import os
import time
from statistics import median
from typing import Any

import cv2
import numpy as np

from seg_imaging import _text_mask_for_refinement
from seg_lines import line_alignment_primary
from seg_trace import _log
from table_grid import detect_table_grid


def _engine_adapter(engine: str, paddle_model: str | None):
    """表格识别的引擎触点：与整页识别同一套适配器（kraken 默认，
    paddle = PaddleEngineAdapter，行/字读法与正文行同源）。"""
    if engine == "paddle":
        from paddle_bridge import PaddleEngineAdapter

        return PaddleEngineAdapter(paddle_model)
    from kraken_bridge import _KRAKEN_ADAPTER

    return _KRAKEN_ADAPTER


def _vl_spotting_read(
    image_path: str,
    rect: tuple[int, int, int, int],
    paddle_model: str | None,
    vl_config: dict | None = None,
    vl_predict: dict | None = None,
) -> dict:
    """VL spotting 区域读（接缝，测试可 patch）。rect = (x, y, w, h)
    表格外框；返回 {"boxes","texts","confs"}（原图绝对坐标）。vl_config
    透传保证与文本视图共享同一 VL 池。"""
    from paddle_bridge import vl_spotting_read

    x, y, w, h = rect
    return vl_spotting_read(
        image_path, {"x": x, "y": y, "w": w, "h": h},
        model=paddle_model, vl_config=vl_config, vl_predict=vl_predict,
    )


def _kraken_pool_size_for_diag() -> str:
    """诊断用 kraken 池大小（懒导入，测不到返回 '?'——提示行不阻塞识别）。"""
    try:
        from kraken_bridge import pool_size

        return str(pool_size() or 0)
    except Exception:  # noqa: BLE001 —— 诊断点缀，拿不到就别提
        return "?"


# VL spotting 超时后的冷却窗（秒，按模型记）：超时意味着 VL 在当前显存
# 条件下跑不动（kraken 池挤占），窗内重试只会再烧一遍交互预算——
# 冷却期直接逐字/序列读法（秒级出结果），窗后自动再试 VL（用户调小
# 并发后无需重启服务）。PADDLE_VL_SPOT_SKIP=0 关闭。
_VL_SPOT_COOLDOWN = float(os.environ.get("PADDLE_VL_SPOT_SKIP", "600"))
_vl_spot_skip_until: dict[str, float] = {}


def _vl_cell_texts(
    image_path: str,
    grid: dict[str, Any],
    cells: list[dict[str, Any]],
    horizontal_dir: str,
    vertical_dir: str,
    paddle_model: str | None,
    vl_config: dict | None,
    vl_predict: dict | None,
    diag: list[str],
) -> dict[int, list[tuple[tuple[int, int, int, int], str, float]]]:
    """PaddleOCR-VL spotting 读表（官网 Demo 同款能力源）：裁剪表格外框
    → VL 文本检测与识别 → 文本框按中心归格。返回
    {格序号: [(VL 框, 文本, conf), ...]（格内阅读序）}；失败返回空
    （调用方回落逐字/序列读法）。"""
    cooldown_left = _vl_spot_skip_until.get(paddle_model or "", 0.0) - time.time()
    if cooldown_left > 0:
        diag.append(
            f"VL spotting 跳过：近期超时过（冷却期还剩 {cooldown_left:.0f}s，"
            "显存挤占时 VL 跑不动不重试）；直接逐字/序列读法。把"
            "「设置 → 识别进程数」调小可立即恢复 VL 读表"
        )
        return {}
    try:
        spot = _vl_spotting_read(
            image_path,
            (grid["x"], grid["y"], grid["w"], grid["h"]),
            paddle_model,
            vl_config,
            vl_predict,
        )
    except Exception as exc:  # noqa: BLE001 —— VL 失败回落，不阻塞表格
        diag.append(f"VL spotting 失败：{exc} → 回落逐字/序列读法")
        if "超时" in str(exc):
            _vl_spot_skip_until[paddle_model or ""] = (
                time.time() + _VL_SPOT_COOLDOWN
            )
            try:
                from paddle_bridge import SPOT_TIMEOUT as spot_budget
            except ImportError:  # 测试环境无 paddle_bridge 时省略预算数
                spot_budget = None
            budget = (
                f"（交互预算 {spot_budget:.0f}s）" if spot_budget else ""
            )
            diag.append(
                f"VL 推理超时{budget}：多半是显存被并行识别进程挤占——"
                f"当前 kraken 池 {_kraken_pool_size_for_diag()} 路各占一份"
                "显存。把「设置 → 识别进程数」调回自动（按硬件）或调小，"
                f"VL 读表（质量更好）即可恢复（{_VL_SPOT_COOLDOWN:.0f}s 后"
                "自动重试）；本次已回落逐字/序列读法，结果照常秒级返回。"
            )
        return {}
    boxes = spot.get("boxes") or []
    texts = spot.get("texts") or []
    confs = spot.get("confs") or []
    per_cell: dict[int, list[tuple[tuple, str, float]]] = {}
    for i, b in enumerate(boxes):
        if i >= len(texts):
            break
        cx = b["x"] + b["w"] / 2.0
        cy = b["y"] + b["h"] / 2.0
        for ci, cell in enumerate(cells):
            if (
                cell["x"] <= cx <= cell["x"] + cell["w"]
                and cell["y"] <= cy <= cell["y"] + cell["h"]
            ):
                per_cell.setdefault(ci, []).append(
                    (
                        (int(b["x"]), int(b["y"]), int(b["w"]), int(b["h"])),
                        str(texts[i]),
                        float(confs[i]) if i < len(confs) else 0.0,
                    )
                )
                break
    out: dict[int, list[tuple[tuple, str, float]]] = {}
    for ci, hits in per_cell.items():
        cell = cells[ci]
        rects = [h[0] for h in hits]
        by_rect = {h[0]: h for h in hits}
        ordered = [
            by_rect[r] for r in _order_rects(
                rects, cell["orientation"], horizontal_dir, vertical_dir
            )
            if r in by_rect
        ]
        if any(h[1] for h in ordered):
            out[ci] = ordered
    diag.append(
        f"VL spotting：{len(boxes)} 文本框 → {len(out)} 格有文本"
        f"（区域裁剪 {grid['w']}×{grid['h']}）"
    )
    return out


def _distribute_vl_chars(
    boxes: list[tuple[int, int, int, int]],
    vl_rect: tuple[int, int, int, int],
    text: str,
    orientation: str,
) -> list[str]:
    """VL 文本字符按阅读轴位置分布到格内墨迹字框（纯几何，零 OCR）：
    VL 框的阅读轴区间按字符数等分，字符中心落在哪个字框的轴区间内就
    归哪框（一框可得多字拼接）；落在框间空隙的字符（分隔符等）不占框
    ——高亮锚点足够，正文仍以 VL 文本为准。"""
    n = len(boxes)
    out = [""] * n
    if n == 0 or not text:
        return out
    if orientation == "vertical":
        v0, v1 = vl_rect[1], vl_rect[1] + vl_rect[3]
        spans = [(b[1], b[1] + b[3]) for b in boxes]
    else:
        v0, v1 = vl_rect[0], vl_rect[0] + vl_rect[2]
        spans = [(b[0], b[0] + b[2]) for b in boxes]
    total = len(text)
    if v1 <= v0:
        return out
    for i, ch in enumerate(text):
        c = v0 + (i + 0.5) / total * (v1 - v0)
        for bi, (a0, a1) in enumerate(spans):
            if a0 <= c <= a1:
                out[bi] += ch
                break
    return out


# 方形格（宽高比在 [1/1.5, 1.5] 内）跟随页面方向，更扁/更高才反转。
_SQUARE_RATIO = 1.5
# 碎块过滤：面积 < 同格中位字框面积 6% 的连通域（断线残墨、格线毛刺）
# 不参与识别。
_FRAG_AREA_FRACTION = 0.06
# 极端细长的连通域（去栏线后残余的断线段）不是字。
_THIN_RATIO = 6.0
# 斜杠/分隔笔画滤：墨迹填充率 < 0.35 且面积 < 同格中位字一半的连通域
# 视为字间分隔斜杠（实体字填充率 ≥0.45；稀疏实体字面积与同格字相当，
# 被面积条件保住）。
_SLASH_FILL = 0.35
_SLASH_AREA = 0.5


def cell_orientation(
    cell: dict[str, Any], page_orientation: str
) -> str:
    """格内文字方向：几何优先，方形格跟随页面。"""
    w, h = float(cell["w"]), float(cell["h"])
    if w > h * _SQUARE_RATIO:
        return "horizontal"
    if h > w * _SQUARE_RATIO:
        return "vertical"
    return page_orientation


def _reading_groups(
    rects: list[tuple[int, int, int, int]],
    orientation: str,
    horizontal_dir: str,
    vertical_dir: str,
) -> list[tuple[tuple[int, int, int, int], list[tuple[int, int, int, int]]]]:
    """格内字框按阅读单元分组：竖排 = 列（列序 = horizontal_dir，列内
    序 = vertical_dir）；横排 = 行（行序 = vertical_dir，行内序恒为
    左→右——横排汉字天然从左往右读，页面 rtl 是竖排的列序方向，不
    适用于横排格；实测竖排 rtl 书的时辰表横排标签被反读成「點至夜午」
    （实为「午夜至點」），根因即此）。列/行划分用中位字宽做容差——
    同列字的 x 抖动小于半个字宽。返回 [(组外接框, 组内阅读序字框)]，
    组间按阅读序排列。"""
    if not rects:
        return []

    def center(a: tuple[int, int, int, int], i: int) -> float:
        return a[i] + a[i + 2] / 2

    clusters: list[list[float | list]] = []
    if orientation == "vertical":
        span = median(r[2] for r in rects)
        for r in sorted(rects, key=lambda r: center(r, 0)):
            c = center(r, 0)
            if clusters and abs(c - clusters[-1][0]) <= max(4.0, span * 0.6):
                clusters[-1][1].append(r)
                clusters[-1][0] = (clusters[-1][0] + c) / 2
            else:
                clusters.append([c, [r]])
        if horizontal_dir == "rtl":
            clusters.reverse()
        for cl in clusters:
            cl[1].sort(
                key=lambda r: -r[1] if vertical_dir == "btt" else r[1]
            )
    else:
        span = median(r[3] for r in rects)
        for r in sorted(rects, key=lambda r: center(r, 1)):
            c = center(r, 1)
            if clusters and abs(c - clusters[-1][0]) <= max(4.0, span * 0.6):
                clusters[-1][1].append(r)
                clusters[-1][0] = (clusters[-1][0] + c) / 2
            else:
                clusters.append([c, [r]])
        if vertical_dir == "btt":
            clusters.reverse()
        # 行内恒左→右（见 docstring）
        for cl in clusters:
            cl[1].sort(key=lambda r: r[0])

    groups: list[tuple[tuple[int, int, int, int], list]] = []
    for _, members in clusters:
        x0 = min(r[0] for r in members)
        y0 = min(r[1] for r in members)
        x1 = max(r[0] + r[2] for r in members)
        y1 = max(r[1] + r[3] for r in members)
        groups.append(((x0, y0, x1 - x0, y1 - y0), members))
    return groups


def _order_rects(
    rects: list[tuple[int, int, int, int]],
    orientation: str,
    horizontal_dir: str,
    vertical_dir: str,
) -> list[tuple[int, int, int, int]]:
    """格内字框排阅读序（= 阅读单元分组按序展开）。"""
    return [
        r
        for _, members in _reading_groups(
            rects, orientation, horizontal_dir, vertical_dir
        )
        for r in members
    ]


def _cell_char_rects(
    mask: np.ndarray,
    cell: dict[str, Any],
) -> tuple[list[tuple[int, int, int, int]], dict[str, int]]:
    """格内字框：去栏线 mask 的连通域 → 中心入格 → 细长线/斜杠/碎块过滤。

    窗口向格外放 3px：贴格线的字（格线剔除处略缺墨）完整入框，靠
    中心入格过滤兜住越界部分。返回 (字框, 过滤统计)——统计进识别日志
    （连通域/出格/细长/斜杠/碎块各滤了多少，漏字时可对照原图定位环节）。
    """
    empty = {"components": 0, "outside": 0, "thin": 0, "slash": 0, "frag": 0}
    pad = 3
    cx0 = max(0, cell["x"] - pad)
    cy0 = max(0, cell["y"] - pad)
    cx1 = min(mask.shape[1], cell["x"] + cell["w"] + pad)
    cy1 = min(mask.shape[0], cell["y"] + cell["h"] + pad)
    if cx1 - cx0 < 4 or cy1 - cy0 < 4:
        return [], empty
    sub = (mask[cy0:cy1, cx0:cx1] > 0).astype(np.uint8)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(sub)
    # (x, y, w, h, ink_area)：面积留在框上供斜杠滤用
    comps = [
        (int(sx), int(sy), int(sw), int(sh), int(sa))
        for i in range(1, n)
        for sx, sy, sw, sh, sa in (stats[i],)
        if sa >= 4
    ]
    # 绝对坐标 + 中心入格
    abs_rects = [(cx0 + c[0], cy0 + c[1], c[2], c[3], c[4]) for c in comps]
    gx0, gy0 = cell["x"], cell["y"]
    gx1, gy1 = cell["x"] + cell["w"], cell["y"] + cell["h"]
    inside = [
        r for r in abs_rects
        if gx0 <= r[0] + r[2] / 2 <= gx1 and gy0 <= r[1] + r[3] / 2 <= gy1
    ]
    fstats = {
        "components": len(abs_rects),
        "outside": len(abs_rects) - len(inside),
        "thin": 0,
        "slash": 0,
        "frag": 0,
    }
    if not inside:
        return [], fstats
    # 细长线残余丢弃（长宽比 > _THIN_RATIO）
    kept = [
        r for r in inside
        if max(r[2], r[3]) <= min(r[2], r[3]) * _THIN_RATIO
    ]
    fstats["thin"] = len(inside) - len(kept)
    if not kept:
        return [], fstats
    # 斜杠/分隔笔画滤：格内的字间分隔斜杠 bbox 近方形（长宽比过不了
    # 细长滤），但墨迹填充率远低于实体字（斜杠 ~0.3，字 ≥0.45）且墨迹
    # 面积不足同格中位字一半——实测干支表「甲/己」格中的分隔斜杠被逐字
    # 读成 I/1/L。实体稀疏字（二/八）填充率也低，但面积与同格字相当，
    # 面积条件保它们不被误滤。
    med_area = median(r[4] for r in kept)
    solid = [
        r for r in kept
        if r[4] / max(1, r[2] * r[3]) >= _SLASH_FILL
        or r[4] >= med_area * _SLASH_AREA
    ]
    fstats["slash"] = len(kept) - len(solid)
    if not solid:
        return [], fstats
    # 碎块滤（相对中位字框面积）
    med_box = median(r[2] * r[3] for r in solid)
    final = [r for r in solid if r[2] * r[3] >= med_box * _FRAG_AREA_FRACTION]
    fstats["frag"] = len(solid) - len(final)
    return [(r[0], r[1], r[2], r[3]) for r in final], fstats


def _group_sequence_chars(
    adapter,
    image_path: str,
    groups: list[tuple[tuple[int, int, int, int], list]],
    orientation: str,
    horizontal_dir: str,
) -> list[list[dict] | None]:
    """一组同方向阅读单元的序列读法（语境增强）：返回与 groups 同序的
    [序列字列表]（不可达/失败为 None）。竖排：kraken 整行直读（整批一
    次请求）、paddle 字框拼条（每组一次请求）；横排：paddle 整行直读
    （整批一次请求；kraken 无横排域，调用方不收集横排组）。"""
    out: list[list[dict] | None] = []
    if not groups:
        return out
    if orientation == "horizontal" and not getattr(
        adapter, "horizontal_line_read", False
    ):
        return [None] * len(groups)
    rects = [
        {"x": int(g[0][0]), "y": int(g[0][1]),
         "w": int(g[0][2]), "h": int(g[0][3])}
        for g in groups
    ]
    if orientation == "horizontal" or getattr(
        adapter, "vertical_line_read", False
    ):
        lines = adapter.read_lines(
            image_path, rects, orientation, horizontal_dir
        )
        for ln in lines:
            chars = [
                {"text": str((c.get("text") or "").strip()[:1]),
                 "conf": float(c.get("conf") or 0.0)}
                for c in (ln.get("chars") or [])
            ]
            out.append(chars or None)
        return out
    # paddle 竖排：字框拼条序列读法（每组一次请求）。read_strip_chars
    # 的 rect 参数是 dict（PaddleEngineAdapter 里 rect.get(...)），此处
    # 必须转——曾因直传 tuple 抛 'tuple' object has no attribute 'get'，
    # 竖排序列读整方向失败、全部回落逐字读。
    for rect, members in zip(rects, (g[1] for g in groups)):
        chars = adapter.read_strip_chars(
            image_path, rect, members, orientation, horizontal_dir
        )
        entries = [
            {"text": str((c.get("text") or "").strip()[:1]),
             "conf": float(c.get("conf") or 0.0)}
            for c in (chars or [])
        ]
        out.append(entries or None)
    return out


def _fuse_sequence(
    recs: list[dict],
    crop_texts: list[str],
    groups: list[tuple[int, str, tuple, list, str]],
    seq_by_start: dict[int, list[dict] | None],
    diag: list[str] | None = None,
) -> None:
    """逐组融合：序列读法与逐字读法吻合率高（语境读法对齐可信）时正文
    取序列字，错位/失败保持逐字读结果（line_alignment_primary 的行装配
    同款规则；字框是墨迹连通域锚定的，boxes_trusted）。决策逐组写入
    [diag]（识别日志）：两路文本与吻合数都在，差异可对照原图分析。"""
    for start, _orientation, _grect, members, label in groups:
        seq = seq_by_start.get(start)
        crop_group = crop_texts[start: start + len(members)]
        if seq is None:
            if diag is not None:
                diag.append(
                    f"{label} 序列读=无（引擎不支持/失败）"
                    f" 框内=「{''.join(crop_group)}」 → 保持框内"
                )
            continue
        seq_texts = [c["text"] for c in seq]
        if len(seq) != len(members):
            # 数量不匹配时的安全子序列修剪：序列字**全部**按序对上框内
            # 读法（框里多出复读字/斜杠残框）时，多余的框读空——
            # 「99至11點」→「9至11點」、「下下午1至3點」→「下午1至3點」。
            # 只按"文本相等"配对，不引入序列的错读字；序列字对不齐则
            # 整组放弃（保持框内读法，防序列误读覆写正确框内读法）。
            seq_of_box: dict[int, int] = {}
            si = 0
            for k in range(len(members)):
                if (
                    si < len(seq)
                    and crop_group[k]
                    and crop_group[k] == seq[si]["text"]
                ):
                    seq_of_box[k] = si
                    si += 1
            if len(seq) >= 2 and si == len(seq):
                for k in range(len(members)):
                    s_i = seq_of_box.get(k)
                    recs[start + k] = (
                        dict(seq[s_i]) if s_i is not None
                        else {"text": "", "conf": 0.0}
                    )
                if diag is not None:
                    diag.append(
                        f"{label} 序列=「{''.join(seq_texts)}」"
                        f"({len(seq)}字) 框内=「{''.join(crop_group)}」"
                        f"({len(members)}框) → 子序列对齐，滤多余框 "
                        f"{len(members) - len(seq)}"
                    )
            elif diag is not None:
                diag.append(
                    f"{label} 序列=「{''.join(seq_texts)}」"
                    f"({len(seq)}字) 框内=「{''.join(crop_group)}」"
                    f"({len(members)}框) → 数量不匹配，保持框内"
                )
            continue
        comparable = sum(1 for a, b in zip(crop_group, seq_texts) if a and b)
        matches = sum(1 for a, b in zip(crop_group, seq_texts) if a and a == b)
        take_seq = line_alignment_primary(
            crop_group, seq_texts, boxes_trusted=True,
        ) == "seq"
        if diag is not None:
            diag.append(
                f"{label} 序列=「{''.join(seq_texts)}」"
                f"(conf.{max((c['conf'] for c in seq), default=0):.2f}) "
                f"框内=「{''.join(crop_group)}」 吻合{matches}/{comparable} "
                f"→ {'取序列（语境）' if take_seq else '保持框内'}"
            )
        if not take_seq:
            continue
        for k, entry in enumerate(seq):
            if entry["text"]:
                recs[start + k] = {
                    "text": entry["text"],
                    "conf": entry["conf"],
                }


def recognize_table(
    image_path: str,
    x: int,
    y: int,
    w: int,
    h: int,
    orientation: str = "vertical",
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
    engine: str = "kraken",
    paddle_model: str | None = None,
    vl_config: dict | None = None,
    vl_predict: dict | None = None,
) -> dict[str, Any]:
    """表格识别入口：网格 + 每格文字（含字框与逐字置信度）。

    坐标均为全图绝对像素。格线不足时透传 detect_table_grid 的
    ok=False + reason；识别异常同样落到 ok=False（网格几何仍返回，
    文字留空由前端提示重试）。[engine]/[paddle_model]/[vl_config]/
    [vl_predict] 与整页识别同一口径（kraken 默认；paddle 随书内模型，
    VL 书走 spotting 读表）；vl_config 保证与文本视图共享同一个 VL 池
    （池按模型+解析配置绑定，缺省会因签名不同反复重建池）。
    """
    grid = detect_table_grid(image_path, x, y, w, h)
    if not grid.get("ok"):
        return grid
    cells: list[dict[str, Any]] = grid["cells"]
    adapter = _engine_adapter(engine, paddle_model)
    try:
        from paddle_bridge import is_vl_model

        vl_book = engine == "paddle" and bool(paddle_model) and is_vl_model(
            paddle_model
        )
    except ImportError:  # 测试环境无 paddle_bridge 时按非 VL 处理
        vl_book = False
    t_start = time.time()
    # 识别日志（诊断差异用：随结果返回 grid["log"]，前端可查看/复制）：
    # 引擎与模型 → 每格连通域与过滤 → 逐字读/序列读与逐组融合决策 →
    # 汇总耗时。与官网 Demo 效果不一致时，逐行对照即可定位差异环节。
    # 引擎行如实显示**书内设置的模型**（VL 书的逐字/序列兜底是行级小
    # 模型，只作兜底说明，不再让首行看起来像没用书内模型）。
    if engine == "paddle":
        engine_line = (
            f"引擎=paddle（书内模型 {str(paddle_model or '').strip() or '默认档'}）"
        )
        if vl_book:
            engine_line += f"：VL spotting 读表，逐字/序列兜底 {adapter.model}"
    else:
        engine_line = f"引擎={adapter.ocr_tag}"
    diag: list[str] = [
        engine_line + f" 方向={orientation}/{horizontal_dir}/{vertical_dir}",
        f"序列读法：竖排={'字框拼条' if not getattr(adapter, 'vertical_line_read', True) else '整行直读'}"
        f" 横排={'整行直读' if getattr(adapter, 'horizontal_line_read', False) else '不支持（跳过）'}",
        f"网格 {grid['rows']}×{grid['cols']} 格数={len(cells)}"
        f" 外框=({grid['x']},{grid['y']},{grid['w']},{grid['h']})",
    ]
    try:
        mask = _text_mask_for_refinement(image_path)
        if mask is None:
            for cell in cells:
                cell["orientation"] = cell_orientation(cell, orientation)
                cell["text"], cell["chars"] = "", []
            grid["reason"] = "无法生成页面墨迹 mask"
            grid["ocr"] = "unavailable"
            diag.append("失败：无法生成页面墨迹 mask")
            grid["log"] = diag
            return grid
        # PaddleOCR-VL 书：先跑 VL spotting（官网 Demo 同款质量源），
        # 文本按格归属；VL 覆盖的格跳过逐字/序列读（见下），字框几何供
        # 高亮。VL 失败时全部回落逐字/序列读法。
        vl_cell_text: dict[int, list[tuple[tuple, str, float]]] = {}
        if vl_book:
            for cell in cells:
                cell["orientation"] = cell_orientation(cell, orientation)
            vl_cell_text = _vl_cell_texts(
                image_path, grid, cells,
                horizontal_dir, vertical_dir, paddle_model,
                vl_config, vl_predict, diag,
            )
        # 先全表收集字框（mask 内部有缓存，只算一次），再合成一批逐字读。
        # VL 已覆盖的格**跳过**逐字/序列读——省一批小模型请求与 96 组逐
        # 组拼条往返，更不把 paddle 池从 VL 切到小模型再重载（此前 VL 书
        # 每次表格识别都往返切池，是慢的主因之一）；字框文本用纯几何分布
        # （_distribute_vl_chars）。VL 全覆盖时完全不触小模型池。
        vl_covered = set(vl_cell_text)
        pending = [i for i in range(len(cells)) if i not in vl_covered]
        if vl_cell_text and not pending:
            diag.append(
                f"VL 全覆盖 {len(cells)} 格：跳过逐字/序列读（不切换识别池）"
            )
        elif vl_cell_text:
            diag.append(
                f"VL 覆盖 {len(vl_cell_text)}/{len(cells)} 格："
                f"未覆盖 {len(pending)} 格走逐字/序列读法"
            )
        per_cell: list[list[tuple[int, int, int, int]]] = []
        for cell in cells:
            cell["orientation"] = cell_orientation(cell, orientation)
            rects, cstats = _cell_char_rects(mask, cell)
            diag.append(
                f"格({cell['row']},{cell['col']}) {cell['w']}×{cell['h']}"
                f" {'竖排' if cell['orientation'] == 'vertical' else '横排'}"
                f" 连通域={cstats['components']}"
                f" 出格={cstats['outside']} 细长滤={cstats['thin']}"
                f" 斜杠滤={cstats['slash']} 碎块滤={cstats['frag']}"
                f" → 字框{len(rects)}"
            )
            per_cell.append(_order_rects(
                rects, cell["orientation"], horizontal_dir, vertical_dir
            ))
        flat = [
            r for i in pending for r in per_cell[i]
        ]
        t_read = time.time()
        recs: list[dict] = (
            adapter.read_char_boxes(
                image_path, flat, orientation, horizontal_dir, pad=True
            )
            if flat
            else []
        )
        t_read = time.time() - t_read
        diag.append(
            f"逐字读：{len(flat)} 框一批一次请求，{t_read:.1f}s"
        )
        # 序列读法（语境增强）：格内按阅读单元分组，逐字读与序列读按
        # 行装配同款吻合率融合。kraken 横排无序列域（horizontal_line_read
        # =False），跳过横排组。
        if flat:
            groups: list[tuple[int, str, tuple, list, str]] = []
            pos = 0
            for i in pending:
                cell, rects = cells[i], per_cell[i]
                label = f"格({cell['row']},{cell['col']})"
                for grect, members in _reading_groups(
                    rects, cell["orientation"], horizontal_dir, vertical_dir
                ):
                    groups.append(
                        (pos, cell["orientation"], grect, members, label)
                    )
                    pos += len(members)
            seq_by_start: dict[int, list[dict] | None] = {}
            for group_orientation in ("vertical", "horizontal"):
                if (
                    group_orientation == "horizontal"
                    and not getattr(adapter, "horizontal_line_read", False)
                ):
                    continue
                bucket = [
                    g for g in groups if g[1] == group_orientation
                ]
                if not bucket:
                    continue
                t_seq = time.time()
                try:
                    seqs = _group_sequence_chars(
                        adapter, image_path,
                        [(g[2], g[3]) for g in bucket],
                        group_orientation, horizontal_dir,
                    )
                except Exception as exc:  # noqa: BLE001 —— 序列读失败回落逐字读
                    _log(
                        f"[table] 序列读法失败（{group_orientation}），"
                        f"回落逐字读：{exc}"
                    )
                    diag.append(
                        f"序列读失败（{'横排' if group_orientation == 'horizontal' else '竖排'}）："
                        f"{exc} → 该方向全部保持框内读法"
                    )
                    seqs = []
                t_seq = time.time() - t_seq
                diag.append(
                    f"序列读（{'横排' if group_orientation == 'horizontal' else '竖排'}）："
                    f"{len(bucket)} 组，{t_seq:.1f}s"
                )
                for g, seq in zip(bucket, seqs):
                    seq_by_start[g[0]] = seq
            recs = [dict(r) for r in recs]
            _fuse_sequence(
                recs,
                [(r.get("text") or "").strip()[:1] for r in recs],
                groups,
                seq_by_start,
                diag,
            )
    except Exception as exc:  # noqa: BLE001 —— daemon 池/切分异常不吞几何
        grid["reason"] = f"单元格识别失败：{exc}"
        grid["ocr"] = "unavailable"
        for cell in cells:
            cell["orientation"] = cell_orientation(cell, orientation)
            cell["text"], cell["chars"] = "", []
        diag.append(f"失败：单元格识别异常 {exc}")
        grid["log"] = diag
        return grid
    pos = 0
    for ci, (cell, rects) in enumerate(zip(cells, per_cell)):
        # 逐字/序列读只覆盖 VL 未读的格（pending）；VL 格 chunk 为空，
        # 字框文本由几何分布填充。
        if ci in vl_cell_text:
            chunk: list[dict] = []
        else:
            chunk = recs[pos: pos + len(rects)]
            pos += len(rects)
        cell["text"] = "".join((c.get("text") or "").strip() for c in chunk)
        cell["chars"] = [
            {
                "x": int(r[0]), "y": int(r[1]), "w": int(r[2]), "h": int(r[3]),
                "text": (chunk[k].get("text") or "").strip()
                    if k < len(chunk) else "",
                "conf": float(chunk[k].get("conf") or 0.0)
                    if k < len(chunk) else 0.0,
            }
            for k, r in enumerate(rects)
        ]
        # VL spotting 覆盖（官网同款质量源）：正文取 VL 文本；VL 字符按
        # 阅读轴位置几何分布到墨迹字框（高亮锚点，零 OCR 请求），落在
        # 框间空隙的字符（分隔符）不占框。
        vl = vl_cell_text.get(ci)
        if vl is not None:
            vl_text = "".join(h[1] for h in vl)
            vl_conf = max((h[2] for h in vl), default=0.0)
            assigned = 0
            for hit_rect, hit_text, hit_conf in vl:
                dist = _distribute_vl_chars(
                    rects, hit_rect, hit_text, cell["orientation"]
                )
                for bi, part in enumerate(dist):
                    if part:
                        ch = cell["chars"][bi]
                        ch["text"] = (ch["text"] or "") + part
                        ch["conf"] = max(ch["conf"], hit_conf)
                        assigned += 1
            cell["text"] = vl_text
            diag.append(
                f"格({cell['row']},{cell['col']}) VL=「{vl_text}」"
                f"(conf.{vl_conf:.2f}) → 取 VL（{assigned}/{len(rects)} 框锚定）"
            )
    if vl_cell_text:
        grid["ocr"] = f"paddle-vl+{paddle_model}(spotting)"
    else:
        # VL 书回落时引擎标记如实注明原因——否则末行只写兜底小模型名，
        # 看起来像书内 VL 设置没生效（首行虽已显示书内模型，末行仍易误读）。
        vl_note = next(
            (
                "VL 超时回落"
                if ("超时" in ln or "冷却" in ln)
                else "VL 失败回落"
                for ln in diag
                if ln.startswith(("VL spotting 失败：", "VL spotting 跳过："))
            ),
            "",
        )
        grid["ocr"] = (
            f"{adapter.ocr_tag}（{vl_note}）" if vl_note else adapter.ocr_tag
        )
    diag.append(
        f"完成：{len(cells)} 格 / {sum(len(r) for r in per_cell)} 字"
        f" / 共 {time.time() - t_start:.1f}s / ocr={grid['ocr']}"
    )
    grid["log"] = diag
    _log("[table] 识别日志：\n  " + "\n  ".join(diag))
    return grid
