"""拆字可视化调试工具。

用法:
    python debug_visualize.py <图片路径> [--region x,y,w,h]

不带 --region: 跑全图切分 (等同 /segment 接口)
带 --region: 只切指定行框 (等同 /segment_region 接口)

输出:
    <图片>_debug.png          原图 + 蓝框(单字) + 绿框(行)
    <图片>_debug.txt          完整 debug_trace 日志
    控制台同时打印每个框的坐标和切分数
"""

import sys
import os
import argparse
import json

import cv2

# 让脚本能直接 import segmenter（和 main.py 同目录运行）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import segmenter  # noqa: E402


def parse_region(s: str):
    parts = [int(v.strip()) for v in s.split(",")]
    if len(parts) != 4:
        raise ValueError("region 必须是 x,y,w,h")
    return tuple(parts)


def draw_blocks(img, blocks, color, thickness):
    for b in blocks:
        x, y, w, h = b["x"], b["y"], b["w"], b["h"]
        cv2.rectangle(img, (x, y), (x + w, y + h), color, thickness)
        if "text" in b and b["text"]:
            cv2.putText(img, b["text"], (x, max(0, y - 4)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 1, cv2.LINE_AA)


def draw_lines(img, lines, color, thickness):
    for ln in lines:
        x, y, w, h = ln["x"], ln["y"], ln["w"], ln["h"]
        cv2.rectangle(img, (x, y), (x + w, y + h), color, thickness)


def run_full_image(image_path: str, out_img: str, out_log: str):
    segmenter.begin_debug_trace()
    result = segmenter.segment_image_with_metadata(image_path)
    trace = segmenter.debug_trace_snapshot()

    img = segmenter._imread(image_path)
    if img is None:
        raise RuntimeError(f"无法读取图片: {image_path}")

    draw_lines(img, result.get("lines", []), (0, 255, 0), 3)
    draw_blocks(img, result.get("blocks", []), (255, 0, 0), 2)

    cv2.imwrite(out_img, img)
    with open(out_log, "w", encoding="utf-8") as f:
        f.write("\n".join(trace))

    print(f"engine = {result.get('engine')}")
    print(f"lines  = {len(result.get('lines', []))}")
    print(f"blocks = {len(result.get('blocks', []))}")
    print()
    for i, ln in enumerate(result.get("lines", [])):
        chars = ln.get("chars", [])
        text_preview = "".join(c.get("text", "") for c in chars)
        print(f"line#{i} ({ln['x']},{ln['y']},{ln['w']},{ln['h']}) "
              f"chars={len(chars)} text={text_preview!r}")
        for j, c in enumerate(chars):
            print(f"    char#{j} ({c['x']},{c['y']},{c['w']},{c['h']}) text={c.get('text','')!r}")
    print()
    print(f"可视化图已保存: {out_img}")
    print(f"调试日志已保存: {out_log}")
    print()
    print("=== 关键日志 (后 60 行) ===")
    for line in trace[-60:]:
        print(line)


def run_region(image_path: str, region, out_img: str, out_log: str):
    import kraken_bridge

    segmenter.begin_debug_trace()
    line = kraken_bridge.kraken_segment_line(
        image_path,
        {"x": region[0], "y": region[1], "w": region[2], "h": region[3]},
        line_id="debug_line",
        line_no=0,
        orientation="vertical",
        horizontal_dir="rtl",
        char_splitter=segmenter.make_kraken_char_splitter(
            image_path, "vertical", "rtl"
        ),
    )
    trace = segmenter.debug_trace_snapshot()

    img = segmenter._imread(image_path)
    if img is None:
        raise RuntimeError(f"无法读取图片: {image_path}")

    rx, ry, rw, rh = region
    cv2.rectangle(img, (rx, ry), (rx + rw, ry + rh), (0, 255, 0), 3)
    draw_blocks(img, line.get("chars", []), (255, 0, 0), 2)

    cv2.imwrite(out_img, img)
    with open(out_log, "w", encoding="utf-8") as f:
        f.write("\n".join(trace))

    chars = line.get("chars", [])
    text_preview = "".join(c.get("text", "") for c in chars)
    print(f"region ({rx},{ry},{rw},{rh}) chars={len(chars)} text={text_preview!r}")
    for j, c in enumerate(chars):
        print(f"    char#{j} ({c['x']},{c['y']},{c['w']},{c['h']}) text={c.get('text','')!r}")
    print()
    print(f"可视化图已保存: {out_img}")
    print(f"调试日志已保存: {out_log}")
    print()
    print("=== 关键日志 (后 60 行) ===")
    for line in trace[-60:]:
        print(line)


def main():
    parser = argparse.ArgumentParser(description="拆字可视化调试")
    parser.add_argument("image_path", help="图片路径")
    parser.add_argument("--region", default=None,
                        help="只切指定行框，格式 x,y,w,h。不传则跑全图。")
    args = parser.parse_args()

    if not os.path.exists(args.image_path):
        print(f"图片不存在: {args.image_path}", file=sys.stderr)
        sys.exit(1)

    base, ext = os.path.splitext(args.image_path)
    out_img = f"{base}_debug.png"
    out_log = f"{base}_debug.txt"

    if args.region:
        region = parse_region(args.region)
        run_region(args.image_path, region, out_img, out_log)
    else:
        run_full_image(args.image_path, out_img, out_log)


if __name__ == "__main__":
    main()