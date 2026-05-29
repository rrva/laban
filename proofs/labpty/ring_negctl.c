/*
 * Negative-control twin of ring_proof.c (see frame_negctl.c for the
 * discipline). Reintroduces one removed guard and asserts the same bounds
 * property; CBMC must find a counter-example (check-cbmc runs this with
 * expect=fail). If it silently starts verifying, the clamp's proof has
 * gone vacuous.
 *
 * Only labpty_byte_ring.h is needed (types + constants); the buggy writer
 * is a local copy of labpty_byte_ring_write minus the over-capacity clamp,
 * so it touches no atomics and need not pull in byte_ring.c.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "labpty_byte_ring.h"

#ifdef LABPTY_CBMC
size_t   nondet_size(void);
uint64_t nondet_u64(void);
#define ASSUME(c) __CPROVER_assume(c)
#else
#include <assert.h>
static volatile unsigned g_nd_seed;
static size_t   nondet_size(void) { return (size_t)g_nd_seed; }
static uint64_t nondet_u64(void)  { return (uint64_t)g_nd_seed; }
#define ASSUME(c) do { if (!(c)) return; } while (0)
#endif

/*
 * BUG-SHAPE: drop labpty_byte_ring_write's over-capacity clamp
 *   if (retained > output_capacity) { retained = output_capacity; source = ...; }
 *
 * Without it, a payload longer than the ring leaves retained = len > capacity,
 * so the tail copy `memcpy(ring, source + first, retained - first)` writes
 * past the capacity-sized ring region. CBMC must find the out-of-bounds write.
 */
static labpty_status_t ring_write_no_clamp(
    labpty_byte_ring_writer_t *writer, const uint8_t *bytes, size_t len) {
    if (!writer->map || writer->output_capacity == 0) return LABPTY_E_RING_MAP_FAILED;
    size_t retained = len; /* clamp removed here */
    const uint8_t *source = bytes;
    uint64_t next_offset = writer->output_offset + (uint64_t)len;
    uint64_t retained_start = next_offset - (uint64_t)retained;
    uint64_t pos = retained_start & (writer->output_capacity - 1);
    uint8_t *ring = writer->map + writer->output_ring_offset;
    size_t first = retained;
    if (pos + retained > writer->output_capacity) first = (size_t)(writer->output_capacity - pos);
    if (first > 0) memcpy(ring + pos, source, first);
    if (retained > first) memcpy(ring, source + first, retained - first);
    writer->output_offset = next_offset;
    return LABPTY_OK;
}

void negctl_byte_ring_write_no_clamp(void) {
    uint64_t cap = nondet_u64();
    ASSUME(cap >= 4 && cap <= 64 && (cap & (cap - 1)) == 0);
    size_t len = nondet_size();
    ASSUME(len <= 2 * (size_t)cap + 8);
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
    w.output_offset = nondet_u64();
    (void)ring_write_no_clamp(&w, src, len);
}

#ifndef LABPTY_CBMC
int main(void) {
    negctl_byte_ring_write_no_clamp();
    return 0;
}
#endif
