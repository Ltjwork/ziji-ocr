# -*- coding: utf-8 -*-
"""model_store 加载器单测：验签加载、物化缓存、无包/坏包降级不抛异常。

隔离方式沿用 test_model_registry 的模块属性置换：测试期换掉
model_store.PUBLIC_KEY 与 OCR_ZJPACK 环境变量，包与缓存全部落在
tempdir（缓存目录取自包文件所在目录，天然随包隔离）。
"""
from __future__ import annotations

import os
import tempfile
import unittest

import ed25519
import model_store
import zjpack


class ModelStoreTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp()
        self._old_pub = model_store.PUBLIC_KEY
        self._old_env = os.environ.get("OCR_ZJPACK")
        self.seed = os.urandom(32)
        model_store.PUBLIC_KEY = ed25519.publickey(self.seed)
        self.pack_path = os.path.join(self._tmp, "models_release.zjpack")
        os.environ["OCR_ZJPACK"] = self.pack_path
        self._reset()

    def tearDown(self):
        model_store.PUBLIC_KEY = self._old_pub
        if self._old_env is None:
            os.environ.pop("OCR_ZJPACK", None)
        else:
            os.environ["OCR_ZJPACK"] = self._old_env
        self._reset()

    @staticmethod
    def _reset():
        model_store._pack = None
        model_store._pack_state = None
        model_store._broken_state = None

    def _write_pack(self, extra: list | None = None):
        import secrets

        payload = secrets.token_bytes(2048)
        file_path = os.path.join(self._tmp, "src.bin")
        with open(file_path, "wb") as f:
            f.write(payload)
        entries = [
            {"name": "char_det.pt", "kind": "yolo_char_det", "path": file_path},
            {"name": "chat_rec.mlmodel", "kind": "kraken_rec", "data": b"KRAKEN"},
        ] + (extra or [])
        return zjpack.write_pack(self.pack_path, entries, self.seed,
                                 pack_version="test"), payload

    def test_resolve_materializes(self):
        _, payload = self._write_pack()
        path = model_store.resolve("yolo_char_det")
        self.assertIsNotNone(path)
        with open(path, "rb") as f:
            self.assertEqual(f.read(), payload)
        # 缓存命中：第二次 resolve 返回同一路径
        self.assertEqual(model_store.resolve("yolo_char_det"), path)

    def test_unknown_kind_returns_none(self):
        self._write_pack()
        self.assertIsNone(model_store.resolve("yolo_nothing"))

    def test_missing_pack_returns_none(self):
        self.assertIsNone(model_store.resolve("yolo_char_det"))

    def test_broken_pack_degrades_silently(self):
        _, _ = self._write_pack()
        size = os.path.getsize(self.pack_path)
        with open(self.pack_path, "r+b") as f:
            f.seek(size - 70)   # 载荷尾部
            b = f.read(1)
            f.seek(size - 70)
            f.write(bytes([b[0] ^ 0xFF]))
        self.assertIsNone(model_store.resolve("yolo_char_det"))

    def test_wrong_public_key_degrades_silently(self):
        _, _ = self._write_pack()
        model_store.PUBLIC_KEY = ed25519.publickey(os.urandom(32))
        self.assertIsNone(model_store.resolve("yolo_char_det"))

    def test_repack_picks_new_content(self):
        """换包（同路径重写）后指纹变化，加载器自动重开并物化新内容。"""
        _, payload1 = self._write_pack()
        first = model_store.resolve("yolo_char_det")
        with open(first, "rb") as f:
            self.assertEqual(f.read(), payload1)
        _, payload2 = self._write_pack()   # 内容不同的新包
        second = model_store.resolve("yolo_char_det")
        self.assertNotEqual(first, second)   # sha8 目录不同，天然分目录
        with open(second, "rb") as f:
            self.assertEqual(f.read(), payload2)


if __name__ == "__main__":
    unittest.main()
