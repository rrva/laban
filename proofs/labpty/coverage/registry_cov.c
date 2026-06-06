/*
 * Deterministic MC/DC coverage harness for labpty_registry.c's decision
 * functions.
 *
 * The LabptyTests integration suite is the wrong instrument for MC/DC: it is
 * timing-dependent (the daemon MC/DC number jitters run-to-run) and it cannot
 * reach the defensive vectors — a NULL requested id, a child_pid that is
 * already gone, a path that overflows its buffer. This harness calls each
 * boolean decision directly with the exact condition combinations MC/DC
 * requires, deterministically. It is built instrumented and its profile is
 * merged with the integration profile in scripts/coverage-labpty, so the
 * reported daemon MC/DC is the UNION of what either exercises.
 *
 * labpty_registry.c is #included so the harness can reach its static
 * decision helpers (the same pattern as the CBMC harnesses).
 */
#include <assert.h>
#include <string.h>

#include "labpty_registry.c"

/* labpty_registry_open references this terminal-core symbol; the harness
 * never calls open, so stub it to link without the terminal-core library. */
int laban_pty_open(int rows, int cols, const char *const *argv,
                   const char *const *envp, const char *cwd,
                   int *out_master_fd, pid_t *out_child_pid) {
    (void)rows; (void)cols; (void)argv; (void)envp; (void)cwd;
    if (out_master_fd) *out_master_fd = -1;
    if (out_child_pid) *out_child_pid = -1;
    return -1;
}

/* (capacity >= MIN && capacity <= MAX && power-of-two): drive each condition
 * to independently determine the result. */
static void cover_valid_output_capacity(void) {
    assert(valid_output_capacity(LABPTY_MIN_OUTPUT_CAPACITY));               /* T T T */
    assert(valid_output_capacity(LABPTY_MAX_OUTPUT_CAPACITY));               /* T T T */
    assert(!valid_output_capacity(1024));                                   /* C1 false (< MIN) */
    assert(!valid_output_capacity((uint64_t)LABPTY_MAX_OUTPUT_CAPACITY * 2));/* C2 false (> MAX) */
    assert(!valid_output_capacity(300000));                                 /* C3 false (not 2^n) */
}

/* (requested && requested[0]): NULL is unreachable from the protocol, but the
 * defensive guard is real — drive it here. */
static void cover_make_logical_id(void) {
    char out[LABPTY_LOGICAL_ID_BYTES + 1];
    make_logical_id(7, NULL, out, sizeof(out));    /* C1 false: requested == NULL */
    assert(out[0] != '\0');
    make_logical_id(7, "", out, sizeof(out));      /* C1 true, C2 false: requested[0] == 0 */
    assert(out[0] != '\0');
    make_logical_id(7, "my-id", out, sizeof(out)); /* C1 true, C2 true */
    assert(strcmp(out, "my-id") == 0);
}

/* (used && !alive && child_pid <= 0 && !close_pending): each condition false in
 * turn, plus the all-true reclaim. */
static void cover_is_reclaimable(void) {
    labpty_session_t s;
    memset(&s, 0, sizeof(s));
    s.used = 1; s.alive = 0; s.child_pid = 0; s.close_pending = 0;
    assert(is_reclaimable_dead_session(&s) == 1);                                 /* all true */
    s.used = 0;          assert(!is_reclaimable_dead_session(&s)); s.used = 1;          /* used false */
    s.alive = 1;         assert(!is_reclaimable_dead_session(&s)); s.alive = 0;         /* alive true */
    s.child_pid = 9999;  assert(!is_reclaimable_dead_session(&s)); s.child_pid = 0;     /* child > 0 */
    s.close_pending = 1; assert(!is_reclaimable_dead_session(&s)); s.close_pending = 0; /* close_pending */
    /* reclaim_dead_session collapses a zeroed dead-leak slot (no live fds,
     * ring map is NULL so byte_ring_close is a no-op) and rejects a live one. */
    assert(reclaim_dead_session(&s) == 1);
    memset(&s, 0, sizeof(s)); s.used = 1; s.alive = 1;
    assert(reclaim_dead_session(&s) == 0);
}

static void cover_find_and_ring_path(void) {
    labpty_registry_t reg;
    labpty_registry_init(&reg, "/tmp");
    assert(labpty_registry_find(&reg, 0) == NULL);                 /* no used slot holds 0 */
    reg.sessions[3].used = 1; reg.sessions[3].handle = 42;
    assert(labpty_registry_find(&reg, 42) == &reg.sessions[3]);    /* used && handle matches */
    assert(labpty_registry_find(&reg, 99) == NULL);                /* used, handle mismatch */

    char path[LABPTY_PATH_BYTES + 1];
    assert(make_ring_path(&reg, 7, path, sizeof(path)) == LABPTY_OK);          /* n < cap */
    assert(make_ring_path(&reg, 7, path, 4) == LABPTY_E_PAYLOAD_TOO_LARGE);    /* n >= cap */
}

/* Real forked children for the reaping paths. The harness is built WITHOUT
 * -fprofile-continuous, so children that _exit() or are killed never run
 * atexit and never write to the parent's profile file. */
static pid_t fork_exiting_child(void) {
    pid_t p = fork();
    if (p == 0) _exit(0);          /* exits immediately -> reapable */
    return p;
}
static pid_t fork_stubborn_child(void) {
    pid_t p = fork();
    if (p == 0) { setpgid(0, 0); for (;;) pause(); } /* own pgroup; dies only on signal */
    return p;
}

/* wait_for_child_exit: child reaped on the first poll; a non-child returning
 * ECHILD; and a stubborn child that forces the SIGKILL escalation. */
static void cover_wait_for_child_exit(void) {
    pid_t a = fork_exiting_child();
    usleep(50000);
    assert(wait_for_child_exit(a) == 1);          /* got == child_pid */
    assert(wait_for_child_exit(999999) == 1);     /* got < 0, errno == ECHILD */
    pid_t c = fork_stubborn_child();
    usleep(50000);
    assert(wait_for_child_exit(c) == 1);          /* 20-poll loop -> SIGKILL -> reaped */
}

/* labpty_registry_reap (ReapTick): close_pending with the child already gone;
 * close_pending with a stubborn child past its SIGKILL deadline; and a natural
 * exit that becomes a dead leak. */
static void cover_reap(void) {
    labpty_registry_t reg;
    labpty_registry_init(&reg, "/tmp");

    reg.sessions[0].used = 1; reg.sessions[0].close_pending = 1; reg.sessions[0].child_pid = 0;
    labpty_registry_reap(&reg);
    assert(reg.sessions[0].used == 0);            /* close_pending + child gone -> freed */

    pid_t c = fork_stubborn_child();
    usleep(50000);
    reg.sessions[1].used = 1; reg.sessions[1].close_pending = 1;
    reg.sessions[1].child_pid = c; reg.sessions[1].terminate_deadline_ns = 1; /* long past */
    for (int i = 0; i < 300 && reg.sessions[1].used; i++) {
        labpty_registry_reap(&reg);               /* deadline elapsed -> SIGKILL, then reap */
        if (reg.sessions[1].used) usleep(10000);
    }
    assert(reg.sessions[1].used == 0);

    pid_t d = fork_exiting_child();
    usleep(50000);
    reg.sessions[2].used = 1; reg.sessions[2].alive = 1;
    reg.sessions[2].close_pending = 0; reg.sessions[2].child_pid = d;
    labpty_registry_reap(&reg);                   /* natural exit -> dead leak */
    assert(reg.sessions[2].used == 1 && reg.sessions[2].child_pid == 0 && reg.sessions[2].alive == 0);
    reclaim_dead_session(&reg.sessions[2]);
}

/* R1 regression: labpty_registry_reap must tear down a still-ALIVE session
 * whose pty master closed (drain_session on EOF in the degraded no-inspect
 * path) but whose child keeps running — but only AFTER a grace deadline, so a
 * child caught in its own exit() window is reaped into a dead-leak (id kept)
 * by the waitpid path instead of being force-closed. Drives: arm-on-first-
 * sight, hold within the grace window, tear-down once it elapses, the natural-
 * exit path that must NOT trip the hangup, and the stale-arming clear. */
static void cover_reap_master_hangup(void) {
    labpty_registry_t reg;
    labpty_registry_init(&reg, "/tmp");

    /* Hung-up but still running: first reap arms the grace deadline only. */
    pid_t stubborn = fork_stubborn_child();
    usleep(50000);
    labpty_session_t *s = &reg.sessions[0];
    s->used = 1; s->alive = 1; s->close_pending = 0;
    s->child_pid = stubborn; s->master_fd = -1; s->slave_inspect_fd = -1;
    snprintf(s->logical_id, sizeof(s->logical_id), "hangup");
    char path[LABPTY_PATH_BYTES + 1];
    snprintf(path, sizeof(path), "/tmp/labpty-regcov-hangup-%ld.br", (long)getpid());
    unlink(path);
    assert(labpty_byte_ring_create(path, LABPTY_MIN_OUTPUT_CAPACITY, "hangup", &s->ring) == LABPTY_OK);

    labpty_registry_reap(&reg);
    assert(s->hangup_deadline_ns != 0);              /* armed */
    assert(s->alive == 1 && s->close_pending == 0);  /* not yet torn down */

    /* Still hung up but within the grace window: no tear-down. */
    s->hangup_deadline_ns = (uint64_t)-1;            /* far future -> now < deadline */
    labpty_registry_reap(&reg);
    assert(s->alive == 1 && s->close_pending == 0);

    /* Grace elapsed and still hung up: tear down via the async close. */
    s->hangup_deadline_ns = 1;                       /* long past */
    labpty_registry_reap(&reg);
    assert(s->alive == 0);                           /* no longer falsely alive */
    assert(s->close_pending == 1);                   /* async reap armed */
    assert(s->logical_id[0] == '\0');                /* id relinquished -> reopen unblocked */

    /* Finish the stubborn child the way the event loop would (SIGKILL + reap). */
    for (int i = 0; i < 300 && reg.sessions[0].used; i++) {
        reg.sessions[0].terminate_deadline_ns = 1;
        labpty_registry_reap(&reg);
        if (reg.sessions[0].used) usleep(10000);
    }
    assert(reg.sessions[0].used == 0);
    unlink(path);

    /* A naturally-exiting child whose master also closed must NOT be torn down
     * as a hangup: reap's waitpid reaps it into a dead-leak with its id KEPT,
     * and the grace deadline is never armed. */
    pid_t exiting = fork_exiting_child();
    usleep(50000);
    labpty_session_t *d = &reg.sessions[1];
    d->used = 1; d->alive = 1; d->close_pending = 0;
    d->child_pid = exiting; d->master_fd = -1; d->slave_inspect_fd = -1;
    snprintf(d->logical_id, sizeof(d->logical_id), "natural");
    labpty_registry_reap(&reg);
    assert(d->used == 1 && d->child_pid == 0 && d->alive == 0);  /* dead-leak */
    assert(d->hangup_deadline_ns == 0);                          /* never armed */
    assert(strcmp(d->logical_id, "natural") == 0);               /* id KEPT -> reclaimable */
    reclaim_dead_session(d);

    /* A running child with a healthy master clears any stale grace arming
     * (the master_fd >= 0 / non-hangup branch). */
    pid_t healthy = fork_stubborn_child();
    usleep(50000);
    labpty_session_t *h = &reg.sessions[2];
    h->used = 1; h->alive = 1; h->close_pending = 0;
    h->child_pid = healthy; h->master_fd = 0;        /* >= 0: master present */
    h->hangup_deadline_ns = 12345;                   /* stale arming */
    labpty_registry_reap(&reg);
    assert(h->hangup_deadline_ns == 0);              /* cleared */
    assert(h->alive == 1 && h->used == 1);
    kill(healthy, SIGKILL);
    int st; waitpid(healthy, &st, 0);
    h->used = 0;
}

/* labpty_session_request_close on a child-alive session relinquishes the id
 * AND removes the shm .br dir entry immediately, while keeping the mapping
 * alive for reap's final heartbeat. Without the unlink-at-terminate the file
 * lingered on disk for the whole SIGKILL/reap window — and since a
 * close_pending session is no longer listed, the drain-to-quiescent sweep
 * could finish before reap removed it, stranding the ring file. */
static void cover_request_close_unlinks_ring_path(void) {
    labpty_session_t s;
    memset(&s, 0, sizeof(s));
    s.used = 1; s.alive = 1; s.master_fd = -1; s.slave_inspect_fd = -1;
    snprintf(s.logical_id, sizeof(s.logical_id), "regcov-unlink");
    char path[LABPTY_PATH_BYTES + 1];
    snprintf(path, sizeof(path), "/tmp/labpty-regcov-unlink-%ld.br", (long)getpid());
    unlink(path); /* defensive: no stale file from a prior aborted run */
    assert(labpty_byte_ring_create(path, LABPTY_MIN_OUTPUT_CAPACITY, "regcov", &s.ring) == LABPTY_OK);
    assert(access(path, F_OK) == 0);             /* present while the session is live */

    pid_t child = fork_stubborn_child();         /* own pgroup; child_pid > 0 */
    s.child_pid = child;
    labpty_session_request_close(&s, 1);

    assert(s.close_pending == 1);                /* child still alive -> close_pending */
    assert(s.logical_id[0] == '\0');             /* id relinquished at terminate */
    assert(access(path, F_OK) != 0);             /* .br dir entry removed now, not at reap */
    assert(s.ring.path[0] == '\0');              /* path cleared so reap won't double-unlink */
    assert(s.ring.map != NULL);                  /* mapping kept for the final heartbeat */
    labpty_byte_ring_heartbeat(&s.ring);         /* still usable on the live mapping */

    int st; waitpid(child, &st, 0);              /* request_close's SIGHUP killed it; reap */
    s.child_pid = 0;
    labpty_byte_ring_close(&s.ring);             /* munmaps; path empty -> no second unlink */
    assert(s.ring.map == NULL);
}

int main(void) {
    cover_valid_output_capacity();
    cover_make_logical_id();
    cover_is_reclaimable();
    cover_find_and_ring_path();
    cover_wait_for_child_exit();
    cover_reap();
    cover_reap_master_hangup();
    cover_request_close_unlinks_ring_path();
    return 0;
}
