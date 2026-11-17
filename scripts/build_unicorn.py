#!/usr/bin/env python3
"""构建 unicorn 静态库（ARM64 模拟核心，v5 摘要用）。

- pinned 源码下载（sha256 校验）+ 本地缓存
- windows-amd64：mingw gcc（本机 C:/mingw64）
- android {arm64-v8a,armeabi-v7a,x86_64}：NDK toolchain
- linux-amd64 / macos：CI release.yml 现产现用（同一脚本）

产物：native/bridge/third/unicorn/prebuilt/<target>/{libunicorn.a, include/}

用法：
  python scripts/build_unicorn.py --windows
  python scripts/build_unicorn.py --android --ndk "D:/Android/Sdk/ndk/28.2.13676358"
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILD = REPO / "build" / "unicorn-src"
SRC = BUILD / "unicorn-2.1.4"
OUT = REPO / "native" / "bridge" / "third" / "unicorn" / "prebuilt"

TARBALL_SHA256 = "ea8863f095a0136388694e5a6063afd9bb7650e30243dd6251af59c5ce5601f4"
URL = "https://github.com/unicorn-engine/unicorn/archive/refs/tags/2.1.4.tar.gz"
MINGW = Path("C:/mingw64/bin")
ABI_TARGET = {
    "arm64-v8a": "android-arm64-v8a",
    "armeabi-v7a": "android-armeabi-v7a",
    "x86_64": "android-x86_64",
}


def fetch_source() -> Path:
    if (SRC / "CMakeLists.txt").exists():
        return SRC
    BUILD.mkdir(parents=True, exist_ok=True)
    tarball = BUILD / "unicorn-2.1.4.tar.gz"
    if not tarball.exists() or hashlib.sha256(tarball.read_bytes()).hexdigest() != TARBALL_SHA256:
        print("下载 unicorn 2.1.4 ...")
        for attempt in range(4):
            # 本地可设 DUANJU_DL_PROXY；CI 无代理（不能默认写死 127.0.0.1）。
            proxy = os.environ.get("DUANJU_DL_PROXY", "")
            cmd = ["curl", "-fsSL", "--retry", "3", "-o", str(tarball), URL]
            if proxy:
                cmd[2:2] = ["-x", proxy]
            subprocess.run(cmd, check=False)
            if tarball.exists() and hashlib.sha256(tarball.read_bytes()).hexdigest() == TARBALL_SHA256:
                break
            print(f"下载校验不符（第 {attempt + 1} 次）")
            tarball.unlink(missing_ok=True)
        else:
            sys.exit("unicorn tarball 下载失败（可设 DUANJU_DL_PROXY 换代理）")
    with tarfile.open(tarball) as tf:
        tf.extractall(BUILD)
    if hashlib.sha256(tarball.read_bytes()).hexdigest() != TARBALL_SHA256:
        sys.exit("tarball 哈希不符")
    return SRC


PATCHES = [
    (
        "qemu/accel/tcg/translate-all.c",
        "AddVectoredExceptionHandler(0, (PVECTORED_EXCEPTION_HANDLER)closure)",
        "AddVectoredExceptionHandler(1, (PVECTORED_EXCEPTION_HANDLER)closure)",
        "VEH 注册为 first：last 会被宿主运行时（Go runtime）的 VEH 先行截获",
    ),
    (
        "qemu/accel/tcg/translate-all.c",
        "VirtualAlloc(NULL, size, MEM_RESERVE, PAGE_EXECUTE_READWRITE)",
        "VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE)",
        "code_gen_buffer 直接 COMMIT：按需提交依赖 VEH，在 Go 进程中不可靠",
    ),
    (
        "qemu/include/qemu/int128.h",
        "#if !(defined(_MSC_VER) && defined(__clang__))\ntypedef Int128 __int128_t;",
        "#if !(defined(_MSC_VER) && defined(__clang__)) && !defined(__SIZEOF_INT128__)\ntypedef Int128 __int128_t;",
        "32 位目标（armv7）走 struct Int128 时避免与 clang 内置 __int128_t 冲突",
    ),
]


def patch_source(src: Path) -> None:
    """固化 Windows 宿主兼容补丁（幂等）。安卓走 mmap 分支不受影响。"""
    for rel, old, new, why in PATCHES:
        path = src / rel
        text = path.read_text(encoding="utf-8")
        if new in text:
            continue
        if old not in text:
            sys.exit(f"unicorn 补丁锚点缺失（{rel}）：{old}")
        path.write_text(text.replace(old, new), encoding="utf-8")
        print(f"patched {rel}: {why}")


def run(cmd, env=None, cwd=None):
    print("+", " ".join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True, env=env, cwd=str(cwd) if cwd else None)


def sh_exe() -> str:
    """Windows 上 subprocess 不能用 shell 语义，必须给 sh 绝对路径（PATH 含空格时
    CreateProcess 找不到裸 "sh"）。"""
    for candidate in (r"C:/Program Files/Git/usr/bin/sh.exe",
                      r"C:/Program Files/Git/bin/sh.exe"):
        if Path(candidate).exists():
            return candidate
    return "sh"


def ensure_qemu_config(bld: Path, cc: str = "gcc",
                       extra_cflags: str = "-DUNICORN_HAS_ARM64 -fPIC") -> None:
    """cmake 的 execute_process(sh configure) 在部分宿主上静默失败——
    手动补 config-host.h / aarch64-softmmu/config-target.h。
    需要 sh/strings/pkg-config 可探：Windows 上补 mingw64 + Git usr/bin + 垫片。"""
    host_h = bld / "config-host.h"
    target_h = bld / "aarch64-softmmu" / "config-target.h"
    # 不提前返回：旧 cache 可能带着错误的 CONFIG_INT128 / CRLF，下面幂等修复。
    toolbin = BUILD / "toolbin"
    toolbin.mkdir(parents=True, exist_ok=True)
    pkg_stub = toolbin / "pkg-config"
    pkg_stub.write_text('#!/bin/sh\nexec "' + str(MINGW / "pkgconf.exe").replace("\\", "/") + '" "$@"\n')
    pkg_stub.chmod(0o755)
    env = os.environ.copy()
    extra_path = [str(MINGW), r"C:/Program Files/Git/usr/bin", str(toolbin)]
    env["PATH"] = ";".join(extra_path) + os.pathsep + env["PATH"]
    env["PKG_CONFIG"] = str(pkg_stub)
    if not (bld / "config-host.mak").exists():
        run([sh_exe(), SRC / "qemu" / "configure",
             f"--cc={cc}",
             f"--extra-cflags={extra_cflags}",
             "--target-list=aarch64-softmmu,"], env=env, cwd=bld)
    # NDK clang 交叉编译时 configure 的 int128 探测会失败，导致 int128.h 走
    # struct 分支并与 clang 内置 __int128_t 冲突（typedef redefinition）。
    # clang 全系支持 __int128，直接补 CONFIG_INT128（幂等）。
    mak = bld / "config-host.mak"
    target_mak = bld / "aarch64-softmmu" / "config-target.mak"
    # Windows 上 configure 产出的 .mak 是 CRLF，create_config 的 sh 解析会把
    # 值末尾的 \r 带进取值（路径被折行 + CONFIG_POSIX 输出裸 y）。统一转 LF。
    for path in (mak, target_mak):
        raw = path.read_bytes()
        if b"\r\n" in raw:
            path.write_bytes(raw.replace(b"\r\n", b"\n"))
    text = mak.read_text(encoding="utf-8", errors="ignore")
    # 仅 64 位目标启用原生 __int128（armv7 没有，会编译失败）。
    is64 = ("arm64" in bld.name) or ("x86_64" in bld.name) or bld.name.startswith("build-windows")
    if is64 and "CONFIG_INT128" not in text:
        mak.write_text(text.rstrip() + "\nCONFIG_INT128=y\n", encoding="utf-8", newline="\n")
    elif not is64 and "CONFIG_INT128" in text:
        kept = [ln for ln in text.splitlines() if not ln.startswith("CONFIG_INT128")]
        mak.write_text("\n".join(kept) + "\n", encoding="utf-8", newline="\n")
    subprocess.run([sh_exe(), str(SRC / "qemu" / "scripts" / "create_config")],
                   stdin=open(bld / "config-host.mak", "rb"),
                   stdout=open(host_h, "wb"), check=True, cwd=str(bld), env=env)
    subprocess.run([sh_exe(), str(SRC / "qemu" / "scripts" / "create_config")],
                   stdin=open(bld / "aarch64-softmmu" / "config-target.mak", "rb"),
                   stdout=open(target_h, "wb"), check=True, cwd=str(bld), env=env)


def collect(target: str, build_dir: Path) -> Path:
    lib = build_dir / "libunicorn.a"
    if not lib.exists():
        sys.exit(f"产物缺失: {lib}")
    dest = OUT / target
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(lib, dest / "libunicorn.a")
    # 抽掉调试段（NDK 产物 28MB -> 5MB）。
    strip = shutil.which("llvm-strip") or (
        Path(os.environ.get("ANDROID_NDK", "")) / "toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe")
    if strip and Path(strip).exists():
        subprocess.run([str(strip), "--strip-debug", str(dest / "libunicorn.a")], check=False)
    inc_dest = dest / "include" / "unicorn"
    inc_dest.parent.mkdir(parents=True, exist_ok=True)
    if inc_dest.exists():
        shutil.rmtree(inc_dest)
    shutil.copytree(SRC / "include" / "unicorn", inc_dest)
    print(f"prebuilt -> {dest / 'libunicorn.a'} ({(dest / 'libunicorn.a').stat().st_size // 1024} KB)")
    return dest


def build_windows() -> None:
    src = fetch_source()
    patch_source(src)
    bld = BUILD / "build-windows-amd64"
    bld.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = f"{MINGW};{env['PATH']}"
    if not (bld / "build.ninja").exists():
        run([str(MINGW / "cmake.exe"), "-G", "Ninja",
             "-DCMAKE_MAKE_PROGRAM=" + str(MINGW / "ninja.exe"),
             "-DCMAKE_C_COMPILER=" + str(MINGW / "gcc.exe"),
             "-DCMAKE_BUILD_TYPE=Release",
             "-DUNICORN_ARCH=aarch64", str(src)], env=env, cwd=bld)
    ensure_qemu_config(bld)
    run([str(MINGW / "ninja.exe")], env=env, cwd=bld)
    collect("windows-amd64", bld)


ANDROID_TRIPLES = {
    "arm64-v8a": "aarch64-linux-android",
    "armeabi-v7a": "armv7a-linux-androideabi",
    "x86_64": "x86_64-linux-android",
}


def build_android(ndk: str) -> None:
    src = fetch_source()
    patch_source(src)
    # collect() 用 llvm-strip 抽调试段（28MB → 5MB），依赖这个环境变量定位。
    os.environ.setdefault("ANDROID_NDK", str(Path(ndk)))
    sdk_cmake = Path("D:/Android/Sdk/cmake/3.22.1/bin/cmake.exe")
    if not sdk_cmake.exists():
        sdk_cmake = shutil.which("cmake")
    toolchain = Path(ndk) / "build" / "cmake" / "android.toolchain.cmake"
    clang = list(Path(ndk).glob("toolchains/llvm/prebuilt/*/bin/clang.exe"))
    if not clang:
        sys.exit(f"NDK clang 不存在: {ndk}")
    clang = clang[0]
    for abi, target in ABI_TARGET.items():
        bld = BUILD / f"build-{target}"
        bld.mkdir(parents=True, exist_ok=True)
        run([sdk_cmake, "-G", "Ninja",
             "-DCMAKE_MAKE_PROGRAM=" + str(Path(sdk_cmake).parent / "ninja.exe"),
             f"-DCMAKE_TOOLCHAIN_FILE={toolchain}",
             f"-DANDROID_ABI={abi}",
             "-DANDROID_PLATFORM=android-24",
             "-DCMAKE_BUILD_TYPE=Release",
             "-DUNICORN_ARCH=aarch64", str(src)], cwd=bld)
        triple = ANDROID_TRIPLES[abi]
        # 显式 --sysroot 会破坏 clang 的 crtbegin 查找（NDK r28 实测）——依赖自动探测。
        ensure_qemu_config(bld, cc=str(clang),
                           extra_cflags=f"-DUNICORN_HAS_ARM64 -fPIC --target={triple}24")
        run([str(Path(sdk_cmake).parent / "ninja.exe")], cwd=bld)
        collect(target, bld)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--windows", action="store_true")
    ap.add_argument("--android", action="store_true")
    ap.add_argument("--linux", action="store_true")
    ap.add_argument("--macos", action="store_true")
    ap.add_argument("--ndk", default=os.environ.get("ANDROID_NDK", ""))
    args = ap.parse_args()
    if not (args.windows or args.android or args.linux or args.macos):
        ap.error("至少选择一个目标")
    if args.windows:
        build_windows()
    if args.android:
        if not args.ndk:
            sys.exit("--android 需要 --ndk")
        build_android(args.ndk)
    if args.linux:
        build_native_linux()
    if args.macos:
        build_native_macos()


def build_native_linux() -> None:
    src = fetch_source()
    bld = BUILD / "build-linux-amd64"
    bld.mkdir(parents=True, exist_ok=True)
    run(["cmake", "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
         "-DUNICORN_ARCH=aarch64", str(src)], cwd=bld)
    run(["ninja"], cwd=bld)
    collect("linux-amd64", bld)


def build_native_macos() -> None:
    src = fetch_source()
    # 括号必须留着：Path / "x" + str 会先算 Path 再拼 str（TypeError）。
    bld = BUILD / ("build-macos-" + os.uname().machine)
    bld.mkdir(parents=True, exist_ok=True)
    run(["cmake", "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
         "-DUNICORN_ARCH=aarch64", str(src)], cwd=bld)
    run(["ninja"], cwd=bld)
    collect(f"macos-{os.uname().machine}", bld)


if __name__ == "__main__":
    main()
