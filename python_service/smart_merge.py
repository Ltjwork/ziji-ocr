"""智能合并扫描：以一次手工合并的字框对为模板，在多页中找同类墨迹对。

场景：全书许多同一符号（如「；」）被识别器拆成上下/左右两个框，程
序把它们当成两个标点。用户在编辑器把其中一处手工合并后，以前的两
框为模板（几何构型 + 各框 HOG 墨迹特征），在其它页的同行相邻字框对
里找"长得一样"的对：构型（跨轴重叠 / 阅读轴归一化间距 / 两框尺寸比）
与模板一致，且两框墨迹 HOG 距离都在阈值内。匹配到的对由前端按与手
工合并完全相同的口径合并；任何已确认（confirmed / box_confirmed）的
框恒不参与——校对成果不动。

构型量全部是相对量（比例/归一化间距），跨页分辨率差异自动免疫。
纯 CPU（复用 char_cluster 的 HOG machinery），不与识别抢 GPU 门。
"""

import math
import time

import numpy as np

from char_cluster import MAX_ASPECT_DIFF, W_ASPECT, _char_feature
from segmenter import _text_mask_for_refinement

# 两框墨迹距离（HOG 余弦 + 宽高比惩罚，与聚类同公式）的默认阈值。
# 聚类默认 0.15 把"同字形"聚成组；成对匹配是拿半个字形的裁切互比，
# 形态波动略大，给一点余量。
DEFAULT_THRESHOLD = 0.18

# 几何构型容差（相对量，无量纲）：
CROSS_OVERLAP_MIN = 0.55  # 跨轴重叠比例下限（两框须基本同列/同行）
GAP_TOL = 0.40  # 归一化阅读轴间距与模板的偏差上限
SIZE_RATIO_TOL = 0.59  # 尺寸比偏差 |log(r/r_t)| 上限（≈1.8 倍）

_DIR_READER = {
    # dir → (阅读轴长度取法, 阅读轴上游标, 跨轴上游标, 跨轴长度取法)
    "ttb": ("h", "y", "x", "w"),
    "btt": ("h", "y", "x", "w"),
    "ltr": ("w", "x", "y", "h"),
    "rtl": ("w", "x", "y", "h"),
}


def _feature_distance(fa, fb) -> float:
    """两个 (hog, aspect) 特征的距离（与 char_cluster._distance_matrix 同式）。"""
    hog_a, aspect_a = fa
    hog_b, aspect_b = fb
    cos = float(np.clip(1.0 - float(hog_a @ hog_b), 0.0, 2.0))
    pen = W_ASPECT * float(
        np.clip(abs(math.log(aspect_a) - math.log(aspect_b)), 0.0, MAX_ASPECT_DIFF)
    )
    return cos + pen


def pair_geometry(a, b, direction: str):
    """阅读序相邻两框 (a 在前, b 在后) 的构型描述。

    全部相对量：跨轴重叠比例、阅读轴归一化间距（正=分离, 负=交叠）、
    两框沿阅读轴/跨轴的尺寸比。退化（尺寸为 0）返回 None。
    """
    spec = _DIR_READER.get(direction)
    if spec is None:
        return None
    read_key, read_pos, cross_pos, cross_key = spec
    la, lb = getattr(a, read_key), getattr(b, read_key)
    ca, cb = getattr(a, cross_key), getattr(b, cross_key)
    if la <= 0 or lb <= 0 or ca <= 0 or cb <= 0:
        return None
    # 阅读轴间距：first 阅读侧边缘 → second（ttb/ltr 为 b 在 a 后；
    # btt/rtl 阅读方向反向，first 在物理下游）。
    if direction == "ttb":
        gap = b.y - (a.y + a.h)
    elif direction == "btt":
        gap = a.y - (b.y + b.h)
    elif direction == "ltr":
        gap = b.x - (a.x + a.w)
    else:  # rtl
        gap = a.x - (b.x + b.w)
    a1, a2 = getattr(a, cross_pos), getattr(a, cross_pos) + ca
    b1, b2 = getattr(b, cross_pos), getattr(b, cross_pos) + cb
    overlap = min(a2, b2) - max(a1, b1)
    return {
        "overlap": overlap / min(ca, cb),
        "gap": gap / ((la + lb) / 2.0),
        "read_ratio": la / lb,
        "cross_ratio": ca / cb,
    }


def geometry_matches(t, c) -> bool:
    """候选构型 c 是否与模板构型 t 一致（双门槛的第一道）。"""
    if t is None or c is None:
        return False
    if c["overlap"] < CROSS_OVERLAP_MIN:
        return False
    if abs(c["gap"] - t["gap"]) > GAP_TOL:
        return False
    if abs(math.log(c["read_ratio"] / t["read_ratio"])) > SIZE_RATIO_TOL:
        return False
    if abs(math.log(c["cross_ratio"] / t["cross_ratio"])) > SIZE_RATIO_TOL:
        return False
    return True


def _union_rect(a, b) -> tuple[int, int, int, int]:
    x1, y1 = min(a.x, b.x), min(a.y, b.y)
    x2 = max(a.x + a.w, b.x + b.w)
    y2 = max(a.y + a.h, b.y + b.h)
    return (x1, y1, x2 - x1, y2 - y1)


def _order_pair_by_direction(a, b, direction: str):
    """把 (a, b) 归位成阅读序（前, 后）：按阅读轴起点，方向感知。"""
    spec = _DIR_READER.get(direction)
    if spec is None:
        return None
    read_pos = spec[1]
    pa, pb = getattr(a, read_pos), getattr(b, read_pos)
    if direction in ("ttb", "ltr"):
        return (a, b) if pa <= pb else (b, a)
    return (a, b) if pa >= pb else (b, a)


def scan_smart_merge(
    template_image_path: str,
    template_rects,
    template_dir: str,
    pages,
    threshold: float = DEFAULT_THRESHOLD,
) -> dict:
    """在 pages 里找与模板字框对同类的相邻字框对。

    template_rects 为两个 (x, y, w, h)（顺序不限，内部按 template_dir
    归位成阅读序）；pages 为带 page_id/image_path/lines 的对象，line 带
    dir 与阅读序 blocks（块带 id/x/y/w/h/confirmed/box_confirmed）。

    返回 matches: [{page_id, first_id, second_id, merged, score}]，按
    score 升序、同页 id 互斥（一个框只进一次合并）；单页失败记入
    failed_pages 不中断整批。
    """
    started = time.time()
    threshold = float(min(0.5, max(0.05, threshold)))

    t_mask = _text_mask_for_refinement(template_image_path)
    if t_mask is None:
        raise ValueError(f"cannot read template image: {template_image_path}")

    class _R:
        def __init__(self, r):
            self.x, self.y, self.w, self.h = r

    t_first, t_second = _order_pair_by_direction(
        _R(template_rects[0]), _R(template_rects[1]), template_dir
    )
    if t_first is None:
        raise ValueError(f"bad template_dir: {template_dir}")
    tf1 = _char_feature(t_mask, (t_first.x, t_first.y, t_first.w, t_first.h))
    tf2 = _char_feature(t_mask, (t_second.x, t_second.y, t_second.w, t_second.h))
    if tf1 is None or tf2 is None:
        raise ValueError("template box has no extractable ink")
    t_geom = pair_geometry(t_first, t_second, template_dir)
    if t_geom is None:
        raise ValueError("degenerate template geometry")

    candidates: list[dict] = []
    failed_pages: list[dict] = []
    scanned_pages = 0
    for page in pages:
        try:
            mask = _text_mask_for_refinement(page.image_path)
            if mask is None:
                raise ValueError(f"cannot read image or build text mask: {page.image_path}")
            scanned_pages += 1
            for line in page.lines:
                if line.dir != template_dir:
                    continue
                blocks = line.blocks
                for i in range(len(blocks) - 1):
                    a, b = blocks[i], blocks[i + 1]
                    if a.confirmed or a.box_confirmed or b.confirmed or b.box_confirmed:
                        continue
                    c_geom = pair_geometry(a, b, line.dir)
                    if not geometry_matches(t_geom, c_geom):
                        continue
                    fa = _char_feature(mask, (a.x, a.y, a.w, a.h))
                    fb = _char_feature(mask, (b.x, b.y, b.w, b.h))
                    if fa is None or fb is None:
                        continue
                    score = max(
                        _feature_distance(fa, tf1),
                        _feature_distance(fb, tf2),
                    )
                    if score <= threshold:
                        candidates.append(
                            {
                                "page_id": page.page_id,
                                "first_id": a.id,
                                "second_id": b.id,
                                "merged": _union_rect(a, b),
                                "score": round(float(score), 4),
                            }
                        )
        except Exception as exc:
            failed_pages.append(
                {"page_id": getattr(page, "page_id", ""), "error": str(exc)}
            )

    # 同页内一个框只能被合并一次：按 score 升序贪心保留互斥对。
    candidates.sort(key=lambda m: m["score"])
    used: set[tuple[str, str]] = set()
    matches: list[dict] = []
    for m in candidates:
        keys = ((m["page_id"], m["first_id"]), (m["page_id"], m["second_id"]))
        if keys[0] in used or keys[1] in used:
            continue
        used.update(keys)
        matches.append(m)

    return {
        "matches": matches,
        "failed_pages": failed_pages,
        "scanned_pages": scanned_pages,
        "threshold": threshold,
        "params": {
            "feature": "pair-hog+geometry",
            "cross_overlap_min": CROSS_OVERLAP_MIN,
            "gap_tol": GAP_TOL,
            "size_ratio_tol": SIZE_RATIO_TOL,
        },
        "elapsed_ms": round((time.time() - started) * 1000.0, 1),
    }


def scan_smart_split(
    template_image_path: str,
    template_rect,
    pages,
    threshold: float = DEFAULT_THRESHOLD,
) -> dict:
    """智能分割扫描：在 pages 的所有字框里找与模板框同类墨迹的单框。

    模板是手工 Alt 拆分前的原框（一个框里挤了两个字，如两个标点并成
    一框）。匹配为单框对单框的 HOG 距离（含宽高比惩罚），无构型门槛
    ——「两字叠成的瘦高框」这类构型信息已体现在整框形态里。已确认
    （confirmed / box_confirmed）的框恒跳过。pages 结构与
    [scan_smart_merge] 一致（lines × blocks，行归属即应用时的插入
    上下文）。返回 matches: [{page_id, block_id, score}]（score 升序）。
    """
    started = time.time()
    threshold = float(min(0.5, max(0.05, threshold)))
    t_mask = _text_mask_for_refinement(template_image_path)
    if t_mask is None:
        raise ValueError(f"cannot read template image: {template_image_path}")
    t_feat = _char_feature(t_mask, tuple(template_rect))
    if t_feat is None:
        raise ValueError("template box has no extractable ink")

    matches: list[dict] = []
    failed_pages: list[dict] = []
    scanned_pages = 0
    for page in pages:
        try:
            mask = _text_mask_for_refinement(page.image_path)
            if mask is None:
                raise ValueError(
                    f"cannot read image or build text mask: {page.image_path}"
                )
            scanned_pages += 1
            for line in page.lines:
                for block in line.blocks:
                    if block.confirmed or block.box_confirmed:
                        continue
                    feat = _char_feature(
                        mask, (block.x, block.y, block.w, block.h)
                    )
                    if feat is None:
                        continue
                    score = _feature_distance(feat, t_feat)
                    if score <= threshold:
                        matches.append(
                            {
                                "page_id": page.page_id,
                                "block_id": block.id,
                                "score": round(float(score), 4),
                            }
                        )
        except Exception as exc:
            failed_pages.append(
                {"page_id": getattr(page, "page_id", ""), "error": str(exc)}
            )

    matches.sort(key=lambda m: m["score"])
    return {
        "matches": matches,
        "failed_pages": failed_pages,
        "scanned_pages": scanned_pages,
        "threshold": threshold,
        "params": {"feature": "single-hog"},
        "elapsed_ms": round((time.time() - started) * 1000.0, 1),
    }
