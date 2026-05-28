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
    /* Inspection-only fd on the slave side: opened with O_RDONLY|O_NOCTTY
     * via ptsname(master_fd) so handle_write can query tcgetattr,
     * FIONREAD, and fpathconf(_PC_MAX_CANON/_PC_MAX_INPUT) before
     * committing a cooked-mode write. Never read from. -1 if the
     * preflight machinery is unavailable; in that case writes use the
     * pre-ADR-0008 best-effort path. See docs/adr/0008. */
    int slave_inspect_fd;
    /* Estimated bytes accepted by writeInput since the last canonical
     * delimiter (\n / VEOL / VEOF) we saw in our own payloads. These
     * bytes sit in the slave's raw queue waiting for a delimiter to
     * promote them into the canonical queue. Counts against MAX_INPUT
     * along with FIONREAD on the slave. Reset to "bytes after last
     * delimiter in the just-accepted payload" on every accepted write. */
    uint64_t canonical_pending_estimate;
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
labpty_status_t labpty_registry_open(
    labpty_registry_t *registry,
    const labpty_open_request_t *request,
    labpty_session_t **out
);
void labpty_registry_reap(labpty_registry_t *registry);
void labpty_session_close(labpty_session_t *session);
labpty_descriptor_view_t labpty_session_descriptor(labpty_session_t *session);

#endif
