# -*- coding: utf-8 -*-
"""zjpack 容器与内置 Ed25519 的单测：RFC 8032 向量、往返读写、篡改检测。"""
from __future__ import annotations

import os
import tempfile
import unittest

import ed25519
import zjpack

# RFC 8032 §7.1 TEST 1~3（空消息/单字节/双字节）。
_RFC_VECTORS = [
    (
        "9d61b19deffd5a60ba844af492ec2cc4"
        "4449c5697b326919703bac031cae7f60",
        "d75a980182b10ab7d54bfed3c964073a"
        "0ee172f3daa62325af021a68f707511a",
        "",
        "e5564300c360ac729086e2cc806e828a"
        "84877f1eb8e5d974d873e06522490155"
        "5fb8821590a33bacc61e39701cf9b46b"
        "d25bf5f0595bbe24655141438e7a100b",
    ),
    (
        "4ccd089b28ff96da9db6c346ec114e0f"
        "5b8a319f35aba624da8cf6ed4fb8a6fb",
        "3d4017c3e843895a92b70aa74d1b7ebc"
        "9c982ccf2ec4968cc0cd55f12af4660c",
        "72",
        "92a009a9f0d4cab8720e820b5f642540"
        "a2b27b5416503f8fb3762223ebdb69da"
        "085ac1e43e15996e458f3613d0f11d8c"
        "387b2eaeb4302aeeb00d291612bb0c00",
    ),
    (
        "c5aa8df43f9f837bedb7442f31dcb7b1"
        "66d38535076f094b85ce3a2e0b4458f7",
        "fc51cd8e6218a1a38da47ed00230f058"
        "0816ed13ba3303ac5deb911548908025",
        "af82",
        "6291d657deec24024827e69c3abe01a3"
        "0ce548a284743a445e3680d7db5ac3ac"
        "18ff9b538d16f290ae67f760984dc659"
        "4a7c15e9716ed28dc027beceea1ec40a",
    ),
]


class Ed25519VectorsTest(unittest.TestCase):
    def test_rfc8032(self):
        for seed_hex, pub_hex, msg_hex, sig_hex in _RFC_VECTORS:
            seed = bytes.fromhex(seed_hex)
            pub = bytes.fromhex(pub_hex)
            msg = bytes.fromhex(msg_hex)
            sig = bytes.fromhex(sig_hex)
            self.assertEqual(ed25519.publickey(seed), pub)
            self.assertEqual(ed25519.signature(msg, seed, pub), sig)
            self.assertTrue(ed25519.checkvalid(sig, msg, pub))
            self.assertFalse(ed25519.checkvalid(sig, msg + b"x", pub))

    def test_rejects_garbage(self):
        seed = os.urandom(32)
        pub = ed25519.publickey(seed)
        sig = ed25519.signature(b"m", seed, pub)
        wrong_pub = ed25519.publickey(os.urandom(32))
        self.assertFalse(ed25519.checkvalid(sig, b"m", wrong_pub))
        self.assertFalse(ed25519.checkvalid(sig[:-1] + b"\x00", b"m", pub))
        self.assertFalse(ed25519.checkvalid(b"\x00" * 64, b"m", pub))


class ZjpackRoundTripTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp()
        self.seed = os.urandom(32)
        self.pub = ed25519.publickey(self.seed)
        self.pack_path = os.path.join(self._tmp, "p.zjpack")

    def _entries(self):
        file_path = os.path.join(self._tmp, "char_det.pt")
        with open(file_path, "wb") as f:
            f.write(os.urandom(1024) + b"FILE-ENTRY")
        return [
            {"name": "char_det.pt", "kind": "yolo_char_det", "path": file_path,
             "src": "run_test"},
            {"name": "manifest.json", "kind": "manifest",
             "data": b'{"pack_version": "t"}'},
        ]

    def test_round_trip(self):
        manifest = zjpack.write_pack(self.pack_path, self._entries(), self.seed,
                                     pack_version="t1")
        self.assertTrue(os.path.exists(self.pack_path))
        self.assertEqual(manifest["size_bytes"], os.path.getsize(self.pack_path))
        pack = zjpack.open_pack(self.pack_path, self.pub)
        self.assertEqual(pack.index["pack_version"], "t1")
        entry = pack.entry_by_kind("yolo_char_det")
        self.assertIsNotNone(entry)
        self.assertEqual(entry["src"], "run_test")
        out_dir = os.path.join(self._tmp, "out")
        materialized = pack.materialize(entry, out_dir)
        with open(materialized, "rb") as f:
            self.assertEqual(f.read(),
                             open(os.path.join(self._tmp, "char_det.pt"), "rb").read())
        # 复用路径：已存在且大小一致时不重写
        again = pack.materialize(entry, out_dir)
        self.assertEqual(again, materialized)

    def test_tampered_payload_rejected(self):
        zjpack.write_pack(self.pack_path, self._entries(), self.seed)
        with open(self.pack_path, "r+b") as f:
            f.seek(os.path.getsize(self.pack_path) - 100)
            byte = f.read(1)
            f.seek(os.path.getsize(self.pack_path) - 100)
            f.write(bytes([byte[0] ^ 0xFF]))
        with self.assertRaises(zjpack.ZjpackError):
            zjpack.open_pack(self.pack_path, self.pub)

    def test_tampered_index_rejected(self):
        zjpack.write_pack(self.pack_path, self._entries(), self.seed)
        # 篡改索引区第一个字节（版本号后内容，仍保持长度不变）
        with open(self.pack_path, "r+b") as f:
            f.seek(zjpack.HEADER.size + 2)
            f.write(b"~")
        with self.assertRaises(zjpack.ZjpackError):
            zjpack.open_pack(self.pack_path, self.pub)

    def test_wrong_key_rejected(self):
        zjpack.write_pack(self.pack_path, self._entries(), self.seed)
        other = ed25519.publickey(os.urandom(32))
        with self.assertRaises(zjpack.ZjpackError):
            zjpack.open_pack(self.pack_path, other)

    def test_truncated_rejected(self):
        zjpack.write_pack(self.pack_path, self._entries(), self.seed)
        size = os.path.getsize(self.pack_path)
        with open(self.pack_path, "r+b") as f:
            f.truncate(size - 5)
        with self.assertRaises(zjpack.ZjpackError):
            zjpack.open_pack(self.pack_path, self.pub)


if __name__ == "__main__":
    unittest.main()
