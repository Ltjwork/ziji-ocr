# -*- coding: utf-8 -*-
"""train_worker 训练参数传递测试：确保早停按预期禁用（patience=0）、
续训命令绝不携带 epochs（总轮数以 last.pt 内原始设置为准）。

用 mock 替身 YOLO，不起真实训练；两个用例都会因 best.pt 不存在而以
rc=1 结束——这是 worker 的正常收尾路径，参数断言发生在其之前。"""
import os
import sys
import tempfile
import unittest
from unittest import mock

import train_worker


def _run_worker(argv):
    with mock.patch.object(sys, "argv", argv), \
            mock.patch("ultralytics.YOLO") as yolo_cls:
        model = yolo_cls.return_value
        rc = train_worker.main()
    return rc, model.train.call_args


class WorkerTrainKwargsTests(unittest.TestCase):
    def test_resume_disables_early_stop_and_never_passes_epochs(self):
        with tempfile.TemporaryDirectory() as run_dir:
            rc, call = _run_worker([
                "train_worker.py", "--task", "detect",
                "--base", os.path.join(run_dir, "train", "weights", "last.pt"),
                "--resume", "--device", "cpu", "--run-dir", run_dir,
            ])
            self.assertEqual(rc, 1)  # 无 best.pt：正常失败收尾
            kwargs = call.kwargs
            # 早停必须禁用：旧 run 存的 patience=100 + 早期 best_fitness
            # 会让续训立刻再次早停（patience 在 resume 白名单里可覆写）
            self.assertEqual(kwargs.get("patience"), 0)
            self.assertTrue(kwargs.get("resume"))
            # 续训绝不传 epochs：总轮数以检查点内保存的原始值为准
            # （argparse 默认 150 若传进去会顶掉用户原本选的 300）
            self.assertNotIn("epochs", kwargs)
            self.assertEqual(kwargs.get("device"), "cpu")

    def test_fresh_training_disables_early_stop(self):
        with tempfile.TemporaryDirectory() as run_dir:
            rc, call = _run_worker([
                "train_worker.py", "--task", "detect", "--data", "x.yaml",
                "--base", "yolov8s.pt", "--epochs", "300",
                "--device", "cpu", "--run-dir", run_dir,
            ])
            self.assertEqual(rc, 1)
            kwargs = call.kwargs
            self.assertEqual(kwargs.get("patience"), 0)
            self.assertEqual(kwargs.get("epochs"), 300)
            self.assertEqual(kwargs.get("mosaic"), 0.0)  # 古籍适配参数仍在


if __name__ == "__main__":
    unittest.main()
