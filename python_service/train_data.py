# -*- coding: utf-8 -*-
"""训练数据判定与标注载入（从 training_service 拆出）。

「训练数据只认已确认」的判定层（README 标注与训练规则）：
_is_confirmed/_box_confirmed/_page_confirmed 与旧页兼容、_page_split 按页
划分 train/val 防泄漏；书籍/标注页载入与图像读取辅助也在此。
训练_service.py 仍为门面，外部 import 面不变。
"""
import json
import hashlib
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import time
from typing import Any
import cv2
import numpy as np
import imaging
import registry_io




SERVICE_DIR = registry_io.SERVICE_DIR


# 数据集/训练模型根目录可配置（train_paths.json，见 train_paths 模块）。
# 模块属性保留为测试/显式覆盖缝：None = 跟随配置；测试隔离时直接赋值
# 临时目录（_isolate_datasets_root 依赖此行为）。
DATASETS_ROOT = None



# 数据集全局共享：所有书籍的样本合并进 datasets/_global/<layer>/，文件名带
# <书籍ID>_ 前缀区分归属。模型产物与注册表（models/）本就是全局的，数据集
# 与其对齐——在任何书籍项目里看到的都是同一份训练数据。
GLOBAL_DATASET_DIR = "_global"

# 旧版按书数据集（datasets/<书籍ID>/）迁移后的存放处：只挪位置保留备份，
# 不删除任何数据。
LEGACY_DATASET_DIR = "_legacy"


TRAINED_ROOT = None


def datasets_root() -> str:
    """当前数据集根目录（train_paths 配置，或测试覆盖值）。"""
    if DATASETS_ROOT:
        return DATASETS_ROOT
    import train_paths

    return train_paths.dataset_root()


def trained_root_dir() -> str:
    """当前训练模型根目录（train_paths 配置，或测试覆盖值）。"""
    if TRAINED_ROOT:
        return TRAINED_ROOT
    import train_paths

    return train_paths.trained_root()


WORKER_PATH = os.path.join(SERVICE_DIR, "train_worker.py")



LAYER_INFO = {
    "char_det": {"task": "detect", "names": ["char"], "title": "单字检测"},
    "line_det": {"task": "detect", "names": ["line_normal", "line_annotation"], "title": "行检测"},
    "paragraph_det": {"task": "detect", "names": ["paragraph"], "title": "自然段检测"},
    # region_det 类别词表是 Dart/Python 双实现协议（flutter_app/lib/models/
    # models.dart 的 regionLabels），两侧必须同序：main_text 恒为 id=0、
    # 新类只追加不重排——重排会让旧标注/旧模型的类别 id 静默错标。
    # figure=插图区 / table=表格区（+83 表格识别）：暂无对应训练数据，
    # 旧模型不产出这两类；人工确认的框会进入 region_det 训练集，积累
    # 够了即可训出自动检测。
    "region_det": {"task": "detect",
                   "names": ["main_text", "header", "footer", "page_number",
                             "margin_note", "figure", "table"],
                   "title": "版面区检测"},
    "char_cls": {"task": "classify", "names": [], "title": "单字候选分类"},
}


LAYERS = list(LAYER_INFO.keys())


DATASET_SCHEMA_VERSION = 2



# Minimum confirmed samples recommended before starting a first useful model.
# Larger backbones have more capacity and therefore need more examples.  These
# values are deliberately exposed through /train/stats so the UI can explain
# the requirement instead of silently applying a hard-coded gate.
TRAINING_REQUIREMENTS: dict[str, dict[str, dict[str, int]]] = {
    "char_det": {
        "yolov8n": {"instances": 300},
        "yolov8s": {"instances": 900},
        "yolov8m": {"instances": 1800},
        "yolov8l": {"instances": 3600},
    },
    "line_det": {
        "yolov8n": {"instances": 120},
        "yolov8s": {"instances": 360},
        "yolov8m": {"instances": 720},
        "yolov8l": {"instances": 1440},
    },
    "paragraph_det": {
        "yolov8n": {"instances": 60},
        "yolov8s": {"instances": 180},
        "yolov8m": {"instances": 360},
        "yolov8l": {"instances": 720},
    },
    "region_det": {
        "yolov8n": {"instances": 30},
        "yolov8s": {"instances": 90},
        "yolov8m": {"instances": 180},
        "yolov8l": {"instances": 360},
    },
    "char_cls": {
        "yolov8n": {"instances": 500, "classes": 50},
        "yolov8s": {"instances": 1500, "classes": 120},
        "yolov8m": {"instances": 3000, "classes": 240},
        "yolov8l": {"instances": 6000, "classes": 480},
    },
}




def _layer_default_model(layer: str) -> str:
    """该层的历史默认基础档位（旧注册表条目没记录 base_model 时按此归档）。"""
    return "yolov8n" if layer == "char_cls" else "yolov8s"




def _training_readiness(
    layer: str,
    instances: int,
    classes: int = 0,
    rounds_by_model: dict[str, int] | None = None,
) -> dict[str, Any]:
    """Build model-size-aware readiness information for the training page.

    每个档位的数据要求按该档位已成功训练的轮数进阶：第 k 轮训练需要
    基础要求 × k 个确认样本（与 Kraken 微调"每代 +100 行"同一思路——
    同一批数据反复重训没有增益）。[rounds_by_model] 为 档位 -> 已成功
    训练次数，缺省全部为 0（从未训练）。

    另外给出 next_milestone（下一个里程碑）：所有未达标候选中要求最低
    的档位；要求并列时优先"已训练过"的档位（同一个模型连续进化到下一
    轮，例如 n 第 3 轮要求与 s 第 1 轮相同时继续练 n）。全部达标时指向
    要求最高的档位。
    """
    rounds_by_model = rounds_by_model or {}
    requirements = TRAINING_REQUIREMENTS.get(layer, TRAINING_REQUIREMENTS["char_det"])
    by_model: dict[str, dict[str, Any]] = {}
    for model, target in requirements.items():
        rounds = max(0, int(rounds_by_model.get(model, 0)))
        target_instances = target.get("instances", 0) * (rounds + 1)
        # 字类覆盖要求不随轮数放大：可用字类受书籍实际用字上限约束，
        # 递增会变成永远达不到的目标；轮数门槛只作用于样本量。
        target_classes = target.get("classes", 0)
        instance_progress = min(1.0, instances / target_instances) if target_instances else 1.0
        class_progress = min(1.0, classes / target_classes) if target_classes else 1.0
        progress = min(instance_progress, class_progress)
        missing_instances = max(0, target_instances - instances)
        missing_classes = max(0, target_classes - classes)
        by_model[model] = {
            "rounds": rounds + 1,
            "target_instances": target_instances,
            "target_classes": target_classes,
            "progress": round(progress, 4),
            "ready": progress >= 1.0,
            "missing_instances": missing_instances,
            "missing_classes": missing_classes,
        }
    # The smallest model whose data requirement is met is the most useful
    # recommendation; otherwise show the smallest model as the next target.
    recommended = next((m for m in requirements if by_model[m]["ready"]), next(iter(requirements)))
    # 下一个里程碑：候选 = 每个档位的"下一轮"。排序键依次为：要求样本数
    # （低者优先）、并列时已训练过的档位优先（同一个模型连续进化到第
    # k+1 轮，而不是同等数据成本下切换到新档位）、档位更高优先（n<s<m<l）。
    order = list(requirements.keys())

    def _candidate_key(model: str) -> tuple[int, int, int]:
        info = by_model[model]
        trained = 1 if info["rounds"] > 1 else 0
        return (info["target_instances"], -trained, -order.index(model))

    unsatisfied = [m for m in order if not by_model[m]["ready"]]
    milestone_model = (
        min(unsatisfied, key=_candidate_key)
        if unsatisfied
        else max(order, key=_candidate_key)
    )
    milestone = {"model": milestone_model, **by_model[milestone_model]}
    return {
        "instances": instances,
        "classes": classes,
        "recommended_model": recommended,
        "requirements": by_model,
        "next_milestone": milestone,
    }




def _is_confirmed(item: dict[str, Any] | None) -> bool:
    """Return whether an annotation is explicitly approved for training.

    ``confirmed`` is retained for annotations written by older Flutter builds;
    new annotations use the four-state ``status`` field.
    """
    if not item:
        return False
    status = str(item.get("status", "")).strip().lower()
    return status == "confirmed" or item.get("confirmed") is True




def _box_confirmed(item: dict[str, Any] | None) -> bool:
    """识别框几何是否可作为检测训练样本。

    编辑器「确认识别框」会把本页正文区/段落/行/字框统一标记
    ``box_confirmed``（只认可几何，文字候选仍待确认）；「确认并保存」
    的完全确认（status=confirmed）蕴含几何确认。只作用于检测层
    （char/line/paragraph/region det）；文字类训练（char_cls、Kraken
    行导出）不看这个标记，仍要求完全确认。
    """
    if not item:
        return False
    return _is_confirmed(item) or item.get("box_confirmed") is True




def _page_confirmed(page: dict[str, Any]) -> bool:
    # PageAnnotation historically had no status field. Treat such containers
    # as approved and enforce confirmation on the actual regions/lines/chars.
    if "status" not in page and "confirmed" not in page:
        return True
    return _is_confirmed(page)




def _page_split(pages: list[dict], train_ratio: float, seed: int) -> dict[str, str]:
    """Deterministic page-level split. A page can never straddle train/val."""
    ids = sorted(str(p.get("page_id") or p.get("id") or i) for i, p in enumerate(pages))
    rng = random.Random(seed)
    rng.shuffle(ids)
    cut = max(1, min(len(ids), int(round(len(ids) * train_ratio)))) if ids else 0
    # Keep a validation page when there are at least two pages.
    if len(ids) > 1:
        cut = min(cut, len(ids) - 1)
    return {page_id: ("train" if i < cut else "val") for i, page_id in enumerate(ids)}




def _log(message: str) -> None:
    print(f"[train] {message}", flush=True)




def _imread(path: str):
    """cv2.imread 不支持中文路径；数据集生成对坏图容错（None=跳过）。"""
    try:
        return imaging.imread_unicode(path)
    except OSError:
        return None




def _image_size(path: str):
    """只读文件头取宽高，不整图解码。"""
    with open(path, "rb") as f:
        head = f.read(32)
    if len(head) >= 24 and head[:4] == b"\x89PNG":
        w = int.from_bytes(head[16:20], "big")
        h = int.from_bytes(head[20:24], "big")
        return w, h
    if len(head) >= 4 and head[:2] == b"\xff\xd8":
        # JPEG：逐段找 SOFn
        with open(path, "rb") as f:
            data = f.read()
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h = int.from_bytes(data[i + 5:i + 7], "big")
                w = int.from_bytes(data[i + 7:i + 9], "big")
                return w, h
            seg_len = int.from_bytes(data[i + 2:i + 4], "big")
            if seg_len < 2:
                break
            i += 2 + seg_len
    return None




# ────────────────────────── 数据集生成 ──────────────────────────


def _infer_vertical_paragraphs(lines: list[dict], horizontal_dir: str) -> list[dict]:
    """标注缺段落时按竖排规则推断（与前端 _clusterVerticalLines 同逻辑）：
    阅读序遍历相邻列，短列收尾 / 段首空格 / 列距过大断段。"""
    # Imported annotations from older builds can omit geometry while they are
    # still being reviewed. They must not make the stats endpoint fail.
    lines = [
        line for line in lines
        if all(key in line for key in ("x", "y", "w", "h"))
    ]
    if not lines:
        return []
    rtl = horizontal_dir == "rtl"
    sorted_lines = sorted(lines, key=lambda l: l["x"], reverse=rtl)

    widths = sorted(l["w"] for l in lines)
    median_w = float(np.median(widths))
    gap_limit = median_w * 2.2

    bottoms = [l["y"] + l["h"] for l in lines]
    tops = [l["y"] for l in lines]
    max_bottom, min_top = max(bottoms), min(tops)
    heights = sorted(l["h"] for l in lines)
    median_h = float(np.median(heights))
    short_tol = median_h * 0.35

    char_heights = [
        l["h"] / len(l["chars"]) for l in lines if l.get("chars")
    ]
    char_h = float(np.median(char_heights)) if char_heights else median_h / 30
    indent_tol = char_h * 1.2

    paragraphs = []
    seg: list[dict] = []
    prev = None
    for ln in sorted_lines:
        if prev is not None:
            gap = abs(prev["x"] - ln["x"])
            prev_short = (max_bottom - (prev["y"] + prev["h"])) > short_tol
            indented = (ln["y"] - min_top) > indent_tol
            if prev_short or indented or gap > gap_limit:
                if seg:
                    paragraphs.append(seg)
                seg = []
        seg.append(ln)
        prev = ln
    if seg:
        paragraphs.append(seg)
    return paragraphs




def _book_dirs_under(project_dir: str) -> list[str]:
    """project_dir 是单本书时返回 [它本身]；是库根目录时返回全部书籍目录。

    传入库根目录（不含 project.json）即为"汇总全部书籍"模式。
    """
    if os.path.exists(os.path.join(project_dir, "project.json")):
        return [project_dir]
    books = []
    if os.path.isdir(project_dir):
        for name in sorted(os.listdir(project_dir)):
            d = os.path.join(project_dir, name)
            if os.path.isdir(d) and os.path.exists(os.path.join(d, "project.json")):
                books.append(d)
    return books




def has_books(project_dir: str) -> bool:
    """project_dir 是单本书目录、或库根目录下有书籍（汇总模式）时 True。

    /train/datasets、/train/start 的入口校验用它与 generate_datasets/
    dataset_stats 的取数语义保持一致——三者都接受库根目录，入口不能
    只认 project.json，否则训练页"全部书籍（汇总）"启动即报
    project not found。"""
    return bool(_book_dirs_under(project_dir))




def _annotation_pages(project_dir: str) -> list[dict]:
    ann_dir = os.path.join(project_dir, "annotations")
    pages = []
    if not os.path.isdir(ann_dir):
        return pages
    for name in sorted(os.listdir(ann_dir)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(ann_dir, name), encoding="utf-8") as f:
                pages.append(json.load(f))
        except Exception as exc:
            _log(f"skip {name}: {exc}")
    return pages




def _load_book(book_dir: str) -> dict[str, Any]:
    """读取书籍的 project.json；文件缺失或损坏时返回空 dict。"""
    try:
        with open(os.path.join(book_dir, "project.json"), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}




def _load_book_pages(books: list[str]) -> tuple[list[dict[str, Any]], dict[int, str]]:
    """汇总多本书的标注页，返回 (pages, id(page) -> 该书横排阅读方向)。

    段落推断回退需要知道页所属书籍的 horizontal_dir（rtl 从右往左），
    汇总模式下各书方向可能不同，必须逐书记录而不是共用一个值。
    """
    pages: list[dict[str, Any]] = []
    h_by_page: dict[int, str] = {}
    for b in books:
        book_h = h_dir(_load_book(b))
        for page in _annotation_pages(b):
            pages.append(page)
            h_by_page[id(page)] = book_h
    return pages, h_by_page




def h_dir(project: dict) -> str:
    return (project.get("settings") or {}).get("horizontal_dir", "ltr")



def global_root() -> str:
    """全局共享数据集根目录（datasets/_global）。跟随 train_paths 配置
    （DATASETS_ROOT 模块属性仍可整体覆盖，测试切临时目录用）。"""
    return os.path.join(datasets_root(), GLOBAL_DATASET_DIR)



def global_layer_dir(layer: str) -> str:
    """某层的全局数据集目录：所有书籍合并后的同一份训练数据。"""
    return os.path.join(global_root(), layer)



def library_root_of(project_dir: str) -> str:
    """project_dir 是单本书时返回其父目录（书库根）；已是库根则原样返回。"""
    norm = os.path.normpath(project_dir)
    if os.path.exists(os.path.join(norm, "project.json")):
        return os.path.dirname(norm)
    return norm



def all_book_dirs(project_dir: str) -> list[str]:
    """书库级聚合：project_dir 所在书库下的全部书籍目录。

    数据集与模型都是全局资产，统计/训练取数始终按整个书库聚合——传入
    单本书还是库根目录，得到的都是同一批书籍。"""
    return _book_dirs_under(library_root_of(project_dir))
