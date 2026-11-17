# -*- coding: utf-8 -*-
"""SDK 素材获取（自有实现）：官方 APK 分段 Range 下载 + 哈希校验 + 原始字节切片。
素材是官方公开分发的 libmetasec_ml.so / 配置帧（互操作事实），哈希全锁定。"""
import base64
import hashlib
import json
import urllib.request
import zlib
from pathlib import Path

APK = "https://lf9-apk.ugapk.cn/package/apk/novelread/12267_74332/novelread_78105987a_v12267_74332_b929_1793271281.apk?v=1793271287"
APK_SIZE = 112946914
IMAGE_NAME = "libmetasec_ml.so"
CONFIG_NAME = "sdk-app-config.encoded"
# 随应用分发的锁定素材目录（已随 Go 原生移植移入 hongguov5 包单一事实源）
BUNDLED_ASSETS_DIR = Path(__file__).resolve().parent.parent / "hongguov5" / "assets"
FILES = {
    IMAGE_NAME: (4501136, "c6831ab265a0cb76dacfa3b7041e9ea0f706490106a74e12f39058671cc14fe3"),
    CONFIG_NAME: (304, "584a01183f1e6783326bff49d4f1319f33fcce678afb93ca0dc8b60a56b65855"),
}
# (apk 内起始偏移, 压缩段大小, 压缩段 sha256, 解压后大小)
PARTS = {
    IMAGE_NAME: (1497823, 1497823, "3839797f0a1e0ef6c604d639d0054a527b99ed1fa6aa9ecd2e80a9d87c8d133f", 4501136),
    CONFIG_NAME: (64901723, 3915212, "46526aa656dd910e06aeedbb2b23b5b846fd029ae49841587d38fcc4f9f277e6", 10417728),
}


class SdkAssetsError(ValueError):
    pass


def _redirect_ok(current: str, location: str, visited: set) -> str:
    from urllib.parse import urljoin, urlsplit
    if not isinstance(location, str) or not location or len(location) > 8192:
        raise SdkAssetsError("redirect-invalid")
    target = urljoin(current, location)
    parts = urlsplit(target)
    host = parts.hostname or ""
    if (parts.scheme != "https" or parts.username or parts.password or parts.fragment
            or parts.port not in (None, 443, 20443)
            or not any(host == s or host.endswith("." + s) for s in ("ugapk.cn", "jspcdn.cn"))
            or any(ord(c) < 33 or ord(c) == 127 for c in target) or target in visited):
        raise SdkAssetsError("redirect-invalid")
    return target


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _direct_opener():
    return urllib.request.build_opener(_NoRedirect, urllib.request.ProxyHandler({}))


def _inflate(packed: bytes, limit: int) -> bytes:
    decoder = zlib.decompressobj(-15)
    try:
        result = decoder.decompress(packed, limit + 1)
    except zlib.error:
        raise SdkAssetsError("compression-invalid")
    if len(result) != limit or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise SdkAssetsError("size-invalid")
    return result


def _download(name: str) -> bytes:
    start, size, digest, unpacked = PARTS[name]
    end = start + size - 1
    url = APK
    visited = {url}
    opener = _direct_opener()
    packed = None
    for hop in range(3):
        req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}", "Accept-Encoding": "identity"})
        try:
            response = opener.open(req, timeout=25)
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308):
                if hop == 2:
                    raise SdkAssetsError("redirect-limit")
                url = _redirect_ok(url, error.headers.get("Location"), visited)
                visited.add(url)
                continue
            raise SdkAssetsError("range-unavailable")
        if response.status != 206 or response.headers.get("Content-Range") != f"bytes {start}-{end}/{APK_SIZE}":
            raise SdkAssetsError("range-unavailable")
        if response.headers.get("Content-Encoding", "identity") != "identity":
            raise SdkAssetsError("encoding-invalid")
        packed = response.read(size + 1)
        if len(packed) > size:
            raise SdkAssetsError("transfer-limit")
        break
    if packed is None or len(packed) != size:
        raise SdkAssetsError("transfer-limit")
    if hashlib.sha256(packed).hexdigest() != digest:
        raise SdkAssetsError("integrity-failed")
    result = _inflate(packed, unpacked)
    if name == CONFIG_NAME:
        result = result[1936053:1936053 + 304]
    if len(result) != FILES[name][0] or hashlib.sha256(result).hexdigest() != FILES[name][1]:
        raise SdkAssetsError("integrity-failed")
    return result


def load_assets(directory: Path, allow_download=True) -> dict:
    root = Path(directory)
    root.mkdir(parents=True, exist_ok=True)
    results = {}
    for name, (size, digest) in FILES.items():
        # 1) 随应用分发的锁定素材（最高优先）
        bundled = BUNDLED_ASSETS_DIR / name
        if bundled.exists():
            data = bundled.read_bytes()
            if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                raise SdkAssetsError("bundled-integrity-failed")
            results[name] = data
            continue
        target = root / name
        if target.exists():
            data = target.read_bytes()
            if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                raise SdkAssetsError("cache-integrity-failed")
            results[name] = data
            continue
        if not allow_download:
            raise SdkAssetsError("materials-not-installed")
        data = _download(name)
        tmp = root / (name + ".tmp")
        tmp.write_bytes(data)
        tmp.replace(target)
        results[name] = data
    return results


# ---------------- 官方素材内常量的提取（偏移为互操作事实） ----------------

def read_sdk_image(image: bytes) -> dict:
    if len(image) != 4501136 or hashlib.sha256(image).hexdigest() != FILES[IMAGE_NAME][1]:
        raise ValueError("unsupported-sdk-image")
    inner = image[0x66690:0x66698] + bytes(a ^ b for a, b in
                                           zip(image[0x9D08C:0x9D094], image[0x9D118:0x9D120]))
    return {
        "frame": image[0x665F0:0x66600],
        "substitutions": image[0xFFCF9:0x1000F9],
        "exchange_inner_key": inner,
        "unavailable": image[0x66C44:0x66C4C].decode("ascii"),
    }


def decode_app_config(encoded: bytes, app_id: str = "8662") -> dict:
    from Crypto.Cipher import AES, ARC4
    if len(encoded) != 304:
        raise ValueError("invalid-config-size")
    raw = base64.b64decode(encoded, validate=True)
    if len(raw) != 228:
        raise ValueError("invalid-config-frame")
    application = app_id.encode("ascii")
    nonce = raw[:4]
    wrapping_key = hashlib.md5(application + nonce + application).digest()
    plaintext = AES.new(wrapping_key, AES.MODE_ECB).decrypt(raw[4:])
    padding = plaintext[-1]
    if not 1 <= padding <= 16 or plaintext[-padding:] != bytes([padding]) * padding:
        raise ValueError("invalid-config-padding")
    plaintext = plaintext[:-padding]
    if len(plaintext) < 9:
        raise ValueError("invalid-config-payload")
    head, tail = plaintext[:4], plaintext[-4:]
    mask = 0
    for byte in nonce + head + tail:
        mask ^= byte
    stream_key = hashlib.sha1(head + application + nonce).digest()
    payload = ARC4.new(stream_key).decrypt(plaintext[4:-4])
    message = bytes(byte ^ mask for byte in reversed(payload))
    found = {}
    for number, kind, value in pb_decode(message):
        if number != 8 or kind != 2:
            continue
        entry = {}
        for sub_number, sub_kind, sub_value in pb_decode(value):
            if sub_number not in (1, 2) or sub_kind != 2 or sub_number in entry:
                raise ValueError("invalid-key-entry")
            entry[sub_number] = sub_value
        if set(entry) != {1, 2}:
            raise ValueError("incomplete-key-entry")
        name = entry[1]
        if name not in (b"sign_key", b"common_key") or name in found:
            raise ValueError("unexpected-key-entry")
        key = base64.b64decode(entry[2], validate=True)
        if len(key) != 32:
            raise ValueError("invalid-key-size")
        found[name] = key
    if set(found) != {b"sign_key", b"common_key"}:
        raise ValueError("missing-key-entry")
    return {"signing_key": found[b"sign_key"], "exchange_key": found[b"common_key"]}


def pb_decode(data: bytes):
    rows, cursor = [], 0
    while cursor < len(data):
        tag, cursor = _pb_int(data, cursor)
        number, kind = tag >> 3, tag & 7
        if kind == 0:
            value, cursor = _pb_int(data, cursor)
        elif kind in (1, 2, 5):
            size = 8 if kind == 1 else (4 if kind == 5 else 0)
            if kind == 2:
                size, cursor = _pb_int(data, cursor)
            if size > len(data) - cursor:
                raise ValueError("truncated-field")
            value = data[cursor:cursor + size]
            cursor += size
        else:
            raise ValueError("wire-type-unsupported")
        rows.append((number, kind, value))
    return rows


def _pb_int(data, cursor):
    result = 0
    for part in range(10):
        if cursor >= len(data):
            raise ValueError("number-truncated")
        byte = data[cursor]
        cursor += 1
        result |= (byte & 127) << (7 * part)
        if byte < 128:
            return result, cursor
    raise ValueError("number-overflow")
