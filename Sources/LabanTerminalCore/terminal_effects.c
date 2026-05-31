#include "session_internal.h"

#define LABAN_RESPONSE_CAP_MAX (1u << 16)  /* 64 KiB hard ceiling */

void laban_title_changed_cb(GhosttyTerminal terminal, void *userdata) {
    (void)terminal;
    LabanSession *s = (LabanSession *)userdata;
    s->title_dirty = 1;
}

void laban_bell_cb(GhosttyTerminal terminal, void *userdata) {
    (void)terminal;
    LabanSession *s = (LabanSession *)userdata;
    if (!s) return;
    s->bell_count++;
    if (s->bell_callback) {
        s->bell_callback(s->bell_userdata, s, s->bell_count);
    }
}

static void laban_session_capture_response(
    LabanSession *s, const uint8_t *data, size_t len) {
    if (!s || !data || len == 0) return;
    size_t needed = s->response_len + len;
    if (needed > LABAN_RESPONSE_CAP_MAX) return;  /* drop on runaway */
    if (needed > s->response_cap) {
        size_t new_cap = s->response_cap ? s->response_cap : 256;
        while (new_cap < needed) new_cap *= 2;
        if (new_cap > LABAN_RESPONSE_CAP_MAX) new_cap = LABAN_RESPONSE_CAP_MAX;
        uint8_t *nb = realloc(s->response_buf, new_cap);
        if (!nb) return;
        s->response_buf = nb;
        s->response_cap = new_cap;
    }
    memcpy(s->response_buf + s->response_len, data, len);
    s->response_len += len;
}

int laban_write_terminal_response(LabanSession *s, const uint8_t *data, size_t len) {
    if (!s || !data) return -1;
    if (len == 0) return 0;
    if (s->pty_fd >= 0) {
        int rc = laban_write_pty_bytes(s, data, len, LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE);
        if (rc == 0) {
            laban_session_capture_response(s, data, len);
        }
        return rc;
    }
    laban_session_capture_response(s, data, len);
    laban_emit_capture_bytes(s, LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE, data, len);
    return 0;
}

void laban_effect_write_pty(GhosttyTerminal terminal, void *userdata,
                             const uint8_t *data, size_t len) {
    (void)terminal;
    LabanSession *s = (LabanSession *)userdata;
    if (!s) return;
    (void)laban_write_terminal_response(s, data, len);
}

bool laban_effect_size(GhosttyTerminal terminal, void *userdata,
                        GhosttySizeReportSize *out_size) {
    (void)terminal;
    LabanSession *s = (LabanSession *)userdata;
    if (!s || !out_size) return false;
    out_size->rows        = s->rows;
    out_size->columns     = s->cols;
    out_size->cell_width  = s->cell_width;
    out_size->cell_height = s->cell_height;
    return true;
}

bool laban_effect_device_attributes(GhosttyTerminal terminal, void *userdata,
                                     GhosttyDeviceAttributes *out_attrs) {
    (void)terminal;
    (void)userdata;
    if (!out_attrs) return false;

    /* DA1: VT220 conformance with ANSI color. Keep this conservative: Laban
       does not install a custom terminfo entry or intentionally expose
       terminal-driven 80/132-column switching. (OSC 52 clipboard IS supported,
       via the osc_host.c side-channel bridge, but DA1 never advertised it.) */
    out_attrs->primary.conformance_level = GHOSTTY_DA_CONFORMANCE_VT220;
    out_attrs->primary.features[0] = GHOSTTY_DA_FEATURE_ANSI_COLOR;
    out_attrs->primary.num_features = 1;

    /* DA2: VT220-type, version 1, no ROM cartridge. */
    out_attrs->secondary.device_type = GHOSTTY_DA_DEVICE_TYPE_VT220;
    out_attrs->secondary.firmware_version = 1;
    out_attrs->secondary.rom_cartridge = 0;

    /* DA3: arbitrary unit id. */
    out_attrs->tertiary.unit_id = 0;

    return true;
}

GhosttyString laban_effect_xtversion(GhosttyTerminal terminal, void *userdata) {
    (void)terminal;
    (void)userdata;
    static const uint8_t kVersion[] = "laban";
    return (GhosttyString){ .ptr = kVersion, .len = sizeof(kVersion) - 1 };
}

GhosttyString laban_effect_enquiry(GhosttyTerminal terminal, void *userdata) {
    (void)terminal;
    (void)userdata;
    static const uint8_t kAnswerback[] = "laban";
    return (GhosttyString){ .ptr = kAnswerback, .len = sizeof(kAnswerback) - 1 };
}

bool laban_effect_color_scheme(GhosttyTerminal terminal, void *userdata,
                                GhosttyColorScheme *out_scheme) {
    (void)terminal;
    LabanSession *s = (LabanSession *)userdata;
    if (!s || !out_scheme) return false;
    *out_scheme =
        s->color_scheme == LABAN_COLOR_SCHEME_LIGHT
            ? GHOSTTY_COLOR_SCHEME_LIGHT
            : GHOSTTY_COLOR_SCHEME_DARK;
    return true;
}

static int laban_session_emit_color_scheme_report_locked(LabanSession *s) {
    if (!s) return -1;
    static const uint8_t dark[] = "\x1B[?997;1n";
    static const uint8_t light[] = "\x1B[?997;2n";
    if (s->color_scheme == LABAN_COLOR_SCHEME_LIGHT) {
        return laban_write_terminal_response(s, light, sizeof(light) - 1);
    }
    return laban_write_terminal_response(s, dark, sizeof(dark) - 1);
}

int laban_session_mode_active_locked(LabanSession *s, GhosttyMode mode, int *out_active) {
    if (out_active) *out_active = 0;
    if (!s || !out_active) return -1;
    bool active = false;
    GhosttyResult r = ghostty_terminal_mode_get(s->terminal, mode, &active);
    if (r != GHOSTTY_SUCCESS) return -1;
    *out_active = active ? 1 : 0;
    return 0;
}

int laban_session_drain_response(
    LabanSession *s, uint8_t *out_bytes, size_t out_capacity, size_t *out_len) {
    if (out_len) *out_len = 0;
    if (!s || !out_len) return -1;
    if (!out_bytes && out_capacity > 0) return -1;
    SESSION_LOCK(s);
    if (s->response_len == 0) return 0;
    size_t take = s->response_len < out_capacity ? s->response_len : out_capacity;
    if (take > 0 && out_bytes) memcpy(out_bytes, s->response_buf, take);
    size_t remaining = s->response_len - take;
    if (remaining > 0) {
        memmove(s->response_buf, s->response_buf + take, remaining);
    }
    s->response_len = remaining;
    *out_len = take;
    return 0;
}

int laban_session_set_bell_callback(
    LabanSession *s,
    LabanBellCallback callback,
    void *userdata
) {
    if (!s) return -1;
    SESSION_LOCK(s);
    s->bell_callback = callback;
    s->bell_userdata = userdata;
    return 0;
}

int laban_session_bell_count(LabanSession *s, uint64_t *out_count) {
    if (out_count) *out_count = 0;
    if (!s || !out_count) return -1;
    SESSION_LOCK(s);
    *out_count = s->bell_count;
    return 0;
}

int laban_session_synchronized_output_active(LabanSession *s, int *out_active) {
    if (!s) return -1;
    SESSION_LOCK(s);
    return laban_session_mode_active_locked(s, GHOSTTY_MODE_SYNC_OUTPUT, out_active);
}

int laban_session_reset_synchronized_output(LabanSession *s) {
    if (!s) return -1;
    SESSION_LOCK(s);
    GhosttyResult r = ghostty_terminal_mode_set(
        s->terminal, GHOSTTY_MODE_SYNC_OUTPUT, false);
    return r == GHOSTTY_SUCCESS ? 0 : -1;
}

int laban_session_set_color_scheme(LabanSession *s, int color_scheme) {
    if (!s) return -1;
    if (color_scheme != LABAN_COLOR_SCHEME_LIGHT &&
        color_scheme != LABAN_COLOR_SCHEME_DARK) {
        return -1;
    }
    SESSION_LOCK(s);
    int changed = s->color_scheme != color_scheme;
    s->color_scheme = color_scheme;
    if (!changed) return 0;

    int report = 0;
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_COLOR_SCHEME_REPORT, &report) == 0 &&
        report) {
        return laban_session_emit_color_scheme_report_locked(s);
    }
    return 0;
}

int laban_session_focus_reporting_enabled(LabanSession *s, int *out_enabled) {
    if (!s) return -1;
    SESSION_LOCK(s);
    return laban_session_mode_active_locked(s, GHOSTTY_MODE_FOCUS_EVENT, out_enabled);
}

static int laban_session_encode_focus_locked(
    LabanSession *s,
    int focused,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (out_len) *out_len = 0;
    if (!s || !out_len) return -1;
    if (!out_bytes && out_capacity > 0) return -1;
    if (s->status != 0) return 0;

    int enabled = 0;
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_FOCUS_EVENT, &enabled) != 0) return -1;
    if (!enabled) return 0;

    GhosttyResult r = ghostty_focus_encode(
        focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST,
        (char *)out_bytes,
        out_capacity,
        out_len);
    if (r == GHOSTTY_SUCCESS) return 0;
    if (r == GHOSTTY_OUT_OF_SPACE) return 1;
    return -1;
}

int laban_session_encode_focus(
    LabanSession *s,
    int focused,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (out_len) *out_len = 0;
    if (!s || !out_len) return -1;
    if (!out_bytes && out_capacity > 0) return -1;
    SESSION_LOCK(s);
    return laban_session_encode_focus_locked(
        s, focused, out_bytes, out_capacity, out_len);
}

int laban_session_send_focus(LabanSession *s, int focused) {
    if (!s) return -1;
    SESSION_LOCK(s);
    uint8_t stack_buf[16];
    size_t len = 0;
    int rc = laban_session_encode_focus_locked(s, focused, stack_buf, sizeof(stack_buf), &len);
    if (rc != 0) return rc;
    if (len == 0) return 0;
    if (s->fixture_mode) return 0;
    if (s->pty_fd < 0) return -1;
    return laban_write_pty_input(s, stack_buf, len);
}
