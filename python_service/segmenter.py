# 本文件是门面（facade）：实现已按职责拆分到 seg_trace, seg_models, seg_imaging, seg_refine, seg_chars, seg_lines, seg_pipeline, seg_layout, seg_doublecol, seg_candidates，此处 re-export 保持既有 import 面不变。
import os
import platform
import sys
import threading
import traceback
from contextvars import ContextVar
import cv2
import numpy as np
from typing import Any
from imaging import imread_unicode
from metadata import enrich_result
from model_registry import resolve_model_path
from seg_trace import _log, _exception_summary
from seg_trace import _log
from seg_trace import _log
from seg_imaging import (_imread, _runs, _merge_close_runs, _tight_rect, _to_block, _text_mask_for_refinement, _is_edge_ruling_fragment, _is_cross_column_band)
from seg_trace import _log, _exception_summary
from seg_imaging import (_to_block, _runs, _merge_close_runs, _tight_rect, _text_mask_for_refinement)
from seg_refine import split_punct_merged_boxes
from seg_trace import _log
from seg_imaging import (_runs, _merge_close_runs, _merge_fragmentary_strips, _text_mask_for_refinement, _tight_rect)
from seg_models import _predict_detection_layer
from seg_refine import _tight_piece
from seg_trace import (begin_debug_trace, debug_trace_snapshot, _log, _exception_summary)
from seg_models import (_predict_detection_layer, _override_for, record_yolo_error, current_yolo_error, _YOLO_PREDICT_LOCK, _default_yolo_model_path, _import_opencc, _load_yolo_char_model, _yolo_diagnostics)
from seg_imaging import (_imread, _to_block, mask_polarity_info, _clamp_result_to_image, _merge_close_runs, _remove_ruling_lines, _runs, _text_mask_for_refinement, _tight_rect, _zero_edge_filler_bands)
from seg_refine import _tight_piece
from seg_lines import (line_alignment_primary, _filter_isolated_yolo_noise, _group_yolo_char_rects_into_lines)
from seg_chars import _split_chars_in_region
from seg_layout import (_filter_layout, _augment_with_model_hierarchy)
from seg_doublecol import (drop_duplicate_fragment_lines, split_double_column_lines, _merge_adjacent_line_fragments)
from seg_candidates import get_char_candidates
from seg_trace import _log, append_debug_trace
from seg_imaging import (_text_mask_for_refinement, _imread)
from seg_refine import expand_line_rect_to_neighbor_ink
from seg_models import _predict_detection_layer
from seg_trace import _log
from seg_imaging import (_to_block, _runs)
from seg_refine import _tight_piece
from seg_trace import _log, _exception_summary
from seg_imaging import _imread
from seg_models import (_get_custom_model, _YOLO_PREDICT_LOCK)


from seg_trace import (  # noqa: E402,F401
    _TRACE_DEFAULT,
    _DEBUG_TRACE,
    _trace_list,
    _append_trace,
    _log,
    begin_debug_trace,
    debug_trace_snapshot,
    append_debug_trace,
    _exception_summary,
)

from seg_models import (  # noqa: E402,F401
    _YOLO_CHAR_MODEL,
    _YOLO_CHAR_PATH,
    _YOLO_ERROR,
    _OPENCC_ERROR,
    _YOLO_PREDICT_LOCK,
    _import_opencc,
    _preload_torch_for_windows,
    _default_yolo_model_path,
    _load_yolo_char_model,
    _yolo_diagnostics,
    _CUSTOM_MODELS,
    _MODELS_DISABLED,
    _MODEL_TEST,
    _MODEL_TEST_CACHE,
    _MODEL_OVERRIDES,
    set_models_disabled,
    _override_for,
    set_model_test,
    _load_test_model,
    _get_custom_model,
    reset_custom_models,
    record_yolo_error,
    current_yolo_error,
    _predict_detection_layer,
)

from seg_imaging import (  # noqa: E402,F401
    _imread,
    _runs,
    _merge_close_runs,
    _merge_fragmentary_strips,
    _is_edge_ruling_fragment,
    _remove_ruling_lines,
    _tight_rect,
    _to_block,
    _TEXT_MASK_CACHE,
    _MASK_POLARITY_INFO,
    mask_polarity_info,
    _zero_edge_filler_bands,
    _clamp_rect_to_image,
    _clamp_result_to_image,
    _text_mask_for_refinement,
)

from seg_refine import (  # noqa: E402,F401
    _estimate_vertical_grid_count,
    _choose_expected_count,
    _expand_rect_for_punctuation,
    expand_line_rect_to_neighbor_ink,
    _PUNCT_SPLIT_TALL_RATIO,
    _PUNCT_SPLIT_MIN_MARGIN,
    _PUNCT_SPLIT_GIANT_RATIO,
    _PUNCT_SPLIT_PUNCT_RATIO,
    _PUNCT_SPLIT_MAIN_LO,
    _PUNCT_SPLIT_MAIN_HI,
    _PUNCT_SPLIT_GLYPH_SPAN,
    _PUNCT_SPLIT_GLYPH_RUN_MAX,
    _PUNCT_SPLIT_MAX_PASSES,
    _tight_piece,
    _run_ink_width,
    _split_tall_box_by_ink_runs,
    _split_giant_box_by_runs,
    _merge_adjacent_punct_fragments,
    split_punct_merged_boxes,
)

from seg_chars import (  # noqa: E402,F401
    _split_chars_in_region,
    _split_by_equal_division,
    _split_by_layout_grid,
    _slot_tight_rect,
    make_kraken_char_splitter,
    _split_chars_by_y_projection,
)

from seg_lines import (  # noqa: E402,F401
    line_alignment_primary,
    _vertical_line_strips,
    _resolve_overlapping_line_boxes,
    _split_char_rect_at_strip_seams,
    _filter_isolated_yolo_noise,
    _group_yolo_char_rects_into_lines,
)

from seg_pipeline import (  # noqa: E402,F401
    _segment_with_yolo_chars,
    _segment_with_opencv,
    _apply_sort_and_renumber,
    segment_image_with_metadata,
)

from seg_layout import (  # noqa: E402,F401
    REGION_BODY_LABELS,
    REGION_EXCLUDED_LABELS,
    _filter_layout,
    _rect_of,
    _set_rect,
    _clamp_rect_into,
    _region_containing,
    _region_overlap_conflicts,
    _enforce_hierarchy_containment,
    _augment_with_model_hierarchy,
    detect_main_regions,
    build_body_gated_image,
    dispose_body_gated_image,
    regions_from_boxes,
    filter_result_to_region,
    extend_lines_to_region_ink,
    segment_lines_in_region,
)

from seg_doublecol import (  # noqa: E402,F401
    _char_body_blocks,
    _double_column_sub_rects,
    double_column_roles,
    _filter_spurious_double_column_parts,
    split_double_column_lines,
    drop_duplicate_fragment_lines,
    _merge_adjacent_line_fragments,
)

from seg_candidates import (  # noqa: E402,F401
    get_char_candidates,
    _cls_name_to_char,
    _char_cls_candidates,
)
