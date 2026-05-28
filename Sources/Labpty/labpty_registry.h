#ifndef LABPTY_REGISTRY_H
#define LABPTY_REGISTRY_H

#include "labpty_byte_ring.h"
#include "labpty_protocol.h"

typedef struct {
    uint8_t used;
    uint8_t alive;
    /* Set while a session is in the asynchronous teardown window: the
     * client called terminate, the daemon dispatched SIGHUP, but the
     * child has not yet been reaped. labpty_registry_reap escalates
     * to SIGKILL after `terminate_deadline_ns` and finalises slot
     * cleanup once waitpid returns the zombie. */
    uint8_t close_pending;
    /* Set after labpty_registry_reap has escalated the close to
     * SIGKILL so we don't re-issue it on every tick. */
    uint8_t sigkill_sent;
    /* Absolute deadline (monotonic_ns) at which a still-running
     * close_pending child gets escalated to SIGKILL. Zero when no
     * close is in flight. */
    uint64_t terminate_deadline_ns;
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
    /* Bitmask of client slots (0..LABPTY_MAX_CLIENTS-1) currently
     * attached to this session. popcount is the connected-client count
     * surfaced in the descriptor. Set on openSession (the opener) and the
     * ATTACH op; cleared on DETACH and on client disconnect, where
     * client_release scrubs the departing client's bit from every
     * session. A freshly opened slot starts at 0 via memset, so a reused
     * slot never inherits a prior session's attachments. */
    uint8_t attached_clients;
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
/* Asynchronous termination request: dispatches SIGHUP to the child
 * process group, tears down the master/inspect fds, arms the
 * close_pending machinery, and returns immediately. The slot stays
 * `used` (with `alive` = 0) until labpty_registry_reap finalises it
 * — either by reaping the child or by escalating to SIGKILL after
 * `terminate_deadline_ns`. Cannot be used during daemon shutdown
 * because no further reap ticks will run; cleanup_daemon uses
 * labpty_session_close for the synchronous path. */
void labpty_session_request_close(labpty_session_t *session, uint64_t now_ns);
labpty_descriptor_view_t labpty_session_descriptor(labpty_session_t *session);

#endif
