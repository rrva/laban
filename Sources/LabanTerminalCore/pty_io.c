#include "session_internal.h"

pid_t laban_waitpid_retry(pid_t pid, int *status, int options) {
    pid_t ret;
    do {
        ret = waitpid(pid, status, options);
    } while (ret < 0 && errno == EINTR);
    return ret;
}

void laban_signal_child_process_group(pid_t child_pid, int sig) {
    if (child_pid <= 0) return;
    /* The child becomes a session leader, so its pid is also its process group.
     * Escalating the group catches shell-launched foreground/background
     * children that ignore SIGHUP when the PTY closes. */
    if (kill(-child_pid, sig) < 0 && errno == ESRCH) {
        (void)kill(child_pid, sig);
    }
}

static uint64_t monotonic_us(void) {
    struct timespec ts = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

static size_t laban_session_drain_locked_(LabanSession *s);

int laban_write_pty_bytes(
    LabanSession *s,
    const uint8_t *bytes,
    size_t len,
    LabanCaptureBytesDirection direction
) {
    enum {
        WRITE_PTY_BUDGET_US = 20000,
        WRITE_PTY_CHUNK_MAX = 16384,
    };
    if (!s || !bytes) return -1;
    if (len == 0) return 0;
    if (s->pty_fd < 0) return -1;
    uint64_t started_us = monotonic_us();
    size_t written = 0;
    while (written < len) {
        uint64_t now_us = monotonic_us();
        if (started_us > 0 && now_us > started_us &&
            now_us - started_us >= WRITE_PTY_BUDGET_US) {
            return -1;
        }
        size_t chunk_len = len - written;
        if (chunk_len > WRITE_PTY_CHUNK_MAX) chunk_len = WRITE_PTY_CHUNK_MAX;
        ssize_t n = write(s->pty_fd, bytes + written, chunk_len);
        if (n > 0) {
            laban_emit_capture_bytes(s, direction, bytes + written, (size_t)n);
            written += (size_t)n;
            continue;
        }
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                /* Wait only within the total write budget. This path runs
                 * from UI input and terminal-response effects, so repeated
                 * back-pressure must not accumulate into a visible stall. */
                uint64_t elapsed_us =
                    (started_us > 0 && now_us > started_us) ? now_us - started_us : 0;
                suseconds_t remaining_us =
                    elapsed_us < WRITE_PTY_BUDGET_US
                        ? (suseconds_t)(WRITE_PTY_BUDGET_US - elapsed_us)
                        : 0;
                if (remaining_us <= 0) return -1;
                fd_set wfds;
                FD_ZERO(&wfds);
                FD_SET(s->pty_fd, &wfds);
                struct timeval tv = { .tv_sec = 0, .tv_usec = remaining_us };
                int sr = select(s->pty_fd + 1, NULL, &wfds, NULL, &tv);
                if (sr < 0 && errno == EINTR) continue;
                if (sr <= 0) return -1; /* timeout or error */
                continue;
            }
            return -1;
        }
        /* n == 0 : the master returned no bytes without an error. Treat
         * as a transient and retry once via the same select path. */
        return -1;
    }
    return 0;
}

int laban_write_pty_input(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (s && s->suppress_pty_output_until_input) {
        (void)laban_session_drain_locked_(s);
        s->suppress_pty_output_until_input = 0;
    }
    return laban_write_pty_bytes(s, bytes, len, LABAN_CAPTURE_BYTES_PTY_INPUT);
}

static size_t laban_session_drain_locked_(LabanSession *s) {
    enum { MAX_BYTES_PER_POLL = 256 * 1024 };
    size_t drained = 0;

    uint8_t buf[4096];
    for (;;) {
        if (drained >= MAX_BYTES_PER_POLL) break;
        ssize_t n = read(s->pty_fd, buf, sizeof(buf));
        if (n > 0) {
            if (!s->suppress_pty_output_until_input) {
                laban_vt_write_capture(s, buf, (size_t)n);
            }
            drained += (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) break;

        /* n == 0 or permanent error (EIO on macOS = PTY slave closed). */
        {
            int ws = 0;
            pid_t ret = laban_waitpid_retry(s->child_pid, &ws, WNOHANG);
            if (ret == s->child_pid) {
                if (WIFEXITED(ws)) {
                    s->status = 1;
                    s->exit_status = WEXITSTATUS(ws);
                } else if (WIFSIGNALED(ws)) {
                    s->status = 2;
                    s->exit_status = WTERMSIG(ws);
                }
            }
        }
        break;
    }
    return drained;
}

int laban_session_poll(LabanSession *s) {
    if (!s) return -1;
    SESSION_LOCK(s);
    if (s->fixture_mode) return 0; /* no PTY to drain */
    if (s->status != 0) return 0;  /* already exited */
    (void)laban_session_drain_locked_(s);
    return 0;
}

int laban_session_poll_blocking(LabanSession *s, int timeout_ms) {
    if (!s) return -1;

    /* Snapshot fd / mode / exit-state under the lock so we observe a
     * coherent view; release before parking in select() so other
     * threads can mutate the session while we wait. */
    int fd;
    int fixture;
    int exited;
    {
        SESSION_LOCK(s);
        fd = s->pty_fd;
        fixture = s->fixture_mode;
        exited = (s->status != 0);
    }
    if (fixture) return 0;
    if (exited) return 0;
    if (fd < 0) return 0;

    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    struct timeval tv = {
        .tv_sec = timeout_ms / 1000,
        .tv_usec = (timeout_ms % 1000) * 1000,
    };
    int sr;
    do {
        sr = select(fd + 1, &rfds, NULL, NULL,
                    timeout_ms < 0 ? NULL : &tv);
    } while (sr < 0 && errno == EINTR);
    if (sr < 0) return -1;
    if (sr == 0) return 0; /* timeout */

    SESSION_LOCK(s);
    /* Re-validate after re-acquiring the lock: another thread may have
     * resized the PTY (unlikely) or the session may have transitioned
     * to exited during our wait. */
    if (s->pty_fd != fd) return 0;
    if (s->fixture_mode) return 0;
    if (s->status != 0) return 0;
    return (int)laban_session_drain_locked_(s);
}
