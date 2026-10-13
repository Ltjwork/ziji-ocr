# -*- coding: utf-8 -*-
"""识别消融评测（recog_eval）的单元测试。

覆盖：差异对齐与指标纯函数（替换/漏/多/标点/混淆）、冻结评测集的构建
（确定性抽样、设置挂载、落盘复用）、三档消融的调用形态（A 不切分直喂、
B 纯连通域 n=0、C 走单行全链路）与指标聚合。不跑真模型：kraken_bridge
的三个识别入口与 segmenter 的切分器全部 mock。
"""

import json
import os
import tempfile
import unittest
from unittest import mock

import recog_eval
from recog_eval import (
    TIER_LABELS,
    _delta,
    _tier_summary,
    align_errors,
    build_eval_set,
    cer_for,
    eval_set_summary,
    last_run_summary,
    load_eval_set,
    run_ablation,
)


def _fake_splitter(boxes):
    """make_kraken_char_splitter 的替身：无视参数返回固定字框。"""
    calls = []

    def splitter(rect, n):
        calls.append({"rect": dict(rect), "n": n})
        return list(boxes)

    splitter.calls = calls
    splitter.last_method = "components"
    return splitter


class AlignErrorsTests(unittest.TestCase):
    def test_identity(self):
        e = align_errors("天地玄黃", "天地玄黃")
        self.assertEqual(e["edits"], 0)
        self.assertEqual((e["sub"], e["del"], e["ins"]), (0, 0, 0))
        self.assertEqual(e["punct_errors"], 0)

    def test_substitution_pairing(self):
        e = align_errors("天地玄黃", "天地玄黄")
        self.assertEqual(e["sub"], 1)
        self.assertEqual(e["confusions"][("黃", "黄")], 1)

    def test_delete_and_insert(self):
        self.assertEqual(align_errors("天地玄黃", "天地玄")["del"], 1)
        self.assertEqual(align_errors("天地玄", "天地玄黃")["ins"], 1)

    def test_punct_error_counted(self):
        # 圈点被读成逗号 → 1 次标点替换；尾部多读句号 → 1 次标点多字。
        e = align_errors("一、二", "一，二")
        self.assertEqual(e["sub"], 1)
        self.assertEqual(e["punct_errors"], 1)
        e2 = align_errors("一、二", "一、二。")
        self.assertEqual(e2["ins"], 1)
        self.assertEqual(e2["punct_errors"], 1)

    def test_punct_not_counted_on_han_errors(self):
        e = align_errors("天地玄黃", "天地玄荒")
        self.assertEqual(e["punct_errors"], 0)

    def test_cer_for(self):
        self.assertEqual(cer_for("天地玄黃", "天地玄黃"), 0.0)
        self.assertAlmostEqual(cer_for("天地玄黃", "天地玄"), 0.25)
        self.assertAlmostEqual(cer_for("天地玄", "天地玄黃"), 1 / 3)
        self.assertIsNone(cer_for("", "天地"))

    def test_replace_block_surplus_becomes_del_and_ins(self):
        # replace 块 2 字 GT 对 1 字预测：1 对替换 + 1 字漏。
        e = align_errors("天地玄黃", "天地玄")
        self.assertEqual(e["sub"], 0)
        self.assertEqual(e["del"], 1)


class TierSummaryTests(unittest.TestCase):
    def test_aggregation(self):
        s = _tier_summary(
            TIER_LABELS["a"],
            [
                {"gt": "天地玄黃", "pred": "天地玄黃"},
                {"gt": "一、二", "pred": "一，二"},
                {"gt": "宇宙", "pred": "宇宙洪"},
            ],
            elapsed_s=12.34,
        )
        self.assertEqual(s["lines"], 3)
        self.assertEqual(s["chars"], 9)
        self.assertEqual(s["sub"], 1)  # 、→，
        self.assertEqual(s["ins"], 1)  # 宇宙 → 宇宙洪
        self.assertEqual(s["edits"], 2)
        self.assertAlmostEqual(s["cer"], 2 / 9, places=4)
        self.assertEqual(s["punct_errors"], 1)
        self.assertEqual(s["elapsed_s"], 12.3)
        self.assertTrue(any(
            c["gt"] == "、" and c["pred"] == "，" for c in s["confusions"]
        ))

    def test_delta(self):
        before = {"cer": 0.10, "accuracy": 0.90, "punct_errors": 5}
        after = {"cer": 0.06, "accuracy": 0.94, "punct_errors": 2}
        d = _delta(before, after, "修正代码")
        self.assertEqual(d["name"], "修正代码")
        self.assertAlmostEqual(d["cer_drop"], 0.04)
        self.assertAlmostEqual(d["accuracy_gain"], 0.04)
        self.assertEqual(d["punct_errors_after"], 2)


class BuildEvalSetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.book = os.path.join(self.tmp.name, "书一")
        os.makedirs(self.book)
        with open(
            os.path.join(self.book, "project.json"), "w", encoding="utf-8"
        ) as f:
            json.dump(
                {"settings": {"orientation": "vertical", "horizontal_dir": "rtl"}},
                f, ensure_ascii=False,
            )
        self._patchers = [
            mock.patch.object(recog_eval, "EVAL_SET_PATH",
                              os.path.join(self.tmp.name, "eval_set.json")),
            mock.patch("kraken_training._all_book_dirs", return_value=[self.book]),
        ]
        for p in self._patchers:
            p.start()
            self.addCleanup(p.stop)

    def _fake_lines(self, count):
        return [
            {
                "image_path": f"img_{i:03d}.png",
                "x": 10, "y": i * 300, "w": 80, "h": 260,
                "text": f"第{i}行文字",
            }
            for i in range(count)
        ]

    def test_samples_evenly_and_attaches_settings(self):
        with mock.patch(
            "kraken_training._confirmed_lines",
            return_value=self._fake_lines(10),
        ):
            payload = build_eval_set(self.book, limit=5)
        self.assertEqual(len(payload["lines"]), 5)
        self.assertEqual(payload["total_confirmed"], 10)
        self.assertEqual(payload["books"], ["书一"])
        # 确定性均匀抽样：10 行取 5 → 下标 0/2/4/6/8
        self.assertEqual([ln["y"] for ln in payload["lines"]],
                         [0, 600, 1200, 1800, 2400])
        for ln in payload["lines"]:
            self.assertEqual(ln["orientation"], "vertical")
            self.assertEqual(ln["horizontal_dir"], "rtl")
            self.assertEqual(ln["book_dir"], self.book)
        # 冻结落盘：load_eval_set 读回同一批
        loaded = load_eval_set()
        self.assertEqual(eval_set_summary(loaded)["size"], 5)
        self.assertEqual(
            [ln["y"] for ln in loaded["lines"]],
            [ln["y"] for ln in payload["lines"]],
        )

    def test_no_confirmed_lines_raises(self):
        with mock.patch(
            "kraken_training._confirmed_lines", return_value=[]
        ):
            with self.assertRaises(ValueError):
                build_eval_set(self.book, limit=5)


class RunAblationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image = os.path.join(self.tmp.name, "page.png")
        with open(self.image, "wb") as f:
            f.write(b"png")
        self.runs_dir = os.path.join(self.tmp.name, "eval_runs")
        self.lines = [
            {
                "image_path": self.image,
                "x": 10, "y": 20, "w": 80, "h": 260,
                "text": "天地玄黃",
                "orientation": "vertical",
                "horizontal_dir": "rtl",
            },
            {
                "image_path": os.path.join(self.tmp.name, "missing.png"),
                "x": 1, "y": 2, "w": 3, "h": 4,
                "text": "宇宙洪荒",
                "orientation": "vertical",
                "horizontal_dir": "rtl",
            },
        ]
        self.eval_set = {
            "built_at": "t", "total_confirmed": 2, "limit": 2,
            "books": ["书一"], "lines": self.lines,
        }
        self.boxes = [(10, 20, 80, 60), (10, 90, 80, 60),
                      (10, 160, 80, 60), (10, 230, 80, 50)]
        self._patchers = [
            mock.patch.object(recog_eval, "EVAL_RUNS_DIR", self.runs_dir),
        ]
        for p in self._patchers:
            p.start()
            self.addCleanup(p.stop)

    def test_three_tiers_calls_and_metrics(self):
        fake_splitter = _fake_splitter(self.boxes)
        with mock.patch(
            "segmenter.make_kraken_char_splitter",
            return_value=fake_splitter,
        ) as mk, mock.patch(
            "kraken_bridge.recognize_lines",
            return_value=[{"text": "天地玄黃", "conf": 0.9}],
        ) as rec_lines, mock.patch(
            "kraken_bridge._recognize_char_boxes",
            return_value=[
                {"text": "天"}, {"text": "地"}, {"text": "玄"},
            ],
        ) as rec_boxes, mock.patch(
            "kraken_bridge.kraken_segment_line",
            return_value={"text": "天地玄荒", "chars": []},
        ) as seg_line:
            result = run_ablation(self.eval_set)

        # A：确认行框直喂整行读法，方向来自评测集设置
        rec_lines.assert_called_once()
        args = rec_lines.call_args.args
        self.assertEqual(args[0], self.image)
        self.assertEqual(args[1], [{"x": 10, "y": 20, "w": 80, "h": 260}])
        self.assertEqual(args[2], "vertical")
        self.assertEqual(args[3], "rtl")
        # B：纯连通域（n=0）切框后逐框读法
        mk.assert_called_once_with(self.image, "vertical", "rtl")
        self.assertEqual(fake_splitter.calls[0]["n"], 0)
        rec_boxes.assert_called_once()
        self.assertEqual(rec_boxes.call_args.args[1], self.boxes)
        # C：单行全链路（kraken_segment_line，传入同一个切分器）
        seg_line.assert_called_once()
        c_args = seg_line.call_args.args
        self.assertEqual(c_args[0], self.image)
        self.assertEqual(c_args[4], "vertical")
        self.assertEqual(c_args[5], "rtl")
        self.assertIsNone(c_args[6])
        self.assertIs(c_args[7], fake_splitter)

        # 指标：A 全对；B 漏 1 字（4 框只回 3 字）；C 错 1 字
        self.assertEqual(result["tiers"]["a"]["cer"], 0.0)
        self.assertEqual(result["tiers"]["b"]["del"], 1)
        self.assertEqual(result["tiers"]["c"]["sub"], 1)
        self.assertEqual(
            result["deltas"]["a_to_b"]["accuracy_gain"], -0.25
        )
        # 缺图的行被跳过并计数，不进指标
        self.assertEqual(result["skipped"], 1)
        self.assertEqual(len(result["details"]), 1)
        self.assertEqual(result["details"][0]["gt"], "天地玄黃")
        self.assertEqual(result["details"][0]["preds"]["b"], "天地玄")
        # 运行结果留档且可读回摘要
        self.assertTrue(os.path.isdir(self.runs_dir))
        last = last_run_summary()
        self.assertIsNotNone(last)
        self.assertEqual(set(last["tiers"].keys()), {"a", "b", "c"})

    def test_splitter_failure_counts_as_empty_b(self):
        fake_splitter = _fake_splitter([])
        with mock.patch(
            "segmenter.make_kraken_char_splitter",
            return_value=fake_splitter,
        ), mock.patch(
            "kraken_bridge.recognize_lines",
            return_value=[{"text": "天地玄黃"}],
        ), mock.patch(
            "kraken_bridge._recognize_char_boxes"
        ) as rec_boxes, mock.patch(
            "kraken_bridge.kraken_segment_line",
            return_value={"text": "天地玄黃"},
        ):
            result = run_ablation(self.eval_set)
        rec_boxes.assert_not_called()
        # 切分失败 → B 档空文本，GT 4 字全计漏字
        self.assertEqual(result["tiers"]["b"]["del"], 4)
        self.assertEqual(result["details"][0]["preds"]["b"], "")


if __name__ == "__main__":
    unittest.main()
