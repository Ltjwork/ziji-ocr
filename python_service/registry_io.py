# -*- coding: utf-8 -*-
"""models/registry.json 的统一读写（收敛三处历史实现）。

此前 training_service / verify_training / char_verify 各有一份读写代码且
已漂移（verify_training 版缺目录兜底，char_verify 内联只读，原子写只有
verify_templates 做过）。本模块是唯一实现：JSON 结构一字不动，写入统一
走原子写（临时文件 + os.replace，防止写一半崩溃留下坏注册表）。
"""
from __future__ import annotations

import json
import os
import tempfile

SERVICE_DIR = os.path.dirname(os.path.abspath(__file__))
REGISTRY_PATH = os.path.join(SERVICE_DIR, "models", "registry.json")


def load_registry(path: str = REGISTRY_PATH) -> dict:
    """读注册表；文件缺失或损坏返回 {"layers": {}}。"""
    if not os.path.exists(path):
        reg = {}
    else:
        try:
            with open(path, encoding="utf-8") as f:
                reg = json.load(f)
        except Exception:
            reg = {}
    reg.setdefault("layers", {})
    return reg


def save_registry(reg: dict, path: str = REGISTRY_PATH) -> None:
    """原子写注册表（临时文件 + os.replace）。"""
    root = os.path.dirname(path)
    os.makedirs(root, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=root, suffix=".json.tmp")
    os.close(fd)
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(reg, f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
