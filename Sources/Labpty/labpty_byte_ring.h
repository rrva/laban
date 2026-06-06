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
/* Remove the ring's on-disk path while keeping its live mapping. The fd was
 * already closed at create (MAP_SHARED keeps the mapping valid), so this only
 * unlinks the directory entry: the producer can still publish a final
 * heartbeat into the mapping and an attached reader's existing mmap is
 * unaffected. Used at terminate so a close_pending session's shm file does not
 * linger on disk for the reap/SIGKILL window; the eventual
 * labpty_byte_ring_close then just munmaps (the path is already cleared). */
void labpty_byte_ring_unlink_path(labpty_byte_ring_writer_t *writer);
labpty_status_t labpty_byte_ring_write(labpty_byte_ring_writer_t *writer, const uint8_t *bytes, size_t len);
void labpty_byte_ring_heartbeat(labpty_byte_ring_writer_t *writer);

#endif
