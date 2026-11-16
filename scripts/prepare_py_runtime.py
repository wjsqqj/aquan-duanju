# -*- coding: utf-8 -*-
"""准备内嵌 Python 运行时（红果 v5 sidecar 用）。

产出 build/py-runtime/python/：
  python-3.12.8 embeddable + pip 安装 unicorn/pycryptodome 到 Lib/site-packages
  + python312._pth 指向 Lib/site-packages。
幂等：已就绪（python.exe + 两个包）则跳过。需要代理时设 HTTPS_PROXY。
"""
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ROOT = REPO / "build" / "py-runtime"
PYTHON = ROOT / "python"
EMBED_URL = "https://www.python.org/ftp/python/3.12.8/python-3.12.8-embed-amd64.zip"
PTH_NAME = "python312._pth"
PTH_CONTENT = "python312.zip\r\n.\r\nLib/site-packages\r\n"


def main() -> int:
    marker = PYTHON / ".prepared"
    if marker.exists() and (PYTHON / "python.exe").exists():
        print("py-runtime ready (cached)")
        return 0
    PYTHON.mkdir(parents=True, exist_ok=True)
    archive = ROOT / "python-embed.zip"
    if not archive.exists():
        print("downloading", EMBED_URL)
        urllib.request.urlretrieve(EMBED_URL, archive)
    with zipfile.ZipFile(archive) as zf:
        zf.extractall(PYTHON)
    (PYTHON / PTH_NAME).write_text(PTH_CONTENT, encoding="ascii")
    # 代理透传给 pip（默认环境变量即可；urllib 不涉及）
    result = subprocess.run(
        [sys.executable, "-m", "pip", "install", "--target",
         str(PYTHON / "Lib" / "site-packages"), "--upgrade", "unicorn", "pycryptodome"],
        check=False)
    if result.returncode != 0:
        sys.exit("pip install failed")
    marker.write_text("ok\n", encoding="ascii")
    print("py-runtime prepared at", PYTHON)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
