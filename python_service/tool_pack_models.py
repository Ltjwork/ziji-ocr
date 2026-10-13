# -*- coding: utf-8 -*-
"""发版打包 CLI（管理员机使用，installer 已排除不分发）：

  python tool_pack_models.py --init-key        首次：生成签名密钥对
  python tool_pack_models.py [--version 20261009]   打包当前激活的模型

与界面「打包发版」按钮（POST /models/pack）同一实现（api_pack.pack_release）。
"""
from __future__ import annotations

import argparse
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))


def main() -> None:
    ap = argparse.ArgumentParser(description="字迹模型发版打包工具")
    ap.add_argument("--init-key", action="store_true",
                    help="生成 release_keys/zjpack_ed25519 并打印公钥")
    ap.add_argument("--version", default="", help="包版本号（缺省当天日期）")
    args = ap.parse_args()

    if args.init_key:
        import ed25519

        key_path = Path(__file__).resolve().parent / "release_keys" / "zjpack_ed25519"
        key_path.parent.mkdir(exist_ok=True)
        if key_path.exists():
            sys.exit(f"私钥已存在：{key_path}（轮换需同时更新 model_store.PUBLIC_KEY）")
        seed = secrets.token_bytes(32)
        key_path.write_bytes(seed)
        pub = ed25519.publickey(seed).hex()
        print(f"私钥已写入 {key_path}（只留本机，勿分发、勿打包）")
        print(f"公钥 hex（粘贴进 model_store.PUBLIC_KEY）：\n{pub}")
        return

    import api_pack

    try:
        r = api_pack.pack_release(args.version)
    except RuntimeError as exc:
        sys.exit(str(exc))
    print(f"打包完成：{r['path']}")
    print(f"版本 {r['pack_version']}  {r['size_bytes'] / 1e6:.1f}MB  "
          f"sha256={r['sha256'][:16]}…")
    for e in r["entries"]:
        src = ""
        prov = r.get("layers", {}).get(e["kind"]) or {}
        if prov:
            src = prov.get("run") or prov.get("file") or prov.get("source") or ""
        print(f"  {e['kind']:<26} {e['name']:<28} "
              f"{e['length'] / 1e6:8.1f}MB  {src}")


if __name__ == "__main__":
    main()
