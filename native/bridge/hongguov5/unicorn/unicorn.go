// Package unicorn 是 libunicorn（ARM64 模拟）的最小 cgo 绑定，只覆盖 v5 摘要
// 核心需要的 API 面：内存映射/读写、寄存器、emu_start/stop 与四类 hook。
// 回调桥：hook_add 的 user_data 指向 C 堆上的 8 字节槽位（存 hook id），
// C trampoline 读出 id 调 //export 的 Go 函数按 id 分发——C 侧只持有 C 内存，
// 遵守 cgo 指针规则。静态库路径见 unicorn_link_*.go（平台 build tag 选择）。
package unicorn

/*
#include "unicorn_bridge.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"sync"
	"unsafe"
)

var (
	ErrUnicorn = errors.New("unicorn")
	regMu      sync.Mutex
	engines    = map[uintptr]*Engine{}
)

// CodeHook 代码执行回调（要停机调用 Engine.EmuStop）。
type CodeHook func(e *Engine, address uint64, size uint32)

// MemReadHook 内存读回调（统计预算；超限调 EmuStop）。
type MemReadHook func(e *Engine, address uint64, size int32)

// MemInvalidHook 返回 false 终止模拟（对齐 python hook 返回 False）。
type MemInvalidHook func(e *Engine, address uint64) bool

// IntrHook 中断/系统调用回调。
type IntrHook func(e *Engine, intno uint32)

type Engine struct {
	uc      *C.uc_engine
	code    map[uint64]CodeHook
	memRead map[uint64]MemReadHook
	invalid MemInvalidHook
	intr    IntrHook
	hooks   []C.uc_hook
	slots   []unsafe.Pointer
	nextID  uint64
}

// Open 打开 ARM64 模拟器（恒定架构，与宿主无关）。
func Open() (*Engine, error) {
	var uc *C.uc_engine
	if err := C.uc_open(C.uc_arch(C.UC_ARCH_ARM64), C.uc_mode(C.UC_MODE_ARM), &uc); err != 0 {
		return nil, fmt.Errorf("%w: open %d", ErrUnicorn, int(err))
	}
	e := &Engine{
		uc:      uc,
		code:    map[uint64]CodeHook{},
		memRead: map[uint64]MemReadHook{},
	}
	regMu.Lock()
	engines[uintptr(unsafe.Pointer(uc))] = e
	regMu.Unlock()
	return e, nil
}

func (e *Engine) Close() error {
	if e.uc == nil {
		return nil
	}
	regMu.Lock()
	delete(engines, uintptr(unsafe.Pointer(e.uc)))
	regMu.Unlock()
	uc := e.uc
	e.uc = nil
	for _, slot := range e.slots {
		C.aquan_free_slot(slot)
	}
	e.slots = nil
	if err := C.uc_close(uc); err != 0 {
		return fmt.Errorf("%w: close %d", ErrUnicorn, int(err))
	}
	return nil
}

func (e *Engine) MemMap(addr, size uint64) error {
	if err := C.aquan_mem_map(e.uc, C.uint64_t(addr), C.uint64_t(size), C.uint32_t(C.UC_PROT_ALL)); err != 0 {
		return fmt.Errorf("%w: mem_map %#x %d (%d)", ErrUnicorn, addr, size, int(err))
	}
	return nil
}

func (e *Engine) MemWrite(addr uint64, data []byte) error {
	if len(data) == 0 {
		return nil
	}
	if err := C.uc_mem_write(e.uc, C.uint64_t(addr), unsafe.Pointer(&data[0]), C.uint64_t(len(data))); err != 0 {
		return fmt.Errorf("%w: mem_write %#x %d (%d)", ErrUnicorn, addr, len(data), int(err))
	}
	return nil
}

func (e *Engine) MemRead(addr uint64, size int) ([]byte, error) {
	out := make([]byte, size)
	if size == 0 {
		return out, nil
	}
	if err := C.uc_mem_read(e.uc, C.uint64_t(addr), unsafe.Pointer(&out[0]), C.uint64_t(size)); err != 0 {
		return nil, fmt.Errorf("%w: mem_read %#x %d (%d)", ErrUnicorn, addr, size, int(err))
	}
	return out, nil
}

// 寄存器/常量（cgo 直引头文件枚举）。
const (
	RegX0        = int(C.UC_ARM64_REG_X0)
	RegX1        = int(C.UC_ARM64_REG_X1)
	RegX2        = int(C.UC_ARM64_REG_X2)
	RegX3        = int(C.UC_ARM64_REG_X3)
	RegX8        = int(C.UC_ARM64_REG_X8)
	RegX28       = int(C.UC_ARM64_REG_X28)
	RegSP        = int(C.UC_ARM64_REG_SP)
	RegLR        = int(C.UC_ARM64_REG_LR)
	RegPC        = int(C.UC_ARM64_REG_PC)
	RegTPIDREL0  = int(C.UC_ARM64_REG_TPIDR_EL0)
	HookCode     = int(C.UC_HOOK_CODE)
	HookMemRead  = int(C.UC_HOOK_MEM_READ)
	HookMemInval = int(C.UC_HOOK_MEM_INVALID)
	HookIntr     = int(C.UC_HOOK_INTR)
)

func (e *Engine) RegWrite(reg int, value uint64) error {
	if err := C.uc_reg_write(e.uc, C.int(reg), unsafe.Pointer(&value)); err != 0 {
		return fmt.Errorf("%w: reg_write %d (%d)", ErrUnicorn, reg, int(err))
	}
	return nil
}

func (e *Engine) RegRead(reg int) (uint64, error) {
	var value C.uint64_t
	if err := C.uc_reg_read(e.uc, C.int(reg), unsafe.Pointer(&value)); err != 0 {
		return 0, fmt.Errorf("%w: reg_read %d (%d)", ErrUnicorn, reg, int(err))
	}
	return uint64(value), nil
}

// EmuStart 对齐 python：timeout 微秒、count 指令数（0 = 不限）。
func (e *Engine) EmuStart(begin, until, timeout, count uint64) error {
	if err := C.uc_emu_start(e.uc, C.uint64_t(begin), C.uint64_t(until),
		C.uint64_t(timeout), C.size_t(count)); err != 0 {
		msg := C.GoString(C.uc_strerror(err))
		return fmt.Errorf("%w: emu %s", ErrUnicorn, msg)
	}
	return nil
}

func (e *Engine) EmuStop() error {
	if err := C.uc_emu_stop(e.uc); err != 0 {
		return fmt.Errorf("%w: emu_stop %d", ErrUnicorn, int(err))
	}
	return nil
}

func (e *Engine) newSlot() unsafe.Pointer {
	e.nextID++
	slot := C.aquan_alloc_slot(C.ulonglong(e.nextID))
	e.slots = append(e.slots, slot)
	return slot
}

func (e *Engine) HookCode(begin, end uint64, fn CodeHook) error {
	slot := e.newSlot()
	e.code[e.nextID] = fn
	var hook C.uc_hook
	if err := C.aquan_hook_add_code(e.uc, &hook, slot,
		C.uint64_t(begin), C.uint64_t(end)); err != 0 {
		delete(e.code, e.nextID)
		return fmt.Errorf("%w: hook_code %d", ErrUnicorn, int(err))
	}
	e.hooks = append(e.hooks, hook)
	return nil
}

func (e *Engine) HookMemRead(begin, end uint64, fn MemReadHook) error {
	slot := e.newSlot()
	e.memRead[e.nextID] = fn
	var hook C.uc_hook
	if err := C.aquan_hook_add_memread(e.uc, &hook, slot,
		C.uint64_t(begin), C.uint64_t(end)); err != 0 {
		delete(e.memRead, e.nextID)
		return fmt.Errorf("%w: hook_mem_read %d", ErrUnicorn, int(err))
	}
	e.hooks = append(e.hooks, hook)
	return nil
}

func (e *Engine) HookMemInvalid(fn MemInvalidHook) error {
	slot := e.newSlot()
	e.invalid = fn
	var hook C.uc_hook
	if err := C.aquan_hook_add_mem_invalid(e.uc, &hook, slot); err != 0 {
		return fmt.Errorf("%w: hook_mem_invalid %d", ErrUnicorn, int(err))
	}
	e.hooks = append(e.hooks, hook)
	return nil
}

func (e *Engine) HookIntr(fn IntrHook) error {
	slot := e.newSlot()
	e.intr = fn
	var hook C.uc_hook
	if err := C.aquan_hook_add_intr(e.uc, &hook, slot); err != 0 {
		return fmt.Errorf("%w: hook_intr %d", ErrUnicorn, int(err))
	}
	e.hooks = append(e.hooks, hook)
	return nil
}

func engineOf(ptr uint64) *Engine {
	regMu.Lock()
	defer regMu.Unlock()
	return engines[uintptr(ptr)]
}

// ---- C → Go 回调入口 ----

//export goAquanCodeHook
func goAquanCodeHook(handle C.ulonglong, uc C.ulonglong,
	address C.uint64_t, size C.uint32_t) {
	engine := engineOf(uint64(uc))
	if engine == nil {
		return
	}
	if fn, ok := engine.code[uint64(handle)]; ok {
		fn(engine, uint64(address), uint32(size))
	}
}

//export goAquanMemReadHook
func goAquanMemReadHook(handle C.ulonglong, uc C.ulonglong,
	address C.uint64_t, size C.int) {
	engine := engineOf(uint64(uc))
	if engine == nil {
		return
	}
	if fn, ok := engine.memRead[uint64(handle)]; ok {
		fn(engine, uint64(address), int32(size))
	}
}

//export goAquanMemInvalidHook
func goAquanMemInvalidHook(handle C.ulonglong, uc C.ulonglong,
	address C.uint64_t) C.int {
	engine := engineOf(uint64(uc))
	if engine == nil || engine.invalid == nil {
		return 0
	}
	if engine.invalid(engine, uint64(address)) {
		return 1
	}
	return 0
}

//export goAquanIntrHook
func goAquanIntrHook(handle C.ulonglong, uc C.ulonglong,
	intno C.uint) {
	engine := engineOf(uint64(uc))
	if engine == nil || engine.intr == nil {
		return
	}
	engine.intr(engine, uint32(intno))
}
