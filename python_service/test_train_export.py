# -*- coding: utf-8 -*-
"""页级增量导出测试：manifest 记账、只导新增/变化页、删书保留、
region_det 全量导出（任意确认类别、与整本识别完成解耦）、baseline
转换、force 重写、pending 扫描。"""
import json
import os
import shutil
import tempfile
import unittest

import cv2
import numpy as np

import train_data
import train_datasets
import train_manifest as tm
from training_service import dataset_stats, export_datasets, generate_datasets


def _isolate(testcase):
    testcase._tmp = tempfile.mkdtemp(prefix="train_export_")
    testcase._old_root = train_data.DATASETS_ROOT
    train_data.DATASETS_ROOT = os.path.join(testcase._tmp, "datasets")
    train_datasets._MIGRATED = False


def _restore(testcase):
    train_data.DATASETS_ROOT = testcase._old_root
    train_datasets._MIGRATED = False
    shutil.rmtree(testcase._tmp, ignore_errors=True)


def _make_book(root, name, pages, *, completed=False):
    """pages: [{pid, regions: [(label|None)], blocks_confirmed: n}]"""
    book = os.path.join(root, name)
    os.makedirs(os.path.join(book, "annotations"))
    project = {"id": name, "settings": {}}
    if completed:
        project["recognition_status"] = "completed"
    with open(os.path.join(book, "project.json"), "w", encoding="utf-8") as f:
        json.dump(project, f, ensure_ascii=False)
    for spec in pages:
        img = np.zeros((100, 100), dtype=np.uint8)
        img_path = os.path.join(book, f"{spec['pid']}.png")
        ok, buf = cv2.imencode(".png", img)
        assert ok
        buf.tofile(img_path)
        regions = []
        for j, label in enumerate(spec.get("regions", [])):
            region = {"id": f"mr{j}", "x": 10, "y": 10 + j * 12, "w": 60,
                      "h": 10, "status": "confirmed"}
            if label is not None:
                region["label"] = label
            regions.append(region)
        ann = {
            "page_id": spec["pid"],
            "image_path": img_path,
            "main_regions": regions,
            "blocks": [
                {"id": f"b{i}", "x": 10, "y": 40 + i * 5, "w": 8, "h": 8,
                 "status": "confirmed"}
                for i in range(spec.get("blocks_confirmed", 0))
            ],
            "lines": [], "paragraphs": [],
        }
        with open(os.path.join(book, "annotations", f"{spec['pid']}.json"),
                  "w", encoding="utf-8") as f:
            json.dump(ann, f, ensure_ascii=False)
    return book


def _ann_path(book, pid):
    return os.path.join(book, "annotations", f"{pid}.json")


def _layer_label_files(layer):
    g = os.path.join(train_data.datasets_root(), "_global", layer)
    out = []
    for split in ("train", "val"):
        d = os.path.join(g, split, "labels")
        if os.path.isdir(d):
            out += [os.path.join(d, n) for n in os.listdir(d)]
    return out


class IncrementalExportTests(unittest.TestCase):
    def setUp(self):
        _isolate(self)
        self._lib = tempfile.mkdtemp(prefix="train_export_lib_")

    def tearDown(self):
        _restore(self)
        shutil.rmtree(self._lib, ignore_errors=True)

    def test_second_export_is_noop_and_pending_drops_to_zero(self):
        from training_service import scan_pending

        book = _make_book(self._lib, "bookA", [
            {"pid": "page_000", "regions": ["main_text"],
             "blocks_confirmed": 2},
            {"pid": "page_001", "regions": ["header", "footer"],
             "blocks_confirmed": 1},
        ], completed=True)
        first = export_datasets(book, ["char_det", "region_det"])
        self.assertEqual(first["layers"]["char_det"]["new_pages"], 2)
        self.assertEqual(first["layers"]["region_det"]["new_pages"], 2)
        pending = scan_pending(book)["pending"]
        self.assertEqual(pending["char_det"]["pages"], 0)
        second = export_datasets(book, ["char_det", "region_det"])
        self.assertEqual(second["layers"]["char_det"]["new_pages"], 0)
        self.assertEqual(second["layers"]["char_det"]["updated_pages"], 0)
        self.assertFalse(second["layers"]["char_det"]["written"])

    def test_changed_page_rewrites_and_new_page_appends(self):
        book = _make_book(self._lib, "bookB", [
            {"pid": "page_000", "regions": ["main_text"],
             "blocks_confirmed": 2},
        ], completed=True)
        export_datasets(book, ["char_det"])
        # 变化：page_000 加一个确认字块；新增：page_001
        with open(_ann_path(book, "page_000"), encoding="utf-8") as f:
            ann = json.load(f)
        ann["blocks"].append({"id": "bx", "x": 50, "y": 50, "w": 8, "h": 8,
                              "status": "confirmed"})
        with open(_ann_path(book, "page_000"), "w", encoding="utf-8") as f:
            json.dump(ann, f, ensure_ascii=False)
        _make_page(book, "page_001", blocks=1)
        result = export_datasets(book, ["char_det"])
        self.assertEqual(result["layers"]["char_det"]["updated_pages"], 1)
        self.assertEqual(result["layers"]["char_det"]["new_pages"], 1)
        # 统计口径 = manifest：page_000 变更后 3 块 + page_001 新页 1 块
        self.assertEqual(result["layers"]["char_det"]["manifest"]["instances"], 4)

    def test_deleted_book_keeps_data_and_stats(self):
        book = _make_book(self._lib, "bookC", [
            {"pid": "page_000", "regions": ["main_text"],
             "blocks_confirmed": 2},
        ], completed=True)
        export_datasets(book, ["char_det"])
        before_stats = dataset_stats(book)["layers"]["char_det"]["instances"]
        files_before = _layer_label_files("char_det")
        # 删书（书库目录移除）后：样本与统计不变
        shutil.rmtree(book)
        after = dataset_stats(self._lib)
        self.assertEqual(after["layers"]["char_det"]["instances"], before_stats)
        self.assertEqual(_layer_label_files("char_det"), files_before)
        # 再导出也不动已删书的样本
        export_datasets(self._lib, ["char_det"])
        self.assertEqual(_layer_label_files("char_det"), files_before)

    def test_force_rewrites_library_pages_only(self):
        book = _make_book(self._lib, "bookD", [
            {"pid": "page_000", "regions": ["main_text"],
             "blocks_confirmed": 1},
        ], completed=True)
        export_datasets(book, ["char_det"])
        other = _make_book(self._lib, "bookE", [
            {"pid": "page_000", "regions": ["main_text"],
             "blocks_confirmed": 1},
        ], completed=True)
        export_datasets(other, ["char_det"])
        result = export_datasets(self._lib, ["char_det"], force=True)
        self.assertEqual(result["layers"]["char_det"]["updated_pages"], 2)


class RegionExportTests(unittest.TestCase):
    """region_det 全量导出（原"识别完成的书一次性抽 8 页"已移除）：
    主区快设/编辑器确认的版面区（主区/页眉/页脚等任意类别）全部进入
    训练集与统计，与整本识别是否完成解耦。"""

    def setUp(self):
        _isolate(self)
        self._lib = tempfile.mkdtemp(prefix="train_sample_")

    def tearDown(self):
        _restore(self)
        shutil.rmtree(self._lib, ignore_errors=True)

    def test_all_confirmed_pages_export_regardless_of_completion(self):
        # 12 页都有已确认版面区 → 全部导出（旧抽样只导 8 页）；书未整本
        # 识别完成（纯主区快设成果）也照导。
        from training_service import scan_pending

        pages = [{"pid": f"page_{i:03d}", "regions": ["main_text"],
                  "blocks_confirmed": 1} for i in range(12)]
        book = _make_book(self._lib, "bookS", pages, completed=False)
        first = export_datasets(book, ["region_det"])
        self.assertEqual(first["layers"]["region_det"]["new_pages"], 12)
        self.assertEqual(
            first["layers"]["region_det"]["manifest"]["instances"], 12)
        # 无未决页：pending 扫描为 0
        pending = scan_pending(book)["pending"]
        self.assertEqual(pending["region_det"]["pages"], 0)

    def test_later_confirmed_page_joins_incrementally(self):
        # 首导后另一页新确认了版面区 → 增量导出补上（旧"一次性抽样"语义
        # 下抽样集固定、永不补页）
        pages = [{"pid": "page_000", "regions": ["main_text"],
                  "blocks_confirmed": 1},
                 {"pid": "page_001", "regions": [], "blocks_confirmed": 1}]
        book = _make_book(self._lib, "bookT", pages, completed=False)
        export_datasets(book, ["region_det"])
        with open(_ann_path(book, "page_001"), encoding="utf-8") as f:
            ann = json.load(f)
        ann["main_regions"].append(
            {"id": "mr_new", "x": 5, "y": 5, "w": 10, "h": 10,
             "status": "confirmed", "label": "header"})
        with open(_ann_path(book, "page_001"), "w", encoding="utf-8") as f:
            json.dump(ann, f, ensure_ascii=False)
        second = export_datasets(book, ["region_det"])
        self.assertEqual(second["layers"]["region_det"]["new_pages"], 1)
        self.assertEqual(
            second["layers"]["region_det"]["manifest"]["instances"], 2)

    def test_pages_without_confirmed_regions_skipped(self):
        # 未确认版面区的页不产生 region_det 样本（其他层不受影响）
        pages = [{"pid": "page_000", "regions": [], "blocks_confirmed": 2},
                 {"pid": "page_001", "regions": ["header"],
                  "blocks_confirmed": 1}]
        book = _make_book(self._lib, "bookU", pages, completed=True)
        with open(_ann_path(book, "page_000"), encoding="utf-8") as f:
            ann = json.load(f)
        ann["main_regions"] = []
        with open(_ann_path(book, "page_000"), "w", encoding="utf-8") as f:
            json.dump(ann, f, ensure_ascii=False)
        result = export_datasets(book, ["region_det", "char_det"])
        self.assertEqual(result["layers"]["region_det"]["new_pages"], 1)
        self.assertEqual(result["layers"]["char_det"]["new_pages"], 2)


class ManifestBaselineTests(unittest.TestCase):
    def setUp(self):
        _isolate(self)
        self._lib = tempfile.mkdtemp(prefix="train_baseline_")

    def tearDown(self):
        _restore(self)
        shutil.rmtree(self._lib, ignore_errors=True)

    def test_meta_json_converted_to_manifest_baseline(self):
        book = _make_book(self._lib, "bookM", [
            {"pid": "page_000", "regions": ["main_text"],
             "blocks_confirmed": 1},
            {"pid": "page_001", "regions": ["main_text"],
             "blocks_confirmed": 1},
        ], completed=True)
        # 旧链路（按书整写）先产出 _meta.json
        generate_datasets(book, ["char_det"], force=True)
        manifest = tm.ensure_manifest_baseline()
        self.assertIn("bookM", manifest["books"])
        entry = manifest["books"]["bookM"]["layers"]["char_det"]
        self.assertEqual(entry.get("train_instances", 0)
                         + entry.get("val_instances", 0), 2)
        self.assertTrue(manifest["books"]["bookM"].get("baseline"))
        # 统计走 manifest：删掉书目录后统计仍在（baseline 口径兜底分支）
        shutil.rmtree(book)
        stats = dataset_stats(self._lib)
        self.assertEqual(stats["layers"]["char_det"]["instances"], 2)

    def test_manifest_moves_with_dataset_folder(self):
        # 模拟跨机迁移：换一个数据集根目录，把整个目录拷过去，统计随行
        book = _make_book(self._lib, "bookX", [
            {"pid": "page_000", "regions": ["main_text"],
             "blocks_confirmed": 2},
        ], completed=True)
        export_datasets(book, ["char_det"])
        old_root = train_data.datasets_root()
        new_root = os.path.join(self._tmp, "moved_datasets")
        shutil.copytree(old_root, new_root)
        train_data.DATASETS_ROOT = new_root
        train_datasets._MIGRATED = False
        try:
            stats = dataset_stats(self._lib)
            self.assertEqual(stats["layers"]["char_det"]["instances"], 2)
            # 新根下的再导出：manifest 已记账 → 无新增
            result = export_datasets(book, ["char_det"])
            self.assertEqual(result["layers"]["char_det"]["new_pages"], 0)
        finally:
            train_data.DATASETS_ROOT = old_root


class ConfirmedExcludedRegionFilterTests(unittest.TestCase):
    """页眉页脚只作版面标注（region_det）：已确认排除类区内的行/字/
    段落不进内容层训练数据；region_det 照常收录全部已确认区。"""

    def _page(self, *, header_confirmed=True):
        return {
            "page_id": "page_000",
            "image_path": "x.png",
            "main_regions": [
                {"id": "mr_h", "x": 0, "y": 0, "w": 100, "h": 20,
                 "label": "header",
                 "status": "confirmed" if header_confirmed else "proposed"},
                {"id": "mr_m", "x": 0, "y": 30, "w": 100, "h": 60,
                 "label": "main_text", "status": "confirmed"},
            ],
            "lines": [
                {"id": "l_h", "x": 40, "y": 5, "w": 20, "h": 8,
                 "status": "confirmed",
                 "chars": [{"id": "c_h", "x": 40, "y": 5, "w": 8, "h": 8,
                            "status": "confirmed", "text": "眉"}]},
                {"id": "l_m", "x": 40, "y": 50, "w": 20, "h": 8,
                 "status": "confirmed",
                 "chars": [{"id": "c_m", "x": 40, "y": 50, "w": 8, "h": 8,
                            "status": "confirmed", "text": "正"}]},
            ],
            "blocks": [
                {"id": "c_h", "x": 40, "y": 5, "w": 8, "h": 8,
                 "status": "confirmed"},
                {"id": "c_m", "x": 40, "y": 50, "w": 8, "h": 8,
                 "status": "confirmed"},
            ],
            "paragraphs": [],
        }

    def test_content_layers_drop_confirmed_excluded(self):
        from train_datasets import page_labels, char_cls_page_items

        ann = self._page()
        # char_det / line_det：只留正文区里的那一个
        self.assertEqual(len(page_labels("char_det", ann)), 1)
        self.assertEqual(len(page_labels("line_det", ann)), 1)
        # char_cls：页眉行不产分类样本
        items = char_cls_page_items(ann)
        self.assertEqual([i["text"] for i in items], ["正"])
        # region_det：页眉+正文两个都收（页眉正是它的训练样本）
        self.assertEqual(len(page_labels("region_det", ann)), 2)

    def test_proposed_excluded_region_does_not_filter(self):
        from train_datasets import page_labels

        ann = self._page(header_confirmed=False)
        # 未确认的排除类候选不挡数据：两个字块都进 char_det
        self.assertEqual(len(page_labels("char_det", ann)), 2)

    def test_paragraph_inference_skips_excluded_lines(self):
        from train_datasets import page_labels

        ann = self._page()
        ann["lines"][1]["chars"][0]["type"] = "annotation"
        # 行级联推断段落：只剩正文行参与（页眉行被排除）
        labels = page_labels("paragraph_det", ann, "ltr")
        self.assertEqual(len(labels), 1)

    def test_export_end_to_end_excludes_header_chars(self):
        _isolate(self)
        self._lib = tempfile.mkdtemp(prefix="train_export_lib_")
        try:
            ann = self._page()
            book = os.path.join(self._lib, "bookG")
            os.makedirs(os.path.join(book, "annotations"))
            with open(os.path.join(book, "project.json"), "w",
                      encoding="utf-8") as f:
                json.dump({"id": "bookG", "settings": {}}, f)
            img = np.zeros((100, 100), dtype=np.uint8)
            img_path = os.path.join(book, "page_000.png")
            ok, buf = cv2.imencode(".png", img)
            assert ok
            buf.tofile(img_path)
            ann["image_path"] = img_path
            with open(_ann_path(book, "page_000"), "w",
                      encoding="utf-8") as f:
                json.dump(ann, f, ensure_ascii=False)
            result = export_datasets(book, ["char_det", "region_det"])
            # 2 个确认字块只有正文 1 个入账；版面区 2 个全入账
            self.assertEqual(result["layers"]["char_det"]["manifest"]["instances"], 1)
            self.assertEqual(result["layers"]["region_det"]["manifest"]["instances"], 2)
        finally:
            _restore(self)
            shutil.rmtree(self._lib, ignore_errors=True)


def _make_page(book, pid, blocks=0, regions=None):
    """向已有书追加一页（带真图与确认标注）。"""
    img = np.zeros((100, 100), dtype=np.uint8)
    img_path = os.path.join(book, f"{pid}.png")
    ok, buf = cv2.imencode(".png", img)
    assert ok
    buf.tofile(img_path)
    ann = {
        "page_id": pid,
        "image_path": img_path,
        "main_regions": [
            {"id": f"mr{i}", "x": 10, "y": 10 + i * 12, "w": 60, "h": 10,
             "status": "confirmed", **({"label": lb} if lb else {})}
            for i, lb in enumerate(regions or ["main_text"])
        ],
        "blocks": [
            {"id": f"b{i}", "x": 10, "y": 40 + i * 5, "w": 8, "h": 8,
             "status": "confirmed"} for i in range(blocks)
        ],
        "lines": [], "paragraphs": [],
    }
    with open(os.path.join(book, "annotations", f"{pid}.json"), "w",
              encoding="utf-8") as f:
        json.dump(ann, f, ensure_ascii=False)


class ExportMaterialTests(unittest.TestCase):
    """导出素材处理：过大降采样到 MAX_EXPORT_SIDE、统一存 JPG（q95）、
    换格式重写清理旧扩展名文件（防同页双样本）。"""

    def setUp(self):
        _isolate(self)

    def tearDown(self):
        _restore(self)

    def _images(self, layer):
        g = os.path.join(train_data.datasets_root(), "_global", layer)
        found = []
        for split in ("train", "val"):
            d = os.path.join(g, split, "images")
            if os.path.isdir(d):
                found += [os.path.join(d, n) for n in os.listdir(d)]
        return found

    def test_detect_big_png_downscaled_to_jpg(self):
        lib = tempfile.mkdtemp(prefix="mat_lib_")
        book = _make_book(lib, "bookM", [
            {"pid": "page_000", "regions": ["main_text"]},
        ])
        # 覆盖成 3200×1800 大图（_make_book 默认 100×100）
        big = np.zeros((1800, 3200), dtype=np.uint8)
        ok, buf = cv2.imencode(".png", big)
        assert ok
        buf.tofile(os.path.join(book, "page_000.png"))
        export_datasets(book, ["region_det"])
        files = self._images("region_det")
        self.assertEqual(len(files), 1)
        self.assertTrue(files[0].endswith(".jpg"), files[0])
        out = cv2.imread(files[0], cv2.IMREAD_UNCHANGED)
        self.assertEqual(max(out.shape[:2]), 2560)
        shutil.rmtree(lib, ignore_errors=True)

    def test_detect_rewrite_purges_stale_png(self):
        lib = tempfile.mkdtemp(prefix="mat_lib_")
        book = _make_book(lib, "bookO", [
            {"pid": "page_000", "regions": ["main_text"]},
        ])
        export_datasets(book, ["region_det"])
        (jpg,) = self._images("region_det")
        # 模拟 PNG 时代的旧文件：同 base 不同扩展名
        stale = os.path.splitext(jpg)[0] + ".png"
        open(stale, "wb").close()
        export_datasets(lib, ["region_det"], force=True)
        files = self._images("region_det")
        self.assertEqual([os.path.basename(f) for f in files],
                         ["bookO_page_000.jpg"])
        shutil.rmtree(lib, ignore_errors=True)

    def test_char_cls_crops_jpg_metadata_and_page_purge(self):
        lib = tempfile.mkdtemp(prefix="mat_lib_")
        book = _make_book(lib, "bookN", [{"pid": "page_000"}])
        with open(_ann_path(book, "page_000"), encoding="utf-8") as f:
            ann = json.load(f)
        ann["lines"] = [{
            "id": "l0", "status": "confirmed",
            "x": 0, "y": 0, "w": 80, "h": 40,
            "chars": [{"text": "天", "x": 10, "y": 10, "w": 30, "h": 30,
                       "status": "confirmed"}],
        }]
        with open(_ann_path(book, "page_000"), "w", encoding="utf-8") as f:
            json.dump(ann, f, ensure_ascii=False)
        export_datasets(book, ["char_cls"])
        cls_dir = os.path.join(train_data.datasets_root(), "_global",
                               "char_cls", "train", "天")
        self.assertEqual(os.listdir(cls_dir), ["bookN_page_000_l0_0.jpg"])
        meta_path = os.path.join(os.path.dirname(os.path.dirname(cls_dir)),
                                 "metadata_bookN.json")
        with open(meta_path, encoding="utf-8") as f:
            meta = json.load(f)
        self.assertTrue(meta["samples"][0]["path"].endswith(".jpg"))
        # 旧 .png 残留（格式迁移/序号变化）：重写该页时清掉
        open(os.path.join(cls_dir, "bookN_page_000_l0_0.png"), "wb").close()
        export_datasets(book, ["char_cls"], force=True)
        self.assertEqual(os.listdir(cls_dir), ["bookN_page_000_l0_0.jpg"])
        shutil.rmtree(lib, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
