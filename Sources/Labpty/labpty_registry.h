#ifndef LABPTY_REGISTRY_H
#define LABPTY_REGISTRY_H

#include "labpty_byte_ring.h"
#include "labpty_protocol.h"

typedef struct {
    uint8_t used;
    uint8_t alive;
    /* Set when labpty_session_close ran but wait_for_child_exit timed out
     * (child still alive after SIGKILL + ~500ms). The slot stays `used`
     * so labpty_registry_reap can finish the cleanup when the child is
     * eventually reaped; without this flag the slot would leak forever. */
    uint8_t close_pending;
    uint64_t handle;
    pid_t child_pid;
    int master_fd;
    uint32_t rows;
    uint32_t cols;
    char logical_id[LABPTY_LOGICAL_ID_BYTES + 1];
    labpty_byte_ring_writer_t ring;
} labpty_session_t;

typedef struct {
    labpty_session_t sessions[LABPTY_MAX_SESSIONS];
    uint64_t next_handle;
    char shm_dir[LABPTY_PATH_BYTES + 1];
} labpty_registry_t;

void labpty_registry_init(labpty_registry_t *registry, const char *shm_dir);
labpty_session_t *labpty_registry_find(labpty_registry_t *registry, uint64_t handle);
labpty_session_t *labpty_registry_find_logical(labpty_registry_t *registry, const char *logical_id);
labpty_status_t labpty_registry_open(
    labpty_registry_t *registry,
    const labpty_open_request_t *request,
    labpty_session_t **out
);
void labpty_registry_reap(labpty_registry_t *registry);
void labpty_session_close(labpty_session_t *session);
labpty_descriptor_view_t labpty_session_descriptor(labpty_session_t *session);

#endif
