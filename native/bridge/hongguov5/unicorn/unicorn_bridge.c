#include "unicorn_bridge.h"

#include <stdlib.h>

/* //export 的 Go 函数（cgo 生成的原型在此前置声明）。 */
extern void goAquanCodeHook(unsigned long long handle, unsigned long long uc,
                            uint64_t address, uint32_t size);
extern void goAquanMemReadHook(unsigned long long handle, unsigned long long uc,
                               uint64_t address, int size);
extern int goAquanMemInvalidHook(unsigned long long handle, unsigned long long uc,
                                 uint64_t address);
extern void goAquanIntrHook(unsigned long long handle, unsigned long long uc,
                            unsigned int intno);

static void _aquan_code_trampoline(uc_engine *uc, uint64_t address, uint32_t size,
                                   void *user_data) {
    goAquanCodeHook(*(unsigned long long *)user_data,
                    (unsigned long long)(uintptr_t)uc, address, size);
}

static void _aquan_memread_trampoline(uc_engine *uc, uc_mem_type type,
                                      uint64_t address, int size, int64_t value,
                                      void *user_data) {
    (void)type;
    (void)value;
    goAquanMemReadHook(*(unsigned long long *)user_data,
                       (unsigned long long)(uintptr_t)uc, address, size);
}

static bool _aquan_mem_invalid_trampoline(uc_engine *uc, uc_mem_type type,
                                          uint64_t address, int size, int64_t value,
                                          void *user_data) {
    (void)type;
    (void)size;
    (void)value;
    return goAquanMemInvalidHook(*(unsigned long long *)user_data,
                                 (unsigned long long)(uintptr_t)uc,
                                 address) != 0;
}

static void _aquan_intr_trampoline(uc_engine *uc, uint32_t intno, void *user_data) {
    goAquanIntrHook(*(unsigned long long *)user_data,
                    (unsigned long long)(uintptr_t)uc, intno);
}

void *aquan_alloc_slot(unsigned long long id) {
    unsigned long long *slot = (unsigned long long *)malloc(sizeof(unsigned long long));
    if (slot == NULL) {
        return NULL;
    }
    *slot = id;
    return (void *)slot;
}

void aquan_free_slot(void *slot) { free(slot); }

uc_err aquan_hook_add_code(uc_engine *uc, uc_hook *hh, void *user_data,
                           uint64_t begin, uint64_t end) {
    return uc_hook_add(uc, hh, UC_HOOK_CODE, (void *)_aquan_code_trampoline,
                       user_data, begin, end);
}

uc_err aquan_hook_add_memread(uc_engine *uc, uc_hook *hh, void *user_data,
                              uint64_t begin, uint64_t end) {
    return uc_hook_add(uc, hh, UC_HOOK_MEM_READ, (void *)_aquan_memread_trampoline,
                       user_data, begin, end);
}

uc_err aquan_hook_add_mem_invalid(uc_engine *uc, uc_hook *hh, void *user_data) {
    return uc_hook_add(uc, hh, UC_HOOK_MEM_INVALID,
                       (void *)_aquan_mem_invalid_trampoline, user_data, 1, 0);
}

uc_err aquan_hook_add_intr(uc_engine *uc, uc_hook *hh, void *user_data) {
    return uc_hook_add(uc, hh, UC_HOOK_INTR, (void *)_aquan_intr_trampoline,
                       user_data, 1, 0);
}

uc_err aquan_hook_del(uc_engine *uc, uc_hook hh) { return uc_hook_del(uc, hh); }

uc_err aquan_mem_map(uc_engine *uc, uint64_t address, uint64_t size, uint32_t perms) {
    return uc_mem_map(uc, address, size, perms);
}
