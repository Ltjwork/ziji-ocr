# 本文件是门面（facade）：实现已按职责拆分到 api_base, api_segment, api_page, api_export, api_recognize, api_train, api_verify, api_kraken, api_region, api_table，此处 re-export 保持既有 import 面不变。
import base64
import functools
import os
import sys
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import List, Optional
import cv2
import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import kraken_bridge
import segmenter
import char_cluster
import char_verify
import daemon_sizing
import page_dewarp
from imaging import imwrite_unicode
from layout_refinement import normalize_layout
from segmenter import (
    begin_debug_trace,
    debug_trace_snapshot,
    segment_image_with_metadata,
    segment_lines_in_region,
    get_char_candidates,
    make_kraken_char_splitter,
    mask_polarity_info,
    split_punct_merged_boxes,
    _imread,
    _text_mask_for_refinement,
    _split_chars_in_region,
    expand_line_rect_to_neighbor_ink,
)
from api_base import (Block, _acquire_recognition_slot, app, _gated_recognition, _release_recognition_slot)
from api_base import app, _gated_recognition
from api_base import (_acquire_recognition_slot, app, _gated_recognition, _release_recognition_slot)
from api_base import Block, app, _gated_recognition
from api_base import app, _gated_recognition
from api_base import app, _gated_recognition
from api_base import app, _gated_recognition







from api_base import (  # noqa: E402,F401
    BACKEND_BUILD,
    install_console_log,
    lifespan,
    app,
    _recognition_slots,
    _recognition_exclusive,
    _EXCLUSIVE_DRAIN_TIMEOUT,
    _acquire_recognition_slot,
    _release_recognition_slot,
    _gated_recognition,
    Block,
    health,
    _process_stats_lock,
    _process_stats_cache,
    _PROCESS_STATS_TTL,
    _nvidia_vram_bytes,
    _collect_process_stats,
    process_stats,
)

from api_segment import (  # noqa: E402,F401
    SegmentRequest,
    _draw_debug_overlay,
    _draw_mask_overlay,
    CropRequest,
    CharBox,
    SegmentRegionRequest,
    SegmentLinesInRegionRequest,
    segment,
    crop,
    segment_region,
    segment_lines_in_region_endpoint,
    DebugCharSplitLine,
    DebugCharSplitRequest,
    _cleanup_debug_images,
    debug_char_split,
)

from api_page import (  # noqa: E402,F401
    PdfToImagesRequest,
    TransformPageRequest,
    transform_page,
    SplitPageRequest,
    split_page,
    DetectPageQuadRequest,
    detect_page_quad,
    deskew_sizing,
    DewarpPageRequest,
    dewarp_page,
    _pdf_page_diag,
    pdf_to_images,
)

from api_export import (  # noqa: E402,F401
    ExcalidrawExportRequest,
    export_excalidraw,
    CrnnLineItem,
    ExportCrnnRequest,
    PackLmdbRequest,
    export_crnn,
    pack_lmdb,
)

from api_recognize import (  # noqa: E402,F401
    CharCandidatesRequest,
    RecognizeCharRequest,
    CharCandidatesBatchRequest,
    char_candidates,
    recognize_char,
    char_candidates_batch,
    CharClustersRequest,
    char_clusters,
    CharClustersPage,
    CharClustersBatchRequest,
    char_clusters_batch,
    CharThumbItem,
    CharThumbnailsRequest,
    _THUMB_IMG_CACHE,
    char_thumbnails,
    LineThumbBox,
    _LineThumbItemFull,
    LineThumbnailsWithBoxesRequest,
    line_thumbnails,
    LineInkBox,
    LineInkItem,
    LineInkRequest,
    LayoutAnalyzeLine,
    LayoutAnalyzeRequest,
    analyze_layout,
    _structural_ink,
    _core_ink,
    line_ink,
    RecognitionEvalRequest,
    recognition_eval,
    recognition_eval_set,
)

from api_region import (  # noqa: E402,F401
    RegionPrelabelRequest,
    RegionRefineItem,
    RegionRefineRequest,
    PagePrelabelImageRequest,
    region_prelabel_endpoint,
    region_refine,
    page_prelabel_image,
)

from api_table import (  # noqa: E402,F401
    DetectTablesRequest,
    RecognizeTableRequest,
    detect_tables,
    recognize_table_endpoint,
)

from api_train import (  # noqa: E402,F401
    TrainDatasetsRequest,
    TrainStartRequest,
    TrainStopRequest,
    ModelActivateRequest,
    train_stats,
    train_datasets,
    train_start,
    train_status,
    train_log,
    CharClsEvaluateRequest,
    char_cls_evaluate,
    train_preflight,
    train_stop,
    models_list,
    models_activate,
    models_deactivate,
)

from api_cleanup import (  # noqa: E402,F401
    CleanupRunRequest,
    cleanup_status,
    cleanup_run,
)

from api_verify import (  # noqa: E402,F401
    VerifyCharRequest,
    VerifyCharItem,
    VerifyCharsBatchRequest,
    verify_char,
    verify_chars_batch,
    VerifyTrainDataRequest,
    VerifyTrainExportRequest,
    VerifyTrainStartRequest,
    VerifyTrainStopRequest,
    VerifyTrainActivateRequest,
    VerifyTemplatesUpdateRequest,
    VerifyTemplatesClearRequest,
    verify_train_data,
    verify_train_export,
    verify_train_start,
    verify_train_status,
    verify_train_stop,
    verify_train_activate,
    verify_train_deactivate,
    verify_templates_update,
    verify_templates_clear,
)

from api_kraken import (  # noqa: E402,F401
    KrakenExportRequest,
    KrakenTrainStartRequest,
    KrakenStopRequest,
    KrakenActivateRequest,
    kraken_export,
    kraken_train_start,
    kraken_status,
    kraken_data,
    kraken_stop,
    kraken_activate,
    kraken_deactivate,
)

from api_paddle import (  # noqa: E402,F401
    PaddleProbeRequest,
    PaddleDownloadRequest,
    PaddlePoolResizeRequest,
    paddle_models,
    paddle_status,
    paddle_probe,
    paddle_download,
    paddle_pool_resize,
)

from api_bench import (  # noqa: E402,F401
    BenchPredItem,
    BenchEvalRequest,
    bench_dynasty_cases,
    bench_dynasty_eval,
    bench_dynasty_runs,
)

from api_pack import (  # noqa: E402,F401
    ModelPackRequest,
    models_pack,
)


if __name__ == "__main__":
    import socket
    import uvicorn

    # 先落盘再干活：端口选择/模型加载等启动过程也要进独立日志窗口。
    # 大日志轮转必须发生在打开文件之前（Windows 不允许改名打开中的
    # 文件），所以它先于 install_console_log 执行。
    import cleanup_service

    _rot = cleanup_service.rotate_big_logs()
    install_console_log(
        Path(__file__).resolve().parent / "logs" / "service_console.log"
    )
    _start_clean = cleanup_service.startup_cleanup()
    _freed_mb = (
        _rot.get("freed", 0)
        + (_start_clean.get("dumps") or {}).get("freed", 0)
        + (_start_clean.get("old_logs") or {}).get("freed", 0)
    ) / (1 << 20)
    if _rot.get("rotated") or _freed_mb >= 1:
        print(
            f"[cleanup] 启动清理：轮转 {_rot.get('rotated') or []}，"
            f"回收 {_freed_mb:.0f}MB（自动策略见 /cleanup/status）",
            flush=True,
        )

    # 崩溃排查诊断：大 PDF 导入时后端曾出现"无任何 traceback、进程直接
    # 消失"的硬崩溃（service_console.log 停在中间页）。两个挂钩：
    # 1) faulthandler 把原生层致命错误（Windows access violation、abort）
    #    当场的全线程 Python 栈落盘 faulthandler.log——无 traceback 崩溃
    #    的现场就在这里；
    # 2) dump_traceback_later 每分钟把全线程栈追加到同一文件，区分"进程
    #    卡死在某次调用（还能看到栈）"与"进程被外部杀掉（栈停在最后
    #    一次正常位置）"。排查结束后可把周期调大或移除。
    import faulthandler
    import platform

    diag_path = Path(__file__).resolve().parent / "logs" / "faulthandler.log"
    diag_path.parent.mkdir(parents=True, exist_ok=True)
    _diag_handle = open(diag_path, "a", encoding="utf-8", errors="replace")
    _diag_handle.write(
        f"\n===== 诊断挂钩 {time.strftime('%Y-%m-%d %H:%M:%S')} "
        f"pid={os.getpid()} python={platform.python_version()} =====\n"
    )
    _diag_handle.flush()
    faulthandler.enable(file=_diag_handle, all_threads=True)
    faulthandler.dump_traceback_later(60, repeat=True, file=_diag_handle)
    print(f"[diag] faulthandler 已开启 -> {diag_path}", flush=True)
    try:
        import psutil

        vm = psutil.virtual_memory()
        print(
            f"[diag] mem total={vm.total / (1 << 30):.0f}GB "
            f"available={vm.available / (1 << 30):.1f}GB "
            f"cpu={psutil.cpu_count(logical=True)}",
            flush=True,
        )
    except Exception:
        pass

    # Windows 上 Hyper-V/WSL/Docker 的 winnat 会在开机时随机保留端口段
    # （netsh interface ipv4 show excludedportrange protocol=tcp），固定
    # 端口落进保留段时 bind 报 Errno 13（访问权限不允许），任何程序都
    # 无法监听。保留段可能连续数百个端口（实测有机器 8482-9181 整段、
    # 甚至 8672-9371 六段连排把 8765-9264 全部覆盖），所以基准端口选
    # 在远离保留段常见区间的 1288，并从它起连续探测 500 个候选；整段
    # 都不可绑时让系统分配空闲端口（bind(0)）——实际端口写入
    # service_port.txt 供 Flutter 端跟随，服务可用性不依赖固定端口段。
    chosen_port = None
    for candidate in range(1288, 1288 + 500):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.bind(("127.0.0.1", candidate))
            chosen_port = candidate
            break
        except OSError:
            continue
    if chosen_port is None:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.bind(("127.0.0.1", 0))
                chosen_port = int(probe.getsockname()[1])
            print(
                "[service] 1288-1787 整段不可绑（winnat 端口保留？详见 "
                "netsh interface ipv4 show excludedportrange），"
                f"改用系统分配端口 {chosen_port}",
                flush=True,
            )
        except OSError as exc:
            raise SystemExit(f"[service] no available port: {exc}")

    port_file = Path(__file__).resolve().parent / "service_port.txt"
    port_file.write_text(str(chosen_port), encoding="utf-8")
    print(
        f"[service] listening on 127.0.0.1:{chosen_port} "
        f"(port written to {port_file})",
        flush=True,
    )
    uvicorn.run(app, host="127.0.0.1", port=chosen_port)
