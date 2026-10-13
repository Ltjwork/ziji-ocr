"""Canonical locations and names for OCR YOLO models."""
from __future__ import annotations

import os

from registry_io import SERVICE_DIR
MODEL_ROOT = os.path.join(SERVICE_DIR, "models")


def baseline_candidates(layer: str, service_dir: str = SERVICE_DIR) -> tuple:
    """某层散文件基线的候选路径（按优先级）。service_dir 参数化供打包/测试
    注入；解析优先级本身见 resolve_model_path。"""
    model_root = os.path.join(service_dir, "models")
    if layer == "char_det":
        return (os.path.join(model_root, "yolo_char.pt"),
                os.path.join(service_dir, "yolo_char.pt"))
    if layer == "char_cls":
        return (os.path.join(model_root, "yolov8n-cls.pt"),
                os.path.join(service_dir, "yolov8n-cls.pt"))
    return (os.path.join(model_root, f"{layer}.pt"),)


# The detector is intentionally separate from the classification checkpoint.
# Keep the legacy filename as the first candidate for existing installations,
# while allowing a registry/environment override without code changes.
DEFAULT_MODEL_FILES = {layer: baseline_candidates(layer)
                       for layer in ("char_det", "char_cls")}


def _pack_fallback(kind: str) -> str | None:
    """发行包兜底：散文件缺失（用户机安装形态）时取 .zjpack 物化路径。
    任何异常按无 pack 处理——识别链路绝不被加载器问题打断。"""
    try:
        import model_store

        return model_store.resolve(kind)
    except Exception:
        return None


def resolve_model_path(layer: str = "char_det") -> str:
    override = os.environ.get(f"OCR_YOLO_{layer.upper()}_MODEL", "").strip()
    if layer == "char_det":
        override = os.environ.get("OCR_YOLO_CHAR_MODEL", override).strip()
    if override:
        return os.path.abspath(override)
    candidates = DEFAULT_MODEL_FILES.get(layer) or baseline_candidates(layer)
    for path in candidates:
        if os.path.exists(path):
            return path
    packed = _pack_fallback(f"yolo_{layer}")
    if packed:
        return packed
    return candidates[0] if candidates else os.path.join(MODEL_ROOT, f"{layer}.pt")
