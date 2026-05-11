#include "session_internal.h"

int laban_paste_is_safe(const uint8_t *bytes, size_t len) {
    if (!bytes && len > 0) return 0;
    return ghostty_paste_is_safe((const char *)bytes, len) ? 1 : 0;
}

int laban_session_bracketed_paste_enabled(LabanSession *s, int *out_enabled) {
    if (!s) return -1;
    SESSION_LOCK(s);
    return laban_session_mode_active(s, GHOSTTY_MODE_BRACKETED_PASTE, out_enabled);
}

int laban_session_encode_paste(
    LabanSession *s,
    const uint8_t *bytes,
    size_t len,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len,
    int *out_bracketed
) {
    if (out_len) *out_len = 0;
    if (out_bracketed) *out_bracketed = 0;
    if (!s || !out_len || !out_bracketed) return -1;
    if (len > 0 && !bytes) return -1;
    if (!out_bytes && out_capacity > 0) return -1;
    SESSION_LOCK(s);

    bool bracketed = false;
    ghostty_terminal_mode_get(s->terminal, GHOSTTY_MODE_BRACKETED_PASTE, &bracketed);

    /* ghostty_paste_encode mutates input in place; make a writable copy. */
    char *mutable_input = NULL;
    if (len > 0) {
        mutable_input = malloc(len);
        if (!mutable_input) return -1;
        memcpy(mutable_input, bytes, len);
    }

    size_t written = 0;
    GhosttyResult r = ghostty_paste_encode(
        mutable_input, len, bracketed,
        (char *)out_bytes, out_capacity, &written);

    free(mutable_input);

    if (r != GHOSTTY_SUCCESS) return -1;
    *out_len = written;
    *out_bracketed = bracketed ? 1 : 0;
    return 0;
}

int laban_session_write_paste(
    LabanSession *s,
    const uint8_t *bytes,
    size_t len,
    LabanPasteResult *out_result
) {
    if (!s) {
        if (out_result) {
            out_result->bracketed = 0;
            out_result->bytes_written = 0;
        }
        return -1;
    }
    if (len > SIZE_MAX - 16) {
        if (out_result) {
            out_result->bracketed = 0;
            out_result->bytes_written = 0;
        }
        return -1;
    }
    SESSION_LOCK(s);
    size_t cap = len + 16;
    uint8_t *buf = malloc(cap);
    if (!buf) {
        if (out_result) {
            out_result->bracketed = 0;
            out_result->bytes_written = 0;
        }
        return -1;
    }
    size_t out_len = 0;
    int rc = laban_session_write_paste_encoded(s, bytes, len, buf, cap, &out_len, out_result);
    free(buf);
    return rc == 1 ? -1 : rc;
}

int laban_session_write_paste_encoded(
    LabanSession *s,
    const uint8_t *bytes,
    size_t len,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len,
    LabanPasteResult *out_result
) {
    if (out_result) {
        out_result->bracketed = 0;
        out_result->bytes_written = 0;
    }
    if (out_len) *out_len = 0;
    if (!s || !out_len) return -1;
    if (len > 0 && !bytes) return -1;
    if (!out_bytes && out_capacity > 0) return -1;
    if (len > SIZE_MAX - 16) return -1;
    SESSION_LOCK(s);

    /* +14 for ESC[200~ (7 bytes) + ESC[201~ (7 bytes) = 14 bytes worst case.
       Using 16 for alignment. */
    size_t cap = len + 16;
    uint8_t *buf = malloc(cap);
    if (!buf) return -1;

    size_t enc_len = 0;
    int bracketed = 0;
    int r = laban_session_encode_paste(s, bytes, len, buf, cap, &enc_len, &bracketed);
    if (r != 0) { free(buf); return -1; }
    if (enc_len > out_capacity) {
        *out_len = enc_len;
        free(buf);
        return 1;
    }

    if (s->fixture_mode) {
        laban_vt_write_capture(s, buf, enc_len);
    } else {
        if (laban_write_pty_input(s, buf, enc_len) != 0) { free(buf); return -1; }
    }

    if (enc_len > 0 && out_bytes) {
        memcpy(out_bytes, buf, enc_len);
    }
    *out_len = enc_len;

    if (out_result) {
        out_result->bracketed = bracketed;
        out_result->bytes_written = enc_len;
    }

    free(buf);
    return 0;
}

