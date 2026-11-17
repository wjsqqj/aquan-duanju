# -*- coding: utf-8 -*-
"""v5 Go 移植黄金夹具生成器：用 Python sidecar（对拍基准）产出确定性向量。

运行：python scripts/v5_golden.py
输出：native/bridge/hongguov5/testdata/golden.json

确定性手段：monkeypatch uuid4/secrets/os.getpid 为固定序列；毫秒显式传参；
素材用仓库内锁定资产；Unicorn 引擎验证历史无关性后复用（见 --matrix 探针）。
"""
import json
import os
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SIDECAR = REPO / "native" / "bridge" / "hongguo-sidecar"
OUT = REPO / "native" / "bridge" / "hongguov5" / "testdata" / "golden.json"
sys.path.insert(0, str(SIDECAR))

import v5register  # noqa: E402
import v5session  # noqa: E402
import v5wire  # noqa: E402
from pyvendor.TTEncrypt import TT  # noqa: E402
from pyvendor.XGorgon import XGorgon  # noqa: E402
from v5assets import CONFIG_NAME, IMAGE_NAME, decode_app_config, load_assets, read_sdk_image  # noqa: E402
from v5unicorn import SdkDigestCore  # noqa: E402

MS = 1774000000000
SECONDS = MS // 1000
DEVICE_ID = "7399254569531119116"
IID = "7189224567890123456"
TOKEN = "Cg8IARABGAIQAQi6vK3wBQi6vK3wBQ"

FIXED_UUIDS = [
    "5f0c8a2e-1b3d-4e5f-9a8b-7c6d5e4f3a21",
    "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
    "99887766-5544-4332-2110-fedcba987654",
]
FIXED_TOKEN_HEX = "c3" * 8


class FakeSecrets:
    """确定性 secrets 替身：按函数名返回固定值，与调用顺序无关。"""

    _RB32 = [0x11111111, 0x22222222, 0x33333333]

    def randbits(self, n):
        if n == 8:
            return 0x5A
        if n == 16:
            return 0x1234
        if n == 32:
            return self._RB32.pop(0) if self._RB32 else 0x11111111
        if n == 64:
            return 0x4444444444444440
        raise AssertionError(f"randbits-{n}")

    def randbelow(self, n):
        if n == 1 << 16:
            return 0x1234
        if n == 900000000:
            return 123456789
        raise AssertionError(f"randbelow-{n}")

    def token_bytes(self, n):
        if n == 4:
            return b"\xaa\xbb\xcc\xdd"
        raise AssertionError(f"token_bytes-{n}")

    def token_hex(self, n):
        if n == 8:
            return FIXED_TOKEN_HEX
        if n == 16:
            return "a1" * 16
        raise AssertionError(f"token_hex-{n}")


FAKE = FakeSecrets()


def main():
    golden = {}

    # ---- 确定性补丁（只影响本进程）----
    uuid_counter = {"i": 0}
    real_uuid4 = v5register.uuid.uuid4

    def fake_uuid4():
        from uuid import UUID
        value = UUID(FIXED_UUIDS[uuid_counter["i"] % len(FIXED_UUIDS)])
        uuid_counter["i"] += 1
        return value

    real_getpid = os.getpid
    v5register.uuid.uuid4 = fake_uuid4
    v5register.secrets.token_hex = FAKE.token_hex
    v5session.secrets = FAKE
    v5wire.secrets = FAKE
    os.getpid = lambda: 12345
    try:
        run(golden)
    finally:
        os.getpid = real_getpid
        v5register.uuid.uuid4 = real_uuid4

    def _scan(node, path):
        if isinstance(node, bytes):
            raise AssertionError(f"bytes at {path}: {node[:16].hex()}")
        if isinstance(node, dict):
            for k, v in node.items():
                _scan(v, f"{path}.{k}")
        elif isinstance(node, list):
            for i, v in enumerate(node):
                _scan(v, f"{path}[{i}]")

    _scan(golden, "root")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(golden, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"golden -> {OUT} ({OUT.stat().st_size} bytes)")


def run(golden):
    assets = load_assets(SIDECAR / "assets", allow_download=False)
    materials = decode_app_config(assets[CONFIG_NAME])
    image = read_sdk_image(assets[IMAGE_NAME])

    # ---- SM3 多长度 ----
    samples = [b"", b"abc", b"a" * 63, b"b" * 64, b"c" * 65, bytes(range(256)) * 4]
    golden["sm3"] = [[s.hex(), v5wire.sm3(s).hex()] for s in samples]

    # ---- protobuf ----
    fields_int = [(1, 2), (3, 8662), (7, 1777775), (16, 255)]
    golden["pb_encode_int"] = v5wire.pb_encode(fields_int).hex()
    golden["pb_decode_int"] = [[n, k, v] for n, k, v in v5wire.pb_decode(bytes.fromhex(golden["pb_encode_int"]))]
    fields_mix = [(1, "8662"), (4, DEVICE_ID), (14, 8), (16, 255.25), (17, b"\x01\x02\x00\x03")]
    enc = v5wire.pb_encode(fields_mix)
    golden["pb_encode_mix"] = enc.hex()
    golden["pb_decode_mix"] = [[n, k, (v.hex() if isinstance(v, bytes) else v)] for n, k, v in v5wire.pb_decode(enc)]
    golden["signed"] = [(-999999, v5wire.signed(-999999)), (1388734, v5wire.signed(1388734)), (0, 0), (1, 2)]

    # ---- XTEA 链（多长度 + 双向）----
    inner = image["exchange_inner_key"]
    golden["xtea"] = []
    for length in (8, 16, 40):
        data = bytes((i * 7 + 3) & 255 for i in range(length))
        enc_fwd = v5session.xtea_chain(data, inner, b"\x01\x02\x03\x04")
        back = v5session.xtea_chain(enc_fwd, inner, b"\x01\x02\x03\x04", decrypt=True)
        assert back == data
        golden["xtea"].append([data.hex(), b"\x01\x02\x03\x04".hex(), enc_fwd.hex()])

    # ---- payload 加解密（固定 nonce/entropy）----
    common = materials["exchange_key"]
    plaintext = v5session._device_payload(
        context_params(), image["unavailable"], None)
    golden["payload_encrypt"] = []
    for nonce, entropy in ((b"\x00\x11\x22\x33", 0x5A), (b"\xaa\xbb\xcc\xdd", 0x07)):
        cipher = v5session.encrypt_payload(plaintext, common=common, inner=inner,
                                           nonce=nonce, entropy_byte=entropy)
        assert plaintext == v5session.decrypt_payload(cipher, common=common, inner=inner)
        golden["payload_encrypt"].append([plaintext.hex(), nonce.hex(), entropy, cipher.hex()])

    # ---- 设备负载构造（字节级）----
    params = context_params()
    golden["device_proof"] = v5session._device_proof(DEVICE_ID).hex()
    golden["device_payload"] = plaintext.hex()
    golden["device_payload_token"] = v5session._device_payload(params, image["unavailable"], TOKEN.encode()).hex()
    golden["bound_device_proof"] = v5session._bound_device_proof(params).hex()
    golden["bootstrap_query"] = v5session._bootstrap_query(
        {**params, "version_name": "7.4.3.32", "version_code": "74332",
         "manifest_version_code": "74332", "update_version_code": "74332",
         "device_platform": "android", "os": "android"}, MS).decode("ascii")

    # ---- ladon 推进 ----
    golden["advance_ladon"] = [
        [prev, alloc, secs, v5session._advance_ladon(prev, alloc, secs)]
        for prev, alloc, secs in ((0, 0x4444444444444440, SECONDS), (0x0BCD1234, 0x12345670, 1700000000))
    ]

    # ---- Unicorn 摘要核心 ----
    core_holder = {}

    def core(payload, mode, seconds):
        engine = core_holder.get("engine")
        if engine is None:
            engine = SdkDigestCore(assets["libmetasec_ml.so"])
        try:
            result = engine.digest(payload, mode, seconds)[0][:16]
        except Exception:
            core_holder["engine"] = None
            raise
        core_holder["engine"] = engine
        return result

    # 历史无关性探针：同输入在“新引擎”与“用过几次的引擎”上输出一致。
    probe_payload = bytes(range(52))
    fresh = SdkDigestCore(assets["libmetasec_ml.so"])
    first = fresh.digest(probe_payload, 3, SECONDS)[0]
    core(probe_payload, 3, SECONDS)
    core(probe_payload, 5, SECONDS)
    second = core_holder["engine"].digest(probe_payload, 3, SECONDS)[0]
    assert first == second, "digest 输出依赖引擎历史，矩阵需复现生产调用序"
    print("digest history-independence: OK")

    golden["digest_matrix"] = []
    for mode in range(16):
        for seconds in (SECONDS, 1700000000):
            payload = bytes(range(20, 52 + 20))[:52]
            d = core_holder["engine"].digest(payload, mode, seconds)[0]
            golden["digest_matrix"].append([payload.hex(), mode, seconds, d.hex()])

    query_b = b"aid=8662&device_platform=android&version_code=74332"
    body_b = b'{"dr_scene":"player"}'
    golden["digest_v5"] = [
        [query_b.hex(), b"".hex(), SECONDS, v5wire.digest_v5(query_b, b"", SECONDS, core=core).hex()],
        [query_b.hex(), body_b.hex(), 1700000000, v5wire.digest_v5(query_b, body_b, 1700000000, core=core).hex()],
    ]

    # ---- wire 原语 ----
    golden["selector"] = [
        [v5wire.sm3(query_b).hex(), __import__("hashlib").md5(body_b).digest().hex(), 1700000000,
         v5wire.selector(v5wire.sm3(query_b), __import__("hashlib").md5(body_b).digest(), 1700000000)],
    ]
    prefix = bytes.fromhex(golden["digest_matrix"][3][3][:32])
    golden["checksum"] = [[prefix.hex(), v5wire.checksum(prefix)]]

    # medusa / v5 块密码
    key16 = v5wire.sm3(b"seed-key")[:16]
    golden["medusa_block"] = [
        [key16.hex(), secs, bytes(range(16)).hex(),
         v5wire.MedusaCipher(key16, secs).block(bytes(range(16))).hex()]
        for secs in (SECONDS, SECONDS + 1, SECONDS + 2, SECONDS + 3)
    ]
    subst = image["substitutions"]
    golden["v5_block"] = [
        [key16.hex(), secs, bytes(range(16)).hex(),
         v5wire.V5BlockCipher(key16, subst[0:256], 0).block(bytes(range(16))).hex(),
         v5wire.V5BlockCipher(key16, subst[256:512], 1).block(bytes(range(16))).hex()]
        for secs in (SECONDS, SECONDS + 1)
    ]
    golden["scramble_key"] = [
        [materials["signing_key"].hex(), nonce, v5wire.derive_scramble_key(materials["signing_key"], nonce)[0].hex(),
         v5wire.derive_scramble_key(materials["signing_key"], nonce)[1].hex()]
        for nonce in (0x12345678, 0xAAAABBBB)
    ]
    scramble_target = bytes(range(64)) * 4
    golden["scramble"] = [
        [scramble_target.hex(), v5wire.derive_scramble_key(materials["signing_key"], 0x12345678)[0].hex(),
         v5wire.scramble(scramble_target, v5wire.derive_scramble_key(materials["signing_key"], 0x12345678)[0]).hex()]
    ]

    # gorgon（固定 nonce）
    golden["xgorgon_handle"] = [
        [bytes((i * 11 + 5) & 255 for i in range(20)).hex(),
         bytes(XGorgon()._XGorgon__handle(list((i * 11 + 5) & 255 for i in range(20)))).hex()]
    ]
    golden["gorgon_v5"] = [
        [query_b.hex(), body_b.hex(), 1700000000, 0x1234, b"\x05\x04".hex(),
         v5wire.gorgon_v5(query_b, body_b, 1700000000, nonce=0x1234, flags=b"\x05\x04")],
        [query_b.hex(), b"".hex(), SECONDS, 0xABCD, bytes(2).hex(),
         v5wire.gorgon_v5(query_b, b"", SECONDS, nonce=0xABCD, flags=bytes(2))],
    ]

    # envelope（固定 nonce）
    proto = golden_proto(image, materials, params)
    golden["envelope_v5"] = [
        [proto.hex(), v5wire.sm3(query_b).hex(), golden["digest_v5"][0][3],
         SECONDS, 0x12345678, 0x9ABCDEF0,
         v5wire.envelope_v5(proto, v5wire.sm3(query_b),
                            bytes.fromhex(golden["digest_v5"][0][3]), SECONDS,
                            0x12345678, 0x9ABCDEF0, seed=materials["signing_key"],
                            frame=image["frame"], prefix=bytes.fromhex(golden["digest_v5"][0][3][:32])[:8],
                            substitution_tables=image["substitutions"])],
    ]

    # ladon/helios（固定随机 4B）
    golden["ladon"] = [
        [SECONDS, 646637794, 8662, b"\xaa\xbb\xcc\xdd".hex(),
         __import__("pyvendor.XLadon", fromlist=["x"]).ladon_encrypt(SECONDS, 646637794, 8662, random_bytes=b"\xaa\xbb\xcc\xdd")],
        [1700000000, 1611921764, 1233, b"\x00\x01\x02\x03".hex(),
         __import__("pyvendor.XLadon", fromlist=["x"]).ladon_encrypt(1700000000, 1611921764, 1233, random_bytes=b"\x00\x01\x02\x03")],
    ]

    # ---- TTEncrypt（确定性：gzip mtime=0 + 固定 32B nonce）----
    import gzip as gzip_mod

    from pyvendor import TTEncrypt as _TTE

    TT_NONCE = [0x61] * 32
    _TTE.TT.hex_9C8 = lambda self: list(TT_NONCE)
    tt = TT()
    payloads = [
        json.dumps({"magic_tag": "ss_app_log", "header": {"aid": 8662, "device_id": DEVICE_ID},
                    "_gen_time": MS}, ensure_ascii=False, separators=(",", ":")),
        "x" * 300,
        "红果短剧中文载荷测试 payload",
        json.dumps({"magic_tag": "ss_app_log", "header": {("k%03d" % i): i for i in range(120)},
                    "_gen_time": MS}, ensure_ascii=False, separators=(",", ":")),
    ]
    golden["tt_encrypt"] = []
    for p in payloads:
        content = bytearray(gzip_mod.compress(p.encode(), compresslevel=9, mtime=0))
        for i, b in enumerate([31, 139, 8, 0, 0, 0, 0, 0, 0, 0]):
            content[i] = b
        frame = tt.encrypt(p)
        assert tt.decrypt(frame) == p, "TT round-trip 失败"
        golden["tt_encrypt"].append([p, content.hex(), frame.hex()])

    # ---- 注册请求（全量确定性）----
    reg_url, reg_body, reg_headers, reg_params = v5register.prepare_registration(MS)
    golden["register_request"] = {
        "url": reg_url,
        "body": reg_body.hex(),
        "headers": {k: str(v) for k, v in sorted(reg_headers.items())},
    }

    # ---- 完整签名请求（bootstrap + playback）----
    context = {
        "params": {**params, "device_id": DEVICE_ID, "iid": IID},
        "cookies": {"odin_tt": "fixed-odin-token", "ttreq": "fixed-ttreq",
                    "store-region": "cn", "store-region-src": "did"},
        "device_token": TOKEN,
        "user_agent": v5register.USER_AGENT,
    }
    bootstrap = v5session.prepare_bootstrap(
        context, MS, materials=materials, image=image, core=core, token=None, previous_ladon=0)
    golden["sign_bootstrap"] = pack_request(bootstrap)
    playback = v5session.prepare_playback_v5(
        context, "7399254569531119117", MS, token=TOKEN,
        previous_ladon=bootstrap["next_ladon"], materials=materials, image=image, core=core)
    golden["sign_playback"] = pack_request(playback)

    # ---- 素材常量 ----
    golden["materials"] = {
        "signing_key": materials["signing_key"].hex(),
        "exchange_key": materials["exchange_key"].hex(),
        "frame": image["frame"].hex(),
        "substitutions": image["substitutions"].hex(),
        "exchange_inner_key": image["exchange_inner_key"].hex(),
        "unavailable": image["unavailable"],
    }


def golden_proto(image, materials, params):
    """构造 envelope 输入 proto（复用 _sign_prepared_v5 的 message 组装形状）。"""
    nonce0 = 0x11111111
    counters = v5wire.pb_encode([(1, 2), (2, 1388734), (3, 1388734), (5, 1388734)])
    environment = v5wire.pb_encode([(1, 2), (6, "v04.10.03.04-bugfix"), (7, 12345 * 2),
                                    (8, params.get("channel", "")),
                                    (12, v5session._bound_device_proof(params)),
                                    (14, "7.4.3.32"), (15, 4228), (19, MS * 2)])
    state = json.dumps({"cmr": 16777216, "cmr2": 16777216, "vpn": 0, "kd": 0,
                        "dyn": "", "do": 0, "tk": False}, separators=(",", ":"))
    prefix = struct.pack("<Q", 0x0504)
    return v5wire.pb_encode([(1, image["frame"]), (2, 10), (3, nonce0 * 2), (4, "8662"),
                             (5, DEVICE_ID), (6, "646637794"), (7, "7.4.3.32"),
                             (8, v5session.SDK_VERSION), (9, v5session.SDK_CODE * 2),
                             (10, prefix), (12, SECONDS * 2), (13, b"\x01" * 20),
                             (14, v5wire.sm3(b"aid=8662")[:6]), (15, counters),
                             (16, ""), (17, SECONDS * 2), (20, "none"), (21, 738),
                             (23, environment), (24, state)])


def context_params():
    _, _, _, params = v5register.prepare_registration(MS)
    return {**params, "device_id": DEVICE_ID, "iid": IID,
            "sdkid": "", "subaid": "", "bd_did": "", "klink_egdi": ""}


def pack_request(request):
    headers = {k: v for k, v in sorted(request["headers"].items())}
    return {"url": request["url"], "headers": headers,
            "body": request["body"].hex(), "next_ladon": request["next_ladon"]}


if __name__ == "__main__":
    main()
