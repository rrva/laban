/*
 * CBMC bounded-model-checking harness for the labpty wire-format
 * decoders (Sources/Labpty/labpty_frame.c, labpty_protocol.c).
 *
 * Every byte these decoders consume arrives from a client socket, so
 * the daemon's trust boundary is exactly here. CBMC explores ALL inputs
 * up to a small length bound and proves the decoders:
 *   - never read or write out of bounds,
 *   - never overflow a signed integer or shift by an out-of-range
 *     amount (no undefined behaviour),
 *   - and hand back values that satisfy the contracts the rest of the
 *     daemon relies on (frame_len in range; the write-input slice fully
 *     contained in the request buffer; strings NUL-terminated within
 *     their fixed-size field).
 *
 * This is the C-tier analogue of the TLA+ models under specs/labpty:
 * bounded + exhaustive + counterexample-producing. The negative-control
 * twin in frame_negctl.c documents the bug-shapes these guards prevent.
 * See scripts/check-cbmc and docs/process/formal-specs.md.
 *
 * The two decoder translation units are #included directly so the proof
 * can reach their static helpers (read_string, valid_utf8). Each
 * proof_* function is a CBMC entry point; scripts/check-cbmc sets the
 * --function, --unwind bound and the memory-safety / UB check flags.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "labpty_frame.c"
#include "labpty_protocol.c"

#ifdef LABPTY_CBMC
size_t   nondet_size(void);
unsigned nondet_uint(void);
#define ASSUME(c)     __CPROVER_assume(c)
#define ASSERT(c, m)  __CPROVER_assert((c), m)
/* CBMC 6.9 ships no model for memchr; read_string uses it to reject
 * embedded NULs. Supply a faithful one so the scan's reads (s[0..n-1])
 * are themselves bounds-checked rather than left as an unmodelled call. */
void *memchr(const void *s, int c, size_t n) {
    const unsigned char *p = (const unsigned char *)s;
    for (size_t i = 0; i < n; i++) {
        if (p[i] == (unsigned char)c) return (void *)(p + i);
    }
    return NULL;
}
#else
/* Fallback so the harness doubles as a compile-only drift smoke under a
 * plain C compiler when cbmc is absent (scripts/check-cbmc degraded
 * mode). The volatile seed stops the compiler constant-folding the
 * "nondeterministic" inputs away. ASSUME becomes an early return, which
 * is sound only because every proof_* function returns void. */
#include <assert.h>
static volatile unsigned g_nd_seed;
static size_t   nondet_size(void) { return (size_t)g_nd_seed; }
static unsigned nondet_uint(void) { return g_nd_seed; }
#define ASSUME(c)     do { if (!(c)) return; } while (0)
#define ASSERT(c, m)  assert((c) && (m))
#endif

/* valid_utf8 does multi-byte lookahead (s[i+1..i+3]); prove the i+k>=n
 * guards keep every read inside the buffer for an arbitrary input. */
void proof_valid_utf8(void) {
    size_t n = nondet_size();
    ASSUME(n <= 6);
    uint8_t *s = malloc(n);
    ASSUME(s != NULL);
#ifndef LABPTY_CBMC
    if (n) memset(s, (int)nondet_uint(), n);
#endif
    (void)valid_utf8(s, n);
}

/* read_string copies a length-prefixed field into a fixed out[out_cap].
 * Prove the memcpy and the NUL terminator stay in bounds and the result
 * is always NUL-terminated within the field. */
void proof_read_string(void) {
    size_t len = nondet_size();
    ASSUME(len <= 14);
    uint8_t *buf = malloc(len);
    ASSUME(buf != NULL);
#ifndef LABPTY_CBMC
    if (len) memset(buf, (int)nondet_uint(), len);
#endif
    labpty_reader_t reader = { buf, buf + len };
    char out[8];
    if (read_string(&reader, 8, out, sizeof(out)) == LABPTY_OK) {
        ASSERT(strlen(out) < sizeof(out), "NUL-terminated within out_cap");
    }
}

void proof_decode_header(void) {
    size_t len = nondet_size();
    ASSUME(len <= 26);
    uint8_t *buf = malloc(len);
    ASSUME(buf != NULL);
#ifndef LABPTY_CBMC
    if (len) memset(buf, (int)nondet_uint(), len);
#endif
    labpty_frame_header_t out;
    if (labpty_decode_header(buf, len, &out) == LABPTY_OK) {
        ASSERT(out.frame_len >= LABPTY_FRAME_HEADER_BYTES, "frame_len >= header");
        ASSERT(out.frame_len <= LABPTY_MAX_FRAME, "frame_len <= max");
        ASSERT(out.abi_major == 1, "abi_major pinned to 1");
    }
}

void proof_decode_resize(void) {
    size_t len = nondet_size();
    ASSUME(len <= 18);
    uint8_t *buf = malloc(len);
    ASSUME(buf != NULL);
#ifndef LABPTY_CBMC
    if (len) memset(buf, (int)nondet_uint(), len);
#endif
    labpty_resize_request_t out;
    if (labpty_decode_resize_request(buf, len, &out) == LABPTY_OK) {
        ASSERT(out.rows >= 1 && out.rows <= 4096, "rows in range");
        ASSERT(out.cols >= 1 && out.cols <= 4096, "cols in range");
    }
}

void proof_decode_signal(void) {
    size_t len = nondet_size();
    ASSUME(len <= 14);
    uint8_t *buf = malloc(len);
    ASSUME(buf != NULL);
#ifndef LABPTY_CBMC
    if (len) memset(buf, (int)nondet_uint(), len);
#endif
    labpty_signal_request_t out;
    (void)labpty_decode_signal_request(buf, len, &out);
}

void proof_decode_handle(void) {
    size_t len = nondet_size();
    ASSUME(len <= 10);
    uint8_t *buf = malloc(len);
    ASSUME(buf != NULL);
#ifndef LABPTY_CBMC
    if (len) memset(buf, (int)nondet_uint(), len);
#endif
    labpty_handle_request_t out;
    (void)labpty_decode_handle_request(buf, len, &out);
}

void proof_decode_output_wake_park(void) {
    size_t len = nondet_size();
    ASSUME(len <= 36);
    uint8_t *buf = malloc(len);
    ASSUME(buf != NULL);
#ifndef LABPTY_CBMC
    if (len) memset(buf, (int)nondet_uint(), len);
#endif
    labpty_output_wake_park_request_t out;
    if (labpty_decode_output_wake_park_request(buf, len, &out) == LABPTY_OK) {
        ASSERT(out.count <= LABPTY_MAX_SESSIONS, "wake park count bounded");
        ASSERT(out.count <= 2, "bounded harness permits at most two complete entries");
    }
}

/* The decoded slice (out.bytes, out.len) is handed straight to the PTY
 * master write path. Prove it is capped and lies entirely inside the
 * request buffer for every input. */
void proof_decode_write_input(void) {
    size_t len = nondet_size();
    ASSUME(len <= 20);
    uint8_t *buf = malloc(len);
    ASSUME(buf != NULL);
#ifndef LABPTY_CBMC
    if (len) memset(buf, (int)nondet_uint(), len);
#endif
    labpty_write_input_request_t out;
    if (labpty_decode_write_input_request(buf, len, &out) == LABPTY_OK) {
        ASSERT(out.len <= 64u * 1024u, "input_len capped");
        ASSERT(out.bytes >= buf, "slice base inside buffer");
        ASSERT((size_t)(out.bytes - buf) + out.len <= len, "slice end inside buffer");
    }
}

void proof_decode_hello(void) {
    size_t len = nondet_size();
    ASSUME(len <= 20);
    uint8_t *buf = malloc(len);
    ASSUME(buf != NULL);
#ifndef LABPTY_CBMC
    if (len) memset(buf, (int)nondet_uint(), len);
#endif
    labpty_hello_request_t out;
    if (labpty_decode_hello_request(buf, len, &out) == LABPTY_OK) {
        ASSERT(out.capability_count <= 64, "capability_count bounded");
    }
}

void proof_decode_open(void) {
    size_t len = nondet_size();
    ASSUME(len <= 28);
    uint8_t *buf = malloc(len);
    ASSUME(buf != NULL);
#ifndef LABPTY_CBMC
    if (len) memset(buf, (int)nondet_uint(), len);
#endif
    labpty_open_request_t *out = malloc(sizeof *out);
    ASSUME(out != NULL);
    if (labpty_decode_open_request(buf, len, out) == LABPTY_OK) {
        ASSERT(out->argv_count <= LABPTY_ARGV_MAX, "argv_count bounded");
        ASSERT(out->envp_count <= LABPTY_ENVP_MAX, "envp_count bounded");
        ASSERT(out->rows >= 1 && out->rows <= 4096, "rows in range");
        ASSERT(out->cols >= 1 && out->cols <= 4096, "cols in range");
    }
}

#ifndef LABPTY_CBMC
int main(void) {
    (void)sizeof(labpty_ring_magic); /* used only by main.c; silence -Wunused */
    proof_valid_utf8();
    proof_read_string();
    proof_decode_header();
    proof_decode_resize();
    proof_decode_signal();
    proof_decode_handle();
    proof_decode_output_wake_park();
    proof_decode_write_input();
    proof_decode_hello();
    proof_decode_open();
    return 0;
}
#endif
