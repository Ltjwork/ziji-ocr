# -*- coding: utf-8 -*-
"""按书跨页模板库：字 → 已确认墨迹参照（128 画布 + 骨架 + 可选嵌入）。

刻本同字同雕版，人工确认过的墨迹是比楷体字模强得多的参照。模板库把
char_verify 的同伴互证从页内扩展到全书：verify_chars_batch 对有模板的
字取"与本书已确认同字的最大相似度"参与升级/降级判定。

存储：python_service/verify_templates/<project_id>.npz（压缩，原子写，
不污染书籍目录）。每字至多 TEMPLATE_MAX_PER_CHAR 个实例（覆盖不同刻
印形态），npz 键 "canv:<字>"= (n,128,128) uint8、"skel:<字>"=
(n,128,128) uint8、"emb:<字>"= (n,64) float32（训练模型可用时才有）、
"meta"= JSON 字符串。度量：有嵌入用余弦（(cos+1)/2），否则双向
Chamfer（char_verify._shape_score）——模板库先于模型可用。
"""

import json
import os
import tempfile

import numpy as np

import char_verify

TEMPLATE_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "verify_templates")
TEMPLATE_MAX_PER_CHAR = 4

# 嵌入度量的判定阈值（余弦映射到 0-1 后；与 Chamfer 的 PEER_* 常数不同
# 刻度，回测标定）。Chamfer 路径复用 char_verify 的 PEER_* 常数。
EMB_AGREE = 0.78
EMB_STRONG = 0.90


def _npz_path(project_dir: str) -> str:
    pid = os.path.basename(os.path.normpath(project_dir))
    return os.path.join(TEMPLATE_ROOT, f"{pid}.npz")


def load(project_dir: str) -> dict[str, dict]:
    """读模板库：字 → {canvas, skel, emb}。无库/损坏返回空 dict。"""
    path = _npz_path(project_dir)
    if not os.path.exists(path):
        return {}
    try:
        data = np.load(path, allow_pickle=False)
    except Exception:
        return {}
    out: dict[str, dict] = {}
    for key in data.files:
        if not key.startswith("canv:"):
            continue
        ch = key[5:]
        entry = {"canvas": data[key]}
        if f"skel:{ch}" in data.files:
            entry["skel"] = data[f"skel:{ch}"]
        if f"emb:{ch}" in data.files:
            entry["emb"] = data[f"emb:{ch}"]
        out[ch] = entry
    return out


def _save_atomic(path: str, arrays: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(
        dir=os.path.dirname(path), suffix=".npz.tmp")
    os.close(fd)
    try:
        with open(tmp, "wb") as f:
            np.savez_compressed(f, **arrays)
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def update(project_dir: str, entries: list[tuple[str, np.ndarray]]
           ) -> dict:
    """合并新模板：entries 为 [(字, 128 画布二值图 uint8)]。

    每字保留至多 TEMPLATE_MAX_PER_CHAR 个实例（新模板追加，超出丢最
    旧）；骨架即时派生，嵌入在模型可用时预计算（相似度查询零推理）。"""
    if not entries:
        return {"added": 0, "chars": 0}
    module = char_verify._pair_model_module()
    lib = load(project_dir)
    added = 0
    for ch, canvas in entries:
        arr = (canvas > 0).astype(np.uint8) * 255
        skel = char_verify._skeleton(arr)
        emb = None
        if module is not None:
            glyph_z = char_verify._glyph_embedding(ch, module)
            if glyph_z is not None:
                z = char_verify._embed_images(module, [arr])[0]
                emb = z.astype(np.float32)
        entry = lib.setdefault(
            ch, {"canvas": np.zeros((0, 128, 128), np.uint8),
                 "skel": np.zeros((0, 128, 128), np.uint8)})
        if emb is not None and "emb" not in entry:
            entry["emb"] = np.zeros((0, emb.shape[0]), np.float32)
        entry["canvas"] = np.concatenate(
            [entry["canvas"], arr[None]])[-TEMPLATE_MAX_PER_CHAR:]
        entry["skel"] = np.concatenate(
            [entry["skel"], skel[None]])[-TEMPLATE_MAX_PER_CHAR:]
        if emb is not None:
            entry["emb"] = np.concatenate(
                [entry.get("emb", np.zeros((0, emb.shape[0]), np.float32)),
                 emb[None]])[-TEMPLATE_MAX_PER_CHAR:]
        elif "emb" in entry:
            # 无模型的更新使嵌入失配：整字丢弃旧嵌入，回退 Chamfer 度量
            entry.pop("emb", None)
        added += 1
    arrays: dict = {}
    for ch, entry in lib.items():
        arrays[f"canv:{ch}"] = entry["canvas"]
        arrays[f"skel:{ch}"] = entry["skel"]
        if "emb" in entry and len(entry["emb"]) == len(entry["canvas"]):
            arrays[f"emb:{ch}"] = entry["emb"]
    arrays["meta"] = np.array(json.dumps(
        {"chars": len(lib), "updated": _now_iso()}, ensure_ascii=False))
    _save_atomic(_npz_path(project_dir), arrays)
    return {"added": added, "chars": len(lib)}


def update_from_blocks(project_dir: str, image_path: str, blocks: list
                       ) -> dict:
    """从一页字块中提取已确认单字的墨迹模板（编辑器确认保存后/批量校验
    时的增量更新入口）。"""
    mask = char_verify._text_mask_for_refinement(image_path)
    if mask is None:
        return {"added": 0, "chars": 0}
    entries = []
    for b in blocks:
        text = (getattr(b, "text", "") or "").strip()
        if getattr(b, "status", None) != "confirmed" or len(text) != 1:
            continue
        glyph = char_verify._glyph_features(text)
        if glyph is None:
            continue
        ink, _reason = char_verify._crop_ink(
            mask, (b.x, b.y, b.w, b.h))
        if ink is None:
            continue
        canvas = char_verify._prepare(ink.copy(), target_w=glyph[4])
        entries.append((text, canvas))
    if not entries:
        return {"added": 0, "chars": 0}
    return update(project_dir, entries)


def clear(project_dir: str) -> dict:
    """清空本书模板库（「本书重置为未确认」时同步调用）。"""
    path = _npz_path(project_dir)
    if os.path.exists(path):
        os.remove(path)
        return {"cleared": True}
    return {"cleared": False}


def best_similarity(ch: str, ink_canvas: np.ndarray,
                    ink_skel: np.ndarray, lib: dict[str, dict]
                    ) -> tuple[float, int] | None:
    """与本书已确认同字模板的最大相似度（0-1）+ 模板数。无模板返回
    None。有嵌入用余弦（(cos+1)/2），否则双向 Chamfer。"""
    entry = lib.get(ch)
    if not entry or not len(entry.get("canvas", [])):
        return None
    n = len(entry["canvas"])
    emb = entry.get("emb")
    if emb is not None and len(emb) == n:
        module = char_verify._pair_model_module()
        if module is not None:
            z = char_verify._embed_images(module, [ink_canvas])[0]
            cos = emb @ z
            return float((float(cos.max()) + 1.0) / 2.0), n
    skels = entry.get("skel")
    if skels is None or not len(skels):
        return None
    best = 0.0
    for i in range(len(skels)):
        best = max(best, char_verify._shape_score(ink_skel, skels[i]))
    return float(best), n


def _now_iso() -> str:
    import datetime
    return datetime.datetime.now().isoformat(timespec="seconds")
