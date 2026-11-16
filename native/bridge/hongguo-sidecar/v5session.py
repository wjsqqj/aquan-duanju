# -*- coding: utf-8 -*-
"""v5 会话与播放签名（自有实现）：mssdk get_token 交换（XTEA 链 + AES-CBC +
CRC16 + zlib）→ 会话持久化 → 播放请求 v5 签名（stub argus/ladon + gorgon_v5 +
helios(646637794) + envelope_v5）→ multi_video_model/player/v1。"""
import base64
import binascii
import hashlib
import json
import os
import re
import secrets
import struct
import time
import urllib.parse
import urllib.request
import zlib
from pathlib import Path
from urllib.parse import quote, urlencode

from pyvendor.XLadon import ladon_encrypt
from v5assets import CONFIG_NAME, decode_app_config, read_sdk_image
from v5wire import (
    V5BlockCipher, digest_v5, derive_scramble_key, envelope_v5, gorgon_v5,
    pb_decode, pb_encode, scramble, signed, sm3, xor_bytes,
)

MASK = 0xFFFFFFFF
MASK64 = (1 << 64) - 1
DELTA = 0x9E3779B9

SDK_VERSION = "v04.10.03-ml-android"
SDK_CODE = 0x040A0300
BOOTSTRAP_ORIGIN = "https://mssdk.zijieapi.com"
BOOTSTRAP_PATH = "/sdi/get_token"
PLAYBACK_ORIGIN = "https://api5-normal-sinfonlineb.fqnovel.com"
PLAYBACK_PATH = "/novel/player/multi_video_model/player/v1"
MAX_PLAIN = 65536
LICENSE_HELIOS_V5 = 646637794
IMAGE_NAME_KEY = "libmetasec_ml.so"


# ---------------- SDI 线材编解码（XTEA 链 + AES-CBC 外层 + CRC16 框架） ----------------

def xtea_chain(data: bytes, key: bytes, nonce: bytes, *, decrypt=False) -> bytes:
    if not data or len(data) % 8 or len(data) > MAX_PLAIN * 2:
        raise ValueError("invalid-xtea-blocks")
    if len(key) != 16 or len(nonce) != 4:
        raise ValueError("invalid-xtea-materials")
    key_words = struct.unpack(">4I", key)
    cycles = 32 + 8 * (int.from_bytes(nonce, "little") % 5)
    previous = nonce + struct.pack("<I", 0x20200427)
    result = bytearray()
    for offset in range(0, len(data), 8):
        source = data[offset:offset + 8]
        block = source if decrypt else bytes(a ^ b for a, b in zip(source, previous))
        words = list(struct.unpack(">2I", block))
        steps = range(cycles * 2 - 1, -1, -1) if decrypt else range(cycles * 2)
        for step in steps:
            target = step & 1
            total = ((step + 1) // 2 * DELTA) & MASK
            other = words[1 - target]
            key_index = (total >> (11 * target)) & 3
            mix = ((((other << 4) ^ (other >> 5)) + other) & MASK) ^ ((total + key_words[key_index]) & MASK)
            words[target] = (words[target] + (-mix if decrypt else mix)) & MASK
        transformed = struct.pack(">2I", *words)
        result.extend(bytes(a ^ b for a, b in zip(transformed, previous)) if decrypt else transformed)
        previous = source if decrypt else transformed
    return bytes(result)


def encrypt_payload(plaintext: bytes, *, common: bytes, inner: bytes, nonce: bytes, entropy_byte: int) -> bytes:
    if len(common) != 32 or len(inner) != 16:
        raise ValueError("invalid-exchange-materials")
    if len(plaintext) > MAX_PLAIN:
        raise ValueError("invalid-plaintext")
    compressed = zlib.compress(plaintext)
    compressed = b"\x78\x01" + compressed[2:]
    container = struct.pack("<I", len(plaintext)) + compressed
    extra = (-len(container)) % 8
    position = 1 + ((extra - 1) % 4)
    frame = bytearray(len(container) + 8 + extra)
    frame[0] = (entropy_byte & 0xF8) | extra
    frame[position:position + len(container)] = container
    crc_offset = 1 if position >= 3 else position + len(container)
    frame[crc_offset:crc_offset + 2] = struct.pack(">H", binascii.crc_hqx(container, 0))
    encrypted = xtea_chain(bytes(frame), inner, nonce)
    wrapped = bytes([encrypted[0] ^ 3]) + encrypted + nonce
    from Crypto.Cipher import AES
    from Crypto.Util.Padding import pad
    return AES.new(common[:16], AES.MODE_CBC, common[16:]).encrypt(pad(wrapped, 16))


def decrypt_payload(ciphertext: bytes, *, common: bytes, inner: bytes) -> bytes:
    if len(common) != 32 or len(inner) != 16:
        raise ValueError("invalid-exchange-materials")
    from Crypto.Cipher import AES
    from Crypto.Util.Padding import unpad
    if not ciphertext or len(ciphertext) % 16 or len(ciphertext) > MAX_PLAIN * 2:
        raise ValueError("invalid-ciphertext")
    try:
        wrapped = unpad(AES.new(common[:16], AES.MODE_CBC, common[16:]).decrypt(ciphertext), 16)
    except ValueError:
        raise ValueError("invalid-padding")
    if len(wrapped) < 13 or (len(wrapped) - 5) % 8 or wrapped[0] ^ wrapped[1] != 3:
        raise ValueError("invalid-outer-frame")
    frame = xtea_chain(wrapped[1:-4], inner, wrapped[-4:], decrypt=True)
    extra = frame[0] & 7
    length = len(frame) - 8 - extra
    position = 1 + ((extra - 1) % 4)
    if length < 4:
        raise ValueError("invalid-inner-frame")
    container = frame[position:position + length]
    expected_size = int.from_bytes(container[:4], "little")
    if expected_size > MAX_PLAIN:
        raise ValueError("response-too-large")
    decoder = zlib.decompressobj()
    value = decoder.decompress(container[4:], expected_size + 1)
    if len(value) != expected_size or not decoder.eof or decoder.unconsumed_tail or decoder.unused_data:
        raise ValueError("invalid-decoded-size")
    return value


def exchange_request(plaintext: bytes, milliseconds: int, *, common: bytes, inner: bytes,
                     nonce: bytes, entropy_byte: int) -> bytes:
    ciphertext = encrypt_payload(plaintext, common=common, inner=inner, nonce=nonce, entropy_byte=entropy_byte)
    return pb_encode([(1, 0x20200422 * 2), (2, 2), (3, 2), (4, ciphertext), (5, milliseconds * 2)])


def exchange_response(packet: bytes, *, common: bytes, inner: bytes):
    fields = {}
    for number, kind, value in pb_decode(packet, limit=MAX_PLAIN * 2):
        if number in (1, 2):
            if kind != 0 or (number in fields and fields[number] != value):
                raise ValueError("invalid-response-header")
        elif number == 3:
            if kind != 0:
                raise ValueError("invalid-response-status")
        elif number == 6:
            if kind != 2 or number in fields:
                raise ValueError("invalid-response-ciphertext")
        else:
            continue
        fields[number] = value
    if fields.get(1) != 0x20120312 * 2 or fields.get(2) != 2:
        raise ValueError("invalid-response-header")
    if 6 not in fields:
        code = fields.get(3)
        if code is not None:
            raise ValueError(f"exchange-refused:{(code >> 1) ^ -(code & 1)}")
        raise ValueError("missing-response-ciphertext")
    decoded = decrypt_payload(fields[6], common=common, inner=inner)
    result = {}
    for number, kind, value in pb_decode(decoded):
        if number not in (1, 2):
            continue
        if number in result or kind != (2 if number == 1 else 0):
            raise ValueError("invalid-session-fields")
        result[number] = value
    if set(result) != {1, 2}:
        raise ValueError("incomplete-session")
    status = (result[2] >> 1) ^ -(result[2] & 1)
    if status not in (200, 202):
        raise ValueError(f"session-status-{status}")
    token = result[1].decode("utf-8")
    if not token or len(result[1]) > 256 or any(ord(c) < 33 or ord(c) > 126 for c in token):
        raise ValueError("invalid-session-token")
    return {"token": token, "status": status}


# ---------------- 设备负载 / 引导请求 ----------------

def _device_proof(device_id: str) -> bytes:
    return pb_encode([
        (1, 2), (2, 4), (3, "8662"), (4, device_id),
        (5, "Ai6svO3PyrwDOUSmO6ZcResxu"), (6, "!noperm!"), (7, 1777775), (8, 1777775),
        (9, 6), (10, 1777775), (11, "!notset!"), (12, "Asia/Shanghai,8"), (13, "zh_CN"), (14, 8),
        (16, 255.24993896484375), (17, 35.58599090576172), (18, 3.467449188232422),
        (19, 3.467449188232422), (20, 255.1754913330078), (21, 42.17544174194336),
        (22, "16"), (23, 82), (24, 72), (25, 3456776033270), (26, 3456776033270),
        (27, 3456776033270), (28, 3456776033274), (29, 1), (30, "25053RT47C"), (31, "Redmi"),
        (32, "25053RT47C"), (33, "25053RT47C"), (34, "Xiaomi"), (35, "Redmi"), (36, "Redmi"), (38, 62),
    ])


def _device_payload(params: dict, marker: str, token) -> bytes:
    strings = [1, 19, 20, 23, 28, 31, 32, 38, 39, 50, 53, 93, 94, 95, 96,
               109, 110, 111, 115, 135, 2000, 2001]
    numbers = [13, 29, 30, 36, 37, 41, 42, 43, 49, 51, 52, 56, 57, 58, 59,
               60, 61, 62, 63, 64, 66, 67, 69, 70, 71, 72, 73, 74, 75, 76,
               77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 97, 98, 99,
               100, 101, 102, 103, 104, 105, 113, 114, 116, 117, 118]
    values = {index: marker for index in strings}
    values.update({index: signed(-999999) for index in numbers})
    for index, key in ((2, "device_brand"), (3, "device_type"), (6, "os_version"),
                       (7, "resolution"), (9, "rom_version")):
        values[index] = params.get(key) or marker
    values.update({5: "Android", 12: "Asia/Shanghai,8"})
    for index, key in ((8, "dpi"), (48, "os_api")):
        raw = str(params.get(key, ""))
        values[index] = signed(int(raw)) if raw.isdigit() else signed(-999999)
    fields = [(1, pb_encode(sorted(values.items()))), (3, "android"), (4, SDK_VERSION),
              (5, signed(SDK_CODE)), (6, params["aid"]), (7, params["version_name"]),
              (8, params["device_id"]), (11, signed(-999999)), (16, signed(-999999)), (17, marker)]
    if token is not None:
        fields.insert(1, (2, token))
    return pb_encode(fields)


def _bound_device_proof(params: dict) -> bytes:
    replacements = {3: params["aid"], 4: params["device_id"], 5: params["cdid"],
                    22: params["os_version"], 30: params["device_type"],
                    31: params["device_brand"], 32: params["device_type"],
                    33: params["device_type"], 34: params["device_brand"],
                    35: params["device_brand"], 36: params["device_brand"]}
    fields = []
    for number, kind, value in pb_decode(_device_proof(params["device_id"])):
        if number in replacements:
            value = replacements[number]
        elif kind == 5:
            value = struct.unpack("<f", value)[0]
        fields.append((number, value))
    return pb_encode(fields)


def _advance_ladon(previous: int, allocation: int, seconds: int) -> int:
    checksum = 0
    for byte in b"646637794":
        checksum ^= byte
        for _ in range(8):
            checksum = (checksum >> 1) ^ (0x95AC9329AC4BC9B5 if checksum & 1 else 0)
    checksum &= MASK64
    mixed = (allocation ^ checksum ^ seconds) & MASK64
    rotated = ((mixed << 4) | (mixed >> 60)) & MASK64
    return previous ^ (rotated & MASK)


def _bootstrap_query(params: dict, milliseconds: int) -> bytes:
    fields = [("lc_id", "646637794"), ("platform", "android"), ("device_platform", "android"),
              ("sdk_ver", SDK_VERSION), ("sdk_ver_code", str(SDK_CODE)),
              ("app_ver", params["version_name"]), ("version_code", params["version_code"]),
              ("aid", params["aid"]), ("sdkid", params.get("sdkid", "")),
              ("subaid", params.get("subaid", "")), ("iid", params["iid"]),
              ("did", params["device_id"]), ("bd_did", params.get("bd_did", "")),
              ("client_type", "inhouse"), ("region_type", "ml"), ("mode", "2"),
              ("full_update_version_code", params["update_version_code"])]
    for key in ("os", "ssmix", "_rticket", "cdid", "channel", "app_name", "version_name",
                "manifest_version_code", "update_version_code", "resolution", "dpi", "device_type",
                "device_brand", "language", "os_api", "os_version", "ac", "host_abi",
                "dragon_device_type", "pv_player", "compliance_status", "need_personal_recommend",
                "player_so_load", "is_android_pad_screen", "rom_version", "device_id", "klink_egdi"):
        value = str(milliseconds) if key == "_rticket" else ("1" if key == "need_personal_recommend" else params.get(key, ""))
        fields.append((key, value))
    return urlencode(fields, quote_via=quote, safe="*").encode("ascii")


def _send(request) -> bytes:
    parts = urllib.parse.urlsplit(request["url"])
    if (parts.scheme, parts.netloc, parts.path) not in (
            ("https", "mssdk.zijieapi.com", "/sdi/get_token"),
            ("https", PLAYBACK_ORIGIN.replace("https://", ""), PLAYBACK_PATH)):
        raise ValueError("invalid-route")
    if any(k.lower() in ("authorization", "x-tt-token", "x-tt-passport-csrf-token") for k in request["headers"]):
        raise ValueError("account-auth-on-sdk-route")
    req = urllib.request.Request(request["url"], data=request["body"],
                                 headers=dict(request["headers"]), method="POST")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=20) as response:
        if response.status != 200:
            raise ValueError(f"request-http-{response.status}")
        limit = 131072 if parts.path == "/sdi/get_token" else 2 * 1024 * 1024
        data = response.read(limit + 1)
        if len(data) > limit:
            raise ValueError("response-limit")
    if not data:
        raise ValueError("response-empty")
    return data


def _sign_prepared_v5(params, cookies, query, body, milliseconds, *, materials, image,
                      core, token, previous_ladon, origin, path, bootstrap=False):
    seconds = milliseconds // 1000
    proof = digest_v5(query, body, seconds, core=core)
    prefix = struct.pack("<Q", 2 if bootstrap else 0x0504)
    counters = pb_encode([(1, 2), (2, 1388734), (3, 1388734), (5, 1388734)])
    environment = pb_encode([(1, 2), (6, "v04.10.03.04-bugfix"), (7, os.getpid() * 2),
                             (8, params.get("channel", "")), (12, _bound_device_proof(params)),
                             (14, params["version_name"]), (15, 4228), (19, milliseconds * 2)])
    state = json.dumps({"cmr": 16777216, "cmr2": 16777216, "vpn": 0, "kd": 0,
                        "dyn": "", "do": 0, "tk": token is not None}, separators=(",", ":"))
    nonce = [secrets.randbits(32) for _ in range(3)]
    message = pb_encode([(1, image["frame"]), (2, 10), (3, nonce[0] * 2), (4, "8662"),
                         (5, params["device_id"]), (6, "646637794"), (7, params["version_name"]),
                         (8, SDK_VERSION), (9, SDK_CODE * 2), (10, prefix), (12, seconds * 2),
                         (13, proof), (14, sm3(query)[:6]), (15, counters),
                         (16, token or ""), (17, seconds * 2), (20, "none"), (21, 738),
                         (23, environment), (24, state)])
    medusa = envelope_v5(message, sm3(query), proof, seconds, nonce[1], nonce[2],
                         seed=materials["signing_key"], frame=image["frame"], prefix=prefix,
                         substitution_tables=image["substitutions"])
    next_ladon = _advance_ladon(previous_ladon, secrets.randbits(64) & ~15, seconds)
    headers = {
        "Content-Type": "application/octet-stream", "Accept": "*/*",
        "X-TT-Request-Tag": "t=0;n=0", "X-SS-DP": "8662", "X-Khronos": str(seconds),
        "X-Argus": base64.b64encode(struct.pack("<I", seconds)).decode(),
        "X-Ladon": base64.b64encode(struct.pack(">I", next_ladon)).decode(),
        "X-Gorgon": gorgon_v5(query, body, seconds, flags=prefix[:2]),
        "X-Helios": ladon_encrypt(seconds, LICENSE_HELIOS_V5, 8662, random_bytes=secrets.token_bytes(4)),
        "X-Medusa": medusa,
        "X-SS-STUB": hashlib.md5(body).hexdigest().upper(),
        "X-VC-Bdturing-SDK-Version": "4.0.3.cn",
        "X-TT-Trace-ID": f"00-{secrets.token_hex(16)}-{secrets.token_hex(8)}-01",
        "User-Agent": (f"com.phoenix.read/74332 (Linux; U; Android {params['os_version']}; zh_CN; "
                       f"{params['device_type']}; Cronet/TTNetVersion:8d40f833_2026-03-03)"),
    }
    selected = {"install_id": params["iid"]}
    for name in ("odin_tt", "ttreq", "store-region"):
        value = cookies.get(name)
        if value and isinstance(value, str) and len(value) <= 8192 \
                and not re.search(r"[\x00-\x20;\x7f-\uffff]", value):
            selected[name] = value
    selected["store-region-src"] = "did"
    headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in selected.items())
    return {"url": origin + path + "?" + query.decode("ascii"), "headers": headers,
            "body": body, "next_ladon": next_ladon}


def prepare_bootstrap(context, milliseconds, *, materials, image, core, token=None, previous_ladon=0):
    params = dict(context["params"])
    params.update(version_name="7.4.3.32", version_code="74332", manifest_version_code="74332",
                  update_version_code="74332", device_platform="android", os="android")
    query = _bootstrap_query(params, milliseconds)
    plaintext = _device_payload(params, image["unavailable"], token)
    body = exchange_request(plaintext, milliseconds, common=materials["exchange_key"],
                            inner=image["exchange_inner_key"], nonce=secrets.token_bytes(4),
                            entropy_byte=secrets.randbits(8))
    return _sign_prepared_v5(params, context.get("cookies", {}), query, body, milliseconds,
                             materials=materials, image=image, core=core, token=token,
                             previous_ladon=previous_ladon, origin=BOOTSTRAP_ORIGIN,
                             path=BOOTSTRAP_PATH, bootstrap=True)


def prepare_playback_v5(context, video, milliseconds, *, token, previous_ladon, materials, image, core):
    cookies = context.get("cookies", {})
    params = dict(context["params"])
    if params.get("aid") != "8662":
        raise ValueError("invalid-application")
    params.update(version_code="74332", version_name="7.4.3.32", update_version_code="74332",
                  manifest_version_code="74332", device_platform="android", os="android",
                  _rticket=str(milliseconds))
    names = ("device_platform os ssmix _rticket cdid channel aid app_name version_code version_name "
             "manifest_version_code update_version_code resolution dpi device_type device_brand "
             "language os_api os_version ac host_abi dragon_device_type pv_player compliance_status "
             "need_personal_recommend player_so_load is_android_pad_screen rom_version device_id iid "
             "klink_egdi").split()
    query = urlencode([(name, params[name]) for name in names if params.get(name)],
                      quote_via=quote, safe="*").encode("ascii")
    payload = {"dr_scene": "player", "mixed_video_id_map": {"1004": [video]}, "biz_param": {
        "detail_page_version": 0, "device_level": 4, "disable_digg_stat": False,
        "need_all_video_definition": True, "need_mp4_align": False, "use_os_player": False,
        "use_server_dns": False, "video_platform": 1024}}
    import gzip as gzip_mod
    body = gzip_mod.compress(json.dumps(payload, separators=(",", ":")).encode(), mtime=0)
    request = _sign_prepared_v5(params, cookies, query, body, milliseconds, token=token,
                                previous_ladon=previous_ladon, materials=materials, image=image,
                                core=core, origin=PLAYBACK_ORIGIN, path=PLAYBACK_PATH, bootstrap=False)
    request["headers"].update({
        "Content-Type": "application/json; charset=utf-8", "Content-Encoding": "gzip",
        "Accept": "application/json",
        "X-Reading-Request": f"{milliseconds}-{100000000 + secrets.randbelow(900000000)}",
        "X-TT-Store-Region": cookies.get("store-region") or "cn",
        "X-TT-Store-Region-Src": "did",
        "X-SS-REQ-TICKET": str(milliseconds),
    })
    return request


# ---------------- 会话持久化与获取 ----------------

SESSION_VERSION = "v04.10.03-ml-android"


def _binding(context) -> str:
    params = context["params"]
    data = json.dumps({k: params[k] for k in ("aid", "device_id", "iid", "cdid")},
                      sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(data).hexdigest()


def _validate_session(state, binding):
    if state.get("schema") != 1 or state.get("sdkVersion") != SESSION_VERSION or state.get("status") != 200:
        raise ValueError("invalid-session")
    if state.get("deviceBinding") != binding:
        raise ValueError("session-device-mismatch")
    token = state.get("token")
    if not isinstance(token, str) or not 1 <= len(token) <= 256 or any(ord(c) < 33 or ord(c) > 126 for c in token):
        raise ValueError("invalid-token")
    if not isinstance(state.get("ladon"), int) or not 0 <= state["ladon"] <= MASK:
        raise ValueError("invalid-ladon-state")
    return dict(state)


def ensure_session(directory: Path, context, assets: dict, core) -> dict:
    path = directory / "hongguo-sdk-session.json"
    directory.mkdir(parents=True, exist_ok=True)
    binding = _binding(context)
    if path.exists():
        try:
            return _validate_session(json.loads(path.read_text(encoding="utf-8")), binding)
        except Exception:
            pass
    materials = decode_app_config(assets[CONFIG_NAME])
    image = read_sdk_image(assets[IMAGE_NAME_KEY])
    previous_ladon = 0
    token = None
    for _attempt in range(2):
        prepared = prepare_bootstrap(context, int(time.time() * 1000), materials=materials,
                                     image=image, core=core, token=token,
                                     previous_ladon=previous_ladon)
        result = exchange_response(_send(prepared), common=materials["exchange_key"],
                                   inner=image["exchange_inner_key"])
        if result["status"] == 200:
            state = {"schema": 1, "sdkVersion": SESSION_VERSION, "status": 200,
                     "deviceBinding": binding, "token": result["token"],
                     "ladon": prepared["next_ladon"], "createdAt": int(time.time())}
            state = _validate_session(state, binding)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
            tmp.replace(path)
            return state
        if result["status"] != 202:
            raise ValueError(f"session-status-{result['status']}")
        token = result["token"]
        previous_ladon = prepared["next_ladon"]
    raise ValueError("session-not-ready")
