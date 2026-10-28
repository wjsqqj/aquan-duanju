#!/usr/bin/env python3
"""Linux 完整构建：Go 核心 .so → flutter build linux → 已带原生库的 tar.gz。

用法：python scripts/build_linux.py [--version 0.4.0] [--zip]
产物：build/aquan-linux-x64-<版本>.tar.gz 与同名 .sha256
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUNDLE = REPO / "build" / "linux" / "x64" / "release" / "bundle"


def sh(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="0.0.0-dev")
    args = ap.parse_args()

    sh([sys.executable, str(REPO / "scripts" / "build_native.py"),
        "--linux", "--version", args.version])
    sh([sys.executable, str(REPO / "scripts" / "build_native.py"),
        "--cli", "--version", args.version])
    sh(["flutter", "build", "linux", "--release"])

    lib_dir = BUNDLE / "lib"
    lib_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(REPO / "build" / "libaquan_core.so", lib_dir / "libaquan_core.so")
    cli = REPO / "build" / "aquan-cli"
    if cli.exists():
        shutil.copy2(cli, BUNDLE / "aquan-cli")
        (BUNDLE / "aquan-cli").chmod(0o755)

    for name in ("aquan_duanju", str(Path("lib") / "libaquan_core.so"),
                 str(Path("data") / "flutter_assets")):
        path = BUNDLE / name
        if not path.exists():
            sys.exit(f"产物缺失 {name}")

    archive = REPO / "build" / f"aquan-linux-x64-{args.version}.tar.gz"
    root = f"aquan-linux-x64-{args.version}"
    with tarfile.open(archive, "w:gz") as tf:
        for f in BUNDLE.rglob("*"):
            tf.add(f, arcname=f"{root}/{f.relative_to(BUNDLE)}")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (REPO / "build" / (archive.stem + ".sha256")).write_text(
        f"{digest}  {archive.name}\n", encoding="utf-8")
    print(f"packed {archive}")


if __name__ == "__main__":
    main()
