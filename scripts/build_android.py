#!/usr/bin/env python3
"""Android 完整构建：Go 核心 so（三 ABI）→ flutter build apk --split-per-abi。

用法：python scripts/build_android.py --ndk <NDK 路径> [--version 0.1.0]
产物：build/app/outputs/flutter-apk/*.apk
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def sh(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ndk", required=True)
    ap.add_argument("--version", default="0.0.0-dev")
    args = ap.parse_args()

    sh([sys.executable, str(REPO / "scripts" / "build_native.py"),
        "--android", "--ndk", args.ndk, "--version", args.version])
    sh(["flutter", "build", "apk", "--release", "--split-per-abi"])


if __name__ == "__main__":
    main()
