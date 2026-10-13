# -*- coding: utf-8 -*-
"""页面几何域路由（从 main.py 拆出）：/transform_page /split_page /detect_page_quad /deskew_sizing /dewarp_page /pdf_to_images。"""
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
import page_stitch
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
from api_base import app, _gated_recognition





class PdfToImagesRequest(BaseModel):
    pdf_path: str
    output_dir: str
    dpi: int = 200
    # 断点续跑：跳过输出目录里已转换完成的页（应用退出后重新发起转换时，
    # 客户端带 true——已渲染的页不重复渲染）
    skip_existing: bool = False




class TransformPageRequest(BaseModel):
    image_path: str
    op: str  # rotate_cw | rotate_ccw | flip_h | flip_v




@app.post("/transform_page")
def transform_page(req: TransformPageRequest):
    """书页图像旋转/镜像（就地改写 PNG），返回变换前后尺寸。

    像素变换用 cv2；标注几何由编辑器端按同一映射同步变换（页框/行框/
    字框逐层换算，无需重新识别即可保持对齐）。
    """
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    img = _imread(req.image_path)
    if img is None:
        raise HTTPException(status_code=400, detail="cannot read image")
    ops = {
        "rotate_cw": lambda a: cv2.rotate(a, cv2.ROTATE_90_CLOCKWISE),
        "rotate_ccw": lambda a: cv2.rotate(a, cv2.ROTATE_90_COUNTERCLOCKWISE),
        "flip_h": lambda a: cv2.flip(a, 1),  # 左右镜像
        "flip_v": lambda a: cv2.flip(a, 0),  # 上下镜像
    }
    fn = ops.get(req.op)
    if fn is None:
        raise HTTPException(status_code=400, detail=f"unknown op: {req.op}")
    old_h, old_w = img.shape[:2]
    out = fn(img)
    ok, buf = cv2.imencode(".png", out)
    if not ok:
        raise HTTPException(status_code=500, detail="encode failed")
    try:
        buf.tofile(req.image_path)  # 覆盖原文件（cv2 不支持中文路径）
    except OSError as exc:
        raise HTTPException(status_code=500, detail=f"write failed: {exc}")
    print(
        f"[transform_page] op={req.op} {old_w}x{old_h} -> "
        f"{out.shape[1]}x{out.shape[0]} path={req.image_path}",
        flush=True,
    )
    return {
        "old_w": old_w,
        "old_h": old_h,
        "new_w": int(out.shape[1]),
        "new_h": int(out.shape[0]),
    }




class SplitPageRequest(BaseModel):
    image_path: str
    spine_ratio: float  # 中缝位置，相对本页宽度的比例（0~1）
    left_path: Optional[str] = None  # 左半页输出路径，None = 不输出左页
    right_path: Optional[str] = None  # 右半页输出路径，None = 不输出右页




@app.post("/split_page")
def split_page(req: SplitPageRequest):
    """把一张左右跨页扫描图按中缝切成两页 PNG（跨页拆分功能的图像步骤）。

    坐标换算与文件写入都在后端做：spine_ratio 按本页实际宽度取整成像素
    x（页面尺寸不一时各页按同一比例下刀），输出路径由调用方给定，目录
    自动创建。写盘走 imencode + tofile（与 _imread 对称，中文路径安全）。
    """
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    img = _imread(req.image_path)
    if img is None:
        raise HTTPException(status_code=400, detail="cannot read image")
    if not 0.0 <= req.spine_ratio <= 1.0:
        raise HTTPException(status_code=400, detail="spine_ratio out of range")

    h, w = img.shape[:2]
    spine_x = max(1, min(w - 1, int(round(req.spine_ratio * w))))
    halves = [
        (req.left_path, img[:, :spine_x]),
        (req.right_path, img[:, spine_x:]),
    ]
    widths: dict[str, int] = {}
    for side, (out_path, crop) in zip(("left_w", "right_w"), halves):
        widths[side] = int(crop.shape[1])
        if out_path is None or crop.shape[1] <= 0:
            continue
        out_dir = os.path.dirname(out_path)
        if out_dir:
            try:
                os.makedirs(out_dir, exist_ok=True)
            except OSError as exc:
                raise HTTPException(
                    status_code=500, detail=f"mkdir failed: {exc}"
                )
        ok, buf = cv2.imencode(".png", crop)
        if not ok:
            raise HTTPException(status_code=500, detail="encode failed")
        try:
            buf.tofile(out_path)
        except OSError as exc:
            raise HTTPException(status_code=500, detail=f"write failed: {exc}")

    print(
        f"[split_page] {w}x{h} spine_x={spine_x} "
        f"left={req.left_path} right={req.right_path}",
        flush=True,
    )
    return {
        "w": w,
        "h": h,
        "spine_x": spine_x,
        "left_w": widths["left_w"],
        "right_w": widths["right_w"],
    }




class DetectPageQuadRequest(BaseModel):
    image_path: str




@app.post("/detect_page_quad")
def detect_page_quad(req: DetectPageQuadRequest):
    """智能检测书页四角裁切点（校对摆正的"自动分析"步骤）。

    返回原图像素坐标下 TL,TR,BR,BL 四点；needs_warp=False 表示页面
    已贴满全图且无弯边，批量模式可直接跳过该页。算法在 page_dewarp。
    """
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    img = _imread(req.image_path)
    if img is None:
        raise HTTPException(status_code=400, detail="cannot read image")
    h, w = img.shape[:2]
    points, method, trace = page_dewarp.detect_page_quad(img)
    needs_warp = page_dewarp.quad_needs_warp(w, h, points)
    print(
        f"[detect_page_quad] {w}x{h} method={method} needs_warp={needs_warp} "
        f"path={req.image_path}",
        flush=True,
    )
    return {
        "w": w,
        "h": h,
        "points": points,
        "method": method,
        "needs_warp": needs_warp,
        "trace": trace,
    }




@app.get("/deskew_sizing")
def deskew_sizing():
    """批量摆正的并行页数决策：按 CPU 物理核与可用内存算 worker 数。

    /dewarp_page 与 /detect_page_quad 是纯 CPU OpenCV（大运算释放
    GIL），FastAPI 同步端点天然进线程池——前端并行发 N 个请求即可真
    并行。N 由 daemon_sizing.decide_dewarp_workers 决策并给出理由
    （环境变量 OCR_DEWARP_WORKERS 可覆盖），前端按此开 worker 池。"""
    cpu_phys = daemon_sizing.cpu_physical_count()
    ram_available = daemon_sizing.available_ram()
    workers, why = daemon_sizing.decide_dewarp_workers(cpu_phys, ram_available)
    print(
        f"[deskew_sizing] workers={workers} cpu_phys={cpu_phys} "
        f"ram_free={ram_available // daemon_sizing.MB}MB ({why})",
        flush=True,
    )
    return {
        "workers": workers,
        "reason": why,
        "cpu_physical": cpu_phys,
        "ram_available": ram_available,
    }


class StitchPagesRequest(BaseModel):
    image_a: str  # 前段（上下拼的上页 / 左右拼的左页）
    image_b: str  # 后段（下页 / 右页）
    direction: str = "v"  # 'v' 上下拼 | 'h' 左右拼
    auto_trim: bool = True   # 自动裁掉接缝侧空白（按墨迹投影）
    auto_align: bool = True  # 自动对齐（错位/重复扫描重叠）
    # 手动微调（优先于自动）：重叠像素（B 叠进 A 的量）、垂直于拼接方向
    # 的错位像素（正 = B 沿坐标轴正向平移）。
    overlap: Optional[int] = None
    offset: Optional[int] = None
    seam_fade: int = 24  # 重叠带内的羽化宽度 px（0=硬拼）
    preview: bool = False
    preview_max_px: int = 1400
    out_path: Optional[str] = None  # preview=True 时忽略；必填写盘路径


@app.post("/stitch_pages")
def stitch_pages(req: StitchPagesRequest):
    """两页智能拼接（连续表格/图片拼成正常一页）：裁接缝空白 → 投影
    相关对齐错位/重叠 → 重叠带羽化。详见 page_stitch.py。preview 模式
    返回 base64 小图与 trace；否则写 out_path。
    """
    for path in (req.image_a, req.image_b):
        if not os.path.exists(path):
            raise HTTPException(status_code=400, detail=f"image not found: {path}")
    if not req.preview and not req.out_path:
        raise HTTPException(status_code=400, detail="out_path required")
    a = _imread(req.image_a)
    b = _imread(req.image_b)
    if a is None or b is None:
        raise HTTPException(status_code=400, detail="cannot read image")
    if req.direction not in ("v", "h"):
        raise HTTPException(status_code=400, detail=f"unknown direction: {req.direction}")
    try:
        out, trace = page_stitch.stitch_pages(
            a, b, direction=req.direction,
            auto_trim=req.auto_trim, auto_align=req.auto_align,
            overlap=req.overlap, offset=req.offset, seam_fade=req.seam_fade,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    if req.preview:
        preview_max = max(64, min(req.preview_max_px, 4000))
        scale = min(1.0, preview_max / max(trace["out_w"], trace["out_h"]))
        if scale < 1.0:
            out = cv2.resize(
                out,
                (
                    max(1, int(round(trace["out_w"] * scale))),
                    max(1, int(round(trace["out_h"] * scale))),
                ),
                interpolation=cv2.INTER_AREA,
            )
        ok, buf = cv2.imencode(".png", out)
        if not ok:
            raise HTTPException(status_code=500, detail="encode failed")
        return {
            "image_b64": base64.b64encode(buf).decode("ascii"),
            "trace": trace,
        }

    out_dir = os.path.dirname(req.out_path)
    if out_dir:
        try:
            os.makedirs(out_dir, exist_ok=True)
        except OSError as exc:
            raise HTTPException(status_code=500, detail=f"mkdir failed: {exc}")
    ok, buf = cv2.imencode(".png", out)
    if not ok:
        raise HTTPException(status_code=500, detail="encode failed")
    try:
        buf.tofile(req.out_path)
    except OSError as exc:
        raise HTTPException(status_code=500, detail=f"write failed: {exc}")
    print(
        f"[stitch_pages] {req.image_a} + {req.image_b} ({req.direction}) -> "
        f"{req.out_path} {trace['out_w']}x{trace['out_h']} "
        f"trim=({trace['trim_a']},{trace['trim_b']}) "
        f"offset={trace['offset']}(auto={trace['offset_auto']}) "
        f"overlap={trace['overlap']}(auto={trace['overlap_auto']})",
        flush=True,
    )
    return {"out_path": req.out_path, "trace": trace}




class DewarpPageRequest(BaseModel):
    image_path: str
    # TL,TR,BR,BL 四角的原图像素坐标。
    corners: List[List[float]]
    # 边中点实际坐标（键 top/right/bottom/left）；缺省的边视为直边。
    edge_mids: Optional[dict] = None
    grayscale: bool = False  # 去色：灰度 + 分位对比度拉伸
    sharpen: bool = False    # 锐化：unsharp mask
    # 去透印：把背面/下一页透出的浅色文字压成纸白（保留深色主墨）。
    debleed: bool = False
    debleed_strength: int = 50  # 1..100，越大压得越狠
    # preview=True 时不写盘，降采样后返回 base64 PNG 供前端弹窗预览。
    preview: bool = False
    preview_max_px: int = 1000
    # 正式输出路径（preview=True 时忽略）；不传则就地改写 image_path。
    out_path: Optional[str] = None




@app.post("/dewarp_page")
def dewarp_page(req: DewarpPageRequest):
    """按裁切点把书页拉平摆正（直边走单应、弯边走 Coons patch），
    可叠加去色/锐化。写盘走 imencode + tofile（中文路径安全）。

    与 /transform_page 不同：默认输出到 out_path 新文件（保留原图），
    仅当 out_path 缺省时才就地改写 image_path。
    """
    if not os.path.exists(req.image_path):
        raise HTTPException(status_code=400, detail="image not found")
    img = _imread(req.image_path)
    if img is None:
        raise HTTPException(status_code=400, detail="cannot read image")
    try:
        out, out_w, out_h = page_dewarp.dewarp_page(img, req.corners, req.edge_mids)
        out = page_dewarp.enhance_page(
            out, req.grayscale, req.sharpen,
            debleed=req.debleed, debleed_strength=req.debleed_strength,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    if req.preview:
        preview_max = max(64, min(req.preview_max_px, 4000))
        scale = min(1.0, preview_max / max(out_w, out_h))
        if scale < 1.0:
            out = cv2.resize(
                out,
                (max(1, int(round(out_w * scale))), max(1, int(round(out_h * scale)))),
                interpolation=cv2.INTER_AREA,
            )
        ok, buf = cv2.imencode(".png", out)
        if not ok:
            raise HTTPException(status_code=500, detail="encode failed")
        return {
            "image_b64": base64.b64encode(buf).decode("ascii"),
            "w": int(out_w),
            "h": int(out_h),
        }

    target = req.out_path or req.image_path
    out_dir = os.path.dirname(target)
    if out_dir:
        try:
            os.makedirs(out_dir, exist_ok=True)
        except OSError as exc:
            raise HTTPException(status_code=500, detail=f"mkdir failed: {exc}")
    ok, buf = cv2.imencode(".png", out)
    if not ok:
        raise HTTPException(status_code=500, detail="encode failed")
    try:
        buf.tofile(target)
    except OSError as exc:
        raise HTTPException(status_code=500, detail=f"write failed: {exc}")
    print(
        f"[dewarp_page] {req.image_path} -> {target} {out_w}x{out_h} "
        f"gray={req.grayscale} sharpen={req.sharpen} "
        f"debleed={req.debleed}@{req.debleed_strength}",
        flush=True,
    )
    return {"w": int(out_w), "h": int(out_h), "out_path": target}




def _pdf_page_diag(page, pixmap, page_no: int) -> tuple[str, str]:
    """PDF→PNG 逐页诊断：日志行后缀与黑边告警行（都可能为空串）。

    定位"导入的页面图自带一大圈黑边"问题：① 媒介框(MediaBox)≠裁切框
    (CropBox)、页面旋转——盒径不一致时渲染范围可能与看图软件不同；
    ② 渲染结果里的最大近黑暗块（占比 ≥1% 才记录，≥30% 出 ⚠ 独立行）
    ——黑边/黑底一旦进了 PNG，之后会被智能边框当成"纸"。全部只记录
    不改行为。"""
    bits: List[str] = []
    try:
        mb = page.mediabox
        cb = page.cropbox
        if mb is not None:
            bits.append(f"mediabox={mb.width:.0f}x{mb.height:.0f}")
        if (
            mb is not None
            and cb is not None
            and (
                abs(cb.width - mb.width) > 0.5
                or abs(cb.height - mb.height) > 0.5
                or abs(cb.x0 - mb.x0) > 0.5
                or abs(cb.y0 - mb.y0) > 0.5
            )
        ):
            bits.append(
                f"cropbox={cb.width:.0f}x{cb.height:.0f}"
                f"+{cb.x0:.0f},{cb.y0:.0f}（≠媒介框，注意渲染范围）"
            )
        if page.rotation:
            bits.append(f"rot={page.rotation}")
    except Exception:
        pass

    warn = ""
    try:
        stats = page_dewarp.dark_region_stats(
            page_dewarp.pixmap_rgb_array(pixmap)
        )
        if stats:
            bx, by, bw, bh = stats["bbox"]
            bits.append(
                f"dark_block={stats['share'] * 100:.0f}%"
                f"@({bx},{by})+{bw}x{bh} luma={stats['luma']:.0f}"
            )
            if stats["share"] >= 0.30:
                warn = (
                    f"[pdf_to_images] ⚠ 第 {page_no} 页渲染结果有 "
                    f"{stats['share'] * 100:.0f}% 的近黑暗块"
                    f"（bbox {bw}x{bh}@({bx},{by})，均亮 {stats['luma']:.0f}）"
                    "——该页会带着黑边/黑底进入后续流程并被智能边框当成"
                    "「纸」，若 PDF 原页无黑底请检查此页的盒径/对象"
                )
    except Exception:
        pass
    return (" " + " ".join(bits)) if bits else "", warn




@app.post("/pdf_to_images")
def pdf_to_images(req: PdfToImagesRequest):
    """PDF 转页图（任务化）：立即返回 task_id 与总页数，转换在后台线程
    逐页进行，进度经 GET /pdf_to_images/status 轮询。

    [skip_existing]=true 时跳过输出目录中已存在的 page_NNN.png（应用退出
    后的断点续跑：客户端导入时先落盘书记录，重启后带 true 重新发起，
    已渲染页不重复渲染）。每页先写 page_NNN.part.png 再原子改名——中途
    退出的半截文件不会被误判为已完成页。"""
    if not os.path.exists(req.pdf_path):
        raise HTTPException(status_code=400, detail="pdf not found")

    try:
        import fitz  # PyMuPDF
    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=(
                f"PyMuPDF 不可用（{exc}）。请在应用的环境准备页对"
                "「识别服务环境」点击『修复 PDF 组件』，完成后重启应用再试。"
            ),
        )

    try:
        doc = fitz.open(req.pdf_path)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"cannot open pdf: {exc}")
    total = doc.page_count
    doc.close()
    if total <= 0:
        raise HTTPException(status_code=400, detail="pdf has no pages")

    task_id = f"pdf_{int(time.time() * 1000)}"
    with _pdf_tasks_lock:
        _pdf_task_prune_locked()
        _pdf_tasks[task_id] = {
            "status": "running",
            "current": 0,
            "total": total,
            "images": [],
            "error": None,
            "started": time.time(),
            "ended": None,
        }
    threading.Thread(
        target=_run_pdf_task,
        args=(task_id, req.pdf_path, req.output_dir, req.dpi,
              req.skip_existing),
        daemon=True,
    ).start()
    return {"task_id": task_id, "total": total}




@app.get("/pdf_to_images/status")
def pdf_to_images_status(task_id: str):
    with _pdf_tasks_lock:
        task = _pdf_tasks.get(task_id)
        if task is None:
            raise HTTPException(
                status_code=404,
                detail="转图任务不存在（后端可能重启过，请重新发起导入）")
        return {
            "task_id": task_id,
            "status": task["status"],
            "current": task["current"],
            "total": task["total"],
            "images": list(task["images"]),
            "error": task["error"],
        }




# 任务表（内存态）：完成/失败的任务保留 1 小时供查询，新任务启动时清理
_pdf_tasks: dict = {}
_pdf_tasks_lock = threading.Lock()
_PDF_TASK_TTL = 3600.0


def _pdf_task_prune_locked():
    now = time.time()
    stale = [
        tid
        for tid, t in _pdf_tasks.items()
        if t.get("ended") and now - t["ended"] > _PDF_TASK_TTL
    ]
    for tid in stale:
        _pdf_tasks.pop(tid, None)




def _run_pdf_task(
    task_id: str, pdf_path: str, output_dir: str, dpi: int, skip_existing: bool
) -> None:
    import traceback

    with _pdf_tasks_lock:
        task = _pdf_tasks.get(task_id)
    if task is None:
        return

    def _fail(message: str) -> None:
        with _pdf_tasks_lock:
            task["status"] = "failed"
            task["error"] = message
            task["ended"] = time.time()
        print(f"[pdf_to_images] task {task_id} FAILED: {message}", flush=True)

    try:
        import fitz
    except Exception as exc:
        _fail(f"PyMuPDF 不可用: {exc}")
        return

    try:
        doc = fitz.open(pdf_path)
    except Exception as exc:
        _fail(f"cannot open pdf: {exc}")
        return

    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    # 清理上次中断留下的半截文件（原子写的临时名），它们不是已完成页
    for stale_part in out_dir.glob("page_*.part.png"):
        try:
            stale_part.unlink()
        except OSError:
            pass

    zoom = dpi / 72.0
    matrix = fitz.Matrix(zoom, zoom)

    # 大 PDF（数百 MB/数百页）导入时两端曾一起无 traceback 消失：逐页记录
    # 渲染/落盘耗时与内存足迹（进程 RSS + 系统可用内存），配合启动时挂的
    # faulthandler 定位是哪一页、什么资源状态下出的事。
    def _mem_line() -> str:
        try:
            import psutil

            proc = psutil.Process(os.getpid())
            vm = psutil.virtual_memory()
            return (
                f"rss={proc.memory_info().rss / (1 << 30):.2f}GB "
                f"sys_avail={vm.available / (1 << 30):.1f}GB"
            )
        except Exception:
            return "rss=? sys_avail=?"

    t_start = time.perf_counter()
    try:
        pdf_mb = os.path.getsize(pdf_path) / (1 << 20)
    except OSError:
        pdf_mb = -1
    print(
        f"[pdf_to_images] task {task_id} start pages={doc.page_count} "
        f"dpi={dpi} skip_existing={skip_existing} pdf={pdf_mb:.0f}MB "
        f"{_mem_line()}",
        flush=True,
    )

    images: List[str] = []
    warned_pages = 0
    try:
        for i in range(doc.page_count):
            filename = f"page_{i:03d}.png"
            out_path = str(out_dir / filename)
            part_path = str(out_dir / f"page_{i:03d}.part.png")
            if skip_existing and os.path.isfile(out_path) and os.path.getsize(out_path) > 0:
                images.append(out_path)
                with _pdf_tasks_lock:
                    task["current"] = i + 1
                continue
            page_t0 = time.perf_counter()
            try:
                page = doc.load_page(i)
                pixmap = page.get_pixmap(matrix=matrix, alpha=False)
                render_s = time.perf_counter() - page_t0
                # 原子写：半截 part 文件不会被续跑误判为已完成页
                pixmap.save(part_path)
                os.replace(part_path, out_path)
                diag, warn = _pdf_page_diag(page, pixmap, i + 1)
            except Exception as exc:
                # Python 层异常（如磁盘满/解码失败）：任务置 failed 带页号，
                # 已成功的页留盘——续跑（skip_existing）只重试失败页。
                try:
                    os.unlink(part_path)
                except OSError:
                    pass
                print(
                    f"[pdf_to_images] task {task_id} FAILED at page "
                    f"{i + 1}/{doc.page_count} ({_mem_line()})",
                    flush=True,
                )
                traceback.print_exc()
                _fail(f"第 {i + 1} 页渲染失败: {exc}")
                return
            images.append(out_path)
            with _pdf_tasks_lock:
                task["current"] = i + 1
            print(
                f"[pdf_to_images] page {i + 1}/{doc.page_count} "
                f"{pixmap.width}x{pixmap.height}px -> {out_path} "
                f"render={render_s:.2f}s "
                f"total={time.perf_counter() - page_t0:.2f}s {_mem_line()}"
                f"{diag}",
                flush=True,
            )
            if warn:
                warned_pages += 1
                print(warn, flush=True)
    finally:
        doc.close()
    with _pdf_tasks_lock:
        task["images"] = images
        task["status"] = "done"
        task["ended"] = time.time()
    print(
        f"[pdf_to_images] task {task_id} done count={len(images)} "
        f"warned_pages={warned_pages} "
        f"elapsed={time.perf_counter() - t_start:.1f}s {_mem_line()}",
        flush=True,
    )
