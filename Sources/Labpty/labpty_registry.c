#include "labpty_registry.h"

static uint64_t reap_monotonic_ns(void);

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

static int valid_output_capacity(uint64_t capacity) {
    return capacity >= LABPTY_MIN_OUTPUT_CAPACITY &&
           capacity <= LABPTY_MAX_OUTPUT_CAPACITY &&
           (capacity & (capacity - 1)) == 0;
}

static void signal_child_process_group(pid_t child_pid, int signo) {
    assert(child_pid > 0);
    /* ESRCH: the child's process group has already been torn down.
     * EPERM: POSIX `killpg` rejected the call because no member of the
     * group is eligible (e.g., the child re-parented its pgrp). In
     * both cases the child itself may still be reachable by pid, so
     * fall back. Other errno values (EINVAL on a bogus signo) aren't
     * recoverable; the caller already accepts a best-effort signal. */
    if (killpg(child_pid, signo) != 0 && (errno == ESRCH || errno == EPERM)) {
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

/* Modelled by specs/labpty/LabptyLifecycle.tla::DeadLeak and ReclaimDeadLeak
 * (commit 5420964). Pre-5420964 the dead-leak state was absorbing; the
 * companion LabptyLifecyclePreSlotReclaim.tla pins that counter-example. */
static int is_reclaimable_dead_session(const labpty_session_t *session) {
    assert(session != NULL);
    return session->used && !session->alive && session->child_pid <= 0 && !session->close_pending;
}

static int reclaim_dead_session(labpty_session_t *session) {
    assert(session != NULL);
    if (!is_reclaimable_dead_session(session)) return 0;
    labpty_session_close(session);
    return 1;
}

static int reclaim_one_dead_session(labpty_registry_t *registry) {
    assert(registry != NULL);
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        if (reclaim_dead_session(&registry->sessions[i])) return 1;
    }
    return 0;
}

/* Modelled by specs/labpty/LabptyLifecycle.tla::OpenSession (free-slot
 * path) and ::ReclaimDeadLeak (the reclaim_dead_session +
 * reclaim_one_dead_session calls below). The two-stage reclaim — same
 * logical_id first, then any dead slot — keeps long-lived daemons from
 * exhausting their slot pool. */
labpty_status_t labpty_registry_open(
    labpty_registry_t *registry,
    const labpty_open_request_t *request,
    labpty_session_t **out
) {
    assert(registry != NULL);
    assert(request != NULL);
    assert(out != NULL);
    *out = NULL;
    labpty_registry_reap(registry);
    /* Reject a live duplicate; reclaim a same-id dead-leak slot (a child that
     * exited naturally on a session the client never terminated). A session
     * the client DID terminate has already relinquished its logical_id in
     * labpty_session_request_close, so it is not found here at all — that
     * decoupling of id reuse from child reaping is what makes a rapid
     * terminate->reopen of the same id race-free without blocking the
     * single-threaded event loop. Modelled by specs/labpty/LabptyReuse.tla;
     * the pre-fix "a terminated id stays held" shape is pinned by the
     * MC_ReusePreFix.cfg negative control. */
    labpty_session_t *existing = labpty_registry_find_logical(registry, request->logical_id);
    if (existing && !reclaim_dead_session(existing)) return LABPTY_E_SESSION_ID_IN_USE;
    labpty_session_t *slot = free_slot(registry);
    if (!slot && reclaim_one_dead_session(registry)) slot = free_slot(registry);
    if (!slot) return LABPTY_E_PAYLOAD_TOO_LARGE;
    uint64_t cap = request->output_capacity ? request->output_capacity : LABPTY_DEFAULT_OUTPUT_CAPACITY;
    if (!valid_output_capacity(cap)) return LABPTY_E_PAYLOAD_TOO_LARGE;
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
    /* Open a second slave-side fd on the same pty for inspection only:
     * tcgetattr / FIONREAD / fpathconf in handle_write's preflight. The
     * child already holds its own slave fds (dup'd to stdio); ours is
     * passive, O_NOCTTY to avoid claiming the controlling tty. If this
     * fails the daemon degrades gracefully — handle_write skips the
     * preflight and the pre-ADR-0008 best-effort write loop runs. */
    int slave_inspect_fd = -1;
    char ptsname_buf[LABPTY_PATH_BYTES + 1];
    if (ptsname_r(master_fd, ptsname_buf, sizeof(ptsname_buf)) == 0) {
        slave_inspect_fd = open(ptsname_buf, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    }
    /* Defensive: never let a leftover inspect fd survive slot reuse —
     * memset would overwrite the fd value and orphan the descriptor. */
    if (slot->slave_inspect_fd > 0) {
        close(slot->slave_inspect_fd);
    }
    memset(slot, 0, sizeof(*slot));
    slot->used = 1;
    slot->alive = 1;
    slot->handle = handle;
    slot->child_pid = child_pid;
    slot->master_fd = master_fd;
    slot->slave_inspect_fd = slave_inspect_fd;
    slot->canonical_pending_estimate = 0;
    slot->rows = request->rows;
    slot->cols = request->cols;
    snprintf(slot->logical_id, sizeof(slot->logical_id), "%s", logical_id);
    status = labpty_byte_ring_create(ring_path, cap, slot->logical_id, &slot->ring);
    if (status != LABPTY_OK) {
        /* Arm asynchronous teardown rather than the synchronous close, which
         * busy-waits in usleep steps up to ~700ms on the single-threaded event
         * loop after a post-fork ring-create failure (disk-full / fd / RLIMIT).
         * labpty_registry_reap finishes via WNOHANG + SIGKILL escalation, the
         * same path handle_terminate uses. (L3) */
        labpty_session_request_close(slot, reap_monotonic_ns());
        return status;
    }
    *out = slot;
    return LABPTY_OK;
}

/* Synchronous full-close path. Used at daemon shutdown
 * (cleanup_daemon) and from the open failure path where there's no
 * surrounding reap loop to finish the work. Modelled by
 * specs/labpty/LabptyLifecycle.tla::TerminateFast (when the child
 * reaps inside wait_for_child_exit) and ::TerminateSlow (when it
 * doesn't, leaving close_pending=1 for ReapTick to finish — the F2
 * fix). */
void labpty_session_close(labpty_session_t *session) {
    assert(session != NULL);
    assert(session->master_fd >= -1);
    if (session->alive && session->child_pid > 0) signal_child_process_group(session->child_pid, SIGHUP);
    drain_master_into_ring(session);
    if (session->slave_inspect_fd >= 0) {
        close(session->slave_inspect_fd);
        session->slave_inspect_fd = -1;
    }
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
        session->sigkill_sent = 0;
        session->terminate_deadline_ns = 0;
    } else {
        /* Child outlived our SIGKILL deadline. Leave used=1 so the
         * registry slot persists; labpty_registry_reap will finish the
         * cleanup when the OS finally hands us the zombie. Relinquish the
         * id like labpty_session_request_close so the slot never blocks
         * reuse of its logical_id while it waits to reap. */
        session->close_pending = 1;
        session->logical_id[0] = '\0';
    }
}

/* Window between SIGHUP-on-request and SIGKILL escalation in
 * labpty_registry_reap. Wide enough that well-behaved children
 * (which exit on SIGHUP within microseconds) are reaped on the next
 * event-loop tick without ever being SIGKILLed; tight enough that
 * a HUP-ignoring child doesn't sit in the registry for long. */
#define LABPTY_TERMINATE_HUP_BUDGET_NS 200000000ull  /* 200 ms */

void labpty_session_request_close(labpty_session_t *session, uint64_t now_ns) {
    assert(session != NULL);
    assert(session->master_fd >= -1);
    if (session->alive && session->child_pid > 0) {
        signal_child_process_group(session->child_pid, SIGHUP);
    }
    /* Drain the master once so any output the child emitted after the
     * client decided to terminate still lands in the byte ring; then
     * close the daemon-side fds. The ring stays open under
     * close_pending so labpty_registry_reap can publish a final
     * heartbeat and close it atomically with slot release. */
    drain_master_into_ring(session);
    if (session->slave_inspect_fd >= 0) {
        close(session->slave_inspect_fd);
        session->slave_inspect_fd = -1;
    }
    if (session->master_fd >= 0) {
        close(session->master_fd);
        session->master_fd = -1;
    }
    session->alive = 0;
    if (session->child_pid > 0) {
        session->close_pending = 1;
        session->sigkill_sent = 0;
        session->terminate_deadline_ns = now_ns + LABPTY_TERMINATE_HUP_BUDGET_NS;
        /* Relinquish the logical_id the instant the client terminates,
         * before the async reap finishes freeing this slot. A client
         * reopening the same id then finds no holder (the slot reaps under
         * no id on a later tick) and never races SESSION_ID_IN_USE — without
         * the open path blocking the event loop waiting for the child.
         * Modelled by specs/labpty/LabptyReuse.tla::NotAliveImpliesIdRelinquished;
         * the pre-fix "keep the id while close_pending" shape is pinned by
         * MC_ReusePreFix.cfg. LabptyLifecycle.tla has no logical_id, so it
         * could not catch this — see formal-specs.md. */
        session->logical_id[0] = '\0';
    } else {
        /* Child already gone; collapse the slot in place. */
        labpty_byte_ring_close(&session->ring);
        session->close_pending = 0;
        session->sigkill_sent = 0;
        session->terminate_deadline_ns = 0;
        session->used = 0;
    }
}

static uint64_t reap_monotonic_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ((uint64_t)ts.tv_sec * 1000000000ull) + (uint64_t)ts.tv_nsec;
}

/* Modelled by specs/labpty/LabptyLifecycle.tla::ReapTick. The close_pending
 * branch is the F2 fix that LabptyLifecyclePreF2 demonstrates the absence of.
 * The SIGKILL escalation inside this function is the loop-non-blocking part
 * of the async-terminate fix: handle_terminate returns immediately with
 * close_pending=1 and a deadline; this tick promotes to SIGKILL once the
 * deadline elapses, then WNOHANG-reaps. */
void labpty_registry_reap(labpty_registry_t *registry) {
    assert(registry != NULL);
    assert(registry->next_handle > 0);
    uint64_t now = reap_monotonic_ns();
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &registry->sessions[i];
        if (!s->used) continue;
        if (s->close_pending && !s->sigkill_sent && s->child_pid > 0 &&
            s->terminate_deadline_ns != 0 && now >= s->terminate_deadline_ns) {
            signal_child_process_group(s->child_pid, SIGKILL);
            s->sigkill_sent = 1;
        }
        if (s->child_pid <= 0) {
            /* The inspect fd is only useful while the child is alive
             * (writeInput preflight). Close it as soon as the slot is
             * known dead so a dead-leak slot (close_pending=0) does not
             * hold it until terminate/reuse — the H-6 fd leak. */
            if (s->slave_inspect_fd >= 0) {
                close(s->slave_inspect_fd);
                s->slave_inspect_fd = -1;
            }
            if (s->close_pending) {
                labpty_byte_ring_close(&s->ring);
                s->close_pending = 0;
                s->sigkill_sent = 0;
                s->terminate_deadline_ns = 0;
                s->used = 0;
            }
            continue;
        }
        int status = 0;
        pid_t got = waitpid(s->child_pid, &status, WNOHANG);
        if (got == s->child_pid || (got < 0 && errno == ECHILD)) {
            s->child_pid = 0;
            s->alive = 0;
            if (s->slave_inspect_fd >= 0) {
                close(s->slave_inspect_fd);
                s->slave_inspect_fd = -1;
            }
            if (s->close_pending) {
                labpty_byte_ring_close(&s->ring);
                s->close_pending = 0;
                s->sigkill_sent = 0;
                s->terminate_deadline_ns = 0;
                s->used = 0;
            }
        }
    }
}

labpty_descriptor_view_t labpty_session_descriptor(labpty_session_t *session) {
    assert(session != NULL);
    assert(session->used != 0);
    /* No tcgetpgrp(master_fd) call here — see comment on labpty_descriptor_view_t. */
    labpty_descriptor_view_t view = {
        .handle = session->handle,
        .child_pid = (int32_t)session->child_pid,
        .rows = session->rows,
        .cols = session->cols,
        .alive = session->alive,
        .logical_id = session->logical_id,
        .ring_path = session->ring.path,
        .output_capacity = session->ring.output_capacity,
        .input_capacity = 0,
        .connected_clients = (uint32_t)__builtin_popcount(session->attached_clients),
    };
    return view;
}
