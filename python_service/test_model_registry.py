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

    def test_delete_checkpoint_removes_epoch_file(self):
        run_dir = _make_run(self._trained, "char_det", "run_ck")
        ck = os.path.join(run_dir, "train", "weights", "epoch10.pt")
        with open(ck, "wb") as f:
            f.write(b"x" * 1024)
        result = train_registry.delete_checkpoint("char_det", ck)
        self.assertFalse(os.path.exists(ck))
        self.assertEqual(result["size"], 1024)

    def test_delete_checkpoint_allows_best_last_and_updates_registry(self):
        # 每个版本（含 best/last）都可单独删除；删 best 同步清注册表
        # best 标记，run 仍登记（剩余轮数/曲线入口保留）。
        run_dir = _make_run(self._trained, "char_det", "run_ck2")
        w = os.path.join(run_dir, "train", "weights")
        open(os.path.join(w, "last.pt"), "wb").close()
        train_registry.reconcile_disk_runs()
        # last 直接删（无注册表联动）
        train_registry.delete_checkpoint("char_det",
                                         os.path.join(w, "last.pt"))
        self.assertFalse(os.path.exists(os.path.join(w, "last.pt")))
        # best 删后该 run 的注册表 best 置空，run 条目仍在
        train_registry.delete_checkpoint("char_det",
                                         os.path.join(w, "best.pt"))
        self.assertFalse(os.path.exists(os.path.join(w, "best.pt")))
        models = train_registry.list_models()
        runs = [r for r in models["char_det"]["runs"]
                if r["run_dir"] == run_dir]
        self.assertEqual(len(runs), 1)
        self.assertFalse(runs[0]["best"])
        # 非 weights 结构与训练目录外的路径一律拒绝
        with self.assertRaises(ValueError):
            train_registry.delete_checkpoint(
                "char_det", os.path.join(run_dir, "done.json"))
        with self.assertRaises(ValueError):
            train_registry.delete_checkpoint(
                "char_det", os.path.join(self._tmp, "evil.pt"))

    def test_activate_epoch_checkpoint_runs_and_falls_back_metrics(self):
        # 训练曲线弹窗"按轮启用"：activate 收 epoch{N}.pt 路径（历史上
        # 这里 AttributeError 500，按轮启用从未成功过）
        run_dir = _make_run(self._trained, "char_det", "run_epoch_act")
        ck = os.path.join(run_dir, "train", "weights", "epoch40.pt")
        open(ck, "wb").close()
        models = train_registry.activate_model("char_det", ck)
        self.assertTrue(models["active_exists"])
        nc = os.path.normcase(os.path.abspath(ck))
        self.assertEqual(
            os.path.normcase(os.path.abspath(models["active_source"])), nc)
        # 指标兜底到所在 run 的登记值
        self.assertEqual(models["metrics"], {"metrics/mAP50(B)": 0.2})

    def test_delete_checkpoint_rejects_active_source(self):
        run_dir = _make_run(self._trained, "char_det", "run_ck3")
        w = os.path.join(run_dir, "train", "weights")
        ck = os.path.join(w, "epoch20.pt")
        open(ck, "wb").close()
        train_registry.activate_model("char_det", ck)
        with self.assertRaises(ValueError):
            train_registry.delete_checkpoint("char_det", ck)
        # 删其他轮不受影响；当前启用走稳定副本，推理不中断
        other = os.path.join(w, "epoch30.pt")
        open(other, "wb").close()
        train_registry.delete_checkpoint("char_det", other)
        self.assertFalse(os.path.exists(other))
        models = train_registry.list_models()
        self.assertTrue(models["char_det"]["active_exists"])
        self.assertTrue(os.path.exists(models["char_det"]["active"]))


    def test_list_models_attaches_checkpoints_with_metrics(self):
        # 管理页展开行的数据源：list_models 一次带回每个 run 的检查点
        # 清单与每轮主指标（含 nan 降级），不用逐 run 拉 /train/curve。
        run_dir = _make_run(self._trained, "char_det", "run_ck_list")
        w = os.path.join(run_dir, "train", "weights")
        with open(os.path.join(run_dir, "train", "results.csv"), "w",
                  encoding="utf-8", newline="") as f:
            f.write("epoch,metrics/mAP50-95(B)\n"
                    "3,nan\n10,0.60\n20,0.50\n")
        # 注册表登记指标也用主指标列（best 行展示来源）
        with open(os.path.join(run_dir, "done.json"), "w",
                  encoding="utf-8") as f:
            json.dump({"best": os.path.join(w, "best.pt"),
                       "metrics": {"metrics/mAP50-95(B)": 0.61},
                       "epochs": 2}, f, ensure_ascii=False)
        for n in (10, 20):
            open(os.path.join(w, "epoch%d.pt" % n), "wb").close()
        open(os.path.join(w, "last.pt"), "wb").close()
        train_registry.reconcile_disk_runs()
        models = train_registry.list_models()
        runs = {r["run_dir"]: r for r in models["char_det"]["runs"]}
        cks = runs[run_dir]["checkpoints"]
        names = [c["name"] for c in cks]
        self.assertEqual(names, ["epoch10.pt", "epoch20.pt",
                                 "best.pt", "last.pt"])
        by_name = {c["name"]: c for c in cks}
        self.assertEqual(by_name["epoch10.pt"]["metric"], 0.6)
        self.assertEqual(by_name["epoch20.pt"]["metric"], 0.5)
        self.assertEqual(by_name["epoch20.pt"]["epoch"], 20)
        self.assertEqual(by_name["best.pt"]["metric"], 0.61)  # 注册表登记值
        self.assertEqual(by_name["last.pt"]["metric"], 0.5)  # CSV 末轮
        json.dumps(cks, allow_nan=False)  # nan 行已降级，无泄漏

    def test_import_model_registers_external_pt(self):
        src_pt = os.path.join(self._tmp, "external.pt")
        with open(src_pt, "wb") as f:
            f.write(b"x" * 2048)
        record = train_registry.import_model("char_det", src_pt)
        best = record["best"]
        self.assertTrue(os.path.exists(best))
        self.assertIn("run_import_", record["run_dir"])
        models = train_registry.list_models()
        runs = models["char_det"]["runs"]
        self.assertTrue(any(r["run_dir"] == record["run_dir"] for r in runs))
        # 导入后可按 best 启用（与其他训练产物同等管理）
        models = train_registry.activate_model("char_det", best)
        self.assertTrue(models["active_exists"])
        # 拒绝非 .pt 与不存在的文件
        with self.assertRaises(ValueError):
            train_registry.import_model("char_det", src_pt + ".txt")
        with self.assertRaises(ValueError):
            train_registry.import_model(
                "char_det", os.path.join(self._tmp, "nope.pt"))

    def test_cleanup_scan_counts_epochs_and_status(self):
        run_dir = _make_run(self._trained, "char_det", "run_scan")
        w = os.path.join(run_dir, "train", "weights")
        open(os.path.join(w, "epoch10.pt"), "wb").close()
        with open(os.path.join(w, "epoch20.pt"), "wb") as f:
            f.write(b"x" * 4096)
        # 未完成残目录（无 results.csv，scan_layer_runs 不认、清理页可整删）
        abort = os.path.join(self._trained, "char_det", "run_abort")
        os.makedirs(abort)
        train_registry.reconcile_disk_runs()
        scan = train_registry.cleanup_scan()
        runs = {r["name"]: r for r in scan["runs"]}
        self.assertEqual(runs["run_scan"]["epochs_count"], 2)
        self.assertTrue(runs["run_scan"]["registered"])
        self.assertTrue(runs["run_scan"]["finished"])
        self.assertTrue(runs["run_scan"]["trained"])
        self.assertFalse(runs["run_abort"]["registered"])
        self.assertFalse(runs["run_abort"]["trained"])

    def test_cleanup_run_epochs_keeps_best_last_and_active(self):
        run_dir = _make_run(self._trained, "char_det", "run_clean")
        w = os.path.join(run_dir, "train", "weights")
        open(os.path.join(w, "last.pt"), "wb").close()
        for n in (10, 20, 30):
            open(os.path.join(w, "epoch%d.pt" % n), "wb").close()
        train_registry.activate_model("char_det",
                                      os.path.join(w, "epoch20.pt"))
        result = train_registry.cleanup_run("char_det", run_dir, "epochs")
        self.assertEqual(result["deleted"], 2)
        self.assertEqual(result["skipped_active"], 1)
        self.assertTrue(os.path.exists(os.path.join(w, "best.pt")))
        self.assertTrue(os.path.exists(os.path.join(w, "last.pt")))
        self.assertTrue(os.path.exists(os.path.join(w, "epoch20.pt")))
        self.assertFalse(os.path.exists(os.path.join(w, "epoch10.pt")))

    def test_cleanup_run_dir_deletes_unregistered_only(self):
        abort = os.path.join(self._trained, "char_det", "run_abort2")
        os.makedirs(abort)
        train_registry.cleanup_run("char_det", abort, "dir")
        self.assertFalse(os.path.exists(abort))
        # 已登记的 run 拒绝整删（走 /models/delete_run 同步停用与注册表）
        run_dir = _make_run(self._trained, "char_det", "run_reg")
        train_registry.reconcile_disk_runs()
        with self.assertRaises(ValueError):
            train_registry.cleanup_run("char_det", run_dir, "dir")
        self.assertTrue(os.path.exists(run_dir))


if __name__ == "__main__":
    unittest.main()
