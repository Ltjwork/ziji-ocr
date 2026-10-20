# -*- coding: utf-8 -*-
"""CASIA 手写数据解析：GNT（单字）与 DGRL（离线文本页）。

只读解析，数据内容不会被执行。格式核验依据 Gnt/001-f.gnt（4024 个样本，
逐个走完整个文件）与 HWDB2.0/001-P16.dgrl（解析后正好吃完整个文件，行图
目视正确）。

GNT 样本：4B 样本大小（小端，含 10B 头）+ 2B 编码 + 2B 宽 + 2B 高 + 灰度位图。
DGRL 文件：73B 文件头（头大小 / "DGR" 格式码 / 注释 / 编码名 / 编码类型 / 位深）
          + 4B 页 rows + 4B 页 cols + 4B 行数；每行 = 4B 字数 + 2B 编码×字数
          + 4B×4（row, col, h, w）+ 8 位灰度位图 h×w。
DGRL 的 row/col 为行顶、行左坐标（页面竖版：rows=3493 > cols=2482）。
"""
import os
import re
import struct
from dataclasses import dataclass

import numpy as np

_WRITER_RE = re.compile(r"^(\d+)-")
DGRL_HEADER_SIZE = 73
DGRL_LINE_TABLE_OFFSET = 85  # 文件头 73B + 页 rows/cols 8B + 行数 4B
# DGRL 中编码 0xFFFF 的字：页面上有字形，但标签缺失（如涂改、未收录），替换符占位
UNKNOWN_CHAR = chr(0xFFFD)


def writer_id(path: str) -> int:
    """文件名开头的作者编号：001-f.gnt / 0001-P11.dgrl。"""
    m = _WRITER_RE.match(os.path.basename(path))
    if not m:
        raise ValueError(f"无法从文件名取作者编号: {path}")
    return int(m.group(1))


def decode_code(unit: bytes) -> str:
    """两字节编码：单字节 ASCII 存为 [字符, 0]，其余为 GBK 双字节（高字节在前）。"""
    if unit == b"\x00\x00":
        raise ValueError("空编码")
    if unit[1] == 0:
        return chr(unit[0])
    return unit.decode("gbk")  # 非法 GBK 抛 UnicodeDecodeError（ValueError 子类）


def read_gnt(path: str):
    """逐个产出 (标签, 位图)；位图为 uint8 (h, w)，白底黑字。"""
    with open(path, "rb") as f:
        data = f.read()
    off = 0
    while off < len(data):
        if off + 10 > len(data):
            raise ValueError(f"GNT 尾部不完整: {path}")
        size, = struct.unpack_from("<I", data, off)
        w, h = struct.unpack_from("<HH", data, off + 6)
        if size != 10 + w * h or off + size > len(data):
            raise ValueError(f"GNT 样本长度不符 @{off}: {path}")
        label = decode_code(data[off + 4:off + 6])
        bmp = np.frombuffer(data, dtype=np.uint8, count=w * h, offset=off + 10)
        yield label, bmp.reshape(h, w).copy()
        off += size


@dataclass
class DgrlLine:
    text: str
    row: int  # 行顶（页面纵向），可为负：行图伸出页边
    col: int  # 行左（页面横向），可为负：行图伸出页边
    bitmap: np.ndarray  # uint8 (h, w)，白底黑字


@dataclass
class DgrlPage:
    rows: int  # 页高（纵向像素）
    cols: int  # 页宽（横向像素）
    lines: list


def read_dgrl(path: str) -> DgrlPage:
    """解析一个离线文本页；结构不符或末尾残留字节都会抛 ValueError。"""
    with open(path, "rb") as f:
        data = f.read()
    header_size, = struct.unpack_from("<I", data, 0)
    code_type, bpp = struct.unpack_from("<HH", data, 69)
    if header_size != DGRL_HEADER_SIZE or code_type != 2 or bpp != 8:
        raise ValueError(
            f"DGRL 文件头不符（头 {header_size}, 编码 {code_type}, 位深 {bpp}）: {path}"
        )
    rows, cols, n_lines = struct.unpack_from("<III", data, 73)
    off = DGRL_LINE_TABLE_OFFSET
    lines = []
    for _ in range(n_lines):
        n_chars, = struct.unpack_from("<I", data, off)
        off += 4
        text = "".join(
            UNKNOWN_CHAR if data[off + 2 * k:off + 2 * k + 2] == b"\xff\xff"
            else decode_code(data[off + 2 * k:off + 2 * k + 2])
            for k in range(n_chars)
        )
        off += 2 * n_chars
        row, col = struct.unpack_from("<ii", data, off)  # 有符号：实测有 -5 的列坐标
        h, w = struct.unpack_from("<II", data, off + 8)
        off += 16
        if h == 0 or w == 0 or off + h * w > len(data):
            raise ValueError(f"DGRL 行图长度不符 @{off}: {path}")
        bmp = np.frombuffer(data, dtype=np.uint8, count=h * w, offset=off)
        off += h * w
        lines.append(DgrlLine(text, row, col, bmp.reshape(h, w).copy()))
    if off != len(data):
        raise ValueError(f"DGRL 末尾残留 {len(data) - off} 字节: {path}")
    return DgrlPage(rows, cols, lines)
