# -*- coding: utf-8 -*-
"""整页直读（PaddleOCR 全管线 / Kraken blla）的阅读序工具。

直读模式不走主区/段落/单行/单字的标注管线：引擎自己检出文本行，
这里只负责把"引擎输出顺序"（通常按检测框自上而下）重排成古籍阅读序，
并把每行文本拼成整页文本。纯函数，无 IO，供 paddle_bridge /
kraken_bridge 共用。
"""
from __future__ import annotations

import statistics


def _center(line: dict) -> tuple[float, float]:
    return (
        line["x"] + line["w"] / 2.0,
        line["y"] + line["h"] / 2.0,
    )


def _group_by_axis(lines: list[dict], axis: int, tol: float) -> list[list[dict]]:
    """按指定轴中心把行贪心聚成组（列/行），组内顺序保持轴升序。

    先按轴中心升序排，再顺序并组：与当前组_running 均值的距离 ≤ tol 就
    并入并更新均值。比固定步长量化稳——列距不均、列中心抖动（检测框
    漂移小半个列宽）都不会把同列拆散或把相邻列并错。"""
    ordered = sorted(lines, key=lambda l: _center(l)[axis])
    groups: list[dict] = []
    for line in ordered:
        c = _center(line)[axis]
        if groups and abs(c - groups[-1]["mean"]) <= tol:
            g = groups[-1]
            g["lines"].append(line)
            g["sum"] += c
            g["mean"] = g["sum"] / len(g["lines"])
        else:
            groups.append({"lines": [line], "sum": c, "mean": c})
    return [g["lines"] for g in groups]


def sort_lines_reading_order(
    lines: list[dict],
    orientation: str,
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
) -> list[dict]:
    """按阅读序重排直读出的行（返回新列表）。

    竖排：先按 x 中心聚成列（tol = 半个列宽中位数），列按阅读序排
    （rtl 从右到左 / ltr 从左到右），列内按 y（ttb 升序 / btt 降序）。
    横排：先按 y 中心聚成行，行从上到下，行内按 x（ltr 升序 / rtl 降序）。
    """
    if not lines:
        return []
    vertical = orientation != "horizontal"
    axis = 0 if vertical else 1
    spans = [max(1.0, float(l["w"] if vertical else l["h"])) for l in lines]
    # 聚类容差：同轴跨度（竖排=列宽/横排=行高）中位数的一半——同列各行
    # 中心的抖动通常远小于半个列宽，相邻列的中心距至少接近一个列宽。
    tol = statistics.median(spans) * 0.5

    groups = _group_by_axis(lines, axis, tol)
    if vertical and horizontal_dir == "rtl":
        groups.reverse()
    out: list[dict] = []
    for group in groups:
        if vertical:
            group.sort(key=lambda l: _center(l)[1], reverse=vertical_dir == "btt")
        else:
            group.sort(key=lambda l: _center(l)[0], reverse=horizontal_dir == "rtl")
        out.extend(group)
    return out


def lines_to_page_text(
    lines: list[dict],
    orientation: str,
    horizontal_dir: str = "ltr",
    vertical_dir: str = "ttb",
) -> tuple[str, list[dict]]:
    """重排 + 拼接整页文本：每行一段（\\n 分隔），返回 (text, 排序后行)。

    btt（从下到上）/rtl 的行内字符序引擎按几何正向输出，这里对行文本
    做反向，保证拼出的整页文本从头到尾都是阅读序。"""
    ordered = sort_lines_reading_order(lines, orientation, horizontal_dir, vertical_dir)
    reverse_inline = (
        vertical_dir == "btt"
        if orientation != "horizontal"
        else horizontal_dir == "rtl"
    )
    texts = []
    for line in ordered:
        text = str(line.get("text") or "")
        if reverse_inline:
            text = text[::-1]
        texts.append(text)
    return "\n".join(texts), ordered
