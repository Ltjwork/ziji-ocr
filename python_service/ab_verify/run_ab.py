# -*- coding: utf-8 -*-
"""A/B 编排：起服务实例（基线/并行）→ 等预热 → 跑页 → 对比。

- 基线：OCR_KRAKEN_WORKERS=1 + KRAKEN_PREP_PIPELINE=0 ≙ 旧版单 daemon 串行
- 并行：全默认（硬件自动定 daemon 数，worker 内流水线开启）
- service_port.txt 保护：实例写入自己的端口后立刻恢复原内容，运行中的
  App 不受影响。
"""
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

SERVICE_DIR = Path(__file__).resolve().parent.parent
WORK = Path(__file__).resolve().parent / "_out"
# 经 conda run 启动（与 App 生产方式一致）：直接用 env 的 python.exe
# 会因 conda DLL 路径不全卡在 torch 导入。
CONDA_RUN = ["conda", "run", "-n", "paddle", "python"]
BOOKS = Path(r"C:\Users\LLLL\Documents\GujiBT")
PORT_FILE = SERVICE_DIR / "service_port.txt"

PAGES = [
    str(BOOKS / "1789591116071" / "page_000.png"),
    str(BOOKS / "1789591116071" / "page_001.png"),
    str(BOOKS / "1789591116071" / "page_002.png"),
    str(BOOKS / "1790196783944" / "page_000.png"),
    str(BOOKS / "1790196783944" / "page_002.png"),
]
WARMUP = str(BOOKS / "1789591116071" / "page_032.png")


def http_get(port: int, path: str, timeout: float = 5.0):
    with urllib.request.urlopen(
        f"http://127.0.0.1:{port}{path}", timeout=timeout
    ) as resp:
        return json.loads(resp.read().decode("utf-8"))


def wait_health(port: int, deadline_s: float = 120.0) -> None:
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        try:
            http_get(port, "/health")
            return
        except Exception:
            time.sleep(1.0)
    raise SystemExit(f"service on {port} not healthy in {deadline_s}s")


def wait_workers(port: int, want_ready: int | None, deadline_s: float = 600.0):
    """等池就绪；want_ready=None 表示等 ready == total（全部预热完）。"""
    t0 = time.time()
    last = None
    while time.time() - t0 < deadline_s:
        try:
            stats = http_get(port, "/process_stats", timeout=10)
            workers = stats.get("workers") or {}
            ready, total = workers.get("ready", 0), workers.get("total", 0)
            if last != (ready, total):
                print(f"  workers ready/total = {ready}/{total}", flush=True)
                last = (ready, total)
            if want_ready is None:
                if ready >= total and ready >= 1:
                    return total
            elif ready >= want_ready:
                return total
        except Exception:
            pass
        time.sleep(2.0)
    raise SystemExit("workers did not become ready in time")


def pid_of_port(port: int):
    out = subprocess.run(
        ["netstat", "-ano", "-p", "tcp"],
        capture_output=True,
    ).stdout.decode("utf-8", errors="replace")
    for line in out.splitlines():
        if f"127.0.0.1:{port}" in line and "LISTENING" in line:
            return int(line.split()[-1])
    return None


def start_instance(tag: str, env_extra: dict) -> tuple[int, subprocess.Popen]:
    saved_port = PORT_FILE.read_text(encoding="utf-8")
    env = {**os.environ, **env_extra, "PYTHONUTF8": "1"}
    proc = subprocess.Popen(
        [*CONDA_RUN, "main.py"],
        cwd=str(SERVICE_DIR),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    # 等实例写出自己的端口，然后立刻恢复 service_port.txt（App 继续用旧实例）
    t0 = time.time()
    my_port = None
    while time.time() - t0 < 60:
        try:
            content = PORT_FILE.read_text(encoding="utf-8").strip()
            if content and content != saved_port.strip():
                my_port = int(content)
                break
        except Exception:
            pass
        time.sleep(0.5)
    if my_port is None:
        proc.kill()
        raise SystemExit(f"[{tag}] instance did not pick a port")
    PORT_FILE.write_text(saved_port, encoding="utf-8")
    print(f"[{tag}] instance pid={proc.pid} port={my_port}（service_port.txt 已恢复）", flush=True)
    return my_port, proc


def stop_instance(tag: str, port: int, proc: subprocess.Popen) -> None:
    pid = pid_of_port(port)
    for target in {pid} - {None}:
        subprocess.run(["taskkill", "/F", "/PID", str(target)],
                       capture_output=True)
    try:
        proc.wait(timeout=10)
    except Exception:
        proc.kill()
    time.sleep(2.0)
    print(f"[{tag}] stopped", flush=True)


def run_pages(tag: str, port: int) -> None:
    out_dir = WORK / tag
    log = (WORK / f"{tag}_child.log").open("w", encoding="utf-8")
    subprocess.run(
        [*CONDA_RUN, str(Path(__file__).resolve().parent / "ab_segment_run.py"),
         str(port), str(out_dir), WARMUP, *PAGES],
        stdout=log,
        stderr=subprocess.STDOUT,
        check=True,
    )


def main() -> None:
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    if which in ("base", "both"):
        port, proc = start_instance("base", {
            "OCR_KRAKEN_WORKERS": "1",
            "KRAKEN_PREP_PIPELINE": "0",
        })
        try:
            wait_health(port)
            wait_workers(port, want_ready=1)
            run_pages("base", port)
        finally:
            stop_instance("base", port, proc)
    if which in ("parallel", "both"):
        port, proc = start_instance("parallel", {})
        try:
            wait_health(port)
            total = wait_workers(port, want_ready=None, deadline_s=900)
            print(f"[parallel] pool fully ready: {total} workers", flush=True)
            run_pages("parallel", port)
        finally:
            stop_instance("parallel", port, proc)


if __name__ == "__main__":
    main()
