# -*- coding: utf-8 -*-
"""两路读法逐字融合（_align_seq_to_boxes / _fuse_line_chars）的单元测试。

覆盖：顺序对齐（含标点插入导致的整体错开）、agree 状态分类、分歧位
候选挂载、复读翻转、primary=box 的正文来源、框内多字读法的降级。
"""

import unittest

from kraken_bridge import _align_seq_to_boxes, _fuse_line_chars


def kchar(t, c=0.9):
    return {"text": t, "conf": c}


class AlignTests(unittest.TestCase):
    def test_identity(self):
        pair = _align_seq_to_boxes(["天", "地", "玄"], ["天", "地", "玄"])
        self.assertEqual(pair, [0, 1, 2])

    def test_punct_shift(self):
        # 序列在第 2 位多读出一个标点 → 后续整体错开一格；对齐应把每个
        # 框配到正确的序列字（位置 zip 会全部配到邻字）。
        seq = ["一", "、", "二", "三", "四"]
        box = ["一", "二", "三", "四"]
        pair = _align_seq_to_boxes(seq, box)
        self.assertEqual(pair, [0, 2, 3, 4])

    def test_empty_reads(self):
        # 空读法不应占用对齐位（序列中间的空位跳过）
        pair = _align_seq_to_boxes(["甲", "", "乙"], ["甲", "乙"])
        self.assertEqual(pair, [0, 2])

    def test_disjoint(self):
        # 完全不吻合时 replace 段仍左对齐配对（按"对齐但读法不同"处理），
        # 是否挂候选由 _fuse_line_chars 的锚点护栏决定
        pair = _align_seq_to_boxes(["子", "丑"], ["寅", "卯"])
        self.assertEqual(pair, [0, 1])


class FuseTests(unittest.TestCase):
    def _fuse(self, seq, crops, primary="seq", seq_confs=None, box_confs=None, multis=None):
        kchars = [
            kchar(t, (seq_confs or {}).get(i, 0.9)) for i, t in enumerate(seq)
        ]
        boxes = [(0, i * 10, 10, 10) for i in range(len(crops))]
        box_results = []
        for i, c in enumerate(crops):
            # 模拟 _pair_boxes_with_seq.build：crop 为空时回退位置位序列字
            if c:
                text = c
                conf = (box_confs or {}).get(i, 0.8)
            else:
                text = seq[i] if i < len(seq) else ""
                conf = (seq_confs or {}).get(i, 0.9) if i < len(seq) else 0.0
            multi = (multis or {}).get(i, False)
            box_results.append((text, conf, [], multi))
        return _fuse_line_chars(
            kchars,
            boxes,
            box_results,
            crops,
            primary,
            id_prefix="k_t_",
            col=1,
            line_id="L",
        )

    def test_both_agree(self):
        chars, flips, agrees = self._fuse(["天", "地"], ["天", "地"])
        self.assertEqual([c["text"] for c in chars], ["天", "地"])
        self.assertEqual(agrees, ["both", "both"])
        self.assertTrue(all(not c["candidates"] for c in chars))
        self.assertEqual(flips, [])
        self.assertEqual([c["agree"] for c in chars], ["both", "both"])

    def test_conflict_attaches_alt_candidate(self):
        # 序列读"出"、框内读"山" → 正文取序列字（primary=seq），框内读法
        # 挂为末位候选，agree=conflict
        chars, flips, agrees = self._fuse(["出", "米"], ["山", "米"])
        self.assertEqual(chars[0]["text"], "出")
        self.assertEqual(agrees[0], "conflict")
        self.assertEqual(chars[0]["candidates"], [{"text": "山", "score": 0.8}])
        self.assertEqual(agrees[1], "both")
        self.assertEqual(flips, [])

    def test_punct_shift_text_follows_alignment(self):
        # 序列多读一个标点（第 2 位），后续位置位全部是邻字；正文按对齐位
        # 落字，逐框读法全部"一致"
        seq = ["一", "、", "二", "三"]
        crops = ["一", "二", "三"]
        chars, _, agrees = self._fuse(seq, crops)
        self.assertEqual([c["text"] for c in chars], ["一", "二", "三"])
        self.assertEqual(agrees, ["both", "both", "both"])

    def test_box_primary_text_from_box(self):
        chars, _, agrees = self._fuse(["甲", "乙"], ["丙", "乙"], primary="box")
        self.assertEqual(chars[0]["text"], "丙")
        self.assertEqual(agrees[0], "conflict")
        # 另一路（序列字）挂为候选供人工裁决
        self.assertEqual(chars[0]["candidates"], [{"text": "甲", "score": 0.9}])

    def test_repeat_flip(self):
        # 序列复读（第 2 位重复上一字）、框内读法不同 → 正文翻转为框内
        # 读法，序列字降为候选
        seq = ["星", "星", "為"]
        crops = ["星", "流", "為"]
        chars, flips, agrees = self._fuse(seq, crops)
        self.assertEqual(chars[1]["text"], "流")
        self.assertEqual(flips, [(1, "星", "流")])
        self.assertEqual(chars[1]["candidates"], [{"text": "星", "score": 0.9}])
        self.assertEqual(agrees[1], "conflict")

    def test_true_double_char_no_flip(self):
        # 真叠字：序列与框内一致，不干预
        seq = ["星", "星", "為"]
        crops = ["星", "星", "為"]
        chars, flips, agrees = self._fuse(seq, crops)
        self.assertEqual([c["text"] for c in chars], ["星", "星", "為"])
        self.assertEqual(flips, [])
        self.assertEqual(agrees, ["both", "both", "both"])

    def test_multi_degrades_not_conflict(self):
        # 框内读出多字（吃邻字）→ box_multi：不挂候选、不翻转，正文仍取
        # 序列字
        seq = ["天", "地"]
        crops = ["天地", "地"]
        chars, flips, agrees = self._fuse(seq, crops, multis={0: True})
        self.assertEqual(agrees[0], "box_multi")
        self.assertEqual(chars[0]["candidates"], [])
        self.assertEqual(chars[0]["text"], "天")
        self.assertEqual(flips, [])

    def test_seq_missing_char_box_fills(self):
        # 序列中间漏读一个字（对齐位 None）→ 该框正文取框内读法
        seq = ["春", "秋"]
        crops = ["春", "夏", "秋"]
        chars, _, agrees = self._fuse(seq, crops)
        self.assertEqual([c["text"] for c in chars], ["春", "夏", "秋"])
        self.assertEqual(agrees, ["both", "box", "both"])

    def test_disjoint_line_no_alt_candidates(self):
        # 整行两路完全不吻合（无一致锚点，疑似系统性错位）→ 不逐位互挂
        # 候选（重现"候选=邻字"噪声），agree 仍标记 conflict 供显示
        chars, _, agrees = self._fuse(["子", "丑"], ["寅", "卯"])
        self.assertEqual(agrees, ["conflict", "conflict"])
        self.assertTrue(all(not c["candidates"] for c in chars))
        self.assertEqual(chars[0]["text"], "子")

    def test_empty_everywhere(self):
        chars, _, agrees = self._fuse([""], [""])
        self.assertEqual(chars[0]["text"], "")
        self.assertEqual(agrees, ["none"])


if __name__ == "__main__":
    unittest.main()
