/*
 * Deterministic assertion harness for handle_signal's client-controlled signal
 * validation (Sources/Labpty/main.c, commit 51f7761 / lesson L9): a signal
 * number arriving from a client socket must be range-checked before the daemon
 * forwards it to killpg/kill — the daemon defines the accepted set, it does not
 * relay arbitrary integers to a process-killing syscall.
 *
 * killpg/kill are macro-stubbed before main.c is #included so the harness can
 * OBSERVE exactly what reaches the syscall layer. The load-bearing assertions:
 *   - an out-of-range signo (negative, or >= NSIG) returns LABPTY_E_INTERNAL
 *     and NEVER reaches killpg/kill (g_last_sig stays untouched);
 *   - an in-range signo is forwarded to the syscall with that exact value.
 * Reverting the range check (the L9 fix) makes the out-of-range cases reach the
 * stub, so g_last_sig changes and the assertion fails — this harness is the
 * regression gate for that bug class. It is built and run by
 * scripts/coverage-labpty, which also merges its profile so handle_signal's
 * decisions count toward daemon MC/DC.
 */
#include <sys/types.h>

static int g_last_sig = -999;
static int test_killpg(pid_t pg, int sig) { (void)pg; g_last_sig = sig; return -1; } /* fail -> fall to kill */
static int test_kill(pid_t pid, int sig) { (void)pid; g_last_sig = sig; return 0; }
#define killpg test_killpg
#define kill test_kill
#define main labpty_daemon_main_unused
#include "main.c"
#undef main
#undef killpg
#undef kill

#include <assert.h>

int laban_pty_open(int rows, int cols, const char *const *argv,
                   const char *const *envp, const char *cwd,
                   int *out_master_fd, pid_t *out_child_pid) {
    (void)rows; (void)cols; (void)argv; (void)envp; (void)cwd;
    if (out_master_fd) *out_master_fd = -1;
    if (out_child_pid) *out_child_pid = -1;
    return -1;
}

static labpty_daemon_t cov_daemon;

static size_t build_signal_payload(uint8_t *buf, size_t cap, uint64_t handle, int32_t signo) {
    labpty_writer_t w = { buf, buf + cap };
    labpty_write_u64(&w, handle);
    labpty_write_i32(&w, signo);
    return (size_t)(w.cur - buf);
}

static void prepare_session(void) {
    memset(&cov_daemon, 0, sizeof(cov_daemon));
    labpty_session_t *s = &cov_daemon.registry.sessions[0];
    s->used = 1; s->alive = 1; s->handle = 100; s->child_pid = 4242; s->master_fd = -1;
    snprintf(s->logical_id, sizeof(s->logical_id), "sig");
    snprintf(s->ring.path, sizeof(s->ring.path), "/tmp/signal_cov.br");
    s->ring.output_capacity = LABPTY_MIN_OUTPUT_CAPACITY;
}

/* (signo < 0 || signo >= NSIG): each side of the guard, plus an in-range value
 * that must reach the syscall — the negative-control direction for the proof. */
static void cover_signal_validation(void) {
    uint8_t pay[64], out[512];
    size_t out_len = 0, n;

    prepare_session();
    g_last_sig = -999;
    n = build_signal_payload(pay, sizeof(pay), 100, -1);                 /* signo < 0 */
    assert(handle_signal(&cov_daemon, pay, n, out, sizeof(out), &out_len) == LABPTY_E_INTERNAL);
    assert(g_last_sig == -999);                                         /* no kill reached */

    g_last_sig = -999;
    n = build_signal_payload(pay, sizeof(pay), 100, NSIG);              /* signo >= NSIG */
    assert(handle_signal(&cov_daemon, pay, n, out, sizeof(out), &out_len) == LABPTY_E_INTERNAL);
    assert(g_last_sig == -999);

    g_last_sig = -999;
    n = build_signal_payload(pay, sizeof(pay), 100, NSIG + 100);        /* far out of range */
    assert(handle_signal(&cov_daemon, pay, n, out, sizeof(out), &out_len) == LABPTY_E_INTERNAL);
    assert(g_last_sig == -999);

    g_last_sig = -999;
    n = build_signal_payload(pay, sizeof(pay), 100, 0);                 /* signo 0: valid null signal */
    (void)handle_signal(&cov_daemon, pay, n, out, sizeof(out), &out_len);
    assert(g_last_sig == 0);                                           /* forwarded */

    g_last_sig = -999;
    n = build_signal_payload(pay, sizeof(pay), 100, SIGTERM);           /* in range */
    (void)handle_signal(&cov_daemon, pay, n, out, sizeof(out), &out_len);
    assert(g_last_sig == SIGTERM);

    /* Session lookup gates before the range check: a missing/not-alive session
     * is rejected without reaching it. */
    g_last_sig = -999;
    n = build_signal_payload(pay, sizeof(pay), 999, SIGTERM);
    assert(handle_signal(&cov_daemon, pay, n, out, sizeof(out), &out_len) == LABPTY_E_SESSION_NOT_FOUND);
    cov_daemon.registry.sessions[0].alive = 0;
    n = build_signal_payload(pay, sizeof(pay), 100, SIGTERM);
    assert(handle_signal(&cov_daemon, pay, n, out, sizeof(out), &out_len) == LABPTY_E_SESSION_NOT_FOUND);
}

int main(void) {
    cover_signal_validation();
    return 0;
}
