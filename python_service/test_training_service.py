import json
import os
import shutil
import sys
import tempfile
import unittest

import cv2
import numpy as np

import train_data
import train_datasets
from train_tasks import training_curve
from train_worker import list_checkpoints
from training_service import _page_split, _training_readiness, dataset_stats, has_books


def _isolate_datasets_root(testcase):
    """把全局数据集根切到临时目录：统计/生成/迁移都不碰真实书库。"""
    testcase._tmp_root = tempfile.mkdtemp(prefix="train_global_")
    testcase._old_root = train_data.DATASETS_ROOT
    train_data.DATASETS_ROOT = os.path.join(testcase._tmp_root, "datasets")
    train_datasets._MIGRATED = False


def _restore_datasets_root(testcase):
    train_data.DATASETS_ROOT = testcase._old_root
    train_datasets._MIGRATED = False
    shutil.rmtree(testcase._tmp_root, ignore_errors=True)


class TrainingReadinessTests(unittest.TestCase):
    def test_backbone_size_increases_required_samples(self):
        readiness = _training_readiness("char_det", 900)
        requirements = readiness["requirements"]
        self.assertTrue(requirements["yolov8n"]["ready"])
        self.assertTrue(requirements["yolov8s"]["ready"])
        self.assertFalse(requirements["yolov8m"]["ready"])
        self.assertEqual(readiness["recommended_model"], "yolov8n")

    def test_classifier_requires_both_samples_and_classes(self):
        readiness = _training_readiness("char_cls", 500, 10)
        compact = readiness["requirements"]["yolov8n"]
        self.assertFalse(compact["ready"])
        self.assertEqual(compact["missing_classes"], 40)
        self.assertEqual(compact["progress"], 0.2)

    def test_page_split_never_duplicates_page(self):
        pages = [{"page_id": f"page_{i:03d}"} for i in range(10)]
        first = _page_split(pages, 0.8, 42)
        second = _page_split(pages, 0.8, 42)
        self.assertEqual(first, second)
        self.assertEqual(set(first.values()), {"train", "val"})
        self.assertEqual(sum(value == "val" for value in first.values()), 2)


class TrainingRoundEscalationTests(unittest.TestCase):
    def test_trained_tier_requires_more_data_for_next_round(self):
        # s 档已成功训练 1 次 → 第 2 轮需要 900*2=1800 个样本
        readiness = _training_readiness(
            "char_det", 1210, rounds_by_model={"yolov8s": 1}
        )
        requirements = readiness["requirements"]
        self.assertEqual(requirements["yolov8s"]["rounds"], 2)
        self.assertEqual(requirements["yolov8s"]["target_instances"], 1800)
        self.assertFalse(requirements["yolov8s"]["ready"])
        self.assertEqual(requirements["yolov8s"]["missing_instances"], 590)
        # 未训练过的档位仍按第一轮基础要求计
        self.assertEqual(requirements["yolov8m"]["rounds"], 1)
        self.assertEqual(requirements["yolov8m"]["target_instances"], 1800)

    def test_milestone_prefers_continuing_same_tier_on_tie(self):
        # s 第 2 轮与 m 第 1 轮同为 1800：并列时同一模型连续进化优先（s r2）
        readiness = _training_readiness(
            "char_det", 1210, rounds_by_model={"yolov8s": 1}
        )
        self.assertEqual(readiness["next_milestone"]["model"], "yolov8s")
        self.assertEqual(readiness["next_milestone"]["rounds"], 2)
        self.assertEqual(readiness["next_milestone"]["target_instances"], 1800)

    def test_same_tier_escalates_round_by_round(self):
        # n 训完 2 轮 → 里程碑指向 n 第 3 轮（900），与 s 第 1 轮并列时仍选 n
        readiness = _training_readiness(
            "char_det", 650, rounds_by_model={"yolov8n": 2}
        )
        self.assertEqual(readiness["next_milestone"]["model"], "yolov8n")
        self.assertEqual(readiness["next_milestone"]["rounds"], 3)
        # 第 3 轮要求 300*3=900，还差 250 个样本
        self.assertEqual(readiness["next_milestone"]["missing_instances"], 250)

    def test_milestone_keeps_escalating_within_tier(self):
        # n 训完 3 轮（s 首轮要求已被数据满足）→ 里程碑继续指向 n 第 4 轮
        readiness = _training_readiness(
            "char_det", 950, rounds_by_model={"yolov8n": 3}
        )
        self.assertEqual(readiness["next_milestone"]["model"], "yolov8n")
        self.assertEqual(readiness["next_milestone"]["rounds"], 4)
        self.assertEqual(readiness["next_milestone"]["target_instances"], 1200)
        self.assertEqual(readiness["next_milestone"]["missing_instances"], 250)

    def test_milestone_targets_cheapest_unmet_requirement(self):
        # 数据不足时里程碑指向要求最低的未达标档位
        readiness = _training_readiness("char_det", 100)
        self.assertEqual(readiness["next_milestone"]["model"], "yolov8n")
        self.assertFalse(readiness["next_milestone"]["ready"])

    def test_milestone_falls_back_to_largest_when_all_ready(self):
        # 四个档位（含 l）都达标 → 里程碑指向要求最高的 l
        readiness = _training_readiness("char_det", 4000)
        self.assertEqual(readiness["next_milestone"]["model"], "yolov8l")
        self.assertTrue(readiness["next_milestone"]["ready"])

    def test_classifier_class_target_does_not_escalate_with_rounds(self):
        # 字类覆盖要求不随轮数放大，只放大样本量
        readiness = _training_readiness(
            "char_cls", 921, 346, rounds_by_model={"yolov8n": 1}
        )
        n = readiness["requirements"]["yolov8n"]
        self.assertEqual(n["target_instances"], 1000)
        self.assertEqual(n["target_classes"], 50)
        # 字类 346 已远超 50；样本 921 差 79 个到第 2 轮的 1000
        self.assertFalse(n["ready"])
        self.assertEqual(n["missing_instances"], 79)
        self.assertEqual(n["missing_classes"], 0)

def _make_book(ann: dict) -> str:
    """临时书籍项目：project.json + 单页标注 + 真图（导出要拷贝图片）。"""
    root = tempfile.mkdtemp(prefix="train_stat_")
    book = os.path.join(root, "book")
    os.makedirs(os.path.join(book, "annotations"))
    with open(os.path.join(book, "project.json"), "w", encoding="utf-8") as f:
        json.dump({"id": "book", "settings": {}}, f, ensure_ascii=False)
    img = np.zeros((256, 256), dtype=np.uint8)
    img_path = os.path.join(book, "page_000.png")
    ok, buf = cv2.imencode(".png", img)
    assert ok
    buf.tofile(img_path)
    ann = {**ann, "image_path": img_path}
    with open(
        os.path.join(book, "annotations", "page_000.json"), "w", encoding="utf-8"
    ) as f:
        json.dump(ann, f, ensure_ascii=False)
    return book


class DatasetStatsBoxConfirmedTests(unittest.TestCase):
    """「确认识别框」的 box_confirmed 标记计入检测层统计；文字类门槛不变。"""

    def setUp(self):
        _isolate_datasets_root(self)

    def tearDown(self):
        _restore_datasets_root(self)

    def _ann(self) -> dict:
        char = {"id": "c1", "x": 0, "y": 0, "w": 10, "h": 10,
                "text": "之", "status": "proposed"}
        return {
            "page_id": "page_000",
            "image_path": "",
            "main_regions": [
                {"id": "mr1", "x": 0, "y": 0, "w": 100, "h": 200, "status": "proposed"},
            ],
            "paragraphs": [
                {"id": "p1", "x": 0, "y": 0, "w": 100, "h": 80},
            ],
            "lines": [
                {"id": "l1", "x": 0, "y": 0, "w": 100, "h": 20,
                 "chars": [dict(char)]},
            ],
            "blocks": [char],
        }

    def _mark(self, ann: dict) -> dict:
        # 模拟 Flutter 端 markBoxesConfirmed 的落盘结果
        ann["boxes_reviewed"] = True
        for r in ann["main_regions"]:
            r["box_confirmed"] = True
        for p in ann["paragraphs"]:
            p["box_confirmed"] = True
        for ln in ann["lines"]:
            ln["box_confirmed"] = True
            for c in ln.get("chars", []):
                c["box_confirmed"] = True
        for b in ann.get("blocks", []):
            b["box_confirmed"] = True
        return ann

    def test_box_confirmed_counts_into_all_detection_layers(self):
        from training_service import export_datasets

        # 统计 = 已导出（manifest）口径：先增量导出，再断言各层实例数
        book = _make_book(self._mark(self._ann()))
        export_datasets(book,
                        ["char_det", "line_det", "paragraph_det", "char_cls"])
        layers = dataset_stats(book)["layers"]
        self.assertEqual(layers["paragraph_det"]["instances"], 1)
        self.assertEqual(layers["line_det"]["instances"], 1)
        # 字框几何确认 → 计入检测
        self.assertEqual(layers["char_det"]["instances"], 1)
        # 文字未确认 → 不计入分类，也不产生字类
        self.assertEqual(layers["char_cls"]["instances"], 0)
        self.assertEqual(layers["char_cls"]["classes"], 0)
        # 书未识别完成 → region_det 不导出（等待完成后一次性抽样）
        self.assertEqual(layers["region_det"]["instances"], 0)

    def test_proposed_boxes_do_not_count(self):
        ann = self._ann()
        # 未打 box_confirmed、status 全 proposed：检测层全为 0
        stats = dataset_stats(_make_book(ann))
        layers = stats["layers"]
        self.assertEqual(layers["region_det"]["instances"], 0)
        self.assertEqual(layers["paragraph_det"]["instances"], 0)
        self.assertEqual(layers["line_det"]["instances"], 0)
        self.assertEqual(layers["char_det"]["instances"], 0)

    def test_confirmed_status_still_counts(self):
        ann = self._ann()
        for r in ann["main_regions"]:
            r["status"] = "confirmed"
        for p in ann["paragraphs"]:
            p["status"] = "confirmed"
        for ln in ann["lines"]:
            ln["status"] = "confirmed"
            for c in ln["chars"]:
                c["status"] = "confirmed"
        for b in ann["blocks"]:
            b["status"] = "confirmed"
        from training_service import export_datasets

        book = _make_book(ann)
        export_datasets(book)
        layers = dataset_stats(book)["layers"]
        self.assertEqual(layers["paragraph_det"]["instances"], 1)
        self.assertEqual(layers["line_det"]["instances"], 1)
        self.assertEqual(layers["char_det"]["instances"], 1)
        # 完全确认的文字计入分类
        self.assertEqual(layers["char_cls"]["instances"], 1)
        # 版面区确认即导出（与整本识别完成解耦——主区快设成果全量进
        # region_det，原"完成书一次性抽样"门槛已移除）
        self.assertEqual(layers["region_det"]["instances"], 1)


class HasBooksTests(unittest.TestCase):
    """训练入口校验语义：单本书目录与库根目录（汇总模式）都必须放行。

    /train/datasets、/train/start 曾只认 project.json，训练页默认数据源
    「全部书籍（汇总）」传的是库根目录 → 启动即报 project not found，
    而统计/预检接口接受库根目录出现"检测全绿、启动失败"的矛盾。"""

    def setUp(self):
        _isolate_datasets_root(self)

    def tearDown(self):
        _restore_datasets_root(self)

    def test_single_book_dir_passes(self):
        book = _make_book({"page_id": "page_000", "image_path": ""})
        self.assertTrue(has_books(book))

    def test_library_root_with_books_passes_and_aggregates(self):
        book = _make_book({"page_id": "page_000", "image_path": ""})
        root = os.path.dirname(book)
        self.assertTrue(has_books(root))
        # 入口放行的库根目录，统计接口必须同样吃得下（口径一致）
        self.assertEqual(dataset_stats(root)["pages"], 1)

    def test_empty_library_root_fails(self):
        root = tempfile.mkdtemp(prefix="train_empty_")
        self.assertFalse(has_books(root))

    def test_missing_path_fails(self):
        missing = os.path.join(tempfile.gettempdir(), "no_such_train_dir")
        self.assertFalse(has_books(missing))


def _make_book_with_images(root: str, name: str, pages: int = 2) -> str:
    """临时书籍项目：project.json + 真实小图 + 整页已确认的检测标注。"""
    book = os.path.join(root, name)
    ann_dir = os.path.join(book, "annotations")
    os.makedirs(ann_dir)
    with open(os.path.join(book, "project.json"), "w", encoding="utf-8") as f:
        json.dump({"id": name, "settings": {},
                   "recognition_status": "completed"}, f, ensure_ascii=False)
    for i in range(pages):
        img = np.zeros((64, 64), dtype=np.uint8)
        img_path = os.path.join(book, f"page_{i:03d}.png")
        ok, buf = cv2.imencode(".png", img)
        assert ok
        buf.tofile(img_path)
        ann = {
            "page_id": f"page_{i:03d}",
            "image_path": img_path,
            "main_regions": [
                {"x": 4, "y": 4, "w": 40, "h": 50, "status": "confirmed"}],
            "blocks": [
                {"x": 8, "y": 8, "w": 12, "h": 14, "status": "confirmed"}],
            "lines": [],
            "paragraphs": [],
        }
        with open(os.path.join(ann_dir, f"page_{i:03d}.json"), "w",
                  encoding="utf-8") as f:
            json.dump(ann, f, ensure_ascii=False)
    return book



class GlobalDatasetSharingTests(unittest.TestCase):
    """数据集全局共享：所有书的样本合并进 datasets/_global/<layer>/。

    从任何一本书（或库根）统计/取数据集，看到的都是同一份累计数据；
    对某本书重新生成只替换它自己的样本，其他书的贡献不动——模型产物
    与注册表本就是全局的，数据集与其同口径。"""

    def setUp(self):
        _isolate_datasets_root(self)
        self._lib = tempfile.mkdtemp(prefix="train_lib_")
        self.book_a = _make_book_with_images(self._lib, "bookA", pages=2)
        self.book_b = _make_book_with_images(self._lib, "bookB", pages=1)

    def tearDown(self):
        _restore_datasets_root(self)
        shutil.rmtree(self._lib, ignore_errors=True)

    def _layer_images(self, layer: str) -> list[str]:
        out = []
        g = os.path.join(train_data.DATASETS_ROOT, "_global", layer)
        for split in ("train", "val"):
            d = os.path.join(g, split, "images")
            if os.path.isdir(d):
                out.extend(os.listdir(d))
        return out

    def test_stats_aggregate_whole_library_from_any_book(self):
        from training_service import export_datasets

        # 统计 = 已导出（manifest）口径：先从库根增量导出一次
        export_datasets(self._lib)
        # 单本书/另一本书/库根三种入口，统计结果完全一致（全局口径）
        stats_a = dataset_stats(self.book_a)
        stats_b = dataset_stats(self.book_b)
        stats_root = dataset_stats(self._lib)
        for stats in (stats_a, stats_b, stats_root):
            self.assertEqual(stats["pages"], 3)
            self.assertEqual(stats["layers"]["region_det"]["instances"], 3)
            self.assertEqual(stats["layers"]["char_det"]["instances"], 3)
        # 数据集目录任何入口都是同一条全局路径
        dir_a = stats_a["layers"]["region_det"]["dataset_dir"]
        self.assertEqual(dir_a, stats_b["layers"]["region_det"]["dataset_dir"])
        self.assertEqual(dir_a, stats_root["layers"]["region_det"]["dataset_dir"])
        self.assertEqual(dir_a, train_datasets.global_layer_dir("region_det"))

    def test_generate_merges_books_and_regenerates_only_requested(self):
        from training_service import generate_datasets
        generate_datasets(self.book_a, ["region_det"], force=True)
        self.assertEqual(len(self._layer_images("region_det")), 2)
        generate_datasets(self.book_b, ["region_det"], force=True)
        images = self._layer_images("region_det")
        self.assertEqual(len(images), 3)
        self.assertEqual(
            {n.split("_")[0] for n in images}, {"bookA", "bookB"})
        # 重新生成 bookA 不动 bookB 的样本
        generate_datasets(self.book_a, ["region_det"], force=True)
        self.assertEqual(len(self._layer_images("region_det")), 3)
        # data.yaml 指向全局目录
        yaml_path = os.path.join(
            train_datasets.global_layer_dir("region_det"), "data.yaml")
        with open(yaml_path, encoding="utf-8") as f:
            head = f.readline()
        self.assertIn("_global/region_det", head.replace("\\", "/"))

    def test_dataset_dir_shared_and_auto_generates_library(self):
        from training_service import dataset_dir
        # 从 bookB 发起也自动按整个书库生成（三页全部并入）
        out = dataset_dir(self.book_b, "region_det")
        self.assertEqual(out, train_datasets.global_layer_dir("region_det"))
        self.assertEqual(len(self._layer_images("region_det")), 3)
        self.assertEqual(dataset_dir(self.book_a, "region_det"), out)

    def test_legacy_per_book_datasets_migrated(self):
        pid = "1789591116071"
        legacy_layer = os.path.join(
            train_data.DATASETS_ROOT, pid, "region_det")
        for split, pages in (("train", ["page_000", "page_001"]),
                             ("val", ["page_002"])):
            for kind in ("images", "labels"):
                os.makedirs(os.path.join(legacy_layer, split, kind))
            for pg in pages:
                with open(os.path.join(legacy_layer, split, "images",
                                       pg + ".png"), "wb") as f:
                    f.write(b"\x89PNG\r\n\x1a\n")
                with open(os.path.join(legacy_layer, split, "labels",
                                       pg + ".txt"), "w") as f:
                    f.write("0 0.5 0.5 0.2 0.2\n")
        with open(os.path.join(train_data.DATASETS_ROOT, pid, "_meta.json"),
                  "w", encoding="utf-8") as f:
            json.dump({"generated_at": 1.0, "pages": 3, "settings": {},
                       "layers": {"region_det": {"train_pages": 2}}}, f)
        train_datasets._migrate_legacy_datasets()
        g = os.path.join(train_data.DATASETS_ROOT, "_global", "region_det")
        images = []
        for split in ("train", "val"):
            images += os.listdir(os.path.join(g, split, "images"))
        self.assertEqual(sorted(images), [
            f"{pid}_page_000.png", f"{pid}_page_001.png",
            f"{pid}_page_002.png"])
        self.assertTrue(os.path.exists(os.path.join(g, "data.yaml")))
        # 旧目录移入 _legacy 保留备份，不删除
        self.assertFalse(os.path.exists(
            os.path.join(train_data.DATASETS_ROOT, pid)))
        self.assertTrue(os.path.isdir(os.path.join(
            train_data.DATASETS_ROOT, "_legacy", pid)))
        # 幂等：重复迁移不再动任何东西
        train_datasets._MIGRATED = False
        train_datasets._migrate_legacy_datasets()
        self.assertEqual(len(images), 3)


class RegionDetMultiClassTests(unittest.TestCase):
    """region_det 多类化：label→类别 id 映射、data.yaml 类名、词表指纹
    触发缓存重建、/train/stats 的每类分布。"""

    def setUp(self):
        _isolate_datasets_root(self)
        self._lib = tempfile.mkdtemp(prefix="train_region_")

    def tearDown(self):
        _restore_datasets_root(self)
        shutil.rmtree(self._lib, ignore_errors=True)

    def _make_book(self, name: str, region_specs: list[tuple[int, str]]) -> str:
        """region_specs: [(页序, label 或 None)]，坐标固定合法小框。"""
        book = os.path.join(self._lib, name)
        ann_dir = os.path.join(book, "annotations")
        os.makedirs(ann_dir)
        with open(os.path.join(book, "project.json"), "w", encoding="utf-8") as f:
            json.dump({"id": name, "settings": {}}, f, ensure_ascii=False)
        pages = sorted({i for i, _ in region_specs})
        labels_by_page: dict[int, list[str | None]] = {}
        for i, label in region_specs:
            labels_by_page.setdefault(i, []).append(label)
        for i in pages:
            img = np.zeros((64, 64), dtype=np.uint8)
            img_path = os.path.join(book, f"page_{i:03d}.png")
            ok, buf = cv2.imencode(".png", img)
            assert ok
            buf.tofile(img_path)
            regions = []
            for j, label in enumerate(labels_by_page[i]):
                region = {"x": 4, "y": 4 + j * 8, "w": 40, "h": 6,
                          "status": "confirmed"}
                if label is not None:
                    region["label"] = label
                regions.append(region)
            ann = {"page_id": f"page_{i:03d}", "image_path": img_path,
                   "main_regions": regions, "blocks": [], "lines": [],
                   "paragraphs": []}
            with open(os.path.join(ann_dir, f"page_{i:03d}.json"), "w",
                      encoding="utf-8") as f:
                json.dump(ann, f, ensure_ascii=False)
        return book

    def _mark_completed(self, book: str) -> None:
        with open(os.path.join(book, "project.json"), encoding="utf-8") as f:
            project = json.load(f)
        project["recognition_status"] = "completed"
        with open(os.path.join(book, "project.json"), "w",
                  encoding="utf-8") as f:
            json.dump(project, f, ensure_ascii=False)

    def _label_cls_ids(self, book_id: str) -> dict[str, set[int]]:
        """从全局数据集标签文件读回 {页ID: {类别 id 集合}}。"""
        g = os.path.join(train_data.DATASETS_ROOT, "_global", "region_det")
        out: dict[str, set[int]] = {}
        for split in ("train", "val"):
            lbl_dir = os.path.join(g, split, "labels")
            if not os.path.isdir(lbl_dir):
                continue
            for name in os.listdir(lbl_dir):
                if not name.startswith(book_id + "_"):
                    continue
                page = name[len(book_id) + 1:-len(".txt")]
                ids: set[int] = set()
                with open(os.path.join(lbl_dir, name), encoding="utf-8") as f:
                    for line in f:
                        if line.strip():
                            ids.add(int(line.split()[0]))
                out[page] = ids
        return out

    def test_region_labels_map_to_class_ids(self):
        from training_service import generate_datasets
        book = self._make_book("bookM", [
            (0, "main_text"), (0, "header"), (0, "footer"),
            (0, "page_number"), (0, "margin_note"),
            (1, None),  # 旧标注无 label → 缺省 main_text
            (1, "weird_label"),  # 词表外 → 跳过并计数
        ])
        result = generate_datasets(book, ["region_det"], force=True)
        ids = self._label_cls_ids("bookM")
        self.assertEqual(ids["page_000"], {0, 1, 2, 3, 4})
        self.assertEqual(ids["page_001"], {0})
        self.assertEqual(
            result["layers"]["region_det"]["skipped"]["unknown_class"], 1)

    def test_data_yaml_lists_all_region_classes_in_order(self):
        from training_service import generate_datasets
        book = self._make_book("bookY", [(0, "main_text"), (1, "main_text")])
        generate_datasets(book, ["region_det"], force=True)
        yaml_path = os.path.join(
            train_datasets.global_layer_dir("region_det"), "data.yaml")
        with open(yaml_path, encoding="utf-8") as f:
            content = f.read()
        names = train_data.LAYER_INFO["region_det"]["names"]
        self.assertEqual(names[0], "main_text")  # id=0 恒为 main_text
        for i, name in enumerate(names):
            self.assertIn(f"  {i}: {name}\n", content)

    def test_names_fingerprint_invalidates_cached_dataset(self):
        from training_service import generate_datasets
        book = self._make_book("bookC", [
            (0, "main_text"), (0, "header"), (1, "footer")])
        generate_datasets(book, ["region_det"], force=True)
        # 第二次不 force：类集一致 → 命中缓存
        again = generate_datasets(book, ["region_det"])
        self.assertTrue(again["layers"]["region_det"]["cached"])
        # 模拟旧版本写入的单类缓存条目（classes 与当前词表不符）→ 必须重建
        meta_path = train_datasets._meta_path()
        with open(meta_path, encoding="utf-8") as f:
            meta = json.load(f)
        meta["books"]["bookC"]["layers"]["region_det"]["classes"] = ["main_text"]
        with open(meta_path, "w", encoding="utf-8") as f:
            json.dump(meta, f, ensure_ascii=False)
        rebuilt = generate_datasets(book, ["region_det"])
        self.assertFalse(rebuilt["layers"]["region_det"]["cached"])
        self.assertEqual(
            rebuilt["layers"]["region_det"]["classes"],
            train_data.LAYER_INFO["region_det"]["names"])
        # 重建后的标签仍带多类 id
        self.assertEqual(self._label_cls_ids("bookC")["page_000"], {0, 1})

    def test_stats_reports_region_class_distribution(self):
        from training_service import dataset_stats
        book = self._make_book("bookP", [
            (0, "main_text"), (0, "header"), (0, "header"),
            (1, "footer"), (1, None),
        ])
        # 完成书：一次性抽样（2 页 < 上限 8 → 全抽）后统计分布
        self._mark_completed(book)
        from training_service import export_datasets

        export_datasets(book)
        per_class = dataset_stats(book)["layers"]["region_det"]["per_class"]
        self.assertEqual(per_class, {"main_text": 2, "header": 2, "footer": 1})


class TrainingCurveTests(unittest.TestCase):
    """training_curve：results.csv 解析 + 检查点清单（不跑真实训练）。"""

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="train_curve_")

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _write(self, rel: str, content: str) -> None:
        path = os.path.join(self._tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(content)

    def _touch(self, rel: str) -> None:
        path = os.path.join(self._tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "wb").close()

    def test_detect_curve_parses_rows_and_checkpoints(self):
        self._write(
            "run/train/results.csv",
            "epoch,time,train/box_loss,train/cls_loss,train/dfl_loss,"
            "metrics/precision(B),metrics/recall(B),metrics/mAP50(B),"
            "metrics/mAP50-95(B),val/box_loss,val/cls_loss,val/dfl_loss,"
            "lr/pg0,lr/pg1,lr/pg2\n"
            "1,2.5,2.0,3.0,1.2,0.10,0.09,0.05,0.03,2.5,4.8,1.4,0,0,0\n"
            "2,3.5,1.8,2.7,1.1,0.20,0.19,0.10,0.07,2.2,4.1,1.3,0,0,0\n",
        )
        self._touch("run/train/weights/best.pt")
        self._touch("run/train/weights/last.pt")
        self._touch("run/train/weights/epoch2.pt")
        curve = training_curve(os.path.join(self._tmp, "run"))
        self.assertEqual(curve["kind"], "detect")
        self.assertEqual(len(curve["rows"]), 2)
        self.assertAlmostEqual(curve["rows"][1]["metrics/mAP50-95(B)"], 0.07)
        # epoch 检查点按轮数升序在前，best/last 排最后
        names = [c["name"] for c in curve["checkpoints"]]
        self.assertEqual(names, ["epoch2.pt", "best.pt", "last.pt"])
        self.assertEqual(curve["checkpoints"][0]["epoch"], 2)
        self.assertTrue(str(curve["best"]).endswith("best.pt"))

    def test_curve_tolerates_broken_cells(self):
        # 值为空/非数字的单元格解析为 None（前端按断点处理），不炸整表
        self._write(
            "run/train/results.csv",
            "epoch,time,train/box_loss,metrics/mAP50(B)\n"
            "1,2.5,2.0,0.05\n2,,not_a_number,\n",
        )
        curve = training_curve(os.path.join(self._tmp, "run"))
        self.assertEqual(curve["kind"], "detect")
        self.assertEqual(curve["rows"][1]["train/box_loss"], None)
        self.assertEqual(curve["rows"][1]["metrics/mAP50(B)"], None)

    def test_siamese_curve_reads_run_level_csv(self):
        self._write(
            "run/results.csv",
            "epoch,train_loss,val_loss,val_auc\n"
            "1,0.70,1.60,0.55\n2,0.40,0.80,0.91\n",
        )
        self._touch("run/best.pt")
        curve = training_curve(os.path.join(self._tmp, "run"))
        self.assertEqual(curve["kind"], "siamese")
        self.assertEqual(curve["rows"][-1]["val_auc"], 0.91)
        # 双塔 best.pt 在 run 根目录：进检查点清单，best 字段指向它
        self.assertEqual([c["name"] for c in curve["checkpoints"]], ["best.pt"])
        self.assertTrue(str(curve["best"]).endswith("best.pt"))
        self.assertIsNone(curve["last"])

    def test_missing_run_dir_raises(self):
        with self.assertRaises(ValueError):
            training_curve(os.path.join(self._tmp, "nope"))

    def test_list_checkpoints_ignores_stray_files(self):
        self._touch("w/best.pt")
        self._touch("w/last.pt")
        self._touch("w/epoch10.pt")
        self._touch("w/epoch2.pt")
        self._touch("w/notes.txt")
        self._touch("w/epochx.pt")
        found = list_checkpoints(os.path.join(self._tmp, "w"))
        self.assertEqual(
            [(c["name"], c["epoch"]) for c in found],
            [("epoch2.pt", 2), ("epoch10.pt", 10),
             ("best.pt", None), ("last.pt", None)],
        )


if __name__ == "__main__":
    unittest.main()