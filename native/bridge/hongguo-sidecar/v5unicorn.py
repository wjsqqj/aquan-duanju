# -*- coding: utf-8 -*-
"""ARM64 SDK 摘要核心模拟器（自有实现）：加载哈希锁定的官方 libmetasec_ml.so，
建模导入函数/JNI 缺席/单线程环境，在 digest 边界停机取 20 字节摘要。
依赖：pip unicorn。所有偏移与镜像哈希绑定（互操作事实）。"""
import hashlib
import struct
import time

import unicorn as uc
from unicorn.arm64_const import (
    UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3,
    UC_ARM64_REG_X8, UC_ARM64_REG_X28, UC_ARM64_REG_SP, UC_ARM64_REG_LR,
    UC_ARM64_REG_PC, UC_ARM64_REG_TPIDR_EL0,
)

EXPECTED = "c6831ab265a0cb76dacfa3b7041e9ea0f706490106a74e12f39058671cc14fe3"

BASE, HEAP, STACK, IMPORT, STOP = 0x1000000, 0x2000000, 0x3000000, 0x4000000, 0x5000000
MASK64 = (1 << 64) - 1


class SdkDigestCore:
    def __init__(self, image: bytes):
        if not isinstance(image, bytes) or len(image) != 4501136 or \
                hashlib.sha256(image).hexdigest() != EXPECTED:
            raise ValueError("unsupported-sdk-image")
        self.u = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
        self.u.mem_map(0, 0x1000, uc.UC_PROT_READ)
        self.env_reads = 0
        self.u.hook_add(uc.UC_HOOK_MEM_READ, self._env_read, begin=0, end=0xFFF)
        self.u.mem_map(BASE, 0x500000)
        self.u.mem_map(HEAP, 0x800000)
        self.u.mem_map(STACK, 0x200000)
        self.u.mem_map(IMPORT, 0x10000)
        self.u.mem_map(STOP, 0x1000)
        self.heap = HEAP
        self.allocations = {}
        self.calls = {}
        self.mutex_depth = {}
        self.once_done = set()
        self.once_pending = []
        self.thread_keys = {}
        self.errno_address = self.alloc(4)
        self.imports = {}

        phoff = struct.unpack_from("<Q", image, 32)[0]
        stride, count = struct.unpack_from("<HH", image, 54)
        for index in range(count):
            kind, _, offset, address, _, size, _, _ = struct.unpack_from(
                "<IIQQQQQQ", image, phoff + index * stride)
            if kind == 1:
                self.u.mem_write(BASE + address, image[offset:offset + size])
        shoff = struct.unpack_from("<Q", image, 40)[0]
        stride, count, string_index = struct.unpack_from("<HHH", image, 58)
        sections = [struct.unpack_from("<IIQQQQIIQQ", image, shoff + i * stride) for i in range(count)]
        table = sections[string_index]
        names = image[table[4]:table[4] + table[5]]

        def text(buf, start):
            return buf[start:buf.index(b"\0", start)].decode()

        by_name = {text(names, item[0]): item for item in sections}
        syms = by_name[".dynsym"]
        strings = sections[syms[6]]
        strings = image[strings[4]:strings[4] + strings[5]]
        symbols = [struct.unpack_from("<IBBHQQ", image, syms[4] + i) for i in range(0, syms[5], syms[9])]
        for name in (".rela.dyn", ".rela.plt"):
            section = by_name[name]
            for pos in range(section[4], section[4] + section[5], 24):
                address, info, addend = struct.unpack_from("<QQq", image, pos)
                symbol, kind = info >> 32, info & 0xFFFFFFFF
                if kind == 1027:
                    value = BASE + addend
                elif kind in (1025, 1026, 257):
                    entry = symbols[symbol]
                    if entry[3]:
                        value = BASE + entry[4] + addend
                    else:
                        value = IMPORT + symbol * 128
                        self.imports[value] = text(strings, entry[0])
                else:
                    raise RuntimeError(f"unsupported-relocation-{kind}")
                self.u.mem_write(BASE + address, struct.pack("<Q", value))
        # JavaVM 缺席建模：GetEnv 槽指向导入垫片，写入全局 VM 槽。
        vm_table = self.alloc(64)
        self.u.mem_write(vm_table + 0x20, struct.pack("<Q", IMPORT + 0xF100))
        self.u.mem_write(vm_table + 0x30, struct.pack("<Q", IMPORT + 0xF110))
        vm_object = self.alloc(struct.pack("<Q", vm_table))
        vm_global = struct.unpack("<Q", self.read(BASE + 0x3E8368, 8))[0]
        self.u.mem_write(vm_global, struct.pack("<Q", vm_object))
        self.u.reg_write(UC_ARM64_REG_TPIDR_EL0, STACK)
        self.u.hook_add(uc.UC_HOOK_CODE, self._hook, begin=IMPORT, end=IMPORT + 0xFFFF)
        self.u.hook_add(uc.UC_HOOK_CODE, self._boundary,
                        begin=BASE + 0x17DC48, end=BASE + 0x17DC48)
        self.u.hook_add(uc.UC_HOOK_MEM_INVALID, self._invalid_memory)
        self.u.hook_add(uc.UC_HOOK_INTR, self._interrupt)

    def _env_read(self, u, access, address, size, value, data):
        self.env_reads += 1
        if self.env_reads > 64:
            raise RuntimeError("env-read-budget")

    def _boundary(self, u, address, size, data):
        slot = u.reg_read(UC_ARM64_REG_X28)
        instruction = struct.unpack("<Q", self.read(slot, 8))[0]
        if instruction == BASE + 0xECC40:
            self.core_returned = True
            u.emu_stop()

    def _interrupt(self, u, number, data):
        call = u.reg_read(UC_ARM64_REG_X8)
        if number != 2:
            raise RuntimeError("unsupported-interrupt")
        if call == 57:  # close
            u.reg_write(UC_ARM64_REG_X0, 0xFFFFFFFFFFFFFFF7 & MASK64)
            return
        if call != 56:  # openat
            raise RuntimeError(f"unsupported-syscall-{call}")
        pointer = u.reg_read(UC_ARM64_REG_X1)
        path = bytearray()
        for _ in range(256):
            byte = self.read(pointer + len(path), 1)
            if byte == b"\0":
                break
            path.extend(byte)
        else:
            raise RuntimeError("unbounded-sdk-path")
        u.reg_write(UC_ARM64_REG_X0, 0xFFFFFFFFFFFFFFFE & MASK64)  # ENOENT

    def _invalid_memory(self, u, access, address, size, value, data):
        self.missing = {"address": hex(address), "pc": hex(u.reg_read(UC_ARM64_REG_PC) - BASE)}
        return False

    def alloc(self, value):
        if isinstance(value, int):
            value = bytes(value)
        address = self.heap
        self.heap += (len(value) + 31) // 16 * 16
        self.allocations[address] = len(value)
        self.u.mem_write(address, value)
        return address

    def read(self, address, count) -> bytes:
        return bytes(self.u.mem_read(address, count))

    def _hook(self, u, address, size, data):
        if address in (IMPORT + 0xF100, IMPORT + 0xF110):
            self.calls["JNI_environment_unavailable"] = self.calls.get("JNI_environment_unavailable", 0) + 1
            u.mem_write(u.reg_read(UC_ARM64_REG_X1), bytes(8))
            u.reg_write(UC_ARM64_REG_X0, 0xFFFFFFFF)  # JNI_ERR
            u.reg_write(UC_ARM64_REG_PC, u.reg_read(UC_ARM64_REG_LR))
            return
        if address == IMPORT + 0xF000:
            control, previous_lr = self.once_pending.pop()
            self.once_done.add(control)
            u.mem_write(control, struct.pack("<I", 2))
            u.reg_write(UC_ARM64_REG_X0, 0)
            u.reg_write(UC_ARM64_REG_LR, previous_lr)
            u.reg_write(UC_ARM64_REG_PC, previous_lr)
            return
        name = self.imports.get(address)
        if not name:
            return
        self.calls[name] = self.calls.get(name, 0) + 1
        a, b, c, d = (u.reg_read(r) for r in (UC_ARM64_REG_X0, UC_ARM64_REG_X1,
                                              UC_ARM64_REG_X2, UC_ARM64_REG_X3))
        if name in ("malloc", "calloc"):
            value = self.alloc(a if name == "malloc" else a * b)
        elif name == "free":
            value = 0
        elif name == "realloc":
            value = self.alloc(b)
            if a:
                self.u.mem_write(value, self.read(a, min(b, self.allocations[a])))
        elif name in ("memcpy", "memmove", "__memcpy_chk", "__memmove_chk"):
            if name.endswith("_chk"):
                assert c <= d
            self.u.mem_write(a, self.read(b, c))
            value = a
        elif name in ("memset", "__memset_chk"):
            assert c <= 2 * 1024 * 1024
            if name.endswith("_chk"):
                assert c <= d
            self.u.mem_write(a, bytes([b & 255]) * c)
            value = a
        elif name == "memcmp":
            left, right = self.read(a, c), self.read(b, c)
            value = (left > right) - (left < right)
        elif name in ("strlen", "__strlen_chk"):
            value = 0
            while self.read(a + value, 1) != b"\0":
                value += 1
                assert value <= 65536
        elif name in ("pthread_mutex_lock", "pthread_mutex_unlock"):
            self.read(a, 4)
            depth = self.mutex_depth.get(a, 0)
            if name.endswith("_unlock"):
                assert depth > 0
                depth -= 1
            else:
                depth += 1
            self.mutex_depth[a] = depth
            value = 0
        elif name == "pthread_cond_broadcast":
            self.read(a, 4)
            value = 0
        elif name == "pthread_once":
            self.read(a, 4)
            if a not in self.once_done:
                assert BASE <= b < BASE + 0x500000
                assert all(control != a for control, _ in self.once_pending)
                self.once_pending.append((a, u.reg_read(UC_ARM64_REG_LR)))
                u.reg_write(UC_ARM64_REG_LR, IMPORT + 0xF000)
                u.reg_write(UC_ARM64_REG_PC, b)
                return
            value = 0
        elif name == "pthread_key_create":
            key = len(self.thread_keys) + 1
            self.thread_keys[key] = 0
            u.mem_write(a, struct.pack("<I", key))
            value = 0
        elif name == "pthread_setspecific":
            self.thread_keys[a] = b
            value = 0
        elif name == "pthread_getspecific":
            value = self.thread_keys.get(a, 0)
        elif name in ("gettid", "getpid"):
            value = 1
        elif name == "syscall" and a in (172, 178):
            value = 1
        elif name == "clock_gettime":
            u.mem_write(b, struct.pack("<qq", 1700000000 if a == 0 else 1, 0))
            value = 0
        elif name in ("__system_property_find", "getenv"):
            value = 0
        elif name == "__errno":
            value = self.errno_address
        elif name == "__cxa_thread_atexit_impl":
            value = 0
        else:
            raise RuntimeError(f"import-unavailable-{name}")
        u.reg_write(UC_ARM64_REG_X0, value & MASK64)
        u.reg_write(UC_ARM64_REG_PC, u.reg_read(UC_ARM64_REG_LR))

    def digest(self, payload: bytes, selector: int, seconds: int):
        assert len(payload) == 52 and 0 <= selector < 16 and 0 <= seconds <= 0xFFFFFFFF
        pointer = self.alloc(payload + b"\0")
        # SDK 自有字节串：vtable、u32 capacity、u32 length、data 指针
        argument = self.alloc(struct.pack("<QIIQ", BASE + 0x3C8288,
                                          len(payload) + 1, len(payload), pointer))
        result = self.alloc(24)
        self.core_returned = False
        self.u.reg_write(UC_ARM64_REG_SP, STACK + 0x1F0000)
        self.u.reg_write(UC_ARM64_REG_X0, argument)
        self.u.reg_write(UC_ARM64_REG_X1, selector)
        self.u.reg_write(UC_ARM64_REG_X2, seconds)
        self.u.reg_write(UC_ARM64_REG_X8, result)
        self.u.reg_write(UC_ARM64_REG_LR, STOP)
        started = time.monotonic()
        self.u.emu_start(BASE + 0x2AAC34, STOP, timeout=20_000_000, count=100_000_000)
        if not (self.core_returned or self.u.reg_read(UC_ARM64_REG_PC) == STOP):
            raise RuntimeError("digest-budget-reached")
        raw = self.read(result, 24)
        _, capacity, length, pointer = struct.unpack("<QIIQ", raw)
        if length != 20 or capacity < length:
            raise RuntimeError(f"unexpected-digest-length-{length}")
        return self.read(pointer, length), time.monotonic() - started
