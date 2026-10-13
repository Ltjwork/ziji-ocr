"""cluster_chars_batch 冒烟测试：合成两页图（每页画相同的一组"字"），
同名/同形字跨页应聚进同一全局组；单页 cluster_chars 行为不回归。

运行：python test_char_cluster_batch.py
"""

import os
import tempfile

import cv2
import numpy as np

import char_cluster


class _Block:
    def __init__(self, bid, x, y, w, h):
        self.id = bid
        self.x, self.y, self.w, self.h = x, y, w, h


def _make_page(path, chars, seed):
    """chars: [(block_id, char)]，在页面上按网格画黑色大字。"""
    rng = np.random.default_rng(seed)
    img = np.full((1000, 800), 255, dtype=np.uint8)
    blocks = []
    for i, (bid, ch) in enumerate(chars):
        col, row = divmod(i, 8)
        x = 40 + col * 180 + int(rng.integers(-6, 6))
        y = 40 + row * 120 + int(rng.integers(-6, 6))
        cv2.putText(
            img, ch, (x, y + 80), cv2.FONT_HERSHEY_SIMPLEX, 3.0, 0, 12, cv2.LINE_AA
        )
        blocks.append(_Block(bid, x - 6, y - 6, 100 + 12, 100 + 12))
    cv2.imwrite(path, img)
    return blocks


def main():
    with tempfile.TemporaryDirectory() as tmp:
        p1 = os.path.join(tmp, "page_001.png")
        p2 = os.path.join(tmp, "page_002.png")
        # 两页各画 6 个字：4 个字形两页都有（跨页应合并），2 个每页独有
        glyphs = ["A", "B", "E", "H", "Q", "Z"]
        blocks1 = _make_page(p1, [(f"0|{g}{i}", g) for i, g in enumerate(glyphs)], 1)
        blocks2 = _make_page(p2, [(f"1|{g}{i}", g) for i, g in enumerate(glyphs)], 2)

        class _Page:
            def __init__(self, image_path, blocks):
                self.image_path = image_path
                self.blocks = blocks

        result = char_cluster.cluster_chars_batch(
            [_Page(p1, blocks1), _Page(p2, blocks2)], threshold=0.15
        )
        clusters = result["clusters"]
        print("clusters:")
        for c in clusters:
            print(" ", c["size"], c["block_ids"])
        print(
            "singletons:", len(result["singletons"]),
            "skipped:", len(result["skipped"]),
            "failed:", result["failed_pages"],
        )

        # 每个字形两页各 1 个实例 → 跨页合并后每组 size==2、组数 == 字形数
        sizes = sorted(c["size"] for c in clusters)
        assert sizes == [2] * len(glyphs), f"期望每个字形聚成 2 字组，实际 {sizes}"
        ids = {frozenset(c["block_ids"]) for c in clusters}
        assert len(ids) == len(glyphs)
        for c in clusters:
            pages = {b.split("|")[0] for b in c["block_ids"]}
            assert pages == {"0", "1"}, f"组未跨页合并: {c['block_ids']}"
        assert not result["failed_pages"]
        print("batch OK")

        # 单页接口回归：同阈值下页 1 的 6 个不同字形应各自成单字（无组）
        single = char_cluster.cluster_chars(p1, blocks1, threshold=0.15)
        assert single["clusters"] == [] or all(
            c["size"] == 1 for c in single["clusters"]
        )
        print("single-page OK (no unexpected merges)")


if __name__ == "__main__":
    main()
