#ifndef LABPTY_BYTE_RING_H
#define LABPTY_BYTE_RING_H

#include "labpty_frame.h"

typedef struct {
    int fd;
    uint8_t *map;
    size_t map_len;
    uint64_t output_offset;
    uint64_t output_capacity;
    uint64_t output_ring_offset;
    char path[LABPTY_PATH_BYTES + 1];
} labpty_byte_ring_writer_t;

labpty_status_t labpty_byte_ring_create(
    const char *path,
    uint64_t output_capacity,
    const char *logical_id,
    labpty_byte_ring_writer_t *out
);

void labpty_byte_ring_close(labpty_byte_ring_writer_t *writer);
labpty_status_t labpty_byte_ring_write(labpty_byte_ring_writer_t *writer, const uint8_t *bytes, size_t len);
void labpty_byte_ring_heartbeat(labpty_byte_ring_writer_t *writer);

#endif
