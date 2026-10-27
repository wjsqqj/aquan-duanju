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
    sh(["flutter", "build", "windows", "--release"])

    target = RELEASE / "aquan_core.dll"
    shutil.copy2(dll, target)
    print(f"copied {dll} -> {target}")

    # 产物自检：可执行与核心库必须同时在。
    for name in ("aquan_duanju.exe", "aquan_core.dll", "flutter_windows.dll"):
        if not (RELEASE / name).exists():
            sys.exit(f"产物缺失 {name}")

    if not args.zip:
        return

    zip_path = REPO / "build" / f"aquan-windows-x64-{args.version}.zip"
    with zipfile.ZIP_DEFLATED, zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in RELEASE.rglob("*"):
            if f.is_file():
                zf.write(f, f.relative_to(RELEASE))
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    (REPO / "build" / (zip_path.stem + ".sha256")).write_text(
        f"{digest}  {zip_path.name}\n", encoding="utf-8")
    print(f"packed {zip_path}")


if __name__ == "__main__":
    main()
