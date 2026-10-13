# -*- coding: utf-8 -*-
"""撤销确认后的数据集清理测试（train_export 的 _prune_stale_pages）。

覆盖：
1. 确认被撤销（box_confirmed/status 全清）的页：下次导出删样本文件、
   manifest 记账回退、统计（instances/pages）随之下降；
2. 仍有效的页不动（部分撤销只清部分）；
3. 书里已不存在的页（跨页拆分/删页）保留旧数据——与"删书不影响"同口径；
4. char_cls 层同样清理（行确认被撤销后 purge 类目录样本）；
5. 全书 region_det 确认清空时（allowed 为空）已登记页也全部清理。

运行：conda run -n paddle python -m pytest test_train_prune.py -q
"""
import json
import os
import shutil
import tempfile
import unittest

import cv2
import numpy as np

import train_data
import train_datasets
from training_service import dataset_stats, export_datasets


def _isolate(testcase):
    testcase._tmp = tempfile.mkdtemp(prefix="train_prune_")
    testcase._old_root = train_data.DATASETS_ROOT
    train_data.DATASETS_ROOT = os.path.join(testcase._tmp, "datasets")
    train_datasets._MIGRATED = False


def _restore(testcase):
    train_data.DATASETS_ROOT = testcase._old_root
    train_datasets._MIGRATED = False
    shutil.rmtree(testcase._tmp, ignore_errors=True)


def _make_book(root, name, pages):
    """pages: [{pid, regions: [label|None], blocks_confirmed: n}]"""
    book = os.path.join(root, name)
    os.makedirs(os.path.join(book, "annotations"))
    with open(os.path.join(book, "project.json"), "w", encoding="utf-8") as f:
        json.dump({"id": name, "settings": {}}, f, ensure_ascii=False)
    for spec in pages:
        _make_page(book, spec["pid"], regions=spec.get("regions", []),
                   blocks=spec.get("blocks_confirmed", 0))
    return book


def _make_page(book, pid, *, regions=("main_text",), blocks=0):
    img_path = os.path.join(book, f"{pid}.png")
    ok, buf = cv2.imencode(".png", np.zeros((100, 100), dtype=np.uint8))
    assert ok
    buf.tofile(img_path)
    ann = {
        "page_id": pid,
        "image_path": img_path,
        "main_regions": [],
        "blocks": [
            {"id": f"b{i}", "x": 10, "y": 40 + i * 5, "w": 8, "h": 8,
             "status": "confirmed"}
            for i in range(blocks)
        ],
        "lines": [], "paragraphs": [],
    }
    for j, label in enumerate(regions):
        region = {"id": f"mr{j}", "x": 10, "y": 10 + j * 12, "w": 60, "h": 10,
                  "status": "confirmed"}
        if label is not None:
            region["label"] = label
        ann["main_regions"].append(region)
    _write_ann(book, pid, ann)


def _write_ann(book, pid, ann):
    with open(os.path.join(book, "annotations", f"{pid}.json"), "w",
              encoding="utf-8") as f:
        json.dump(ann, f, ensure_ascii=False)


def _read_ann(book, pid):
    with open(os.path.join(book, "annotations", f"{pid}.json"),
              encoding="utf-8") as f:
        return json.load(f)


def _layer_label_files(layer):
    g = os.path.join(train_data.datasets_root(), "_global", layer)
    out = []
    for split in ("train", "val"):
        d = os.path.join(g, split, "labels")
        if os.path.isdir(d):
            out += [os.path.basename(n) for n in os.listdir(d)]
    return out


def _revert_all_confirms(ann):
    """模拟「改回未保存」：reviewed/box_confirmed/status 全清。"""
    ann["reviewed"] = False
    ann["boxesReviewed"] = False
    for r in ann.get("main_regions", []):
        r["status"] = "proposed"
        r.pop("box_confirmed", None)
    for b in ann.get("blocks", []):
        b["status"] = "proposed"
        b.pop("box_confirmed", None)
    for line in ann.get("lines", []):
        line["status"] = "proposed"
        line.pop("box_confirmed", None)
        for c in line.get("chars", []):
            c["status"] = "proposed"
            c.pop("box_confirmed", None)
            c.pop("confirmed", None)


class TrainPruneTests(unittest.TestCase):
    def setUp(self):
        _isolate(self)
        self._lib = tempfile.mkdtemp(prefix="train_prune_lib_")

    def tearDown(self):
        _restore(self)
        shutil.rmtree(self._lib, ignore_errors=True)

    def test_reverted_page_pruned_files_and_stats(self):
        book = _make_book(self._lib, "bookP", [
            {"pid": "page_000", "regions": ["main_text"],
             "blocks_confirmed": 2},
            {"pid": "page_001", "regions": ["header"], "blocks_confirmed": 1},
        ])
        export_datasets(book, ["char_det", "region_det"])
        self.assertEqual(len(_layer_label_files("char_det")), 2)
        self.assertEqual(len(_layer_label_files("region_det")), 2)
        before = dataset_stats(book)
        self.assertEqual(before["layers"]["char_det"]["instances"], 3)
        self.assertEqual(before["layers"]["region_det"]["instances"], 2)

        # 撤销 page_000 的全部确认（改回未保存），下次导出应清理它
        ann = _read_ann(book, "page_000")
        _revert_all_confirms(ann)
        _write_ann(book, "page_000", ann)

        result = export_datasets(book, ["char_det", "region_det"])
        self.assertEqual(result["layers"]["char_det"]["pruned_pages"], 1)
        self.assertEqual(result["layers"]["region_det"]["pruned_pages"], 1)
        # 样本文件只剩 page_001；统计同步回退
        self.assertEqual(_layer_label_files("char_det"),
                         ["bookP_page_001.txt"])
        self.assertEqual(result["layers"]["char_det"]["manifest"]["instances"],
                         1)
        self.assertEqual(result["layers"]["region_det"]["manifest"]["pages"], 1)

    def test_removed_page_kept(self):
        book = _make_book(self._lib, "bookQ", [
            {"pid": "page_000", "regions": ["main_text"],
             "blocks_confirmed": 1},
        ])
        export_datasets(book, ["char_det"])
        files = _layer_label_files("char_det")
        # 页文件被删（跨页拆分/删页）：导出不动旧样本（宽容口径）
        os.remove(os.path.join(book, "annotations", "page_000.json"))
        result = export_datasets(book, ["char_det"])
        self.assertEqual(result["layers"]["char_det"]["pruned_pages"], 0)
        self.assertEqual(_layer_label_files("char_det"), files)

    def test_char_cls_pruned_when_line_confirm_reverted(self):
        book = _make_book(self._lib, "bookR", [
            {"pid": "page_000", "regions": [], "blocks_confirmed": 0},
        ])
        # 给 page_000 一条已确认行 + 已确认单字（char_cls 样本）
        ann = _read_ann(book, "page_000")
        ann["lines"] = [{
            "id": "l0", "x": 10, "y": 10, "w": 8, "h": 8,
            "status": "confirmed",
            "chars": [{"id": "c0", "x": 10, "y": 10, "w": 8, "h": 8,
                       "text": "天", "status": "confirmed"}],
        }]
        _write_ann(book, "page_000", ann)
        export_datasets(book, ["char_cls"])
        self.assertEqual(
            dataset_stats(book)["layers"]["char_cls"]["instances"], 1)
        # 行确认撤销 → char_cls 清理 + 统计回退
        ann = _read_ann(book, "page_000")
        _revert_all_confirms(ann)
        _write_ann(book, "page_000", ann)
        result = export_datasets(book, ["char_cls"])
        self.assertEqual(result["layers"]["char_cls"]["pruned_pages"], 1)
        self.assertEqual(result["layers"]["char_cls"]["manifest"]["instances"],
                         0)
        cls_dir = os.path.join(train_data.datasets_root(), "_global",
                               "char_cls")
        leftovers = [
            os.path.join(dp, n)
            for dp, _, ns in os.walk(cls_dir) for n in ns
            if n.startswith("bookR_page_000")
        ]
        self.assertEqual(leftovers, [])

    def test_region_det_all_unconfirmed_prunes_registered_pages(self):
        book = _make_book(self._lib, "bookS", [
            {"pid": "page_000", "regions": ["main_text"], "blocks_confirmed": 0},
            {"pid": "page_001", "regions": ["footer"], "blocks_confirmed": 0},
        ])
        export_datasets(book, ["region_det"])
        self.assertEqual(len(_layer_label_files("region_det")), 2)
        # 全书确认清空（allowed 为空）：已登记页也应全部清理，而不是跳过
        for pid in ("page_000", "page_001"):
            ann = _read_ann(book, pid)
            _revert_all_confirms(ann)
            _write_ann(book, pid, ann)
        result = export_datasets(book, ["region_det"])
        self.assertEqual(result["layers"]["region_det"]["pruned_pages"], 2)
        self.assertEqual(_layer_label_files("region_det"), [])
        self.assertEqual(
            result["layers"]["region_det"]["manifest"]["instances"], 0)


if __name__ == "__main__":
    unittest.main()
