#ifndef LABPTY_FRAME_H
#define LABPTY_FRAME_H

#include "include/labpty_internal.h"

typedef struct {
    uint16_t abi_major;
    uint16_t abi_minor;
    uint32_t frame_len;
    uint16_t op;
    uint16_t code;
    uint64_t seq;
} labpty_frame_header_t;

typedef struct {
    const uint8_t *cur;
    const uint8_t *end;
} labpty_reader_t;

typedef struct {
    uint8_t *cur;
    uint8_t *end;
} labpty_writer_t;

labpty_status_t labpty_decode_header(
    const uint8_t *bytes,
    size_t len,
    labpty_frame_header_t *out
);

labpty_status_t labpty_encode_header(
    uint8_t *bytes,
    size_t len,
    const labpty_frame_header_t *header
);

labpty_status_t labpty_read_u8(labpty_reader_t *reader, uint8_t *out);
labpty_status_t labpty_read_u16(labpty_reader_t *reader, uint16_t *out);
labpty_status_t labpty_read_u32(labpty_reader_t *reader, uint32_t *out);
labpty_status_t labpty_read_u64(labpty_reader_t *reader, uint64_t *out);
labpty_status_t labpty_read_i32(labpty_reader_t *reader, int32_t *out);
labpty_status_t labpty_read_bytes(labpty_reader_t *reader, size_t n, const uint8_t **out);

labpty_status_t labpty_write_u8(labpty_writer_t *writer, uint8_t value);
labpty_status_t labpty_write_u16(labpty_writer_t *writer, uint16_t value);
labpty_status_t labpty_write_u32(labpty_writer_t *writer, uint32_t value);
labpty_status_t labpty_write_u64(labpty_writer_t *writer, uint64_t value);
labpty_status_t labpty_write_i32(labpty_writer_t *writer, int32_t value);
labpty_status_t labpty_write_bytes(labpty_writer_t *writer, const uint8_t *bytes, size_t n);

#endif
