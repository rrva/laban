#include "labpty_frame.h"

static labpty_status_t require_read(labpty_reader_t *reader, size_t n) {
    assert(reader != NULL);
    assert(reader->cur <= reader->end);
    if ((size_t)(reader->end - reader->cur) < n) return LABPTY_E_TRUNCATED_FRAME;
    return LABPTY_OK;
}

static labpty_status_t require_write(labpty_writer_t *writer, size_t n) {
    assert(writer != NULL);
    assert(writer->cur <= writer->end);
    if ((size_t)(writer->end - writer->cur) < n) return LABPTY_E_TRUNCATED_FRAME;
    return LABPTY_OK;
}

labpty_status_t labpty_read_u8(labpty_reader_t *reader __single, uint8_t *out __single) {
    assert(out != NULL);
    assert(reader != NULL);
    if (require_read(reader, 1) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    *out = reader->cur[0];
    reader->cur += 1;
    return LABPTY_OK;
}

labpty_status_t labpty_read_u16(labpty_reader_t *reader __single, uint16_t *out __single) {
    assert(out != NULL);
    assert(reader != NULL);
    if (require_read(reader, 2) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    /* The shift promotes uint16_t to int (per C integer-promotion rules)
     * and the OR result is therefore int; cast back to silence
     * -Wimplicit-int-conversion. The masked value always fits in uint16_t. */
    *out = (uint16_t)((uint16_t)reader->cur[0] | ((uint16_t)reader->cur[1] << 8));
    reader->cur += 2;
    return LABPTY_OK;
}

labpty_status_t labpty_read_u32(labpty_reader_t *reader __single, uint32_t *out __single) {
    assert(out != NULL);
    assert(reader != NULL);
    if (require_read(reader, 4) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    *out = (uint32_t)reader->cur[0] | ((uint32_t)reader->cur[1] << 8)
        | ((uint32_t)reader->cur[2] << 16) | ((uint32_t)reader->cur[3] << 24);
    reader->cur += 4;
    return LABPTY_OK;
}

labpty_status_t labpty_read_u64(labpty_reader_t *reader __single, uint64_t *out __single) {
    assert(out != NULL);
    assert(reader != NULL);
    if (require_read(reader, 8) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value |= ((uint64_t)reader->cur[i]) << (i * 8);
    reader->cur += 8;
    *out = value;
    return LABPTY_OK;
}

labpty_status_t labpty_read_i32(labpty_reader_t *reader __single, int32_t *out __single) {
    uint32_t raw = 0;
    assert(out != NULL);
    assert(reader != NULL);
    labpty_status_t status = labpty_read_u32(reader, &raw);
    if (status != LABPTY_OK) return status;
    *out = (int32_t)raw;
    return LABPTY_OK;
}

labpty_status_t labpty_read_bytes(labpty_reader_t *reader __single, size_t n, const uint8_t **out __single) {
    assert(out != NULL);
    assert(reader != NULL);
    if (require_read(reader, n) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    *out = reader->cur;
    reader->cur += n;
    return LABPTY_OK;
}

labpty_status_t labpty_write_u8(labpty_writer_t *writer __single, uint8_t value) {
    assert(writer != NULL);
    assert(writer->cur <= writer->end);
    if (require_write(writer, 1) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    writer->cur[0] = value;
    writer->cur += 1;
    return LABPTY_OK;
}

labpty_status_t labpty_write_u16(labpty_writer_t *writer __single, uint16_t value) {
    assert(writer != NULL);
    assert(writer->cur <= writer->end);
    if (require_write(writer, 2) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    writer->cur[0] = (uint8_t)(value & 0xFF);
    writer->cur[1] = (uint8_t)((value >> 8) & 0xFF);
    writer->cur += 2;
    return LABPTY_OK;
}

labpty_status_t labpty_write_u32(labpty_writer_t *writer __single, uint32_t value) {
    assert(writer != NULL);
    assert(writer->cur <= writer->end);
    if (require_write(writer, 4) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    for (int i = 0; i < 4; i++) writer->cur[i] = (uint8_t)((value >> (i * 8)) & 0xFF);
    writer->cur += 4;
    return LABPTY_OK;
}

labpty_status_t labpty_write_u64(labpty_writer_t *writer __single, uint64_t value) {
    assert(writer != NULL);
    assert(writer->cur <= writer->end);
    if (require_write(writer, 8) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    for (int i = 0; i < 8; i++) writer->cur[i] = (uint8_t)((value >> (i * 8)) & 0xFF);
    writer->cur += 8;
    return LABPTY_OK;
}

labpty_status_t labpty_write_i32(labpty_writer_t *writer __single, int32_t value) {
    assert(writer != NULL);
    assert(writer->cur <= writer->end);
    return labpty_write_u32(writer, (uint32_t)value);
}

labpty_status_t labpty_write_bytes(labpty_writer_t *writer __single, const uint8_t *bytes __sized_by(n), size_t n) {
    assert(writer != NULL);
    assert(bytes != NULL || n == 0);
    if (require_write(writer, n) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (n > 0) memcpy(writer->cur, bytes, n);
    writer->cur += n;
    return LABPTY_OK;
}

labpty_status_t labpty_decode_header(
    const uint8_t *bytes __sized_by(len),
    size_t len,
    labpty_frame_header_t *out __single
) {
    assert(bytes != NULL);
    assert(out != NULL);
    if (len < LABPTY_FRAME_HEADER_BYTES) return LABPTY_E_TRUNCATED_FRAME;
    labpty_reader_t reader = { .cur = bytes, .end = bytes + LABPTY_FRAME_HEADER_BYTES };
    const uint8_t *magic = NULL;
    if (labpty_read_bytes(&reader, 4, &magic) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (memcmp(magic, labpty_frame_magic, 4) != 0) return LABPTY_E_VERSION_MISMATCH;
    if (labpty_read_u16(&reader, &out->abi_major) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (labpty_read_u16(&reader, &out->abi_minor) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (out->abi_major != 1) return LABPTY_E_VERSION_MISMATCH;
    if (labpty_read_u32(&reader, &out->frame_len) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (out->frame_len < LABPTY_FRAME_HEADER_BYTES) return LABPTY_E_TRUNCATED_FRAME;
    if (out->frame_len > LABPTY_MAX_FRAME) return LABPTY_E_OVERSIZE_FRAME;
    if (labpty_read_u16(&reader, &out->op) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (labpty_read_u16(&reader, &out->code) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    if (labpty_read_u64(&reader, &out->seq) != LABPTY_OK) return LABPTY_E_TRUNCATED_FRAME;
    return LABPTY_OK;
}

labpty_status_t labpty_encode_header(
    uint8_t *bytes __sized_by(len),
    size_t len,
    const labpty_frame_header_t *header __single
) {
    assert(bytes != NULL);
    assert(header != NULL);
    if (len < LABPTY_FRAME_HEADER_BYTES) return LABPTY_E_TRUNCATED_FRAME;
    labpty_writer_t writer = { .cur = bytes, .end = bytes + LABPTY_FRAME_HEADER_BYTES };
    labpty_status_t status = labpty_write_bytes(&writer, labpty_frame_magic, 4);
    if (status != LABPTY_OK) return status;
    if ((status = labpty_write_u16(&writer, header->abi_major)) != LABPTY_OK) return status;
    if ((status = labpty_write_u16(&writer, header->abi_minor)) != LABPTY_OK) return status;
    if ((status = labpty_write_u32(&writer, header->frame_len)) != LABPTY_OK) return status;
    if ((status = labpty_write_u16(&writer, header->op)) != LABPTY_OK) return status;
    if ((status = labpty_write_u16(&writer, header->code)) != LABPTY_OK) return status;
    return labpty_write_u64(&writer, header->seq);
}
