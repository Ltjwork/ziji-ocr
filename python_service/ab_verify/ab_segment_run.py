# -*- coding: utf-8 -*-
"""A/B 驱动：对一组书页调 /segment，落盘响应（去 debug_trace）与耗时。

用法：python ab_segment_run.py <port> <out_dir> <warmup_page> <page>...
输出：out_dir/<序号>_<书号>_<页名>.json + out_dir/timing.json
"""
import json
import sys
import time
import urllib.request
from pathlib import Path


def post_segment(port: int, image_path: str, timeout: float = 900.0) -> dict:
    body = json.dumps({
        "image_path": image_path,
        "layout_mode": "all_text",
        "orientation": "vertical",
        "horizontal_dir": "ltr",
        "vertical_dir": "ttb",
    }).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/segment",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main() -> None:
    port = int(sys.argv[1])
    out_dir = Path(sys.argv[2])
    warmup = sys.argv[3]
    pages = sys.argv[4:]
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[warmup] {warmup}", flush=True)
    t0 = time.time()
    post_segment(port, warmup)
    print(f"[warmup] done in {time.time() - t0:.1f}s", flush=True)

    timing = []
    for i, page in enumerate(pages):
        tag = f"{i:02d}_{'_'.join(Path(page).parts[-2:]).replace('.png', '')}"
        print(f"[run] {page}", flush=True)
        t0 = time.time()
        try:
            result = post_segment(port, page)
        except Exception as exc:
            import traceback
            traceback.print_exc()
            timing.append({"page": page, "error": str(exc)})
            continue
        elapsed = time.time() - t0
        result.pop("debug_trace", None)
        result.pop("debug_image_path", None)
        result.pop("mask_image_path", None)
        (out_dir / f"{tag}.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        n_chars = len(result.get("blocks") or [])
        n_lines = len(result.get("lines") or [])
        timing.append({"page": page, "seconds": round(elapsed, 2),
                       "lines": n_lines, "chars": n_chars})
        print(f"[run] {elapsed:6.1f}s lines={n_lines} chars={n_chars}", flush=True)

    (out_dir / "timing.json").write_text(
        json.dumps(timing, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    total = sum(t["seconds"] for t in timing)
    print(f"[run] total {total:.1f}s for {len(pages)} pages", flush=True)


if __name__ == "__main__":
    main()
