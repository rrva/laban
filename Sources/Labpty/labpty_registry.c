#include "labpty_registry.h"

static labpty_session_t *free_slot(labpty_registry_t *registry) {
    assert(registry != NULL);
    assert(registry->next_handle > 0);
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        if (!registry->sessions[i].used) return &registry->sessions[i];
    }
    return NULL;
}

static void make_logical_id(uint64_t handle, const char *requested, char *out, size_t cap) {
    assert(out != NULL);
    assert(cap > 0);
    if (requested && requested[0]) {
        snprintf(out, cap, "%s", requested);
    } else {
        snprintf(out, cap, "labpty-%llu", (unsigned long long)handle);
    }
}

static labpty_status_t make_ring_path(
    const labpty_registry_t *registry,
    uint64_t handle,
    char *out,
    size_t cap
) {
    assert(registry != NULL);
    assert(out != NULL);
    int n = snprintf(out, cap, "%s/labpty-%llu.br", registry->shm_dir, (unsigned long long)handle);
    if (n < 0 || (size_t)n >= cap) return LABPTY_E_PAYLOAD_TOO_LARGE;
    return LABPTY_OK;
}

static void signal_child_process_group(pid_t child_pid, int signo) {
    assert(child_pid > 0);
    if (killpg(child_pid, signo) != 0 && errno == ESRCH) {
        kill(child_pid, signo);
    }
}

static int wait_for_child_exit(pid_t child_pid) {
    assert(child_pid > 0);
    for (int i = 0; i < 20; i++) {
        int status = 0;
        pid_t got = waitpid(child_pid, &status, WNOHANG);
        if (got == child_pid || (got < 0 && errno != EINTR)) return 1;
        usleep(10000);
    }
    int status = 0;
    pid_t got = waitpid(child_pid, &status, WNOHANG);
    if (got == child_pid || (got < 0 && errno != EINTR)) return 1;
    signal_child_process_group(child_pid, SIGKILL);
    for (int i = 0; i < 50; i++) {
        got = waitpid(child_pid, &status, WNOHANG);
        if (got == child_pid || (got < 0 && errno != EINTR)) return 1;
        usleep(10000);
    }
    return 0;
}

static void set_nonblocking(int fd) {
    if (fd < 0) return;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return;
    (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void drain_master_into_ring(labpty_session_t *session) {
    assert(session != NULL);
    if (session->master_fd < 0) return;
    uint8_t buf[4096];
    for (int i = 0; i < 1024; i++) {
        ssize_t n = read(session->master_fd, buf, sizeof(buf));
        if (n > 0) {
            labpty_byte_ring_write(&session->ring, buf, (size_t)n);
            continue;
        }
        if (n == 0) break;
        if (errno == EINTR) continue;
        break;
    }
}

void labpty_registry_init(labpty_registry_t *registry, const char *shm_dir) {
    assert(registry != NULL);
    assert(shm_dir != NULL);
    memset(registry, 0, sizeof(*registry));
    registry->next_handle = 1;
    snprintf(registry->shm_dir, sizeof(registry->shm_dir), "%s", shm_dir);
}

labpty_session_t *labpty_registry_find(labpty_registry_t *registry, uint64_t handle) {
    assert(registry != NULL);
    /* handle is client-controlled; handle == 0 (or any unmatched value)
     * must return NULL, not abort the daemon. Real handles start at 1
     * (next_handle initializes to 1), so the loop naturally returns NULL
     * for 0 since no slot ever holds that value. */
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        if (registry->sessions[i].used && registry->sessions[i].handle == handle) return &registry->sessions[i];
    }
    return NULL;
}

static labpty_session_t *labpty_registry_find_logical(labpty_registry_t *registry, const char *logical_id) {
    assert(registry != NULL);
    assert(logical_id != NULL);
    if (!logical_id[0]) return NULL;
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &registry->sessions[i];
        if (s->used && strcmp(s->logical_id, logical_id) == 0) return s;
    }
    return NULL;
}

labpty_status_t labpty_registry_open(
    labpty_registry_t *registry,
    const labpty_open_request_t *request,
    labpty_session_t **out
) {
    assert(registry != NULL);
    assert(request != NULL);
    assert(out != NULL);
    *out = NULL;
    if (labpty_registry_find_logical(registry, request->logical_id)) return LABPTY_E_SESSION_ID_IN_USE;
    labpty_session_t *slot = free_slot(registry);
    if (!slot) return LABPTY_E_PAYLOAD_TOO_LARGE;
    uint64_t handle = registry->next_handle++;
    char logical_id[LABPTY_LOGICAL_ID_BYTES + 1];
    char ring_path[LABPTY_PATH_BYTES + 1];
    make_logical_id(handle, request->logical_id, logical_id, sizeof(logical_id));
    labpty_status_t status = make_ring_path(registry, handle, ring_path, sizeof(ring_path));
    if (status != LABPTY_OK) return status;
    int master_fd = -1;
    pid_t child_pid = -1;
    const char *const *argv = request->argv_count > 0 ? request->argv_ptrs : NULL;
    const char *const *envp = request->envp_count > 0 ? request->envp_ptrs : NULL;
    if (laban_pty_open((int)request->rows, (int)request->cols, argv, envp, request->cwd, &master_fd, &child_pid) != 0) {
        return LABPTY_E_PTY_OPEN_FAILED;
    }
    set_nonblocking(master_fd);
    memset(slot, 0, sizeof(*slot));
    slot->used = 1;
    slot->alive = 1;
    slot->handle = handle;
    slot->child_pid = child_pid;
    slot->master_fd = master_fd;
    slot->rows = request->rows;
    slot->cols = request->cols;
    snprintf(slot->logical_id, sizeof(slot->logical_id), "%s", logical_id);
    uint64_t cap = request->output_capacity ? request->output_capacity : LABPTY_DEFAULT_OUTPUT_CAPACITY;
    status = labpty_byte_ring_create(ring_path, cap, slot->logical_id, &slot->ring);
    if (status != LABPTY_OK) {
        labpty_session_close(slot);
        return status;
    }
    *out = slot;
    return LABPTY_OK;
}

void labpty_session_close(labpty_session_t *session) {
    assert(session != NULL);
    assert(session->master_fd >= -1);
    if (session->alive && session->child_pid > 0) signal_child_process_group(session->child_pid, SIGHUP);
    drain_master_into_ring(session);
    if (session->master_fd >= 0) {
        close(session->master_fd);
        session->master_fd = -1;
    }
    session->alive = 0;
    int reaped = 1;
    if (session->child_pid > 0) {
        reaped = wait_for_child_exit(session->child_pid);
        if (reaped) session->child_pid = 0;
    }
    labpty_byte_ring_close(&session->ring);
    if (reaped) {
        session->used = 0;
        session->close_pending = 0;
    } else {
        /* Child outlived our SIGKILL deadline. Leave used=1 so the
         * registry slot persists; labpty_registry_reap will finish the
         * cleanup when the OS finally hands us the zombie. */
        session->close_pending = 1;
    }
}

void labpty_registry_reap(labpty_registry_t *registry) {
    assert(registry != NULL);
    assert(registry->next_handle > 0);
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &registry->sessions[i];
        if (!s->used || s->child_pid <= 0) continue;
        int status = 0;
        pid_t got = waitpid(s->child_pid, &status, WNOHANG);
        if (got == s->child_pid || (got < 0 && errno == ECHILD)) {
            s->child_pid = 0;
            s->alive = 0;
            if (s->close_pending) {
                /* labpty_session_close already closed the ring; just
                 * release the slot now that the child is finally gone. */
                s->close_pending = 0;
                s->used = 0;
            }
        }
    }
}

labpty_descriptor_view_t labpty_session_descriptor(labpty_session_t *session) {
    assert(session != NULL);
    assert(session->used != 0);
    int32_t fg_pgid = -1;
    if (session->alive && session->master_fd >= 0) fg_pgid = (int32_t)tcgetpgrp(session->master_fd);
    labpty_descriptor_view_t view = {
        .handle = session->handle,
        .child_pid = (int32_t)session->child_pid,
        .foreground_pid = fg_pgid,
        .foreground_pgid = fg_pgid,
        .rows = session->rows,
        .cols = session->cols,
        .alive = session->alive,
        .logical_id = session->logical_id,
        .ring_path = session->ring.path,
        .output_capacity = session->ring.output_capacity,
        .input_capacity = 0,
    };
    return view;
}
