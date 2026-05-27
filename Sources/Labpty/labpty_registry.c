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

void labpty_registry_init(labpty_registry_t *registry, const char *shm_dir) {
    assert(registry != NULL);
    assert(shm_dir != NULL);
    memset(registry, 0, sizeof(*registry));
    registry->next_handle = 1;
    snprintf(registry->shm_dir, sizeof(registry->shm_dir), "%s", shm_dir);
}

labpty_session_t *labpty_registry_find(labpty_registry_t *registry, uint64_t handle) {
    assert(registry != NULL);
    assert(handle > 0);
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        if (registry->sessions[i].used && registry->sessions[i].handle == handle) return &registry->sessions[i];
    }
    return NULL;
}

labpty_session_t *labpty_registry_find_logical(labpty_registry_t *registry, const char *logical_id) {
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
        close(master_fd);
        memset(slot, 0, sizeof(*slot));
        return status;
    }
    *out = slot;
    return LABPTY_OK;
}

void labpty_session_close(labpty_session_t *session) {
    assert(session != NULL);
    assert(session->master_fd >= -1);
    if (session->alive && session->child_pid > 0) killpg(session->child_pid, SIGHUP);
    if (session->master_fd >= 0) close(session->master_fd);
    if (session->child_pid > 0) {
        for (int i = 0; i < 20; i++) {
            int status = 0;
            pid_t got = waitpid(session->child_pid, &status, WNOHANG);
            if (got == session->child_pid) break;
            usleep(10000);
        }
        int status = 0;
        if (waitpid(session->child_pid, &status, WNOHANG) == 0) {
            killpg(session->child_pid, SIGKILL);
            waitpid(session->child_pid, &status, 0);
        }
    }
    session->master_fd = -1;
    session->alive = 0;
    labpty_byte_ring_close(&session->ring);
}

void labpty_registry_reap(labpty_registry_t *registry) {
    assert(registry != NULL);
    assert(registry->next_handle > 0);
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &registry->sessions[i];
        if (!s->used || s->child_pid <= 0) continue;
        int status = 0;
        pid_t got = waitpid(s->child_pid, &status, WNOHANG);
        if (got == s->child_pid) {
            if (s->master_fd >= 0) close(s->master_fd);
            s->master_fd = -1;
            s->alive = 0;
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
