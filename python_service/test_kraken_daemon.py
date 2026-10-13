# -*- coding: utf-8 -*-
"""kraken_bridge 常驻 daemon 的协议测试：用 stub worker 脚本代替真实
kraken 环境（无重型依赖），覆盖请求往返、stdout 噪音容忍、超时重启、
shutdown 与 stdin 关闭自杀。"""

import json
import sys
import textwrap
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from kraken_bridge import _KrakenDaemon

STUB_WORKER = textwrap.dedent(
    """
    import json, sys, time
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        op = req.get("op")
        rid = req.get("id")
        if op == "ping":
            print("noise line before pong", flush=True)
            print(json.dumps({"id": rid, "ok": True, "result": {"pong": True}}), flush=True)
        elif op == "slow":
            time.sleep(5)
            print(json.dumps({"id": rid, "ok": True, "result": {}}), flush=True)
        elif op == "sleep":
            time.sleep(float(req.get("payload", {}).get("secs", 0.1)))
            print(json.dumps({"id": rid, "ok": True, "result": {}}), flush=True)
        elif op == "boom":
            sys.exit(3)
        elif op == "cuda_fail":
            # 模拟致命 CUDA 错误（上下文损坏）：首次调用返回 CUDA 错误并落
            # 标记文件；进程重启后（标记已存在）恢复正常——验证"致命错误
            # 杀进程 + 下次请求自动重启/池重试一次"的自愈链路。
            from pathlib import Path as _P
            raw = req.get("payload", {}).get("marker", "")
            marker = _P(raw) if raw else None
            if marker is not None and marker.exists():
                print(json.dumps({"id": rid, "ok": True, "result": {"recovered": True}}), flush=True)
            else:
                if marker is not None:
                    marker.write_text("x", encoding="utf-8")
                print(json.dumps({"id": rid, "ok": False, "error": "CUDA error: an illegal memory access was encountered"}), flush=True)
        elif op == "oom_fail":
            # 瞬态 OOM：不该触发杀进程/池重试
            print(json.dumps({"id": rid, "ok": False, "error": "CUDA error: out of memory"}), flush=True)
        elif op == "echo":
            print(json.dumps({"id": rid, "ok": True, "result": req.get("payload")}), flush=True)
        elif op == "shutdown":
            print(json.dumps({"id": rid, "ok": True, "result": {"bye": True}}), flush=True)
            break
    """
)


class KrakenDaemonTests(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.worker = Path(self._tmp.name) / "stub_worker.py"
        self.worker.write_text(STUB_WORKER, encoding="utf-8")

    def _daemon(self, timeout=10.0):
        return _KrakenDaemon(
            sys.executable,
            str(self.worker),
            request_timeout=timeout,
        )

    def test_request_roundtrip_tolerates_stdout_noise(self):
        d = self._daemon()
        self.addCleanup(d.shutdown)
        result = d.request("ping")
        self.assertEqual(result, {"pong": True})
        # 噪音行被跳过，第二条请求仍能正确按 id 匹配
        result = d.request("echo", {"hello": "世界"})
        self.assertEqual(result, {"hello": "世界"})

    def test_timeout_kills_and_next_request_restarts(self):
        d = self._daemon(timeout=1.0)
        self.addCleanup(d.shutdown)
        with self.assertRaises(RuntimeError) as ctx:
            d.request("slow")
        self.assertIn("超时", str(ctx.exception))
        # 超时后自动重启，后续请求正常
        self.assertEqual(d.request("ping"), {"pong": True})

    def test_crash_raises_and_next_request_restarts(self):
        d = self._daemon()
        self.addCleanup(d.shutdown)
        with self.assertRaises(RuntimeError):
            d.request("boom")
        self.assertEqual(d.request("ping"), {"pong": True})

    def test_fatal_cuda_error_kills_daemon_and_next_request_restarts(self):
        # 致命 CUDA 错误后进程被杀（否则坏上下文会重复报同一错误），下次
        # 请求自动重启新进程恢复正常
        d = self._daemon()
        self.addCleanup(d.shutdown)
        marker = Path(self._tmp.name) / "cuda_marker"
        with self.assertRaises(RuntimeError) as ctx:
            d.request("cuda_fail", {"marker": str(marker)})
        self.assertIn("illegal memory access", str(ctx.exception))
        self.assertFalse(d._alive())  # 中毒进程已终止
        self.assertEqual(
            d.request("cuda_fail", {"marker": str(marker)}), {"recovered": True}
        )

    def test_transient_oom_error_keeps_daemon_alive(self):
        # CUDA OOM 是瞬态错误：不杀进程、池也不重试，直接上抛
        d = self._daemon()
        self.addCleanup(d.shutdown)
        with self.assertRaises(RuntimeError) as ctx:
            d.request("oom_fail")
        self.assertIn("out of memory", str(ctx.exception))
        self.assertTrue(d._alive())
        self.assertEqual(d.request("ping"), {"pong": True})

    def test_shutdown_stops_process(self):
        d = self._daemon()
        d.request("ping")
        d.shutdown()
        self.assertFalse(d._alive())

    def test_worker_exits_when_stdin_closes(self):
        import subprocess

        proc = subprocess.Popen(
            [sys.executable, str(self.worker)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        proc.stdin.close()
        rc = proc.wait(timeout=10)
        self.assertEqual(rc, 0)


class DaemonPoolTests(unittest.TestCase):
    """_DaemonPool 的并发调度测试：同样用 stub worker（sleep op 可控时长）。"""

    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.worker = Path(self._tmp.name) / "stub_worker.py"
        self.worker.write_text(STUB_WORKER, encoding="utf-8")

    def _daemon(self, tag=""):
        return _KrakenDaemon(sys.executable, str(self.worker), tag=tag)

    def _pool(self, count: int):
        from kraken_bridge import _DaemonPool

        pool = _DaemonPool()
        for i in range(count):
            d = self._daemon(tag=f"k{i + 1}")
            self.addCleanup(d.shutdown)
            pool.add_daemon(d)
        return pool

    @staticmethod
    def _run_threads(fns):
        import threading

        threads = [threading.Thread(target=fn) for fn in fns]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=60)

    def test_two_members_run_concurrently(self):
        import time

        pool = self._pool(2)
        results = []

        def call(i):
            results.append(pool.request("sleep", {"secs": 0.8}))

        t0 = time.time()
        self._run_threads([lambda: call(0), lambda: call(1)])
        elapsed = time.time() - t0
        self.assertEqual(len(results), 2)
        # 两个 0.8s 请求在两个成员上并行：总耗时远小于串行的 1.6s。
        # 余量放宽到 1.5s（进程启动/调度抖动）。
        self.assertLess(elapsed, 1.5)

    def test_single_member_serializes_requests(self):
        import time

        pool = self._pool(1)
        done = []

        def call():
            pool.request("sleep", {"secs": 0.6})
            done.append(1)

        t0 = time.time()
        self._run_threads([call, call])
        elapsed = time.time() - t0
        self.assertEqual(len(done), 2)
        # 单成员实例锁保证两个请求排队执行（协议安全），总耗时 ≥ 1.2s。
        self.assertGreaterEqual(elapsed, 1.15)

    def test_crashed_member_pool_keeps_serving(self):
        pool = self._pool(2)
        with self.assertRaises(RuntimeError):
            pool.request("boom")  # 崩在某个成员上
        # 该成员惰性重启，池继续服务
        self.assertEqual(pool.request("ping"), {"pong": True})
        self.assertEqual(pool.size, 2)

    def test_fatal_cuda_error_pool_retries_once_and_recovers(self):
        # 致命 CUDA 错误：池在重启后的新进程上重试同一请求一次，整页
        # 识别不因单次 CUDA 崩溃而失败（用户实测整书识别反复报 CUDA
        # illegal memory access 直到重启后端）
        pool = self._pool(1)
        marker = Path(self._tmp.name) / "pool_marker"
        self.assertEqual(
            pool.request("cuda_fail", {"marker": str(marker)}),
            {"recovered": True},
        )
        # 重试成功后池仍健康
        self.assertEqual(pool.request("ping"), {"pong": True})
        self.assertEqual(pool.size, 1)

    def test_fatal_cuda_error_pool_raises_after_retry_still_failing(self):
        # 重试后仍致命失败（真实场景：CUDA/驱动持续异常）：正常上抛，
        # 不无限重试
        pool = self._pool(1)
        with self.assertRaises(RuntimeError) as ctx:
            pool.request("cuda_fail", {"marker": ""})  # 无标记文件：每次都失败
        self.assertIn("illegal memory access", str(ctx.exception))
        self.assertEqual(pool.size, 1)

    def test_transient_oom_pool_does_not_retry(self):
        # 瞬态 OOM 不触发池重试（当前实现直接上抛）
        pool = self._pool(1)
        with self.assertRaises(RuntimeError) as ctx:
            pool.request("oom_fail")
        self.assertIn("out of memory", str(ctx.exception))

    def test_shutdown_drains_inflight_and_rejects_new(self):
        import threading

        pool = self._pool(1)
        outcome = []

        def inflight():
            outcome.append(pool.request("sleep", {"secs": 1.0}))

        t = threading.Thread(target=inflight)
        t.start()
        import time

        time.sleep(0.3)  # 确保请求已在途
        pool.shutdown(drain_timeout=10)
        t.join(timeout=10)
        self.assertEqual(outcome, [{}])  # 在途请求被排空等待，正常完成
        with self.assertRaises(RuntimeError):
            pool.request("ping")  # 新请求被拒

    def test_request_waits_for_first_member(self):
        import threading
        import time

        from kraken_bridge import _DaemonPool

        pool = _DaemonPool()
        outcome = []

        def caller():
            outcome.append(pool.request("echo", {"x": 1}))

        t = threading.Thread(target=caller)
        t.start()
        time.sleep(0.4)  # 请求线程应阻塞在等待空闲成员
        self.assertEqual(outcome, [])
        d = self._daemon()
        self.addCleanup(d.shutdown)
        pool.add_daemon(d)
        t.join(timeout=10)
        self.assertEqual(outcome, [{"x": 1}])
        pool.shutdown()

    def test_wait_ready_and_size(self):
        from kraken_bridge import _DaemonPool

        pool = _DaemonPool()
        self.assertEqual(pool.size, 0)
        self.assertFalse(pool.wait_ready(1, timeout=0.2))
        d = self._daemon()
        self.addCleanup(d.shutdown)
        pool.add_daemon(d)
        self.assertTrue(pool.wait_ready(1, timeout=1))
        self.assertEqual(pool.size, 1)
        pool.shutdown()


if __name__ == "__main__":
    unittest.main()
