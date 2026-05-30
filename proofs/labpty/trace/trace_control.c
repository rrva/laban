/*
 * Runtime trace-conformance scenario for the labpty control-channel state
 * machine — the per-connection accept -> hello -> dispatch -> write -> idle /
 * expire cycle in Sources/Labpty/main.c, where the 2aac41a slot-leak bug lived
 * (a rejected pre-hello client wrongly marked established, never reclaimed).
 *
 * It drives the REAL client pipeline over a socketpair: client_pump_read parses
 * a frame in two reads (partial -> reading, rest -> dispatch), dispatch_frame
 * stages the response (-> writing), client_pump_write drains it and runs the
 * load-bearing `established = negotiated` line (-> idle), expire_stalled_clients
 * reclaims a stalled slot, and client_release disconnects. Each transition
 * emits the observable per-client state (state, in_use, negotiated,
 * established). scripts/check-trace replays every run through
 * specs/labpty/LabptyControlChannel.tla (EstablishOnAnyRoundTrip = FALSE, the
 * correct spec); the model's frames_issued is a TLC finiteness bound with no
 * daemon counterpart, so it stays a hidden model variable and only the four
 * observable fields are pinned.
 *
 * Built with -DLABPTY_TRACE_NEGCTL, write-complete sets established = 1 (the
 * pre-2aac41a bug), so a rejected-hello client ends established=1, negotiated=0
 * — EstablishedImpliesNegotiated fails and TLC MUST reject the trace.
 */
#define main labpty_daemon_main_unused
#include "main.c"
#undef main

#include <assert.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>

enum { SCN_CLIENTS = 3, SCN_STEPS = 60, MAX_FRAMES = 9, SPLIT = 12 };
enum { KIND_HELLO_OK, KIND_HELLO_REJECT, KIND_PING };

/* registry_open's pty backend; the control channel never opens a session, so
 * this is only here to satisfy the linker. */
int laban_pty_open(int rows, int cols, const char *const *argv,
                   const char *const *envp, const char *cwd,
                   int *out_master_fd, pid_t *out_child_pid) {
    (void)rows; (void)cols; (void)argv; (void)envp; (void)cwd;
    if (out_master_fd) *out_master_fd = -1;
    if (out_child_pid) *out_child_pid = -1;
    return -1;
}

static labpty_daemon_t dstate;
static int peer_fd[SCN_CLIENTS];           /* our end of each socketpair */
static int frames[SCN_CLIENTS];            /* frame cycles since last accept */
typedef struct { uint8_t buf[1024]; size_t len; size_t written; int kind; } inflight_t;
static inflight_t inflight[SCN_CLIENTS];
static FILE *trace_fp = NULL;

static uint32_t rng_state = 1;
static uint32_t rng_next(void) {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    rng_state = x;
    return x;
}

static const char *client_state(const labpty_client_t *c) {
    if (!c->in_use) return "empty";
    if (c->write_total > c->write_sent) return "writing";
    if (c->read_have > 0) return "reading";
    return "idle";
}

static void emit(const char *action) {
    if (!trace_fp) return;
    fprintf(trace_fp, "{\"action\":\"%s\",\"clients\":[", action);
    for (int i = 0; i < SCN_CLIENTS; i++) {
        const labpty_client_t *c = &dstate.clients[i];
        fprintf(trace_fp,
                "%s{\"state\":\"%s\",\"in_use\":%d,\"negotiated\":%d,\"established\":%d}",
                i ? "," : "", client_state(c), c->in_use ? 1 : 0,
                c->negotiated ? 1 : 0, c->established ? 1 : 0);
    }
    fprintf(trace_fp, "]}\n");
    fflush(trace_fp);
}

static size_t build_hello(uint8_t *buf, int with_caps, uint64_t seq) {
    uint8_t pay[512];
    labpty_writer_t w = { pay, pay + sizeof(pay) };
    labpty_write_u16(&w, 1);  /* protocol_major = 1 */
    labpty_write_u16(&w, 0);  /* protocol_minor */
    labpty_write_u32(&w, 0);  /* client_id length = 0 */
    if (with_caps) {
        static const char *const caps[] = { "byte-ring/v1", "write-input-rpc/v1",
                                             "heartbeat-shm/v1", "session-id-pinning/v1" };
        labpty_write_u32(&w, 4);
        for (int i = 0; i < 4; i++) {
            labpty_write_u32(&w, (uint32_t)strlen(caps[i]));
            labpty_write_bytes(&w, (const uint8_t *)caps[i], strlen(caps[i]));
        }
    } else {
        labpty_write_u32(&w, 0);  /* no capabilities -> negotiate rejects */
    }
    size_t plen = (size_t)(w.cur - pay);
    labpty_frame_header_t h = { .abi_major = 1, .abi_minor = 0,
                                .frame_len = (uint32_t)(LABPTY_FRAME_HEADER_BYTES + plen),
                                .op = LABPTY_OP_HELLO, .code = 0, .seq = seq };
    labpty_encode_header(buf, LABPTY_FRAME_HEADER_BYTES, &h);
    memcpy(buf + LABPTY_FRAME_HEADER_BYTES, pay, plen);
    return LABPTY_FRAME_HEADER_BYTES + plen;
}

static size_t build_ping(uint8_t *buf, uint64_t seq) {
    labpty_frame_header_t h = { .abi_major = 1, .abi_minor = 0,
                                .frame_len = LABPTY_FRAME_HEADER_BYTES,
                                .op = LABPTY_OP_PING, .code = 0, .seq = seq };
    labpty_encode_header(buf, LABPTY_FRAME_HEADER_BYTES, &h);
    return LABPTY_FRAME_HEADER_BYTES;
}

static void set_nb(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK); }

static void do_accept(int c) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return;
    set_nb(sv[0]);
    set_nb(sv[1]);
    peer_fd[c] = sv[0];
    frames[c] = 0;
    labpty_client_t *cl = &dstate.clients[c];
    memset(cl, 0, sizeof(*cl));
    cl->fd = sv[1];
    cl->in_use = 1;
    cl->deadline_ns = monotonic_ns() + LABPTY_IO_IDLE_TIMEOUT_NS;
    emit("Accept");
}

static void do_startframe(int c, int kind) {
    inflight_t *f = &inflight[c];
    f->kind = kind;
    if (f->kind == KIND_PING) f->len = build_ping(f->buf, (uint64_t)c);
    else f->len = build_hello(f->buf, f->kind == KIND_HELLO_OK, (uint64_t)c);
    size_t chunk = f->len < SPLIT ? f->len : SPLIT;
    ssize_t wn = write(peer_fd[c], f->buf, chunk);
    f->written = wn > 0 ? (size_t)wn : 0;
    client_pump_read(&dstate, &dstate.clients[c]);
    emit("StartFrame");
}

static const char *do_dispatch(int c) {
    inflight_t *f = &inflight[c];
    while (f->written < f->len) {
        ssize_t wn = write(peer_fd[c], f->buf + f->written, f->len - f->written);
        if (wn <= 0) break;
        f->written += (size_t)wn;
    }
    int neg_before = dstate.clients[c].negotiated;
    client_pump_read(&dstate, &dstate.clients[c]);
    if (f->kind == KIND_HELLO_OK || f->kind == KIND_HELLO_REJECT) return "DispatchHello";
    return neg_before ? "DispatchNonHelloNormal" : "DispatchNonHelloBeforeHello";
}

static void do_writecomplete(int c) {
    client_pump_write(&dstate.clients[c]);
#ifdef LABPTY_TRACE_NEGCTL
    /* Pre-2aac41a regression: established on any round-trip, so a rejected
     * pre-hello client (negotiated=0) is wrongly marked established=1 and never
     * reclaimed. EstablishedImpliesNegotiated then fails -> TLC must reject. */
    dstate.clients[c].established = 1;
#endif
    uint8_t junk[4096];
    while (read(peer_fd[c], junk, sizeof(junk)) > 0) { }
    frames[c]++;
    emit("WriteComplete");
}

static void do_expire(int c) {
    dstate.clients[c].deadline_ns = 1; /* idle deadline elapsed */
    expire_stalled_clients(&dstate);
    if (!dstate.clients[c].in_use && peer_fd[c] >= 0) { close(peer_fd[c]); peer_fd[c] = -1; }
    emit("Expire");
}

static void do_disconnect(int c) {
    client_release(&dstate, &dstate.clients[c]);
    if (peer_fd[c] >= 0) { close(peer_fd[c]); peer_fd[c] = -1; }
    emit("Disconnect");
}

/* Model-enabledness of each action, so every emitted record matches an enabled
 * LabptyControlChannel action. */
static int is_idle(const labpty_client_t *c) {
    return c->in_use && c->write_total <= c->write_sent && c->read_have == 0;
}
static int is_reading(const labpty_client_t *c) {
    return c->in_use && c->write_total <= c->write_sent && c->read_have > 0;
}
static int is_writing(const labpty_client_t *c) { return c->in_use && c->write_total > c->write_sent; }
static int expire_eligible(const labpty_client_t *c) {
    return c->in_use && (!c->established || c->read_have > 0 || c->write_total > c->write_sent);
}

typedef struct { int kind; int c; } act_t;
enum { A_ACCEPT, A_START, A_DISPATCH, A_WRITE, A_EXPIRE, A_DISCONNECT };

static void run_random(uint32_t seed) {
    rng_state = seed ? seed : 1;
    emit("Init");

    /* Deterministic rejected-hello round trip: the exact pre-2aac41a shape — a
     * client whose hello is rejected (negotiated stays 0) completes a write.
     * Post-fix established stays 0; the -DLABPTY_TRACE_NEGCTL build marks it 1,
     * the leak. Run on every seed so the negative control always reaches the
     * state EstablishedImpliesNegotiated forbids. */
    do_accept(0);
    do_startframe(0, KIND_HELLO_REJECT);
    if (is_reading(&dstate.clients[0])) { const char *l = do_dispatch(0); emit(l); }
    if (is_writing(&dstate.clients[0])) do_writecomplete(0);

    /* hello-OK, then a normal post-hello PING -> DispatchNonHelloNormal: the one
     * dispatch the random walk almost never reaches, because a negotiated
     * client must survive to a SECOND round-trip. Run on every seed so that
     * transition (and negotiated=1/established=1) is always exercised — model
     * coverage, not just conformance. */
    do_accept(1);
    do_startframe(1, KIND_HELLO_OK);
    if (is_reading(&dstate.clients[1])) { const char *l = do_dispatch(1); emit(l); }
    if (is_writing(&dstate.clients[1])) do_writecomplete(1);
    do_startframe(1, KIND_PING);
    if (is_reading(&dstate.clients[1])) { const char *l = do_dispatch(1); emit(l); }
    if (is_writing(&dstate.clients[1])) do_writecomplete(1);

    for (int step = 0; step < SCN_STEPS; step++) {
        static act_t acts[SCN_CLIENTS * 5];
        int n = 0;
        for (int c = 0; c < SCN_CLIENTS; c++) {
            labpty_client_t *cl = &dstate.clients[c];
            if (!cl->in_use) { acts[n++] = (act_t){ A_ACCEPT, c }; continue; }
            if (is_idle(cl) && frames[c] < MAX_FRAMES) acts[n++] = (act_t){ A_START, c };
            if (is_reading(cl)) acts[n++] = (act_t){ A_DISPATCH, c };
            if (is_writing(cl)) acts[n++] = (act_t){ A_WRITE, c };
            if (expire_eligible(cl)) acts[n++] = (act_t){ A_EXPIRE, c };
            acts[n++] = (act_t){ A_DISCONNECT, c };
        }
        if (n == 0) continue;
        act_t a = acts[rng_next() % (uint32_t)n];
        switch (a.kind) {
            case A_ACCEPT:     do_accept(a.c); break;
            case A_START:      do_startframe(a.c, (int)(rng_next() % 3)); break;
            case A_DISPATCH: { const char *lbl = do_dispatch(a.c); emit(lbl); } break;
            case A_WRITE:      do_writecomplete(a.c); break;
            case A_EXPIRE:     do_expire(a.c); break;
            case A_DISCONNECT: do_disconnect(a.c); break;
            default: break;
        }
    }
}

int main(int argc, char **argv) {
    memset(&dstate, 0, sizeof(dstate));
    for (int i = 0; i < SCN_CLIENTS; i++) peer_fd[i] = -1;
    const char *path = getenv("LABPTY_TRACE");
    if (path && path[0]) trace_fp = fopen(path, "a");
    /* main.c's own labpty_trace_emit (the attachment binding) is gated on
     * LABPTY_TRACE and would fire from client_release into our file. Unset it
     * after we open our stream so its lazy getenv resolves to inert; this
     * harness emits the control-channel projection itself. */
    unsetenv("LABPTY_TRACE");

    uint32_t seed = argc > 1 ? (uint32_t)strtoul(argv[1], NULL, 10) : 1u;
    run_random(seed);

    for (int i = 0; i < SCN_CLIENTS; i++) if (peer_fd[i] >= 0) close(peer_fd[i]);
    return 0;
}
