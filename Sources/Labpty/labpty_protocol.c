#include "labpty_protocol.h"

static uint64_t labpty_mono_ns(void) {
    struct timespec ts;
    /* Don't wrap clock_gettime in assert(): under -DNDEBUG the assert
     * expression isn't evaluated, the call never runs, and `ts` stays
     * uninitialized. SwiftPM's release config doesn't pass -DNDEBUG
     * today but the hazard is latent — match main.c::monotonic_ns's
     * defensive `if`+0 pattern instead. */
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
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
    if (len > 0) {
        if (memchr(bytes, 0, len) != NULL) return LABPTY_E_PAYLOAD_TOO_LARGE;
        memcpy(out, bytes, len);
    }
    out[len] = '\0';
    return LABPTY_OK;
}

/* Defensive UTF-8 validator for protocol text fields that are echoed
 * back to Swift clients (logical_id in descriptors, client_id in
 * hello). Swift's LabptyPayloadReader.readString refuses non-UTF-8,
 * so a raw same-uid client could otherwise stuff a single 0xFF byte
 * into a session's logical_id and poison every subsequent
 * listLabptySessions() call on the first-party client. Rejected non-
 * NUL bytes already include the NUL guard in read_string above; this
 * adds the structural UTF-8 check on top. */
static int valid_utf8(const uint8_t *s, size_t n) {
    size_t i = 0;
    assert(s != NULL || n == 0);
    while (i < n) {
        uint8_t c = s[i];
        if (c <= 0x7fu) {
            i += 1;
            continue;
        }
        if ((c & 0xe0u) == 0xc0u) {
            if (c < 0xc2u || i + 1 >= n) return 0;
            if ((s[i + 1] & 0xc0u) != 0x80u) return 0;
            i += 2;
            continue;
        }
        if ((c & 0xf0u) == 0xe0u) {
            if (i + 2 >= n) return 0;
            if ((s[i + 1] & 0xc0u) != 0x80u) return 0;
            if ((s[i + 2] & 0xc0u) != 0x80u) return 0;
            /* Reject overlong (c==0xe0 with low continuation) and
             * surrogate range (c==0xed with high continuation). */
            if (c == 0xe0u && s[i + 1] < 0xa0u) return 0;
            if (c == 0xedu && s[i + 1] >= 0xa0u) return 0;
            i += 3;
            continue;
        }
        if ((c & 0xf8u) == 0xf0u) {
            if (c > 0xf4u) return 0;
            if (i + 3 >= n) return 0;
            if ((s[i + 1] & 0xc0u) != 0x80u) return 0;
            if ((s[i + 2] & 0xc0u) != 0x80u) return 0;
            if ((s[i + 3] & 0xc0u) != 0x80u) return 0;
            if (c == 0xf0u && s[i + 1] < 0x90u) return 0;
            if (c == 0xf4u && s[i + 1] >= 0x90u) return 0;
            i += 4;
            continue;
        }
        return 0;
    }
    return 1;
}

static labpty_status_t read_utf8_string(
    labpty_reader_t *reader,
    uint32_t max_bytes,
    char *out,
    size_t out_cap
) {
    labpty_status_t status = read_string(reader, max_bytes, out, out_cap);
    if (status != LABPTY_OK) return status;
    size_t len = strlen(out);
    if (!valid_utf8((const uint8_t *)out, len)) return LABPTY_E_PAYLOAD_TOO_LARGE;
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

/* envp-specific decoder. The entry stride is hard-coded to
 * LABPTY_ENV_BYTES + 1 so the function is intentionally NOT generic over
 * any other string-array layout (argv uses smaller entries via
 * read_argv_array). If you need another string-array type, add a new
 * decoder rather than parameterizing this one — a stride mismatch here
 * would silently corrupt the next field of the open request. */
static labpty_status_t read_envp_array(
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

/* The hardware limit is 0xFFFF per dimension (TIOCSWINSZ uses unsigned
 * short) but realistic terminals stay well below this. Capping at 4096
 * blocks pathological values that could starve renderers or trip OOM in
 * snapshot consumers downstream while leaving plenty of slack for tiled
 * 8K-display layouts. */
enum {
    LABPTY_MAX_WINSIZE_DIMENSION = 4096,
};

static labpty_status_t validate_winsize(uint32_t rows, uint32_t cols) {
    if (rows < 1 || rows > LABPTY_MAX_WINSIZE_DIMENSION) return LABPTY_E_PAYLOAD_TOO_LARGE;
    if (cols < 1 || cols > LABPTY_MAX_WINSIZE_DIMENSION) return LABPTY_E_PAYLOAD_TOO_LARGE;
    return LABPTY_OK;
}

labpty_status_t labpty_decode_open_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_open_request_t *out __single
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    memset(out, 0, sizeof(*out));
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u32(&reader, &out->rows);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_read_u32(&reader, &out->cols)) != LABPTY_OK) return status;
    if ((status = validate_winsize(out->rows, out->cols)) != LABPTY_OK) return status;
    if ((status = labpty_read_u64(&reader, &out->output_capacity)) != LABPTY_OK) return status;
    if ((status = read_argv_array(&reader, out)) != LABPTY_OK) return status;
    status = read_envp_array(&reader, LABPTY_ENVP_MAX, LABPTY_ENV_BYTES,
        out->envp, out->envp_ptrs, &out->envp_count);
    if (status != LABPTY_OK) return status;
    if ((status = read_string(&reader, LABPTY_CWD_BYTES, out->cwd, sizeof(out->cwd))) != LABPTY_OK) return status;
    /* logical_id is echoed back to every Swift client via
     * listLabptySessions; LabptyPayloadReader.readString refuses non-
     * UTF-8 input and would otherwise throw on the entire list
     * response. */
    status = read_utf8_string(&reader, LABPTY_LOGICAL_ID_BYTES, out->logical_id, sizeof(out->logical_id));
    if (status != LABPTY_OK) return status;
    /* Trailing bytes are forward-compatible additive fields per ADR 0007.
     * A future LabanApp/laband may append new optional fields to this
     * request; an OLD labpty (this code) must accept and ignore them so
     * long-lived sessions survive client upgrades. The same rationale
     * applies to the other fixed-shape request decoders below. */
    return LABPTY_OK;
}

labpty_status_t labpty_decode_resize_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_resize_request_t *out __single
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u64(&reader, &out->handle);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_read_u32(&reader, &out->rows)) != LABPTY_OK) return status;
    if ((status = labpty_read_u32(&reader, &out->cols)) != LABPTY_OK) return status;
    if ((status = validate_winsize(out->rows, out->cols)) != LABPTY_OK) return status;
    /* Trailing bytes are tolerated for additive evolution (see ADR 0007
     * note in labpty_decode_open_request). */
    return LABPTY_OK;
}

labpty_status_t labpty_decode_signal_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_signal_request_t *out __single
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u64(&reader, &out->handle);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_read_i32(&reader, &out->signo)) != LABPTY_OK) return status;
    /* Trailing bytes are tolerated for additive evolution (see ADR 0007
     * note in labpty_decode_open_request). */
    return LABPTY_OK;
}

labpty_status_t labpty_decode_handle_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_handle_request_t *out __single
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u64(&reader, &out->handle);
    if (status != LABPTY_OK) return status;
    /* Trailing bytes are tolerated for additive evolution (see ADR 0007
     * note in labpty_decode_open_request). */
    return LABPTY_OK;
}

labpty_status_t labpty_decode_write_input_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_write_input_request_t *out __single
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    if (len < 12) return LABPTY_E_TRUNCATED_FRAME;
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u64(&reader, &out->handle);
    if (status != LABPTY_OK) return status;
    /* Explicit input_len prefix lets the operation grow additive
     * trailing fields without those bytes being silently typed into
     * the PTY. The previous shape (handle followed by remaining-of-
     * payload bytes) closed off ADR 0007's additive-evolution path
     * for this op specifically. */
    uint32_t input_len = 0;
    status = labpty_read_u32(&reader, &input_len);
    if (status != LABPTY_OK) return status;
    if (input_len > (uint32_t)(64 * 1024)) return LABPTY_E_PAYLOAD_TOO_LARGE;
    if ((size_t)(reader.end - reader.cur) < input_len) return LABPTY_E_TRUNCATED_FRAME;
    out->len = (size_t)input_len;
    out->bytes = reader.cur;
    /* Trailing bytes past out->bytes are tolerated for additive
     * evolution (see ADR 0007 note in labpty_decode_open_request). */
    return LABPTY_OK;
}

labpty_status_t labpty_decode_hello_request(
    const uint8_t *payload __sized_by(len),
    size_t len,
    labpty_hello_request_t *out __single
) {
    assert(payload != NULL || len == 0);
    assert(out != NULL);
    memset(out, 0, sizeof(*out));
    labpty_reader_t reader = { .cur = payload, .end = payload + len };
    labpty_status_t status = labpty_read_u16(&reader, &out->protocol_major);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_read_u16(&reader, &out->protocol_minor)) != LABPTY_OK) return status;
    /* Symmetric with logical_id: client_id is text that observability
     * paths may surface to Swift, so reject non-UTF-8 up front. */
    if ((status = read_utf8_string(&reader, LABPTY_LOGICAL_ID_BYTES, out->client_id, sizeof(out->client_id))) != LABPTY_OK) return status;
    uint32_t cap_count = 0;
    if ((status = labpty_read_u32(&reader, &cap_count)) != LABPTY_OK) return status;
    if (cap_count > 64) return LABPTY_E_PAYLOAD_TOO_LARGE;
    out->capability_count = cap_count;
    for (uint32_t i = 0; i < cap_count; i++) {
        status = read_string(&reader, 64, out->capabilities[i], sizeof(out->capabilities[i]));
        if (status != LABPTY_OK) return status;
    }
    /* Trailing bytes are tolerated for additive evolution (see ADR 0007
     * note in labpty_decode_open_request). Hello especially must remain
     * future-additive: a new client field appended after capabilities
     * would otherwise break every existing labpty deployment. */
    return LABPTY_OK;
}

static const char *const labpty_required_capabilities[] = {
    "byte-ring/v1",
    "write-input-rpc/v1",
    "heartbeat-shm/v1",
    "session-id-pinning/v1",
};

labpty_status_t labpty_negotiate_hello(const labpty_hello_request_t *request __single) {
    assert(request != NULL);
    if (request->protocol_major != 1) return LABPTY_E_VERSION_MISMATCH;
    size_t required = sizeof(labpty_required_capabilities) / sizeof(labpty_required_capabilities[0]);
    for (size_t i = 0; i < required; i++) {
        int found = 0;
        for (uint32_t j = 0; j < request->capability_count; j++) {
            if (strcmp(labpty_required_capabilities[i], request->capabilities[j]) == 0) {
                found = 1;
                break;
            }
        }
        if (!found) return LABPTY_E_CAPABILITY_REQUIRED;
    }
    return LABPTY_OK;
}

labpty_status_t labpty_encode_hello_response(uint8_t *out __sized_by(cap), size_t cap, size_t *out_len __single) {
    assert(out != NULL);
    assert(out_len != NULL);
    labpty_writer_t writer = { .cur = out, .end = out + cap };
    labpty_status_t status = labpty_write_u16(&writer, 1);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_write_u16(&writer, 0)) != LABPTY_OK) return status;
    if ((status = labpty_write_u64(&writer, labpty_mono_ns())) != LABPTY_OK) return status;
    const char *const caps[] = {
        "byte-ring/v1",
        "write-input-rpc/v1",
        "heartbeat-shm/v1",
        "session-id-pinning/v1",
    };
    size_t cap_count = sizeof(caps) / sizeof(caps[0]);
    if ((status = labpty_write_u32(&writer, (uint32_t)cap_count)) != LABPTY_OK) return status;
    for (size_t i = 0; i < cap_count; i++) {
        if ((status = write_string(&writer, caps[i])) != LABPTY_OK) return status;
    }
    *out_len = (size_t)(writer.cur - out);
    return LABPTY_OK;
}

labpty_status_t labpty_encode_ping_response(uint8_t *out __sized_by(cap), size_t cap, size_t *out_len __single) {
    assert(out != NULL);
    assert(out_len != NULL);
    labpty_writer_t writer = { .cur = out, .end = out + cap };
    labpty_status_t status = labpty_write_u64(&writer, labpty_mono_ns());
    if (status != LABPTY_OK) return status;
    *out_len = (size_t)(writer.cur - out);
    return LABPTY_OK;
}

labpty_status_t labpty_encode_descriptor(
    labpty_writer_t *writer __single,
    const labpty_descriptor_view_t *descriptor __single
) {
    assert(writer != NULL);
    assert(descriptor != NULL);
    labpty_status_t status = labpty_write_u64(writer, descriptor->handle);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_write_i32(writer, descriptor->child_pid)) != LABPTY_OK) return status;
    if ((status = labpty_write_u32(writer, descriptor->rows)) != LABPTY_OK) return status;
    if ((status = labpty_write_u32(writer, descriptor->cols)) != LABPTY_OK) return status;
    if ((status = labpty_write_u8(writer, descriptor->alive)) != LABPTY_OK) return status;
    if ((status = write_string(writer, descriptor->logical_id)) != LABPTY_OK) return status;
    if ((status = write_string(writer, descriptor->ring_path)) != LABPTY_OK) return status;
    if ((status = labpty_write_u64(writer, descriptor->output_capacity)) != LABPTY_OK) return status;
    return labpty_write_u64(writer, descriptor->input_capacity);
}
