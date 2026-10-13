# -*- coding: utf-8 -*-
"""Ed25519 纯 Python 实现（.zjpack 模型包签名/验签用，零第三方依赖）。

改编自 Ed25519 参考实现（D. J. Bernstein / Tanja Lange 等发布于公有领域，
https://ed25519.cr.yp.to/software.html），由 Python 2 移植到 Python 3：
little-endian bytes 编解码、标量乘由递归改为迭代。运行环境是 conda
Python 3.10 且不引入 cryptography 依赖，故内置此实现。RFC 8032 测试
向量见 test_zjpack.py。单次签名/验签数百毫秒，只在打开发行包时调用
一次（识别服务启动本就要几十秒，可忽略）。
"""
from __future__ import annotations

import hashlib

q = 2**255 - 19
l = 2**252 + 27742317777372353535851937790883648493


def _inv(x: int) -> int:
    return pow(x, q - 2, q)


d = -121665 * _inv(121666) % q
_I = pow(2, (q - 1) // 4, q)


def _xrecover(y: int) -> int:
    xx = (y * y - 1) * _inv(d * y * y + 1)
    x = pow(xx, (q + 3) // 8, q)
    if (x * x - xx) % q != 0:
        x = x * _I % q
    if x % 2 != 0:
        x = q - x
    return x


_By = 4 * _inv(5)
_Bx = _xrecover(_By)
_B = (_Bx % q, _By % q)


def _edwards_add(P, Q):
    x1, y1 = P
    x2, y2 = Q
    x3 = (x1 * y2 + x2 * y1) * _inv(1 + d * x1 * x2 * y1 * y2)
    y3 = (y1 * y2 + x1 * x2) * _inv(1 - d * x1 * x2 * y1 * y2)
    return (x3 % q, y3 % q)


def _scalarmult(P, e: int):
    if e == 0:
        return (0, 1)
    Q = (0, 1)
    for bit in bin(e)[2:]:
        Q = _edwards_add(Q, Q)
        if bit == "1":
            Q = _edwards_add(Q, P)
    return Q


def _encode_point(P) -> bytes:
    x, y = P
    out = bytearray(y.to_bytes(32, "little"))
    out[31] |= (x & 1) << 7
    return bytes(out)


def _is_on_curve(P) -> bool:
    x, y = P
    return (-x * x + y * y - 1 - d * x * x * y * y) % q == 0


def _point_decode(s: bytes):
    if len(s) != 32:
        raise ValueError("bad point length")
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    if y >= q:
        raise ValueError("y out of range")
    x = _xrecover(y)
    if x & 1 != sign:
        x = q - x
    P = (x, y)
    if not _is_on_curve(P):
        raise ValueError("point not on curve")
    return P


def _secret_expansion(seed: bytes):
    h = hashlib.sha512(seed).digest()
    a_int = int.from_bytes(h[:32], "little")
    # clamp：bit254 置 1、低 3 位与 bit255 清零（bits 3..253 取自哈希）
    a = 2**254 | (((a_int >> 3) & ((1 << 251) - 1)) << 3)
    return a, h[32:]


def _hint(m: bytes) -> int:
    return int.from_bytes(hashlib.sha512(m).digest(), "little")


def publickey(seed: bytes) -> bytes:
    """32 字节私钥种子 → 32 字节公钥。"""
    if len(seed) != 32:
        raise ValueError("seed must be 32 bytes")
    a, _ = _secret_expansion(seed)
    return _encode_point(_scalarmult(_B, a))


def signature(m: bytes, seed: bytes, public: bytes) -> bytes:
    """消息签名（64 字节）。public 可由 publickey(seed) 得到。"""
    if len(seed) != 32:
        raise ValueError("seed must be 32 bytes")
    a, prefix = _secret_expansion(seed)
    A = _point_decode(public)
    r = _hint(prefix + m) % l
    R = _encode_point(_scalarmult(_B, r))
    S = (r + _hint(R + public + m) * a) % l
    return R + S.to_bytes(32, "little")


def checkvalid(s: bytes, m: bytes, public: bytes) -> bool:
    """验签：格式错/点非法/S 超界/等式不成立均返回 False，不抛异常。"""
    if len(s) != 64 or len(public) != 32:
        return False
    try:
        A = _point_decode(public)
        R = _point_decode(s[:32])
    except ValueError:
        return False
    S = int.from_bytes(s[32:], "little")
    if S >= l:
        return False
    h = _hint(s[:32] + public + m) % l
    left = _scalarmult(_B, S)
    right = _edwards_add(R, _scalarmult(A, h))
    return left == right
