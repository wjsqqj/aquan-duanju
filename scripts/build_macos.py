#!/usr/bin/env python3
"""macOS 完整构建：Go 核心 dylib → flutter build macos → .app 的 zip + dmg。

用法：python scripts/build_macos.py [--version 0.4.4]
产物：build/aquan-macos-<arch>-<版本>.zip 与 .dmg，及同名 .sha256
"""

from __future__ import annotations

import argparse
import hashlib
import platform
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "build" / "macos" / "Build" / "Products" / "Release" / "aquan_duanju.app"


def sh(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="0.0.0-dev")
    args = ap.parse_args()

    sh([sys.executable, str(REPO / "scripts" / "build_native.py"),
        "--macos", "--version", args.version])
    sh([sys.executable, str(REPO / "scripts" / "build_native.py"),
        "--cli", "--version", args.version])
    sh(["flutter", "build", "macos", "--release"])

    macos_dir = APP / "Contents" / "MacOS"
    shutil.copy2(REPO / "build" / "libaquan_core.dylib",
                 macos_dir / "libaquan_core.dylib")
    cli = REPO / "build" / "aquan-cli"
    if cli.exists():
        shutil.copy2(cli, macos_dir / "aquan-cli")
        (macos_dir / "aquan-cli").chmod(0o755)

    # 复制原生库后重新做 ad-hoc 签名，否则 Gatekeeper 直接拒绝启动。
    sh(["codesign", "--force", "--deep", "--sign", "-", str(APP)])

    arch = "arm64" if platform.machine() == "arm64" else "x64"
    archive = REPO / "build" / f"aquan-macos-{arch}-{args.version}.zip"
    sh(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
        str(APP), str(archive)])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (REPO / "build" / (archive.name + ".sha256")).write_text(
        f"{digest}  {archive.name}\n", encoding="utf-8")
    print(f"packed {archive}")

    # dmg：拖进 Applications 的安装镜像（zip 保留作为解压即用版）。
    staging = REPO / "build" / "dmg-staging"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    shutil.copytree(APP, staging / APP.name)
    (staging / "Applications").symlink_to("/Applications")
    dmg = REPO / "build" / f"aquan-macos-{arch}-{args.version}.dmg"
    if dmg.exists():
        dmg.unlink()
    sh(["hdiutil", "create", "-volname", "阿圈短剧", "-srcfolder",
        str(staging), "-ov", "-format", "UDZO", str(dmg)])
    shutil.rmtree(staging)
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (REPO / "build" / (dmg.name + ".sha256")).write_text(
        f"{digest}  {dmg.name}\n", encoding="utf-8")
    print(f"packed {dmg}")


if __name__ == "__main__":
    main()
