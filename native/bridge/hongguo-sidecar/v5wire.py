# -*- coding: utf-8 -*-
"""红果 v5 匿名取流协议 — wire 编解码原语（本项目自有实现）。

协议常量（字段号/置换表/种子/帧常量）来自公开逆向研究的互操作事实；
实现结构为本项目独立编写。SM3 优先用 hashlib（OpenSSL 3.x 自带），
不可用时回退纯 Python 实现。
"""
import base64
import hashlib
import json
import secrets
import struct
from pathlib import Path

from pyvendor.XGorgon import XGorgon
from pyvendor.XLadon import ladon_encrypt

MASK = 0xFFFFFFFF
DELTA = 0x9E3779B9

# 表文件已随 Go 原生移植移入 hongguov5 包（go:embed 单一事实源）。
_FULL_TABLES = json.loads(
    (Path(__file__).resolve().parent.parent / "hongguov5" / "medusa_wire_tables.json").read_text())
_TABLES = _FULL_TABLES["variants"]
_DIGEST_INDICES = bytes.fromhex(_FULL_TABLES["digestIndices"])
_DIGEST_CONSTANTS = _FULL_TABLES["digestRoundConstants"]
_MEDUSA_CONSTANTS = (0xCA025DDC, 0x823DC546, 0xC9420583, 0xC298225F)
_V5_ROUND_CONSTANTS = (0xBBB5DE72, 0xD4638D5B, 0x92A5F73B, 0x89F8A1C9)
_V5_ROW_ORDERS = ((2, 0, 3, 1), (1, 3, 2, 0), (3, 2, 1, 0), (2, 3, 1, 0))
_V5_LAST_COLUMN = ((15, 7, 3, 11), (11, 3, 15, 7), (3, 15, 11, 7), (15, 3, 11, 7))
_V5_SOURCE_BITS = (6, 5, 3, 4, 2, 7, 1, 0)
_V5_PACKED_BITS = (1, 7, 3, 6, 2, 0, 4, 5)


# ---------------- SM3（hashlib 优先，纯 Python 兜底） ----------------

def _sm3_pure(data: bytes) -> bytes:
    IV = (0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600,
          0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E)
    T = [0x79CC4519] * 16 + [0x7A879D8A] * 48

    def rol(x, n):
        n %= 32
        return ((x << n) | (x >> (32 - n))) & MASK

    def ff(a, b, c, i):
        return (a ^ b ^ c) if i < 16 else ((a & b) | (a & c) | (b & c))

    def gg(a, b, c, i):
        return (a ^ b ^ c) if i < 16 else (((a ^ b) & c) | (a & (b ^ c))) & MASK

    def p0(x):
        return x ^ rol(x, 9) ^ rol(x, 17)

    def p1(x):
        return x ^ rol(x, 15) ^ rol(x, 23)

    msg = bytearray(data)
    bitlen = len(data) * 8
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    msg += struct.pack(">Q", bitlen)
    v = list(IV)
    for off in range(0, len(msg), 64):
        w = list(struct.unpack(">16I", msg[off:off + 64]))
        for i in range(16, 68):
            a = w[i - 16] ^ w[i - 9] ^ rol(w[i - 3], 15)
            a ^= rol(a, 15) ^ rol(a, 23)
            w.append(p1(a) ^ w[i - 13] ^ rol(w[i - 6], 7))
        a, b, c, d, e, f, g, h = v
        for i in range(64):
            ss1 = rol((rol(a, 12) + T[i] + rol(w[i], i % 32)) & MASK, 7)
            ss2 = ss1 ^ rol(a, 12)
            tt1 = (ff(a, b, c, i) + d + ss2 + w[68 + i]) & MASK
            tt2 = (gg(e, f, g, i) + h + ss1 + w[i]) & MASK
            d = c
            c = rol(b, 9)
            b = a
            a = tt1
            h = g
            g = rol(f, 19)
            f = e
            e = p0(tt2)
        v = [(x ^ y) & MASK for x, y in zip(v, (a, b, c, d, e, f, g, h))]
    return struct.pack(">8I", *v)


def sm3(data: bytes) -> bytes:
    try:
        return hashlib.new("sm3", data).digest()
    except Exception:
        return _sm3_pure(data)


# ---------------- protobuf（保持字节序：写入序） ----------------

def pb_varint(value: int) -> bytes:
    if not 0 <= value < (1 << 64):
        raise ValueError("protobuf-field-out-of-range")
    out = bytearray()
    while value > 127:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


def pb_encode(fields) -> bytes:
    """fields: [(number, value)]；int=varint、float=fixed32 LE、str/bytes=LEN。
    空字符串/空字节按上游惯例省略。"""
    out = bytearray()
    for number, value in fields:
        if isinstance(value, bool):
            value = int(value)
        if isinstance(value, int):
            out += pb_varint(number << 3)
            out += pb_varint(value)
        elif isinstance(value, float):
            out += pb_varint((number << 3) | 5)
            out += struct.pack("<f", value)
        else:
            if isinstance(value, str):
                value = value.encode("utf-8")
            if value:
                out += pb_varint((number << 3) | 2)
                out += pb_varint(len(value))
                out += value
    return bytes(out)


def pb_decode(data: bytes, limit=1 << 16):
    """严格有界 protobuf 读：[(number, wire_type, value)]，保留重复。"""
    if len(data) > limit:
        raise ValueError("wire-data-too-large")
    rows, cursor = [], 0
    while cursor < len(data):
        tag, cursor = _pb_int(data, cursor)
        number, kind = tag >> 3, tag & 7
        if not 1 <= number < (1 << 29):
            raise ValueError("protobuf-field-invalid")
        if kind == 0:
            value, cursor = _pb_int(data, cursor)
        elif kind in (1, 2, 5):
            size = 8 if kind == 1 else (4 if kind == 5 else 0)
            if kind == 2:
                size, cursor = _pb_int(data, cursor)
            if size > len(data) - cursor:
                raise ValueError("protobuf-field-truncated")
            value = data[cursor:cursor + size]
            cursor += size
        else:
            raise ValueError("protobuf-wire-type-unsupported")
        rows.append((number, kind, value))
        if len(rows) > 512:
            raise ValueError("too-many-wire-fields")
    return rows


def _pb_int(data, cursor):
    result = 0
    for part in range(10):
        if cursor >= len(data):
            raise ValueError("protobuf-number-truncated")
        byte = data[cursor]
        cursor += 1
        if part == 9 and byte > 1:
            raise ValueError("protobuf-number-overflow")
        result |= (byte & 127) << (7 * part)
        if byte < 128:
            return result, cursor
    raise ValueError("protobuf-number-invalid")


def zigzag(value: int) -> int:
    return (value << 1) ^ (value >> 63) & ((1 << 64) - 1) if value >= 0 else ((-value) * 2 - 1)


def signed(value: int) -> int:
    """上游 signed()：Python 任意精度语义，正数×2、负数 ~(-2v)。
    设备负载与 bootstrap 计数都用它。"""
    return (value << 1) ^ (value >> 63)


# ---------------- medusa v3 摘要分支（selector/checksum/digest_branch_two） ----------------

def selector(query_digest: bytes, body_digest: bytes, seconds: int) -> int:
    value = 0x20230928
    for part in (query_digest, body_digest, struct.pack("<I", seconds)):
        for index, byte in enumerate(part):
            if index % 2:
                value = ~(value ^ (value >> 7) ^ ((value << 12) | byte)) & MASK
            else:
                value = (value ^ (value >> 4) ^ (value << 6) ^ byte) & MASK
    return value


def checksum(value: bytes) -> int:
    result = 0x20220420
    for index, byte in enumerate(value[:12]):
        if index % 2:
            result = (result ^ (result >> 5) ^ ~((result << 11) | byte)) & MASK
        else:
            result = (result ^ (result >> 3) ^ (result << 7) ^ byte) & MASK
    return ((result | 4) ^ 0x01000000) & MASK


def digest_branch_two(query_digest, body_digest, seconds):
    choice = selector(query_digest, body_digest, seconds)
    if (choice & 15) % 3 != 2:
        raise ValueError("unsupported-digest-branch")
    variant = ((choice & 13) * 86) >> 8
    bias = (0x8980F29B, 0xEB549C7F, 0xB08726DB, 0xD40CB5E6, 0xE8F559E4)[variant]
    seed = (seconds + bias) & MASK
    shift = (seed + 5) & 7
    suffix = bytes(((v >> shift) | (v << (8 - shift))) & 255 for v in bytes.fromhex("8496779dd4150bf8"))
    message = query_digest + body_digest + struct.pack("<I", seconds) + suffix + struct.pack("<I", 416)
    words = struct.unpack("<16I", message)
    iv = [_rol32(v, -seed) for v in (0x79E0F2FB, 0xC8B52570, 0xEBC2F8CD, 0x7C104D93)]
    finish = [_rol32(v, -((seed + 6) & 255)) for v in (0x19BE4866, 0xE85986B4, 0xE19B326E, 0x71D1D7D4)]
    a, b, c, d = iv
    schedule = _DIGEST_INDICES[variant * 64:(variant + 1) * 64]
    constants = _DIGEST_CONSTANTS
    shifts = ((7, 12, 17, 22), (5, 9, 14, 20), (4, 11, 16, 23), (6, 10, 15, 21))
    for step in range(64):
        phase = step // 16
        if phase == 0:
            f = (b & c) | (~b & d)
        elif phase == 1:
            f = (b & d) | (c & ~d)
        elif phase == 2:
            f = b ^ c ^ d
        else:
            f = c ^ (b | ~d)
        constant = _rol32(constants[step] & MASK, -((seed + 1) & 255))
        result = (b + _rol32((a + f + words[schedule[step]] + constant) & MASK, shifts[phase][step % 4])) & MASK
        a, d, c, b = d, c, b, result
    final = struct.pack("<4I", *[((v + i) & MASK) ^ f for v, i, f in zip((a, b, c, d), iv, finish)])
    return final + struct.pack("<I", checksum(final))


def _rol32(value: int, bits: int) -> int:
    value &= MASK
    bits %= 32
    return ((value << bits) | (value >> ((32 - bits) % 32))) & MASK


# ---------------- medusa v3 线材密码（V5BlockCipher 的基类） ----------------

def xor_bytes(a: bytes, b: bytes) -> bytes:
    if len(a) != len(b):
        raise ValueError("length-mismatch")
    return bytes(x ^ y for x, y in zip(a, b))


def _twice(value: int) -> int:
    return ((value << 1) ^ (0x11B if value & 128 else 0)) & 255


def _rotate_byte(value: int, bits: int) -> int:
    value &= 255
    return ((value << bits) | (value >> (8 - bits))) & 255


def derive_scramble_key(seed: bytes, nonce: int):
    digest = sm3(seed + struct.pack("<I", nonce) + seed)
    byte = (nonce >> 16) & 255
    mask = ~((((nonce >> 5) & 0x7F800) | (nonce >> 24)) ^ (byte >> 5) ^ byte) & MASK
    return digest, struct.pack("<I", mask)


def scramble(payload: bytes, key: bytes) -> bytes:
    if len(payload) < 4 or len(key) != 32:
        raise ValueError("invalid-scramble-input")
    transformed = []
    for index, value in enumerate(payload):
        a, b = key[(index % 8) * 4:(index % 8) * 4 + 2]
        middle = _rotate_byte((~(_rotate_byte(value, 4) + a)) ^ b, 3)
        transformed.append(~((middle + b) ^ a) & 255)
    out = bytearray(reversed(transformed))
    original_first = out[0]
    edge = out[-1] ^ out[-2]
    out[0] = (out[0] + (~edge & 255)) & 255
    out[1] = (out[1] + ((out[-1] ^ out[0] ^ 0xFE) & 255)) & 255
    out[2] = (out[2] + (((edge - original_first) & 255) ^ _rotate_byte(out[1], 3) ^ 2)) & 255
    for index in range(3, len(out) - 1):
        out[index] = (out[index] + (~(out[index - 2] ^ _rotate_byte(out[index - 1], 3) ^ index) & 255)) & 255
    out[-1] ^= out[-2]
    out[0] = ((out[0] ^ out[1]) + sum(out[1:])) & 255
    return bytes(out)


class MedusaCipher:
    def __init__(self, key: bytes, seconds: int):
        if len(key) != 16:
            raise ValueError("invalid-wire-key")
        variant = seconds % 4
        self.box = base64.b64decode(_TABLES[variant]["box"])
        self.rows, self.shift = _TABLES[variant]["rows"], _TABLES[variant]["shift"]
        constant = _MEDUSA_CONSTANTS[variant]
        initial = xor_bytes(key, struct.pack("<I", constant) * 4)
        words = [initial[i:i + 4] for i in range(0, 16, 4)]
        for i in range(4, 12):
            word = words[-1]
            if i % 4 == 0:
                word = bytearray(self.box[v] for v in word[1:] + word[:1])
                word[0] ^= (constant >> ((2 * i) & 24)) & 255
            words.append(xor_bytes(words[i - 4], word))
        self.keys = [b"".join(words[i:i + 4]) for i in range(0, 12, 4)]

    def _add_key(self, state: bytes, key: bytes) -> bytes:
        return bytes(state[row * 4 + col] ^ key[row * 4 + self.rows[col]]
                     for row in range(4) for col in range(4))

    def block(self, block: bytes) -> bytes:
        if len(block) != 16:
            raise ValueError("invalid-block")
        state = self._add_key(block, self.keys[0])
        for step in (1, 2):
            sub = bytes(self.box[v] for v in state)
            reordered = b"".join(sub[row * 4:row * 4 + 4] for row in self.rows)
            state = bytes(reordered[i] for i in self.shift)
            if step == 1:
                state = bytes(state[row * 4 + self.rows[col]] for row in range(4) for col in range(4))
                output = bytearray(16)
                for col in range(4):
                    column = [state[row * 4 + col] for row in range(4)]
                    total = column[0] ^ column[1] ^ column[2] ^ column[3]
                    for row in range(4):
                        output[row * 4 + col] = column[row] ^ total ^ _twice(column[row] ^ column[(row + 1) % 4])
                state = bytes(output)
            state = self._add_key(state, self.keys[step])
        return xor_bytes(state, self.keys[1])

    def wrap(self, payload: bytes, iv: bytes) -> bytes:
        if len(payload) < 248 or len(iv) != 16:
            raise ValueError("invalid-wire-envelope")
        source_bits = (5, 6, 2, 4, 3, 1, 0, 7)
        packed_bits = (1, 6, 0, 7, 2, 4, 5, 3)
        sampled = bytes(sum(((payload[group * 8 + j] >> source_bits[j]) & 1) << packed_bits[j]
                            for j in range(8)) for group in range(31)) + b"\x01"
        previous = iv
        encrypted = b""
        for index in (0, 16):
            previous = self.block(xor_bytes(sampled[index:index + 16], previous))
            encrypted += previous
        out = bytearray(payload)
        for group in range(31):
            for j in range(8):
                bit = source_bits[j]
                out[group * 8 + j] = (out[group * 8 + j] & ~(1 << bit)) | (((encrypted[group] >> packed_bits[j]) & 1) << bit)
        return encrypted[-1:] + bytes(out)


# ---------------- v5 线材（digest/gorgon/cipher/envelope） ----------------

def digest_v5(query: bytes, body: bytes, seconds: int, core) -> bytes:
    query_hash = sm3(query)
    body_hash = hashlib.md5(body).digest() if body else bytes(16)
    mode = selector(query_hash, body_hash, seconds) & 15
    payload = query_hash + body_hash + struct.pack("<I", seconds)
    prefix = core(payload, mode, seconds)
    if not isinstance(prefix, bytes) or len(prefix) != 16:
        raise ValueError("invalid-sdk-core-result")
    return prefix + struct.pack("<I", checksum(prefix) | 0x20)


def gorgon_v5(query: bytes, body: bytes, seconds: int, nonce=None, flags: bytes = bytes(2)) -> str:
    if nonce is None:
        nonce = secrets.randbelow(1 << 16)
    query_hash = hashlib.md5(query).digest()[:4]
    body_hash = hashlib.md5(body).digest()[:4] if body else bytes(4)
    payload = query_hash + body_hash + bytes(4) + bytes.fromhex("00030A04") + struct.pack(">I", seconds)
    key = bytes((0x4A, flags[0], 0x16, nonce >> 8, 0x47, 0x6C, flags[1], nonce & 0xFF))
    from Crypto.Cipher import ARC4
    encrypted = ARC4.new(key).encrypt(payload)
    transformed = bytes(XGorgon()._XGorgon__handle(list(encrypted)))
    frame = bytes.fromhex("8404") + struct.pack("<H", nonce) + flags
    return (frame + transformed).hex()


class V5BlockCipher(MedusaCipher):
    def __init__(self, key: bytes, substitution: bytes, variant: int):
        if len(key) != 16 or len(substitution) != 256 or not 0 <= variant < 4:
            raise ValueError("invalid-wire-cipher-init")
        self.box = substitution
        self.rows = _V5_ROW_ORDERS[variant]
        self.shift = tuple(_V5_LAST_COLUMN[variant][index // 4] if index % 4 == 3
                           else (index + (0, 8, 12)[index % 4]) % 16 for index in range(16))
        constant = _V5_ROUND_CONSTANTS[variant]
        initial = xor_bytes(key, struct.pack("<I", constant) * 4)
        words = [initial[i:i + 4] for i in range(0, 16, 4)]
        for index in range(4, 12):
            previous = words[-1]
            if index % 4 == 0:
                rotated = previous[1:] + previous[:1]
                previous = bytes(self.box[byte] for byte in rotated)
                round_byte = (constant >> ((2 * index) & 24)) & 255
                previous = bytes((previous[0] ^ round_byte,)) + previous[1:]
            words.append(xor_bytes(words[index - 4], previous))
        self.keys = [b"".join(words[index:index + 4]) for index in (0, 4, 8)]


def compact_cipher_v5(payload: bytes, seconds: int, key_material: bytes, substitution_tables: bytes) -> bytes:
    if len(payload) < 248 or len(key_material) != 32 or len(substitution_tables) != 1024:
        raise ValueError("invalid-wire-payload")
    sampled = bytes(sum(((payload[group * 8 + bit] >> _V5_SOURCE_BITS[bit]) & 1) << _V5_PACKED_BITS[bit]
                        for bit in range(8)) for group in range(31)) + b"\x01"
    variant = seconds & 3
    cipher = V5BlockCipher(hashlib.md5(key_material[:16]).digest(),
                           substitution_tables[variant * 256:(variant + 1) * 256], variant)
    first = cipher.block(xor_bytes(sampled[:16], hashlib.md5(key_material[16:]).digest()))
    return first + cipher.block(xor_bytes(sampled[16:], first))


def envelope_v5(proto: bytes, query_digest: bytes, body_proof: bytes, seconds: int,
                key_nonce: int, frame_nonce: int, *, seed: bytes, frame: bytes,
                prefix: bytes, substitution_tables: bytes) -> str:
    for value, size in ((query_digest, 32), (body_proof, 20), (seed, 32),
                        (frame, 16), (prefix, 8), (substitution_tables, 1024)):
        if not isinstance(value, bytes) or len(value) != size:
            raise ValueError("invalid-wire-component")
    if not isinstance(proto, bytes) or not 229 <= len(proto) <= (1 << 20):
        raise ValueError("invalid-proof-message")
    key, mask = derive_scramble_key(seed, key_nonce)
    mixed = bytes(reversed(prefix + scramble(proto, key)))
    mixed = bytes(value ^ mask[(~index) & 3] for index, value in enumerate(mixed))
    flags = 0x18000001 | ((query_digest[0] & 63) << 14) | ((body_proof[0] & 63) << 8)
    payload = bytearray(b"\xCA" + struct.pack("<II", frame_nonce, flags) + mixed + struct.pack("<H", key_nonce >> 16))
    encrypted = compact_cipher_v5(bytes(payload), seconds, seed, substitution_tables)
    for group in range(31):
        for offset, source_bit in enumerate(_V5_SOURCE_BITS):
            index = group * 8 + offset
            bit = (encrypted[group] >> _V5_PACKED_BITS[offset]) & 1
            payload[index] = (payload[index] & ~(1 << source_bit)) | (bit << source_bit)
    header = struct.pack("<I", seconds ^ 5) + xor_bytes(frame, struct.pack("<I", seconds) * 4)
    result = header + struct.pack("<H", key_nonce & 65535) + b"\x00\x01" + encrypted[-1:] + bytes(payload)
    return base64.b64encode(result).decode("ascii")


def helios_v5(seconds: int, license_id: int, aid: str) -> str:
    return ladon_encrypt(seconds, license_id, int(aid), random_bytes=secrets.token_bytes(4))
