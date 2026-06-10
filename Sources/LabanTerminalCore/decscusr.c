/* DECSCUSR / DEC mode 12 cursor-override scanner.
 *
 * Sniffs cursor-style and cursor-blink override sequences out of the PTY byte
 * stream in parallel with libghostty's own VT parser:
 *
 *   DECSCUSR:  CSI Ps SP q  (ESC [ <digit(s)> 0x20 q)
 *     Ps 1: blinking block  -> style + blink both overridden
 *     Ps 2: steady block    -> style + blink both overridden
 *     Ps 3: blinking under  -> style + blink both overridden
 *     Ps 4: steady under    -> style + blink both overridden
 *     Ps 5: blinking bar    -> style + blink both overridden
 *     Ps 6: steady bar      -> style + blink both overridden
 *     Ps 0 / absent         -> clear both overrides (revert to user setting)
 *
 *   DEC private mode 12:  CSI ? 12 h  (enable blink) / CSI ? 12 l (disable)
 *     Only the blink override flag is set; style is not touched.
 *
 * Clear-on-reset sequences: RIS (ESC c), DECSTR (CSI ! p),
 * alt-screen exit (CSI ? 1049 l / ? 1047 l / ? 47 l).
 *
 * All state survives chunk boundaries (same design as the other scanners).
 * Observe-only: every byte still flows unchanged to ghostty_terminal_vt_write.
 */

#include "session_internal.h"
#include <string.h>

/* DS_* states, DS_PARAM_MAX, and LabanDecscsrScanner are declared in
 * session_internal.h beside the sibling scanners (TS_, O133_, OH_) so
 * capture.c can name DS_NORMAL in its scan gate. */

/* -------------------------------------------------------------------------
 * Helpers
 * -------------------------------------------------------------------------*/

static inline void ds_clear_both(LabanSession *s) {
    s->cursor_style_overridden = 0;
    s->cursor_blink_overridden = 0;
}

/* Dispatch from DS_AFTER_ESC on byte b. */
static inline DecscsrState ds_after_esc(LabanDecscsrScanner *sc, uint8_t b) {
    if (b == '[') {
        sc->param_len = 0;
        return DS_CSI_PARAM;
    }
    if (b == 'c') {
        /* RIS: ESC c — handled inline by the caller after state transition */
        return DS_NORMAL;   /* caller checks b=='c' */
    }
    if (b == 0x1B) return DS_AFTER_ESC;  /* another ESC — stay */
    return DS_NORMAL;
}

/* Parse accumulated param digits as an int; returns 0 if empty/invalid. */
static int ds_param_int(const char *param, size_t len) {
    if (len == 0) return 0;
    int v = 0;
    for (size_t i = 0; i < len; i++) {
        if (param[i] < '0' || param[i] > '9') return 0;
        if (v < 100000) v = v * 10 + (param[i] - '0');
    }
    return v;
}

/* -------------------------------------------------------------------------
 * Main scanner entry point
 * -------------------------------------------------------------------------*/

void laban_scan_cursor_override(LabanSession *s, const uint8_t *bytes, size_t len) {
    /* Only operate when a session is present; the scanner is a no-op for nil. */
    if (!s || !bytes || len == 0) return;

    LabanDecscsrScanner *sc = &s->cursor_override_scanner;

    for (size_t i = 0; i < len; i++) {
        uint8_t b = bytes[i];

        switch (sc->state) {

        case DS_NORMAL:
            /* Plain text fast-path: jump to the next ESC. */
            i = laban_scan_skip_to_esc(bytes, len, i);
            if (i < len) {
                /* ESC found at position i. b is already consumed by the loop
                 * increment so stay and let the loop re-fetch bytes[i] — but
                 * we advanced i to the ESC position; transition now. */
                sc->state = DS_AFTER_ESC;
            }
            break;

        case DS_AFTER_ESC:
            /* b is the byte after ESC */
            if (b == 'c') {
                /* RIS: clear both overrides */
                ds_clear_both(s);
                sc->state = DS_NORMAL;
            } else if (b == '[') {
                sc->param_len = 0;
                sc->param[0] = '\0';
                sc->state = DS_CSI_PARAM;
            } else if (b == 0x1B) {
                sc->state = DS_AFTER_ESC; /* another ESC: stay */
            } else {
                sc->state = DS_NORMAL;
            }
            break;

        case DS_CSI_PARAM:
            if (b >= '0' && b <= '9') {
                if (sc->param_len + 1 < DS_PARAM_MAX) {
                    sc->param[sc->param_len++] = (char)b;
                }
            } else if (b == ' ') {
                /* CSI Ps SP ... — the SP that gates DECSCUSR */
                sc->state = DS_CSI_SP;
            } else if (b == '?') {
                /* CSI ? — DEC private mode: reset params and accumulate fresh */
                sc->param_len = 0;
                sc->param[0] = '\0';
                sc->state = DS_CSI_PRIV;
            } else if (b == '!') {
                /* CSI ! — DECSTR if followed by 'p' */
                sc->state = DS_CSI_BANG;
            } else if (b == 0x1B) {
                sc->state = DS_AFTER_ESC;
            } else {
                sc->state = DS_NORMAL;
            }
            break;

        case DS_CSI_SP:
            if (b == 'q') {
                /* DECSCUSR: CSI Ps SP q */
                int ps = ds_param_int(sc->param, sc->param_len);
                if (ps >= 1 && ps <= 6) {
                    s->cursor_style_overridden = 1;
                    s->cursor_blink_overridden = 1;
                } else {
                    /* Ps 0 or absent: revert to user setting */
                    ds_clear_both(s);
                }
            } else if (b == 0x1B) {
                sc->state = DS_AFTER_ESC;
                break;
            }
            sc->state = DS_NORMAL;
            break;

        case DS_CSI_PRIV:
            if (b >= '0' && b <= '9') {
                if (sc->param_len + 1 < DS_PARAM_MAX) {
                    sc->param[sc->param_len++] = (char)b;
                }
            } else if (b == 'h') {
                /* CSI ? Pm h: check for mode 12 (blink on) */
                if (ds_param_int(sc->param, sc->param_len) == 12) {
                    s->cursor_blink_overridden = 1;
                }
                sc->state = DS_NORMAL;
            } else if (b == 'l') {
                /* CSI ? Pm l: check for mode 12 (blink off) and alt-screen exits */
                int mode = ds_param_int(sc->param, sc->param_len);
                if (mode == 12) {
                    s->cursor_blink_overridden = 0;
                } else if (mode == 1049 || mode == 1047 || mode == 47) {
                    /* Alt-screen exit: clear both overrides */
                    ds_clear_both(s);
                }
                sc->state = DS_NORMAL;
            } else if (b == 0x1B) {
                sc->state = DS_AFTER_ESC;
            } else {
                sc->state = DS_NORMAL;
            }
            break;

        case DS_CSI_BANG:
            if (b == 'p') {
                /* DECSTR: CSI ! p — clear both overrides */
                ds_clear_both(s);
            } else if (b == 0x1B) {
                sc->state = DS_AFTER_ESC;
                break;
            }
            sc->state = DS_NORMAL;
            break;

        case DS_CSI_PRIV_H:
        case DS_CSI_PRIV_L:
        case DS_SKIP:
            sc->state = DS_NORMAL;
            break;
        }
    }
}
