/*
 * Runtime trace-conformance scenario for the labpty logical_id reuse machine —
 * the registry lifecycle where the recent SESSION_ID_IN_USE race lived
 * (testRapidOpenTerminateSameLogicalIdSurvives; the relinquish-at-terminate fix
 * in labpty_session_request_close).
 *
 * It drives the REAL registry — labpty_registry_open, labpty_session_request_
 * close (which relinquishes the id), labpty_registry_reap — through a seeded
 * random walk over open(id)/terminate/reap on a small id set, then emits the
 * observable per-slot state (used, alive, close_pending, logical_id) the model
 * abstracts. scripts/check-trace replays every run through
 * specs/labpty/LabptyReuse.tla with TLC (Fixed = TRUE, the correct spec): each
 * transition must be an OpenSession / Terminate / DaemonReap, and the reuse
 * invariants (NotAliveImpliesIdRelinquished, TerminatedIdIsReusable) must hold
 * on every state.
 *
 * The daemon's reap is atomic where the model splits ChildDies then ReapTick,
 * so TraceReuse's DaemonReap collapses both — see that module. The scenario
 * keeps a deterministic rapid terminate->reopen-same-id step (the exact bug
 * shape) so conformance is checked on it directly.
 *
 * Built with -DLABPTY_TRACE_NEGCTL, terminate restores the logical_id after
 * request_close relinquishes it — the pre-fix "keep the id while close_pending"
 * regression MC_ReusePreFix.cfg models — so a close_pending slot retains its id
 * and TLC MUST reject the trace (the terminate step matches no Fixed=TRUE
 * action, and NotAliveImpliesIdRelinquished fails).
 */
#include <assert.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* registry.c is #included (not linked) so the harness can reach its static
 * reject helper labpty_registry_find_logical — the same pattern as
 * registry_cov.c. laban_pty_open below satisfies registry_open's reference. */
#include "labpty_registry.c"

enum { MODEL_SLOTS = 4, N_IDS = 3, SCN_STEPS = 40 };
static const char *const IDS[N_IDS] = { "a", "b", "c" };

/* registry_open's pty backend, stubbed: a stubborn child in its own process
 * group, alive until SIGKILL (a real session's child is a long-lived shell). */
int laban_pty_open(int rows, int cols, const char *const *argv,
                   const char *const *envp, const char *cwd,
                   int *out_master_fd, pid_t *out_child_pid) {
    (void)rows; (void)cols; (void)argv; (void)envp; (void)cwd;
    pid_t p = fork();
    if (p == 0) {
        /* Survive request_close's SIGHUP (default action kills) so the slot
         * stays close_pending until an explicit do_reap SIGKILLs it; otherwise
         * registry_open's internal reap would free and reuse it in one step. */
        signal(SIGHUP, SIG_IGN);
        setpgid(0, 0);
        for (;;) pause();
    }
    if (out_master_fd) *out_master_fd = open("/dev/null", O_RDWR);
    if (out_child_pid) *out_child_pid = p;
    return 0;
}

static labpty_registry_t reg;
static labpty_open_request_t open_req; /* ~1.4 MB; static, not on the stack */
static FILE *trace_fp = NULL;

static uint32_t rng_state = 1;
static uint32_t rng_next(void) {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    rng_state = x;
    return x;
}

/* Emit the observable per-slot lifecycle state over the first MODEL_SLOTS
 * registry slots. A free or id-relinquished slot reports logical_id "none",
 * matching the model's NoId. */
static void emit(const char *action) {
    if (!trace_fp) return;
    fprintf(trace_fp, "{\"action\":\"%s\",\"used\":[", action);
    for (int i = 0; i < MODEL_SLOTS; i++)
        fprintf(trace_fp, "%s%d", i ? "," : "", reg.sessions[i].used ? 1 : 0);
    fprintf(trace_fp, "],\"alive\":[");
    for (int i = 0; i < MODEL_SLOTS; i++)
        fprintf(trace_fp, "%s%d", i ? "," : "", reg.sessions[i].alive ? 1 : 0);
    fprintf(trace_fp, "],\"cp\":[");
    for (int i = 0; i < MODEL_SLOTS; i++)
        fprintf(trace_fp, "%s%d", i ? "," : "", reg.sessions[i].close_pending ? 1 : 0);
    fprintf(trace_fp, "],\"lid\":[");
    for (int i = 0; i < MODEL_SLOTS; i++) {
        const labpty_session_t *s = &reg.sessions[i];
        const char *lid = (s->used && s->logical_id[0]) ? s->logical_id : "none";
        fprintf(trace_fp, "%s\"%s\"", i ? "," : "", lid);
    }
    fprintf(trace_fp, "]}\n");
    fflush(trace_fp);
}

static int count_used(void) {
    int n = 0;
    for (int i = 0; i < MODEL_SLOTS; i++) n += reg.sessions[i].used;
    return n;
}
static int count_cp(void) {
    int n = 0;
    for (int i = 0; i < MODEL_SLOTS; i++) n += (reg.sessions[i].used && reg.sessions[i].close_pending);
    return n;
}

/* Open id: the real registry_open. Emits only on success (a blocked id leaves
 * the registry unchanged, which is a non-transition, not a model step). */
static int do_open(const char *id) {
    memset(&open_req, 0, sizeof(open_req));
    open_req.rows = 24;
    open_req.cols = 80;
    snprintf(open_req.logical_id, sizeof(open_req.logical_id), "%s", id);
    labpty_session_t *sess = NULL;
    if (labpty_registry_open(&reg, &open_req, &sess) != LABPTY_OK) return 0;
    emit("OpenSession");
    return 1;
}

/* Terminate slot s: the real request_close relinquishes the id. The deadline is
 * left in the future so registry_open's internal reap does NOT free this slot
 * mid-open (which would fuse a reap and an open into one observable step); the
 * slot is freed only by an explicit do_reap. */
static void do_terminate(int s, const char *held_id) {
    labpty_session_t *sess = &reg.sessions[s];
    labpty_session_request_close(sess, reap_monotonic_ns());
    /* Pin the kill deadline far out so no registry_open internal reap frees
     * this slot before an explicit do_reap; only do_reap forces it past. */
    if (sess->used && sess->close_pending) sess->terminate_deadline_ns = UINT64_MAX;
#ifdef LABPTY_TRACE_NEGCTL
    /* Pre-fix regression: keep the id while close_pending. */
    if (sess->used && sess->close_pending)
        snprintf(sess->logical_id, sizeof(sess->logical_id), "%s", held_id);
#else
    (void)held_id;
#endif
    emit("Terminate");
}

/* DaemonReap: force every close_pending slot past its deadline and drain them
 * to free in one batch (the model's ReapTick frees all reaped close_pending
 * slots at once), then emit if anything changed. */
static void do_reap(void) {
    int before = count_used();
    for (int i = 0; i < MODEL_SLOTS; i++)
        if (reg.sessions[i].used && reg.sessions[i].close_pending)
            reg.sessions[i].terminate_deadline_ns = 1;
    for (int i = 0; i < 2000 && count_cp() > 0; i++) {
        labpty_registry_reap(&reg);
        if (count_cp() > 0) usleep(1000);
    }
    assert(count_cp() == 0);
    if (count_used() != before) emit("DaemonReap");
}

/* registry_open's reject rule: a NEW open of id is blocked while any used slot
 * still holds it (a relinquished slot no longer holds it). */
static int id_held(const char *id) {
    return labpty_registry_find_logical(&reg, id) != NULL;
}

static void cleanup_children(void) {
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        pid_t cp = reg.sessions[i].child_pid;
        if (reg.sessions[i].used && cp > 0) { kill(cp, SIGKILL); waitpid(cp, NULL, 0); }
    }
}

typedef struct { int kind; int s; const char *id; } act_t;
enum { ACT_OPEN, ACT_TERMINATE, ACT_REAP };

static void run_random(uint32_t seed) {
    rng_state = seed ? seed : 1;
    emit("Init");

    /* A deterministic rapid terminate->reopen-same-id prelude: the exact race
     * the fix closed, checked on every seed. */
    do_open("a");
    for (int s = 0; s < MODEL_SLOTS; s++)
        if (reg.sessions[s].used && reg.sessions[s].alive) { do_terminate(s, "a"); break; }
    do_open("a"); /* reopen the just-relinquished id BEFORE reaping the old slot */
    do_reap();

    for (int step = 0; step < SCN_STEPS; step++) {
        static act_t acts[N_IDS + MODEL_SLOTS + 1];
        int n = 0;
        if (count_used() < MODEL_SLOTS) {
            for (int k = 0; k < N_IDS; k++)
                if (!id_held(IDS[k])) acts[n++] = (act_t){ ACT_OPEN, 0, IDS[k] };
        }
        for (int s = 0; s < MODEL_SLOTS; s++)
            if (reg.sessions[s].used && reg.sessions[s].alive)
                acts[n++] = (act_t){ ACT_TERMINATE, s, reg.sessions[s].logical_id };
        if (count_cp() > 0) acts[n++] = (act_t){ ACT_REAP, 0, NULL };
        if (n == 0) continue;

        act_t a = acts[rng_next() % (uint32_t)n];
        switch (a.kind) {
            case ACT_OPEN:      (void)do_open(a.id); break;
            case ACT_TERMINATE: do_terminate(a.s, a.id); break;
            case ACT_REAP:      do_reap(); break;
            default: break;
        }
    }
}

int main(int argc, char **argv) {
    const char *shm_dir = getenv("LABPTY_TRACE_SHMDIR");
    labpty_registry_init(&reg, shm_dir && shm_dir[0] ? shm_dir : "/tmp");
    const char *path = getenv("LABPTY_TRACE");
    if (path && path[0]) trace_fp = fopen(path, "a");

    uint32_t seed = argc > 1 ? (uint32_t)strtoul(argv[1], NULL, 10) : 1u;
    run_random(seed);

    cleanup_children();
    return 0;
}
