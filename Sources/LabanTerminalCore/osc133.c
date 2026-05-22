#include "session_internal.h"

/* Parse the buffered OSC 133 payload (everything after `133;`, e.g. "A",
 * "B", "C", "D", or "D;0") and fire the callback for the A/B/C/D subset.
 * Unknown actions are ignored. */
static void parse_osc133_payload(LabanSession *s, const char *payload, size_t len) {
    if (!s->osc133_callback || len == 0) return;

    LabanOSC133Action action;
    switch (payload[0]) {
    case 'A': action = LABAN_OSC133_PROMPT_START; break;
    case 'B': action = LABAN_OSC133_PROMPT_END; break;
    case 'C': action = LABAN_OSC133_COMMAND_START; break;
    case 'D': action = LABAN_OSC133_COMMAND_END; break;
    default: return; /* L/I/N/P and unknown actions are not reported */
    }

    int has_exit_code = 0;
    int exit_code = 0;
    /* Only 'D' carries an exit code: `D;<digits>`. Parse a non-negative
     * decimal argument; ignore anything non-numeric (e.g. trailing options). */
    if (action == LABAN_OSC133_COMMAND_END && len >= 3 && payload[1] == ';') {
        size_t i = 2;
        if (i < len && payload[i] >= '0' && payload[i] <= '9') {
            int value = 0;
            while (i < len && payload[i] >= '0' && payload[i] <= '9') {
                value = value * 10 + (payload[i] - '0');
                i++;
            }
            has_exit_code = 1;
            exit_code = value;
        }
    }

    s->osc133_callback(s->osc133_userdata, s, action, has_exit_code, exit_code);
}

void laban_scan_osc133(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s->osc133_callback) return;
    LabanOSC133Scanner *sc = &s->osc133_scanner;
    for (size_t i = 0; i < len; i++) {
        uint8_t b = bytes[i];
        switch (sc->state) {
        case O133_NORMAL:
            if (b == 0x1B) sc->state = O133_AFTER_ESC;
            break;
        case O133_AFTER_ESC:
            if (b == ']') {
                sc->state = O133_OSC_NUM;
                sc->num_len = 0;
            } else if (b == 0x1B) {
                /* stay; double-ESC */
            } else {
                sc->state = O133_NORMAL;
            }
            break;
        case O133_OSC_NUM:
            if (b == ';') {
                sc->num[sc->num_len] = '\0';
                if (strcmp(sc->num, "133") == 0) {
                    sc->state = O133_BODY_133;
                    sc->payload_len = 0;
                    sc->payload_overflow = 0;
                } else {
                    sc->state = O133_BODY_OTHER;
                }
            } else if (b == 0x07) {
                sc->state = O133_NORMAL;
            } else if (b == 0x1B) {
                sc->state = O133_AFTER_ESC;
            } else if (sc->num_len + 1 < OSC133_NUM_MAX) {
                sc->num[sc->num_len++] = (char)b;
            } else {
                sc->state = O133_BODY_OTHER;
            }
            break;
        case O133_BODY_133:
            if (b == 0x07) {
                if (!sc->payload_overflow) {
                    parse_osc133_payload(s, sc->payload, sc->payload_len);
                }
                sc->state = O133_NORMAL;
            } else if (b == 0x1B) {
                sc->state = O133_BODY_133_AFTER_ESC;
            } else if (sc->payload_len + 1 < OSC133_PAYLOAD_MAX) {
                sc->payload[sc->payload_len++] = (char)b;
            } else {
                sc->payload_overflow = 1;
            }
            break;
        case O133_BODY_133_AFTER_ESC:
            if (b == '\\') {
                if (!sc->payload_overflow) {
                    parse_osc133_payload(s, sc->payload, sc->payload_len);
                }
            }
            sc->state = O133_NORMAL;
            break;
        case O133_BODY_OTHER:
            if (b == 0x07) sc->state = O133_NORMAL;
            else if (b == 0x1B) sc->state = O133_BODY_OTHER_AFTER_ESC;
            break;
        case O133_BODY_OTHER_AFTER_ESC:
            sc->state = O133_NORMAL;
            break;
        }
    }
}

int laban_session_set_osc133_callback(
    LabanSession *s,
    LabanOSC133Callback callback,
    void *userdata
) {
    if (!s) return -1;
    SESSION_LOCK(s);
    s->osc133_callback = callback;
    s->osc133_userdata = userdata;
    /* Reset scanner state so a stale partial sequence (from before the
     * callback was attached) doesn't fire on the new observer. */
    s->osc133_scanner.state = O133_NORMAL;
    s->osc133_scanner.payload_len = 0;
    s->osc133_scanner.num_len = 0;
    return 0;
}
