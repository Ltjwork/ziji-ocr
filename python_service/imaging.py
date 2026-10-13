# -*- coding: utf-8 -*-
"""OpenCV 图像文件 IO 的中文路径统一封装（全项目唯一实现）。

cv2.imread / cv2.imwrite 在 Windows 上遇到非 ASCII 路径分别返回 None 或
静默失败，统一走 np.fromfile/imdecode 与 imencode/tofile。本模块只收敛
「文件落盘」路径；内存内编码（缩略图 base64、data URL 等）不经此模块。
"""
from __future__ import annotations

import os

import cv2
import numpy as np


def imread_unicode(path: str):
    """等价 cv2.imread(path, IMREAD_COLOR)，中文路径安全。

    文件不存在/不可读时抛 OSError（与 segmenter 历史行为一致，调用方
    自行决定容错；需要「坏图返回 None」语义的见 training_service._imread）。
    """
    buf = np.fromfile(path, dtype=np.uint8)
    return cv2.imdecode(buf, cv2.IMREAD_COLOR)


def imwrite_unicode(path: str, image, ext: str | None = None,
                    params: list | None = None) -> bool:
    """等价 cv2.imwrite(path, image)，中文路径安全；成功返回 True。

    ext 缺省按 path 后缀推导（无后缀按 .png）；params 透传编码参数
    （如 JPEG 质量 [int(cv2.IMWRITE_JPEG_QUALITY), 95]）。
    编码失败或写盘 OSError 均返回 False。
    """
    suffix = ext or os.path.splitext(path)[1] or ".png"
    ok, buf = cv2.imencode(suffix, image,
                           params if params is not None else [])
    if not ok:
        return False
    try:
        buf.tofile(path)
        return os.path.getsize(path) > 0
    except OSError:
        return False
