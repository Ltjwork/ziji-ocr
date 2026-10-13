# -*- coding: utf-8 -*-
"""模型发版打包（手动触发，POST /models/pack）：把当前激活的各层 YOLO +
verify_pair 比对模型 + Kraken 识别模型 + 清单打成签名的
models_release.zjpack，随安装包分发（格式基准见 zjpack.py）。

刻意不做任何自动打包——训练/激活闭环不经过这里，发版是独立动作，被放弃
的实验 run 永远不会进包。私钥在 release_keys/ 下，绝不随安装包分发
（installer Excludes 已排除）。收集规则：某层有激活就打激活模型，
没激活打当前散文件基线（保证用户机永远有一套能跑的底）。
"""
from __future__ import annotations

import filecmp
import json
import os
import time

from fastapi import HTTPException
from pydantic import BaseModel

from api_base import BACKEND_BUILD, app
import model_registry
import model_store
import registry_io
import zjpack

SERVICE_DIR = os.path.dirname(os.path.abspath(__file__))
KEY_PATH = os.path.join(SERVICE_DIR, "release_keys", "zjpack_ed25519")
PACK_OUT = model_store.PACK_PATH

YOLO_LAYERS = ("char_det", "line_det", "paragraph_det", "region_det", "char_cls")


class ModelPackRequest(BaseModel):
    pack_version: str = ""


def _load_seed(key_path: str) -> bytes:
    if not os.path.exists(key_path):
        raise RuntimeError(
            "签名私钥不存在：请先运行 python tool_pack_models.py --init-key "
            "生成 release_keys/zjpack_ed25519（私钥只留管理员机，勿分发）")
    with open(key_path, "rb") as f:
        seed = f.read()
    if len(seed) != 32:
        raise RuntimeError("签名私钥格式不对（应为 32 字节种子），请重新 --init-key")
    return seed


def _run_name(info: dict) -> str:
    """激活来源的 run 目录名（如 run_20260930_153000）。注册表里
    active_source 与 runs[].best 同路径口径，先在 runs 里反查 run_dir
    （ultralytics 的 best 嵌套为 run/train/weights/best.pt，直接取父目录
    只会得到 'weights'）；反查不到再退回 best 的父目录名。"""
    source = info.get("active_source")
    if not source:
        return ""
    norm = os.path.normcase(os.path.abspath(str(source)))
    for run in info.get("runs") or []:
        best = run.get("best")
        if best and os.path.normcase(os.path.abspath(str(best))) == norm:
            run_dir = str(run.get("run_dir") or "").rstrip("\\/")
            if run_dir:
                return os.path.basename(run_dir)
    return os.path.basename(os.path.dirname(norm))


def _collect_entries(service_dir: str, registry_path: str):
    """收集打包条目与来源说明。返回 (entries, provenance)：provenance 按
    kind 记录来源（激活 run / 基线 / 微调），进 manifest 与接口响应。"""
    reg = registry_io.load_registry(registry_path)
    layers = reg.get("layers", {})
    entries: list[dict] = []
    provenance: dict[str, dict] = {}

    def _add_yolo(layer: str, path: str, src: dict):
        kind = f"yolo_{layer}"
        entries.append({"name": f"{layer}.pt", "kind": kind, "path": path})
        provenance[kind] = src

    for layer in YOLO_LAYERS:
        info = layers.get(layer) or {}
        active = info.get("active")
        if active and os.path.exists(active):
            _add_yolo(layer, active, {
                "source": "activated",
                "run": _run_name(info),
                "metrics": info.get("active_metrics"),
            })
            continue
        for base in model_registry.baseline_candidates(layer, service_dir):
            if os.path.exists(base):
                _add_yolo(layer, base, {
                    "source": "baseline", "file": os.path.basename(base)})
                break

    vp_info = layers.get("verify_pair") or {}
    vp = vp_info.get("active")
    stable_vp = os.path.join(service_dir, "models", "active_verify_pair.pt")
    if vp and os.path.exists(vp):
        _add_yolo("verify_pair", vp, {
            "source": "activated",
            "run": _run_name(vp_info),
        })
    elif os.path.exists(stable_vp):
        _add_yolo("verify_pair", stable_vp, {"source": "stable_copy"})

    kraken_dir = os.path.join(service_dir, "kraken_models")
    rec = os.path.join(kraken_dir, "chat_rec.mlmodel")
    backup = os.path.join(kraken_dir, "chat_rec_base_backup.mlmodel")
    if os.path.exists(rec) and os.path.getsize(rec) > 1024:
        finetuned = (os.path.exists(backup)
                     and not filecmp.cmp(rec, backup, shallow=False))
        entries.append({"name": "chat_rec.mlmodel", "kind": "kraken_rec",
                        "path": rec})
        provenance["kraken_rec"] = {
            "source": "fine-tuned" if finetuned else "CHAT_base"}
        if os.path.exists(backup):
            entries.append({"name": "chat_rec_base_backup.mlmodel",
                            "kind": "kraken_rec_base_backup", "path": backup})
    else:
        provenance["kraken_rec"] = {"source": "skipped_loose_missing"}

    return entries, provenance


def pack_release(pack_version: str = "", *, service_dir: str = SERVICE_DIR,
                 registry_path: str = registry_io.REGISTRY_PATH,
                 key_path: str = KEY_PATH, out_path: str = PACK_OUT) -> dict:
    """执行打包并返回 manifest（端点与 CLI 工具共用；可选参数仅供测试注入）。"""
    seed = _load_seed(key_path)
    entries, provenance = _collect_entries(service_dir, registry_path)
    if not any(e["kind"] != "manifest" for e in entries):
        raise RuntimeError("本机没有任何可打包的模型文件（YOLO/Kraken 全缺失）")

    version = (pack_version or "").strip() or time.strftime("%Y%m%d")
    manifest = {
        "pack_version": version,
        "created_at": time.time(),
        "backend_build": BACKEND_BUILD,
        "public_key": model_store.PUBLIC_KEY.hex(),
        "layers": provenance,
    }
    entries.append({"name": "manifest.json", "kind": "manifest",
                    "data": json.dumps(manifest, ensure_ascii=False,
                                       indent=2).encode("utf-8")})

    def _progress(name: str, kind: str, mb: float) -> None:
        print(f"[pack] {name}（{kind}）{mb:.1f}MB", flush=True)

    result = zjpack.write_pack(out_path, entries, seed,
                               pack_version=version, progress=_progress)
    result["layers"] = provenance
    return result


@app.post("/models/pack")
def models_pack(req: ModelPackRequest):
    try:
        return pack_release(req.pack_version)
    except RuntimeError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
