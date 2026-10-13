# -*- coding: utf-8 -*-
"""字迹模型发行包 .zjpack 的容器读写（格式基准以本模块为准）。

格式布局：
  [12B 文件头]  b"ZJPACK" + u8 版本(1) + u8 标志(0，预留加密位) + u32LE 索引字节数
  [索引]        UTF-8 JSON：{"pack_version": str, "created_at": float,
                "entries": [{"name","kind","sha256","offset","length","src"?}]}
                offset 相对载荷区起点；src 是人读的来源说明（训练 run 名等）
  [载荷]        各条目原始字节，不压缩——神经网络权重高熵，压缩收益趋近于
                零还牺牲 mmap/流式的简单性
  [64B 签名]    Ed25519，对 sha256(文件头+索引+载荷) 签名；私钥只在管理员机
                release_keys/ 下，公钥内嵌于 model_store.PUBLIC_KEY

逐条目 sha256 在物化时校验（索引被签名覆盖，条目哈希因此同样受签名保护）。
写走临时文件 + os.replace 原子替换（与 registry_io.save_registry 同纪律）。
"""
from __future__ import annotations

import hashlib
import json
import os
import struct
import tempfile
import time
from pathlib import Path

import ed25519

MAGIC = b"ZJPACK"
VERSION = 1
FLAGS = 0
HEADER = struct.Struct("<6sBBI")
SIG_LEN = 64
_CHUNK = 1024 * 1024


class ZjpackError(Exception):
    """包损坏/验签失败/格式不符。加载侧捕获后按"无 pack"降级，不外抛。"""


def _sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_pack(out_path: str, entries: list[dict], seed: bytes,
               *, pack_version: str = "", progress=None) -> dict:
    """把条目写成签名包。entries 每项含 name/kind 与 path（磁盘文件）或
    data（内存字节），可选 src。返回 manifest：含各条目哈希/长度与整包
    sha256/大小。progress(name, kind, mb) 在每个条目写入时回调一次。"""
    # 索引在文件布局上先于载荷，而条目 sha256 要进索引——先对全部条目
    # 定稿哈希与长度，再序列化索引（此后索引不再变动，签名覆盖它才有意义）。
    index_entries: list[dict] = []
    offset = 0
    for e in entries:
        data = e.get("data")
        if data is not None:
            length, sha = len(data), hashlib.sha256(data).hexdigest()
        else:
            length, sha = os.path.getsize(e["path"]), _sha256_file(e["path"])
        item = {
            "name": e["name"],
            "kind": e["kind"],
            "sha256": sha,
            "offset": offset,
            "length": length,
        }
        if e.get("src"):
            item["src"] = e["src"]
        index_entries.append(item)
        offset += length
    index = {
        "pack_version": pack_version,
        "created_at": time.time(),
        "entries": index_entries,
    }
    index_bytes = json.dumps(index, ensure_ascii=False, indent=2).encode("utf-8")
    head = HEADER.pack(MAGIC, VERSION, FLAGS, len(index_bytes))

    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(out.parent), suffix=".zjpack.tmp")
    os.close(fd)
    try:
        digest = hashlib.sha256()
        with open(tmp, "wb") as f:
            f.write(head)
            f.write(index_bytes)
            digest.update(head)
            digest.update(index_bytes)
            for e, item in zip(entries, index_entries):
                if e.get("data") is not None:
                    f.write(e["data"])
                    digest.update(e["data"])
                else:
                    with open(e["path"], "rb") as src:
                        while True:
                            chunk = src.read(_CHUNK)
                            if not chunk:
                                break
                            f.write(chunk)
                            digest.update(chunk)
                if progress:
                    progress(e["name"], e["kind"], item["length"] / 1e6)
        # 签名覆盖的是内容摘要而非内容本身：签名消息恒为 32 字节，
        # 纯 Python Ed25519 的消息哈希成本与大文件解耦。
        sig = ed25519.signature(digest.digest(), seed, ed25519.publickey(seed))
        with open(tmp, "ab") as f:
            f.write(sig)
        os.replace(tmp, out)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    return {
        "path": str(out),
        "pack_version": pack_version,
        "sha256": _sha256_file(str(out)),
        "size_bytes": os.path.getsize(out),
        "created_at": index["created_at"],
        "entries": [dict(item) for item in index_entries],
    }


class PackFile:
    """已验签的打开句柄：按 kind 查条目、按需物化到磁盘。"""

    def __init__(self, path: str, index: dict, payload_start: int):
        self.path = path
        self.index = index
        self.payload_start = payload_start
        digest = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(_CHUNK), b""):
                digest.update(chunk)
        # sha256 整包（含签名区）——作为物化缓存目录名的一部分，
        # 换包后目录名变化，旧缓存天然失效。
        self.sha_hex = digest.hexdigest()

    @property
    def sha8(self) -> str:
        return self.sha_hex[:8]

    def entry_by_kind(self, kind: str) -> dict | None:
        for item in self.index.get("entries", []):
            if item.get("kind") == kind:
                return item
        return None

    def materialize(self, entry: dict, dest_dir: str) -> str:
        """把条目解出到 dest_dir/<name>（已存在且大小一致则直接复用），
        流式拷贝中顺带校验条目 sha256，不符视为磁盘损坏抛 ZjpackError。"""
        dest = os.path.join(dest_dir, entry["name"])
        length = entry["length"]
        if os.path.exists(dest) and os.path.getsize(dest) == length:
            return dest
        os.makedirs(dest_dir, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=dest_dir, suffix=".part")
        os.close(fd)
        digest = hashlib.sha256()
        try:
            with open(self.path, "rb") as src, open(tmp, "wb") as out:
                src.seek(self.payload_start + entry["offset"])
                left = length
                while left > 0:
                    chunk = src.read(min(_CHUNK, left))
                    if not chunk:
                        raise ZjpackError(
                            f"条目 {entry['name']} 读到包尾仍不足 {length} 字节")
                    out.write(chunk)
                    digest.update(chunk)
                    left -= len(chunk)
            if digest.hexdigest() != entry["sha256"]:
                raise ZjpackError(f"条目 {entry['name']} sha256 不符（包损坏？）")
            os.replace(tmp, dest)
        except BaseException:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise
        return dest


def open_pack(path: str, public_key: bytes) -> PackFile:
    """打开并验签；任何不符抛 ZjpackError（含原因），调用方降级处理。"""
    size = os.path.getsize(path)
    if size < HEADER.size + SIG_LEN:
        raise ZjpackError("文件太小，不是有效的 .zjpack")
    with open(path, "rb") as f:
        head = f.read(HEADER.size)
        magic, version, flags, index_len = HEADER.unpack(head)
        if magic != MAGIC:
            raise ZjpackError("magic 不符")
        if version != VERSION:
            raise ZjpackError(f"不支持的版本 {version}")
        if flags != FLAGS:
            raise ZjpackError(f"不支持的标志位 {flags}")
        if HEADER.size + index_len + SIG_LEN > size:
            raise ZjpackError("索引长度越界")
        index_bytes = f.read(index_len)
        payload_end = size - SIG_LEN
        digest = hashlib.sha256()
        digest.update(head)
        digest.update(index_bytes)
        left = payload_end - f.tell()
        while left > 0:
            chunk = f.read(min(_CHUNK, left))
            if not chunk:
                raise ZjpackError("读载荷时提前到包尾")
            digest.update(chunk)
            left -= len(chunk)
        sig = f.read(SIG_LEN)
    try:
        index = json.loads(index_bytes.decode("utf-8"))
    except Exception as exc:
        raise ZjpackError(f"索引 JSON 解析失败: {exc}") from exc
    if not isinstance(index.get("entries"), list):
        raise ZjpackError("索引缺少 entries")
    payload_len = payload_end - HEADER.size - index_len
    for item in index["entries"]:
        if (item.get("offset", -1) < 0 or item.get("length", -1) < 0
                or item["offset"] + item["length"] > payload_len):
            raise ZjpackError(f"条目 {item.get('name')} 越界")
    if not ed25519.checkvalid(sig, digest.digest(), public_key):
        raise ZjpackError("Ed25519 签名校验失败（包被篡改或公钥不匹配）")
    return PackFile(path, index, HEADER.size + index_len)
