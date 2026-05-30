/*
 * Deterministic assertion harness for the event loop's poll-multiplexing layer
 * (Sources/Labpty/main.c): build_poll_set / add_poll_watch / service_poll_watch.
 * This is the fd -> (kind, index) dispatch that was the last daemon layer with
 * no formal binding — and it is a data-structure CONSISTENCY invariant, not a
 * temporal state machine, so the right tool is a proof harness (the signal_cov
 * pattern), not a TLA+ trace binding.
 *
 * Two properties, both with teeth (a misrouting fault — a wrong stored index,
 * an off-by-one watch, a kind/index mismatch — fails an assertion):
 *
 *   build consistency: every watch build_poll_set emits is mutually consistent
 *     with the daemon state — the listener first; each CLIENT watch's fd/events
 *     match an in_use client at its stored index; each SESSION watch's fd
 *     matches a used master_fd>=0 session; the count is exact; and every
 *     watchable client/session is watched exactly once (no omission, no dup).
 *
 *   dispatch routing: service_poll_watch routes a slot's revents to the handler
 *     at THAT slot's stored index — a faulted CLIENT watch releases the indexed
 *     client and only that client, never a neighbour.
 *
 * Built and run (and MC/DC-merged) by scripts/coverage-labpty; check-anchors
 * rule F requires it to be wired there.
 */
#define main labpty_daemon_main_unused
#include "main.c"
#undef main

#include <assert.h>
#include <sys/socket.h>
#include <unistd.h>

int laban_pty_open(int rows, int cols, const char *const *argv,
                   const char *const *envp, const char *cwd,
                   int *out_master_fd, pid_t *out_child_pid) {
    (void)rows; (void)cols; (void)argv; (void)envp; (void)cwd;
    if (out_master_fd) *out_master_fd = -1;
    if (out_child_pid) *out_child_pid = -1;
    return -1;
}

static labpty_daemon_t d;

/* build_poll_set: the listener watch, then one POLLOUT/POLLIN watch per in_use
 * client, then one per used master_fd>=0 session — every slot consistent. */
static void cover_build_poll_set(void) {
    memset(&d, 0, sizeof(d));
    d.listen_fd = 100;
    d.clients[0].in_use = 1; d.clients[0].fd = 200;                     /* reading */
    d.clients[1].in_use = 1; d.clients[1].fd = 201;
    d.clients[1].write_total = 5; d.clients[1].write_sent = 0;          /* writing -> POLLOUT */
    /* clients[2] left free — must NOT be watched */
    d.clients[3].in_use = 1; d.clients[3].fd = 203;
    d.registry.sessions[0].used = 1; d.registry.sessions[0].master_fd = 300;
    d.registry.sessions[1].used = 1; d.registry.sessions[1].master_fd = -1; /* no master -> skipped */
    d.registry.sessions[5].used = 1; d.registry.sessions[5].master_fd = 305;

    labpty_poll_set_t ps;
    build_poll_set(&d, &ps);

    assert(ps.count == 6); /* 1 listener + 3 clients + 2 sessions */
    assert(ps.kinds[0] == LABPTY_POLL_LISTENER);
    assert(ps.fds[0].fd == 100 && ps.indexes[0] == -1 && ps.fds[0].events == POLLIN);

    int clients_seen = 0, sessions_seen = 0;
    for (nfds_t s = 1; s < ps.count; s++) {
        int idx = ps.indexes[s];
        int fd = ps.fds[s].fd;
        if (ps.kinds[s] == LABPTY_POLL_CLIENT) {
            assert(idx >= 0 && idx < LABPTY_MAX_CLIENTS);
            assert(d.clients[idx].in_use);              /* points at an in_use client */
            assert(d.clients[idx].fd == fd);            /* with that client's fd */
            int writing = d.clients[idx].write_total > d.clients[idx].write_sent;
            assert(ps.fds[s].events == (writing ? POLLOUT : POLLIN));
            clients_seen++;
        } else if (ps.kinds[s] == LABPTY_POLL_SESSION) {
            assert(idx >= 0 && idx < LABPTY_MAX_SESSIONS);
            assert(d.registry.sessions[idx].used && d.registry.sessions[idx].master_fd >= 0);
            assert(d.registry.sessions[idx].master_fd == fd);
            sessions_seen++;
        } else {
            assert(0); /* no kind other than CLIENT/SESSION past the listener */
        }
    }
    assert(clients_seen == 3 && sessions_seen == 2);

    /* completeness: every watchable client/session appears exactly once. */
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        if (!d.clients[i].in_use) continue;
        int found = 0;
        for (nfds_t s = 1; s < ps.count; s++)
            if (ps.kinds[s] == LABPTY_POLL_CLIENT && ps.indexes[s] == i) found++;
        assert(found == 1);
    }
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        if (!(d.registry.sessions[i].used && d.registry.sessions[i].master_fd >= 0)) continue;
        int found = 0;
        for (nfds_t s = 1; s < ps.count; s++)
            if (ps.kinds[s] == LABPTY_POLL_SESSION && ps.indexes[s] == i) found++;
        assert(found == 1);
    }
}

/* A connected socket whose peer is closed: read() returns 0 (EOF), so the
 * client pump returns -1 and service_client_poll asks for a release. An in_use
 * client always has a real fd (add_client sets it; client_release clears
 * in_use with it), so the routing test uses real fds, not -1. */
static int eof_fd(void) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return -1;
    close(sv[1]);
    return sv[0];
}

/* service_poll_watch routes a slot to the handler at its stored index. A
 * faulted CLIENT watch releases the indexed client; a neighbour must be
 * untouched. The listener and a non-readable session watch are exercised for
 * routing coverage. */
static void cover_service_routing(void) {
    memset(&d, 0, sizeof(d));
    int lsv[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, lsv) == 0); /* a socket, not listening */
    d.listen_fd = lsv[0];
    d.clients[2].in_use = 1; d.clients[2].fd = eof_fd();
    d.clients[4].in_use = 1; d.clients[4].fd = eof_fd();
    d.registry.sessions[0].used = 1; d.registry.sessions[0].master_fd = eof_fd();

    labpty_poll_set_t ps;
    build_poll_set(&d, &ps);

    for (nfds_t s = 0; s < ps.count; s++) {
        if (ps.kinds[s] == LABPTY_POLL_CLIENT && ps.indexes[s] == 2) {
            ps.fds[s].revents = POLLHUP;            /* faulted -> pump fails -> release */
            service_poll_watch(&d, &ps, s);
        } else if (ps.kinds[s] == LABPTY_POLL_LISTENER) {
            ps.fds[s].revents = POLLIN;             /* accept() on a non-listening fd: no-op */
            service_poll_watch(&d, &ps, s);
        } else if (ps.kinds[s] == LABPTY_POLL_SESSION) {
            ps.fds[s].revents = POLLOUT;            /* not readable -> no drain, no crash */
            service_poll_watch(&d, &ps, s);
        }
    }
    assert(d.clients[2].in_use == 0);  /* the faulted watch released client 2 */
    assert(d.clients[4].in_use == 1);  /* its neighbour was not misrouted */

    /* a slot with revents == 0 is a no-op (the early return). */
    memset(&d, 0, sizeof(d));
    int rsv[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, rsv) == 0);
    d.listen_fd = rsv[0];
    d.clients[1].in_use = 1; d.clients[1].fd = eof_fd();
    build_poll_set(&d, &ps);
    for (nfds_t s = 0; s < ps.count; s++) { ps.fds[s].revents = 0; service_poll_watch(&d, &ps, s); }
    assert(d.clients[1].in_use == 1);  /* nothing ready -> nothing serviced */
}

int main(void) {
    cover_build_poll_set();
    cover_service_routing();
    return 0;
}
