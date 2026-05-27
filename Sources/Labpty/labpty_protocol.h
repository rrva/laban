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
    const uint8_t *bytes;
    size_t len;
} labpty_write_input_request_t;

typedef struct {
    uint64_t handle;
    int32_t child_pid;
    int32_t foreground_pid;
    int32_t foreground_pgid;
    uint32_t rows;
    uint32_t cols;
    uint8_t alive;
    const char *logical_id;
    const char *ring_path;
    uint64_t output_capacity;
    uint64_t input_capacity;
} labpty_descriptor_view_t;

labpty_status_t labpty_decode_open_request(
    const uint8_t *payload,
    size_t len,
    labpty_open_request_t *out
);

labpty_status_t labpty_decode_resize_request(
    const uint8_t *payload,
    size_t len,
    labpty_resize_request_t *out
);

labpty_status_t labpty_decode_signal_request(
    const uint8_t *payload,
    size_t len,
    labpty_signal_request_t *out
);

labpty_status_t labpty_decode_handle_request(
    const uint8_t *payload,
    size_t len,
    labpty_handle_request_t *out
);

labpty_status_t labpty_decode_write_input_request(
    const uint8_t *payload,
    size_t len,
    labpty_write_input_request_t *out
);

labpty_status_t labpty_encode_hello_response(uint8_t *out, size_t cap, size_t *out_len);
labpty_status_t labpty_encode_ping_response(uint8_t *out, size_t cap, size_t *out_len);
labpty_status_t labpty_encode_descriptor(
    labpty_writer_t *writer,
    const labpty_descriptor_view_t *descriptor
);

#endif
