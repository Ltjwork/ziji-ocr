# -*- coding: utf-8 -*-
"""训练进度明细/ETA/存档轮探针的后端单元测试。

覆盖 train_tasks 的 _parse_yolo_steps 日志解析、_Task._progress_detail
（本轮 batch 进度、每轮耗时、预计剩余）与 _Task._checkpoint_epoch
（epoch{N}.pt 落盘静置判定，前端"存档轮测试页识别"的触发依据）。
"""
import os
import tempfile
import time
import unittest

from train_tasks import _Task, _parse_yolo_steps, _read_log_tail


def _progress_line(epoch, epochs, batch, batches, imgsz=1280):
    """按 ultralytics verbose 进度行格式拼一条日志片段。"""
    return (
        f"      {epoch}/{epochs}      6.49G     0.2683     0.2832     0.8203"
        f"         79       {imgsz}: 50% \u2501\u2501\u2501\u2501\u2500\u2500\u2500"
        f" {batch}/{batches} 8.4it/s 6:19<4:32"
    )


class ParseYoloStepsTests(unittest.TestCase):
    def test_parses_epoch_and_batch_from_progress_line(self):
        steps = _parse_yolo_steps(_progress_line(3, 150, 2291, 4572))
        self.assertEqual(steps, (3, 150, 2291, 4572))

    def test_takes_last_match_from_multiple_lines(self):
        text = _progress_line(1, 150, 10, 4572) + "\n" + _progress_line(2, 150, 100, 4572)
        self.assertEqual(_parse_yolo_steps(text), (2, 150, 100, 4572))

    def test_classify_style_line_also_matches(self):
        # classify 的列更少（无多项损失），仍是 epoch/epochs G内存 ... imgsz: % bar n/m
        text = "     1/150      6.5G      0.952        128        64: 50% \u2501\u2500 10/20 3.2it/s"
        self.assertEqual(_parse_yolo_steps(text), (1, 150, 10, 20))

    def test_returns_none_for_plain_text(self):
        self.assertIsNone(_parse_yolo_steps("Epoch GPU_mem box_loss cls_loss\n"))
        self.assertIsNone(_parse_yolo_steps(""))

    def test_rejects_malformed_counters(self):
        # batch 超过总数 / epoch 超过总轮数：按畸形行丢弃，不产出误导进度
        self.assertIsNone(_parse_yolo_steps(_progress_line(3, 150, 5000, 4572)))
        self.assertIsNone(_parse_yolo_steps(_progress_line(300, 150, 10, 4572)))


class TaskProgressDetailTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="train_progress_")
        self.run_dir = os.path.join(self._tmp, "run_x")
        os.makedirs(os.path.join(self.run_dir, "train", "weights"))
        self.task = _Task("t1", "char_det", 150, self.run_dir)
        self.task.status = "training"

    def tearDown(self):
        import shutil

        shutil.rmtree(self._tmp, ignore_errors=True)

    def _write_csv_rows(self, rows: int):
        with open(os.path.join(self.run_dir, "train", "results.csv"), "w",
                  encoding="utf-8") as f:
            f.write("epoch,loss\n")
            for i in range(1, rows + 1):
                f.write(f"{i},0.5\n")

    def _write_log(self, text: str):
        with open(os.path.join(self.run_dir, "train_log.txt"), "w",
                  encoding="utf-8") as f:
            f.write(text)

    def test_epoch_and_batch_progress_from_log(self):
        self._write_csv_rows(2)
        self._write_log(_progress_line(3, 150, 2291, 4572))
        detail = self.task._progress_detail()
        # 已完成 2 轮 + 第 3 轮内 2291/4572≈0.5024 → 总体 > 2/150
        self.assertEqual(detail["epoch"], 3)
        self.assertEqual(detail["batch"], {"cur": 2291, "total": 4572})
        self.assertAlmostEqual(detail["epoch_progress"], 2291 / 4572, places=3)
        self.assertGreater(detail["overall"], 2.5 / 150)

    def test_eta_from_epoch_marks(self):
        self._write_csv_rows(3)
        now = time.time()
        # 5 分钟完成 3 轮 → 每轮 100s；剩 ~147 轮 → ETA ≈ 14700s
        self.task._epoch_marks = [(now - 300, 1), (now, 3)]
        detail = self.task._progress_detail()
        self.assertAlmostEqual(detail["sec_per_epoch"], 150.0, places=1)
        self.assertAlmostEqual(detail["eta_seconds"], 150.0 * (150 - 3), places=0)

    def test_eta_falls_back_to_elapsed_ratio_before_two_marks(self):
        self._write_csv_rows(3)
        self.task.started = time.time() - 600  # 600s 完成 3/150=2%
        detail = self.task._progress_detail()
        self.assertIsNone(detail["sec_per_epoch"])
        # 600/0.02*(1-0.02) ≈ 29400
        self.assertAlmostEqual(detail["eta_seconds"], 29400.0, delta=500)

    def test_done_task_has_no_eta(self):
        self._write_csv_rows(150)
        self.task.status = "done"
        detail = self.task._progress_detail()
        self.assertEqual(detail["overall"], 1.0)
        self.assertIsNone(detail["eta_seconds"])

    def test_to_dict_exposes_progress_fields(self):
        self._write_csv_rows(1)
        self._write_log(_progress_line(2, 150, 4572, 4572))
        data = self.task.to_dict()
        for key in ("epoch", "epoch_progress", "batch", "sec_per_epoch",
                    "eta_seconds", "checkpoint_epoch"):
            self.assertIn(key, data)
        self.assertEqual(data["epoch"], 2)
        self.assertEqual(data["batch"], {"cur": 4572, "total": 4572})


class CheckpointEpochTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="train_ckpt_")
        self.run_dir = os.path.join(self._tmp, "run_y")
        self.weights = os.path.join(self.run_dir, "train", "weights")
        os.makedirs(self.weights)
        self.task = _Task("t2", "char_det", 150, self.run_dir)

    def tearDown(self):
        import shutil

        shutil.rmtree(self._tmp, ignore_errors=True)

    def _touch(self, name, age_seconds):
        path = os.path.join(self.weights, name)
        with open(path, "wb") as f:
            f.write(b"x")
        stamp = time.time() - age_seconds
        os.utime(path, (stamp, stamp))

    def test_reports_latest_settled_checkpoint(self):
        self._touch("epoch10.pt", 60)
        self._touch("epoch20.pt", 60)
        self.assertEqual(self.task._checkpoint_epoch(), 20)

    def test_skips_freshly_written_checkpoint(self):
        # 刚写的检查点可能仍在落盘（torch.save 大文件需数秒），静置 ≥5s 才上报
        self._touch("epoch10.pt", 60)
        self._touch("epoch20.pt", 1)
        self.assertEqual(self.task._checkpoint_epoch(), 10)

    def test_none_without_checkpoints(self):
        self.assertIsNone(self.task._checkpoint_epoch())
        self._touch("best.pt", 60)
        self._touch("last.pt", 60)
        self.assertIsNone(self.task._checkpoint_epoch())

    def test_none_when_weights_dir_missing(self):
        import shutil

        shutil.rmtree(self.weights)
        self.assertIsNone(self.task._checkpoint_epoch())


class ReadLogTailTests(unittest.TestCase):
    def test_reads_only_tail_bytes(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False,
                                         encoding="utf-8") as f:
            f.write("x" * 20000 + "TAIL_MARKER")
            path = f.name
        try:
            text = _read_log_tail(path, max_bytes=1024)
            self.assertTrue(text.endswith("TAIL_MARKER"))
            self.assertNotIn("x" * 2000, text)
        finally:
            os.unlink(path)

    def test_missing_file_returns_empty(self):
        self.assertEqual(_read_log_tail(os.path.join("no", "such.txt")), "")


if __name__ == "__main__":
    unittest.main()
