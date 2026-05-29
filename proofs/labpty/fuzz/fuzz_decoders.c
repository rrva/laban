/*
 * Engine-agnostic fuzz target for the labpty wire-format decoders.
 *
 * Defines the libFuzzer ABI entry point LLVMFuzzerTestOneInput, which is
 * the de-facto standard consumed by AFL++ (afl-clang-fast + driver),
 * libFuzzer, Honggfuzz and Centipede alike — so the harness outlives any
 * single engine (libFuzzer itself is in maintenance mode). scripts/
 * fuzz-labpty drives it: AFL++ preferred, then libFuzzer, with a
 * deterministic ASan/UBSan corpus replay as the always-available
 * fallback — and that replay is the form wired into scripts/check.
 *
 * Where CBMC (proofs/labpty/frame_proof.c) proves the decoders safe
 * exhaustively up to a small input bound, this exercises them at full
 * size under AddressSanitizer + UBSan: the large-payload paths that are
 * intractable for bounded model checking (open's argv/envp arrays,
 * hello's capability list, 64 KB write-input). The two are complementary
 * halves of the same trust-boundary story.
 *
 * Input layout: the first byte selects the decoder; the remaining bytes
 * are the op payload, fed verbatim. See make_seeds.py for the corpus.
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "labpty_protocol.h"

/* Large output aggregates kept static so each iteration is allocation-
 * free and fast (a fuzzer drives one thread per process). */
static labpty_open_request_t  open_req;
static labpty_hello_request_t hello_req;

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size == 0) return 0;
    const uint8_t *p = data + 1;
    size_t n = size - 1;

    switch (data[0] % 7) {
    case 0: {
        labpty_frame_header_t h;
        labpty_decode_header(p, n, &h);
        break;
    }
    case 1:
        labpty_decode_open_request(p, n, &open_req);
        break;
    case 2: {
        labpty_resize_request_t r;
        labpty_decode_resize_request(p, n, &r);
        break;
    }
    case 3: {
        labpty_signal_request_t s;
        labpty_decode_signal_request(p, n, &s);
        break;
    }
    case 4: {
        labpty_handle_request_t hr;
        labpty_decode_handle_request(p, n, &hr);
        break;
    }
    case 5: {
        labpty_write_input_request_t w;
        if (labpty_decode_write_input_request(p, n, &w) == LABPTY_OK) {
            /* Read the whole decoded slice so the sanitizer confirms it
             * lies inside the input buffer — the property CBMC's
             * proof_decode_write_input proves statically. */
            volatile uint8_t sink = 0;
            for (size_t i = 0; i < w.len; i++) sink = (uint8_t)(sink ^ w.bytes[i]);
            (void)sink;
        }
        break;
    }
    case 6:
        if (labpty_decode_hello_request(p, n, &hello_req) == LABPTY_OK) {
            labpty_negotiate_hello(&hello_req);
        }
        break;
    }
    return 0;
}

#ifdef LABPTY_FUZZ_STANDALONE
/* Deterministic replay driver: feed each file argument through the fuzz
 * target once, under -fsanitize=address,undefined. This is the corpus
 * regression scripts/check runs when no fuzzing engine is installed.
 * libFuzzer and the AFL++ driver supply their own main(), so this is
 * compiled only in replay mode (-DLABPTY_FUZZ_STANDALONE). */
#include <stdio.h>
#include <stdlib.h>

static int replay_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "fuzz-replay: cannot open %s\n", path); return 1; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 1; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return 1; }
    rewind(f);
    uint8_t *buf = (uint8_t *)malloc((size_t)sz + 1u);
    if (!buf) { fclose(f); return 1; }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    (void)LLVMFuzzerTestOneInput(buf, got);
    free(buf);
    return 0;
}

int main(int argc, char **argv) {
    int rc = 0;
    for (int i = 1; i < argc; i++) rc |= replay_file(argv[i]);
    return rc;
}
#endif
