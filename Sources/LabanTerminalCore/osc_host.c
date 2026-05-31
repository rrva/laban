#include "session_internal.h"

/* OSC host-integration scanner.
 *
 * libghostty-vt parses OSC 9 (desktop notification) and the OSC 10/11 color
 * QUERY form, but its VT-only C API neither delivers the notification nor
 * answers the query (the query handler is a no-op in the vendored Zig). Laban
 * therefore scans the raw PTY output stream for these in parallel with
 * libghostty — the same observe-and-act pattern as osc133.c / tab_status.c —
 * and:
 *   - replies to `OSC 10 ; ?` / `OSC 11 ; ?` with the session's effective
 *     foreground/background color, so an agent TUI (e.g. Codex) can match its
 *     theme to Laban's window; and
 *   - delivers `OSC 9 ; <text>` to the registered notification callback.
 *
 * Every byte still flows unchanged into libghostty via ghostty_terminal_vt_write
 * (capture.c). This scanner runs AFTER that write so a color *set* earlier in
 * the same read chunk is applied before a query later in the chunk reads it. */

/* Reply to OSC 10;? (foreground) / OSC 11;? (background) with the session's
 * effective theme color. ghostty_terminal_get returns the OSC override or the
 * configured default WITHOUT touching render-state dirtiness (unlike
 * ghostty_render_state_colors_get, which would steal frames from the renderer).
 * Laban's ThemePaletteInjector feeds OSC 10/11 sets at session start, so this is
 * the exact theme fg/bg. When no color is configured, synthesize a
 * scheme-appropriate black/white pair so the querying app always receives a
 * usable value (Codex requires BOTH replies or it defaults to a dark theme). */
static void respond_osc_color_query(LabanSession *s, int osc_number) {
    GhosttyColorRgb rgb;
    GhosttyResult r;
    if (osc_number == 10) {
        r = ghostty_terminal_get(
            s->terminal, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &rgb);
    } else {
        r = ghostty_terminal_get(
            s->terminal, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &rgb);
    }
    if (r != GHOSTTY_SUCCESS) {
        int light = (s->color_scheme == LABAN_COLOR_SCHEME_LIGHT);
        uint8_t fg = light ? 0x00 : 0xff;  /* dark on light / light on dark */
        uint8_t bg = light ? 0xff : 0x00;
        uint8_t v = (osc_number == 10) ? fg : bg;
        rgb.r = rgb.g = rgb.b = v;
    }

    /* xterm canonical reply: ESC ] <n> ; rgb:RRRR/GGGG/BBBB ESC \
     * Each 8-bit channel is widened to 16-bit by repetition (c -> cc). Codex's
     * parser accepts both 2- and 4-hex forms with BEL or ST; use 4-hex + ST. */
    char buf[48];
    int n = snprintf(buf, sizeof(buf),
                     "\x1b]%d;rgb:%02x%02x/%02x%02x/%02x%02x\x1b\\",
                     osc_number, rgb.r, rgb.r, rgb.g, rgb.g, rgb.b, rgb.b);
    if (n > 0 && (size_t)n < sizeof(buf)) {
        laban_write_terminal_response(s, (const uint8_t *)buf, (size_t)n);
    }
}

/* Act on a fully-buffered OSC payload for a number we track (9/10/11). */
static void dispatch_osc_host(
    LabanSession *s, int osc_number, const char *payload, size_t len) {
    if (osc_number == 10 || osc_number == 11) {
        /* Query form is a lone '?'. Sets ("rgb:...", "#rrggbb") belong to
         * libghostty and must be ignored here. */
        if (len >= 1 && payload[0] == '?') {
            respond_osc_color_query(s, osc_number);
        }
        return;
    }
    if (osc_number == 9) {
        if (len == 0) return;
        /* ConEmu progress (OSC 9 ; 4 ; ...) is not a desktop notification. */
        if (len >= 2 && payload[0] == '4' && payload[1] == ';') return;
        if (s->osc_notification_callback) {
            s->osc_notification_callback(
                s->osc_notification_userdata, s,
                (const uint8_t *)payload, len);
        }
        return;
    }
}

/* Parse the collected OSC number digits. Returns -1 for empty, non-numeric, or
 * absurdly long inputs (which cannot be one of the numbers we handle). */
static int parse_osc_number(const char *num, size_t len) {
    if (len == 0) return -1;
    int value = 0;
    for (size_t i = 0; i < len; i++) {
        if (num[i] < '0' || num[i] > '9') return -1;
        if (value > 100000) return -1;
        value = value * 10 + (num[i] - '0');
    }
    return value;
}

static int osc_host_interesting(int n) {
    return n == 9 || n == 10 || n == 11;
}

void laban_scan_osc_host(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s) return;
    LabanOSCHostScanner *sc = &s->osc_host_scanner;
    for (size_t i = 0; i < len; i++) {
        uint8_t b = bytes[i];
        switch (sc->state) {
        case OH_NORMAL:
            if (b == 0x1B) sc->state = OH_AFTER_ESC;
            break;
        case OH_AFTER_ESC:
            if (b == ']') {
                sc->num_len = 0;
                sc->state = OH_OSC_NUM;
            } else if (b == 'P' || b == 'X' || b == '^' || b == '_') {
                sc->state = OH_STRING;
            } else if (b == 0x1B) {
                sc->state = OH_AFTER_ESC;
            } else {
                sc->state = OH_NORMAL;
            }
            break;
        case OH_OSC_NUM:
            if (b == ';') {
                sc->num[sc->num_len] = '\0';
                sc->osc_number = parse_osc_number(sc->num, sc->num_len);
                if (osc_host_interesting(sc->osc_number)) {
                    sc->state = OH_BODY;
                    sc->payload_len = 0;
                    sc->payload_overflow = 0;
                } else {
                    sc->state = OH_BODY_OTHER;
                }
            } else if (b == 0x07) {
                sc->state = OH_NORMAL;  /* OSC with no ';' body */
            } else if (b == 0x1B) {
                sc->state = OH_AFTER_ESC;
            } else if (sc->num_len + 1 < OSC_HOST_NUM_MAX) {
                sc->num[sc->num_len++] = (char)b;
            } else {
                sc->state = OH_BODY_OTHER;  /* number too long to be ours */
            }
            break;
        case OH_BODY:
            if (b == 0x07) {
                if (!sc->payload_overflow) {
                    dispatch_osc_host(s, sc->osc_number, sc->payload, sc->payload_len);
                }
                sc->state = OH_NORMAL;
            } else if (b == 0x1B) {
                sc->state = OH_BODY_AFTER_ESC;
            } else if (sc->payload_len + 1 < OSC_HOST_PAYLOAD_MAX) {
                sc->payload[sc->payload_len++] = (char)b;
            } else {
                sc->payload_overflow = 1;
            }
            break;
        case OH_BODY_AFTER_ESC:
            /* `\` completes ST -> dispatch. Any other byte means the ESC began a
             * new sequence; route it the same way OH_AFTER_ESC would so a
             * back-to-back OSC is not lost. */
            if (b == '\\') {
                if (!sc->payload_overflow) {
                    dispatch_osc_host(s, sc->osc_number, sc->payload, sc->payload_len);
                }
                sc->state = OH_NORMAL;
            } else if (b == ']') {
                sc->num_len = 0;
                sc->state = OH_OSC_NUM;
            } else if (b == 'P' || b == 'X' || b == '^' || b == '_') {
                sc->state = OH_STRING;
            } else if (b == 0x1B) {
                sc->state = OH_AFTER_ESC;
            } else {
                sc->state = OH_NORMAL;
            }
            break;
        case OH_BODY_OTHER:
            if (b == 0x07) sc->state = OH_NORMAL;
            else if (b == 0x1B) sc->state = OH_BODY_OTHER_AFTER_ESC;
            break;
        case OH_BODY_OTHER_AFTER_ESC:
            if (b == '\\') sc->state = OH_NORMAL;
            else if (b == ']') { sc->num_len = 0; sc->state = OH_OSC_NUM; }
            else if (b == 'P' || b == 'X' || b == '^' || b == '_') sc->state = OH_STRING;
            else if (b == 0x1B) sc->state = OH_AFTER_ESC;
            else sc->state = OH_NORMAL;
            break;
        case OH_STRING:
            if (b == 0x07) sc->state = OH_NORMAL;       /* BEL terminator */
            else if (b == 0x1B) sc->state = OH_STRING_AFTER_ESC;
            break;
        case OH_STRING_AFTER_ESC:
            if (b == '\\') sc->state = OH_NORMAL;        /* ST */
            else if (b == 0x1B) { /* stay; another ESC */ }
            else sc->state = OH_STRING;
            break;
        }
    }
}

int laban_session_set_osc_notification_callback(
    LabanSession *s,
    LabanOSCNotificationCallback callback,
    void *userdata
) {
    if (!s) return -1;
    SESSION_LOCK(s);
    s->osc_notification_callback = callback;
    s->osc_notification_userdata = userdata;
    return 0;
}
