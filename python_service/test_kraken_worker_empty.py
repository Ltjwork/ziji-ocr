# -*- coding: utf-8 -*-
"""kraken_worker._recognize 整批模式（per_line=False）的空白裁剪容错测试：
nlbin 对均匀裁剪（全白/全黑包围盒）抛 KrakenInputException('Image is
empty')，整批应按空行返回而非把异常抛穿整个请求（真实病灶：按主区拆分
page_008 整页识别里，某行全部字框都是无墨空位槽/纯白页边假行，批量补读
时包围盒全白 → worker 500 → 整页拆分失败）。

kraken 环境不在测试环境（paddle env）里，binarization/rpred 以假模块注入
sys.modules；nlbin 行为本身（均匀图抛错）是 kraken 既有语义，不在本文件
验证范围。逐行模式的同口径容错（_prepare_line_safe）见 kraken_worker 内
实现，此处只测整批路径。
"""

import sys
import types
import unittest
from tempfile import TemporaryDirectory
from unittest import mock

from PIL import Image

import kraken_worker


class KrakenInputException(Exception):
    # _is_empty_image_error 按类名+报错文案识别（kraken 的重导入懒加载），
    # 假模块里同名同类即可命中同一判定。
    pass


def _install_fake_kraken(nlbin_impl):
    """注入假 kraken 包（binarization.nlbin 可控、containers/rpred 为
    空 stub——整批路径 import 在 nlbin 之前，缺了会 ImportError），
    返回 (patcher, binarization 模块)。"""
    pkg = types.ModuleType("kraken")
    binarization = types.ModuleType("kraken.binarization")
    binarization.nlbin = nlbin_impl
    rpred = types.ModuleType("kraken.rpred")
    containers = types.ModuleType("kraken.containers")
    containers.BaselineLine = object
    containers.Segmentation = object
    pkg.binarization = binarization
    pkg.rpred = rpred
    pkg.containers = containers
    patcher = mock.patch.dict(
        sys.modules,
        {
            "kraken": pkg,
            "kraken.binarization": binarization,
            "kraken.rpred": rpred,
            "kraken.containers": containers,
        },
    )
    return patcher, binarization


def _raise_empty(im):
    raise KrakenInputException("Image is empty")


class BatchEmptyImageTests(unittest.TestCase):
    def _make_white_page(self, folder: str) -> str:
        path = f"{folder}/white.png"
        Image.new("L", (200, 300), 255).save(path)
        return path

    def test_uniform_batch_crop_returns_empty_lines(self):
        # 全部框远离原点（触发裁剪快速路径 off_x/off_y≠0）：空行结果的
        # 坐标必须还原回全图坐标，否则下游按裁剪系坐标错位。
        with TemporaryDirectory() as folder:
            image_path = self._make_white_page(folder)
            rects = [
                {"x": 100, "y": 50, "w": 30, "h": 200},
                {"x": 100, "y": 60, "w": 30, "h": 190},
            ]
            patcher, _ = _install_fake_kraken(_raise_empty)
            with patcher:
                result = kraken_worker._recognize(
                    None,
                    {
                        "image_path": image_path,
                        "scale": 2.0,
                        "text_direction": "vertical-rl",
                        "lines": rects,
                        # 不带 per_line → 整批模式
                    },
                )
            lines = result["lines"]
            self.assertEqual(len(lines), len(rects))
            for line, rect in zip(lines, rects):
                self.assertEqual(
                    (line["x"], line["y"], line["w"], line["h"]),
                    (rect["x"], rect["y"], rect["w"], rect["h"]),
                )
                self.assertEqual(line["text"], "")
                self.assertEqual(line["conf"], 0.0)
                self.assertEqual(line["chars"], [])

    def test_non_empty_image_error_still_propagates(self):
        # 非空白判错（如 CUDA/模型错误）必须原样抛出，仍走崩溃上报路径。
        with TemporaryDirectory() as folder:
            image_path = self._make_white_page(folder)
            rects = [{"x": 100, "y": 50, "w": 30, "h": 200}]

            def _raise_cuda(im):
                raise RuntimeError("CUDA error: an illegal memory access")

            patcher, _ = _install_fake_kraken(_raise_cuda)
            with patcher:
                with self.assertRaisesRegex(RuntimeError, "CUDA"):
                    kraken_worker._recognize(
                        None,
                        {
                            "image_path": image_path,
                            "scale": 2.0,
                            "text_direction": "vertical-rl",
                            "lines": rects,
                        },
                    )


if __name__ == "__main__":
    unittest.main()
