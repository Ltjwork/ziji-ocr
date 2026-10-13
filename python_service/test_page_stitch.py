# -*- coding: utf-8 -*-
"""page_stitch：两页智能拼接（裁空白/错位对齐/重复重叠/羽化/手动微调）。"""
import base64

import cv2
import numpy as np
import pytest

import page_stitch


def _page(w, h, blocks=(), bg=245):
    """白纸页 + 墨块 [(x, y, bw, bh)]。"""
    img = np.full((h, w, 3), bg, np.uint8)
    for x, y, bw, bh in blocks:
        img[y:y + bh, x:x + bw] = 40
    return img


def _ink_rows(gray):
    """有墨迹的行号集合（二值化取暗部）。"""
    mask = cv2.threshold(gray, 128, 255, cv2.THRESH_BINARY_INV)[1]
    return set(np.flatnonzero(mask.sum(axis=1) >= 255))


def test_vertical_trims_seam_whitespace():
    """上下拼：接缝侧空白裁掉，两页内容首尾相连（缝两侧都是纸边余量）。

    A 内容止于第 279 行（h=320），B 内容起于第 40 行（h=320）。裁后
    总高 ≈ A(280+margin_a) + B(320-40+margin_b)，margin 各约 6px。
    """
    a = _page(200, 320, blocks=[(50, 240, 100, 40)])   # 内容 240..279
    b = _page(200, 320, blocks=[(60, 40, 100, 60)])    # 内容 40..99
    out, trace = page_stitch.stitch_pages(a, b, "v")
    assert trace["direction"] == "v"
    # 裁切量：A 裁掉 320-(280+ma) ≈ 40-ma；B 裁掉 40-mb。
    assert 30 <= trace["trim_a"] <= 40
    assert 30 <= trace["trim_b"] <= 40
    # 总高 = (320-trim_a) + (320-trim_b) - overlap(≈0)。
    assert out.shape[0] == (320 - trace["trim_a"]) + (320 - trace["trim_b"]) - trace["overlap"]
    assert 556 <= out.shape[0] <= 580
    # 接缝附近没有整片空白带：缝（y=320-trim_a 附近）两侧 ±20 行内
    # 既能看到 A 的末行墨也能看到 B 的首行墨。
    rows = _ink_rows(cv2.cvtColor(out, cv2.COLOR_BGR2GRAY))
    seam = 320 - trace["trim_a"]
    assert any(seam - 25 <= y < seam for y in rows), "缝上方应还有 A 的内容"
    assert any(seam <= y < seam + 25 for y in rows), "缝下方应紧接 B 的内容"


def test_horizontal_mirrors_vertical():
    """左右拼：与上下拼同构（宽相加、接缝列空白裁掉）。"""
    a = _page(320, 200, blocks=[(240, 50, 60, 100)])   # 内容右缘 299
    b = _page(320, 200, blocks=[(40, 60, 60, 80)])
    out, trace = page_stitch.stitch_pages(a, b, "h")
    assert trace["direction"] == "h"
    # 裁后宽 = (320-trim_a) + (320-trim_b)：A 内容止于 299 → trim_a≈14，
    # B 内容起于 40 → trim_b≈34，共 ≈592。
    assert 578 <= out.shape[1] <= 600
    assert out.shape[0] >= 200  # 高度至少容纳两页（同高时不加高）


def test_auto_offset_recovers_lateral_shift():
    """自动错位：跨页表格的竖线跨缝对齐——B 的版面整体比 A 左移 20px，
    自动对齐应把 B 右移 ≈20px（offset=+20，多条竖线的投影相关）。"""
    # A 底部与 B 顶部是同一张跨页表格的上下两段：4 条竖线跨缝连续。
    a = _page(400, 300, blocks=[(x, 150, 6, 140) for x in (55, 105, 160, 220)])
    b = _page(400, 300, blocks=[(x, 10, 6, 140) for x in (35, 85, 140, 200)])
    out, trace = page_stitch.stitch_pages(a, b, "v")
    assert trace["offset_auto"] is True
    assert abs(trace["offset"] - 20) <= 4, trace
    assert trace["align_confidence"] >= 0.45
    # 落位验证：缝两侧墨迹质心的 x 坐标一致（竖线连续）。
    seam = (300 - trace["trim_a"])
    col_above = _ink_col_of(out, range_lo=0, range_hi=seam)
    col_below = _ink_col_of(out, range_lo=seam, range_hi=out.shape[0])
    assert abs(col_above - col_below) <= 4, (col_above, col_below)


def test_auto_offset_text_columns():
    """整版竖排文字列的错位恢复（用户实测场景）：宽墨列 + 间隙的文本
    版面，原始投影被大包络主导时峰不显著（旧实现看不出变化）；梯度域
    相关以文字列边界为主，能恢复错位。加宽一列打破周期性避免等价峰。"""
    cols = (40, 90, 140, 190, 240, 300, 350, 400)
    a = _page(460, 300, blocks=[
        (x, 150, 60 if x == 300 else 30, 140) for x in cols
    ])
    b = _page(460, 300, blocks=[
        (x - 24, 10, 60 if x == 300 else 30, 140) for x in cols
    ])
    out, trace = page_stitch.stitch_pages(a, b, "v")
    assert trace["offset_auto"] is True
    assert abs(trace["offset"] - 24) <= 4, trace
    assert trace["align_confidence"] >= _gate()
    # 落位：缝两侧墨迹质心 x 一致（列连续）。
    seam = (300 - trace["trim_a"])
    col_above = _ink_col_of(out, range_lo=0, range_hi=seam)
    col_below = _ink_col_of(out, range_lo=seam, range_hi=out.shape[0])
    assert abs(col_above - col_below) <= 4, (col_above, col_below)


def _gate():
    import page_stitch
    return page_stitch._ALIGN_CONF_GATE


def _ink_col_of(img, range_lo, range_hi):
    """行区间内墨迹质心的 x 坐标（找竖线用）。"""
    seg = img[range_lo:range_hi]
    mask = cv2.threshold(cv2.cvtColor(seg, cv2.COLOR_BGR2GRAY), 128, 255, cv2.THRESH_BINARY_INV)[1]
    xs = np.flatnonzero(mask.sum(axis=0) >= 255)
    assert xs.size > 0
    # 取最靠中间的连续墨列（避开两侧边框块）：直接用所有墨列的均值。
    return float(xs.mean())


def test_manual_overlap_offset_take_precedence():
    """手动重叠/错位优先：数值原样落 trace，高度 = hA'+hB'-overlap。"""
    a = _page(200, 300, blocks=[(50, 200, 100, 80)])
    b = _page(200, 300, blocks=[(50, 20, 100, 80)])
    out, trace = page_stitch.stitch_pages(
        a, b, "v", overlap=40, offset=7,
    )
    assert trace["overlap"] == 40 and trace["overlap_auto"] is False
    assert trace["offset"] == 7 and trace["offset_auto"] is False
    ha = 300 - trace["trim_a"]
    hb = 300 - trace["trim_b"]
    assert out.shape[0] == ha + hb - 40
    assert out.shape[1] >= 200 + 7  # B 右移 7：宽度至少 207


def test_duplicate_scan_auto_overlap():
    """重复扫描重叠：B 开头复拍 A 的结尾（整块平移拷贝），自动识别出
    重叠并抵扣高度。"""
    a = _page(200, 300, blocks=[(40, 100, 120, 180), (40, 40, 20, 20)])
    # B = A 的第 240..299 行复拍 60 行 + 自己的新内容。
    dup = a[240:300].copy()
    rest = _page(200, 240, blocks=[(40, 20, 120, 200)])
    b = np.vstack([dup, rest])
    out, trace = page_stitch.stitch_pages(a, b, "v")
    assert trace["overlap_auto"] is True
    assert trace["overlap"] >= 40, trace  # 复拍 60px，识别应显著非零
    # 高度已按重叠抵扣（不超过两页裁后总高）。
    assert out.shape[0] <= (300 - trace["trim_a"]) + (b.shape[0] - trace["trim_b"])


def test_no_trim_blank_pages_and_low_signal():
    """空页（无墨迹）不裁、不抛；对齐信号太低不动（offset=0）。"""
    a = _page(200, 200)                      # 全白
    b = _page(200, 200, blocks=[(50, 50, 100, 100)])
    out, trace = page_stitch.stitch_pages(a, b, "v")
    assert trace["trim_a"] == 0  # 空页不裁
    assert trace["offset"] == 0  # 无对齐信号：宁可不错位
    assert trace["overlap"] == 0
    assert out.shape[0] == 200 + (200 - trace["trim_b"])


def test_seam_fade_blends_overlap_zone():
    """重叠带羽化：seam_fade>0 时带内为 A/B 逐行线性混合（行值严格介于
    两者之间）；seam_fade=0 时 B 直接覆盖（行值=B 原值）。"""
    # A 末尾整行墨块、B 开头整段纸——重叠带内 A 暗 B 白，混合可见。
    a = _page(200, 200, blocks=[(20, 120, 160, 74)])   # 墨到底缘 193
    b = _page(200, 200, blocks=[(20, 40, 160, 60)])    # B 开篇 34 行白
    soft, t_soft = page_stitch.stitch_pages(a, b, "v", overlap=30, seam_fade=30)
    ha = 200 - t_soft["trim_a"]
    seam = ha - 30  # B 起始行
    a_trim = a[:ha]
    b_trim = b[t_soft["trim_b"]:]
    row = seam + 4  # 带内第 4 行：alpha=(4+1)/31
    alpha = 5 / 31
    x = 100  # A 墨(40)/B 白(245) 处
    exp = 40 * (1 - alpha) + 245 * alpha
    got_soft = float(soft[row, x].mean())
    assert abs(got_soft - exp) <= 1.5, (got_soft, exp)
    hard, t_hard = page_stitch.stitch_pages(a, b, "v", overlap=30, seam_fade=0)
    ha2 = 200 - t_hard["trim_a"]
    seam2 = ha2 - 30
    b_trim2 = b[t_hard["trim_b"]:]
    # 硬拼：同位置直接是 B 的原值（纸白）。
    got_hard = float(hard[seam2 + 4, x].mean())
    assert abs(got_hard - float(b_trim2[4, x].mean())) <= 1.0


def test_stitch_pages_endpoint_preview_and_write(tmp_path):
    """/stitch_pages 端点：preview 返回 b64+trace；写盘返回 out_path。"""
    import api_page  # noqa: F401  # 路由在 api_page 上注册到共享 app
    from fastapi.testclient import TestClient
    from api_base import app

    pa = str(tmp_path / "a.png")
    pb = str(tmp_path / "b.png")
    cv2.imencode(".png", _page(200, 300, blocks=[(50, 200, 100, 80)]))[1].tofile(pa)
    cv2.imencode(".png", _page(200, 300, blocks=[(50, 20, 100, 80)]))[1].tofile(pb)
    client = TestClient(app)

    r = client.post("/stitch_pages", json={
        "image_a": pa, "image_b": pb, "direction": "v", "preview": True,
        "preview_max_px": 300,
    })
    assert r.status_code == 200, r.text
    body = r.json()
    img = cv2.imdecode(np.frombuffer(base64.b64decode(body["image_b64"]), np.uint8), cv2.IMREAD_COLOR)
    assert img is not None
    assert max(img.shape[:2]) <= 300
    assert body["trace"]["direction"] == "v"

    out = str(tmp_path / "stitched.png")
    r2 = client.post("/stitch_pages", json={
        "image_a": pa, "image_b": pb, "direction": "v", "out_path": out,
    })
    assert r2.status_code == 200, r2.text
    assert r2.json()["out_path"] == out
    written = cv2.imdecode(np.fromfile(out, dtype=np.uint8), cv2.IMREAD_COLOR)
    assert written is not None and written.shape[0] > 300

    # 缺 out_path 的写盘请求 → 400。
    r3 = client.post("/stitch_pages", json={"image_a": pa, "image_b": pb})
    assert r3.status_code == 400
