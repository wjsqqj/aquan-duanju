#!/usr/bin/env python3
"""Windows 完整构建：Go 核心 dll → flutter build windows → dll 拷入产物 → ZIP。

用法：python scripts/build_windows.py [--version 0.1.0] [--zip]
产物：build/aquan-windows-x64.zip（--zip 时）
"""

from __future__ import annotations

import argparse
import os
import hashlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RELEASE = REPO / "build" / "windows" / "x64" / "runner" / "Release"


def sh(cmd: list[str]) -> None:
    # Windows 上 flutter 是 .bat，CreateProcess 不做 PATHEXT 解析。
    if os.name == "nt" and cmd and cmd[0] == "flutter":
        cmd = ["flutter.bat"] + cmd[1:]
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="0.0.0-dev")
    ap.add_argument("--zip", action="store_true")
    args = ap.parse_args()

    dll = REPO / "build" / "aquan_core.dll"
    sh([sys.executable, str(REPO / "scripts" / "build_native.py"),
        "--windows", "--version", args.version])
    sh([sys.executable, str(REPO / "scripts" / "build_native.py"),
        "--cli", "--version", args.version])
    sh(["flutter", "build", "windows", "--release"])

    target = RELEASE / "aquan_core.dll"
    shutil.copy2(dll, target)
    print(f"copied {dll} -> {target}")

    # AI / 脚本入口：aquan-cli.exe 与主程序同目录，搜剧时不用启动窗口。
    cli = REPO / "build" / "aquan-cli.exe"
    if cli.exists():
        shutil.copy2(cli, RELEASE / "aquan-cli.exe")
        print(f"copied {cli} -> {RELEASE / 'aquan-cli.exe'}")

    # 红果 v5 sidecar（Python 协议栈 + 官方锁定素材 + 内嵌运行时）：exe 同目录分发。
    py_runtime = REPO / "build" / "py-runtime" / "python"
    if py_runtime.exists():
        runtime_dst = RELEASE / "runtime"
        shutil.rmtree(runtime_dst, ignore_errors=True)
        shutil.copytree(py_runtime, runtime_dst,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        print(f"copied {py_runtime} -> {runtime_dst}")
    sidecar_src = REPO / "native" / "bridge" / "hongguo-sidecar"
    sidecar_dst = RELEASE / "hongguo-sidecar"
    if sidecar_src.exists():
        shutil.rmtree(sidecar_dst, ignore_errors=True)
        shutil.copytree(sidecar_src, sidecar_dst,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        print(f"copied {sidecar_src} -> {sidecar_dst}")

    # v5 共享素材/表：Go 侧 go:embed 已内嵌，但 Python sidecar 兜底按相对路径
    # ../hongguov5/{assets,medusa_wire_tables.json} 读取，必须一并分发。
    assets_src = REPO / "native" / "bridge" / "hongguov5"
    assets_dst = RELEASE / "hongguov5"
    if (assets_src / "assets").exists():
        shutil.rmtree(assets_dst, ignore_errors=True)
        (assets_dst / "assets").mkdir(parents=True, exist_ok=True)
        shutil.copytree(assets_src / "assets", assets_dst / "assets",
                        dirs_exist_ok=True)
        shutil.copy2(assets_src / "medusa_wire_tables.json",
                     assets_dst / "medusa_wire_tables.json")
        print(f"copied {assets_src}/{{assets,medusa_wire_tables.json}} -> {assets_dst}")

    # 产物自检：可执行、核心库、命令行入口与 v5 素材必须同时在。
    for name in ("aquan_duanju.exe", "aquan_core.dll", "flutter_windows.dll",
                 "aquan-cli.exe", "hongguov5/assets/libmetasec_ml.so",
                 "hongguov5/assets/sdk-app-config.encoded",
                 "hongguov5/medusa_wire_tables.json"):
        if not (RELEASE / name).exists():
            sys.exit(f"产物缺失 {name}")

    if not args.zip:
        return

    zip_path = REPO / "build" / f"aquan-windows-x64-{args.version}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in RELEASE.rglob("*"):
            if f.is_file():
                zf.write(f, f.relative_to(RELEASE))
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    (REPO / "build" / (zip_path.stem + ".sha256")).write_text(
        f"{digest}  {zip_path.name}\n", encoding="utf-8")
    print(f"packed {zip_path}")


if __name__ == "__main__":
    main()
