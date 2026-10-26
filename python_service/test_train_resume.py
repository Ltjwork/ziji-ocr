# -*- coding: utf-8 -*-
"""断点续训的后端单元测试：resumable_run 识别中断 run、read_run_meta
解析 args.yaml、resume_training 校验与任务构造（不真正起子进程训练）。"""
import os
import shutil
import tempfile
import unittest
from unittest import mock

import train_data
import train_registry
import train_tasks


def _make_interrupted_run(root, layer, name, *, epochs=300, done_rows=119,
                          done_json=False, last_pt=True, args_yaml=True):
    """构造一个训练 run：results.csv 已 done_rows 行 + last.pt + args.yaml。

    done_json=True 时补写 done.json（模拟已正常完成）；last_pt=False 模拟
    第 1 轮结束前中断（没有可续训的检查点）。"""
    run_dir = os.path.join(root, layer, name)
    weights = os.path.join(run_dir, "train", "weights")
    os.makedirs(weights, exist_ok=True)
    with open(os.path.join(run_dir, "train", "results.csv"), "w",
              encoding="utf-8", newline="") as f:
        f.write("epoch,loss\n")
        for i in range(1, done_rows + 1):
            f.write(f"{i},0.5\n")
    if last_pt:
        open(os.path.join(weights, "last.pt"), "wb").close()
    if args_yaml:
        with open(os.path.join(run_dir, "train", "args.yaml"), "w",
                  encoding="utf-8") as f:
            f.write("task: detect\n"
                    f"epochs: {epochs}\n"
                    "data: D:/guji/datasets/_global/char_det/data.yaml\n"
                    "model: yolov8s.pt\n"
                    "save_period: 10\n")
    if done_json:
        with open(os.path.join(run_dir, "done.json"), "w",
                  encoding="utf-8") as f:
            f.write('{"best": null, "metrics": {}, "epochs": %d}' % epochs)
    return run_dir


class ResumeSandboxTests(unittest.TestCase):
    """隔离训练根目录与任务表（不碰真实磁盘/全局状态）。"""

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="train_resume_")
        self._old_trained = train_data.TRAINED_ROOT
        train_data.TRAINED_ROOT = os.path.join(self._tmp, "trained")
        train_tasks._TASKS.clear()

    def tearDown(self):
        train_data.TRAINED_ROOT = self._old_trained
        train_tasks._TASKS.clear()
        shutil.rmtree(self._tmp, ignore_errors=True)


class ReadRunMetaTests(ResumeSandboxTests):
    def test_parses_args_yaml_scalars(self):
        run = _make_interrupted_run(
            train_data.TRAINED_ROOT, "char_det", "run_x", epochs=300)
        meta = train_registry.read_run_meta(run)
        self.assertEqual(meta["epochs"], "300")
        self.assertEqual(meta["model"], "yolov8s.pt")
        self.assertTrue(meta["data"].endswith("data.yaml"))

    def test_missing_args_yaml_returns_empty(self):
        run = _make_interrupted_run(
            train_data.TRAINED_ROOT, "char_det", "run_x", args_yaml=False)
        self.assertEqual(train_registry.read_run_meta(run), {})


class ResumableRunTests(ResumeSandboxTests):
    def test_interrupted_run_is_resumable(self):
        run = _make_interrupted_run(
            train_data.TRAINED_ROOT, "char_det", "run_a", done_rows=119)
        info = train_registry.resumable_run("char_det")
        self.assertIsNotNone(info)
        self.assertEqual(info["run_dir"], run)
        self.assertEqual(info["epochs"], 300)
        self.assertEqual(info["done"], 119)

    def test_completed_run_is_not_resumable(self):
        _make_interrupted_run(train_data.TRAINED_ROOT, "char_det", "run_a",
                              done_json=True)
        self.assertIsNone(train_registry.resumable_run("char_det"))

    def test_run_without_last_pt_is_not_resumable(self):
        _make_interrupted_run(train_data.TRAINED_ROOT, "char_det", "run_a",
                              last_pt=False)
        self.assertIsNone(train_registry.resumable_run("char_det"))

    def test_picks_latest_interrupted_run(self):
        older = _make_interrupted_run(
            train_data.TRAINED_ROOT, "char_det", "run_a", done_rows=50)
        newer = _make_interrupted_run(
            train_data.TRAINED_ROOT, "char_det", "run_b", done_rows=119)
        stamp = os.path.getmtime(os.path.join(older, "train", "weights", "last.pt"))
        os.utime(os.path.join(older, "train", "weights", "last.pt"),
                 (stamp - 3600, stamp - 3600))
        info = train_registry.resumable_run("char_det")
        self.assertEqual(info["run_dir"], newer)

    def test_list_models_exposes_resumable_per_layer(self):
        _make_interrupted_run(train_data.TRAINED_ROOT, "char_det", "run_a")
        old_reg = train_registry.REGISTRY_PATH
        train_registry.REGISTRY_PATH = os.path.join(self._tmp, "reg.json")
        try:
            models = train_registry.list_models()
            self.assertIn("resumable", models["char_det"])
            self.assertIsNotNone(models["char_det"]["resumable"])
        finally:
            train_registry.REGISTRY_PATH = old_reg


class ResumeTrainingTests(ResumeSandboxTests):
    def test_rejects_unknown_layer(self):
        with self.assertRaises(ValueError):
            train_tasks.resume_training("nope", "whatever")

    def test_rejects_siamese_layer(self):
        with self.assertRaises(ValueError):
            train_tasks.resume_training("verify_pair", "whatever")

    def test_rejects_without_last_pt(self):
        run = _make_interrupted_run(
            train_data.TRAINED_ROOT, "char_det", "run_a", last_pt=False)
        with self.assertRaises(ValueError):
            train_tasks.resume_training("char_det", run)

    def test_rejects_completed_run(self):
        run = _make_interrupted_run(
            train_data.TRAINED_ROOT, "char_det", "run_a", done_json=True)
        with self.assertRaises(ValueError):
            train_tasks.resume_training("char_det", run)

    def test_rejects_without_epochs_meta(self):
        run = _make_interrupted_run(
            train_data.TRAINED_ROOT, "char_det", "run_a", args_yaml=False)
        with self.assertRaises(ValueError):
            train_tasks.resume_training("char_det", run)

    def test_starts_resume_task_with_original_epochs(self):
        run = _make_interrupted_run(
            train_data.TRAINED_ROOT, "char_det", "run_a", done_rows=119)
        last_pt = os.path.join(run, "train", "weights", "last.pt")
        with mock.patch.object(train_tasks.subprocess, "Popen") as popen, \
                mock.patch.object(train_tasks.threading, "Thread") as thread:
            popen.return_value = mock.Mock()
            task = train_tasks.resume_training("char_det", run, device="cpu")
            self.assertTrue(popen.called)
            self.assertTrue(thread.called)
        cmd = popen.call_args[0][0]
        # 关键：续训命令不带 --epochs（总轮数以 last.pt 内保存的原始 300
        # 为准，传了也会被 ultralytics 的 ckpt 参数替换，但绝不能传 150 默认）
        self.assertNotIn("--epochs", cmd)
        self.assertIn("--resume", cmd)
        self.assertIn(last_pt, cmd)
        # 任务登记沿用原 run：进度立即反映已完成的 119/300，ETA 基线=119
        self.assertEqual(task["epochs"], 300)
        self.assertTrue(task["resumed"])
        self.assertEqual(task["run_dir"], run)
        self.assertAlmostEqual(task["progress"], 119 / 300, places=3)
        self.assertEqual(task["epoch"], 120)
        # 续训刚开始还没有新增轮数：不给预计时间（避免荒谬外推）
        self.assertIsNone(task["eta_seconds"])
        registered = train_tasks._TASKS[task["id"]]
        self.assertEqual(registered._base_done, 119)

    def test_rejects_while_another_training_runs(self):
        run = _make_interrupted_run(
            train_data.TRAINED_ROOT, "char_det", "run_a")
        with mock.patch.object(train_tasks.subprocess, "Popen") as popen, \
                mock.patch.object(train_tasks.threading, "Thread"):
            popen.return_value = mock.Mock()
            train_tasks.resume_training("char_det", run)
        with self.assertRaises(RuntimeError):
            train_tasks.resume_training("char_det", run)


if __name__ == "__main__":
    unittest.main()
