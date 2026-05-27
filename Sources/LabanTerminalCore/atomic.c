#include "LabanTerminalCore.h"

#include <assert.h>
#include <stdatomic.h>

uint64_t laban_atomic_load_u64_acquire(const void *slot) {
    assert(slot != NULL);
    const _Atomic uint64_t *atomic_slot = (const _Atomic uint64_t *)slot;
    return atomic_load_explicit(atomic_slot, memory_order_acquire);
}

void laban_atomic_store_u64_release(void *slot, uint64_t value) {
    assert(slot != NULL);
    _Atomic uint64_t *atomic_slot = (_Atomic uint64_t *)slot;
    atomic_store_explicit(atomic_slot, value, memory_order_release);
}
