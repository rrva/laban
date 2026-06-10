#include "session_internal.h"
#include <unistd.h>  /* gethostname for OSC 7 host validation */

/* OSC host-integration scanner.
 *
 * libghostty-vt parses OSC 7/9/10/11/52 but its VT-only C API neither delivers
 * nor answers them. Laban therefore scans the raw PTY output stream for these in
 * parallel with libghostty — the same observe-and-act pattern as osc133.c /
 * tab_status.c — and:
 *   - replies to `OSC 10 ; ?` / `OSC 11 ; ?` with the session's effective
 *     foreground/background color, so an agent TUI (e.g. Codex) can match its
 *     theme to Laban's window;
 *   - delivers `OSC 9 ; <text>` to the registered notification callback;
 *   - bridges `OSC 52 ; <Pc> ; <Pd>` to the macOS clipboard (set base64 /
 *     answer a `?` read query — write always on, read opt-in); and
 *   - adopts `OSC 7 ; file://<host>/<path>` (local host only) as the session's
 *     authoritative cwd and delivers it to the working-directory callback.
 *
 * Every byte still flows unchanged into libghostty: this scanner owns the
 * ghostty_terminal_vt_write for chunks it scans (capture.c), flushing bytes
 * into the parser up to each interesting OSC terminator before dispatching.
 * A color *set* earlier in the same read chunk is therefore applied before a
 * query later in the chunk reads it, and the reply is emitted in stream order
 * relative to replies libghostty generates inline (CPR/DA): a termenv fence
 * probe (`OSC 11;?` then `CSI 6n`) must see the color reply first, or the
 * client takes the CPR as its fence and the stray OSC reply corrupts the
 * next reader (gh: "unexpected escape sequence ['\x1b' ']']"). */

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

/* Append one OSC 52 payload byte to the scanner's lazily-grown heap buffer.
 * Marks overflow (and stops appending) once the payload would exceed
 * OSC_HOST_OSC52_MAX or an allocation fails; an overflowed payload is dropped
 * at the terminator rather than truncating the clipboard. */
static void osc52_append(LabanOSCHostScanner *sc, uint8_t b) {
    if (sc->osc52_overflow) return;
    if (sc->osc52_len + 1 > OSC_HOST_OSC52_MAX) {
        sc->osc52_overflow = 1;
        return;
    }
    if (sc->osc52_len + 1 > sc->osc52_cap) {
        size_t new_cap = sc->osc52_cap ? sc->osc52_cap : 1024;
        while (new_cap < sc->osc52_len + 1) new_cap *= 2;
        if (new_cap > OSC_HOST_OSC52_MAX) new_cap = OSC_HOST_OSC52_MAX;
        char *nb = realloc(sc->osc52_buf, new_cap);
        if (!nb) {
            sc->osc52_overflow = 1;
            return;
        }
        sc->osc52_buf = nb;
        sc->osc52_cap = new_cap;
    }
    sc->osc52_buf[sc->osc52_len++] = (char)b;
}

/* Act on a complete OSC 52 payload, which is `<Pc> ; <Pd>` (the OSC number and
 * its first ';' are already stripped). Splits selection from data on the first
 * ';': a lone '?' data is a read query (answered only when read is enabled),
 * otherwise the data is base64 to set on the clipboard. The base64 is NOT
 * decoded here — the Swift bridge owns base64 + the macOS pasteboard. */
static void dispatch_osc52(LabanSession *s) {
    LabanOSCHostScanner *sc = &s->osc_host_scanner;
    const char *buf = sc->osc52_buf;
    size_t len = sc->osc52_len;

    size_t sep = 0;
    int found = 0;
    for (; sep < len; sep++) {
        if (buf[sep] == ';') { found = 1; break; }
    }
    if (!found) return;  /* malformed: no Pc;Pd separator */

    const char *selection = buf;
    size_t selection_len = sep;
    const char *data = buf + sep + 1;
    size_t data_len = len - sep - 1;

    if (data_len == 1 && data[0] == '?') {
        if (s->osc52_read_enabled && s->osc_clipboard_read_callback) {
            s->osc_clipboard_read_callback(
                s->osc_clipboard_userdata, s, selection, selection_len);
        }
        return;
    }

    /* Empty data clears the selection in xterm; we conservatively ignore it so
     * a stray `OSC 52;c;` cannot silently wipe the user's clipboard. */
    if (data_len == 0) return;
    if (s->osc_clipboard_write_callback) {
        s->osc_clipboard_write_callback(
            s->osc_clipboard_userdata, s, selection, selection_len,
            (const uint8_t *)data, data_len);
    }
}

/* Case-insensitive ASCII comparison of n bytes (hostnames are ASCII). */
static int ascii_ieq(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        char ca = a[i], cb = b[i];
        if (ca >= 'A' && ca <= 'Z') ca += 32;
        if (cb >= 'A' && cb <= 'Z') cb += 32;
        if (ca != cb) return 0;
    }
    return 1;
}

/* Is an OSC 7 authority a local host? Accept an empty authority, `localhost`,
 * or a match (full, or first DNS label) to this machine's hostname. Anything
 * else — chiefly a remote shell over SSH reporting a path that does not exist
 * locally — is rejected so the local proc_pidinfo cwd stands. */
static int osc7_host_is_local(const char *host, size_t len) {
    if (len == 0) return 1;
    if (len == 9 && ascii_ieq(host, "localhost", 9)) return 1;

    char hn[256];
    if (gethostname(hn, sizeof(hn)) != 0) return 0;
    hn[sizeof(hn) - 1] = '\0';
    size_t hn_len = 0;
    while (hn[hn_len]) hn_len++;
    if (hn_len == len && ascii_ieq(host, hn, len)) return 1;

    /* Compare first labels (text before the first '.') so `host` matches
     * `host.local` / `host.example.com` and vice versa. */
    size_t hn_label = 0;
    while (hn_label < hn_len && hn[hn_label] != '.') hn_label++;
    size_t host_label = 0;
    while (host_label < len && host[host_label] != '.') host_label++;
    if (hn_label > 0 && hn_label == host_label && ascii_ieq(host, hn, host_label)) {
        return 1;
    }
    return 0;
}

static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Percent-decode `src` (len bytes) into NUL-terminated `dst`. Returns the
 * decoded length (excluding the NUL), bounded by dst_cap. */
static size_t percent_decode(const char *src, size_t len, char *dst, size_t dst_cap) {
    size_t o = 0;
    for (size_t i = 0; i < len && o + 1 < dst_cap; i++) {
        if (src[i] == '%' && i + 2 < len) {
            int hi = hex_value(src[i + 1]);
            int lo = hex_value(src[i + 2]);
            if (hi >= 0 && lo >= 0) {
                dst[o++] = (char)((hi << 4) | lo);
                i += 2;
                continue;
            }
        }
        dst[o++] = src[i];
    }
    if (dst_cap > 0) dst[o] = '\0';
    return o;
}

/* Act on an OSC 7 working-directory report: `file://<host>/<path>` (the scheme
 * and authority are optional in practice). Adopt the percent-decoded absolute
 * path as the session's authoritative cwd when the host is local, and notify
 * any observer. Called with the session lock held (laban_vt_write_capture). */
static void dispatch_osc7(LabanSession *s, const char *payload, size_t len) {
    if (len == 0) return;

    const char *p = payload;
    size_t n = len;
    const char *host = "";
    size_t host_len = 0;

    static const char scheme[] = "file://";
    const size_t scheme_len = sizeof(scheme) - 1;
    if (n >= scheme_len && memcmp(p, scheme, scheme_len) == 0) {
        p += scheme_len;
        n -= scheme_len;
        host = p;
        size_t h = 0;
        while (h < n && p[h] != '/') h++;
        host_len = h;
        p += h;
        n -= h;  /* p now points at the path, beginning with '/' (or n == 0) */
    }

    if (n == 0 || p[0] != '/') return;          /* require an absolute path */
    if (!osc7_host_is_local(host, host_len)) return;  /* ignore remote hosts */

    char decoded[PATH_MAX];
    size_t dlen = percent_decode(p, n, decoded, sizeof(decoded));
    if (dlen == 0 || decoded[0] != '/') return;

    snprintf(s->osc7_cwd, sizeof(s->osc7_cwd), "%s", decoded);
    s->osc7_cwd_valid = 1;
    if (s->osc_cwd_callback) {
        s->osc_cwd_callback(s->osc_cwd_userdata, s, s->osc7_cwd, dlen);
    }
}

/* Act on a fully-buffered OSC payload for a number we track (7/9/10/11). OSC 52
 * accumulates in its own buffer and is dispatched via dispatch_osc52. */
static void dispatch_osc_host(
    LabanSession *s, int osc_number, const char *payload, size_t len) {
    if (osc_number == 7) {
        dispatch_osc7(s, payload, len);
        return;
    }
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
    return n == 7 || n == 9 || n == 10 || n == 11 || n == 52;
}

/* Write any not-yet-flushed bytes [*flushed, upto) into the VT parser. */
static void flush_vt_pending(LabanSession *s, const uint8_t *bytes,
                             size_t upto, size_t *flushed) {
    if (upto > *flushed) {
        ghostty_terminal_vt_write(s->terminal, bytes + *flushed, upto - *flushed);
        *flushed = upto;
    }
}

void laban_scan_osc_host_vt_write(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s) return;
    LabanOSCHostScanner *sc = &s->osc_host_scanner;
    size_t flushed = 0;
    for (size_t i = 0; i < len; i++) {
        uint8_t b = bytes[i];
        switch (sc->state) {
        case OH_NORMAL:
            /* Plain text: jump to the next ESC instead of stepping per byte. */
            i = laban_scan_skip_to_esc(bytes, len, i);
            if (i < len) sc->state = OH_AFTER_ESC;
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
                    if (sc->osc_number == 52) {
                        sc->osc52_len = 0;
                        sc->osc52_overflow = 0;
                    }
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
                /* Apply the chunk up to and including this terminator before
                 * dispatching: a reply must read post-update state and land in
                 * stream order relative to parser-emitted replies (CPR). */
                flush_vt_pending(s, bytes, i + 1, &flushed);
                if (sc->osc_number == 52) {
                    if (!sc->osc52_overflow) dispatch_osc52(s);
                } else if (!sc->payload_overflow) {
                    dispatch_osc_host(s, sc->osc_number, sc->payload, sc->payload_len);
                }
                sc->state = OH_NORMAL;
            } else if (b == 0x1B) {
                sc->state = OH_BODY_AFTER_ESC;
            } else if (sc->osc_number == 52) {
                osc52_append(sc, b);
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
                flush_vt_pending(s, bytes, i + 1, &flushed);
                if (sc->osc_number == 52) {
                    if (!sc->osc52_overflow) dispatch_osc52(s);
                } else if (!sc->payload_overflow) {
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
            /* Uninteresting OSC body: jump to its BEL/ESC terminator. */
            i = laban_scan_skip_to_esc_or_bel(bytes, len, i);
            if (i >= len) break;
            sc->state = (bytes[i] == 0x07) ? OH_NORMAL : OH_BODY_OTHER_AFTER_ESC;
            break;
        case OH_BODY_OTHER_AFTER_ESC:
            if (b == '\\') sc->state = OH_NORMAL;
            else if (b == ']') { sc->num_len = 0; sc->state = OH_OSC_NUM; }
            else if (b == 'P' || b == 'X' || b == '^' || b == '_') sc->state = OH_STRING;
            else if (b == 0x1B) sc->state = OH_AFTER_ESC;
            else sc->state = OH_NORMAL;
            break;
        case OH_STRING:
            /* DCS/SOS/PM/APC body: jump to its BEL/ESC terminator. */
            i = laban_scan_skip_to_esc_or_bel(bytes, len, i);
            if (i >= len) break;
            sc->state = (bytes[i] == 0x07) ? OH_NORMAL : OH_STRING_AFTER_ESC;
            break;
        case OH_STRING_AFTER_ESC:
            if (b == '\\') sc->state = OH_NORMAL;        /* ST */
            else if (b == 0x1B) { /* stay; another ESC */ }
            else sc->state = OH_STRING;
            break;
        }
    }
    flush_vt_pending(s, bytes, len, &flushed);
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

int laban_session_set_osc_clipboard_callbacks(
    LabanSession *s,
    LabanOSCClipboardWriteCallback write_callback,
    LabanOSCClipboardReadCallback read_callback,
    void *userdata
) {
    if (!s) return -1;
    SESSION_LOCK(s);
    s->osc_clipboard_write_callback = write_callback;
    s->osc_clipboard_read_callback = read_callback;
    s->osc_clipboard_userdata = userdata;
    return 0;
}

int laban_session_set_osc52_read_enabled(LabanSession *s, int enabled) {
    if (!s) return -1;
    SESSION_LOCK(s);
    s->osc52_read_enabled = enabled ? 1 : 0;
    return 0;
}

int laban_session_respond_clipboard_osc52(
    LabanSession *s,
    const char *selection,
    size_t selection_len,
    const uint8_t *base64,
    size_t base64_len
) {
    if (!s) return -1;
    if (!base64 && base64_len > 0) return -1;
    /* Reject a base64 blob that could not have come from a payload we accept,
     * so a buggy responder can't flood the child. */
    if (base64_len > OSC_HOST_OSC52_MAX) return -1;

    SESSION_LOCK(s);

    /* Build `ESC ] 52 ; <selection> ; <base64> ESC \`. An empty selection is
     * legal (defaults to clipboard); the base64 may be empty (empty clipboard).
     * Assemble in one heap buffer so the reply is a single PTY write. */
    const char prefix[] = "\x1b]52;";
    const char suffix[] = ";";          /* between selection and data */
    const char terminator[] = "\x1b\\"; /* ST */
    size_t total = (sizeof(prefix) - 1) + selection_len + (sizeof(suffix) - 1)
                 + base64_len + (sizeof(terminator) - 1);
    uint8_t *out = malloc(total);
    if (!out) return -1;

    size_t off = 0;
    memcpy(out + off, prefix, sizeof(prefix) - 1);
    off += sizeof(prefix) - 1;
    if (selection_len > 0 && selection) {
        memcpy(out + off, selection, selection_len);
        off += selection_len;
    }
    memcpy(out + off, suffix, sizeof(suffix) - 1);
    off += sizeof(suffix) - 1;
    if (base64_len > 0) {
        memcpy(out + off, base64, base64_len);
        off += base64_len;
    }
    memcpy(out + off, terminator, sizeof(terminator) - 1);
    off += sizeof(terminator) - 1;

    int rc = laban_write_terminal_response(s, out, off);
    free(out);
    return rc;
}

int laban_session_set_osc_working_directory_callback(
    LabanSession *s,
    LabanOSCWorkingDirectoryCallback callback,
    void *userdata
) {
    if (!s) return -1;
    SESSION_LOCK(s);
    s->osc_cwd_callback = callback;
    s->osc_cwd_userdata = userdata;
    return 0;
}
