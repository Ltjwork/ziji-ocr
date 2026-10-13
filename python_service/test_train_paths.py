# -*- coding: utf-8 -*-
"""训练路径配置测试：默认值、读写、热生效、测试覆盖缝。"""
import os
import shutil
import tempfile
import unittest

import train_data
import train_paths


class TrainPathsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="train_paths_")
        self._old_config = train_paths._CONFIG_PATH
        train_paths._CONFIG_PATH = os.path.join(self._tmp, "train_paths.json")
        train_paths.reset_cache()
        # 隔离 train_data 的模块覆盖缝（避免别的测试残留影响）
        self._old_datasets_root = train_data.DATASETS_ROOT
        self._old_trained_root = train_data.TRAINED_ROOT
        train_data.DATASETS_ROOT = None
        train_data.TRAINED_ROOT = None

    def tearDown(self):
        train_paths._CONFIG_PATH = self._old_config
        train_paths.reset_cache()
        train_data.DATASETS_ROOT = self._old_datasets_root
        train_data.TRAINED_ROOT = self._old_trained_root
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_defaults_without_config(self):
        cfg = train_paths.load_paths()
        self.assertEqual(cfg, train_paths.defaults())
        # train_data 取值函数跟随配置
        self.assertEqual(train_data.datasets_root(), cfg["dataset_root"])
        self.assertEqual(train_data.trained_root_dir(), cfg["trained_root"])

    def test_save_and_reload_persists(self):
        ds = os.path.join(self._tmp, "my_datasets")
        tm = os.path.join(self._tmp, "my_models")
        saved = train_paths.save_paths(dataset_root=ds, trained_root=tm)
        self.assertEqual(saved["dataset_root"], os.path.normpath(ds))
        # 缓存清空后从盘上重读（模拟另一进程/重启）
        train_paths.reset_cache()
        cfg = train_paths.load_paths()
        self.assertEqual(cfg["trained_root"], os.path.normpath(tm))
        # train_data 跟随新配置
        self.assertEqual(train_data.datasets_root(), os.path.normpath(ds))

    def test_partial_update_keeps_other_field(self):
        first = os.path.join(self._tmp, "ds1")
        train_paths.save_paths(dataset_root=first, trained_root="")
        # 只改 trained_root，dataset_root 保留
        tm = os.path.join(self._tmp, "tm2")
        train_paths.save_paths(dataset_root="", trained_root=tm)
        train_paths.reset_cache()
        cfg = train_paths.load_paths()
        self.assertEqual(cfg["dataset_root"], os.path.normpath(first))
        self.assertEqual(cfg["trained_root"], os.path.normpath(tm))

    def test_module_override_wins_over_config(self):
        train_paths.save_paths(dataset_root=os.path.join(self._tmp, "cfg_ds"))
        train_data.DATASETS_ROOT = os.path.join(self._tmp, "override_ds")
        try:
            self.assertEqual(
                train_data.datasets_root(),
                os.path.join(self._tmp, "override_ds"))
        finally:
            train_data.DATASETS_ROOT = None

    def test_corrupt_config_falls_back_to_defaults(self):
        with open(train_paths._CONFIG_PATH, "w", encoding="utf-8") as f:
            f.write("{not json")
        train_paths.reset_cache()
        self.assertEqual(train_paths.load_paths(), train_paths.defaults())


if __name__ == "__main__":
    unittest.main()
