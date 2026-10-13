# -*- coding: utf-8 -*-
"""api_pack 打包端点单测：伪造 service 目录（激活副本 + 注册表 + kraken
模型 + 基线），走 pack_release 全链路，再用 zjpack 验签读回对账。

隔离方式：pack_release 的 service_dir/registry_path/key_path/out_path
全部是显式参数，直接注入 tempdir，无需置换模块全局。
"""
from __future__ import annotations

import json
import os
import tempfile
import unittest

import api_pack
import ed25519
import zjpack


def _mk(path: str, data: bytes) -> str:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    return path


class PackReleaseTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp()
        self.service_dir = os.path.join(self._tmp, "service")
        self.key_path = os.path.join(self._tmp, "key")
        self.seed = os.urandom(32)
        with open(self.key_path, "wb") as f:
            f.write(self.seed)
        self.out_path = os.path.join(self._tmp, "models_release.zjpack")

        models = os.path.join(self.service_dir, "models")
        self.char_det_bytes = os.urandom(512) + b"ACTIVE_CHAR_DET"
        run_best = _mk(os.path.join(models, "trained", "char_det",
                                     "run_20260930_120000", "best.pt"),
                       self.char_det_bytes)
        self.char_cls_bytes = b"BASELINE_CHAR_CLS"
        _mk(os.path.join(self.service_dir, "yolov8n-cls.pt"), self.char_cls_bytes)
        self.vp_bytes = os.urandom(256) + b"VERIFY_PAIR"
        active_vp = _mk(os.path.join(models, "active_verify_pair.pt"),
                        self.vp_bytes)
        self.kraken_bytes = os.urandom(1024) + b"CHAT_REC"
        _mk(os.path.join(self.service_dir, "kraken_models", "chat_rec.mlmodel"),
            self.kraken_bytes)
        # 官方底座备份与当前一致 → 未微调
        _mk(os.path.join(self.service_dir, "kraken_models",
                         "chat_rec_base_backup.mlmodel"), self.kraken_bytes)
        registry = {
            "layers": {
                "char_det": {
                    "active": os.path.join(models, "active_char_det.pt"),
                    "active_source": run_best,
                    "active_metrics": {"mAP50": 0.91},
                },
                "verify_pair": {"active": active_vp},
            }
        }
        # 激活稳定副本也要在盘上（真实 activate 会复制）
        _mk(os.path.join(models, "active_char_det.pt"), self.char_det_bytes)
        self.registry_path = os.path.join(self.service_dir, "models",
                                          "registry.json")
        with open(self.registry_path, "w", encoding="utf-8") as f:
            json.dump(registry, f, ensure_ascii=False)

    def test_pack_and_read_back(self):
        r = api_pack.pack_release(
            "t9", service_dir=self.service_dir,
            registry_path=self.registry_path, key_path=self.key_path,
            out_path=self.out_path)
        self.assertTrue(os.path.exists(self.out_path))
        self.assertEqual(r["pack_version"], "t9")
        kinds = {e["kind"] for e in r["entries"]}
        self.assertIn("yolo_char_det", kinds)
        self.assertIn("yolo_char_cls", kinds)       # 无激活 → 基线
        self.assertIn("yolo_verify_pair", kinds)
        self.assertIn("kraken_rec", kinds)
        self.assertIn("kraken_rec_base_backup", kinds)
        self.assertIn("manifest", kinds)
        # line_det 等层既无激活也无基线文件 → 不进包
        self.assertNotIn("yolo_line_det", kinds)

        pack = zjpack.open_pack(self.out_path, ed25519.publickey(self.seed))
        out_dir = os.path.join(self._tmp, "out")

        def _materialize(kind: str) -> bytes:
            entry = pack.entry_by_kind(kind)
            self.assertIsNotNone(entry)
            with open(pack.materialize(entry, out_dir), "rb") as f:
                return f.read()

        self.assertEqual(_materialize("yolo_char_det"), self.char_det_bytes)
        self.assertEqual(_materialize("yolo_char_cls"), self.char_cls_bytes)
        self.assertEqual(_materialize("yolo_verify_pair"), self.vp_bytes)
        self.assertEqual(_materialize("kraken_rec"), self.kraken_bytes)
        manifest = json.loads(_materialize("manifest").decode("utf-8"))
        self.assertEqual(manifest["pack_version"], "t9")
        layers = manifest["layers"]
        self.assertEqual(layers["yolo_char_det"]["source"], "activated")
        self.assertEqual(layers["yolo_char_det"]["run"], "run_20260930_120000")
        self.assertEqual(layers["yolo_char_cls"]["source"], "baseline")
        self.assertEqual(layers["kraken_rec"]["source"], "CHAT_base")
        self.assertEqual(layers["yolo_verify_pair"]["source"], "activated")

    def test_default_version_is_date(self):
        import time

        r = api_pack.pack_release(
            "", service_dir=self.service_dir,
            registry_path=self.registry_path, key_path=self.key_path,
            out_path=self.out_path)
        self.assertEqual(r["pack_version"], time.strftime("%Y%m%d"))

    def test_missing_key_raises(self):
        with self.assertRaises(RuntimeError):
            api_pack.pack_release(
                "t", service_dir=self.service_dir,
                registry_path=self.registry_path,
                key_path=os.path.join(self._tmp, "nope"),
                out_path=self.out_path)

    def test_nothing_to_pack_raises(self):
        empty_dir = os.path.join(self._tmp, "empty")
        os.makedirs(empty_dir, exist_ok=True)
        with self.assertRaises(RuntimeError):
            api_pack.pack_release(
                "t", service_dir=empty_dir,
                registry_path=os.path.join(empty_dir, "none.json"),
                key_path=self.key_path, out_path=self.out_path)


if __name__ == "__main__":
    unittest.main()
