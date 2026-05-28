#include "session_internal.h"

void laban_emit_capture_bytes(
    LabanSession *s,
    LabanCaptureBytesDirection direction,
    const uint8_t *bytes,
    size_t len
) {
    if (!s || !s->capture_callback || !bytes || len == 0) return;
    s->capture_callback(s->capture_userdata, s, direction, bytes, len);
}

void laban_vt_write_capture(LabanSession *s, const uint8_t *bytes, size_t len) {
    laban_emit_capture_bytes(s, LABAN_CAPTURE_BYTES_PTY_OUTPUT, bytes, len);
    if (s->capture_fd >= 0 && len > 0) {
        const uint8_t *p = bytes;
        size_t remaining = len;
        while (remaining > 0) {
            ssize_t w = write(s->capture_fd, p, remaining);
            if (w > 0) { p += w; remaining -= (size_t)w; continue; }
            if (w < 0 && errno == EINTR) continue;
            break; /* drop on EAGAIN/permanent error rather than block */
        }
    }
    /* Persistence tee runs BEFORE libghostty so the on-disk transcript
     * sees bytes in the same order they enter the VT parser. The
     * callback contract is memcpy-only — see the public header. */
    if (s->persistence_callback && bytes && len > 0) {
        s->persistence_callback(s->persistence_userdata, s, bytes, len);
    }
    laban_scan_tab_status(s, bytes, len);
    laban_scan_osc133(s, bytes, len);
    ghostty_terminal_vt_write(s->terminal, bytes, len);
    laban_session_note_terminal_dirty(s);
}

void laban_session_note_terminal_dirty(LabanSession *s) {
    if (!s) return;
    s->dirty_generation++;
    if (s->dirty_generation == 0) {
        s->dirty_generation = 1;
    }
}

int laban_session_capture_start(LabanSession *s, const char *path) {
    if (!s || !path) return -1;
    SESSION_LOCK(s);
    if (s->capture_fd >= 0) return -1; /* already capturing */
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    s->capture_fd = fd;
    return 0;
}

int laban_session_capture_stop(LabanSession *s) {
    if (!s) return -1;
    SESSION_LOCK(s);
    if (s->capture_fd >= 0) {
        close(s->capture_fd);
        s->capture_fd = -1;
    }
    return 0;
}

int laban_session_capture_active(LabanSession *s) {
    if (!s) return 0;
    SESSION_LOCK(s);
    return s->capture_fd >= 0 ? 1 : 0;
}

int laban_session_set_capture_callback(
    LabanSession *s,
    LabanCaptureBytesCallback callback,
    void *userdata
) {
    if (!s) return -1;
    SESSION_LOCK(s);
    s->capture_callback = callback;
    s->capture_userdata = userdata;
    return 0;
}

int laban_session_set_persistence_callback(
    LabanSession *s,
    LabanPersistenceBytesCallback callback,
    void *userdata
) {
    if (!s) return -1;
    SESSION_LOCK(s);
    s->persistence_callback = callback;
    s->persistence_userdata = userdata;
    return 0;
}

int laban_session_alt_buffer_active(LabanSession *s) {
    if (!s) return 0;
    SESSION_LOCK(s);
    GhosttyTerminalScreen active = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    GhosttyResult r = ghostty_terminal_get(
        s->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active);
    if (r != GHOSTTY_SUCCESS) return 0;
    return active == GHOSTTY_TERMINAL_SCREEN_ALTERNATE ? 1 : 0;
}
