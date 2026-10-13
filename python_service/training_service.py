# -*- coding: utf-8 -*-
"""训练服务：从项目标注生成 5 层数据集、后台训练任务管理、模型注册表。

5 层模型：
- char_det      单字检测（YOLO detect, 1 类）
- line_det      行检测（YOLO detect, line_normal/line_annotation）
- paragraph_det 自然段检测（YOLO detect, 1 类）
- region_det    正文区检测（YOLO detect, 1 类）
- char_cls      单字候选分类（YOLO classify，字图 → top-K 候选字）

数据集是全局共享资产（与模型/注册表同口径）：所有书籍的样本合并进
python_service/datasets/_global/<layer>/（文件名带 <书籍ID>_ 前缀），
在任何书籍项目里看到的都是同一份训练数据；旧版按书目录自动迁移。
模型产物：     python_service/models/trained/<layer>/run_<ts>/
注册表：       python_service/models/registry.json
"""
# 本文件是门面（facade）：实现已按职责拆分到 train_data, train_datasets, train_tasks, train_registry，此处 re-export 保持既有 import 面不变。
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

from train_data import (  # noqa: E402,F401
    SERVICE_DIR,
    GLOBAL_DATASET_DIR,
    LEGACY_DATASET_DIR,
    WORKER_PATH,
    datasets_root,
    trained_root_dir,
    LAYER_INFO,
    LAYERS,
    DATASET_SCHEMA_VERSION,
    TRAINING_REQUIREMENTS,
    global_root,
    global_layer_dir,
    library_root_of,
    all_book_dirs,
    _layer_default_model,
    _training_readiness,
    _is_confirmed,
    _box_confirmed,
    _page_confirmed,
    _page_split,
    _log,
    _imread,
    _image_size,
    _infer_vertical_paragraphs,
    _book_dirs_under,
    has_books,
    _annotation_pages,
    _load_book,
    _load_book_pages,
    h_dir,
)

from train_datasets import (  # noqa: E402,F401
    _INVALID_FS_CHARS,
    _safe_class_name,
    _write_detect_dataset,
    _write_char_cls_dataset,
    _write_layer_for_book,
    _purge_book_files,
    _finalize_detect_dataset,
    _finalize_char_cls_dataset,
    _cls_disk_stats,
    generate_datasets,
    dataset_stats,
    dataset_dir,
    _migrate_legacy_datasets,
)

from train_export import (  # noqa: E402,F401
    export_datasets,
    scan_pending,
)
from train_registry import (  # noqa: E402,F401
    delete_run,
    reconcile_disk_runs,
    scan_layer_runs,
    run_dir_size_mb,
)

from train_tasks import (  # noqa: E402,F401
    _Task,
    _TASKS,
    _TASK_LOCK,
    _TASK_COUNTER,
    _monitor,
    start_training,
    stop_training,
    training_status,
    training_curve,
    evaluate_char_cls,
    training_log,
    _register_run,
)

from train_registry import (  # noqa: E402,F401
    REGISTRY_PATH,
    _run_base_tier,
    _load_registry,
    _save_registry,
    list_models,
    activate_model,
    deactivate_model,
    active_model_path,
)
