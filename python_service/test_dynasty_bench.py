# -*- coding: utf-8 -*-
"""朝代基准评测（dynasty_bench）测试：归一、载入基准、指标与历史落盘。

不依赖识别管线——评测输入由测试直接构造，覆盖：标点/空白剥离、识别
失败样张不计入聚合（不把故障当 0 分）、run 记录落盘与历史摘要读取。
"""
import json
import os
import unittest
from tempfile import TemporaryDirectory

import dynasty_bench


def _make_bench(root: str) -> str:
    bench = os.path.join(root, "periods")
    os.makedirs(os.path.join(bench, "gt"))
    cases = [
        {
            "id": "01_xianqin",
            "era": "先秦",
            "book": "测试简",
            "image": "01.jpg",
            "reading_order": {
                "orientation": "vertical",
                "horizontal_dir": "ltr",
                "vertical_dir": "ttb",
            },
            "units": [{"label": "简1", "text": "絕智棄辯"}, {"label": "简2", "text": "民利百倍"}],
            "gt_confidence": "high",
        },
        {
            "id": "05_mingqing",
            "era": "明清",
            "book": "测试页",
            "image": "05.jpg",
            "units": [{"label": "列1", "text": "永樂大典，卷一萬一百十。"}],
        },
    ]
    for c in cases:
        with open(
            os.path.join(bench, "gt", f"{c['id']}.json"), "w", encoding="utf-8"
        ) as fh:
            json.dump(c, fh, ensure_ascii=False)
    return bench


class DynastyBenchTest(unittest.TestCase):
    def test_normalize_strips_whitespace_and_punct(self):
        # 基准无标点：预测里混入的空白/标点不计为识别错误（recog_eval 同源集合）。
        self.assertEqual(dynasty_bench._normalize("上德 不德，是 以有德。"), "上德不德是以有德")
        self.assertEqual(dynasty_bench._normalize(""), "")
        self.assertEqual(dynasty_bench._normalize("　絕 智\n棄辯\t"), "絕智棄辯")

    def test_load_cases_orders_and_joins_units(self):
        with TemporaryDirectory() as root:
            bench = _make_bench(root)
            cases = dynasty_bench.load_cases(bench)
            self.assertEqual([c["id"] for c in cases], ["01_xianqin", "05_mingqing"])
            first = cases[0]
            self.assertEqual(first["gt_text"], "絕智棄辯民利百倍")
            # reading_order 缺省样张回退到竖排右起。
            self.assertEqual(cases[1]["reading_order"]["horizontal_dir"], "rtl")
            self.assertTrue(os.path.isabs(first["image_path"]))
            self.assertTrue(first["image_path"].endswith("01.jpg"))

    def test_load_cases_missing_dir(self):
        with TemporaryDirectory() as root:
            with self.assertRaises(FileNotFoundError):
                dynasty_bench.load_cases(os.path.join(root, "nope"))

    def test_evaluate_metrics_and_persistence(self):
        with TemporaryDirectory() as root:
            bench = _make_bench(root)
            record = dynasty_bench.evaluate(
                bench,
                [
                    # 8 字基准：完全正确。
                    {"id": "01_xianqin", "pred_text": "絕智棄辯 民利百倍", "line_count": 2,
                     "duration_ms": 120},
                    # 10 字基准（含标点剥离后）：对 8 字 + 错 1 + 漏 1。
                    {"id": "05_mingqing", "pred_text": "永樂大典卷一萬百十", "line_count": 1,
                     "duration_ms": 80},
                ],
            )
            by_id = {c["id"]: c for c in record["cases"]}
            self.assertAlmostEqual(by_id["01_xianqin"]["accuracy"], 1.0)
            # GT 去标点后 10 字，预测 9 字：difflib 对成 1 个纯漏字（漏「一」）。
            self.assertEqual(by_id["05_mingqing"]["gt_len"], 10)
            self.assertEqual(by_id["05_mingqing"]["sub"], 0)
            self.assertEqual(by_id["05_mingqing"]["del"], 1)
            self.assertAlmostEqual(by_id["05_mingqing"]["cer"], 0.1)
            # 聚合 micro：18 字基准 1 edit → CER 1/18；macro 是两样张平均。
            self.assertAlmostEqual(record["aggregate"]["cer"], 1 / 18)
            self.assertAlmostEqual(
                record["aggregate"]["macro_accuracy"], (1.0 + 0.9) / 2
            )
            self.assertEqual(record["backend_build"] and True, True)
            # 落盘的 run 记录与返回一致，历史能读回。
            with open(record["run_path"], encoding="utf-8") as fh:
                on_disk = json.load(fh)
            self.assertEqual(on_disk["run_id"], record["run_id"])
            runs = dynasty_bench.list_runs(bench)
            self.assertEqual(len(runs), 1)
            self.assertEqual(runs[0]["run_id"], record["run_id"])
            self.assertAlmostEqual(
                runs[0]["per_case"]["01_xianqin"]["accuracy"], 1.0
            )

    def test_evaluate_error_case_not_scored_as_zero(self):
        with TemporaryDirectory() as root:
            bench = _make_bench(root)
            record = dynasty_bench.evaluate(
                bench,
                [
                    {"id": "01_xianqin", "error": "识别超时"},
                    {"id": "05_mingqing", "pred_text": "永樂大典卷一萬一百十",
                     "line_count": 1, "duration_ms": 5},
                ],
            )
            by_id = {c["id"]: c for c in record["cases"]}
            self.assertIsNone(by_id["01_xianqin"]["accuracy"])
            self.assertEqual(by_id["01_xianqin"]["error"], "识别超时")
            # 聚合只算成功样张，不把失败当 0 分拉低。
            self.assertEqual(record["aggregate"]["cases_scored"], 1)
            self.assertAlmostEqual(record["aggregate"]["accuracy"], 1.0)

    def test_evaluate_lines_detail_passthrough(self):
        with TemporaryDirectory() as root:
            bench = _make_bench(root)
            detail = [
                {
                    "x": 0, "y": 0, "w": 100, "h": 400, "text": "絕智棄辯",
                    "chars": [
                        {"x": 10, "y": 10, "w": 80, "h": 90,
                         "text": "絕", "conf": 0.9, "type": "main_text"},
                    ],
                }
            ]
            record = dynasty_bench.evaluate(
                bench,
                [
                    {"id": "01_xianqin", "pred_text": "絕智棄辯民利百倍",
                     "line_count": 1, "duration_ms": 9, "lines": detail},
                    # 不带 lines 的样张：字段为 None，前端按"无字框数据"展示。
                    {"id": "05_mingqing", "pred_text": "永樂大典",
                     "line_count": 1, "duration_ms": 5},
                ],
            )
            by_id = {c["id"]: c for c in record["cases"]}
            self.assertEqual(by_id["01_xianqin"]["lines"], detail)
            self.assertIsNone(by_id["05_mingqing"]["lines"])
            # 落盘往返后仍完整（Python 只存档不解释）。
            with open(record["run_path"], encoding="utf-8") as fh:
                on_disk = json.load(fh)
            self.assertEqual(
                next(c for c in on_disk["cases"] if c["id"] == "01_xianqin")["lines"],
                detail,
            )
            # 历史摘要不携带明细，保持轻量。
            runs = dynasty_bench.list_runs(bench)
            self.assertNotIn("lines", json.dumps(runs))

    def test_evaluate_pipeline_meta_passthrough(self):
        with TemporaryDirectory() as root:
            bench = _make_bench(root)
            record = dynasty_bench.evaluate(
                bench,
                [
                    {
                        "id": "01_xianqin",
                        "pred_text": "絕智棄辯民利百倍",
                        "line_count": 1,
                        "duration_ms": 3,
                        "engine": "hier",
                        "fallback_reason": None,
                        "converter": "opencc-ready",
                        "yolo": {"initialized": True, "model_exists": True},
                        "ai_assist": {"status": "applied", "model": "qwen2.5vl"},
                    },
                    {
                        "id": "05_mingqing",
                        "pred_text": "永樂大典",
                        "engine": "opencv",
                        "fallback_reason": "yolo-char unavailable",
                    },
                ],
            )
            by_id = {c["id"]: c for c in record["cases"]}
            self.assertEqual(by_id["01_xianqin"]["engine"], "hier")
            self.assertEqual(by_id["01_xianqin"]["ai_assist"]["model"], "qwen2.5vl")
            self.assertEqual(by_id["05_mingqing"]["engine"], "opencv")
            self.assertEqual(
                by_id["05_mingqing"]["fallback_reason"],
                "yolo-char unavailable",
            )
            self.assertIsNone(by_id["05_mingqing"]["ai_assist"])
            # 历史摘要不携带这些明细（按字段检查而非子串——backend_build
            # 等无关字段的取值可能恰好包含 "engine" 字样）。
            for run in dynasty_bench.list_runs(bench):
                self.assertNotIn("engine", run)
                self.assertNotIn("ai_assist", run)
                for detail in run["per_case"].values():
                    self.assertNotIn("engine", detail)
                    self.assertNotIn("ai_assist", detail)

    def test_evaluate_unknown_case_rejected(self):
        with TemporaryDirectory() as root:
            bench = _make_bench(root)
            with self.assertRaises(KeyError):
                dynasty_bench.evaluate(bench, [{"id": "99_missing", "pred_text": "x"}])

    def test_list_runs_empty(self):
        with TemporaryDirectory() as root:
            self.assertEqual(dynasty_bench.list_runs(_make_bench(root)), [])


if __name__ == "__main__":
    unittest.main()
