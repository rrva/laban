#include "labpty_protocol.h"

static uint64_t labpty_mono_ns(void) {
    struct timespec ts;
    assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    assert(ts.tv_nsec >= 0);
    return ((uint64_t)ts.tv_sec * 1000000000ull) + (uint64_t)ts.tv_nsec;
}

static labpty_status_t read_string(
    labpty_reader_t *reader,
    uint32_t max_bytes,
    char *out,
    size_t out_cap
) {
    assert(reader != NULL);
    assert(out != NULL);
    uint32_t len = 0;
    labpty_status_t status = labpty_read_u32(reader, &len);
    if (status != LABPTY_OK) return status;
    if (len > max_bytes || (size_t)len >= out_cap) return LABPTY_E_PAYLOAD_TOO_LARGE;
    const uint8_t *bytes = NULL;
    status = labpty_read_bytes(reader, len, &bytes);
    if (status != LABPTY_OK) return status;
    if (len > 0) memcpy(out, bytes, len);
    out[len] = '\0';
    return LABPTY_OK;
}

static labpty_status_t write_string(labpty_writer_t *writer, const char *value) {
    assert(writer != NULL);
    assert(value != NULL);
    size_t len = strlen(value);
    if (len > UINT32_MAX) return LABPTY_E_PAYLOAD_TOO_LARGE;
    labpty_status_t status = labpty_write_u32(writer, (uint32_t)len);
    if (status != LABPTY_OK) return status;
    return labpty_write_bytes(writer, (const uint8_t *)value, len);
}

static labpty_status_t read_string_array(
    labpty_reader_t *reader,
    uint32_t max_count,
    uint32_t max_bytes,
    char entries[][LABPTY_ENV_BYTES + 1],
    const char **ptrs,
    uint32_t *out_count
) {
    assert(reader != NULL);
    assert(entries != NULL);
    assert(ptrs != NULL);
    uint32_t count = 0;
    labpty_status_t status = labpty_read_u32(reader, &count);
    if (status != LABPTY_OK) return status;
    if (count > max_count) return LABPTY_E_PAYLOAD_TOO_LARGE;
    for (uint32_t i = 0; i < count; i++) {
        status = read_string(reader, max_bytes, entries[i], LABPTY_ENV_BYTES + 1);
        if (status != LABPTY_OK) return status;
        ptrs[i] = entries[i];
    }
    ptrs[count] = NULL;
    *out_count = count;
    return LABPTY_OK;
}

static labpty_status_t read_argv_array(labpty_reader_t *reader, labpty_open_request_t *out) {
    assert(reader != NULL);
    assert(out != NULL);
    uint32_t count = 0;
    labpty_status_t status = labpty_read_u32(reader, &count);
    if (status != LABPTY_OK) return status;
    if (count > LABPTY_ARGV_MAX) return LABPTY_E_PAYLOAD_TOO_LARGE;
    for (uint32_t i = 0; i < count; i++) {
        status = read_string(reader, LABPTY_ARG_BYTES, out->argv[i], LABPTY_ARG_BYTES + 1);
        if (status != LABPTY_OK) return status;
        out->argv_ptrs[i] = out->argv[i];
    }
    out->argv_ptrs[count] = NULL;
    out->argv_count = count;
    return LABPTY_OK;
}

labpty_status_t labpty_decode_open_request(
    const uint8_t *payload,
    size_t len,
    labpty_open_request_t *out
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    memset(out, 0, sizeof(*out));
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u32(&reader, &out->rows);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_read_u32(&reader, &out->cols)) != LABPTY_OK) return status;
    if ((status = labpty_read_u64(&reader, &out->output_capacity)) != LABPTY_OK) return status;
    if ((status = read_argv_array(&reader, out)) != LABPTY_OK) return status;
    status = read_string_array(&reader, LABPTY_ENVP_MAX, LABPTY_ENV_BYTES,
        out->envp, out->envp_ptrs, &out->envp_count);
    if (status != LABPTY_OK) return status;
    if ((status = read_string(&reader, LABPTY_CWD_BYTES, out->cwd, sizeof(out->cwd))) != LABPTY_OK) return status;
    status = read_string(&reader, LABPTY_LOGICAL_ID_BYTES, out->logical_id, sizeof(out->logical_id));
    if (status != LABPTY_OK) return status;
    return reader.cur == reader.end ? LABPTY_OK : LABPTY_E_TRUNCATED_FRAME;
}

labpty_status_t labpty_decode_resize_request(
    const uint8_t *payload,
    size_t len,
    labpty_resize_request_t *out
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u64(&reader, &out->handle);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_read_u32(&reader, &out->rows)) != LABPTY_OK) return status;
    if ((status = labpty_read_u32(&reader, &out->cols)) != LABPTY_OK) return status;
    return reader.cur == reader.end ? LABPTY_OK : LABPTY_E_TRUNCATED_FRAME;
}

labpty_status_t labpty_decode_signal_request(
    const uint8_t *payload,
    size_t len,
    labpty_signal_request_t *out
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u64(&reader, &out->handle);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_read_i32(&reader, &out->signo)) != LABPTY_OK) return status;
    return reader.cur == reader.end ? LABPTY_OK : LABPTY_E_TRUNCATED_FRAME;
}

labpty_status_t labpty_decode_handle_request(
    const uint8_t *payload,
    size_t len,
    labpty_handle_request_t *out
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u64(&reader, &out->handle);
    if (status != LABPTY_OK) return status;
    return reader.cur == reader.end ? LABPTY_OK : LABPTY_E_TRUNCATED_FRAME;
}

labpty_status_t labpty_decode_write_input_request(
    const uint8_t *payload,
    size_t len,
    labpty_write_input_request_t *out
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    if (len < 8) return LABPTY_E_TRUNCATED_FRAME;
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u64(&reader, &out->handle);
    if (status != LABPTY_OK) return status;
    out->len = (size_t)(reader.end - reader.cur);
    if (out->len > 64 * 1024) return LABPTY_E_PAYLOAD_TOO_LARGE;
    out->bytes = reader.cur;
    return LABPTY_OK;
}

labpty_status_t labpty_encode_hello_response(uint8_t *out, size_t cap, size_t *out_len) {
    assert(out != NULL);
    assert(out_len != NULL);
    labpty_writer_t writer = { .cur = out, .end = out + cap };
    labpty_status_t status = labpty_write_u16(&writer, 1);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_write_u16(&writer, 0)) != LABPTY_OK) return status;
    if ((status = labpty_write_u64(&writer, labpty_mono_ns())) != LABPTY_OK) return status;
    if ((status = labpty_write_u32(&writer, 4)) != LABPTY_OK) return status;
    const char *caps[4] = {"byte-ring/v1", "write-input-rpc/v1", "heartbeat-shm/v1", "session-id-pinning/v1"};
    for (int i = 0; i < 4; i++) {
        if ((status = write_string(&writer, caps[i])) != LABPTY_OK) return status;
    }
    *out_len = (size_t)(writer.cur - out);
    return LABPTY_OK;
}

labpty_status_t labpty_encode_ping_response(uint8_t *out, size_t cap, size_t *out_len) {
    assert(out != NULL);
    assert(out_len != NULL);
    labpty_writer_t writer = { .cur = out, .end = out + cap };
    labpty_status_t status = labpty_write_u64(&writer, labpty_mono_ns());
    if (status != LABPTY_OK) return status;
    *out_len = (size_t)(writer.cur - out);
    return LABPTY_OK;
}

labpty_status_t labpty_encode_descriptor(
    labpty_writer_t *writer,
    const labpty_descriptor_view_t *descriptor
) {
    assert(writer != NULL);
    assert(descriptor != NULL);
    labpty_status_t status = labpty_write_u64(writer, descriptor->handle);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_write_i32(writer, descriptor->child_pid)) != LABPTY_OK) return status;
    if ((status = labpty_write_i32(writer, descriptor->foreground_pid)) != LABPTY_OK) return status;
    if ((status = labpty_write_i32(writer, descriptor->foreground_pgid)) != LABPTY_OK) return status;
    if ((status = labpty_write_u32(writer, descriptor->rows)) != LABPTY_OK) return status;
    if ((status = labpty_write_u32(writer, descriptor->cols)) != LABPTY_OK) return status;
    if ((status = labpty_write_u8(writer, descriptor->alive)) != LABPTY_OK) return status;
    if ((status = write_string(writer, descriptor->logical_id)) != LABPTY_OK) return status;
    if ((status = write_string(writer, descriptor->ring_path)) != LABPTY_OK) return status;
    if ((status = labpty_write_u64(writer, descriptor->output_capacity)) != LABPTY_OK) return status;
    return labpty_write_u64(writer, descriptor->input_capacity);
}
