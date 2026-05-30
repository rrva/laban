/*
 * Deterministic MC/DC coverage harness for decision functions in
 * Sources/Labpty/main.c. Companion to registry_cov.c; see that file and
 * docs/quality/labpty-mcdc-coverage.md for why integration tests can't do this.
 *
 * main.c is #included (with its main() renamed out of the way) so the harness
 * can reach its static decision helpers, then driven with crafted state. Only
 * side-effect-free vectors are exercised — clients carry fd = -1 so the expiry
 * teardown touches no real descriptors, and no signals or syscalls on live
 * resources are issued.
 */
#define main labpty_daemon_main_unused
#include "main.c"
#undef main

#include <assert.h>
#include <termios.h>

/* Referenced by labpty_registry_open (a separate TU); never called here. */
int laban_pty_open(int rows, int cols, const char *const *argv,
                   const char *const *envp, const char *cwd,
                   int *out_master_fd, pid_t *out_child_pid) {
    (void)rows; (void)cols; (void)argv; (void)envp; (void)cwd;
    if (out_master_fd) *out_master_fd = -1;
    if (out_child_pid) *out_child_pid = -1;
    return -1;
}

static labpty_daemon_t cov_daemon; /* ~2 MB — static, not on the stack */

/* '\n' || VEOL || VEOL2 || VEOF, each guarded by `cc != _POSIX_VDISABLE`. */
static void cover_is_canonical_delimiter(void) {
    struct termios t;
    memset(&t, 0, sizeof(t));
    for (int i = 0; i < NCCS; i++) t.c_cc[i] = (cc_t)_POSIX_VDISABLE;
    assert(is_canonical_delimiter((uint8_t)'\n', &t) == 1); /* byte == '\n' */
    assert(is_canonical_delimiter((uint8_t)'a', &t) == 0);  /* '\n' false; every cc disabled */
    t.c_cc[VEOL] = (cc_t)'@';
    assert(is_canonical_delimiter((uint8_t)'@', &t) == 1);  /* VEOL set and matches */
    assert(is_canonical_delimiter((uint8_t)'#', &t) == 0);  /* VEOL set, byte differs */
    t.c_cc[VEOL] = (cc_t)_POSIX_VDISABLE;
#ifdef VEOL2
    t.c_cc[VEOL2] = (cc_t)'%';
    assert(is_canonical_delimiter((uint8_t)'%', &t) == 1);  /* VEOL2 set and matches */
    assert(is_canonical_delimiter((uint8_t)'&', &t) == 0);  /* VEOL2 set, byte differs */
    t.c_cc[VEOL2] = (cc_t)_POSIX_VDISABLE;
#endif
    t.c_cc[VEOF] = (cc_t)'^';
    assert(is_canonical_delimiter((uint8_t)'^', &t) == 1);  /* VEOF set and matches */
    assert(is_canonical_delimiter((uint8_t)'*', &t) == 0);  /* VEOF set, byte differs */
}

static void set_client(labpty_client_t *c, int in_use, int established,
                       uint64_t deadline, uint64_t frame_deadline,
                       size_t read_have, size_t write_total) {
    memset(c, 0, sizeof(*c));
    c->fd = -1;
    c->in_use = in_use;
    c->established = established;
    c->deadline_ns = deadline;
    c->frame_deadline_ns = frame_deadline;
    c->read_have = read_have;
    c->write_total = write_total;
}

/* Drive every branch of expire_stalled_clients: frame deadline, idle deadline,
 * established-with-pending-frame, established-idle (kept), unestablished. */
static void cover_expire_stalled_clients(void) {
    uint64_t now = monotonic_ns();
    uint64_t past = now > 1000000ull ? now - 1000000ull : 1ull;
    uint64_t future = now + 1000000000000ull;
    memset(&cov_daemon, 0, sizeof(cov_daemon));
    set_client(&cov_daemon.clients[0], 0, 0, 0, 0, 0, 0);            /* not in_use: skipped */
    set_client(&cov_daemon.clients[1], 1, 1, future, past, 0, 0);    /* frame deadline passed */
    set_client(&cov_daemon.clients[2], 1, 1, past, 0, 0, 0);         /* idle, established, no pending: kept */
    set_client(&cov_daemon.clients[3], 1, 1, past, 0, 5, 0);         /* idle, established, pending: released */
    set_client(&cov_daemon.clients[4], 1, 0, past, 0, 0, 0);         /* idle, unestablished: released */
    set_client(&cov_daemon.clients[5], 1, 1, future, 0, 0, 0);       /* not yet at idle deadline: kept */
    set_client(&cov_daemon.clients[6], 1, 1, past, 0, 0, 7);         /* idle, established, write pending: released */
    set_client(&cov_daemon.clients[7], 1, 0, future, past, 0, 0);    /* frame deadline passed, unestablished: released */
    expire_stalled_clients(&cov_daemon);
}

int main(void) {
    cover_is_canonical_delimiter();
    cover_expire_stalled_clients();
    return 0;
}
