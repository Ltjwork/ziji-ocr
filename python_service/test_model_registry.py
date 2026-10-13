# -*- coding: utf-8 -*-
"""模型注册表磁盘对账与 run 删除测试（曲线修复的核心保障）。"""
import json
import os
import shutil
import tempfile
import unittest

import train_data
import train_registry


def _make_run(root, layer, name, *, best=True, done=True, results=True):
    run_dir = os.path.join(root, layer, name)
    os.makedirs(os.path.join(run_dir, "train", "weights"), exist_ok=True)
    if results:
        with open(os.path.join(run_dir, "train", "results.csv"), "w",
                  encoding="utf-8", newline="") as f:
            f.write("epoch,time,train/box_loss,metrics/mAP50(B)\n"
                    "1,1.0,2.0,0.10\n2,1.5,1.8,0.20\n")
    if best:
        open(os.path.join(run_dir, "train", "weights", "best.pt"), "wb").close()
    if done:
        with open(os.path.join(run_dir, "done.json"), "w",
                  encoding="utf-8") as f:
            json.dump({"best": os.path.join(run_dir, "train", "weights",
                                            "best.pt"),
                       "metrics": {"metrics/mAP50(B)": 0.2}, "epochs": 2},
                      f, ensure_ascii=False)
    return run_dir


class RegistryDiskReconcileTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="reg_reconcile_")
        self._old_trained = train_data.TRAINED_ROOT
        self._old_registry = train_registry.REGISTRY_PATH
        self._trained = os.path.join(self._tmp, "trained")
        train_data.TRAINED_ROOT = self._trained
        train_registry.REGISTRY_PATH = os.path.join(self._tmp, "registry.json")
        # activate 会把 best 拷到 SERVICE_DIR/models：沙箱化，绝不碰真实
        # 应用模型目录（历史上一次测试污染过真实 active_char_det.pt）
        self._old_service_dir = train_registry.SERVICE_DIR
        train_registry.SERVICE_DIR = self._tmp

    def tearDown(self):
        train_data.TRAINED_ROOT = self._old_trained
        train_registry.REGISTRY_PATH = self._old_registry
        train_registry.SERVICE_DIR = self._old_service_dir
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_orphan_run_gets_registered_and_listed(self):
        # 磁盘有完整 run 但注册表没登记（历史漏登记/注册写入异常）
        _make_run(self._trained, "line_det", "run_20260101_000000")
        added = train_registry.reconcile_disk_runs()
        self.assertEqual(added, 1)
        models = train_registry.list_models()
        runs = models["line_det"]["runs"]
        self.assertEqual(len(runs), 1)
        self.assertTrue(runs[0]["best"].endswith("best.pt"))
        self.assertEqual(runs[0]["epochs"], 2)
        # 幂等：再对账不重复
        self.assertEqual(train_registry.reconcile_disk_runs(), 0)

    def test_incomplete_run_dir_ignored_and_case_dedupe(self):
        # 没有 results.csv 的残目录不算；大小写不同的同路径不重复登记
        _make_run(self._trained, "char_det", "run_partial", results=False)
        good = _make_run(self._trained, "char_det", "run_good")
        train_registry.reconcile_disk_runs()
        # 手工以不同大小写写入同一路径的重复条目
        reg = train_registry._load_registry()
        reg["layers"]["char_det"]["runs"].append(
            {"run_dir": good.upper(), "best": None})
        train_registry._save_registry(reg)
        train_registry.reconcile_disk_runs()
        models = train_registry.list_models()
        runs = models["char_det"]["runs"]
        dirs = {os.path.normcase(r["run_dir"]) for r in runs}
        self.assertEqual(len(dirs), 1)
        # 列表本身也必须只剩一条：双条同 best 路径会让客户端模型下拉
        # 因重复 value 断言崩溃（此前用 Set 比对掩盖过这个口径）
        self.assertEqual(len(runs), 1)

    def test_duplicate_run_entries_merged(self):
        # 训练进行中 reconcile 补占位（无 metrics）+ 完成登记又 append：
        # 同 run_dir 双条、best 路径相同——对账合并为一条，保留有训练
        # 结果的（客户端下拉因重复 value 崩溃的注册表侧根因）
        run_dir = _make_run(self._trained, "region_det", "run_dup")
        best = os.path.join(run_dir, "train", "weights", "best.pt")
        reg = train_registry._load_registry()
        entry = reg["layers"].setdefault("region_det",
                                         {"active": None, "runs": []})
        entry["runs"].append(
            {"run_dir": run_dir, "best": best, "metrics": None,
             "epochs": None, "started": 100.0, "reconciled": True})
        entry["runs"].append(
            {"run_dir": run_dir, "best": best,
             "metrics": {"metrics/mAP50(B)": 0.9}, "epochs": 300,
             "base_model": "yolov8l.pt", "started": 99.0})
        train_registry._save_registry(reg)
        added = train_registry.reconcile_disk_runs()
        self.assertEqual(added, 0)  # 磁盘 run 已登记，不再补
        runs = train_registry.list_models()["region_det"]["runs"]
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["epochs"], 300)  # 保留有训练结果的
        bests = [r["best"] for r in runs]
        self.assertEqual(len(bests), len(set(bests)))

    def test_delete_run_removes_dir_and_entry(self):
        run_dir = _make_run(self._trained, "region_det", "run_del")
        train_registry.reconcile_disk_runs()
        result = train_registry.delete_run("region_det", run_dir)
        self.assertTrue(result["run_dir"])
        self.assertFalse(os.path.exists(run_dir))
        models = train_registry.list_models()
        self.assertEqual(models["region_det"]["runs"], [])

    def test_delete_run_rejects_outside_path(self):
        outside = os.path.join(self._tmp, "outside", "run_x")
        os.makedirs(outside)
        with self.assertRaises(ValueError):
            train_registry.delete_run("region_det", outside)

    def test_delete_run_deactivates_when_active(self):
        run_dir = _make_run(self._trained, "char_det", "run_active")
        train_registry.reconcile_disk_runs()
        # 把该 run 的 best 启用（activate 会拷贝到应用模型目录）
        models = train_registry.activate_model(
            "char_det", os.path.join(run_dir, "train", "weights", "best.pt"))
        self.assertTrue(models["active"])
        result = train_registry.delete_run("char_det", run_dir)
        self.assertTrue(result["deactivated"])
        models = train_registry.list_models()
        self.assertFalse(models["char_det"]["active"])
        self.assertFalse(os.path.exists(run_dir))


if __name__ == "__main__":
    unittest.main()
