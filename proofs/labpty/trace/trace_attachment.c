/*
 * Runtime trace-conformance scenario for the labpty attachment state machine.
 *
 * This is the frontier that turns "// Modelled by LabptyAttachment.tla" from a
 * claim into a checked fact. It #includes main.c (its main() renamed) and
 * drives a deterministic connect/open/attach/detach/disconnect/terminate
 * sequence through the REAL daemon code: handle_attach/handle_detach set the
 * same attached_clients bits the wire path does, client_release runs the actual
 * scrub funnel, and registry_open allocates a real slot. Each transition fires
 * the production labpty_trace_emit (gated on LABPTY_TRACE), so the emitted
 * NDJSON is exactly the observable (inUse, alive, attached) state the model
 * abstracts.
 *
 * scripts/check-trace replays the trace through specs/labpty/TraceAttachment.tla
 * with TLC and asserts every logged transition is a LabptyAttachment action.
 * Built with -DLABPTY_TRACE_NEGCTL the disconnect skips the scrub — the
 * TeardownSkipsAttachmentScrub regression LabptyAttachment's PreFix config
 * models — so a departed client's bit lingers and TLC MUST reject the trace.
 * That negative control proves the pipeline catches the very bug the scrub
 * funnel exists to prevent.
 */
#define main labpty_daemon_main_unused
#include "main.c"
#undef main

#include <assert.h>
#include <fcntl.h>
#include <unistd.h>

/* registry_open's pty backend, stubbed: fork a child that exits at once (so
 * terminate->reap finds a reapable zombie and frees the slot) and hand back a
 * /dev/null master. ptsname_r on /dev/null fails, so slave_inspect_fd degrades
 * to -1 exactly as production does when the inspect-open fails. */
int laban_pty_open(int rows, int cols, const char *const *argv,
                   const char *const *envp, const char *cwd,
                   int *out_master_fd, pid_t *out_child_pid) {
    (void)rows; (void)cols; (void)argv; (void)envp; (void)cwd;
    pid_t p = fork();
    if (p == 0) _exit(0);
    if (out_master_fd) *out_master_fd = open("/dev/null", O_RDWR);
    if (out_child_pid) *out_child_pid = p;
    return 0;
}

static labpty_daemon_t daemon_state; /* ~2 MB; static, not on the stack */

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
static void connect_client(labpty_daemon_t *d, int c) {
    memset(&d->clients[c], 0, sizeof(d->clients[c]));
    d->clients[c].fd = -1;
    d->clients[c].in_use = 1;
    labpty_trace_emit(d, "Connect");
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    memset(&daemon_state, 0, sizeof(daemon_state));
    labpty_daemon_t *d = &daemon_state;
    const char *shm_dir = getenv("LABPTY_TRACE_SHMDIR");
    labpty_registry_init(&d->registry, shm_dir && shm_dir[0] ? shm_dir : "/tmp");

    /* Trace[1] is the all-zero state, matching the model's Init, so the first
     * Connect is itself a checked transition rather than an unverified start. */
    labpty_trace_emit(d, "Init");

    connect_client(d, 0);
    connect_client(d, 1);

    /* OpenSession by client 0: real slot allocation, opener auto-attached. The
     * registry_open, the |= opener bit, and the emit run with no intervening
     * emit, so the observable step is atomic (used 0->1 AND attached={0}),
     * matching OpenSession(c,s). */
    memset(&d->open_request, 0, sizeof(d->open_request));
    d->open_request.rows = 24;
    d->open_request.cols = 80;
    labpty_session_t *sess = NULL;
    labpty_status_t st = labpty_registry_open(&d->registry, &d->open_request, &sess);
    assert(st == LABPTY_OK && sess != NULL);
    sess->attached_clients |= (uint8_t)(1u << client_index(d, &d->clients[0]));
    labpty_trace_emit(d, "OpenSession");
    uint64_t handle = sess->handle;

    uint8_t pay[64], out[512];
    size_t out_len = 0, n;

    /* Attach client 1, detach it, attach again — it stays attached so the
     * disconnect below has a live bit to scrub. */
    n = build_handle_payload(pay, sizeof(pay), handle);
    assert(handle_attach(d, &d->clients[1], pay, n, out, sizeof(out), &out_len) == LABPTY_OK);
    n = build_handle_payload(pay, sizeof(pay), handle);
    assert(handle_detach(d, &d->clients[1], pay, n, out, sizeof(out), &out_len) == LABPTY_OK);
    n = build_handle_payload(pay, sizeof(pay), handle);
    assert(handle_attach(d, &d->clients[1], pay, n, out, sizeof(out), &out_len) == LABPTY_OK);

#ifdef LABPTY_TRACE_NEGCTL
    /* Regression: teardown forgets to scrub. inUse[1] drops to 0 but the bit
     * lingers in the session mask, so AttachmentImpliesInUse fails and the
     * step matches no Disconnect action — TLC must reject. */
    d->clients[1].in_use = 0;
    d->clients[1].fd = -1;
    labpty_trace_emit(d, "Disconnect");
#else
    /* The real scrub funnel: removes client 1's bit from every session. */
    client_release(d, &d->clients[1]);
#endif

    /* Terminate: request close, then reap until the slot frees. The
     * only-on-change emit mirrors the event loop's Terminate emit. */
    labpty_session_request_close(sess, monotonic_ns());
    for (int i = 0; i < 200 && count_used(d) > 0; i++) {
        int before = count_used(d);
        labpty_registry_reap(&d->registry);
        if (count_used(d) != before) labpty_trace_emit(d, "TerminateSession");
        if (count_used(d) > 0) usleep(10000);
    }
    assert(count_used(d) == 0);

    /* Disconnect client 0 (session already gone; the scrub is a no-op). */
    client_release(d, &d->clients[0]);
    return 0;
}
