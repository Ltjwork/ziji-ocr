# -*- coding: utf-8 -*-
"""易经卦图领域知识（纯逻辑，无图像/IO 依赖）。

三块内容，供 hexagram_chart（几何检测）与 hexagram_recognize（识别
编排）复用，插件端按同一 JSON 口径镜像：

- 卦体：六爻阴阳 → 文王卦序 / 卦名 / Unicode 卦符（U+4DC0..U+4DFF，
  64 卦一一对应），爻名（初九/六二…）由阴阳直接推导。
- 干支：十天干 × 十二地支封闭字表；六十甲子合法配对（奇偶同序）。
  干支之外常见标注字（五行 / 六亲 / 世应）单列宽表——宽表字只警告，
  字表外（多半是引擎误读）记硬错误。
- 京房纳甲：八宫卦爻纳干支定表（纳甲歌：乾金甲子外壬午……），任一
  六爻卦由下卦内纳 + 上卦外纳拼出六爻干支。卦体（几何判阴阳，稳）
  与标注字（引擎读，可能错）两路独立，互相比对就是卦图的"校验和"。
- render_svg：结构化记录 → 仿古竖排 SVG，供回渲染对照校对与导出嵌入
  （插件页的交互渲染与此同数据同布局）。

lines 记录口径（与插件/前端互指）：自下而上 pos 1..6（初爻→上爻），
left/right 为该爻左右标注字列表（元素含 x/y/w/h/text/conf）。
"""
from __future__ import annotations

from typing import Any, Iterable

# ── 干支 ─────────────────────────────────────────────────────────

HEAVENLY_STEMS = "甲乙丙丁戊己庚辛壬癸"
EARTHLY_BRANCHES = "子丑寅卯辰巳午未申酉戌亥"
GANZHI_CHARS = frozenset(HEAVENLY_STEMS + EARTHLY_BRANCHES)
# 干支之外的常见卦图标注字（五行/六亲/世应/动）：见到不报错，只提示
# "非干支字"，避免正常书页被当误读。
KNOWN_EXTRA_CHARS = frozenset("水火木金土父母兄弟子孙妻财官世应")

_STEM_INDEX = {c: i for i, c in enumerate(HEAVENLY_STEMS)}
_BRANCH_INDEX = {c: i for i, c in enumerate(EARTHLY_BRANCHES)}


def is_valid_ganzhi_pair(text: str) -> bool:
    """两字干支配对合法性：干前支后，且奇偶同序（六十甲子表成员）。"""
    if len(text) != 2:
        return False
    s, b = text[0], text[1]
    if s not in _STEM_INDEX or b not in _BRANCH_INDEX:
        return False
    return _STEM_INDEX[s] % 2 == _BRANCH_INDEX[b] % 2


# ── 八卦与文王卦序 ────────────────────────────────────────────────

# 三爻阴阳（自下而上）与自然象。
TRIGRAM_BITS: dict[str, tuple[int, int, int]] = {
    "乾": (1, 1, 1), "兑": (1, 1, 0), "离": (1, 0, 1), "震": (1, 0, 0),
    "巽": (0, 1, 1), "坎": (0, 1, 0), "艮": (0, 0, 1), "坤": (0, 0, 0),
}
TRIGRAM_NATURE = {"乾": "天", "坤": "地", "震": "雷", "巽": "风",
                  "坎": "水", "离": "火", "艮": "山", "兑": "泽"}

# 文王卦序表：(卦名, 上卦, 下卦)，下标+1 即卦序（Unicode 卦符
# U+4DC0+卦序-1）。如 (19, "临", 坤上兑下) → 地泽临 ䷒。
KING_WEN: list[tuple[str, str, str]] = [
    ("乾", "乾", "乾"), ("坤", "坤", "坤"), ("屯", "坎", "震"),
    ("蒙", "艮", "坎"), ("需", "坎", "乾"), ("讼", "乾", "坎"),
    ("师", "坤", "坎"), ("比", "坎", "坤"), ("小畜", "巽", "乾"),
    ("履", "乾", "兑"), ("泰", "坤", "乾"), ("否", "乾", "坤"),
    ("同人", "乾", "离"), ("大有", "离", "乾"), ("谦", "坤", "艮"),
    ("豫", "震", "坤"), ("随", "兑", "震"), ("蛊", "艮", "巽"),
    ("临", "坤", "兑"), ("观", "巽", "坤"), ("噬嗑", "离", "震"),
    ("贲", "艮", "离"), ("剥", "艮", "坤"), ("复", "坤", "震"),
    ("无妄", "乾", "震"), ("大畜", "艮", "乾"), ("颐", "艮", "震"),
    ("大过", "兑", "巽"), ("坎", "坎", "坎"), ("离", "离", "离"),
    ("咸", "兑", "艮"), ("恒", "震", "巽"), ("遁", "乾", "艮"),
    ("大壮", "震", "乾"), ("晋", "离", "坤"), ("明夷", "坤", "离"),
    ("家人", "巽", "离"), ("睽", "离", "兑"), ("蹇", "坎", "艮"),
    ("解", "震", "坎"), ("损", "艮", "兑"), ("益", "巽", "震"),
    ("夬", "兑", "乾"), ("姤", "乾", "巽"), ("萃", "兑", "坤"),
    ("升", "坤", "巽"), ("困", "兑", "坎"), ("井", "坎", "巽"),
    ("革", "兑", "离"), ("鼎", "离", "巽"), ("震", "震", "震"),
    ("艮", "艮", "艮"), ("渐", "巽", "艮"), ("归妹", "震", "兑"),
    ("丰", "震", "离"), ("旅", "离", "艮"), ("巽", "巽", "巽"),
    ("兑", "兑", "兑"), ("涣", "巽", "坎"), ("节", "坎", "兑"),
    ("中孚", "巽", "兑"), ("小过", "震", "艮"), ("既济", "坎", "离"),
    ("未济", "离", "坎"),
]

_TRIGRAM_BY_BITS = {v: k for k, v in TRIGRAM_BITS.items()}


def _bits_to_king_wen() -> dict[tuple[int, ...], int]:
    table: dict[tuple[int, ...], int] = {}
    for num, (_name, upper, lower) in enumerate(KING_WEN, start=1):
        bits = TRIGRAM_BITS[lower] + TRIGRAM_BITS[upper]
        table[bits] = num
    assert len(table) == 64, "文王卦序表阴阳组合必须恰好 64 种"
    return table


_BITS_TO_KING_WEN = _bits_to_king_wen()

_POS_NUM = ["初", "二", "三", "四", "五", "上"]


def yao_name(pos: int, yang: bool) -> str:
    """爻名：阳用九、阴用六；初爻/上爻数字在后（初九/上六），中爻
    数字在前（九二/六五）。"""
    n = _POS_NUM[pos - 1]
    w = "九" if yang else "六"
    return (n + w) if pos in (1, 6) else (w + n)


def _normalize_bits(bits: Any) -> list[int]:
    """接受 '110000' / (1,1,0,…) / (True,…)（自下而上）统一成 0/1 列表。"""
    if isinstance(bits, str):
        seq: Iterable[Any] = bits
        vals = [int(c) for c in seq]
    else:
        vals = [1 if b else 0 for b in bits]
    if len(vals) != 6:
        raise ValueError("卦体必须为六爻（自下而上）")
    return vals


def hexagram_info(bits: Any) -> dict[str, Any]:
    """六爻阴阳（自下而上）→ 卦体信息（卦序/卦名/Unicode 卦符/爻名）。"""
    vals = _normalize_bits(bits)
    key = tuple(vals)
    num = _BITS_TO_KING_WEN.get(key)
    if num is None:  # 理论不可达（2^6 全覆盖），保底防御
        raise ValueError(f"非法卦体：{key}")
    name, upper, lower = KING_WEN[num - 1]
    if upper == lower:
        full_name = f"{name}为{TRIGRAM_NATURE[upper]}"
    else:
        full_name = (
            TRIGRAM_NATURE[upper] + TRIGRAM_NATURE[lower] + name
        )
    cp = 0x4DC0 + num - 1
    return {
        "king_wen": num,
        "name": name,
        "full_name": full_name,
        "unicode": chr(cp),
        "unicode_cp": f"U+{cp:04X}",
        "bits": "".join(str(v) for v in vals),
        "lower": lower,
        "upper": upper,
        "yao_names": [
            yao_name(pos, bool(v)) for pos, v in enumerate(vals, start=1)
        ],
    }


# ── 京房纳甲 ──────────────────────────────────────────────────────

# 八宫纳干支定表（纳甲歌口径）：(内卦纳干, 内卦三爻地支[自下而上],
#                              外卦纳干, 外卦三爻地支[自下而上])。
# 阳卦地支顺行、阴卦逆行（乾震同途、坤巽同途是定表事实）。
_NAJIA: dict[str, tuple[str, str, str, str]] = {
    "乾": ("甲", "子寅辰", "壬", "午申戌"),
    "坤": ("乙", "未巳卯", "癸", "丑亥酉"),
    "震": ("庚", "子寅辰", "庚", "午申戌"),
    "巽": ("辛", "丑亥酉", "辛", "未巳卯"),
    "坎": ("戊", "寅辰午", "戊", "申戌子"),
    "离": ("己", "卯丑亥", "己", "酉未巳"),
    "艮": ("丙", "辰午申", "丙", "戌子寅"),
    "兑": ("丁", "巳卯丑", "丁", "亥酉未"),
}


def najia_for_bits(bits: Any) -> list[str]:
    """六爻纳甲干支（自下而上）：下卦三爻纳**内卦**干支，上卦三爻纳
    **外卦**干支（同卦内外两行不同——乾内甲外壬、坤内乙外癸）。如
    乾卦 → 甲子/甲寅/甲辰/壬午/壬申/壬戌。"""
    vals = _normalize_bits(bits)
    lower = _TRIGRAM_BY_BITS[tuple(vals[:3])]
    upper = _TRIGRAM_BY_BITS[tuple(vals[3:])]
    stem_in, branches_in = _NAJIA[lower][0], _NAJIA[lower][1]
    stem_out, branches_out = _NAJIA[upper][2], _NAJIA[upper][3]
    return [
        stem_in + branches_in[0], stem_in + branches_in[1],
        stem_in + branches_in[2], stem_out + branches_out[0],
        stem_out + branches_out[1], stem_out + branches_out[2],
    ]


# ── 记录校验（卦体几何 × 标注文本 两路互证） ─────────────────────

def validate_record(lines: list[dict[str, Any]]) -> dict[str, Any]:
    """校验 hexagram_recognize 输出的 lines（自下而上）。

    硬错误（errors）：爻数不足；字表外字符（引擎误读的强信号）；
    两字标注非"干+支"或奇偶不配（不可能是六十甲子成员）。
    软提示（warnings）：宽表字（五行/六亲等，书页正常现象）；与京房
    纳甲定表不符（本书可能用爻辰/时辰寄爻等其他体系——提示而非错误）。
    """
    errors: list[str] = []
    warnings: list[str] = []
    if len(lines) != 6:
        errors.append(f"爻数应为 6，实际 {len(lines)}")
        return {"ok": False, "errors": errors, "warnings": warnings}

    bad_chars: list[str] = []
    extra_chars: list[str] = []
    for ln in lines:
        for side in ("left", "right"):
            text = "".join(
                (c.get("text") or "") for c in ln.get(side) or []
            )
            for ch in text:
                if ch in GANZHI_CHARS:
                    continue
                if ch in KNOWN_EXTRA_CHARS:
                    extra_chars.append(ch)
                else:
                    bad_chars.append(ch)
            if len(text) == 2 and not is_valid_ganzhi_pair(text):
                errors.append(
                    f"第{ln['pos']}爻{ {'left': '左', 'right': '右'}[side] }侧"
                    f"「{text}」不是合法干支配对（干前支后、奇偶同序）"
                )
            elif len(text) > 2:
                warnings.append(
                    f"第{ln['pos']}爻{ {'left': '左', 'right': '右'}[side] }侧"
                    f"标注「{text}」超过两字（竖排多注或粘连，请对照切片）"
                )
    if bad_chars:
        errors.append(
            "干支字表外字符：" + "、".join(sorted(set(bad_chars)))
            + "（多为引擎误读，请对照切片改正）"
        )
    if extra_chars:
        warnings.append(
            "非干支标注字：" + "、".join(sorted(set(extra_chars)))
            + "（五行/六亲/世应等常见附注，如无请改正）"
        )

    # 纳甲对照：卦体阴阳（几何判定，稳）推出定表干支，与各爻标注中
    # 的地支比对。吻合率高 → 两路互证；大面积不符 → 只提示体系差异。
    bits = [1 if ln.get("yang") else 0 for ln in lines]
    najia = najia_for_bits(bits)
    matches = compared = 0
    for ln, expect in zip(lines, najia):
        text = "".join(
            ch
            for side in ("left", "right")
            for c in (ln.get(side) or [])
            for ch in (c.get("text") or "")
        )
        branches = [ch for ch in text if ch in _BRANCH_INDEX]
        if not branches:
            continue
        compared += 1
        if expect[1] in branches:
            matches += 1
    verdict = "no-data"
    if compared >= 3:
        if matches == compared:
            verdict = "match"
        elif matches >= (compared + 1) // 2:
            verdict = "partial"
        else:
            verdict = "mismatch"
    najia_report = {
        "matches": matches,
        "compared": compared,
        "verdict": verdict,
    }
    if verdict == "match":
        warnings.append(f"纳甲校验：{matches}/{compared} 爻与京房纳甲定表吻合")
    elif verdict == "mismatch":
        warnings.append(
            f"纳甲校验：仅 {matches}/{compared} 爻与京房纳甲定表相符——"
            "本书可能采用爻辰/时辰寄爻等其他配属体系（仅提示，非错误）"
        )

    return {
        "ok": not errors,
        "errors": errors,
        "warnings": warnings,
        "najia": najia_report,
    }


# ── 仿古竖排 SVG 重绘 ────────────────────────────────────────────

def _xml_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;").replace("<", "&lt;")
        .replace(">", "&gt;").replace('"', "&quot;")
    )


def render_svg(
    lines: list[dict[str, Any]],
    hexagram: dict[str, Any] | None = None,
    frame: bool = True,
) -> str:
    """lines（自下而上）→ 仿古竖排卦图 SVG 字符串。

    上爻在上；阳爻整条、阴爻两段；左右标注按爻行对位。纸墨配色固定
    （导出/测试用确定性产物，交互呈现由插件页负责）。
    """
    pitch = 40
    thick = 6
    bar_w = 128
    mark_w = 34
    pad = 18
    caption_h = 30
    bar_x = pad + mark_w
    width = bar_x + bar_w + mark_w + pad
    rows_h = pitch * 5 + thick
    height = pad + rows_h + caption_h + pad
    parts: list[str] = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}">'
    )
    parts.append(
        f'<rect width="{width}" height="{height}" fill="#f4edda"/>'
    )
    if frame:
        parts.append(
            f'<rect x="4.5" y="4.5" width="{width - 9}" '
            f'height="{height - 9}" fill="none" stroke="#a99468"/>'
        )
    # 自上而下 = pos 6..1
    for row, ln in enumerate(reversed(lines)):
        y = pad + row * pitch
        mark_font = 22
        for side, x_text in (("left", pad), ("right", bar_x + bar_w)):
            chars = [c.get("text") or "" for c in (ln.get(side) or [])]
            stack_text = "".join(chars)
            if not stack_text:
                continue
            per = pitch / max(1, len(stack_text))
            for i, ch in enumerate(stack_text):
                cy = y + thick / 2 - (len(stack_text) - 1 - i) * per
                parts.append(
                    f'<text x="{x_text + mark_w / 2}" y="{cy:.1f}" '
                    f'font-size="{mark_font}" text-anchor="middle" '
                    f'dominant-baseline="central" fill="#37301c" '
                    f'font-family="serif">{_xml_escape(ch)}</text>'
                )
        if ln.get("yang"):
            parts.append(
                f'<rect x="{bar_x}" y="{y}" width="{bar_w}" '
                f'height="{thick}" fill="#37301c" rx="1"/>'
            )
        else:
            half = int(bar_w * 0.42)
            parts.append(
                f'<rect x="{bar_x}" y="{y}" width="{half}" '
                f'height="{thick}" fill="#37301c" rx="1"/>'
            )
            parts.append(
                f'<rect x="{bar_x + bar_w - half}" y="{y}" width="{half}" '
                f'height="{thick}" fill="#37301c" rx="1"/>'
            )
    if hexagram:
        caption = (
            f'{hexagram.get("full_name") or hexagram.get("name", "")}'
            f' {hexagram.get("unicode", "")}'.strip()
        )
        if caption:
            parts.append(
                f'<text x="{width / 2}" y="{pad + rows_h + caption_h / 2}" '
                f'font-size="16" text-anchor="middle" '
                f'dominant-baseline="central" fill="#847650" '
                f'font-family="serif">{_xml_escape(caption)}</text>'
            )
    parts.append("</svg>")
    return "".join(parts)
