# -*- coding: utf-8 -*-
"""A/B 结果对比：逐页归一化（时间戳 id）后逐字节比较 + 耗时表。"""
import json
import re
import sys
from pathlib import Path

WORK = Path(__file__).resolve().parent / "_out"


def normalize(obj) -> str:
    s = json.dumps(obj, ensure_ascii=False, sort_keys=True)
    return re.sub(r"k_\d+_(\d+)_", r"k_X_\1_", s)


def first_diff(a: str, b: str):
    for i, (ca, cb) in enumerate(zip(a, b)):
        if ca != cb:
            return a[max(0, i - 60):i + 80], b[max(0, i - 60):i + 80]
    if len(a) != len(b):
        return f"...len={len(a)}", f"...len={len(b)}"
    return None


def main() -> None:
    base_dir, par_dir = WORK / "base", WORK / "parallel"
    names = sorted(p.name for p in base_dir.glob("*.json") if p.name != "timing.json")
    all_identical = True
    for name in names:
        a = json.loads((base_dir / name).read_text(encoding="utf-8"))
        b_path = par_dir / name
        if not b_path.exists():
            print(f"[{name}] ✗ 并行腿缺文件")
            all_identical = False
            continue
        b = json.loads(b_path.read_text(encoding="utf-8"))
        na, nb = normalize(a), normalize(b)
        if na == nb:
            print(f"[{name}] ✓ 逐字节一致（{len(a.get('blocks') or [])} 字）")
        else:
            all_identical = False
            print(f"[{name}] ✗ 不一致")
            d = first_diff(na, nb)
            if d:
                print(f"    base    ...{d[0]}...")
                print(f"    parallel...{d[1]}...")

    print()
    for tag in ("base", "parallel"):
        t_path = WORK / tag / "timing.json"
        if t_path.exists():
            rows = json.loads(t_path.read_text(encoding="utf-8"))
            total = sum(r.get("seconds", 0) for r in rows)
            errs = [r for r in rows if "error" in r]
            print(f"{tag:9s} 总计 {total:6.1f}s / {len(rows)} 页"
                  + (f"（{len(errs)} 页失败）" if errs else ""))
            for r in rows:
                if "error" in r:
                    print(f"    FAIL {Path(r['page']).name}: {r['error'][:80]}")
                else:
                    print(f"    {r['seconds']:6.1f}s  {Path(r['page']).name}"
                          f"  lines={r['lines']} chars={r['chars']}")
    print()
    print("结论：", "全部页面识别结果一致 ✓" if all_identical else "存在差异 ✗")
    sys.exit(0 if all_identical else 1)


if __name__ == "__main__":
    main()
