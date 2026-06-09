#include "session_internal.h"

static void parse_tab_status_payload(LabanSession *s, const char *payload, size_t len) {
    if (!s->tab_status_callback) return;
    char indicator[64] = {0};
    char status_text[256] = {0};
    char status_color[64] = {0};
    int has_indicator = 0, has_status = 0, has_status_color = 0;

    size_t i = 0;
    while (i < len) {
        char key[32];
        size_t klen = 0;
        while (i < len && payload[i] != '=' && payload[i] != ';') {
            if (klen + 1 < sizeof(key)) key[klen++] = payload[i];
            i++;
        }
        key[klen] = '\0';

        char *target = NULL;
        size_t cap = 0;
        int *flag = NULL;
        if (strcmp(key, "indicator") == 0) {
            target = indicator; cap = sizeof(indicator); flag = &has_indicator;
        } else if (strcmp(key, "status") == 0) {
            target = status_text; cap = sizeof(status_text); flag = &has_status;
        } else if (strcmp(key, "status-color") == 0) {
            target = status_color; cap = sizeof(status_color); flag = &has_status_color;
        }

        if (i < len && payload[i] == '=') {
            i++; /* '=' */
            size_t vlen = 0;
            while (i < len && payload[i] != ';') {
                char c = payload[i];
                if (c == '\\' && i + 1 < len) {
                    i++;
                    c = payload[i];
                }
                if (target && vlen + 1 < cap) target[vlen++] = c;
                i++;
            }
            if (target) {
                target[vlen] = '\0';
                *flag = 1;
            }
        }
        if (i < len && payload[i] == ';') i++;
    }

    s->tab_status_callback(
        s->tab_status_userdata,
        has_indicator ? indicator : NULL,
        has_status ? status_text : NULL,
        has_status_color ? status_color : NULL
    );
}

void laban_scan_tab_status(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s->tab_status_callback) return;
    LabanTabStatusScanner *sc = &s->tab_status_scanner;
    for (size_t i = 0; i < len; i++) {
        uint8_t b = bytes[i];
        switch (sc->state) {
        case TS_NORMAL:
            /* Plain text: jump to the next ESC instead of stepping per byte. */
            i = laban_scan_skip_to_esc(bytes, len, i);
            if (i < len) sc->state = TS_AFTER_ESC;
            break;
        case TS_AFTER_ESC:
            if (b == ']') {
                sc->state = TS_OSC_NUM;
                sc->num_len = 0;
            } else if (b == 0x1B) {
                /* stay; double-ESC */
            } else {
                sc->state = TS_NORMAL;
            }
            break;
        case TS_OSC_NUM:
            if (b == ';') {
                sc->num[sc->num_len] = '\0';
                if (strcmp(sc->num, "21337") == 0) {
                    sc->state = TS_BODY_21337;
                    sc->payload_len = 0;
                    sc->payload_overflow = 0;
                } else {
                    sc->state = TS_BODY_OTHER;
                }
            } else if (b == 0x07) {
                sc->state = TS_NORMAL;
            } else if (b == 0x1B) {
                sc->state = TS_AFTER_ESC;
            } else if (sc->num_len + 1 < TAB_STATUS_NUM_MAX) {
                sc->num[sc->num_len++] = (char)b;
            } else {
                sc->state = TS_BODY_OTHER;
            }
            break;
        case TS_BODY_21337:
            if (b == 0x07) {
                if (!sc->payload_overflow) {
                    parse_tab_status_payload(s, sc->payload, sc->payload_len);
                }
                sc->state = TS_NORMAL;
            } else if (b == 0x1B) {
                sc->state = TS_BODY_21337_AFTER_ESC;
            } else if (sc->payload_len + 1 < TAB_STATUS_PAYLOAD_MAX) {
                sc->payload[sc->payload_len++] = (char)b;
            } else {
                sc->payload_overflow = 1;
            }
            break;
        case TS_BODY_21337_AFTER_ESC:
            if (b == '\\') {
                if (!sc->payload_overflow) {
                    parse_tab_status_payload(s, sc->payload, sc->payload_len);
                }
            }
            sc->state = TS_NORMAL;
            break;
        case TS_BODY_OTHER:
            /* Uninteresting OSC body: jump to its BEL/ESC terminator. */
            i = laban_scan_skip_to_esc_or_bel(bytes, len, i);
            if (i >= len) break;
            sc->state = (bytes[i] == 0x07) ? TS_NORMAL : TS_BODY_OTHER_AFTER_ESC;
            break;
        case TS_BODY_OTHER_AFTER_ESC:
            sc->state = TS_NORMAL;
            break;
        }
    }
}

int laban_session_set_tab_status_callback(
    LabanSession *s,
    LabanTabStatusCallback callback,
    void *userdata
) {
    if (!s) return -1;
    SESSION_LOCK(s);
    s->tab_status_callback = callback;
    s->tab_status_userdata = userdata;
    /* Reset scanner state so a stale partial sequence (from before the
     * callback was attached) doesn't fire on the new observer. */
    s->tab_status_scanner.state = TS_NORMAL;
    s->tab_status_scanner.payload_len = 0;
    s->tab_status_scanner.num_len = 0;
    return 0;
}

