#ifndef LABPTY_PROTOCOL_H
#define LABPTY_PROTOCOL_H

#include "labpty_frame.h"

typedef struct {
    uint32_t rows;
    uint32_t cols;
    uint64_t output_capacity;
    uint32_t argv_count;
    uint32_t envp_count;
    char argv[LABPTY_ARGV_MAX][LABPTY_ARG_BYTES + 1];
    char envp[LABPTY_ENVP_MAX][LABPTY_ENV_BYTES + 1];
    char cwd[LABPTY_CWD_BYTES + 1];
    char logical_id[LABPTY_LOGICAL_ID_BYTES + 1];
    const char *argv_ptrs[LABPTY_ARGV_MAX + 1];
    const char *envp_ptrs[LABPTY_ENVP_MAX + 1];
} labpty_open_request_t;

typedef struct {
    uint64_t handle;
    uint32_t rows;
    uint32_t cols;
} labpty_resize_request_t;

typedef struct {
    uint64_t handle;
    int32_t signo;
} labpty_signal_request_t;

typedef struct {
    uint64_t handle;
} labpty_handle_request_t;

typedef struct {
    uint64_t handle;
    /* The `bytes` pointer addresses exactly `len` bytes of the request
     * frame buffer; -fbounds-safety statically checks every access via
     * the __counted_by relationship. With the extension disabled the
     * annotation is a no-op (zero-cost documentation). */
    const uint8_t *bytes __counted_by(len);
    size_t len;
} labpty_write_input_request_t;

typedef struct {
    uint16_t protocol_major;
    uint16_t protocol_minor;
    char client_id[LABPTY_LOGICAL_ID_BYTES + 1];
    uint32_t capability_count;
    char capabilities[64][65];
} labpty_hello_request_t;

typedef struct {
    uint64_t handle;
    int32_t child_pid;
    /* labpty deliberately does not carry foreground-process metadata.
     * Darwin's TIOCGPGRP requires `isctty(p, tp)` — the daemon, holding
     * only the master fd, has never claimed the PTY as its controlling
     * terminal, so any tcgetpgrp(master_fd) call here would return
     * ENOTTY. Consumers that need the foreground process derive it from
     * the child pid through libproc (see Sources/LabanTerminalCore/
     * process_metadata.c). */
    uint32_t rows;
    uint32_t cols;
    uint8_t alive;
    const char *logical_id;
    const char *ring_path;
    uint64_t output_capacity;
    uint64_t input_capacity;
} labpty_descriptor_view_t;

/* The decoder signatures below sit at the daemon's trust boundary —
 * every byte they consume came in from a client socket. The
 * `payload __sized_by(len)` annotation says "this pointer addresses
 * exactly `len` bytes": -fbounds-safety statically checks every read
 * inside the function body and at every call site; with the extension
 * disabled the annotation expands to nothing. Pointer-to-single output
 * arguments carry `__single` for symmetry. */
labpty_status_t labpty_decode_open_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_open_request_t *out __single
);

labpty_status_t labpty_decode_resize_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_resize_request_t *out __single
);

labpty_status_t labpty_decode_signal_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_signal_request_t *out __single
);

labpty_status_t labpty_decode_handle_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_handle_request_t *out __single
);

labpty_status_t labpty_decode_write_input_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_write_input_request_t *out __single
);

labpty_status_t labpty_decode_hello_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_hello_request_t *out __single
);

labpty_status_t labpty_negotiate_hello(const labpty_hello_request_t *request __single);

labpty_status_t labpty_encode_hello_response(uint8_t *out __sized_by(cap), size_t cap, size_t *out_len __single);
labpty_status_t labpty_encode_ping_response(uint8_t *out __sized_by(cap), size_t cap, size_t *out_len __single);
labpty_status_t labpty_encode_descriptor(
    labpty_writer_t *writer __single,
    const labpty_descriptor_view_t *descriptor __single
);

#endif
