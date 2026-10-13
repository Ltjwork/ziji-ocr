# -*- coding: utf-8 -*-
"""单字墨迹校验（char_verify）的单元测试。

合成样本思路：用随包楷体把字渲染成"墨迹"贴进白底页面（模拟刻本页
扫描），识别文字同样经楷体渲染成对照字形——同字体自比对是校验分的
上界（应恒 ok），叠加断笔/噪点扰动后仍应 ok；换成形近错字则应显著
掉分（mismatch/suspect）。不依赖任何真实书页数据。
"""

import os
import tempfile
import unittest

import cv2
import numpy as np
from PIL import Image

import char_verify as ver


def _page_with_char(ch: str, mutate=None, cell: int = 110, page: int = 600):
    """白底页面中央贴一个楷体字，返回 (页面路径, 字的矩形)。

    mutate(binary) 可对"墨迹"（墨=255 的二值图）做断笔/噪点扰动后再
    贴页，模拟刻印/扫描缺陷。页面需足够大（>=600px）：去栏线按
    max(60, 页宽//4) 的形态学核删除长直线，页面太小时字的竖笔会被
    误当栏线删掉（真实书页 2000px+，字笔画远小于核宽，无此问题）。"""
    glyph = ver._render_glyph(ch)
    assert glyph is not None, f"字体缺字: {ch}"
    if mutate is not None:
        glyph = mutate(glyph)
    canvas = np.full((page, page), 255, dtype=np.uint8)
    gh, gw = glyph.shape
    scale = min(cell / gh, cell / gw, 1.0)
    glyph = np.asarray(
        Image.fromarray(glyph).resize(
            (max(1, int(gw * scale)), max(1, int(gh * scale))),
            Image.Resampling.NEAREST))
    h, w = glyph.shape
    x, y = (page - w) // 2, (page - h) // 2
    # 页面上墨为黑（_text_mask_for_refinement 的 OTSU 反相后变前景）
    patch = canvas[y: y + h, x: x + w]
    canvas[y: y + h, x: x + w] = np.where(glyph > 127, 0, patch)
    fd, path = tempfile.mkstemp(suffix=".png")
    Image.fromarray(canvas).save(path)
    os.close(fd)
    return path, (x, y, w, h)


def _cut_h(ratio: float = 0.5, width: int = 2):
    """水平切断刀：模拟断笔（缝宽 <= 2px 应被闭运算粘回）。"""
    def mutate(binary):
        out = binary.copy()
        y = int(out.shape[0] * ratio)
        out[y: y + width, :] = 0
        return out
    return mutate


class TopologyTests(unittest.TestCase):
    """拓扑计数层：方案核心案例（日/昌/田/目）的骨架拓扑量。"""

    def _topo(self, ch: str) -> dict:
        skel = ver._skeleton(ver._render_glyph(ch))
        return ver._topology(skel)

    def test_richou_tian_mu(self):
        ri = self._topo("日")
        chang = self._topo("昌")
        tian = self._topo("田")
        mu = self._topo("目")
        # 相对关系断言（比绝对值稳，不受楷体笔画细节影响）：
        self.assertEqual(ri["holes"], 2)
        self.assertEqual(mu["holes"], 3)
        self.assertEqual(chang["holes"], 2 * ri["holes"])
        # 田/昌同洞数，靠连通块区分（十字检测有已知局限：细化常把正
        # 交十字拆成相邻两个 T，CN=4 的同点十字不一定保留，故只断言
        # 上限而不强求 ==1）
        self.assertEqual(tian["holes"], chang["holes"])
        self.assertLessEqual(tian["crossings"], 1)
        self.assertEqual(chang["crossings"], 0)
        self.assertEqual(chang["components"], 2)
        self.assertEqual(tian["components"], 1)
        # 封闭字端点应接近 0（楷体书法封口小口可能留下 1-2 个，是
        # L1 退化的设计依据，允许小量）
        self.assertLessEqual(ri["endpoints"], 2)

    def test_open_char_has_endpoints(self):
        # 开放笔画字应有端点（如"人"：撇捺共 3 端点——捺起笔与撇交叠
        # 成 1 端点 + 两笔尾），且洞为 0。
        ren = self._topo("人")
        self.assertEqual(ren["holes"], 0)
        self.assertGreaterEqual(ren["endpoints"], 2)


class VerifyTests(unittest.TestCase):
    """三层比对端到端：同字自比对、结构级错字、同拓扑错字、扰动鲁棒。"""

    def _verify(self, ink_char: str, text: str, mutate=None) -> dict:
        path, rect = _page_with_char(ink_char, mutate=mutate)
        try:
            return ver.verify_char(path, rect, text)
        finally:
            os.unlink(path)

    def test_self_match_is_ok(self):
        for ch in ("天", "昌", "人", "中"):
            with self.subTest(ch=ch):
                result = self._verify(ch, ch)
                self.assertEqual(result["level"], "ok", result)

    def test_structure_error_mismatch(self):
        # 核心案例：昌→日（洞数差 2，硬失败）；反向同理
        self.assertEqual(self._verify("昌", "日")["level"], "mismatch")
        self.assertEqual(self._verify("日", "昌")["level"], "mismatch")

    def test_same_topology_pair_drops_score(self):
        # 田 vs 昌：洞数同为 4，拓扑容差全吸收 → 靠 L1/L2 拉开分差
        good = self._verify("田", "田")
        bad = self._verify("田", "昌")
        self.assertEqual(good["level"], "ok")
        self.assertLess(bad["score"], good["score"] - 0.1)

    def test_ratio_pair_drops_score(self):
        # 未 vs 末：拓扑完全同构，端点/交叉位置比例不同 → L1 掉分。
        # 两方向不对称：末->未（上横长认成上横短）分差显著；未->末
        # 的匹配率约 0.8，落在 MATCH_FULL 归一化（风格容错）与比例
        # 信号的重叠区被拉满——这是该字对在"容忍手写风格偏移"与
        # "区分横长比例"之间的已知边界，由拓扑层与人工兜底。
        good = self._verify("未", "未")
        bad1 = self._verify("未", "末")
        good2 = self._verify("末", "末")
        bad2 = self._verify("末", "未")
        self.assertLessEqual(bad1["score"], good["score"] + 0.02)
        self.assertLess(bad2["score"], good2["score"] - 0.05)

    def test_broken_stroke_still_ok(self):
        # 断笔（1px 缝，真实刻本笔画中断的典型宽度；贴页放大后约
        # 2px）应被闭运算粘回，不改变拓扑判定
        result = self._verify("日", "日", mutate=_cut_h(0.5, 1))
        self.assertEqual(result["level"], "ok", result)

    def test_noise_dots_removed(self):
        def mutate(binary):
            out = binary.copy()
            out[2, 2] = 255
            out[-3, -3] = 255  # 两个 1px 飞白点
            return out
        result = self._verify("日", "日", mutate=mutate)
        self.assertEqual(result["level"], "ok", result)

    def test_skips(self):
        self.assertEqual(self._verify("天", "。")["level"], "skipped")
        self.assertEqual(self._verify("天", "")["level"], "skipped")
        self.assertEqual(self._verify("天", "天地")["level"], "skipped")

    def test_debug_overlay_returned(self):
        path, rect = _page_with_char("天")
        try:
            result = ver.verify_char(path, rect, "天", debug=True)
            self.assertIn("debug_image_b64", result)
            self.assertGreater(len(result["debug_image_b64"]), 100)
        finally:
            os.unlink(path)


class PreprocessTests(unittest.TestCase):
    """阶段 A 预处理：渗墨剔除/贴边门禁/笔宽收细守卫/置信度阈值带。"""

    def test_crop_ink_drops_outside_blob(self):
        # 完全落在字框外的邻字渗墨块被剔除，紧裁后只剩字本身
        mask = np.zeros((200, 200), dtype=np.uint8)
        mask[50:100, 50:100] = 255      # 字
        mask[10:30, 180:199] = 255      # 字框外的邻字墨迹
        crop, reason = ver._crop_ink(mask, (48, 48, 56, 56))
        self.assertIsNone(reason)
        self.assertEqual(crop.shape, (50, 50))

    def test_crop_ink_border_touch_still_verifies(self):
        # 笔画贴边（冒尖/切断）不再跳过：密集刻本的检测框紧贴墨迹，
        # 贴边判据会把整页字误跳掉（回测否决），统一交由后续比对处理
        mask = np.zeros((200, 200), dtype=np.uint8)
        mask[50:102, 80:120] = 255     # 顶端越过字框上沿 2px
        crop, reason = ver._crop_ink(mask, (78, 52, 44, 50))
        self.assertIsNone(reason)
        self.assertIsNotNone(crop)

    def test_shrink_keeps_thin_strokes(self):
        # 粗条(20px)与细条(3px)并存：收细后粗条明显变细、细条仍在
        img = np.zeros((80, 80), dtype=np.uint8)
        img[5:25, 5:75] = 255     # 粗横
        img[40:43, 5:75] = 255    # 细横（守卫保护对象）
        out = ver._shrink_to_width(img, 4.0)
        thick = int(((out[0:30] > 0).any(axis=1)).sum())
        thin = int(((out[30:60] > 0).any(axis=1)).sum())
        self.assertGreater(thick, 0)
        self.assertLess(thick, 20)          # 粗条确实收细了
        self.assertGreaterEqual(thin, 1)    # 细条没被整条吃掉

    def test_shrink_noop_when_thin(self):
        # 笔宽已达目标：原样返回（同对象），不做无谓重阈值化
        img = np.zeros((40, 40), dtype=np.uint8)
        img[18:22, 5:35] = 255  # 4px ≈ 目标宽
        self.assertIs(ver._shrink_to_width(img, 4.0), img)

    def test_level_thresholds_conf_bands(self):
        lo0, hi0 = ver._level_thresholds(None)
        lo_hi_conf, hi_hi_conf = ver._level_thresholds(0.99)
        lo_low, hi_low = ver._level_thresholds(0.2)
        # conf 高 → 阈值带下移（更难标红）；conf 低 → 上移（更容易标红）
        self.assertLess(lo_hi_conf, lo0)
        self.assertLess(hi_hi_conf, hi0)
        self.assertGreater(lo_low, lo0)
        self.assertGreater(hi_low, hi0)

    def test_level_thresholds_cls_bands(self):
        # CLS_SHIFT 默认 0（分类器数据不足期融合关闭）；显式启用后验证
        # 机制：进 top-3 → 更难标红；掉出 top-10 → 更容易标红；中间名次
        # 无附加信号
        original = ver.CLS_SHIFT
        ver.CLS_SHIFT = 0.03
        try:
            lo0, hi0 = ver._level_thresholds(None)
            lo_sup, _ = ver._level_thresholds(None, cls_rank=2)
            lo_out, _ = ver._level_thresholds(None, cls_rank=0)
            lo_mid, hi_mid = ver._level_thresholds(None, cls_rank=5)
            self.assertLess(lo_sup, lo0)
            self.assertGreater(lo_out, lo0)
            self.assertEqual((lo_mid, hi_mid), (lo0, hi0))
        finally:
            ver.CLS_SHIFT = original


class AlignmentTests(unittest.TestCase):
    """阶段 B 对齐：微旋转/微缩放不变性、封闭字 L1 兜底。"""

    def _verify(self, ink_char: str, text: str, mutate=None) -> dict:
        path, rect = _page_with_char(ink_char, mutate=mutate)
        try:
            return ver.verify_char(path, rect, text)
        finally:
            os.unlink(path)

    def test_small_rotation_still_ok(self):
        def mutate(binary):
            h, w = binary.shape
            m = cv2.getRotationMatrix2D((w / 2, h / 2), 3.0, 1.0)
            return cv2.warpAffine(binary, m, (w, h))
        self.assertEqual(self._verify("天", "天", mutate)["level"], "ok")

    def test_small_scale_still_ok(self):
        def mutate(binary):
            h, w = binary.shape
            m = cv2.getRotationMatrix2D((w / 2, h / 2), 0.0, 0.94)
            return cv2.warpAffine(binary, m, (w, h))
        self.assertEqual(self._verify("天", "天", mutate)["level"], "ok")

    def test_closed_char_match_not_none(self):
        # 全封闭字（日）此前 L1 返回 None，采样兜底后应有 match 分
        result = self._verify("日", "日")
        self.assertEqual(result["level"], "ok", result)
        self.assertIsNotNone(result["parts"]["match"])

    def test_alignment_reported(self):
        result = self._verify("天", "天")
        self.assertIn("alignment", result)
        align = result["alignment"]
        self.assertIn("rot", align)
        self.assertIn("scale", align)


class PeerTests(unittest.TestCase):
    """阶段 C 同伴互证：多数簇/确认锚/风格降级/硬失败红线。"""

    @staticmethod
    def _bar(kind: str) -> np.ndarray:
        img = np.zeros((ver.CANVAS, ver.CANVAS), np.uint8)
        if kind == "h":
            img[62:66, 20:108] = 255
        else:
            img[20:108, 62:66] = 255
        return img

    @staticmethod
    def _result(text="天", level="ok", hard_fail=False):
        return {"level": level, "score": 0.8, "hard_fail": hard_fail,
                "text": text}

    def test_odd_one_out_boosted(self):
        # 三同字：两个互像、一个谁都不像 → 少数派 ok 升 suspect
        skels = {"a": self._bar("h"), "b": self._bar("h"),
                 "c": self._bar("v")}
        results = {i: self._result() for i in "abc"}
        ver._peer_verify(results, skels, {})
        self.assertEqual(results["a"]["level"], "ok")
        self.assertEqual(results["b"]["level"], "ok")
        self.assertEqual(results["c"]["level"], "suspect")
        self.assertEqual(results["c"]["peer"]["adjusted"],
                         "boosted_minority")

    def test_confirmed_anchor_boosts_mismatch(self):
        # 组内有确认锚：与锚不像 → 直接 mismatch
        skels = {"a": self._bar("h"), "b": self._bar("h"),
                 "c": self._bar("v")}
        results = {i: self._result() for i in "abc"}
        ver._peer_verify(results, skels, {"a": "confirmed"})
        self.assertEqual(results["c"]["level"], "mismatch")
        self.assertEqual(results["c"]["peer"]["adjusted"],
                         "boosted_by_confirmed")

    def test_style_downgrade_with_anchor(self):
        # 与锚高度一致但楷体标红（非硬失败）→ 风格差异降级
        skels = {"a": self._bar("h"), "b": self._bar("h"),
                 "c": self._bar("h")}
        results = {"a": self._result(level="mismatch"),
                   "b": self._result(level="ok"),
                   "c": self._result(level="suspect")}
        ver._peer_verify(results, skels, {"b": "confirmed"})
        self.assertEqual(results["a"]["level"], "suspect")
        self.assertEqual(results["c"]["level"], "ok")

    def test_hard_fail_never_overridden(self):
        # 红线：拓扑硬失败不受同伴结论影响（防整组读错互相背书）
        skels = {"a": self._bar("h"), "b": self._bar("h"),
                 "c": self._bar("h")}
        results = {"a": self._result(level="mismatch", hard_fail=True),
                   "b": self._result(level="ok"),
                   "c": self._result(level="ok")}
        ver._peer_verify(results, skels, {"b": "confirmed"})
        self.assertEqual(results["a"]["level"], "mismatch")
        self.assertIsNone(results["a"]["peer"]["adjusted"])

    def test_very_strong_peer_downgrades_to_ok(self):
        # 同雕版级雷同（无锚）：整组彼此一模一样但楷体标红 → 纯风格
        # 鸿沟，放行 ok；硬失败不受影响
        skels = {i: self._bar("h") for i in "abc"}
        results = {"a": self._result(level="mismatch"),
                   "b": self._result(level="suspect"),
                   "c": self._result(level="mismatch", hard_fail=True)}
        ver._peer_verify(results, skels, {})
        self.assertEqual(results["a"]["level"], "ok")
        self.assertEqual(results["b"]["level"], "ok")
        self.assertEqual(results["c"]["level"], "mismatch")  # 红线

    def test_small_group_untouched(self):
        # 组 < PEER_MIN_GROUP 不启用
        skels = {"a": self._bar("h"), "b": self._bar("v")}
        results = {"a": self._result(), "b": self._result()}
        ver._peer_verify(results, skels, {})
        self.assertEqual(results["a"]["level"], "ok")
        self.assertNotIn("peer", results["a"])

    def test_batch_reports_peer(self):
        # 整页批量：同字三实例，结果带 peer 明细
        path, rects = _page_with_chars([("天", None), ("天", None),
                                        ("天", None)])
        try:
            class _Blk:
                def __init__(self, bid, rect):
                    self.id, (self.x, self.y, self.w, self.h) = bid, rect
                    self.text, self.conf, self.status = "天", None, None
            blocks = [_Blk(f"t{i}", rects[i]) for i in range(3)]
            out = ver.verify_chars_batch(path, blocks)
            for i in range(3):
                r = out["results"][f"t{i}"]
                self.assertIn("peer", r)
                self.assertEqual(r["peer"]["group"], 3)
        finally:
            os.unlink(path)


def _page_with_chars(pairs, page_h: int = 600, cell: int = 110,
                     gap: int = 30):
    """一页横向排开多个楷体字（peer 批量测试用），返回 (路径, {序号: 矩形})。

    页高 >=600 保证去栏线核（max(60, 页宽//4)）不会误删字内笔画；
    字间距 gap 让各字连通域独立、字框互不贴边。"""
    canvas = np.full((page_h, 40 + (cell + gap) * len(pairs)), 255,
                     dtype=np.uint8)
    rects = {}
    for idx, (ch, mutate) in enumerate(pairs):
        glyph = ver._render_glyph(ch)
        assert glyph is not None, f"字体缺字: {ch}"
        if mutate is not None:
            glyph = mutate(glyph)
        scale = min(cell / glyph.shape[0], cell / glyph.shape[1], 1.0)
        glyph = np.asarray(
            Image.fromarray(glyph).resize(
                (max(1, int(glyph.shape[1] * scale)),
                 max(1, int(glyph.shape[0] * scale))),
                Image.Resampling.NEAREST))
        h, w = glyph.shape
        x0 = 20 + idx * (cell + gap) + (cell - w) // 2
        y0 = (page_h - h) // 2
        patch = canvas[y0: y0 + h, x0: x0 + w]
        canvas[y0: y0 + h, x0: x0 + w] = np.where(glyph > 127, 0, patch)
        rects[idx] = (x0, y0, w, h)
    fd, path = tempfile.mkstemp(suffix=".png")
    Image.fromarray(canvas).save(path)
    os.close(fd)
    return path, rects


class BatchTests(unittest.TestCase):
    def test_batch(self):
        # 一页放不了两个字（_page_with_char 单字）——用两个页面各验一
        # 字，验证批量接口的 results/errors 结构与单字一致性。
        path_a, rect_a = _page_with_char("昌")
        path_b, rect_b = _page_with_char("日")
        try:
            class _Block:
                def __init__(self, bid, rect, text):
                    self.id, (self.x, self.y, self.w, self.h), self.text = \
                        bid, rect, text
            out = ver.verify_chars_batch(
                path_a, [_Block("a", rect_a, "日"), _Block("b", rect_a, "")])
            self.assertIn("a", out["results"])
            self.assertEqual(out["results"]["a"]["level"], "mismatch")
            self.assertEqual(out["results"]["b"]["level"], "skipped")
            single = ver.verify_char(path_b, rect_b, "日")
            self.assertEqual(single["level"], "ok")
        finally:
            os.unlink(path_a)
            os.unlink(path_b)


class EndpointTests(unittest.TestCase):
    """/verify_char 端点冒烟（不起 lifespan，不碰 Kraken daemon）。"""

    def test_endpoint(self):
        try:
            from fastapi.testclient import TestClient
            import main
        except Exception as exc:
            self.skipTest(f"main/fastapi 不可用: {exc}")
        path, rect = _page_with_char("昌")
        try:
            client = TestClient(main.app)
            resp = client.post("/verify_char", json={
                "image_path": path, "x": rect[0], "y": rect[1],
                "w": rect[2], "h": rect[3], "text": "日", "debug": False})
            self.assertEqual(resp.status_code, 200)
            body = resp.json()
            self.assertEqual(body["level"], "mismatch")
            self.assertGreaterEqual(body["elapsed_ms"], 0.0)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
