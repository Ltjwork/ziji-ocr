# -*- coding: utf-8 -*-
"""墨迹比对模型训练设施（verify_training）与跨页模板库（verify_templates）
的单元测试：数据导出口径/易混挖掘门槛/模板读写与相似度，不依赖真实书库
（合成页面走 char_verify 的同一条管线）。"""

import json
import os
import tempfile
import unittest

import numpy as np
from PIL import Image

import char_verify as ver
import verify_templates as vt
import verify_training as vtr


def _page_with_chars(chars, page="guji_page_0.png"):
    """白底页横向排开楷体字（同一"墨迹"风格），返回 (页路径, {序号: 矩形})。"""
    canvas = np.full((600, 40 + 140 * len(chars)), 255, dtype=np.uint8)
    rects = {}
    for idx, ch in enumerate(chars):
        glyph = ver._render_glyph(ch)
        assert glyph is not None
        scale = min(110 / glyph.shape[0], 110 / glyph.shape[1], 1.0)
        glyph = np.asarray(
            Image.fromarray(glyph).resize(
                (max(1, int(glyph.shape[1] * scale)),
                 max(1, int(glyph.shape[0] * scale))),
                Image.Resampling.NEAREST))
        h, w = glyph.shape
        x0 = 20 + idx * 140 + (110 - w) // 2
        y0 = (600 - h) // 2
        patch = canvas[y0: y0 + h, x0: x0 + w]
        canvas[y0: y0 + h, x0: x0 + w] = np.where(glyph > 127, 0, patch)
        rects[idx] = (x0, y0, w, h)
    fd, path = tempfile.mkstemp(suffix=".png")
    Image.fromarray(canvas).save(path)
    os.close(fd)
    return path, rects


def _make_ann(page_id, image_path, chars, rects, confirmed=True):
    """最小页面标注 dict（verify_training 只读 page_id/image_path/lines）。"""
    return {
        "page_id": page_id,
        "image_path": image_path,
        "reviewed": confirmed,
        "lines": [{
            "id": "l0",
            "status": "confirmed" if confirmed else "proposed",
            "chars": [
                {"id": f"c{i}", "text": t, "status": "confirmed",
                 "type": "main_text", "x": rects[i][0], "y": rects[i][1],
                 "w": rects[i][2], "h": rects[i][3],
                 **({"candidates": [{"text": "曰", "score": 0.5}]}
                    if t == "日" else {})}
                for i, t in enumerate(chars)
            ],
        }],
    }


def _make_book(root: str, name: str, ann: dict) -> str:
    """临时书籍项目：project.json + 单页标注（verify_training 只读这两处）。"""
    book = os.path.join(root, name)
    os.makedirs(os.path.join(book, "annotations"))
    with open(os.path.join(book, "project.json"), "w", encoding="utf-8") as f:
        json.dump({"id": name, "settings": {}}, f, ensure_ascii=False)
    with open(os.path.join(book, "annotations", "page_000.json"), "w",
              encoding="utf-8") as f:
        json.dump(ann, f, ensure_ascii=False)
    return book



class ExportTests(unittest.TestCase):
    def test_export_and_manifest(self):
        path, rects = _page_with_chars(["天", "日", "昌"])
        try:
            with tempfile.TemporaryDirectory() as tmp:
                # 借用内部件验证口径：confuse 挖掘只保留相似度达标的字
                confuse = vtr._confusable_map(
                    ["天", "日", "昌", "人"],
                    os.path.join(tmp, "_confuse.json"))
                self.assertIsInstance(confuse, dict)
                # 每字至多 CONFUSE_K 个易混字，且不含自身
                for k, v in confuse.items():
                    self.assertLessEqual(len(v), vtr.CONFUSE_K)
                    self.assertNotIn(k, v)
        finally:
            os.unlink(path)

    def test_iter_confirmed_chars(self):
        path, rects = _page_with_chars(["天", "日"])
        try:
            anns = [_make_ann("page_000", path, ["天", "日"], rects)]
            rows = list(vtr._iter_confirmed_chars(anns))
            texts = [t for _pid, _i, _r, t, _j in rows]
            self.assertEqual(texts, ["天", "日"])
            # 日 的候选首选是 曰 → 被否决首选（硬负样本）
            rejected = {t: j for _pid, _i, _r, t, j in rows}
            self.assertEqual(rejected["日"], "曰")
            self.assertIsNone(rejected["天"])
        finally:
            os.unlink(path)


class ExportMergeTests(unittest.TestCase):
    """verify_pair 数据集全局共享：分书导出互不覆盖，manifest 按书合并。"""

    def test_two_books_merge_and_regenerate_one(self):
        import train_data
        import train_datasets

        path_a, rects_a = _page_with_chars(["天", "日"])
        path_b, rects_b = _page_with_chars(["昌", "明"])
        old_root = train_data.DATASETS_ROOT
        train_data.DATASETS_ROOT = os.path.join(tempfile.mkdtemp(), "datasets")
        train_datasets._MIGRATED = False
        try:
            with tempfile.TemporaryDirectory() as lib:
                book_a = _make_book(lib, "bookA", _make_ann(
                    "page_000", path_a, ["天", "日"], rects_a))
                book_b = _make_book(lib, "bookB", _make_ann(
                    "page_000", path_b, ["昌", "明"], rects_b))
                vtr.export_dataset(book_a, force=True)
                out = vtr.dataset_dir(book_a)
                manifest_path = os.path.join(out, "manifest.json")
                with open(manifest_path, encoding="utf-8") as f:
                    pairs = json.load(f)["pairs"]
                self.assertTrue(pairs)
                self.assertTrue(all(p["name"].startswith("bookA_") for p in pairs))

                vtr.export_dataset(book_b, force=True)
                with open(manifest_path, encoding="utf-8") as f:
                    manifest = json.load(f)
                names = [p["name"] for p in manifest["pairs"]]
                self.assertTrue(any(n.startswith("bookA_") for n in names))
                self.assertTrue(any(n.startswith("bookB_") for n in names))
                # train/val 都非空（siamese 训练的硬要求）
                self.assertGreater(manifest["stats"]["train_pairs"], 0)
                self.assertGreater(manifest["stats"]["val_pairs"], 0)
                # 图对文件真实存在
                for p in manifest["pairs"][:4]:
                    self.assertTrue(os.path.exists(os.path.join(out, p["ink"])))
                    self.assertTrue(os.path.exists(os.path.join(out, p["glyph"])))

                # 重新导出 bookA 不动 bookB 的样本
                vtr.export_dataset(book_a, force=True)
                with open(manifest_path, encoding="utf-8") as f:
                    names = [p["name"] for p in json.load(f)["pairs"]]
                self.assertTrue(any(n.startswith("bookB_") for n in names))
        finally:
            train_data.DATASETS_ROOT = old_root
            train_datasets._MIGRATED = False
            os.unlink(path_a)
            os.unlink(path_b)



class TemplateTests(unittest.TestCase):
    def test_update_load_similarity_chamfer(self):
        path, rects = _page_with_chars(["天", "日"])
        try:
            blocks = []
            for i, ch in enumerate(["天", "日"]):
                b = type("B", (), {})()
                b.text, b.status = ch, "confirmed"
                b.x, b.y, b.w, b.h = rects[i]
                blocks.append(b)
            with tempfile.TemporaryDirectory() as tmp:
                mask = ver._text_mask_for_refinement(path)
                entries = []
                for i, ch in enumerate(["天", "日"]):
                    ink = ver._crop_ink(mask, rects[i])[0]
                    entries.append((ch, ver._prepare(ink)))
                out = vt.update(os.path.join(tmp, "bookA"), entries)
                self.assertEqual(out["added"], 2)
                lib = vt.load(os.path.join(tmp, "bookA"))
                self.assertIn("天", lib)
                self.assertIn("日", lib)
                # 同字模板自比对：相似度接近 1
                glyph = ver._glyph_features("天")
                ink = ver._prepare(
                    ver._crop_ink(ver._text_mask_for_refinement(path),
                                  rects[0])[0], target_w=glyph[4])
                skel = ver._skeleton(ink)
                best, count = vt.best_similarity("天", ink, skel, lib)
                self.assertEqual(count, 1)
                self.assertGreater(best, 0.9)
                # 异字模板不存在 → None
                self.assertIsNone(vt.best_similarity(
                    "地", ink, skel, lib))
                # 清空
                self.assertEqual(
                    vt.clear(os.path.join(tmp, "bookA"))["cleared"], True)
                self.assertEqual(vt.load(os.path.join(tmp, "bookA")), {})
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
