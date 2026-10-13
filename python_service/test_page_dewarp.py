"""page_dewarp 的算法单测：用合成图验证角点检测、单应/Coons 拉平与增强。

运行：conda run -n paddle python -m pytest test_page_dewarp.py -q
"""

import base64
import os
import sys
import unittest
from tempfile import TemporaryDirectory

import cv2
import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import page_dewarp as pd  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from main import app  # noqa: E402


def make_photo(page_quad, size=(1200, 1600), page_value=235, bg_value=60):
    """合成"深色桌面上放一张浅色书页"的照片。

    page_quad: 原图坐标下的 4 点（TL,TR,BR,BL），页面内画密排竖排文字
    （10 列 × 34 字，随页面透视双线性映射），墨迹方向与纸边一致——
    轮廓法/墨迹法都有信号且同向。返回 (img, quad)。
    """
    w, h = size
    img = np.full((h, w, 3), bg_value, dtype=np.uint8)
    quad = np.asarray(page_quad, dtype=np.int32)
    cv2.fillPoly(img, [quad], (page_value, page_value, page_value))
    # 页内竖排文字：密排字块（列方向跟随页面透视）。
    for j in range(10):
        for i in range(34):
            t_x, t_y = (0.08 + j * 0.09), (0.06 + i * 0.026)
            b_x, b_y = t_x + 0.055, t_y + 0.021
            p0 = _lerp_quad(quad, t_x, t_y)
            p1 = _lerp_quad(quad, b_x, b_y)
            cv2.rectangle(
                img,
                tuple(np.round(p0).astype(int)),
                tuple(np.round(p1).astype(int)),
                (30, 30, 30),
                -1,
            )
    return img, quad


def _lerp_quad(quad, u, v):
    """四边形内双线性取点（TL,TR,BR,BL 顺序）。"""
    tl, tr, br, bl = np.asarray(quad, dtype=np.float64)
    top = tl + (tr - tl) * u
    bottom = bl + (br - bl) * u
    return top + (bottom - top) * v


# ---------------------------------------------------------------------------
# 检测
# ---------------------------------------------------------------------------

def test_detect_contour_rotated_page():
    quad = [[300, 240], [1050, 180], [1150, 1380], [240, 1330]]
    img, truth = make_photo(quad)
    pts, method, _trace = pd.detect_page_quad(img)
    assert method == "contour"
    pts = np.asarray(pts)
    # 适度旋转下应把 4 角都找到 ±2% 图幅以内。
    assert np.linalg.norm(pts - np.asarray(quad, dtype=np.float64), axis=1).max() < 0.02 * 1600


def test_detect_orders_corners_tltrbrbl():
    quad = [[300, 240], [1050, 180], [1150, 1380], [240, 1330]]
    img, _ = make_photo(quad)
    pts, _, _trace = pd.detect_page_quad(img)
    pts = np.asarray(pts)
    assert pts[0][0] < pts[2][0] and pts[0][1] < pts[2][1]  # TL vs BR


def test_detect_near_full_frame_tilted_page():
    # 用户实际场景：页面近满幅、约 2° 倾斜、灰底。检测框必须贴着纸边
    #（而非斜切的错误框），且因倾斜被判定需要拉正。
    w, h = 1200, 1600
    quad = np.array(
        [[20, 60], [1165, 15], [1188, 1560], [12, 1592]], dtype=np.float64
    )
    img, truth = make_photo(quad.tolist(), size=(w, h))
    pts, method, _trace = pd.detect_page_quad(img)
    assert method == "contour"
    pts = np.asarray(pts)
    assert np.linalg.norm(pts - truth, axis=1).max() < 0.025 * h
    assert pd.quad_needs_warp(w, h, pts.tolist()) is True


def test_detect_dark_page_on_white_bg():
    # 白底上的深色"页"（反极性）：轮廓法按暗色块取 minAreaRect。
    w, h = 1200, 1600
    img = np.full((h, w, 3), 250, dtype=np.uint8)
    cv2.rectangle(img, (200, 260), (980, 1420), (40, 40, 40), -1)
    pts, method, _trace = pd.detect_page_quad(img)
    assert method == "contour"
    pts = np.asarray(pts)
    assert abs(pts[0][0] - 200) < 40
    assert abs(pts[0][1] - 260) < 40
    assert abs(pts[2][0] - 980) < 40
    assert abs(pts[2][1] - 1420) < 40


def test_detect_projection_fallback(monkeypatch):
    # 墨迹与纸边都无信号时（打桩）兜底内缩全图。
    monkeypatch.setattr(pd, "_quad_from_contour", lambda _: None)
    monkeypatch.setattr(pd, "_quad_from_ink", lambda _: None)
    w, h = 1200, 1600
    img = np.full((h, w, 3), 250, dtype=np.uint8)
    pts, method, _trace = pd.detect_page_quad(img)
    assert method == "default"
    pts = np.asarray(pts)
    assert abs(pts[0][0] - 0.02 * w) < 5
    assert abs(pts[2][0] - 0.98 * w) < 5


def test_detect_ink_aligned_when_text_skews_off_paper():
    # 用户实际场景：纸边端正、但文字版面歪了 ~3°（或反之）——检测框必须
    # 沿墨迹行列对齐（method=ink），而不是贴纸边。
    w, h = 1200, 1600
    img = np.full((h, w, 3), 245, dtype=np.uint8)  # 纸（贴满全图，无边可检）
    # 竖排文本：10 列 × 30 字，整体旋转 3°。
    text_layer = np.full((h, w), 255, dtype=np.uint8)
    angle = 3.0
    M = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)
    for col in range(10):
        x = int(w * 0.12 + col * w * 0.08)
        for row in range(30):
            y = int(h * 0.08 + row * h * 0.031)
            cv2.rectangle(text_layer, (x, y), (x + 18, y + 24), 0, -1)
    rotated_text = cv2.warpAffine(text_layer, M, (w, h), borderValue=255)
    img[rotated_text < 128] = 40
    pts, method, _trace = pd.detect_page_quad(img)
    assert method == "ink"
    pts = np.asarray(pts)
    tilt = pd._quad_tilt(pts)
    assert abs(tilt - angle) < 1.0, f"框倾角 {tilt:.1f}° 应跟随文字 {angle}°"
    assert pd.quad_needs_warp(w, h, pts.tolist()) is True


def test_detect_ink_horizontal_text_aligns_to_lines():
    # 横排文本行倾斜 4°：框应沿文字行方向对齐（转置扫描路径）。
    w, h = 1200, 1600
    img = np.full((h, w, 3), 245, dtype=np.uint8)
    text_layer = np.full((h, w), 255, dtype=np.uint8)
    angle = -4.0
    M = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)
    for row in range(28):
        y = int(h * 0.07 + row * h * 0.033)
        for k in range(24):
            x = int(w * 0.08 + k * w * 0.036)
            cv2.rectangle(text_layer, (x, y), (x + 22, y + 20), 0, -1)
    rotated_text = cv2.warpAffine(text_layer, M, (w, h), borderValue=255)
    img[rotated_text < 128] = 40
    pts, method, _trace = pd.detect_page_quad(img)
    assert method == "ink"
    pts = np.asarray(pts)
    # 纵边倾角应为 90°−4°（横排行的垂直方向）。
    tilt = pd._quad_tilt(pts)
    expect = 90.0 - 4.0
    delta = (tilt - expect) % 90.0
    if delta > 45.0:
        delta -= 90.0
    assert abs(delta) < 1.5, f"框倾角 {tilt:.1f}° 应跟随横排行（{expect}°）"


def test_detect_default_fallback(monkeypatch):
    # 两个主路径都无信号时兜底内缩全图（直接打桩验证回退链）。
    monkeypatch.setattr(pd, "_quad_from_contour", lambda _: None)
    monkeypatch.setattr(pd, "_quad_from_ink", lambda _: None)
    img = np.full((800, 600, 3), 128, dtype=np.uint8)
    pts, method, _trace = pd.detect_page_quad(img)
    assert method == "default"
    pts = np.asarray(pts)
    assert np.allclose(pts, [[12, 16], [587, 16], [587, 783], [12, 783]], atol=1)


def test_detect_blank_scan_full_page_no_warp_needed():
    # 纯色扫描（页面铺满、无边可检）：Otsu 把整图当一个页面轮廓，
    # 结果贴满全图 → 批量模式可自动跳过。
    img = np.full((800, 600, 3), 240, dtype=np.uint8)
    pts, _, _trace = pd.detect_page_quad(img)
    pts = np.asarray(pts)
    assert np.linalg.norm(pts - [[0, 0], [599, 0], [599, 799], [0, 799]], axis=1).max() < 3
    assert pd.quad_needs_warp(600, 800, pts.tolist()) is False


def test_needs_warp_flags():
    w, h = 1000, 1400
    flat = [[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]]
    # 完全贴满全图（干净渲染/PDF 页，偏差 < 1% 对角线）→ 如实跳过。
    exact_full = [[w * 0.004, h * 0.004], [w * 0.996, h * 0.004],
                  [w * 0.996, h * 0.996], [w * 0.004, h * 0.996]]
    # 2% 内缩 = 拍摄页约 2° 倾斜的典型偏差 → 必须拉正（这正是用户要的
    # "点位贴着纸边、把页面转正"），不能当成无需摆正跳过。
    tilted = [[w * 0.02, h * 0.02], [w * 0.98, h * 0.02],
              [w * 0.98, h * 0.98], [w * 0.02, h * 0.98]]
    off = [[80, 60], [w - 1, 0], [w - 1, h - 1], [0, h - 1]]
    assert pd.quad_needs_warp(w, h, flat) is False
    assert pd.quad_needs_warp(w, h, exact_full) is False
    assert pd.quad_needs_warp(w, h, tilted) is True
    assert pd.quad_needs_warp(w, h, off) is True
    # 角点贴合但有弯边 → 仍需拉平。
    bent = {"left": [0, h / 2 + 60]}
    assert pd.quad_needs_warp(w, h, flat, bent) is True


# ---------------------------------------------------------------------------
# 拉平
# ---------------------------------------------------------------------------

def test_dewarp_straight_edges_uses_homography():
    # 透视四边形（右边远、左边近），直边 → 输出宽 ≈ 对边均值、内容白底。
    quad = [[100, 100], [1150, 160], [1200, 1380], [60, 1320]]
    img, _ = make_photo(quad)
    out, ow, oh = pd.dewarp_page(img, quad)
    expect_w = (np.hypot(1050, 60) + np.hypot(1140, 60)) / 2
    expect_h = (np.hypot(40, 1220) + np.hypot(50, 1220)) / 2
    assert abs(ow - round(expect_w)) <= 1
    assert abs(oh - round(expect_h)) <= 1
    assert out.shape == (oh, ow, 3)
    # 输出四角是页面（浅色）而非背景（深色）。
    assert out[5, 5].mean() > 180
    assert out[-5, -5].mean() > 180


def test_dewarp_curved_edge_coons():
    # 左边中点向内弯 80px（书脊卷曲），Coons 路径应无异常且尺寸合理。
    quad = [[100, 100], [1150, 160], [1200, 1380], [60, 1320]]
    img, _ = make_photo(quad)
    left_mid = [80, 740]
    out, ow, oh = pd.dewarp_page(img, quad, {"left": left_mid})
    assert out.shape[0] == oh and out.shape[1] == ow
    assert ow > 400 and oh > 400
    assert out.dtype == np.uint8


def test_dewarp_identity_keeps_size():
    h, w = 400, 300
    img = np.full((h, w, 3), 200, dtype=np.uint8)
    quad = [[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]]
    out, ow, oh = pd.dewarp_page(img, quad)
    # 输出尺寸 = 对边长度（w-1）均值，允许 ±1 取整差。
    assert abs(ow - w) <= 1 and abs(oh - h) <= 1
    assert abs(int(out.mean()) - 200) <= 2


def test_dewarp_rejects_bad_corners():
    img = np.zeros((10, 10, 3), dtype=np.uint8)
    with pytest.raises(ValueError):
        pd.dewarp_page(img, [[0, 0], [1, 1]])


# ---------------------------------------------------------------------------
# 增强
# ---------------------------------------------------------------------------

def test_enhance_grayscale_stretches_contrast():
    base = np.full((60, 80, 3), 120, dtype=np.uint8)
    base[10:20, 10:30] = 40   # 2% 分位以下少量暗部
    base[40:50, 50:70] = 200
    out = pd.enhance_page(base, grayscale=True)
    # 三通道一致（已去色）。
    assert (out[..., 0] == out[..., 1]).all() and (out[..., 1] == out[..., 2]).all()
    assert int(out[15, 20, 0]) < 40   # 暗部被拉伸得更暗
    assert int(out[45, 60, 0]) > 235  # 亮部更亮


def test_enhance_sharpen_changes_pixels():
    rng = np.random.default_rng(7)
    img = (rng.random((60, 80, 3)) * 60 + 120).astype(np.uint8)
    img = cv2.GaussianBlur(img, (0, 0), 1.5)  # 柔化后再锐化应有差异
    out = pd.enhance_page(img, sharpen=True)
    assert not np.array_equal(out, img)
    assert out.shape == img.shape


def test_enhance_noop_returns_same():
    img = np.full((30, 30, 3), 99, dtype=np.uint8)
    out = pd.enhance_page(img)
    assert np.array_equal(out, img)


# ---------------------------------------------------------------------------
# 去透印
# ---------------------------------------------------------------------------

def _make_bleed_page():
    """合成古籍页：米白纸(243) + 深墨细线(40) + 中灰透印细线(198)。"""
    img = np.full((600, 400, 3), 243, dtype=np.uint8)
    for y in range(60, 541, 40):
        img[y, 40:180] = 40        # 主墨
        img[y + 6, 220:360] = 198  # 透印
    return img


def test_remove_show_through_kills_bleed_keeps_ink():
    img = _make_bleed_page()
    out = pd.remove_show_through(img, 50)
    assert out.shape == img.shape and out.dtype == np.uint8
    assert int(out[60, 100].mean()) <= 60    # 主墨保留
    assert int(out[66, 300].mean()) >= 235   # 透印压成纸白
    assert int(out[300, 200].mean()) >= 250  # 纸面净化
    # 未去透印的 enhance_page 不改原图（默认关）。
    assert np.array_equal(pd.enhance_page(img), img)


def test_remove_show_through_strength_monotonic():
    img = _make_bleed_page()
    bleed = [int(pd.remove_show_through(img, s)[66, 300].mean()) for s in (20, 50, 100)]
    # 强度越高透印越白。
    assert bleed[0] <= bleed[1] <= bleed[2]
    # 任何强度主墨都不丢。
    for s in (20, 50, 100):
        assert int(pd.remove_show_through(img, s)[60, 100].mean()) <= 60


def test_remove_show_through_dark_block_preserved():
    # 大片深色块（插图/黑底）：深色核心必须原样保留不被洗白。
    img = _make_bleed_page()
    img[400:560, 180:340] = 20
    out = pd.remove_show_through(img, 80)
    assert int(out[480, 260].mean()) <= 45


def test_remove_show_through_no_halo_around_bold_ink():
    # 回归：粗笔画旁的纸面必须洗白。旧版"背景过暗区整体跳过"在粗字
    # 周围留一圈原纸色灰块（背景被墨拉低误触发），新版按原始深浅逐点
    # 保护深墨、背景面用局部最亮（墨迹拉不低），灰块结构性消失。
    img = np.full((600, 400, 3), 205, dtype=np.uint8)
    img[100:400, 150:220] = 40  # 70px 宽粗笔画
    out = pd.remove_show_through(img, 50)
    assert int(out[250, 100].mean()) >= 235  # 笔画左侧 50px 纸面
    assert int(out[250, 290].mean()) >= 235  # 笔画右侧
    assert int(out[130, 130].mean()) >= 235  # 笔画左上角外侧
    assert int(out[250, 185].mean()) <= 60   # 笔画核心保留


def test_enhance_page_applies_debleed():
    img = _make_bleed_page()
    out = pd.enhance_page(img, debleed=True, debleed_strength=50)
    assert np.array_equal(out, pd.remove_show_through(img, 50))


# ---------------------------------------------------------------------------
# 端点（TestClient，与 test_split_page.py 同模式）
# ---------------------------------------------------------------------------

class PageDewarpEndpointTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = self._tmp.name

    def _write_photo(self, name="书页 照片.png"):
        """合成一张深色桌面 + 浅色斜放书页的照片（中文文件名）。"""
        quad = [[80, 60], [560, 90], [600, 760], [50, 720]]
        img, truth = make_photo(quad, size=(640, 800))
        path = os.path.join(self.root, name)
        ok, buf = cv2.imencode(".png", img)
        self.assertTrue(ok)
        buf.tofile(path)
        return path, truth

    def test_detect_endpoint(self):
        path, truth = self._write_photo()
        resp = self.client.post("/detect_page_quad", json={"image_path": path})
        self.assertEqual(resp.status_code, 200, resp.text)
        data = resp.json()
        self.assertEqual(data["w"], 640)
        self.assertEqual(data["h"], 800)
        self.assertEqual(data["method"], "contour")
        self.assertTrue(data["needs_warp"])
        pts = np.asarray(data["points"])
        self.assertLess(
            np.linalg.norm(pts - truth, axis=1).max(), 0.03 * 800
        )

    def test_dewarp_endpoint_writes_new_file_and_enhances(self):
        path, truth = self._write_photo()
        out_path = os.path.join(self.root, "warped", "page_000.png")
        resp = self.client.post(
            "/dewarp_page",
            json={
                "image_path": path,
                "corners": truth.tolist(),
                "grayscale": True,
                "sharpen": True,
                "out_path": out_path,
            },
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        data = resp.json()
        self.assertEqual(data["out_path"], out_path)
        out = cv2.imdecode(np.fromfile(out_path, dtype=np.uint8), cv2.IMREAD_COLOR)
        self.assertEqual(out.shape, (data["h"], data["w"], 3))
        # 去色后三通道一致。
        self.assertTrue((out[..., 0] == out[..., 1]).all())
        # 原图未被改动。
        src = cv2.imdecode(np.fromfile(path, dtype=np.uint8), cv2.IMREAD_COLOR)
        self.assertNotEqual(src.shape, out.shape)

    def test_dewarp_endpoint_debleed_fields(self):
        # 去透印参数可透传（端点 200 且产出文件）。
        path, truth = self._write_photo()
        out_path = os.path.join(self.root, "warped", "page_debleed.png")
        resp = self.client.post(
            "/dewarp_page",
            json={
                "image_path": path,
                "corners": truth.tolist(),
                "debleed": True,
                "debleed_strength": 60,
                "out_path": out_path,
            },
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertTrue(os.path.exists(out_path))

    def test_dewarp_endpoint_preview_returns_base64(self):
        path, truth = self._write_photo()
        resp = self.client.post(
            "/dewarp_page",
            json={
                "image_path": path,
                "corners": truth.tolist(),
                "preview": True,
                "preview_max_px": 300,
            },
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        data = resp.json()
        self.assertIn("image_b64", data)
        buf = np.frombuffer(base64.b64decode(data["image_b64"]), dtype=np.uint8)
        prev = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        self.assertLessEqual(max(prev.shape[:2]), 300)
        # 预览不落盘（未给 out_path 时也不该写 image_path 同名文件之外的东西）。
        self.assertFalse(os.path.exists(os.path.join(self.root, "warped")))

    def test_dewarp_endpoint_rejects_bad_input(self):
        path, _ = self._write_photo()
        resp = self.client.post(
            "/dewarp_page",
            json={"image_path": path, "corners": [[0, 0]]},
        )
        self.assertEqual(resp.status_code, 400)
        resp = self.client.post(
            "/detect_page_quad", json={"image_path": os.path.join(self.root, "无.png")}
        )
        self.assertEqual(resp.status_code, 400)


def test_detect_trace_documents_decision():
    # 检测日志（用户功能）：trace 必须带上判定依据，供前端展示。
    w, h = 1200, 1600
    img = np.full((h, w, 3), 245, dtype=np.uint8)
    text_layer = np.full((h, w), 255, dtype=np.uint8)
    M = cv2.getRotationMatrix2D((w / 2, h / 2), 3.0, 1.0)
    for col in range(10):
        x = int(w * 0.12 + col * w * 0.08)
        for row in range(30):
            y = int(h * 0.08 + row * h * 0.031)
            cv2.rectangle(text_layer, (x, y), (x + 18, y + 24), 0, -1)
    img[cv2.warpAffine(text_layer, M, (w, h), borderValue=255) < 128] = 40
    _pts, method, trace = pd.detect_page_quad(img)
    assert method == "ink"
    assert trace["ink"]["available"] is True
    assert trace["ink"]["orientation"] == "columns"
    assert abs(trace["ink"]["align_angle_deg"] - 3.0) <= 1.0
    assert trace["ink"]["coverage"] > 0.002
    assert trace["residual_after_paper_deg"] is not None
    assert abs(trace["residual_after_paper_deg"]) > 1.2
    assert "墨迹行列" in trace["decision"]
    # 端点透传 trace
    resp = TestClient(app).post(
        "/detect_page_quad",
        json={"image_path": _write_trace_image(w, h, img)},
    )
    assert resp.status_code == 200
    assert resp.json()["trace"]["decision"] == trace["decision"]


def _write_trace_image(w, h, img):
    import os
    from tempfile import NamedTemporaryFile

    path = os.path.join(
        os.path.dirname(NamedTemporaryFile().name), "trace页.png"
    )
    ok, buf = cv2.imencode(".png", img)
    assert ok
    buf.tofile(path)
    return path


def test_detect_dense_text_not_mistaken_for_paper():
    # 回归（真实 page_000.png 复现）：白底 PDF 页纸边无信号时，密排竖排
    # 文字曾被闭运算熔成的实心块冒充"纸"框成窄条；现在墨迹块被面积占比
    # 拒绝，且"纸边贴满全图"时直接按墨迹框包裹内容区（用户指定：裁掉
    # 周围空白，只包内容）。
    w, h = 1174, 1664
    img = np.full((h, w, 3), 245, dtype=np.uint8)
    text = np.full((h, w), 255, dtype=np.uint8)
    for col in range(14):
        x = int(w * 0.06 + col * w * 0.066)
        for row in range(42):
            y = int(h * 0.05 + row * h * 0.0225)
            cv2.rectangle(text, (x, y), (x + 22, y + 28), 0, -1)
    M = cv2.getRotationMatrix2D((w / 2, h / 2), -0.5, 1.0)
    img[cv2.warpAffine(text, M, (w, h), borderValue=255) < 128] = 40
    pts, method, trace = pd.detect_page_quad(img)
    assert method == "ink"
    assert "墨迹" in trace["decision"]
    pts = np.asarray(pts)
    # 框包裹内容区（不是窄条也不是全图）。
    width = pts[:, 0].max() - pts[:, 0].min()
    height = pts[:, 1].max() - pts[:, 1].min()
    assert 0.7 * w < width <= 1.25 * w  # 允许框略出界（出界区拉平填白）
    assert 0.7 * h < height <= 1.25 * h
    assert pd.quad_needs_warp(w, h, pts.tolist()) is True


def test_detect_table_block_not_mistaken_for_paper():
    # 回归（真实 page_001.png 复现）：页内的高填充表格块（~39% 面积、
    # 倾角与文字一致）曾冒充"纸"，把表格外的 12% 文字全部裁掉。真纸边
    # 必须包含 ≥90% 的（远处）墨迹，表格块被拒后回退墨迹框包住全部内容。
    w, h = 1200, 1600
    img = np.full((h, w, 3), 245, dtype=np.uint8)
    # 左侧表格：粗边框 + 密集格线（高填充、高对比的大块）。
    x0, y0, x1, y1 = int(w*0.06), int(h*0.08), int(w*0.44), int(h*0.90)
    cv2.rectangle(img, (x0, y0), (x1, y1), (30, 30, 30), 6)
    for gy in range(y0 + 60, y1 - 20, 64):
        cv2.line(img, (x0 + 3, gy), (x1 - 3, gy), (60, 60, 60), 2)
    for gx in range(x0 + 90, x1 - 20, 90):
        cv2.line(img, (gx, y0 + 3), (gx, y1 - 3), (60, 60, 60), 2)
    # 右侧竖排文字（在表格外——旧算法会把它们裁掉）。
    for col in range(7):
        x = int(w * 0.52 + col * w * 0.062)
        for row in range(38):
            y = int(h * 0.08 + row * h * 0.023)
            cv2.rectangle(img, (x, y), (x + 18, y + 24), (40, 40, 40), -1)
    pts, method, trace = pd.detect_page_quad(img)
    pts = np.asarray(pts)
    width = pts[:, 0].max() - pts[:, 0].min()
    # 框必须覆盖到右侧文字（不是只包表格）。
    assert width > 0.75 * w, f"框宽 {width:.0f}px 只包住了表格"
    assert method in ("ink", "contour")


def test_detect_ignores_faint_margin_stains():
    # 回归（用户指定行为）：页边淡渍（对比度低，调高亮度/对比度即消失）
    # 不该把墨迹框撑出去——强档掩码定框，淡渍被忽略；真字（对比度高）
    # 正常包裹。
    w, h = 1200, 1600
    img = np.full((h, w, 3), 245, dtype=np.uint8)
    # 真字：中央竖排块（暗度 ~185）。
    for col in range(10):
        x = int(w * 0.14 + col * w * 0.07)
        for row in range(24):
            y = int(h * 0.10 + row * h * 0.025)
            cv2.rectangle(img, (x, y), (x + 20, y + 26), (40, 40, 40), -1)
    # 页边淡渍：右上角与底部大片浅灰（暗度 ~35，敏感档会算成墨迹）。
    cv2.ellipse(img, (int(w * 0.93), int(h * 0.10)), (110, 150), 20, 0, 360,
                (210, 210, 210), -1)
    cv2.ellipse(img, (int(w * 0.30), int(h * 0.96)), (260, 50), 5, 0, 360,
                (212, 212, 212), -1)
    pts, method, trace = pd.detect_page_quad(img)
    assert method == "ink"
    pts = np.asarray(pts)
    # 框只包真字块（文字底界 ~70%）：右界不伸进右上角淡渍区，下界不达
    # 底部淡渍（若被淡渍撑出，会到 96%+）。
    assert pts[:, 0].max() < 0.88 * w, "右界伸进了右上角淡渍"
    assert pts[:, 1].max() < 0.85 * h, "下界伸进了底部淡渍"


def test_detect_whole_page_faint_ink_still_wrapped():
    # 整页淡墨（所有笔画暗度 < 强档阈值）：强档丢墨过半自动回退敏感档，
    # 内容照常包裹（不因提高强度丢内容）。
    w, h = 1200, 1600
    img = np.full((h, w, 3), 245, dtype=np.uint8)
    for col in range(10):
        x = int(w * 0.14 + col * w * 0.07)
        for row in range(34):
            y = int(h * 0.10 + row * h * 0.025)
            cv2.rectangle(img, (x, y), (x + 20, y + 26), (205, 205, 205), -1)
    pts, method, trace = pd.detect_page_quad(img)
    pts = np.asarray(pts)
    width = pts[:, 0].max() - pts[:, 0].min()
    assert width > 0.6 * w, f"整页淡墨未被包裹（框宽 {width:.0f}px）"


def test_detect_keeps_faint_text_near_strong_ink():
    # 回归（真实页复现：上一版强档裸掩码把与强墨同页混排的淡字裁掉）：
    # 有效墨迹按连通组件保留"9px 内有强核"的组件——列内强弱字交替时
    # 淡字全保留；孤立淡渍（远离任何深墨）仍被忽略。
    w, h = 1200, 1600
    img = np.full((h, w, 3), 245, dtype=np.uint8)
    for col in range(10):
        x = int(w * 0.14 + col * w * 0.07)
        for row in range(24):
            y = int(h * 0.10 + row * h * 0.025)
            # 强字（暗度 ~185）与淡字（暗度 ~40，高于淡渍的孤立性：与
            # 强字同列相邻，间距 ~4px < 9px 强核扩散半径）交替。
            val = 40 if row % 2 == 1 else 45
            cv2.rectangle(img, (x, y), (x + 20, y + 26), (val,) * 3, -1)
    # 孤立淡渍（右上角，离最近强墨 > 9px）。
    cv2.ellipse(img, (int(w * 0.93), int(h * 0.10)), (110, 150), 20, 0, 360,
                (208, 208, 208), -1)
    pts, method, trace = pd.detect_page_quad(img)
    assert method == "ink"
    pts = np.asarray(pts)
    # 文字块右界 ~0.86w：淡字与强字同列，右界必须包住它们。
    assert pts[:, 0].max() > 0.80 * w, "与强墨同页的淡字被裁掉了"
    # 孤立淡渍仍被忽略：右上角不进框。
    assert pts[:, 0].max() < 0.90 * w, "孤立淡渍又把框撑出去了"


# ── 源图暗色块诊断（导入黑边/黑底定位，纯量测不改判定）──


def _black_ring_page() -> np.ndarray:
    """仿用户截图：白底上内嵌一大圈黑环，中央一张带字的小白页。"""
    img = np.full((300, 400, 3), 245, np.uint8)  # 白底（黑环外的白边）
    img[40:260, 50:350] = 8  # 大黑环
    img[110:190, 150:250] = 252  # 环内中央小白页
    cv2.putText(img, "10", (175, 160), cv2.FONT_HERSHEY_SIMPLEX, 0.5, 20, 1)
    return img


def test_dark_region_stats_measures_black_ring():
    stats = pd.dark_region_stats(_black_ring_page())
    assert stats is not None
    assert stats["share"] > 0.30
    assert stats["luma"] < 32
    bx, by, bw, bh = stats["bbox"]
    assert abs(bx - 50) <= 4 and abs(by - 40) <= 4
    assert abs(bw - 300) <= 8 and abs(bh - 220) <= 8


def test_dark_region_stats_none_on_plain_page():
    # 白纸 + 细笔画文字：最大暗块 <5% 图幅 → None（不产生噪声）。
    img = np.full((300, 400, 3), 245, np.uint8)
    cv2.putText(img, "10", (175, 160), cv2.FONT_HERSHEY_SIMPLEX, 0.5, 20, 1)
    assert pd.dark_region_stats(img) is None


def test_dark_region_stats_edge_touching_black_bg():
    # 贴边黑底（另一种导入黑边形态）同样量得到。
    img = np.full((300, 400, 3), 245, np.uint8)
    img[60:240, 80:320] = 252  # 中央白页
    outside = img.copy()
    outside[:60, :] = 8
    outside[240:, :] = 8
    outside[:, :80] = 8
    outside[:, 320:] = 8
    img = outside
    stats = pd.dark_region_stats(img)
    assert stats is not None
    assert stats["share"] > 0.30


def test_detect_trace_reports_source_dark_region():
    pts, method, trace = pd.detect_page_quad(_black_ring_page())
    dark = trace.get("source_dark_region")
    assert dark is not None and dark["share"] > 0.30
    assert "暗块" in trace["decision"]
    # bbox 已换算回原图像素（此处无降采样，等于缩样值）。
    assert dark["bbox"][0] <= 55 and dark["bbox"][1] <= 45


def test_pixmap_rgb_array_shapes_samples():
    import fitz

    pix = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, 7, 5))
    pix.clear_with(200)  # 均色填充
    arr = pd.pixmap_rgb_array(pix)
    assert arr.shape == (5, 7, 3)
    assert int(arr[..., 0].mean()) == 200
