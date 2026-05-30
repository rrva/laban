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

int main(void) {
    cover_valid_output_capacity();
    cover_make_logical_id();
    cover_is_reclaimable();
    cover_find_and_ring_path();
    return 0;
}
