#ifndef AQUAN_UNICORN_BRIDGE_H
#define AQUAN_UNICORN_BRIDGE_H

#include <stdint.h>
#include <unicorn/unicorn.h>

/* hook 槽位：C 堆上的 8 字节 hook id（cgo 指针规则要求 C 侧只持有 C 内存）。 */
void *aquan_alloc_slot(unsigned long long id);
void aquan_free_slot(void *slot);

/* 固定回调 + 类型的 uc_hook_add 包装（避免在 Go 侧构造 C 函数指针）。 */
uc_err aquan_hook_add_code(uc_engine *uc, uc_hook *hh, void *user_data,
                           uint64_t begin, uint64_t end);
uc_err aquan_hook_add_memread(uc_engine *uc, uc_hook *hh, void *user_data,
                              uint64_t begin, uint64_t end);
uc_err aquan_hook_add_mem_invalid(uc_engine *uc, uc_hook *hh, void *user_data);
uc_err aquan_hook_add_intr(uc_engine *uc, uc_hook *hh, void *user_data);
uc_err aquan_hook_del(uc_engine *uc, uc_hook hh);

/* 显式包装（诊断 cgo 直调 ABI 用）。 */
uc_err aquan_mem_map(uc_engine *uc, uint64_t address, uint64_t size, uint32_t perms);

#endif
