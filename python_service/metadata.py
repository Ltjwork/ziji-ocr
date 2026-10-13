"""Shared metadata and identity helpers for OCR annotations.

The Flutter editor keeps the original ``id`` for backwards compatibility.  The
UID generated here is immutable for a given source image, geometry and reading
position, so a later OCR pass can be stored as a new revision without making
old crowd tasks point at a different glyph.
"""
from __future__ import annotations

import hashlib
import json
import os
from typing import Any, Iterable

SCHEMA_VERSION = 2
ANNOTATION_STATUSES = ("proposed", "confirmed", "rejected", "needs_review")


def normalize_status(value: Any = None, *, confirmed: bool = False) -> str:
    """Normalize current and legacy status values to the four-state contract."""
    if confirmed:
        return "confirmed"
    value = str(value or "").strip().lower()
    if value in ANNOTATION_STATUSES:
        return value
    # Status names used by pre-v2 Flutter builds.
    if value in ("reviewed", "accepted", "approved"):
        return "confirmed"
    if value in ("candidate", "unverified", "auto", "automatic", ""):
        return "proposed"
    if value in ("invalid", "ignored", "ignore"):
        return "rejected"
    return "needs_review"


def file_sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_uid(
    image_sha256: str,
    kind: str,
    rect: Iterable[int | float],
    *,
    order: int = 0,
    parent_uid: str = "",
) -> str:
    """Return a deterministic, compact UID for a page annotation entity.

    注意：识字数据包/众包链路的 char_uid 由 Flutter 端
    crowd_dataset_exporter.dart 生成，格式与本函数不同（那边是无 kind
    前缀的 24 位十六进制）；本函数的 uid 只用于识别结果与标注身份，
    两套不互换（见 ocr/README.md「标注与训练规则」）。
    """
    values = [int(round(float(v))) for v in rect]
    payload = {
        "image": image_sha256,
        "kind": kind,
        "rect": values,
        "order": int(order),
        "parent": parent_uid,
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return f"{kind}_{hashlib.sha256(encoded).hexdigest()[:24]}"


def revision_for(*, image_sha256: str, settings: dict[str, Any], model_version: str) -> str:
    payload = {"image": image_sha256, "settings": settings, "model": model_version}
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()[:16]


def enrich_result(
    result: dict[str, Any],
    image_path: str,
    *,
    orientation: str,
    horizontal_dir: str,
    vertical_dir: str,
    model_version: str,
    layout_mode: str = "all_text",
) -> dict[str, Any]:
    """Attach version, source hash, status and stable UIDs to a segment result."""
    try:
        source_sha = file_sha256(image_path)
    except OSError:
        source_sha = ""
    settings = {
        "orientation": orientation,
        "horizontal_dir": horizontal_dir,
        "vertical_dir": vertical_dir,
        "layout_mode": layout_mode,
    }
    revision = revision_for(image_sha256=source_sha, settings=settings, model_version=model_version)
    result["schema_version"] = SCHEMA_VERSION
    result["source_sha256"] = source_sha
    result["ocr_revision"] = revision
    result["model_version"] = model_version
    result["settings"] = settings

    regions = result.get("main_regions") or []
    for index, region in enumerate(regions):
        # 与段落/行同一四态合同：旧导出的非四态 status 原样透传会破坏下游
        # 过滤/确认链路（此前只 setdefault，模型附加与人工标注混着来）。
        region["status"] = normalize_status(
            region.get("status"), confirmed=bool(region.get("confirmed")))
        region.setdefault("uid", stable_uid(source_sha, "region", (region.get("x", 0), region.get("y", 0), region.get("w", 0), region.get("h", 0)), order=index))

    paragraphs = result.get("paragraphs") or []
    for index, paragraph in enumerate(paragraphs):
        paragraph["status"] = normalize_status(paragraph.get("status"), confirmed=bool(paragraph.get("confirmed")))
        paragraph.setdefault("uid", stable_uid(source_sha, "paragraph", (paragraph.get("x", 0), paragraph.get("y", 0), paragraph.get("w", 0), paragraph.get("h", 0)), order=index))

    lines = result.get("lines") or []
    for line_index, line in enumerate(lines):
        line["status"] = normalize_status(line.get("status"), confirmed=bool(line.get("confirmed")))
        line_uid = line.setdefault("uid", stable_uid(source_sha, "line", (line.get("x", 0), line.get("y", 0), line.get("w", 0), line.get("h", 0)), order=line_index))
        for char_index, char in enumerate(line.get("chars") or []):
            char["status"] = normalize_status(char.get("status"), confirmed=bool(char.get("confirmed")))
            char.setdefault("uid", stable_uid(source_sha, "char", (char.get("x", 0), char.get("y", 0), char.get("w", 0), char.get("h", 0)), order=char_index, parent_uid=line_uid))
            char.setdefault("legacy_id", char.get("id", ""))
        line["text"] = "".join(str(c.get("text") or "") for c in line.get("chars") or [])
    result["blocks"] = [char for line in lines for char in line.get("chars") or []]
    return result
