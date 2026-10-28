#!/usr/bin/env python3
"""Linux 完整构建：Go 核心 .so → flutter build linux → tar.gz + deb。

用法：python scripts/build_linux.py [--version 0.4.4]
产物：
  build/aquan-linux-x64-<版本>.tar.gz      便携版（解压运行，需系统 libmpv）
  build/aquan-duanju_<版本>_amd64.deb      安装包（双击/dpkg 安装，含桌面入口）
以及同名 .sha256。
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
DESKTOP_FILE = """[Desktop Entry]
Type=Application
Version=1.0
Name=阿圈短剧
Comment=刷短剧（学习与研究用途）
Exec=/usr/bin/aquan-duanju
Icon=aquan-duanju
Terminal=false
Categories=AudioVideo;Video;
StartupWMClass=aquan_duanju
"""

CONTROL = """Package: aquan-duanju
Version: {version}
Section: video
Priority: optional
Architecture: amd64
Maintainer: wjsqqj <wjsqqj@163.com>
Depends: libgtk-3-0, libmpv2 | libmpv1, libasound2, libpulse0
Description: 阿圈短剧 - 红果短剧播放器
 基于 openhongguo（Apache-2.0）逆向的公开接口，仅供学习与研究，
 禁止用于商业用途；内容版权归原平台及权利方所有。
"""


def sh(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def sha256_of(path: Path) -> None:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    (REPO / "build" / (path.name + ".sha256")).write_text(
        f"{digest}  {path.name}\n", encoding="utf-8")
    print(f"packed {path}")


def pack_tar(version: str) -> None:
    archive = REPO / "build" / f"aquan-linux-x64-{version}.tar.gz"
    root = f"aquan-linux-x64-{version}"
    with tarfile.open(archive, "w:gz") as tf:
        for f in BUNDLE.rglob("*"):
            tf.add(f, arcname=f"{root}/{f.relative_to(BUNDLE)}")
    sha256_of(archive)


def pack_deb(version: str) -> None:
    staging = REPO / "build" / "deb" / f"aquan-duanju_{version}_amd64"
    if staging.exists():
        shutil.rmtree(staging)

    opt = staging / "opt" / "aquan-duanju"
    shutil.copytree(BUNDLE, opt)
    (staging / "usr" / "bin").mkdir(parents=True)
    wrapper = staging / "usr" / "bin" / "aquan-duanju"
    wrapper.write_text("#!/bin/sh\nexec /opt/aquan-duanju/aquan_duanju \"$@\"\n",
                       encoding="utf-8")
    wrapper.chmod(0o755)

    apps = staging / "usr" / "share" / "applications"
    apps.mkdir(parents=True)
    (apps / "aquan-duanju.desktop").write_text(DESKTOP_FILE, encoding="utf-8")

    icons = staging / "usr" / "share" / "icons" / "hicolor" / "1024x1024" / "apps"
    icons.mkdir(parents=True)
    shutil.copy2(REPO / "assets" / "icon" / "icon.png",
                 icons / "aquan-duanju.png")

    deb_dir = staging / "DEBIAN"
    deb_dir.mkdir()
    (deb_dir / "control").write_text(CONTROL.format(version=version),
                                     encoding="utf-8")

    out = REPO / "build" / f"aquan-duanju_{version}_amd64.deb"
    if out.exists():
        out.unlink()
    sh(["dpkg-deb", "--build", "--root-owner-group", str(staging), str(out)])
    sha256_of(out)


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

    pack_tar(args.version)
    pack_deb(args.version)


if __name__ == "__main__":
    main()
