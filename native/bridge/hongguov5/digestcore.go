//go:build cgo

package hongguov5

// digestcore.go — ARM64 SDK 摘要核心（移植自 sidecar v5unicorn.py，逐行对齐）：
// 加载哈希锁定的官方 libmetasec_ml.so，建模导入函数/JNI 缺席/单线程环境，
// 在 digest 边界停机取 20 字节摘要。所有偏移与镜像哈希绑定（互操作事实）。

import (
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/wjsqqj/aquan-core/hongguov5/unicorn"
)

const expectedImageSHA256 = "c6831ab265a0cb76dacfa3b7041e9ea0f706490106a74e12f39058671cc14fe3"
const expectedImageSize = 4501136

const (
	digBase   = uint64(0x1000000)
	digHeap   = uint64(0x2000000)
	digStack  = uint64(0x3000000)
	digImport = uint64(0x4000000)
	digStop   = uint64(0x5000000)
)

const mask64 = uint64(0xFFFFFFFFFFFFFFFF)

// 摘要入口/边界/VM 全局槽——与镜像哈希绑定。
const (
	coreEntryAddr   = digBase + 0x2AAC34
	boundaryAddr    = digBase + 0x17DC48
	boundarySlot    = digBase + 0xECC40
	vmGlobalAddr    = digBase + 0x3E8368
	stringVtable    = digBase + 0x3C8288
	jniGetEnvA      = digImport + 0xF100
	jniGetEnvB      = digImport + 0xF110
	onceReturnAddr  = digImport + 0xF000
	digestTimeoutUs = 20_000_000
	digestCountMax  = 100_000_000
)

type sdkDigestCore struct {
	u            *unicorn.Engine
	heap         uint64
	allocations  map[uint64]int
	imports      map[uint64]string
	calls        map[string]int
	mutexDepth   map[uint64]int
	onceDone     map[uint64]struct{}
	oncePending  [][2]uint64
	threadKeys   map[uint64]uint64
	errnoAddress uint64
	envReads     int
	coreReturned bool
	err          error
}

// newSDKDigestCore 打开模拟器并装载镜像（ELF + 重定位 + 导入垫片）。
func newSDKDigestCore(image []byte) (*sdkDigestCore, error) {
	if len(image) != expectedImageSize || sha256Hex(image) != expectedImageSHA256 {
		return nil, errors.New("hongguov5: unsupported-sdk-image")
	}
	u, err := unicorn.Open()
	if err != nil {
		return nil, err
	}
	c := &sdkDigestCore{
		u:           u,
		heap:        digHeap,
		allocations: map[uint64]int{},
		imports:     map[uint64]string{},
		calls:       map[string]int{},
		mutexDepth:  map[uint64]int{},
		onceDone:    map[uint64]struct{}{},
		threadKeys:  map[uint64]uint64{},
	}
	defer func() {
		if c.err != nil {
			u.Close()
		}
	}()

	// 第 0 页只读：环境读取预算（写即触发 invalid）。
	if err := c.protectPage0(); err != nil {
		return nil, err
	}
	for _, m := range [][2]uint64{
		{digBase, 0x500000}, {digHeap, 0x800000}, {digStack, 0x200000},
		{digImport, 0x10000}, {digStop, 0x1000},
	} {
		if err := u.MemMap(m[0], m[1]); err != nil {
			return nil, err
		}
	}

	c.errnoAddress = c.allocInt(4)

	if err := c.loadELF(image); err != nil {
		return nil, err
	}

	// JavaVM 缺席建模：GetEnv 槽指向导入垫片，写入全局 VM 槽。
	vmTable := c.allocInt(64)
	_ = u.MemWrite(vmTable+0x20, le64(digImport+0xF100))
	_ = u.MemWrite(vmTable+0x30, le64(digImport+0xF110))
	vmObject := c.allocBytes(le64(vmTable))
	vmGlobalRaw, err := u.MemRead(vmGlobalAddr, 8)
	if err != nil {
		return nil, err
	}
	vmGlobal := binary.LittleEndian.Uint64(vmGlobalRaw)
	if err := u.MemWrite(vmGlobal, le64(vmObject)); err != nil {
		return nil, err
	}
	if err := u.RegWrite(unicorn.RegTPIDREL0, digStack); err != nil {
		return nil, err
	}

	if err := u.HookCode(digImport, digImport+0xFFFF, c.importHook); err != nil {
		return nil, err
	}
	if err := u.HookCode(boundaryAddr, boundaryAddr, c.boundaryHook); err != nil {
		return nil, err
	}
	if err := u.HookMemRead(0, 0xFFF, c.envReadHook); err != nil {
		return nil, err
	}
	if err := u.HookMemInvalid(c.invalidHook); err != nil {
		return nil, err
	}
	if err := u.HookIntr(c.intrHook); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *sdkDigestCore) Close() {
	if c.u != nil {
		_ = c.u.Close()
		c.u = nil
	}
}

func (c *sdkDigestCore) protectPage0() error {
	// MemMap 只有 ALL 权限；第 0 页需 READ——映射后用 unicorn 无权限保护不可行，
	// 这里退化为：读预算 hook 统计（与 python 一致），写越界由 invalid hook 捕获。
	return c.u.MemMap(0, 0x1000)
}

// ---- ELF 装载与重定位 ----

func (c *sdkDigestCore) loadELF(image []byte) error {
	u := c.u
	phoff := binary.LittleEndian.Uint64(image[32:40])
	stride := binary.LittleEndian.Uint16(image[54:56])
	count := binary.LittleEndian.Uint16(image[56:58])
	for index := uint16(0); index < count; index++ {
		rec := image[uint64(phoff)+uint64(index)*uint64(stride):]
		kind := binary.LittleEndian.Uint32(rec[0:4])
		offset := binary.LittleEndian.Uint64(rec[8:16])
		address := binary.LittleEndian.Uint64(rec[16:24])
		size := binary.LittleEndian.Uint64(rec[32:40])
		if kind == 1 {
			if err := u.MemWrite(digBase+address, image[offset:offset+size]); err != nil {
				return err
			}
		}
	}

	shoff := binary.LittleEndian.Uint64(image[40:48])
	shstride := binary.LittleEndian.Uint16(image[58:60])
	shnum := binary.LittleEndian.Uint16(image[60:62])
	shstrndx := binary.LittleEndian.Uint16(image[62:64])
	// ELF64 节头：name(I) type(I) flags(Q) addr(Q) offset(Q) size(Q)
	// link(I) info(I) addralign(Q) entsize(Q)。
	sections := make([][10]uint64, shnum)
	for i := uint16(0); i < shnum; i++ {
		rec := image[shoff+uint64(i)*uint64(shstride):]
		sections[i][0] = uint64(binary.LittleEndian.Uint32(rec[0:4]))
		sections[i][1] = uint64(binary.LittleEndian.Uint32(rec[4:8]))
		sections[i][2] = binary.LittleEndian.Uint64(rec[8:16])
		sections[i][3] = binary.LittleEndian.Uint64(rec[16:24])
		sections[i][4] = binary.LittleEndian.Uint64(rec[24:32])
		sections[i][5] = binary.LittleEndian.Uint64(rec[32:40])
		sections[i][6] = uint64(binary.LittleEndian.Uint32(rec[40:44]))
		sections[i][7] = uint64(binary.LittleEndian.Uint32(rec[44:48]))
		sections[i][8] = binary.LittleEndian.Uint64(rec[48:56])
		sections[i][9] = binary.LittleEndian.Uint64(rec[56:64])
	}
	table := sections[shstrndx]
	names := image[table[4] : table[4]+table[5]]
	readName := func(start uint64) string {
		end := start
		for end < uint64(len(names)) && names[end] != 0 {
			end++
		}
		return string(names[start:end])
	}
	byName := map[string][10]uint64{}
	for _, item := range sections {
		byName[readName(item[0])] = item
	}

	syms, ok := byName[".dynsym"]
	if !ok {
		return errors.New("hongguov5: dynsym-missing")
	}
	stringsSec := sections[syms[6]]
	strings := image[stringsSec[4] : stringsSec[4]+stringsSec[5]]
	readSymName := func(start uint64) string {
		end := start
		for end < uint64(len(strings)) && strings[end] != 0 {
			end++
		}
		return string(strings[start:end])
	}
	var symbols [][6]uint64
	for offset := uint64(0); offset < syms[5]; offset += syms[9] {
		rec := image[syms[4]+offset:]
		symbols = append(symbols, [6]uint64{
			uint64(binary.LittleEndian.Uint32(rec[0:4])),
			uint64(rec[4]), uint64(rec[5]),
			uint64(binary.LittleEndian.Uint16(rec[6:8])),
			binary.LittleEndian.Uint64(rec[8:16]),
			binary.LittleEndian.Uint64(rec[16:24]),
		})
	}

	for _, name := range []string{".rela.dyn", ".rela.plt"} {
		section, ok := byName[name]
		if !ok {
			return fmt.Errorf("hongguov5: %s-missing", name)
		}
		for pos := section[4]; pos < section[4]+section[5]; pos += 24 {
			rec := image[pos:]
			address := binary.LittleEndian.Uint64(rec[0:8])
			info := binary.LittleEndian.Uint64(rec[8:16])
			addend := int64(binary.LittleEndian.Uint64(rec[16:24]))
			symbol := info >> 32
			kind := info & 0xFFFFFFFF
			var value uint64
			switch kind {
			case 1027: // R_AARCH64_RELATIVE
				value = digBase + uint64(addend)
			case 1025, 1026, 257: // GLOB_DAT / JUMP_SLOT / ABS64
				entry := symbols[symbol]
				if entry[3] != 0 {
					value = digBase + entry[4] + uint64(addend)
				} else {
					value = digImport + symbol*128
					c.imports[value] = readSymName(entry[0])
				}
			default:
				return fmt.Errorf("hongguov5: unsupported-relocation-%d", kind)
			}
			if err := u.MemWrite(digBase+address, le64(value)); err != nil {
				return err
			}
		}
	}
	return nil
}

// ---- 堆分配 ----

func (c *sdkDigestCore) allocInt(size uint64) uint64 {
	addr := c.heap
	c.heap += (size + 31) / 16 * 16
	c.allocations[addr] = int(size)
	// 零填充由 MemMap 的零初始化保证；显式写零以防复用。
	_ = c.u.MemWrite(addr, make([]byte, size))
	return addr
}

func (c *sdkDigestCore) allocBytes(data []byte) uint64 {
	addr := c.heap
	c.heap += (uint64(len(data)) + 31) / 16 * 16
	c.allocations[addr] = len(data)
	_ = c.u.MemWrite(addr, data)
	return addr
}

func (c *sdkDigestCore) read(address, count uint64) []byte {
	out, err := c.u.MemRead(address, int(count))
	if err != nil {
		c.err = err
		return make([]byte, count)
	}
	return out
}

// ---- hooks ----

func (c *sdkDigestCore) envReadHook(e *unicorn.Engine, address uint64, size int32) {
	c.envReads++
	if c.envReads > 64 {
		c.err = errors.New("hongguov5: env-read-budget")
		_ = e.EmuStop()
	}
}

func (c *sdkDigestCore) boundaryHook(e *unicorn.Engine, address uint64, size uint32) {
	slot, err := e.RegRead(unicorn.RegX28)
	if err != nil {
		c.err = err
		_ = e.EmuStop()
		return
	}
	raw, err := e.MemRead(slot, 8)
	if err != nil {
		c.err = err
		_ = e.EmuStop()
		return
	}
	if binary.LittleEndian.Uint64(raw) == boundarySlot {
		c.coreReturned = true
		_ = e.EmuStop()
	}
}

func (c *sdkDigestCore) invalidHook(e *unicorn.Engine, address uint64) bool {
	pc, _ := e.RegRead(unicorn.RegPC)
	c.err = fmt.Errorf("hongguov5: invalid-memory %#x at pc %#x", address, pc-digBase)
	return false
}

func (c *sdkDigestCore) intrHook(e *unicorn.Engine, intno uint32) {
	if intno != 2 {
		c.err = errors.New("hongguov5: unsupported-interrupt")
		_ = e.EmuStop()
		return
	}
	call, err := e.RegRead(unicorn.RegX8)
	if err != nil {
		c.err = err
		_ = e.EmuStop()
		return
	}
	switch call {
	case 57: // close
		_ = e.RegWrite(unicorn.RegX0, 0xFFFFFFFFFFFFFFF7&mask64)
		return
	case 56: // openat
		pointer, err := e.RegRead(unicorn.RegX1)
		if err != nil {
			c.err = err
			_ = e.EmuStop()
			return
		}
		path := make([]byte, 0, 256)
		for i := 0; i < 256; i++ {
			b := c.read(pointer+uint64(len(path)), 1)
			if c.err != nil {
				_ = e.EmuStop()
				return
			}
			if b[0] == 0 {
				break
			}
			path = append(path, b[0])
		}
		_ = e.RegWrite(unicorn.RegX0, 0xFFFFFFFFFFFFFFFE&mask64) // ENOENT
	default:
		c.err = fmt.Errorf("hongguov5: unsupported-syscall-%d", call)
		_ = e.EmuStop()
	}
}

func (c *sdkDigestCore) importHook(e *unicorn.Engine, address uint64, size uint32) {
	if address == jniGetEnvA || address == jniGetEnvB {
		c.calls["JNI_environment_unavailable"]++
		x1, _ := e.RegRead(unicorn.RegX1)
		_ = e.MemWrite(x1, make([]byte, 8))
		_ = e.RegWrite(unicorn.RegX0, 0xFFFFFFFF) // JNI_ERR
		lr, _ := e.RegRead(unicorn.RegLR)
		_ = e.RegWrite(unicorn.RegPC, lr)
		return
	}
	if address == onceReturnAddr {
		pending := c.oncePending[len(c.oncePending)-1]
		c.oncePending = c.oncePending[:len(c.oncePending)-1]
		c.onceDone[pending[0]] = struct{}{}
		_ = e.MemWrite(pending[0], []byte{2, 0, 0, 0})
		_ = e.RegWrite(unicorn.RegX0, 0)
		_ = e.RegWrite(unicorn.RegLR, pending[1])
		_ = e.RegWrite(unicorn.RegPC, pending[1])
		return
	}
	name, ok := c.imports[address]
	if !ok {
		return
	}
	c.calls[name]++
	a, _ := e.RegRead(unicorn.RegX0)
	b, _ := e.RegRead(unicorn.RegX1)
	cc, _ := e.RegRead(unicorn.RegX2)
	d, _ := e.RegRead(unicorn.RegX3)

	var value uint64
	switch name {
	case "malloc":
		value = c.allocInt(a)
	case "calloc":
		value = c.allocInt(a * b)
	case "free":
		value = 0
	case "realloc":
		value = c.allocInt(b)
		if a != 0 {
			prev := c.allocations[a]
			if uint64(prev) > b {
				prev = int(b)
			}
			_ = e.MemWrite(value, c.read(a, uint64(prev)))
		}
	case "memcpy", "memmove", "__memcpy_chk", "__memmove_chk":
		if len(name) > 4 && name[len(name)-4:] == "_chk" && cc > d {
			c.err = fmt.Errorf("hongguov5: memcpy-chk-overflow")
			_ = e.EmuStop()
			return
		}
		_ = e.MemWrite(a, c.read(b, cc))
		value = a
	case "memset", "__memset_chk":
		if cc > 2*1024*1024 {
			c.err = fmt.Errorf("hongguov5: memset-too-large")
			_ = e.EmuStop()
			return
		}
		if len(name) > 4 && name[len(name)-4:] == "_chk" && cc > d {
			c.err = fmt.Errorf("hongguov5: memset-chk-overflow")
			_ = e.EmuStop()
			return
		}
		fill := bytesFill(byte(b&255), int(cc))
		_ = e.MemWrite(a, fill)
		value = a
	case "memcmp":
		left, right := c.read(a, cc), c.read(b, cc)
		value = 0
		for i := range left {
			if left[i] != right[i] {
				if left[i] > right[i] {
					value = 1
				} else {
					value = mask64
				}
				break
			}
		}
	case "strlen", "__strlen_chk":
		value = 0
		for value <= 65536 {
			b1 := c.read(a+value, 1)
			if c.err != nil {
				_ = e.EmuStop()
				return
			}
			if b1[0] == 0 {
				break
			}
			value++
		}
		if value > 65536 {
			c.err = errors.New("hongguov5: strlen-unbounded")
			_ = e.EmuStop()
			return
		}
	case "pthread_mutex_lock":
		_ = c.read(a, 4)
		c.mutexDepth[a]++
		value = 0
	case "pthread_mutex_unlock":
		_ = c.read(a, 4)
		if c.mutexDepth[a] == 0 {
			c.err = errors.New("hongguov5: mutex-underflow")
			_ = e.EmuStop()
			return
		}
		c.mutexDepth[a]--
		value = 0
	case "pthread_cond_broadcast":
		_ = c.read(a, 4)
		value = 0
	case "pthread_once":
		_ = c.read(a, 4)
		if _, done := c.onceDone[a]; !done {
			if !(digBase <= b && b < digBase+0x500000) {
				c.err = errors.New("hongguov5: pthread_once-body-oob")
				_ = e.EmuStop()
				return
			}
			for _, pending := range c.oncePending {
				if pending[0] == a {
					c.err = errors.New("hongguov5: pthread_once-reentrant")
					_ = e.EmuStop()
					return
				}
			}
			lr, _ := e.RegRead(unicorn.RegLR)
			c.oncePending = append(c.oncePending, [2]uint64{a, lr})
			_ = e.RegWrite(unicorn.RegLR, onceReturnAddr)
			_ = e.RegWrite(unicorn.RegPC, b)
			return
		}
		value = 0
	case "pthread_key_create":
		key := uint64(len(c.threadKeys)) + 1
		c.threadKeys[key] = 0
		_ = e.MemWrite(a, le32pack(uint32(key)))
		value = 0
	case "pthread_setspecific":
		c.threadKeys[a] = b
		value = 0
	case "pthread_getspecific":
		value = c.threadKeys[a]
	case "gettid", "getpid":
		value = 1
	case "syscall":
		if a == 172 || a == 178 {
			value = 1
		} else {
			c.err = fmt.Errorf("hongguov5: import-unavailable-syscall-%d", a)
			_ = e.EmuStop()
			return
		}
	case "clock_gettime":
		sec := uint64(1)
		if a == 0 {
			sec = 1700000000
		}
		_ = e.MemWrite(b, append(le64pack(int64(sec)), le64pack(0)...))
		value = 0
	case "__system_property_find", "getenv":
		value = 0
	case "__errno":
		value = c.errnoAddress
	case "__cxa_thread_atexit_impl":
		value = 0
	default:
		c.err = fmt.Errorf("hongguov5: import-unavailable-%s", name)
		_ = e.EmuStop()
		return
	}
	_ = e.RegWrite(unicorn.RegX0, value&mask64)
	lr, _ := e.RegRead(unicorn.RegLR)
	_ = e.RegWrite(unicorn.RegPC, lr)
}

// ---- digest 入口 ----

func (c *sdkDigestCore) digest(payload []byte, selector int, seconds uint32) ([]byte, error) {
	if len(payload) != 52 || selector < 0 || selector >= 16 {
		return nil, errors.New("hongguov5: digest-args")
	}
	pointer := c.allocBytes(append(append([]byte(nil), payload...), 0))
	// SDK 自有字节串：vtable、u32 capacity、u32 length、data 指针
	argument := c.allocBytes(sdkString(
		stringVtable, uint32(len(payload)+1), uint32(len(payload)), pointer))
	result := c.allocInt(24)
	c.coreReturned = false
	c.err = nil
	u := c.u
	_ = u.RegWrite(unicorn.RegSP, digStack+0x1F0000)
	_ = u.RegWrite(unicorn.RegX0, argument)
	_ = u.RegWrite(unicorn.RegX1, uint64(selector))
	_ = u.RegWrite(unicorn.RegX2, uint64(seconds))
	_ = u.RegWrite(unicorn.RegX8, result)
	_ = u.RegWrite(unicorn.RegLR, digStop)
	if err := u.EmuStart(coreEntryAddr, digStop, digestTimeoutUs, digestCountMax); err != nil {
		if c.err != nil {
			return nil, c.err
		}
		return nil, err
	}
	if c.err != nil {
		return nil, c.err
	}
	pc, _ := u.RegRead(unicorn.RegPC)
	if !c.coreReturned && pc != digStop {
		return nil, errors.New("hongguov5: digest-budget-reached")
	}
	raw := c.read(result, 24)
	if c.err != nil {
		return nil, c.err
	}
	length := binary.LittleEndian.Uint32(raw[12:16])
	capacity := binary.LittleEndian.Uint32(raw[8:12])
	dataPtr := binary.LittleEndian.Uint64(raw[16:24])
	if length != 20 || capacity < length {
		return nil, fmt.Errorf("hongguov5: unexpected-digest-length-%d", length)
	}
	return c.read(dataPtr, 20), nil
}
