# -*- coding: utf-8 -*-
"""PDF 转图任务化测试：start/status 状态机、skip_existing 断点续跑
（跳过已完成页、空文件与 .part 半截文件不算完成）、失败页重试。"""
import os
import time

import pytest

import api_page


def _make_pdf(path, pages=3):
    """用 PyMuPDF 现场生成多页 PDF（paddle 环境自带）。"""
    import fitz

    doc = fitz.open()
    for i in range(pages):
        page = doc.new_page(width=200, height=300)
        page.insert_text((20, 50 + 20 * i), f"page {i + 1}")
    doc.save(path)
    doc.close()
    return path


def _start_and_wait(pdf_path, out_dir, skip_existing=False, timeout=60.0):
    req = api_page.PdfToImagesRequest(
        pdf_path=pdf_path, output_dir=out_dir, skip_existing=skip_existing)
    started = api_page.pdf_to_images(req)
    task_id = started["task_id"]
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = api_page.pdf_to_images_status(task_id=task_id)
        if status["status"] != "running":
            return status
        time.sleep(0.05)
    raise AssertionError("转换超时未完成")


def test_full_conversion_status_and_files(tmp_path):
    pdf = _make_pdf(str(tmp_path / "book.pdf"), pages=3)
    out_dir = str(tmp_path / "pages")
    status = _start_and_wait(pdf, out_dir)
    assert status["status"] == "done"
    assert status["current"] == 3 and status["total"] == 3
    assert len(status["images"]) == 3
    for i in range(3):
        assert os.path.getsize(os.path.join(out_dir, f"page_{i:03d}.png")) > 0


def test_skip_existing_resume_only_renders_missing(tmp_path):
    pdf = _make_pdf(str(tmp_path / "book.pdf"), pages=3)
    out_dir = str(tmp_path / "pages")
    _start_and_wait(pdf, out_dir)
    # 模拟"第 2 页失败"：删掉 page_001，把 page_000 的 mtime 拨旧作指纹
    os.unlink(os.path.join(out_dir, "page_001.png"))
    page0 = os.path.join(out_dir, "page_000.png")
    old = time.time() - 3600
    os.utime(page0, (old, old))

    status = _start_and_wait(pdf, out_dir, skip_existing=True)
    assert status["status"] == "done" and status["current"] == 3
    # page_000 未被重渲染（mtime 仍是拨旧的值），page_001 已补齐
    assert os.path.getmtime(page0) == old
    assert os.path.getsize(os.path.join(out_dir, "page_001.png")) > 0


def test_empty_png_and_stale_part_not_treated_as_done(tmp_path):
    pdf = _make_pdf(str(tmp_path / "book.pdf"), pages=2)
    out_dir = str(tmp_path / "pages")
    os.makedirs(out_dir)
    # 0 字节的"已完成页"与上次中断的半截文件都不算完成
    open(os.path.join(out_dir, "page_000.png"), "wb").close()
    open(os.path.join(out_dir, "page_001.part.png"), "wb").close()

    status = _start_and_wait(pdf, out_dir, skip_existing=True)
    assert status["status"] == "done" and status["current"] == 2
    assert os.path.getsize(os.path.join(out_dir, "page_000.png")) > 0
    assert not os.path.exists(os.path.join(out_dir, "page_001.part.png"))


def test_status_unknown_task_404():
    from fastapi import HTTPException

    with pytest.raises(HTTPException) as exc:
        api_page.pdf_to_images_status(task_id="no_such_task")
    assert exc.value.status_code == 404
