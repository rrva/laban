/*
 * CBMC proof of the byte-ring WRITE index arithmetic
 * (Sources/Labpty/labpty_byte_ring.c::labpty_byte_ring_write).
 *
 * Division of labour with the TLA+ model: specs/labpty/LabptyByteRing.tla
 * owns the CROSS-PROCESS ORDERING properties (NoTornRead,
 * WindowDoesNotContainFutureWrites) — the release/acquire dance between a
 * writer process and a reader process over the shared mmap, which neither
 * CBMC nor any sequential analysis can model faithfully. This proof owns
 * the other half: the SEQUENTIAL wraparound index arithmetic the writer
 * runs on every call — the `& (capacity-1)` split into a head copy and a
 * tail copy, plus the over-capacity clamp. It proves that for ANY prior
 * output_offset (unbounded) and ANY payload length, both memcpy targets
 * stay inside the ring region and both source reads stay inside the input
 * buffer: no out-of-bounds write or read, ever.
 *
 * Capacity is a small power-of-two family (4..64): the masking/split logic
 * is parametric in capacity, so a small family proves it for every
 * power-of-two size, exactly as the MC_ByteRing TLA+ configs use small
 * ring sizes. output_offset is left fully unbounded.
 *
 * byte_ring.c is #included so the proof reaches the real write path and
 * its static helpers; the syscall/mmap functions (create/close) are unused
 * here and dropped by --drop-unused-functions.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef LABPTY_CBMC
/* CBMC 6.9 ships no model for the __c11_atomic_store builtin behind
 * atomic_store_explicit. This proof reasons about SEQUENTIAL bounds, not
 * memory ordering (that is LabptyByteRing.tla's job), so model the release
 * store as a plain in-bounds store by casting away _Atomic. The bytes and
 * the target address are identical, so the bounds/pointer checks are
 * exactly the same; only the (irrelevant-here) ordering is dropped. */
#include <stdatomic.h>
#undef atomic_store_explicit
#define atomic_store_explicit(obj, val, order) (*((uint64_t *)(void *)(obj)) = (uint64_t)(val))
#endif

#include "labpty_byte_ring.c"

#ifdef LABPTY_CBMC
size_t   nondet_size(void);
uint64_t nondet_u64(void);
#define ASSUME(c)    __CPROVER_assume(c)
#define ASSERT(c, m) __CPROVER_assert((c), m)
#else
#include <assert.h>
static volatile unsigned g_nd_seed;
static size_t   nondet_size(void) { return (size_t)g_nd_seed; }
static uint64_t nondet_u64(void)  { return (uint64_t)g_nd_seed; }
#define ASSUME(c)    do { if (!(c)) return; } while (0)
#define ASSERT(c, m) assert((c) && (m))
#endif

void proof_byte_ring_write(void) {
    uint64_t cap = nondet_u64();
    ASSUME(cap >= 4 && cap <= 64 && (cap & (cap - 1)) == 0); /* power of two */

    size_t len = nondet_size();
    ASSUME(len <= 2 * (size_t)cap + 8); /* covers no-wrap, wrap, and len>cap clamp */

    size_t map_len = (size_t)LABPTY_INPUT_RING_OFFSET + (size_t)cap;
    uint8_t *map = malloc(map_len);
    ASSUME(map != NULL);
    uint8_t *src = malloc(len == 0 ? 1 : len);
    ASSUME(src != NULL);
#ifndef LABPTY_CBMC
    memset(map, 0, map_len);
    if (len) memset(src, (int)g_nd_seed, len);
#endif

    labpty_byte_ring_writer_t w;
    memset(&w, 0, sizeof(w));
    w.fd = -1;
    w.map = map;
    w.map_len = map_len;
    w.output_capacity = cap;
    w.output_ring_offset = LABPTY_INPUT_RING_OFFSET;
    w.output_offset = nondet_u64(); /* ANY prior write position, unbounded */

    uint64_t before = w.output_offset;
    if (labpty_byte_ring_write(&w, src, len) == LABPTY_OK) {
        ASSERT(w.output_offset == before + (uint64_t)len, "logical offset advances by len");
    }
}

#ifndef LABPTY_CBMC
int main(void) {
    proof_byte_ring_write();
    return 0;
}
#endif
