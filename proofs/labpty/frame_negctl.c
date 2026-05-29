/*
 * Negative-control twin of frame_proof.c.
 *
 * Each harness here reintroduces a specific bug-shape into a copy of a
 * real decoder and asserts the SAME memory-safety property. CBMC is
 * REQUIRED to find a counter-example (scripts/check-cbmc runs these with
 * expect=fail). This is the C-tier analogue of the specs/labpty
 * negative-control configs (MC_*PreFix, *Torn): it proves the harness
 * and the checker can actually see the class of bug the real guard
 * prevents, so a green positive proof in frame_proof.c is meaningful and
 * not vacuous. If one of these silently starts PASSING, the bug-shape it
 * documents is no longer reproducible and someone has weakened the
 * proof.
 *
 * Only labpty_frame.c is pulled in (types + the real reader primitives);
 * the buggy decoders are local copies that differ from the originals by
 * exactly one removed guard, named in each comment.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "labpty_frame.c"

#ifdef LABPTY_CBMC
size_t   nondet_size(void);
unsigned nondet_uint(void);
#define ASSUME(c) __CPROVER_assume(c)
#else
#include <assert.h>
static volatile unsigned g_nd_seed;
static size_t   nondet_size(void) { return (size_t)g_nd_seed; }
static unsigned nondet_uint(void) { return g_nd_seed; }
#define ASSUME(c) do { if (!(c)) return; } while (0)
#endif

/*
 * BUG-SHAPE: drop labpty_decode_header's first guard
 *   `if (len < LABPTY_FRAME_HEADER_BYTES) return LABPTY_E_TRUNCATED_FRAME;`
 *
 * The reader window end is then set to bytes + 24 regardless of how many
 * bytes were actually supplied. require_read() trusts that window, so
 * the fixed-field reads (and the magic memcmp) walk past a buffer
 * shorter than 24 bytes. The guard is load-bearing; CBMC must find the
 * out-of-bounds read.
 */
static labpty_status_t decode_header_no_len_guard(
    const uint8_t *bytes, size_t len, labpty_frame_header_t *out) {
    (void)len; /* guard removed here */
    labpty_reader_t reader = { bytes, bytes + LABPTY_FRAME_HEADER_BYTES };
    const uint8_t *magic = NULL;
    if (labpty_read_bytes(&reader, 4, &magic) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (memcmp(magic, labpty_frame_magic, 4) != 0) return LABPTY_E_VERSION_MISMATCH;
    if (labpty_read_u16(&reader, &out->abi_major) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (labpty_read_u16(&reader, &out->abi_minor) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (out->abi_major != 1) return LABPTY_E_VERSION_MISMATCH;
    if (labpty_read_u32(&reader, &out->frame_len) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (labpty_read_u16(&reader, &out->op) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (labpty_read_u16(&reader, &out->code) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (labpty_read_u64(&reader, &out->seq) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    return LABPTY_OK;
}

void negctl_decode_header(void) {
    size_t len = nondet_size();
    ASSUME(len <= 26);
    uint8_t *buf = malloc(len);
    ASSUME(buf != NULL);
#ifndef LABPTY_CBMC
    if (len) memset(buf, (int)nondet_uint(), len);
#endif
    labpty_frame_header_t out;
    (void)decode_header_no_len_guard(buf, len, &out);
}

/*
 * BUG-SHAPE: drop the `i + k >= n` lookahead bound checks from the
 * multi-byte branches of valid_utf8. A truncated lead byte at the end of
 * the buffer (e.g. 0xC2 as the last byte) then makes the continuation
 * read s[i+1] step one past the end. CBMC must find the out-of-bounds
 * read.
 */
static int valid_utf8_no_lookahead_guard(const uint8_t *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        if (c <= 0x7fu) { i += 1; continue; }
        if ((c & 0xe0u) == 0xc0u) {
            /* removed: if (c < 0xc2u || i + 1 >= n) return 0; */
            if ((s[i + 1] & 0xc0u) != 0x80u) return 0;
            i += 2;
            continue;
        }
        if ((c & 0xf0u) == 0xe0u) {
            /* removed: if (i + 2 >= n) return 0; */
            if ((s[i + 1] & 0xc0u) != 0x80u) return 0;
            if ((s[i + 2] & 0xc0u) != 0x80u) return 0;
            i += 3;
            continue;
        }
        if ((c & 0xf8u) == 0xf0u) {
            /* removed: if (i + 3 >= n) return 0; */
            if ((s[i + 1] & 0xc0u) != 0x80u) return 0;
            if ((s[i + 2] & 0xc0u) != 0x80u) return 0;
            if ((s[i + 3] & 0xc0u) != 0x80u) return 0;
            i += 4;
            continue;
        }
        return 0;
    }
    return 1;
}

void negctl_valid_utf8(void) {
    size_t n = nondet_size();
    ASSUME(n <= 6);
    uint8_t *s = malloc(n);
    ASSUME(s != NULL);
#ifndef LABPTY_CBMC
    if (n) memset(s, (int)nondet_uint(), n);
#endif
    (void)valid_utf8_no_lookahead_guard(s, n);
}

#ifndef LABPTY_CBMC
int main(void) {
    (void)sizeof(labpty_ring_magic);
    negctl_decode_header();
    negctl_valid_utf8();
    return 0;
}
#endif
