"""页面区域 → Excalidraw 场景 JSON（.excalidraw，Obsidian Excalidraw 插件
与 excalidraw.com 均可直接打开编辑）——导出工作台 v2。

设计目标：命盘、表格、示意图（箭头）、圆图、书法印章、混合图文都能
导成可编辑矢量图，且参数可调、结果可预览迭代。

文字来源：默认注入编辑器已校对数据（ocr_lines，不重跑识别、不占 GPU
门，预览迭代秒级）；未注入时区域重识别，结果按 (图像, 区域, 识别参数)
LRU 缓存——工作台里只调图形参数时不重复跑 Kraken。

图形检测分层：

1. 墨迹掩膜：Otsu 二值（极性自检）→ 字框外扩 2px 抠除（文字归文字层，
   低置信字不出文字元素但墨迹同样抠掉，避免字形污染图形层）→ 连通域
   小点过滤；
2. 直线层：长核形态学开运算抽横/竖笔画（不受文字/圆弧穿越影响）→
   共线聚类合并（桥接印刷断线）→ 平行双线合并（古籍双栏线）→ 端点向
   交叉线吸附（拐角对齐）→ 沿线覆盖率 < 0.65 判虚线；
3. 格面还原：V 对 × 相邻共同 H 围成的空格 → 矩形（网格 → 宫格矩形、
   独立框 → 矩形；越出格面继续延伸的墙保留为线段，T 形交接不吞线）；
4. 剩余墨迹：细四边形 → 斜笔画中心线；实心小凸块贴线端 → 箭头
   （endArrowhead）；实心大块 → 填充矩形；椭圆拟合（张角覆盖拒绝
   断弧——直线层已剥离，交叉圆轮廓完整）；其余连通域 Zhang-Suen 细化
   + 最长路径 → 折线（曲线笔画）；霍夫兜底（短横竖可合并成虚线、对角
   线段）；
5. 取色：元素 bbox 内 HSV 饱和度采样 → Excalidraw 调色板最近色
   （还原彩印标注如紫框）；纯黑/自定义模式可覆盖；
6. 文字：竖排行逐字（字框原位）、横排行整行（字号 = 字高中位数）；
   置信度阈值过滤低置信字；
7. 组装：底图（可选，锁定底层）→ 图形 → 文字；groupIds 按类型分组；
   stats 含 ink_coverage（元素 ∪ 字框覆盖的墨迹比例 = 导出保真度）。

build_excalidraw_scene 只吃识别好的 lines（可注入，测试无需起 Kraken）；
region_to_excalidraw 是端点用的完整编排。
"""
# 本文件是门面（facade）：实现已按职责拆分到 excalidraw_scene, excalidraw_ink, excalidraw_lines, excalidraw_graphics，此处 re-export 保持既有 import 面不变。
from __future__ import annotations
import base64
import math
import random
import time
import uuid
from collections import OrderedDict, deque
from typing import Any
import cv2
import numpy as np
from segmenter import _imread
from excalidraw_graphics import (_detect_graphics,
    _stroke_colors, _text_records, _ink_coverage, _region_ink_mask)
from excalidraw_ink import _clamp, _log
from excalidraw_ink import (_clamp, _median, _point_segment_dist, _rect_iou)
from excalidraw_ink import (_log, _clamp, _region_ink_mask,
    _drop_specks, _interior_solid, _point_off_records, _point_segment_dist,
    _median, _rect_iou, _box_close, _angular_coverage, _thin_quad_centerline,
    _thin, _longest_path, _simplify_path, _ink_coverage)
from excalidraw_lines import (_morph_segments, _cluster_straight,
    _append_run, _merge_parallel, _snap_endpoints, _lattice_faces,
    _intervals_cover, _lattice_line_record, _segment_dashed,
    _match_arrow_endpoint, _hough_lines, _merge_collinear, _dedupe_lines)


from excalidraw_scene import (  # noqa: E402,F401
    _DEFAULT_SETTINGS,
    _BOOL_FLAGS,
    normalize_settings,
    _is_hex,
    _OCR_CACHE,
    _OCR_CACHE_MAX,
    _recognize_region,
    region_to_excalidraw,
    _text_box_lines,
    _chars_in_rect,
    _clip_lines_to_rect,
    _normalize_region,
    build_excalidraw_scene,
    _record_bbox,
    _element,
    _line_element,
    _text_element,
    _background_image_element,
    _visual_width,
    _png_data_url,
    _pipeline_images,
)

from excalidraw_ink import (  # noqa: E402,F401
    _log,
    _clamp,
    _region_ink_mask,
    _drop_specks,
    _interior_solid,
    _point_off_records,
    _point_segment_dist,
    _median,
    _rect_iou,
    _box_close,
    _angular_coverage,
    _thin_quad_centerline,
    _thin,
    _longest_path,
    _simplify_path,
    _ink_coverage,
)

from excalidraw_lines import (  # noqa: E402,F401
    _morph_segments,
    _cluster_straight,
    _append_run,
    _merge_parallel,
    _snap_endpoints,
    _lattice_faces,
    _intervals_cover,
    _lattice_line_record,
    _segment_dashed,
    _match_arrow_endpoint,
    _hough_lines,
    _merge_collinear,
    _dedupe_lines,
)

from excalidraw_graphics import (  # noqa: E402,F401
    _text_records,
    _PALETTE,
    _stroke_colors,
    _detect_graphics,
    _component_path,
)
