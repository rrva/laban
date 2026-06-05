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
#include <util.h> /* openpty */

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

/* (--socket && has-value), (--shm-dir && has-value), (socket && shm set). */
static void cover_parse_args(void) {
    char sock[LABPTY_PATH_BYTES + 1], shm[LABPTY_PATH_BYTES + 1];
    char *ok[]          = { "labpty", "--socket", "/s", "--shm-dir", "/d" };
    char *unknown[]     = { "labpty", "--bogus" };
    char *no_sock_val[] = { "labpty", "--socket" };
    char *no_shm_val[]  = { "labpty", "--socket", "/s", "--shm-dir" };
    char *only_sock[]   = { "labpty", "--socket", "/s" };
    assert(parse_args(5, ok, sock, shm) == 0);            /* both flags + values */
    assert(parse_args(2, unknown, sock, shm) == -1);      /* unknown flag */
    assert(parse_args(2, no_sock_val, sock, shm) == -1);  /* --socket without value */
    assert(parse_args(4, no_shm_val, sock, shm) == -1);   /* --shm-dir without value */
    assert(parse_args(3, only_sock, sock, shm) == -1);    /* socket set, shm-dir empty */
}

static void cover_maintenance_due_after_poll(void) {
    unsigned ready_ticks = 12;
    uint64_t next = 0;
    /* Idle (poll timed out): always due, counter and floor reset. */
    assert(maintenance_due_after_poll(0, 1000, &ready_ticks, &next) == 1);
    assert(ready_ticks == 0);
    assert(next == 1000 + LABPTY_MAINTENANCE_INTERVAL_NS);
    /* Poll error: never due, counter untouched. */
    assert(maintenance_due_after_poll(-1, 2000, &ready_ticks, &next) == 0);
    assert(ready_ticks == 0);

    /* Ready-iteration budget path in isolation: pin `now` below the floor so
     * only the 64-iteration budget can fire maintenance. */
    ready_ticks = 0;
    next = 0;
    assert(maintenance_due_after_poll(1, 0, &ready_ticks, &next) == 1); /* now(0) >= next(0) */
    assert(ready_ticks == 0);
    /* next is now the floor; hold `now` at 1 so the floor never trips. */
    for (unsigned i = 1; i < LABPTY_MAINTENANCE_READY_BUDGET; i++) {
        assert(maintenance_due_after_poll(1, 1, &ready_ticks, &next) == 0);
        assert(ready_ticks == i);
    }
    assert(maintenance_due_after_poll(1, 1, &ready_ticks, &next) == 1);
    assert(ready_ticks == 0);

    /* Wall-clock floor path: continuous readiness, counter far below the
     * budget, but the maintenance interval has elapsed — maintenance must
     * still fire. This is the slowloris / SIGKILL-deadline regression guard
     * that the pure ready-count gate cannot provide. */
    ready_ticks = 0;
    next = 0;
    assert(maintenance_due_after_poll(1, 0, &ready_ticks, &next) == 1); /* primes the floor */
    uint64_t floor = next;
    assert(floor == LABPTY_MAINTENANCE_INTERVAL_NS);
    /* One tick below the floor, only the 2nd ready iteration: withheld. */
    assert(maintenance_due_after_poll(1, floor - 1, &ready_ticks, &next) == 0);
    assert(ready_ticks == 1);
    /* At the floor, still only a handful of ready iterations: due anyway. */
    assert(maintenance_due_after_poll(1, floor, &ready_ticks, &next) == 1);
    assert(ready_ticks == 0);
    assert(next == floor + LABPTY_MAINTENANCE_INTERVAL_NS);
}

static size_t build_handle_payload(uint8_t *buf, size_t cap, uint64_t handle) {
    labpty_writer_t w = { buf, buf + cap };
    labpty_write_u64(&w, handle);
    return (size_t)(w.cur - buf);
}

static size_t build_park_payload(uint8_t *buf, size_t cap,
                                 const uint64_t *handles,
                                 const uint64_t *offsets,
                                 uint32_t count) {
    labpty_writer_t w = { buf, buf + cap };
    labpty_write_u32(&w, count);
    for (uint32_t i = 0; i < count; i++) {
        labpty_write_u64(&w, handles[i]);
        labpty_write_u64(&w, offsets[i]);
    }
    return (size_t)(w.cur - buf);
}

static size_t build_resize_payload(uint8_t *buf, size_t cap, uint64_t handle,
                                   uint32_t rows, uint32_t cols) {
    labpty_writer_t w = { buf, buf + cap };
    labpty_write_u64(&w, handle);
    labpty_write_u32(&w, rows);
    labpty_write_u32(&w, cols);
    return (size_t)(w.cur - buf);
}

/* handle_attach/detach/resize: session found-and-alive / missing / not-alive.
 * master_fd = -1 makes resize's ioctl fail deterministically (no real pty). */
static void cover_handlers(void) {
    memset(&cov_daemon, 0, sizeof(cov_daemon));
    cov_daemon.registry.next_handle = 200;
    labpty_session_t *s = &cov_daemon.registry.sessions[0];
    s->used = 1; s->alive = 1; s->handle = 100; s->master_fd = -1;
    s->rows = 24; s->cols = 80;
    snprintf(s->logical_id, sizeof(s->logical_id), "cov");
    snprintf(s->ring.path, sizeof(s->ring.path), "/tmp/cov.br");
    s->ring.output_capacity = LABPTY_MIN_OUTPUT_CAPACITY;
    labpty_client_t *c = &cov_daemon.clients[0];
    c->fd = -1; c->in_use = 1;

    uint8_t pay[64], out[512];
    size_t out_len = 0, n;

    n = build_handle_payload(pay, sizeof(pay), 100);
    assert(handle_attach(&cov_daemon, c, pay, n, out, sizeof(out), &out_len) == LABPTY_OK);
    n = build_handle_payload(pay, sizeof(pay), 999);
    assert(handle_attach(&cov_daemon, c, pay, n, out, sizeof(out), &out_len) == LABPTY_E_SESSION_NOT_FOUND);
    s->alive = 0;
    n = build_handle_payload(pay, sizeof(pay), 100);
    assert(handle_attach(&cov_daemon, c, pay, n, out, sizeof(out), &out_len) == LABPTY_E_SESSION_NOT_FOUND);
    s->alive = 1;

    n = build_handle_payload(pay, sizeof(pay), 100);
    assert(handle_detach(&cov_daemon, c, pay, n, out, sizeof(out), &out_len) == LABPTY_OK);
    n = build_handle_payload(pay, sizeof(pay), 999);
    assert(handle_detach(&cov_daemon, c, pay, n, out, sizeof(out), &out_len) == LABPTY_E_SESSION_NOT_FOUND);

    n = build_resize_payload(pay, sizeof(pay), 100, 30, 100);
    /* master_fd < 0: the child hung up before the reap tick flipped alive;
     * handle_resize reports SESSION_NOT_FOUND rather than ioctl(-1) -> INTERNAL
     * (L2, commit 00d5865). */
    assert(handle_resize(&cov_daemon, pay, n, out, sizeof(out), &out_len) == LABPTY_E_SESSION_NOT_FOUND);
    n = build_resize_payload(pay, sizeof(pay), 999, 30, 100);
    assert(handle_resize(&cov_daemon, pay, n, out, sizeof(out), &out_len) == LABPTY_E_SESSION_NOT_FOUND);
    s->alive = 0;
    n = build_resize_payload(pay, sizeof(pay), 100, 30, 100);
    assert(handle_resize(&cov_daemon, pay, n, out, sizeof(out), &out_len) == LABPTY_E_SESSION_NOT_FOUND);
}

/* dispatch_frame's op router + the pre-hello negotiation gate. An empty
 * payload (frame_len == header size) makes every stateful handler bail at its
 * decode before any signal or syscall, so the routing is covered safely. */
static void cover_dispatch_frame(void) {
    memset(&cov_daemon, 0, sizeof(cov_daemon));
    cov_daemon.registry.next_handle = 1;
    labpty_client_t *c = &cov_daemon.clients[0];
    uint16_t ops[] = {
        LABPTY_OP_HELLO, LABPTY_OP_OPEN_SESSION, LABPTY_OP_LIST_SESSIONS,
        LABPTY_OP_RESIZE_SESSION, LABPTY_OP_SIGNAL_SESSION, LABPTY_OP_TERMINATE_SESSION,
        LABPTY_OP_WRITE_INPUT, LABPTY_OP_PING, LABPTY_OP_ATTACH_SESSION,
        LABPTY_OP_DETACH_SESSION, LABPTY_OP_OPEN_OUTPUT_WAKE,
        LABPTY_OP_PARK_OUTPUT_WAKE,
        (uint16_t)0xBEEF /* unknown op */
    };
    for (size_t i = 0; i < sizeof(ops) / sizeof(ops[0]); i++) {
        memset(c, 0, sizeof(*c));
        c->fd = -1; c->in_use = 1; c->negotiated = 1;
        c->header.op = ops[i];
        c->header.frame_len = LABPTY_FRAME_HEADER_BYTES; /* empty payload */
        size_t out_len = 0;
        (void)dispatch_frame(&cov_daemon, c, &out_len);
    }
    /* negotiation gate: a non-hello op before hello must be rejected. */
    memset(c, 0, sizeof(*c));
    c->fd = -1; c->in_use = 1; c->negotiated = 0;
    c->header.op = LABPTY_OP_PING;
    c->header.frame_len = LABPTY_FRAME_HEADER_BYTES;
    size_t out_len = 0;
    assert(dispatch_frame(&cov_daemon, c, &out_len) == LABPTY_E_CAPABILITY_REQUIRED);
}

/* poll_revents_* predicates and service_client_poll's write/read/fault routing.
 * fd = -1 makes the underlying client_pump_read/write return -1 harmlessly. */
static void cover_poll_dispatch(void) {
    assert(poll_revents_readable(POLLIN) != 0);
    assert(poll_revents_readable(0) == 0);
    assert(poll_revents_faulted(POLLHUP) != 0);
    assert(poll_revents_faulted(0) == 0);

    memset(&cov_daemon, 0, sizeof(cov_daemon));
    labpty_client_t *c = &cov_daemon.clients[0];
    c->fd = -1; c->in_use = 1;
    c->write_total = 10; c->write_sent = 0;
    (void)service_client_poll(&cov_daemon, 0, POLLOUT);  /* writing && POLLOUT */
    c->write_total = 0;  c->write_sent = 0;
    (void)service_client_poll(&cov_daemon, 0, POLLIN);   /* !writing && readable */
    c->write_total = 10; c->write_sent = 0;
    (void)service_client_poll(&cov_daemon, 0, POLLERR);  /* neither -> faulted */
    c->write_total = 0; c->write_sent = 0;
    c->output_wake = 1; c->wake_armed = 1; c->wake_pending = 1;
    cov_daemon.output_wake_armed_count = 1;
    (void)service_client_poll(&cov_daemon, 0, POLLOUT);  /* wake pending flush */
    c->wake_pending = 0;
    (void)service_client_poll(&cov_daemon, 0, POLLIN);   /* wake peer sent data */
    c->in_use = 0;
    (void)service_client_poll(&cov_daemon, 0, POLLIN);   /* not in_use -> 0 */
}

static void set_client_id(labpty_client_t *client, const char *client_id) {
    snprintf(client->client_id, sizeof(client->client_id), "%s", client_id);
}

static void cover_output_wake_paths(void) {
    memset(&cov_daemon, 0, sizeof(cov_daemon));
    labpty_client_t *match = &cov_daemon.clients[0];
    match->fd = -1;
    match->in_use = 1;
    match->output_wake = 1;
    set_client_id(match, "client-a");

    labpty_client_t inactive = {0};
    inactive.fd = -1;
    assert(client_id_matches(&inactive, "client-a") == 0);       /* !in_use */
    inactive.in_use = 1;
    assert(client_id_matches(&inactive, "client-a") == 0);       /* empty id */
    set_client_id(&inactive, "client-b");
    assert(client_id_matches(&inactive, "client-a") == 0);       /* strcmp false */
    assert(client_id_matches(match, "client-a") == 1);           /* all true */

    labpty_session_t *session = &cov_daemon.registry.sessions[0];
    session->used = 1;
    session->alive = 1;
    session->handle = 100;
    session->attached_clients = 0;
    assert(session_has_attached_client_id(&cov_daemon, session, "client-a") == 0);
    session->attached_clients = (uint8_t)(1u << 1);
    cov_daemon.clients[1].fd = -1;
    cov_daemon.clients[1].in_use = 1;
    cov_daemon.clients[1].output_wake = 1;
    set_client_id(&cov_daemon.clients[1], "client-b");
    assert(session_has_attached_client_id(&cov_daemon, session, "client-a") == 0);
    session->attached_clients |= (uint8_t)(1u << 0);
    assert(session_has_attached_client_id(&cov_daemon, session, "client-a") == 1);

    memset(cov_daemon.clients, 0, sizeof(cov_daemon.clients));
    cov_daemon.output_wake_armed_count = 0;
    cov_daemon.clients[0].fd = -1; /* !in_use */
    cov_daemon.clients[1].fd = -1; cov_daemon.clients[1].in_use = 1; set_client_id(&cov_daemon.clients[1], "client-a"); /* !output_wake */
    cov_daemon.clients[2].fd = -1; cov_daemon.clients[2].in_use = 1; cov_daemon.clients[2].output_wake = 1; set_client_id(&cov_daemon.clients[2], "client-b");
    cov_daemon.clients[3].fd = -1; cov_daemon.clients[3].in_use = 1; cov_daemon.clients[3].output_wake = 1; cov_daemon.clients[3].wake_armed = 1; set_client_id(&cov_daemon.clients[3], "client-a");
    cov_daemon.clients[4].fd = -1; cov_daemon.clients[4].in_use = 1; cov_daemon.clients[4].output_wake = 1; set_client_id(&cov_daemon.clients[4], "client-a");
    cov_daemon.output_wake_armed_count = 1;
    arm_output_wake_clients(&cov_daemon, "client-a");
    assert(cov_daemon.clients[4].wake_armed == 1);
    assert(cov_daemon.output_wake_armed_count == 2);

    labpty_client_t queue_client = {0};
    queue_client.fd = -1;
    queue_client.wake_pending = 1;
    assert(queue_output_wake(&queue_client) == 0);
    queue_client.wake_pending = 0;
    queue_client.write_total = 8;
    queue_client.write_sent = 3;
    assert(queue_output_wake(&queue_client) == 0 && queue_client.wake_pending == 1);
    queue_client.write_total = 0;
    queue_client.write_sent = 0;
    queue_client.wake_pending = 0;
    assert(queue_output_wake(&queue_client) == -1);

    int queue_pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, queue_pair) == 0);
    queue_client.fd = queue_pair[0];
    assert(queue_output_wake(&queue_client) == 0);
    uint8_t queue_byte = 0;
    assert(read(queue_pair[1], &queue_byte, 1) == 1 && queue_byte == 1);
    close(queue_pair[0]);
    close(queue_pair[1]);

    labpty_client_t flush_client = {0};
    flush_client.fd = -1;
    assert(flush_output_wake(&flush_client) == 0);       /* !wake_pending */
    flush_client.wake_pending = 1;
    assert(flush_output_wake(&flush_client) == -1);      /* hard write error */
    int flush_pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, flush_pair) == 0);
    flush_client.fd = flush_pair[0];
    flush_client.wake_pending = 1;
    assert(flush_output_wake(&flush_client) == 0 && flush_client.wake_pending == 0);
    assert(read(flush_pair[1], &queue_byte, 1) == 1 && queue_byte == 1);
    close(flush_pair[0]);
    close(flush_pair[1]);

    memset(&cov_daemon, 0, sizeof(cov_daemon));
    session = &cov_daemon.registry.sessions[0];
    session->used = 1;
    session->alive = 1;
    session->handle = 100;
    session->attached_clients = (uint8_t)(1u << 3);
    cov_daemon.output_wake_armed_count = 1;
    cov_daemon.clients[0].fd = -1; /* !in_use */
    cov_daemon.clients[1].fd = -1; cov_daemon.clients[1].in_use = 1; /* !output_wake */
    cov_daemon.clients[2].fd = -1; cov_daemon.clients[2].in_use = 1; cov_daemon.clients[2].output_wake = 1; /* empty id */
    cov_daemon.clients[3].fd = -1; cov_daemon.clients[3].in_use = 1; cov_daemon.clients[3].output_wake = 1; set_client_id(&cov_daemon.clients[3], "client-a"); /* !wake_armed */
    cov_daemon.clients[4].fd = -1; cov_daemon.clients[4].in_use = 1; cov_daemon.clients[4].output_wake = 1; cov_daemon.clients[4].wake_armed = 1; set_client_id(&cov_daemon.clients[4], "client-b"); /* attached but id mismatch */
    notify_output_wake_clients(&cov_daemon, session);
    assert(cov_daemon.clients[4].wake_armed == 1);
    assert(cov_daemon.output_wake_armed_count == 1);

    int wake_pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, wake_pair) == 0);
    memset(&cov_daemon, 0, sizeof(cov_daemon));
    session = &cov_daemon.registry.sessions[0];
    session->used = 1;
    session->alive = 1;
    session->handle = 100;
    session->attached_clients = (uint8_t)(1u << 0);
    match = &cov_daemon.clients[0];
    match->fd = wake_pair[0];
    match->in_use = 1;
    match->output_wake = 1;
    match->wake_armed = 1;
    set_client_id(match, "client-a");
    cov_daemon.output_wake_armed_count = 1;
    notify_output_wake_clients(&cov_daemon, session);
    assert(match->wake_armed == 0);
    assert(cov_daemon.output_wake_armed_count == 0);
    uint8_t wake_byte = 0;
    assert(read(wake_pair[1], &wake_byte, 1) == 1 && wake_byte == 1);
    close(wake_pair[0]);
    close(wake_pair[1]);

    memset(&cov_daemon, 0, sizeof(cov_daemon));
    session = &cov_daemon.registry.sessions[0];
    session->used = 1;
    session->alive = 1;
    session->handle = 100;
    session->attached_clients = (uint8_t)(1u << 0);
    match = &cov_daemon.clients[0];
    match->fd = -1;
    match->in_use = 1;
    match->output_wake = 1;
    match->wake_armed = 1;
    match->wake_pending = 1;
    set_client_id(match, "client-a");
    cov_daemon.output_wake_armed_count = 1;
    notify_output_wake_clients(&cov_daemon, session);
    assert(match->in_use == 1 && match->wake_pending == 1);       /* pending suppresses write */

    memset(&cov_daemon, 0, sizeof(cov_daemon));
    labpty_client_t *client = &cov_daemon.clients[0];
    client->fd = -1;
    client->in_use = 1;
    client->supports_output_wake = 1;
    client->output_wake = 1;
    set_client_id(client, "client-a");
    cov_daemon.registry.sessions[0].used = 1;
    cov_daemon.registry.sessions[0].alive = 1;
    cov_daemon.registry.sessions[0].handle = 100;
    cov_daemon.registry.sessions[0].ring.output_offset = 7;
    cov_daemon.registry.sessions[1].used = 1;
    cov_daemon.registry.sessions[1].alive = 0;
    cov_daemon.registry.sessions[1].handle = 101;
    cov_daemon.registry.sessions[1].ring.output_offset = 9;
    uint8_t pay[64], out[16];
    size_t out_len = 0;
    uint64_t handles[1] = {100};
    uint64_t offsets[1] = {7};
    size_t n = build_park_payload(pay, sizeof(pay), handles, offsets, 1);
    assert(handle_park_output_wake(&cov_daemon, client, pay, n, out, sizeof(out), &out_len) == LABPTY_OK);
    assert(out_len == 1 && out[0] == 1);
    assert((cov_daemon.registry.sessions[0].attached_clients & 1u) != 0);

    handles[0] = 101; offsets[0] = 9;
    n = build_park_payload(pay, sizeof(pay), handles, offsets, 1);
    assert(handle_park_output_wake(&cov_daemon, client, pay, n, out, sizeof(out), &out_len) == LABPTY_OK);
    assert(out_len == 1 && out[0] == 1);
    assert((cov_daemon.registry.sessions[1].attached_clients & 1u) == 0); /* found but !alive */

    handles[0] = 100; offsets[0] = 99;
    n = build_park_payload(pay, sizeof(pay), handles, offsets, 1);
    assert(handle_park_output_wake(&cov_daemon, client, pay, n, out, sizeof(out), &out_len) == LABPTY_OK);
    assert(out_len == 1 && out[0] == 0);                /* offset changed: not parked */

    handles[0] = 999; offsets[0] = 0;
    n = build_park_payload(pay, sizeof(pay), handles, offsets, 1);
    assert(handle_park_output_wake(&cov_daemon, client, pay, n, out, sizeof(out), &out_len) == LABPTY_E_SESSION_NOT_FOUND);
}

static char cov_temp_dir[] = "/tmp/labpty-main-cov.XXXXXX";
static int cov_temp_ready = 0;

static void ensure_cov_temp_dir(void) {
    if (!cov_temp_ready) {
        assert(mkdtemp(cov_temp_dir) != NULL);
        cov_temp_ready = 1;
    }
}

static void init_drain_session(labpty_session_t *s, int fd, const char *name) {
    ensure_cov_temp_dir();
    memset(&cov_daemon, 0, sizeof(cov_daemon));
    memset(s, 0, sizeof(*s));
    s->used = 1;
    s->alive = 1;
    s->master_fd = fd;
    s->slave_inspect_fd = -1;
    char path[LABPTY_PATH_BYTES + 1];
    snprintf(path, sizeof(path), "%s/%s.br", cov_temp_dir, name);
    assert(labpty_byte_ring_create(path, LABPTY_MIN_OUTPUT_CAPACITY, name, &s->ring) == LABPTY_OK);
}

static void close_drain_session(labpty_session_t *s) {
    if (s->master_fd >= 0) close(s->master_fd);
    labpty_byte_ring_close(&s->ring);
}

static void set_fd_nonblock_cov(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    assert(flags >= 0);
    assert(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0);
}

static void cover_drain_session(void) {
    labpty_session_t s;

    int empty_pipe[2];
    assert(pipe(empty_pipe) == 0);
    set_fd_nonblock_cov(empty_pipe[0]);
    init_drain_session(&s, empty_pipe[0], "drain-empty");
    drain_session(&cov_daemon, &s);
    assert(s.master_fd == empty_pipe[0]);          /* EAGAIN before any output: stay open */
    assert(s.ring.output_offset == 0);
    close(empty_pipe[1]);
    close_drain_session(&s);

    int data_pipe[2];
    assert(pipe(data_pipe) == 0);
    set_fd_nonblock_cov(data_pipe[0]);
    const char payload[] = "pty-drain";
    assert(write(data_pipe[1], payload, sizeof(payload) - 1) == (ssize_t)(sizeof(payload) - 1));
    init_drain_session(&s, data_pipe[0], "drain-data");
    drain_session(&cov_daemon, &s);
    assert(s.master_fd == data_pipe[0]);           /* data then EAGAIN/yield: stay open */
    assert(s.ring.output_offset == sizeof(payload) - 1);
    close(data_pipe[1]);
    close_drain_session(&s);

    int eof_pipe[2];
    assert(pipe(eof_pipe) == 0);
    close(eof_pipe[1]);
    init_drain_session(&s, eof_pipe[0], "drain-eof");
    drain_session(&cov_daemon, &s);
    assert(s.master_fd == -1);                     /* EOF closes the dead master */
    labpty_byte_ring_close(&s.ring);

    char file_path[LABPTY_PATH_BYTES + 1];
    ensure_cov_temp_dir();
    snprintf(file_path, sizeof(file_path), "%s/drain-budget.bin", cov_temp_dir);
    int file_fd = open(file_path, O_CREAT | O_RDWR | O_TRUNC, 0600);
    assert(file_fd >= 0);
    uint8_t block[4096];
    memset(block, 'x', sizeof(block));
    for (size_t written = 0; written < LABPTY_SESSION_DRAIN_BYTE_BUDGET + sizeof(block); written += sizeof(block)) {
        assert(write(file_fd, block, sizeof(block)) == (ssize_t)sizeof(block));
    }
    assert(lseek(file_fd, 0, SEEK_SET) == 0);
    init_drain_session(&s, file_fd, "drain-budget");
    drain_session(&cov_daemon, &s);
    assert(s.master_fd == file_fd);                /* byte budget, not EOF, stops the burst */
    assert(s.ring.output_offset == LABPTY_SESSION_DRAIN_BYTE_BUDGET);
    close_drain_session(&s);
    unlink(file_path);
}

static size_t build_write_payload(uint8_t *buf, size_t cap, uint64_t handle,
                                  const uint8_t *data, size_t dlen) {
    labpty_writer_t w = { buf, buf + cap };
    labpty_write_u64(&w, handle);
    labpty_write_u32(&w, (uint32_t)dlen);
    if (dlen) labpty_write_bytes(&w, data, dlen);
    return (size_t)(w.cur - buf);
}

/* handle_write's session lookup and the ADR-0008 canonical backpressure
 * preflight. A real openpty pair gives the slave-inspect fd the preflight
 * needs (tcgetattr/FIONREAD/fpathconf); backpressure is forced by pre-seeding
 * canonical_pending_estimate rather than writing a huge payload. */
static void cover_handle_write(void) {
    memset(&cov_daemon, 0, sizeof(cov_daemon));
    cov_daemon.registry.next_handle = 1;
    labpty_session_t *s = &cov_daemon.registry.sessions[0];
    s->used = 1; s->alive = 1; s->handle = 100;
    s->master_fd = -1; s->slave_inspect_fd = -1;
    uint8_t pay[256];
    size_t n;

    n = build_write_payload(pay, sizeof(pay), 999, (const uint8_t *)"x", 1);
    assert(handle_write(&cov_daemon, pay, n) == LABPTY_E_SESSION_NOT_FOUND); /* no session */
    s->alive = 0;
    n = build_write_payload(pay, sizeof(pay), 100, (const uint8_t *)"x", 1);
    assert(handle_write(&cov_daemon, pay, n) == LABPTY_E_SESSION_NOT_FOUND); /* not alive */
    s->alive = 1;

    /* master_fd < 0: the child hung up before the reap tick flipped alive;
     * handle_write reports SESSION_NOT_FOUND rather than EBADF -> INTERNAL
     * (L2, commit 00d5865). */
    n = build_write_payload(pay, sizeof(pay), 100, (const uint8_t *)"x", 1);
    assert(handle_write(&cov_daemon, pay, n) == LABPTY_E_SESSION_NOT_FOUND);

    int master = -1, slave = -1;
    if (openpty(&master, &slave, NULL, NULL, NULL) == 0) {
        s->master_fd = master;
        s->slave_inspect_fd = slave; /* default termios is canonical (ICANON) */

        n = build_write_payload(pay, sizeof(pay), 100, (const uint8_t *)"hi", 2);
        assert(handle_write(&cov_daemon, pay, n) == LABPTY_OK);              /* canonical, no delimiter */
        n = build_write_payload(pay, sizeof(pay), 100, (const uint8_t *)"a\n", 2);
        assert(handle_write(&cov_daemon, pay, n) == LABPTY_OK);              /* canonical, delimiter */

        s->canonical_pending_estimate = 1000000; /* exceeds any limit -> admissible 0 */
        n = build_write_payload(pay, sizeof(pay), 100, (const uint8_t *)"x", 1);
        assert(handle_write(&cov_daemon, pay, n) == LABPTY_E_INPUT_BACKPRESSURE); /* over budget */
        s->canonical_pending_estimate = 0;

        struct termios raw;
        if (tcgetattr(slave, &raw) == 0) {
            raw.c_lflag &= (tcflag_t)~ICANON;
            tcsetattr(slave, TCSANOW, &raw);
            n = build_write_payload(pay, sizeof(pay), 100, (const uint8_t *)"r", 1);
            assert(handle_write(&cov_daemon, pay, n) == LABPTY_OK);          /* raw: preflight skipped */
        }
        close(master);
        close(slave);
    }
    s->master_fd = -1; s->slave_inspect_fd = -1;
}

/* A close_pending teardown session relinquishes its logical_id (set to "").
 * encode_list_payload must omit such identity-less sessions: the app keys its
 * tab-metadata dictionary by logical_id, and two concurrently-terminating
 * HUP-ignoring children would otherwise emit two "" descriptors and trap the
 * uniqueKeysWithValues initializer. */
static void cover_list_payload_skips_identityless(void) {
    memset(&cov_daemon, 0, sizeof(cov_daemon));
    labpty_registry_t *reg = &cov_daemon.registry;

    reg->sessions[0].used = 1;
    reg->sessions[0].alive = 0;
    reg->sessions[0].handle = 10;
    reg->sessions[0].logical_id[0] = '\0'; /* relinquished id, close_pending */

    reg->sessions[1].used = 1;
    reg->sessions[1].alive = 0;
    reg->sessions[1].handle = 11;
    reg->sessions[1].logical_id[0] = '\0'; /* a second relinquished id */

    reg->sessions[2].used = 1;
    reg->sessions[2].alive = 1;
    reg->sessions[2].handle = 12;
    snprintf(reg->sessions[2].logical_id, sizeof(reg->sessions[2].logical_id), "live-id");

    uint8_t buf[4096];
    size_t n = encode_list_payload(reg, buf, sizeof(buf));
    assert(n >= 4);
    labpty_reader_t reader = { buf, buf + n };
    uint32_t count = 0;
    assert(labpty_read_u32(&reader, &count) == LABPTY_OK);
    assert(count == 1); /* only the identity-bearing session is listed */

    /* No empty ids and no duplicate ids survive in the encoded list. */
    for (uint32_t i = 0; i < count; i++) {
        uint32_t record_len = 0;
        assert(labpty_read_u32(&reader, &record_len) == LABPTY_OK);
        uint64_t handle = 0; int32_t pid = 0; uint32_t rows = 0, cols = 0; uint8_t alive = 0;
        assert(labpty_read_u64(&reader, &handle) == LABPTY_OK);
        assert(labpty_read_i32(&reader, &pid) == LABPTY_OK);
        assert(labpty_read_u32(&reader, &rows) == LABPTY_OK);
        assert(labpty_read_u32(&reader, &cols) == LABPTY_OK);
        assert(labpty_read_u8(&reader, &alive) == LABPTY_OK);
        uint32_t id_len = 0;
        assert(labpty_read_u32(&reader, &id_len) == LABPTY_OK);
        assert(id_len > 0); /* never an empty logical id */
        reader.cur += id_len;
    }
}

/* Regression: handle_terminate's dead-leak branch must close the pty master.
 * A naturally-exited session that reap left as a dead-leak (used=1, alive=0,
 * child_pid=0, ring still open) still owns its master fd. The branch closed
 * the inspect fd and the ring but skipped the master, so terminating such a
 * session leaked one /dev/ptmx fd whenever terminate beat drain_session to the
 * slot — an unbounded fd leak under churn. */
static void cover_terminate_deadleak_closes_master(void) {
    ensure_cov_temp_dir();
    memset(&cov_daemon, 0, sizeof(cov_daemon));
    cov_daemon.registry.next_handle = 500;
    labpty_session_t *s = &cov_daemon.registry.sessions[0];
    s->used = 1;
    s->alive = 0;        /* reap already flipped alive on natural exit */
    s->child_pid = 0;    /* child reaped -> dead-leak, not close_pending */
    s->close_pending = 0;
    s->handle = 400;
    s->rows = 24;
    s->cols = 80;
    s->slave_inspect_fd = -1;
    snprintf(s->logical_id, sizeof(s->logical_id), "deadleak");
    char ring_path[LABPTY_PATH_BYTES + 1];
    snprintf(ring_path, sizeof(ring_path), "%s/deadleak.br", cov_temp_dir);
    assert(labpty_byte_ring_create(ring_path, LABPTY_MIN_OUTPUT_CAPACITY, "deadleak", &s->ring) == LABPTY_OK);

    int master = open("/dev/null", O_RDONLY);
    assert(master >= 0);
    s->master_fd = master;

    uint8_t pay[64], out[512];
    size_t out_len = 0;
    size_t n = build_handle_payload(pay, sizeof(pay), 400);
    assert(handle_terminate(&cov_daemon, pay, n, out, sizeof(out), &out_len) == LABPTY_OK);

    assert(s->used == 0);                                    /* slot collapsed */
    assert(s->master_fd == -1);                              /* master field cleared */
    assert(fcntl(master, F_GETFD) == -1 && errno == EBADF);  /* fd actually closed, not leaked */
    unlink(ring_path);
}

int main(void) {
    cover_is_canonical_delimiter();
    cover_expire_stalled_clients();
    cover_parse_args();
    cover_maintenance_due_after_poll();
    cover_handlers();
    cover_dispatch_frame();
    cover_poll_dispatch();
    cover_output_wake_paths();
    cover_drain_session();
    cover_handle_write();
    cover_list_payload_skips_identityless();
    cover_terminate_deadleak_closes_master();
    if (cov_temp_ready) rmdir(cov_temp_dir);
    return 0;
}
