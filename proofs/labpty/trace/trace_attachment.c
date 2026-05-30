/*
 * Runtime trace-conformance scenario for the labpty attachment state machine.
 *
 * This is the frontier that turns "// Modelled by LabptyAttachment.tla" from a
 * claim into a checked fact. It #includes main.c (its main() renamed) and
 * drives connect/open/attach/detach/disconnect/terminate transitions through
 * the REAL daemon code: handle_attach/handle_detach set the same
 * attached_clients bits the wire path does, client_release runs the actual
 * scrub funnel, and registry_open allocates a real slot. Each transition fires
 * the production labpty_trace_emit (gated on LABPTY_TRACE), so the emitted
 * NDJSON is exactly the observable (inUse, alive, attached) state the model
 * abstracts.
 *
 * Positive mode (a seed in argv[1]) drives a SEEDED-RANDOM sequence of enabled
 * operations: scripts/check-trace runs many seeds and replays every emitted
 * trace through specs/labpty/TraceAttachment.tla, so conformance is checked
 * across a fuzzed behaviour space, not one hand-picked path. Each op is gated
 * on its model precondition, so every emitted record matches an enabled
 * LabptyAttachment action.
 *
 * Built with -DLABPTY_TRACE_NEGCTL the disconnect skips the scrub — the
 * TeardownSkipsAttachmentScrub regression LabptyAttachment's PreFix config
 * models — and a compact fixed scenario disconnects a still-attached client so
 * its bit lingers; TLC MUST reject that trace. The negative control proves the
 * pipeline catches the very bug the scrub funnel exists to prevent.
 */
#define main labpty_daemon_main_unused
#include "main.c"
#undef main

#include <assert.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>

/* The scenario uses a subset of the slot space so masks stay small and traces
 * stay short; the emitter still reports all LABPTY_MAX_CLIENTS/SESSIONS, so the
 * model constants are unchanged. */
enum { SCN_CLIENTS = 4, SCN_SESSION_CAP = 4, SCN_STEPS = 40 };

/* registry_open's pty backend, stubbed: fork a stubborn child that lives in
 * its own process group until signalled (a real session's child is a
 * long-lived shell, not something that exits on its own) and hand back a
 * /dev/null master. ptsname_r on /dev/null fails, so slave_inspect_fd degrades
 * to -1 exactly as production does when the inspect-open fails. A child that
 * exited on its own would make the registry dead-leak/reclaim the slot — real
 * behaviour, but one the attachment model does not cover, so the scenario
 * keeps sessions alive until an explicit terminate (do_terminate). */
int laban_pty_open(int rows, int cols, const char *const *argv,
                   const char *const *envp, const char *cwd,
                   int *out_master_fd, pid_t *out_child_pid) {
    (void)rows; (void)cols; (void)argv; (void)envp; (void)cwd;
    pid_t p = fork();
    if (p == 0) { setpgid(0, 0); for (;;) pause(); }
    if (out_master_fd) *out_master_fd = open("/dev/null", O_RDWR);
    if (out_child_pid) *out_child_pid = p;
    return 0;
}

static labpty_daemon_t daemon_state; /* ~2 MB; static, not on the stack */

/* Deterministic xorshift32 so a seed reproduces a trace byte-for-byte. */
static uint32_t rng_state = 1;
static uint32_t rng_next(void) {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    rng_state = x;
    return x;
}

static size_t build_handle_payload(uint8_t *buf, size_t cap, uint64_t handle) {
    labpty_writer_t w = { buf, buf + cap };
    labpty_write_u64(&w, handle);
    return (size_t)(w.cur - buf);
}

static int count_used(const labpty_daemon_t *d) {
    int n = 0;
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) n += d->registry.sessions[i].used;
    return n;
}

/* Connect bypasses add_client (its accept() needs a real listen socket); the
 * observable effect — inUse[c] 0->1 — and the production emit are identical. */
static void do_connect(labpty_daemon_t *d, int c) {
    memset(&d->clients[c], 0, sizeof(d->clients[c]));
    d->clients[c].fd = -1;
    d->clients[c].in_use = 1;
    labpty_trace_emit(d, "Connect");
}

static void do_disconnect(labpty_daemon_t *d, int c) {
#ifdef LABPTY_TRACE_NEGCTL
    /* Regression: teardown forgets to scrub. inUse[c] drops to 0 but the bit
     * lingers in the session mask, so the step matches no Disconnect action
     * and AttachmentImpliesInUse fails — TLC must reject. */
    d->clients[c].in_use = 0;
    d->clients[c].fd = -1;
    labpty_trace_emit(d, "Disconnect");
#else
    client_release(d, &d->clients[c]); /* the real scrub funnel */
#endif
}

/* OpenSession by client c: registry_open allocates a real slot and the opener
 * is auto-attached. The slot alloc, the |= opener bit and the emit run with no
 * intervening emit, so the observable step is atomic (used 0->1 AND
 * attached={c}), matching OpenSession(c,s). Returns the new handle. */
static uint64_t do_open(labpty_daemon_t *d, int c) {
    memset(&d->open_request, 0, sizeof(d->open_request));
    d->open_request.rows = 24;
    d->open_request.cols = 80;
    labpty_session_t *sess = NULL;
    labpty_status_t st = labpty_registry_open(&d->registry, &d->open_request, &sess);
    assert(st == LABPTY_OK && sess != NULL);
    sess->attached_clients |= (uint8_t)(1u << client_index(d, &d->clients[c]));
    labpty_trace_emit(d, "OpenSession");
    return sess->handle;
}

static void do_attach(labpty_daemon_t *d, int c, uint64_t handle) {
    uint8_t pay[64], out[512];
    size_t out_len = 0;
    size_t n = build_handle_payload(pay, sizeof(pay), handle);
    assert(handle_attach(d, &d->clients[c], pay, n, out, sizeof(out), &out_len) == LABPTY_OK);
}

static void do_detach(labpty_daemon_t *d, int c, uint64_t handle) {
    uint8_t pay[64], out[512];
    size_t out_len = 0;
    size_t n = build_handle_payload(pay, sizeof(pay), handle);
    assert(handle_detach(d, &d->clients[c], pay, n, out, sizeof(out), &out_len) == LABPTY_OK);
}

/* Terminate: request close, then reap until that slot frees. The only-on-change
 * emit mirrors the event loop's Terminate emit. */
static void do_terminate(labpty_daemon_t *d, labpty_session_t *sess) {
    labpty_session_request_close(sess, monotonic_ns());
    sess->terminate_deadline_ns = 1; /* force immediate SIGKILL escalation */
    for (int i = 0; i < 500 && sess->used; i++) {
        int before = count_used(d);
        labpty_registry_reap(&d->registry);
        if (count_used(d) != before) labpty_trace_emit(d, "TerminateSession");
        if (sess->used) usleep(2000);
    }
    assert(sess->used == 0);
}

/* A compact divergent scenario for the negative control: a client disconnects
 * while still attached, so a scrub-skipping client_release leaves its bit set. */
__attribute__((unused))
static void run_fixed_negctl(labpty_daemon_t *d) {
    labpty_trace_emit(d, "Init");
    do_connect(d, 0);
    do_connect(d, 1);
    uint64_t h = do_open(d, 0);   /* attached={0} */
    do_attach(d, 1, h);           /* attached={0,1} */
    do_disconnect(d, 1);          /* scrub-skip: bit 1 lingers -> divergence */
    do_disconnect(d, 0);
}

/* Encoded enabled action. */
typedef struct { int kind; int c; uint64_t handle; labpty_session_t *sess; } act_t;
enum { ACT_CONNECT, ACT_OPEN, ACT_ATTACH, ACT_DETACH, ACT_DISCONNECT, ACT_TERMINATE };

/* Drive a random walk over enabled operations. At each step every action whose
 * model precondition holds is enumerated and one is chosen uniformly, so every
 * emitted record corresponds to an enabled LabptyAttachment action. */
__attribute__((unused))
static void run_random(labpty_daemon_t *d, uint32_t seed) {
    rng_state = seed ? seed : 1;
    labpty_trace_emit(d, "Init"); /* all-zero start == model Init */

    for (int step = 0; step < SCN_STEPS; step++) {
        static act_t acts[SCN_CLIENTS * (3 + SCN_SESSION_CAP * 2)];
        int n = 0;
        int used = count_used(d);
        int any_client = 0;
        for (int c = 0; c < SCN_CLIENTS; c++) if (d->clients[c].in_use) any_client = 1;

        for (int c = 0; c < SCN_CLIENTS; c++) {
            if (!d->clients[c].in_use) {
                acts[n++] = (act_t){ ACT_CONNECT, c, 0, NULL };
                continue;
            }
            acts[n++] = (act_t){ ACT_DISCONNECT, c, 0, NULL };
            if (used < SCN_SESSION_CAP) acts[n++] = (act_t){ ACT_OPEN, c, 0, NULL };
            for (int s = 0; s < LABPTY_MAX_SESSIONS; s++) {
                labpty_session_t *ss = &d->registry.sessions[s];
                if (!ss->used) continue;
                if (ss->alive) acts[n++] = (act_t){ ACT_ATTACH, c, ss->handle, ss };
                acts[n++] = (act_t){ ACT_DETACH, c, ss->handle, ss };
            }
        }
        for (int s = 0; s < LABPTY_MAX_SESSIONS; s++) {
            labpty_session_t *ss = &d->registry.sessions[s];
            if (ss->used) acts[n++] = (act_t){ ACT_TERMINATE, 0, 0, ss };
        }
        if (n == 0) { (void)any_client; continue; }

        act_t a = acts[rng_next() % (uint32_t)n];
        switch (a.kind) {
            case ACT_CONNECT:    do_connect(d, a.c); break;
            case ACT_OPEN:       (void)do_open(d, a.c); break;
            case ACT_ATTACH:     do_attach(d, a.c, a.handle); break;
            case ACT_DETACH:     do_detach(d, a.c, a.handle); break;
            case ACT_DISCONNECT: do_disconnect(d, a.c); break;
            case ACT_TERMINATE:  do_terminate(d, a.sess); break;
            default: break;
        }
    }
}

int main(int argc, char **argv) {
    memset(&daemon_state, 0, sizeof(daemon_state));
    labpty_daemon_t *d = &daemon_state;
    const char *shm_dir = getenv("LABPTY_TRACE_SHMDIR");
    labpty_registry_init(&d->registry, shm_dir && shm_dir[0] ? shm_dir : "/tmp");

#ifdef LABPTY_TRACE_NEGCTL
    (void)argc; (void)argv;
    run_fixed_negctl(d);
#else
    uint32_t seed = argc > 1 ? (uint32_t)strtoul(argv[1], NULL, 10) : 1u;
    run_random(d, seed);
#endif
    /* Reap any session children still paused (never terminated in the walk),
     * so the harness leaves no orphaned process groups behind. */
    for (int s = 0; s < LABPTY_MAX_SESSIONS; s++) {
        pid_t cp = d->registry.sessions[s].child_pid;
        if (d->registry.sessions[s].used && cp > 0) {
            kill(cp, SIGKILL);
            waitpid(cp, NULL, 0);
        }
    }
    return 0;
}
