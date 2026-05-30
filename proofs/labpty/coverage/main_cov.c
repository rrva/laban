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

static size_t build_handle_payload(uint8_t *buf, size_t cap, uint64_t handle) {
    labpty_writer_t w = { buf, buf + cap };
    labpty_write_u64(&w, handle);
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
    assert(handle_resize(&cov_daemon, pay, n, out, sizeof(out), &out_len) == LABPTY_E_INTERNAL); /* ioctl(-1) fails */
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
        LABPTY_OP_DETACH_SESSION, (uint16_t)0xBEEF /* unknown op */
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
    c->in_use = 0;
    (void)service_client_poll(&cov_daemon, 0, POLLIN);   /* not in_use -> 0 */
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

    /* slave_inspect_fd < 0: preflight skipped, raw write to master_fd = -1
     * fails -> INTERNAL (covers the master write-failure branch). */
    n = build_write_payload(pay, sizeof(pay), 100, (const uint8_t *)"x", 1);
    assert(handle_write(&cov_daemon, pay, n) == LABPTY_E_INTERNAL);

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

int main(void) {
    cover_is_canonical_delimiter();
    cover_expire_stalled_clients();
    cover_parse_args();
    cover_handlers();
    cover_dispatch_frame();
    cover_poll_dispatch();
    cover_handle_write();
    return 0;
}
