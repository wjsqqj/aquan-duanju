# -*- coding: utf-8 -*-
"""匿名设备注册（自有实现）：snssdk + TTEncrypt（ssovit MIT）+ 小米14/73932 姿势。
上下文持久化为明文 JSON（与 aquan_device.json 同级敏感度：设备标识，无凭据）。"""
import json
import re
import secrets
import struct
import sys
import time
import uuid
import urllib.request
from pathlib import Path

from pyvendor.TTEncrypt import TT

REGISTER_URL = "https://log.snssdk.com/service/2/device_register/"
VERSION_CODE = 73932
VERSION_NAME = "7.3.9.32"
USER_AGENT = (
    "com.phoenix.read/73932 (Linux; U; Android 14; zh_CN; Xiaomi 14; "
    "Build/UKQ1.230804.001; Cronet/TTNetVersion:8d40f833 "
    "QuicVersion:462f352c 2026-08-31)"
)
COOKIE_NAMES = {"odin_tt", "ttreq", "store-region", "store-region-src"}
MAX_RESPONSE = 2 * 1024 * 1024


def _valid_id(value) -> bool:
    s = str(value)
    return s.isascii() and s.isdigit() and 5 <= len(s) <= 30 and int(s) > 0


def _direct_opener():
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def prepare_registration(now_ms=None):
    ms = int(time.time() * 1000) if now_ms is None else now_ms
    cdid, openudid = str(uuid.uuid4()), secrets.token_hex(8)
    params = {
        "aid": "8662", "app_name": "novelread", "channel": "xiaomi_8662_64",
        "version_code": str(VERSION_CODE), "version_name": VERSION_NAME,
        "manifest_version_code": str(VERSION_CODE), "update_version_code": str(VERSION_CODE),
        "device_platform": "android", "os": "android", "ssmix": "a",
        "device_type": "23127PN0CC", "device_brand": "xiaomi", "os_api": "34", "os_version": "14",
        "resolution": "1200*2670", "dpi": "460", "ac": "wifi", "language": "zh",
        "openudid": openudid, "cdid": cdid, "tt_data": "a", "_rticket": str(ms), "ts": str(ms // 1000),
        "package": "com.phoenix.read", "first_launch_timestamp": str(ms // 1000),
        "last_deeplink_update_version_code": "0", "cpu_support64": "true", "host_abi": "arm64-v8a",
        "is_guest_mode": "0", "app_type": "normal", "minor_status": "0", "appTheme": "light",
        "is_preinstall": "0", "need_personal_recommend": "1", "is_android_pad": "0",
        "is_android_fold": "0", "md": "0", "cronet_version": "8d40f833_2026-03-03",
        "ttnet_version": "4.2.243.31-douyin", "use_store_region_cookie": "1",
    }
    header = {
        "access": "wifi", "aid": 8662, "app_version": VERSION_NAME, "app_version_minor": "",
        "apk_first_install_time": ms, "cdid": cdid, "channel": params["channel"],
        "clientudid": str(uuid.uuid4()), "cpu_abi": "arm64-v8a", "density_dpi": 460,
        "device_brand": "xiaomi", "device_category": "phone", "device_manufacturer": "Xiaomi",
        "device_model": "Xiaomi 14", "device_platform": "android", "display_density": "xxhdpi",
        "display_name": "红果短剧", "git_hash": "fe95b95", "guest_mode": 0, "ipv6_list": [],
        "is_system_app": 0, "language": "zh", "manifest_version_code": VERSION_CODE,
        "not_request_sender": 0, "oaid_may_support": True, "openudid": openudid, "os": "Android",
        "os_api": 34, "os_version": "14", "package": "com.phoenix.read", "region": "CN",
        "release_build": "UKQ1.230804.001_1701234567", "req_id": str(uuid.uuid4()),
        "resolution": "2670x1200", "rom": "hyperos", "rom_version": "OS1.0.32.0.UNCCNXM",
        "sdk_flavor": "china", "sdk_target_version": 29, "sdk_version": "3.7.3-rc.116-douyin",
        "sig_hash": "aea615ab910015038f73c47e45d21466", "sim_serial_number": [],
        "timezone": 8, "tz_name": "Asia/Shanghai", "tz_offset": 28800,
        "update_version_code": VERSION_CODE, "version_code": VERSION_CODE,
        "custom": {
            "is_android_fold": 0, "filter_warn": 0, "is_android_pad": 0, "client_ipv4": "0.0.0.0",
            "web_ua": "Mozilla/5.0 (Linux; Android 14; Xiaomi 14 Build/UKQ1.230804.001; wv) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36",
        },
    }
    payload = json.dumps({"magic_tag": "ss_app_log", "header": header, "_gen_time": ms},
                         ensure_ascii=False, separators=(",", ":"))
    body = TT().encrypt(payload)
    headers = {
        "Content-Type": "application/octet-stream;tt-data=a", "Content-Encoding": "gzip",
        "Accept-Encoding": "gzip", "User-Agent": USER_AGENT,
        "Accept": "application/json; charset=utf-8,application/x-protobuf",
        "X-SS-STUB": __import__("hashlib").md5(body).hexdigest().upper(), "X-SS-DP": "8662",
        "X-SS-REQ-TICKET": str(ms), "X-Khronos": str(ms // 1000),
        "X-Argus": __import__("base64").b64encode(struct.pack("<I", ms // 1000)).decode(),
        "X-TT-Request-Tag": "t=0;n=1", "Log-Encode-Type": "gzip", "Passport-SDK-Version": "60755",
        "Passport-SDK-Settings": "device_transfer_s_0,device_transfer_ab_1", "Sdk-Version": "2",
        "lc": "102", "X-TT-Store-Region": "cn", "X-TT-Store-Region-Src": "did",
        "X-VC-Bdturing-SDK-Version": "4.0.3.cn",
    }
    query = "&".join(f"{k}={v}" for k, v in sorted(params.items()))
    return REGISTER_URL + "?" + query, body, headers, params


def parse_identity(payload: bytes) -> dict:
    if len(payload) > MAX_RESPONSE:
        raise ValueError("response-too-large")
    raw = payload
    if payload.startswith(b"tc\x05\x10"):
        raw = TT().decrypt(payload)
    value = json.loads(raw)
    device = value.get("device_id_str") or value.get("device_id")
    install = value.get("install_id_str") or value.get("install_id")
    if not _valid_id(device) or not _valid_id(install):
        raise ValueError("device-not-issued")
    token = value.get("device_token", "")
    if not isinstance(token, str) or len(token) > 8192:
        raise ValueError("invalid-device-token")
    return {"device_id": str(device), "iid": str(install), "device_token": token}


def registration_cookies(response) -> dict:
    result = {}
    for line in response.headers.get_all("Set-Cookie") or []:
        if not isinstance(line, str) or len(line) > 16384 or "\r" in line or "\n" in line:
            continue
        for part in line.split(";"):
            name, _, value = part.strip().partition("=")
            if name in COOKIE_NAMES and value and len(value) < 8192 and all(32 <= ord(c) < 127 for c in value):
                result[name] = value
    return result


def ensure_device(directory: Path) -> dict:
    path = directory / "hongguo-device.json"
    directory.mkdir(parents=True, exist_ok=True)
    if path.exists():
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
            if state.get("params", {}).get("device_id") and state["params"].get("iid"):
                return state
        except Exception:
            pass
    url, body, headers, params = prepare_registration()
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with _direct_opener().open(req, timeout=30) as response:
        if response.status != 200:
            raise RuntimeError(f"register-http-{response.status}")
        payload = response.read(MAX_RESPONSE + 1)
        if len(payload) > MAX_RESPONSE:
            raise RuntimeError("response-too-large")
        if payload[:2] == b"\x1f\x8b":  # urllib 不自动解压，requests 会
            import gzip as gzip_mod
            payload = gzip_mod.decompress(payload)
        cookies = registration_cookies(response)
    identity = parse_identity(payload)
    state = {
        "params": {**params, "device_id": identity["device_id"], "iid": identity["iid"]},
        "device_token": identity["device_token"],
        "cookies": cookies,
        "user_agent": USER_AGENT,
        "created_at": int(time.time()),
    }
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)
    return state


def load_context(directory: Path) -> dict:
    return ensure_device(directory)
