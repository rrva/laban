#include "LabanTerminalCore.h"
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/render.h>
#include <ghostty/vt/style.h>
#include <ghostty/vt/mouse.h>
#include <ghostty/vt/paste.h>
#include <ghostty/vt/modes.h>
#include <ghostty/vt/device.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/screen.h>
#include <ghostty/vt/point.h>
#include <ghostty/vt/size_report.h>
#include <ghostty/vt/key/encoder.h>
#include <ghostty/vt/key/event.h>
#include <stdbool.h>
#include <util.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <poll.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <signal.h>
#include <sys/proc_info.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pwd.h>
#include <time.h>

#define LABAN_TITLE_MAX_BYTES 1024

/* OSC 21337 scanner state. Sniffs `ESC ] 21337 ; key=value;... ST/BEL`
 * out of the PTY byte stream in parallel with libghostty's own parser
 * (libghostty has no generic "unknown OSC" callback and silently drops
 * everything outside its known set). The scanner observes only — every
 * byte still flows unchanged to libghostty. iTerm2-compatible. */
typedef enum {
    TS_NORMAL = 0,
    TS_AFTER_ESC,
    TS_OSC_NUM,
    TS_BODY_21337,
    TS_BODY_21337_AFTER_ESC,
    TS_BODY_OTHER,
    TS_BODY_OTHER_AFTER_ESC,
} TabStatusState;

#define TAB_STATUS_NUM_MAX 8       /* "21337" + room */
#define TAB_STATUS_PAYLOAD_MAX 1024 /* observed payloads &lt; 100 bytes */

typedef struct {
    TabStatusState state;
    char num[TAB_STATUS_NUM_MAX];
    size_t num_len;
    char payload[TAB_STATUS_PAYLOAD_MAX];
    size_t payload_len;
} LabanTabStatusScanner;

struct LabanSession {
    GhosttyTerminal terminal;
    GhosttyRenderState render_state;
    GhosttyRenderStateRowIterator row_iter;   /* pre-allocated; reused each snapshot */
    GhosttyRenderStateRowCells row_cells;     /* pre-allocated; reused each snapshot */
    int pty_fd;          /* master side; -1 in fixture mode */
    pid_t child_pid;     /* -1 in fixture mode */
    char launch_cwd[PATH_MAX];
    int status;          /* 0=running, 1=exited normally, 2=signaled */
    int exit_status;
    int fixture_mode;
    GhosttyMouseEncoder mouse_encoder;
    int mouse_button_pressed;  /* boolean: is any mouse button currently down */
    LabanMouseButton mouse_pressed_button;
    GhosttyKeyEncoder key_encoder;
    GhosttyKeyEvent key_event;

    int title_dirty;     /* set to 1 by title-changed callback; cleared by consume */

    int capture_fd;      /* file descriptor for PTY-byte capture; -1 if inactive */
    LabanCaptureBytesCallback capture_callback;
    void *capture_userdata;

    LabanTabStatusScanner tab_status_scanner;
    LabanTabStatusCallback tab_status_callback;
    void *tab_status_userdata;

    /* Cached geometry for the SIZE effect (XTWINOPS replies). */
    uint16_t cols;
    uint16_t rows;
    uint32_t cell_width;
    uint32_t cell_height;

    /* Capture of bytes the terminal wants written back to the pty
       (capability replies: DA1/DA2/DA3, XTWINOPS, DSR, XTVERSION, ...).
       In pty mode these are also forwarded to pty_fd; in fixture mode
       this is the only place they live. Drained via
       laban_session_drain_response. */
    uint8_t *response_buf;
    size_t   response_len;
    size_t   response_cap;
};

static void emit_capture_bytes(
    LabanSession *s,
    LabanCaptureBytesDirection direction,
    const uint8_t *bytes,
    size_t len
) {
    if (!s || !s->capture_callback || !bytes || len == 0) return;
    s->capture_callback(s->capture_userdata, s, direction, bytes, len);
}

/* Parse a complete OSC 21337 payload (`key=value;key=value;...`) and
 * dispatch to the registered Swift callback. Backslash-escaped semicolons
 * inside values are unescaped per iTerm2's spec. Unknown keys are
 * silently ignored. NULL is reported for keys absent from this payload
 * so the receiver knows to leave them unchanged. */
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

/* Pure observer — every byte still flows to libghostty unchanged. The
 * scanner only fires the tab-status callback on a successfully parsed
 * `OSC 21337 ; ... BEL/ST` sequence; non-21337 OSCs and any malformed
 * fragments are silently consumed without affecting the VT path. */
static void scan_tab_status(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s->tab_status_callback) return;
    LabanTabStatusScanner *sc = &s->tab_status_scanner;
    for (size_t i = 0; i < len; i++) {
        uint8_t b = bytes[i];
        switch (sc->state) {
        case TS_NORMAL:
            if (b == 0x1B) sc->state = TS_AFTER_ESC;
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
                parse_tab_status_payload(s, sc->payload, sc->payload_len);
                sc->state = TS_NORMAL;
            } else if (b == 0x1B) {
                sc->state = TS_BODY_21337_AFTER_ESC;
            } else if (sc->payload_len + 1 < TAB_STATUS_PAYLOAD_MAX) {
                sc->payload[sc->payload_len++] = (char)b;
            }
            break;
        case TS_BODY_21337_AFTER_ESC:
            if (b == '\\') {
                parse_tab_status_payload(s, sc->payload, sc->payload_len);
            }
            sc->state = TS_NORMAL;
            break;
        case TS_BODY_OTHER:
            if (b == 0x07) sc->state = TS_NORMAL;
            else if (b == 0x1B) sc->state = TS_BODY_OTHER_AFTER_ESC;
            break;
        case TS_BODY_OTHER_AFTER_ESC:
            sc->state = TS_NORMAL;
            break;
        }
    }
}

/* Mirror bytes into the VT parser AND into the active legacy capture file (if any).
 * Capture writes are best-effort: a failed write does not abort the parse,
 * since the user is observing the terminal regardless of capture success. */
static void vt_write_capture(LabanSession *s, const uint8_t *bytes, size_t len) {
    emit_capture_bytes(s, LABAN_CAPTURE_BYTES_PTY_OUTPUT, bytes, len);
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
    scan_tab_status(s, bytes, len);
    ghostty_terminal_vt_write(s->terminal, bytes, len);
}

/* Drain `bytes` to the PTY master, retrying on partial writes (PTY
 * master accepts ~1 KB–4 KB per write depending on kernel) and on
 * EAGAIN (the fd is O_NONBLOCK; a slow child process fills the kernel
 * buffer and blocks back-pressure on us). Without this loop a 2 KB
 * bracketed paste would lose its trailing `ESC[201~` end marker,
 * leaving the receiver in "still receiving paste" mode forever and
 * silently swallowing every subsequent keystroke as paste content. */
static int write_pty_input(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s || !bytes) return -1;
    if (len == 0) return 0;
    if (s->pty_fd < 0) return -1;
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(s->pty_fd, bytes + written, len - written);
        if (n > 0) {
            emit_capture_bytes(
                s, LABAN_CAPTURE_BYTES_PTY_INPUT, bytes + written, (size_t)n);
            written += (size_t)n;
            continue;
        }
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                /* Wait for the child to drain. select() blocks until the
                 * fd is writable again or 1 s elapses (defensive cap so a
                 * dead/stopped child can't permanently freeze the
                 * caller's main thread). */
                fd_set wfds;
                FD_ZERO(&wfds);
                FD_SET(s->pty_fd, &wfds);
                struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
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

static void laban_title_changed_cb(GhosttyTerminal terminal, void *userdata) {
    (void)terminal;
    LabanSession *s = (LabanSession *)userdata;
    s->title_dirty = 1;
}

/* Encode one Unicode codepoint to UTF-8. Returns bytes written (1-4). */
static int encode_utf8(uint32_t cp, uint8_t *out) {
    if (cp < 0x80) {
        out[0] = (uint8_t)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (uint8_t)(0xC0 | (cp >> 6));
        out[1] = (uint8_t)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (uint8_t)(0xE0 | (cp >> 12));
        out[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (uint8_t)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (uint8_t)(0xF0 | (cp >> 18));
    out[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (uint8_t)(0x80 | (cp & 0x3F));
    return 4;
}

static uint16_t laban_cell_flags_from_style(const GhosttyStyle *style) {
    uint16_t flags = 0;
    if (!style) return flags;
    if (style->bold) flags |= LABAN_CELL_FLAG_BOLD;
    if (style->italic) flags |= LABAN_CELL_FLAG_ITALIC;
    if (style->faint) flags |= LABAN_CELL_FLAG_FAINT;
    if (style->inverse) flags |= LABAN_CELL_FLAG_INVERSE;
    if (style->invisible) flags |= LABAN_CELL_FLAG_INVISIBLE;
    if (style->underline != 0) flags |= LABAN_CELL_FLAG_UNDERLINE;
    if (style->strikethrough) flags |= LABAN_CELL_FLAG_STRIKETHROUGH;
    if (style->overline) flags |= LABAN_CELL_FLAG_OVERLINE;
    if (style->blink) flags |= LABAN_CELL_FLAG_BLINK;
    return flags;
}

/* Resolve a GhosttyStyleColor (RGB or palette) into a 0xRRGGBBAA value
 * using the render state's palette. Returns 0 (alpha=0 = unset) when the
 * color tag is GHOSTTY_STYLE_COLOR_NONE. */
static uint32_t resolve_style_color_rgba(
    GhosttyRenderState render_state, GhosttyStyleColor color
) {
    switch (color.tag) {
        case GHOSTTY_STYLE_COLOR_RGB: {
            return ((uint32_t)color.value.rgb.r << 24) |
                   ((uint32_t)color.value.rgb.g << 16) |
                   ((uint32_t)color.value.rgb.b << 8) | 0xFF;
        }
        case GHOSTTY_STYLE_COLOR_PALETTE: {
            GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
            ghostty_render_state_colors_get(render_state, &colors);
            uint8_t idx = color.value.palette;
            GhosttyColorRgb rgb = colors.palette[idx];
            return ((uint32_t)rgb.r << 24) |
                   ((uint32_t)rgb.g << 16) |
                   ((uint32_t)rgb.b << 8) | 0xFF;
        }
        case GHOSTTY_STYLE_COLOR_NONE:
        default:
            return 0;
    }
}

static void free_ghostty_resources(LabanSession *s) {
    ghostty_render_state_row_cells_free(s->row_cells);
    ghostty_render_state_row_iterator_free(s->row_iter);
    ghostty_render_state_free(s->render_state);
    if (s->mouse_encoder) ghostty_mouse_encoder_free(s->mouse_encoder);
    if (s->key_encoder) ghostty_key_encoder_free(s->key_encoder);
    if (s->key_event) ghostty_key_event_free(s->key_event);
    ghostty_terminal_free(s->terminal);
    free(s->response_buf);
    s->response_buf = NULL;
    s->response_len = 0;
    s->response_cap = 0;
}

/* --- Terminal effect callbacks ---
 *
 * Without these, programs that probe terminal capabilities (tmux, vim,
 * starship, ...) will issue queries (DA1/DA2/DSR/XTWINOPS/XTVERSION)
 * and never receive a reply, causing them to hang or fall back to a
 * degraded capability set.
 */

#define LABAN_RESPONSE_CAP_MAX (1u << 16)  /* 64 KiB hard ceiling */

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

static void effect_write_pty(GhosttyTerminal terminal, void *userdata,
                             const uint8_t *data, size_t len) {
    (void)terminal;
    LabanSession *s = (LabanSession *)userdata;
    if (!s) return;
    laban_session_capture_response(s, data, len);
    if (s->pty_fd >= 0 && len > 0) {
        /* Best-effort: capability responses are tiny (<32 bytes typical).
           Partial writes / EAGAIN on a freshly-empty PTY master are rare. */
        ssize_t n = write(s->pty_fd, data, len);
        if (n > 0) {
            emit_capture_bytes(s, LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE, data, (size_t)n);
        }
        (void)n;
    } else if (len > 0) {
        emit_capture_bytes(s, LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE, data, len);
    }
}

static bool effect_size(GhosttyTerminal terminal, void *userdata,
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

static bool effect_device_attributes(GhosttyTerminal terminal, void *userdata,
                                     GhosttyDeviceAttributes *out_attrs) {
    (void)terminal;
    (void)userdata;
    if (!out_attrs) return false;

    /* DA1: VT220 conformance with 132-column support, selective erase,
       and ANSI color. Matches what most modern emulators report. */
    out_attrs->primary.conformance_level = GHOSTTY_DA_CONFORMANCE_VT220;
    out_attrs->primary.features[0] = GHOSTTY_DA_FEATURE_COLUMNS_132;
    out_attrs->primary.features[1] = GHOSTTY_DA_FEATURE_SELECTIVE_ERASE;
    out_attrs->primary.features[2] = GHOSTTY_DA_FEATURE_ANSI_COLOR;
    out_attrs->primary.num_features = 3;

    /* DA2: VT220-type, version 1, no ROM cartridge. */
    out_attrs->secondary.device_type = GHOSTTY_DA_DEVICE_TYPE_VT220;
    out_attrs->secondary.firmware_version = 1;
    out_attrs->secondary.rom_cartridge = 0;

    /* DA3: arbitrary unit id. */
    out_attrs->tertiary.unit_id = 0;

    return true;
}

static GhosttyString effect_xtversion(GhosttyTerminal terminal, void *userdata) {
    (void)terminal;
    (void)userdata;
    static const uint8_t kVersion[] = "laban";
    return (GhosttyString){ .ptr = kVersion, .len = sizeof(kVersion) - 1 };
}

static bool effect_color_scheme(GhosttyTerminal terminal, void *userdata,
                                GhosttyColorScheme *out_scheme) {
    (void)terminal;
    (void)userdata;
    (void)out_scheme;
    /* MVP is fixed Selenized Light; we don't yet adapt to system dark mode. */
    return false;
}

int laban_session_create(
    const LabanLaunchConfig *config,
    LabanTerminalSize initial_size,
    LabanSession **out_session
) {
    if (!config || !out_session) return -1;

    uint16_t cols = (uint16_t)(initial_size.cols > 0 ? initial_size.cols : 80);
    uint16_t rows = (uint16_t)(initial_size.rows > 0 ? initial_size.rows : 24);

    /* PTY mode: resolve and pre-flight the executable before allocating anything. */
    const char *exe = NULL;
    if (!config->fixture_mode) {
        if (config->executable && config->executable[0])
            exe = config->executable;
        else
            exe = getenv("SHELL");
        if (!exe || !exe[0]) {
            struct passwd *pw = getpwuid(getuid());
            if (pw && pw->pw_shell && pw->pw_shell[0]) exe = pw->pw_shell;
        }
        if (!exe || !exe[0]) exe = "/bin/sh";
        if (access(exe, X_OK) != 0) return -1;
    }

    LabanSession *s = calloc(1, sizeof(struct LabanSession));
    if (!s) return -1;
    s->pty_fd = -1;
    s->child_pid = -1;
    s->launch_cwd[0] = '\0';
    s->capture_fd = -1;
    s->capture_callback = NULL;
    s->capture_userdata = NULL;
    s->fixture_mode = config->fixture_mode;

    GhosttyTerminalOptions opts = { .cols = cols, .rows = rows, .max_scrollback = 1000 };

    GhosttyResult r = ghostty_terminal_new(NULL, &s->terminal, opts);
    if (r != GHOSTTY_SUCCESS) { free(s); return -1; }

    /* Cache geometry for the SIZE effect; also picks up cell pixel sizes
       if the caller supplied them at create time (otherwise updated on
       the first laban_session_resize). */
    s->cols        = cols;
    s->rows        = rows;
    s->cell_width  = (uint32_t)(initial_size.cell_width  > 0 ? initial_size.cell_width  : 0);
    s->cell_height = (uint32_t)(initial_size.cell_height > 0 ? initial_size.cell_height : 0);

    /* Register effects so capability probes (DA1/DA2/DSR/XTWINOPS/XTVERSION)
       reach the child process — without these, tmux and vim hang on startup. */
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, (const void *)s);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                         (const void *)effect_write_pty);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_SIZE,
                         (const void *)effect_size);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
                         (const void *)effect_device_attributes);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_XTVERSION,
                         (const void *)effect_xtversion);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME,
                         (const void *)effect_color_scheme);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                         (const void *)laban_title_changed_cb);

    r = ghostty_render_state_new(NULL, &s->render_state);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    r = ghostty_render_state_row_iterator_new(NULL, &s->row_iter);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_render_state_free(s->render_state);
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    r = ghostty_render_state_row_cells_new(NULL, &s->row_cells);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_render_state_row_iterator_free(s->row_iter);
        ghostty_render_state_free(s->render_state);
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    /* Create persistent mouse encoder. */
    r = ghostty_mouse_encoder_new(NULL, &s->mouse_encoder);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_render_state_row_cells_free(s->row_cells);
        ghostty_render_state_row_iterator_free(s->row_iter);
        ghostty_render_state_free(s->render_state);
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    /* Create persistent key encoder and reusable key event. */
    r = ghostty_key_encoder_new(NULL, &s->key_encoder);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_render_state_row_cells_free(s->row_cells);
        ghostty_render_state_row_iterator_free(s->row_iter);
        ghostty_render_state_free(s->render_state);
        ghostty_mouse_encoder_free(s->mouse_encoder);
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    r = ghostty_key_event_new(NULL, &s->key_event);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_render_state_row_cells_free(s->row_cells);
        ghostty_render_state_row_iterator_free(s->row_iter);
        ghostty_render_state_free(s->render_state);
        ghostty_mouse_encoder_free(s->mouse_encoder);
        ghostty_key_encoder_free(s->key_encoder);
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    if (config->fixture_mode) {
        *out_session = s;
        return 0;
    }

    const char *launch_cwd = NULL;
    if (config->cwd && config->cwd[0]) {
        launch_cwd = config->cwd;
    } else {
        launch_cwd = getenv("HOME");
        if (!launch_cwd || !launch_cwd[0]) {
            struct passwd *pw = getpwuid(getuid());
            if (pw && pw->pw_dir) launch_cwd = pw->pw_dir;
        }
    }
    if (launch_cwd && launch_cwd[0]) {
        snprintf(s->launch_cwd, sizeof(s->launch_cwd), "%s", launch_cwd);
    }

    /* Fork a child process with a new PTY. */
    int pty_fd = -1;
    pid_t child = forkpty(&pty_fd, NULL, NULL, NULL);
    if (child < 0) {
        free_ghostty_resources(s);
        free(s);
        return -1;
    }

    if (child == 0) {
        /* Child: reset inherited signal dispositions, set env, exec. */
        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);

        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        unsetenv("NO_COLOR");

        if (config->envp) {
            for (int i = 0; config->envp[i]; i++)
                putenv((char *)config->envp[i]);
        }

        if (launch_cwd && launch_cwd[0]) chdir(launch_cwd);

        if (config->argv) {
            execv(exe, (char *const *)config->argv);
        } else {
            /* Invoke as login shell by prefixing argv[0] with '-'.
               This causes shells to source login profiles and
               start in $HOME. This is the standard approach used
               by Ghostty, iTerm2, Warp, and other modern terminal
               emulators. */
            const char *base = strrchr(exe, '/');
            base = base ? base + 1 : exe;
            char login_arg[256];
            snprintf(login_arg, sizeof(login_arg), "-%s", base);
            char *dargv[] = { login_arg, NULL };
            execv(exe, dargv);
        }
        _exit(127);
    }

    /* Parent: set nonblocking, apply initial window size. */
    s->pty_fd = pty_fd;
    s->child_pid = child;

    int flags = fcntl(pty_fd, F_GETFL, 0);
    if (flags >= 0) fcntl(pty_fd, F_SETFL, flags | O_NONBLOCK);

    struct winsize ws = {
        .ws_row    = (unsigned short)rows,
        .ws_col    = (unsigned short)cols,
        .ws_xpixel = (unsigned short)initial_size.pixel_width,
        .ws_ypixel = (unsigned short)initial_size.pixel_height,
    };
    ioctl(pty_fd, TIOCSWINSZ, &ws);

    *out_session = s;
    return 0;
}

void laban_session_destroy(LabanSession *s) {
    if (!s) return;

    /* Flush and close the capture file before tearing down the rest. */
    if (s->capture_fd >= 0) {
        close(s->capture_fd);
        s->capture_fd = -1;
    }

    /* Close PTY first — sends SIGHUP to the child's session. */
    if (s->pty_fd >= 0) {
        close(s->pty_fd);
        s->pty_fd = -1;
    }

    /* Reap the child without blocking indefinitely. */
    if (s->child_pid > 0 && s->status == 0) {
        int ws = 0;
        int reaped = (waitpid(s->child_pid, &ws, WNOHANG) == s->child_pid);
        if (!reaped) {
            kill(s->child_pid, SIGTERM);
            for (int i = 0; i < 5 && !reaped; i++) {
                struct timespec ts = { .tv_sec = 0, .tv_nsec = 10000000 }; /* 10 ms */
                nanosleep(&ts, NULL);
                reaped = (waitpid(s->child_pid, &ws, WNOHANG) == s->child_pid);
            }
            if (!reaped) {
                kill(s->child_pid, SIGKILL);
                waitpid(s->child_pid, &ws, 0);
            }
        }
    }

    free_ghostty_resources(s);
    free(s);
}

int laban_session_poll(LabanSession *s) {
    if (!s) return -1;
    if (s->fixture_mode) return 0; /* no PTY to drain */
    if (s->status != 0) return 0;  /* already exited */

    uint8_t buf[4096];
    for (;;) {
        ssize_t n = read(s->pty_fd, buf, sizeof(buf));
        if (n > 0) {
            vt_write_capture(s, buf, (size_t)n);
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) break;

        /* n == 0 or permanent error (EIO on macOS = PTY slave closed). */
        {
            int ws = 0;
            pid_t ret = waitpid(s->child_pid, &ws, WNOHANG);
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
    return 0;
}

int laban_session_resize(LabanSession *s, LabanTerminalSize size) {
    if (!s) return -1;
    uint16_t cols = (uint16_t)size.cols;
    uint16_t rows = (uint16_t)size.rows;
    GhosttyResult r = ghostty_terminal_resize(
        s->terminal, cols, rows,
        (uint32_t)size.cell_width, (uint32_t)size.cell_height);
    if (r != GHOSTTY_SUCCESS) return -1;
    s->cols        = cols;
    s->rows        = rows;
    s->cell_width  = (uint32_t)size.cell_width;
    s->cell_height = (uint32_t)size.cell_height;
    if (s->pty_fd >= 0) {
        struct winsize ws = {
            .ws_row    = (unsigned short)rows,
            .ws_col    = (unsigned short)cols,
            .ws_xpixel = (unsigned short)size.pixel_width,
            .ws_ypixel = (unsigned short)size.pixel_height,
        };
        ioctl(s->pty_fd, TIOCSWINSZ, &ws);
    }
    return 0;
}

int laban_session_feed_output(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s || !bytes) return -1;
    vt_write_capture(s, bytes, len);
    return 0;
}

int laban_session_write(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s || !bytes) return -1;
    if (s->fixture_mode) {
        /* Fixture mode: feed bytes directly into the VT parser — no PTY involved. */
        vt_write_capture(s, bytes, len);
        return 0;
    }
    if (s->pty_fd < 0) return -1;
    return write_pty_input(s, bytes, len);
}

int laban_session_replay_pty_output(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s || !bytes) return -1;
    ghostty_terminal_vt_write(s->terminal, bytes, len);
    return 0;
}

int laban_session_snapshot(LabanSession *s, LabanSnapshot **out_snapshot) {
    if (!s || !out_snapshot) return -1;

    /* Sync render state from the terminal. */
    GhosttyResult r = ghostty_render_state_update(s->render_state, s->terminal);
    if (r != GHOSTTY_SUCCESS) return -1;

    /* Read dimensions. */
    uint16_t rs_cols = 80, rs_rows = 24;
    ghostty_render_state_get(s->render_state, GHOSTTY_RENDER_STATE_DATA_COLS, &rs_cols);
    ghostty_render_state_get(s->render_state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rs_rows);
    int rows = (int)rs_rows;
    int cols = (int)rs_cols;
    size_t cell_count = (size_t)(rows * cols);

    /* Default colors from render state. */
    GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    ghostty_render_state_colors_get(s->render_state, &colors);
    uint32_t default_fg = ((uint32_t)colors.foreground.r << 24) |
                          ((uint32_t)colors.foreground.g << 16) |
                          ((uint32_t)colors.foreground.b << 8) | 0xFF;
    uint32_t default_bg = ((uint32_t)colors.background.r << 24) |
                          ((uint32_t)colors.background.g << 16) |
                          ((uint32_t)colors.background.b << 8) | 0xFF;

    LabanSnapshot *snap = calloc(1, sizeof(LabanSnapshot));
    if (!snap) return -1;

    LabanCell *cells = calloc(cell_count, sizeof(LabanCell));
    if (!cells) { free(snap); return -1; }

    /* Pre-fill default colors for every cell. */
    for (size_t i = 0; i < cell_count; i++) {
        cells[i].foreground_rgba = default_fg;
        cells[i].background_rgba = default_bg;
    }

    /* UTF-8 storage: worst case 4 bytes per cell plus null terminator. */
    size_t utf8_cap = cell_count * 4 + 1;
    char *utf8_storage = malloc(utf8_cap);
    if (!utf8_storage) { free(cells); free(snap); return -1; }
    size_t utf8_used = 0;

    /* Hyperlink table: deduped URI strings indexed 1..N by cell.hyperlink_id.
     * Cells whose row reports HYPERLINK=true are checked via grid_ref. */
    char **hyperlink_uris = NULL;
    size_t hyperlink_count = 0;
    size_t hyperlink_cap = 0;

    /* Per-row dirty bytes — one byte per terminal row, 0 = clean, 1 = dirty.
     * Read from libghostty's GHOSTTY_ROW_DATA_DIRTY at the same point we
     * already pull GHOSTTY_ROW_DATA_RAW for the hyperlink check. */
    uint8_t *dirty_rows = calloc((size_t)rows, sizeof(uint8_t));

    /* Populate the pre-allocated row iterator from the render state. */
    ghostty_render_state_get(s->render_state,
        GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &s->row_iter);

    int row_idx = 0;
    while (ghostty_render_state_row_iterator_next(s->row_iter) && row_idx < rows) {
        /* Populate the pre-allocated cells container for this row. */
        ghostty_render_state_row_get(s->row_iter,
            GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &s->row_cells);

        /* Row has any hyperlink? Skip per-cell grid-ref lookups when not.
         * The render-state row iterator doesn't expose this directly; pull
         * the raw GhosttyRow and ask via ghostty_row_get(). The same raw
         * row gives us the per-row dirty bit for the renderer's damage
         * tracking. */
        bool row_has_hyperlink = false;
        {
            GhosttyRow raw_row = 0;
            if (ghostty_render_state_row_get(s->row_iter,
                    GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw_row) == GHOSTTY_SUCCESS) {
                ghostty_row_get(raw_row, GHOSTTY_ROW_DATA_HYPERLINK, &row_has_hyperlink);
                if (dirty_rows) {
                    bool row_dirty = false;
                    if (ghostty_row_get(raw_row, GHOSTTY_ROW_DATA_DIRTY, &row_dirty)
                            == GHOSTTY_SUCCESS) {
                        dirty_rows[row_idx] = row_dirty ? 1 : 0;
                    }
                }
            }
        }

        int col_idx = 0;
        while (ghostty_render_state_row_cells_next(s->row_cells) && col_idx < cols) {
            LabanCell *cell = &cells[row_idx * cols + col_idx];

            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            if (ghostty_render_state_row_cells_get(s->row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS) {
                cell->flags = laban_cell_flags_from_style(&style);
                cell->underline_style = (uint8_t)style.underline;
                cell->underline_color_rgba =
                    resolve_style_color_rgba(s->render_state, style.underline_color);
            }

            /* Width category (narrow / wide / spacer-tail / spacer-head). */
            GhosttyCell raw_cell = 0;
            if (ghostty_render_state_row_cells_get(s->row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw_cell) == GHOSTTY_SUCCESS) {
                GhosttyCellWide w = GHOSTTY_CELL_WIDE_NARROW;
                if (ghostty_cell_get(raw_cell, GHOSTTY_CELL_DATA_WIDE, &w) == GHOSTTY_SUCCESS) {
                    cell->wide = (uint8_t)w;
                }
            }

            /* Grapheme codepoints (0 = empty cell). */
            uint32_t grapheme_len = 0;
            ghostty_render_state_row_cells_get(s->row_cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &grapheme_len);

            if (grapheme_len > 0) {
                uint32_t codepoints[16];
                uint32_t buf_len = grapheme_len < 16 ? grapheme_len : 16;
                ghostty_render_state_row_cells_get(s->row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints);

                /* Fast-path: single ASCII printable → store as codepoint. */
                if (grapheme_len == 1 && codepoints[0] >= 0x20 && codepoints[0] <= 0x7E) {
                    cell->codepoint = codepoints[0];
                }

                /* Encode all codepoints to UTF-8. */
                cell->utf8_offset = (uint32_t)utf8_used;
                for (uint32_t i = 0; i < buf_len && utf8_used + 4 < utf8_cap; i++) {
                    uint8_t tmp[4];
                    int nb = encode_utf8(codepoints[i], tmp);
                    memcpy(utf8_storage + utf8_used, tmp, (size_t)nb);
                    utf8_used += (size_t)nb;
                }
                cell->utf8_length = (uint32_t)(utf8_used - cell->utf8_offset);
            }

            /* Foreground color (GHOSTTY_INVALID_VALUE if unset → keep default). */
            GhosttyColorRgb fg;
            if (ghostty_render_state_row_cells_get(s->row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS) {
                cell->foreground_rgba = ((uint32_t)fg.r << 24) |
                                        ((uint32_t)fg.g << 16) |
                                        ((uint32_t)fg.b << 8) | 0xFF;
            }

            /* Background color (GHOSTTY_INVALID_VALUE if unset → keep default). */
            GhosttyColorRgb bg;
            if (ghostty_render_state_row_cells_get(s->row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS) {
                cell->background_rgba = ((uint32_t)bg.r << 24) |
                                        ((uint32_t)bg.g << 16) |
                                        ((uint32_t)bg.b << 8) | 0xFF;
            }

            if ((cell->flags & LABAN_CELL_FLAG_INVERSE) != 0) {
                uint32_t swapped = cell->foreground_rgba;
                cell->foreground_rgba = cell->background_rgba;
                cell->background_rgba = swapped;
            }

            /* Hyperlink URI lookup via grid ref. Only consult when the row is
             * marked as containing hyperlinks (avoid a per-cell grid_ref walk
             * on the common no-hyperlink path). */
            if (row_has_hyperlink) {
                bool cell_has_link = false;
                if (ghostty_cell_get(raw_cell, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &cell_has_link)
                        == GHOSTTY_SUCCESS && cell_has_link) {
                    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
                    GhosttyPoint pt = {
                        .tag = GHOSTTY_POINT_TAG_VIEWPORT,
                        .value.coordinate = {
                            .x = (uint16_t)col_idx,
                            .y = (uint32_t)row_idx,
                        },
                    };
                    if (ghostty_terminal_grid_ref(s->terminal, pt, &ref) == GHOSTTY_SUCCESS) {
                        size_t uri_len = 0;
                        ghostty_grid_ref_hyperlink_uri(&ref, NULL, 0, &uri_len);
                        if (uri_len > 0 && uri_len < 4096) {
                            char *uri_buf = malloc(uri_len + 1);
                            if (uri_buf) {
                                size_t got = 0;
                                if (ghostty_grid_ref_hyperlink_uri(
                                        &ref, (uint8_t *)uri_buf, uri_len, &got) == GHOSTTY_SUCCESS
                                    && got > 0) {
                                    uri_buf[got] = '\0';
                                    /* Dedupe against existing URIs. */
                                    uint32_t found_id = 0;
                                    for (size_t i = 0; i < hyperlink_count; i++) {
                                        if (strcmp(hyperlink_uris[i], uri_buf) == 0) {
                                            found_id = (uint32_t)(i + 1);
                                            break;
                                        }
                                    }
                                    if (found_id == 0) {
                                        if (hyperlink_count == hyperlink_cap) {
                                            size_t new_cap = hyperlink_cap == 0 ? 4 : hyperlink_cap * 2;
                                            char **new_arr = realloc(hyperlink_uris,
                                                new_cap * sizeof(char *));
                                            if (new_arr) {
                                                hyperlink_uris = new_arr;
                                                hyperlink_cap = new_cap;
                                            }
                                        }
                                        if (hyperlink_count < hyperlink_cap) {
                                            hyperlink_uris[hyperlink_count] = uri_buf;
                                            hyperlink_count++;
                                            cell->hyperlink_id = (uint32_t)hyperlink_count;
                                            uri_buf = NULL; /* table owns it */
                                        }
                                    } else {
                                        cell->hyperlink_id = found_id;
                                    }
                                }
                                free(uri_buf);
                            }
                        }
                    }
                }
            }

            col_idx++;
        }
        row_idx++;
    }
    utf8_storage[utf8_used] = '\0';

    /* Cursor state from render state. The viewport-relative position is only
     * defined when the active screen is on screen; if the user has scrolled
     * into history libghostty reports HAS_VALUE = false, and we must report
     * cursor_visible = 0 so the renderer does not draw a stale (0,0) cursor. */
    int cursor_row = 0, cursor_col = 0, cursor_visible = 0;
    {
        _Bool has_cursor = 0;
        ghostty_render_state_get(s->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &has_cursor);
        if (has_cursor) {
            uint16_t cx = 0, cy = 0;
            ghostty_render_state_get(s->render_state,
                GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx);
            ghostty_render_state_get(s->render_state,
                GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy);
            cursor_col = (int)cx;
            cursor_row = (int)cy;

            _Bool vis = 1;
            ghostty_render_state_get(s->render_state,
                GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &vis);
            cursor_visible = vis ? 1 : 0;
        }
    }

    /* Dirty state. */
    GhosttyRenderStateDirty dirty_state = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_get(s->render_state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty_state);

    /* Title (borrowed — copy before any future vt_write invalidates it). */
    char *title_copy = NULL;
    {
        GhosttyString title_str = {0};
        if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title_str)
                == GHOSTTY_SUCCESS && title_str.len > 0) {
            size_t title_len =
                title_str.len < LABAN_TITLE_MAX_BYTES ? title_str.len : LABAN_TITLE_MAX_BYTES;
            title_copy = malloc(title_len + 1);
            if (title_copy) {
                memcpy(title_copy, title_str.ptr, title_len);
                title_copy[title_len] = '\0';
            }
        }
    }

    /* Mouse tracking. */
    int mouse_tracking = 0;
    {
        _Bool mt = 0;
        if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &mt)
                == GHOSTTY_SUCCESS) {
            mouse_tracking = mt ? 1 : 0;
        }
    }

    snap->rows                   = rows;
    snap->cols                   = cols;
    snap->cursor_row             = cursor_row;
    snap->cursor_col             = cursor_col;
    snap->cursor_visible         = cursor_visible;
    snap->status                 = s->status;
    snap->exit_status            = s->exit_status;
    snap->mouse_tracking         = mouse_tracking;
    snap->focus_reporting        = 0;
    snap->dirty                  = (dirty_state != GHOSTTY_RENDER_STATE_DIRTY_FALSE) ? 1 : 0;
    snap->default_foreground_rgba = default_fg;
    snap->default_background_rgba = default_bg;
    snap->title                  = title_copy;
    snap->utf8_storage    = utf8_storage;
    snap->utf8_storage_len = utf8_used;
    snap->cells           = cells;
    snap->cell_count      = cell_count;
    snap->hyperlink_uris  = (const char *const *)hyperlink_uris;
    snap->hyperlink_count = hyperlink_count;
    snap->dirty_rows      = dirty_rows;
    snap->dirty_row_count = dirty_rows ? (size_t)rows : 0;

    *out_snapshot = snap;
    return 0;
}

void laban_snapshot_destroy(LabanSnapshot *snap) {
    if (!snap) return;
    free((void *)snap->title);
    free((void *)snap->utf8_storage);
    free((void *)snap->cells);
    if (snap->hyperlink_uris) {
        for (size_t i = 0; i < snap->hyperlink_count; i++) {
            free((void *)snap->hyperlink_uris[i]);
        }
        free((void *)snap->hyperlink_uris);
    }
    free((void *)snap->dirty_rows);
    free(snap);
}

int laban_session_render_dirty(LabanSession *session, int *out_dirty) {
    if (!session || !out_dirty) return -1;
    ghostty_render_state_update(session->render_state, session->terminal);
    GhosttyRenderStateDirty dirty_state = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_get(session->render_state,
        GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty_state);
    *out_dirty = (dirty_state != GHOSTTY_RENDER_STATE_DIRTY_FALSE) ? 1 : 0;
    return 0;
}

int laban_session_mark_rendered(LabanSession *session) {
    if (!session) return -1;

    /* Clear global dirty state. */
    GhosttyRenderStateDirty clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_set(session->render_state,
        GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean);

    /* Clear row-level dirty flags by iterating all rows. */
    ghostty_render_state_get(session->render_state,
        GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &session->row_iter);

    bool row_clean = false;
    while (ghostty_render_state_row_iterator_next(session->row_iter)) {
        ghostty_render_state_row_set(session->row_iter,
            GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &row_clean);
    }

    return 0;
}

/* --- Viewport scrolling --- */

int laban_session_consume_title(LabanSession *s, char *buf, size_t capacity) {
    if (!s || !buf || capacity == 0) return -1;
    if (!s->title_dirty) return 0;
    s->title_dirty = 0;
    GhosttyString title_str = {0};
    if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title_str)
            != GHOSTTY_SUCCESS || title_str.len == 0) {
        buf[0] = '\0';
        return 1;
    }
    size_t copy_len = title_str.len < capacity - 1 ? title_str.len : capacity - 1;
    memcpy(buf, title_str.ptr, copy_len);
    buf[copy_len] = '\0';
    return 1;
}

static void copy_cstr(char *dst, size_t dst_cap, const char *src) {
    if (!dst || dst_cap == 0) return;
    if (!src) src = "";
    snprintf(dst, dst_cap, "%s", src);
}

static int pid_parent(pid_t pid, pid_t *out_parent) {
    if (pid <= 0 || !out_parent) return 0;
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof(info));
    int rc = proc_pidinfo((int)pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (rc != (int)sizeof(info)) return 0;
    *out_parent = (pid_t)info.pbi_ppid;
    return 1;
}

static int pid_is_descendant_or_self(pid_t pid, pid_t ancestor) {
    if (pid <= 0 || ancestor <= 0) return 0;
    for (int depth = 0; depth < 64 && pid > 1; depth++) {
        if (pid == ancestor) return 1;
        pid_t parent = -1;
        if (!pid_parent(pid, &parent)) return 0;
        if (parent <= 0 || parent == pid) return 0;
        pid = parent;
    }
    return 0;
}

int laban_session_process_metadata(
    LabanSession *s,
    int *out_child_pid,
    int *out_foreground_pid,
    char *process_buf,
    size_t process_capacity,
    char *command_buf,
    size_t command_capacity,
    char *cwd_buf,
    size_t cwd_capacity
) {
    if (!s) return -1;

    copy_cstr(process_buf, process_capacity, "");
    copy_cstr(command_buf, command_capacity, "");
    copy_cstr(cwd_buf, cwd_capacity, "");

    if (out_child_pid) *out_child_pid = s->child_pid;

    pid_t foreground_pid = -1;
    if (!s->fixture_mode && s->pty_fd >= 0) {
        pid_t pgrp = tcgetpgrp(s->pty_fd);
        if (pid_is_descendant_or_self(pgrp, s->child_pid)) foreground_pid = pgrp;
    }
    if (foreground_pid <= 0 && s->child_pid > 0) foreground_pid = s->child_pid;
    if (out_foreground_pid) *out_foreground_pid = foreground_pid;

    if (foreground_pid <= 0) {
        copy_cstr(cwd_buf, cwd_capacity, s->launch_cwd);
        return 0;
    }

    if (process_buf && process_capacity > 0) {
        char name[256] = {0};
        if (proc_name((int)foreground_pid, name, sizeof(name)) > 0) {
            copy_cstr(process_buf, process_capacity, name);
        }
    }

    if (command_buf && command_capacity > 0) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath((int)foreground_pid, path, sizeof(path)) > 0) {
            copy_cstr(command_buf, command_capacity, path);
        }
    }

    if (cwd_buf && cwd_capacity > 0) {
        struct proc_vnodepathinfo info;
        memset(&info, 0, sizeof(info));
        int rc = proc_pidinfo(
            (int)foreground_pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            sizeof(info)
        );
        if (rc == (int)sizeof(info) && info.pvi_cdir.vip_path[0]) {
            copy_cstr(cwd_buf, cwd_capacity, info.pvi_cdir.vip_path);
        } else {
            copy_cstr(cwd_buf, cwd_capacity, s->launch_cwd);
        }
    }

    return 0;
}

int laban_session_scroll_viewport(LabanSession *s, int delta_rows) {
    if (!s) return -1;
    GhosttyTerminalScrollViewport behavior = {
        .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA,
        .value.delta = (intptr_t)delta_rows,
    };
    ghostty_terminal_scroll_viewport(s->terminal, behavior);
    /* Mark render state dirty so next snapshot picks up the change. */
    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
    ghostty_render_state_set(s->render_state,
        GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty);
    return 0;
}

int laban_session_viewport_state(LabanSession *s, LabanViewportState *out_state) {
    if (!s || !out_state) return -1;
    memset(out_state, 0, sizeof(*out_state));

    GhosttyTerminalScrollbar scrollbar;
    if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar)
            == GHOSTTY_SUCCESS) {
        out_state->total_rows = (int)scrollbar.total;
        out_state->viewport_offset = (int)scrollbar.offset;
        out_state->viewport_rows = (int)scrollbar.len;
    }

    size_t sbr = 0;
    if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &sbr)
            == GHOSTTY_SUCCESS) {
        out_state->scrollback_rows = (int)sbr;
    }

    _Bool mt = 0;
    if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &mt)
            == GHOSTTY_SUCCESS) {
        out_state->mouse_tracking = mt ? 1 : 0;
    }

    return 0;
}

/* --- Mouse encoding and sending --- */

static GhosttyMouseButton map_laban_button(LabanMouseButton btn) {
    switch (btn) {
        case LABAN_MOUSE_BUTTON_LEFT:      return GHOSTTY_MOUSE_BUTTON_LEFT;
        case LABAN_MOUSE_BUTTON_MIDDLE:    return GHOSTTY_MOUSE_BUTTON_MIDDLE;
        case LABAN_MOUSE_BUTTON_RIGHT:     return GHOSTTY_MOUSE_BUTTON_RIGHT;
        case LABAN_MOUSE_BUTTON_WHEEL_UP:  return GHOSTTY_MOUSE_BUTTON_FOUR;
        case LABAN_MOUSE_BUTTON_WHEEL_DOWN: return GHOSTTY_MOUSE_BUTTON_FIVE;
        default:                            return GHOSTTY_MOUSE_BUTTON_UNKNOWN;
    }
}

static int laban_mouse_button_can_be_held(LabanMouseButton btn) {
    return btn == LABAN_MOUSE_BUTTON_LEFT ||
           btn == LABAN_MOUSE_BUTTON_MIDDLE ||
           btn == LABAN_MOUSE_BUTTON_RIGHT;
}

int laban_session_encode_mouse(
    LabanSession *s,
    const LabanMouseEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (!s || !event || !out_len) return -1;
    *out_len = 0;

    /* Sync encoder options from terminal state. */
    ghostty_mouse_encoder_setopt_from_terminal(s->mouse_encoder, s->terminal);

    /* Set geometry from event. */
    GhosttyMouseEncoderSize enc_size = {
        .size = sizeof(GhosttyMouseEncoderSize),
        .screen_width = (uint32_t)(event->screen_width > 0 ? event->screen_width : 800),
        .screen_height = (uint32_t)(event->screen_height > 0 ? event->screen_height : 600),
        .cell_width = (uint32_t)(event->cell_width > 0 ? event->cell_width : 8),
        .cell_height = (uint32_t)(event->cell_height > 0 ? event->cell_height : 16),
        .padding_top = 0,
        .padding_bottom = 0,
        .padding_right = 0,
        .padding_left = 0,
    };
    ghostty_mouse_encoder_setopt(s->mouse_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &enc_size);

    LabanMouseButton effective_button = event->button;
    if ((event->action == LABAN_MOUSE_ACTION_MOTION ||
         event->action == LABAN_MOUSE_ACTION_RELEASE) &&
        effective_button == LABAN_MOUSE_BUTTON_NONE &&
        laban_mouse_button_can_be_held(s->mouse_pressed_button)) {
        effective_button = s->mouse_pressed_button;
    }

    if (event->action == LABAN_MOUSE_ACTION_PRESS &&
        laban_mouse_button_can_be_held(event->button)) {
        s->mouse_button_pressed = 1;
        s->mouse_pressed_button = event->button;
    } else if (event->action == LABAN_MOUSE_ACTION_RELEASE &&
               laban_mouse_button_can_be_held(effective_button)) {
        s->mouse_button_pressed = 0;
        s->mouse_pressed_button = LABAN_MOUSE_BUTTON_NONE;
    }

    /* Set any-button-pressed state. */
    bool pressed = (s->mouse_button_pressed != 0);
    ghostty_mouse_encoder_setopt(s->mouse_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);

    /* Create a Ghostty mouse event. */
    GhosttyMouseEvent gev = NULL;
    if (ghostty_mouse_event_new(NULL, &gev) != GHOSTTY_SUCCESS) return -1;

    /* Action. */
    GhosttyMouseAction ga = GHOSTTY_MOUSE_ACTION_PRESS;
    switch (event->action) {
        case LABAN_MOUSE_ACTION_RELEASE: ga = GHOSTTY_MOUSE_ACTION_RELEASE; break;
        case LABAN_MOUSE_ACTION_MOTION:  ga = GHOSTTY_MOUSE_ACTION_MOTION; break;
        default: break;
    }
    ghostty_mouse_event_set_action(gev, ga);

    /* Button. */
    GhosttyMouseButton gb = map_laban_button(effective_button);
    if (gb == GHOSTTY_MOUSE_BUTTON_UNKNOWN) {
        ghostty_mouse_event_clear_button(gev);
    } else {
        ghostty_mouse_event_set_button(gev, gb);
    }

    /* Modifiers. */
    GhosttyMods mods = (GhosttyMods)(event->modifiers & 0xFFFF);
    ghostty_mouse_event_set_mods(gev, mods);

    /* Position. */
    GhosttyMousePosition pos = { .x = event->x, .y = event->y };
    ghostty_mouse_event_set_position(gev, pos);

    /* Encode. */
    char *buf = (char *)out_bytes;
    GhosttyResult r = ghostty_mouse_encoder_encode(
        s->mouse_encoder, gev, buf, out_capacity, out_len);

    ghostty_mouse_event_free(gev);

    return (r == GHOSTTY_SUCCESS) ? 0 : -1;
}

/* --- Paste --- */

int laban_session_drain_response(
    LabanSession *s, uint8_t *out_bytes, size_t out_capacity, size_t *out_len) {
    if (!s || !out_len) return -1;
    *out_len = 0;
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

int laban_paste_is_safe(const uint8_t *bytes, size_t len) {
    if (!bytes && len > 0) return 0;
    return ghostty_paste_is_safe((const char *)bytes, len) ? 1 : 0;
}

int laban_session_bracketed_paste_enabled(LabanSession *s, int *out_enabled) {
    if (!s || !out_enabled) return -1;
    bool enabled = false;
    GhosttyResult r = ghostty_terminal_mode_get(
        s->terminal, GHOSTTY_MODE_BRACKETED_PASTE, &enabled);
    if (r != GHOSTTY_SUCCESS) return -1;
    *out_enabled = enabled ? 1 : 0;
    return 0;
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
    if (!s || !out_len || !out_bracketed) return -1;
    *out_len = 0;
    *out_bracketed = 0;

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
    if (!s) return -1;

    /* +12 for ESC[200~ (7 bytes) + ESC[201~ (7 bytes) = 14 bytes worst case.
       Using 16 for alignment. */
    size_t cap = len + 16;
    uint8_t *buf = malloc(cap);
    if (!buf) return -1;

    size_t enc_len = 0;
    int bracketed = 0;
    int r = laban_session_encode_paste(s, bytes, len, buf, cap, &enc_len, &bracketed);
    if (r != 0) { free(buf); return -1; }

    if (s->fixture_mode) {
        vt_write_capture(s, buf, enc_len);
    } else {
        if (write_pty_input(s, buf, enc_len) != 0) { free(buf); return -1; }
    }

    if (out_result) {
        out_result->bracketed = bracketed;
        out_result->bytes_written = enc_len;
    }

    free(buf);
    return 0;
}

/* --- Capture --- */

int laban_session_capture_start(LabanSession *s, const char *path) {
    if (!s || !path) return -1;
    if (s->capture_fd >= 0) return -1; /* already capturing */
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    s->capture_fd = fd;
    return 0;
}

int laban_session_capture_stop(LabanSession *s) {
    if (!s) return -1;
    if (s->capture_fd >= 0) {
        close(s->capture_fd);
        s->capture_fd = -1;
    }
    return 0;
}

int laban_session_capture_active(LabanSession *s) {
    if (!s) return 0;
    return s->capture_fd >= 0 ? 1 : 0;
}

int laban_session_set_capture_callback(
    LabanSession *s,
    LabanCaptureBytesCallback callback,
    void *userdata
) {
    if (!s) return -1;
    s->capture_callback = callback;
    s->capture_userdata = userdata;
    return 0;
}

int laban_session_set_tab_status_callback(
    LabanSession *s,
    LabanTabStatusCallback callback,
    void *userdata
) {
    if (!s) return -1;
    s->tab_status_callback = callback;
    s->tab_status_userdata = userdata;
    /* Reset scanner state so a stale partial sequence (from before the
     * callback was attached) doesn't fire on the new observer. */
    s->tab_status_scanner.state = TS_NORMAL;
    s->tab_status_scanner.payload_len = 0;
    s->tab_status_scanner.num_len = 0;
    return 0;
}

int laban_session_send_mouse(LabanSession *s, const LabanMouseEvent *event) {
    if (!s) return -1;
    if (s->fixture_mode) {
        /* Fixture mode: no PTY to write to; encoding is meaningful but sending is not. */
        return 0;
    }
    if (s->pty_fd < 0) return -1;

    uint8_t buf[128];
    size_t len = 0;
    int r = laban_session_encode_mouse(s, event, buf, sizeof(buf), &len);
    if (r != 0) return r;
    if (len == 0) return 0;  /* terminal says nothing to report */

    return write_pty_input(s, buf, len);
}

LabanExitState laban_session_exit_state(LabanSession *session) {
    LabanExitState r = { session->status, session->exit_status };
    return r;
}

/* --- Key encoding and sending --- */

static GhosttyKeyAction map_laban_key_action(LabanKeyAction action) {
    switch (action) {
        case LABAN_KEY_ACTION_PRESS:   return GHOSTTY_KEY_ACTION_PRESS;
        case LABAN_KEY_ACTION_REPEAT:  return GHOSTTY_KEY_ACTION_REPEAT;
        case LABAN_KEY_ACTION_RELEASE: return GHOSTTY_KEY_ACTION_RELEASE;
        default:                        return GHOSTTY_KEY_ACTION_PRESS;
    }
}

static GhosttyKey map_laban_key(LabanKey key) {
    switch (key) {
        case LABAN_KEY_BACKQUOTE:     return GHOSTTY_KEY_BACKQUOTE;
        case LABAN_KEY_BACKSLASH:     return GHOSTTY_KEY_BACKSLASH;
        case LABAN_KEY_BRACKET_LEFT:  return GHOSTTY_KEY_BRACKET_LEFT;
        case LABAN_KEY_BRACKET_RIGHT: return GHOSTTY_KEY_BRACKET_RIGHT;
        case LABAN_KEY_COMMA:         return GHOSTTY_KEY_COMMA;
        case LABAN_KEY_DIGIT_0:       return GHOSTTY_KEY_DIGIT_0;
        case LABAN_KEY_DIGIT_1:       return GHOSTTY_KEY_DIGIT_1;
        case LABAN_KEY_DIGIT_2:       return GHOSTTY_KEY_DIGIT_2;
        case LABAN_KEY_DIGIT_3:       return GHOSTTY_KEY_DIGIT_3;
        case LABAN_KEY_DIGIT_4:       return GHOSTTY_KEY_DIGIT_4;
        case LABAN_KEY_DIGIT_5:       return GHOSTTY_KEY_DIGIT_5;
        case LABAN_KEY_DIGIT_6:       return GHOSTTY_KEY_DIGIT_6;
        case LABAN_KEY_DIGIT_7:       return GHOSTTY_KEY_DIGIT_7;
        case LABAN_KEY_DIGIT_8:       return GHOSTTY_KEY_DIGIT_8;
        case LABAN_KEY_DIGIT_9:       return GHOSTTY_KEY_DIGIT_9;
        case LABAN_KEY_EQUAL:         return GHOSTTY_KEY_EQUAL;
        case LABAN_KEY_A:             return GHOSTTY_KEY_A;
        case LABAN_KEY_B:             return GHOSTTY_KEY_B;
        case LABAN_KEY_C:             return GHOSTTY_KEY_C;
        case LABAN_KEY_D:             return GHOSTTY_KEY_D;
        case LABAN_KEY_E:             return GHOSTTY_KEY_E;
        case LABAN_KEY_F:             return GHOSTTY_KEY_F;
        case LABAN_KEY_G:             return GHOSTTY_KEY_G;
        case LABAN_KEY_H:             return GHOSTTY_KEY_H;
        case LABAN_KEY_I:             return GHOSTTY_KEY_I;
        case LABAN_KEY_J:             return GHOSTTY_KEY_J;
        case LABAN_KEY_K:             return GHOSTTY_KEY_K;
        case LABAN_KEY_L:             return GHOSTTY_KEY_L;
        case LABAN_KEY_M:             return GHOSTTY_KEY_M;
        case LABAN_KEY_N:             return GHOSTTY_KEY_N;
        case LABAN_KEY_O:             return GHOSTTY_KEY_O;
        case LABAN_KEY_P:             return GHOSTTY_KEY_P;
        case LABAN_KEY_Q:             return GHOSTTY_KEY_Q;
        case LABAN_KEY_R:             return GHOSTTY_KEY_R;
        case LABAN_KEY_S:             return GHOSTTY_KEY_S;
        case LABAN_KEY_T:             return GHOSTTY_KEY_T;
        case LABAN_KEY_U:             return GHOSTTY_KEY_U;
        case LABAN_KEY_V:             return GHOSTTY_KEY_V;
        case LABAN_KEY_W:             return GHOSTTY_KEY_W;
        case LABAN_KEY_X:             return GHOSTTY_KEY_X;
        case LABAN_KEY_Y:             return GHOSTTY_KEY_Y;
        case LABAN_KEY_Z:             return GHOSTTY_KEY_Z;
        case LABAN_KEY_MINUS:         return GHOSTTY_KEY_MINUS;
        case LABAN_KEY_PERIOD:        return GHOSTTY_KEY_PERIOD;
        case LABAN_KEY_QUOTE:         return GHOSTTY_KEY_QUOTE;
        case LABAN_KEY_SEMICOLON:     return GHOSTTY_KEY_SEMICOLON;
        case LABAN_KEY_SLASH:         return GHOSTTY_KEY_SLASH;
        case LABAN_KEY_BACKSPACE:     return GHOSTTY_KEY_BACKSPACE;
        case LABAN_KEY_ENTER:         return GHOSTTY_KEY_ENTER;
        case LABAN_KEY_SPACE:         return GHOSTTY_KEY_SPACE;
        case LABAN_KEY_TAB:           return GHOSTTY_KEY_TAB;
        case LABAN_KEY_DELETE:        return GHOSTTY_KEY_DELETE;
        case LABAN_KEY_END:           return GHOSTTY_KEY_END;
        case LABAN_KEY_HOME:          return GHOSTTY_KEY_HOME;
        case LABAN_KEY_INSERT:        return GHOSTTY_KEY_INSERT;
        case LABAN_KEY_PAGE_DOWN:     return GHOSTTY_KEY_PAGE_DOWN;
        case LABAN_KEY_PAGE_UP:       return GHOSTTY_KEY_PAGE_UP;
        case LABAN_KEY_ARROW_DOWN:    return GHOSTTY_KEY_ARROW_DOWN;
        case LABAN_KEY_ARROW_LEFT:    return GHOSTTY_KEY_ARROW_LEFT;
        case LABAN_KEY_ARROW_RIGHT:   return GHOSTTY_KEY_ARROW_RIGHT;
        case LABAN_KEY_ARROW_UP:      return GHOSTTY_KEY_ARROW_UP;
        case LABAN_KEY_ESCAPE:        return GHOSTTY_KEY_ESCAPE;
        case LABAN_KEY_F1:            return GHOSTTY_KEY_F1;
        case LABAN_KEY_F2:            return GHOSTTY_KEY_F2;
        case LABAN_KEY_F3:            return GHOSTTY_KEY_F3;
        case LABAN_KEY_F4:            return GHOSTTY_KEY_F4;
        case LABAN_KEY_F5:            return GHOSTTY_KEY_F5;
        case LABAN_KEY_F6:            return GHOSTTY_KEY_F6;
        case LABAN_KEY_F7:            return GHOSTTY_KEY_F7;
        case LABAN_KEY_F8:            return GHOSTTY_KEY_F8;
        case LABAN_KEY_F9:            return GHOSTTY_KEY_F9;
        case LABAN_KEY_F10:           return GHOSTTY_KEY_F10;
        case LABAN_KEY_F11:           return GHOSTTY_KEY_F11;
        case LABAN_KEY_F12:           return GHOSTTY_KEY_F12;
        case LABAN_KEY_F13:           return GHOSTTY_KEY_F13;
        case LABAN_KEY_F14:           return GHOSTTY_KEY_F14;
        case LABAN_KEY_F15:           return GHOSTTY_KEY_F15;
        case LABAN_KEY_F16:           return GHOSTTY_KEY_F16;
        case LABAN_KEY_F17:           return GHOSTTY_KEY_F17;
        case LABAN_KEY_F18:           return GHOSTTY_KEY_F18;
        case LABAN_KEY_F19:           return GHOSTTY_KEY_F19;
        case LABAN_KEY_F20:           return GHOSTTY_KEY_F20;
        case LABAN_KEY_F21:           return GHOSTTY_KEY_F21;
        case LABAN_KEY_F22:           return GHOSTTY_KEY_F22;
        case LABAN_KEY_F23:           return GHOSTTY_KEY_F23;
        case LABAN_KEY_F24:           return GHOSTTY_KEY_F24;
        default:                       return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

/* Returns non-zero when utf8 is a C0 control byte or a macOS PUA function-key
 * scalar (U+F700-U+F8FF). The libghostty encoder does not want these; pass
 * NULL instead and let it derive output from the logical key. */
static int utf8_is_c0_or_pua(const char *utf8, size_t len) {
    if (!utf8 || len == 0) return 0;
    if (len == 1) {
        uint8_t b = (uint8_t)utf8[0];
        return b <= 0x1Fu || b == 0x7Fu;
    }
    /* U+F700-U+F8FF in UTF-8: 0xEF 0x9C-0xA3 0x80-0xBF */
    if (len == 3) {
        uint8_t b0 = (uint8_t)utf8[0];
        uint8_t b1 = (uint8_t)utf8[1];
        return b0 == 0xEFu && b1 >= 0x9Cu && b1 <= 0xA3u;
    }
    return 0;
}

/* Distinct return value when the output buffer was too small.
 * *out_len will contain the required size. */
#define LABAN_KEY_ENCODE_OUT_OF_SPACE 1

int laban_session_encode_key(
    LabanSession *s,
    const LabanKeyEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (!s || !event || !out_len) return -1;
    *out_len = 0;

    /* Sync encoder from terminal state; this resets option-as-alt to FALSE. */
    ghostty_key_encoder_setopt_from_terminal(s->key_encoder, s->terminal);

    /* Keep option-as-alt false — a future settings path can override this. */
    GhosttyOptionAsAlt opt_as_alt = GHOSTTY_OPTION_AS_ALT_FALSE;
    ghostty_key_encoder_setopt(s->key_encoder,
        GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &opt_as_alt);

    ghostty_key_event_set_action(s->key_event, map_laban_key_action(event->action));
    ghostty_key_event_set_key(s->key_event, map_laban_key(event->key));
    ghostty_key_event_set_mods(s->key_event, (GhosttyMods)(event->modifiers & 0xFFFF));
    ghostty_key_event_set_consumed_mods(s->key_event,
        (GhosttyMods)(event->consumed_modifiers & 0xFFFF));
    ghostty_key_event_set_composing(s->key_event, (bool)(event->composing != 0));
    ghostty_key_event_set_unshifted_codepoint(s->key_event, event->unshifted_codepoint);

    if (event->utf8 && event->utf8_len > 0 &&
        !utf8_is_c0_or_pua(event->utf8, event->utf8_len)) {
        ghostty_key_event_set_utf8(s->key_event, event->utf8, event->utf8_len);
    } else {
        ghostty_key_event_set_utf8(s->key_event, NULL, 0);
    }

    GhosttyResult r = ghostty_key_encoder_encode(
        s->key_encoder, s->key_event,
        (char *)out_bytes, out_capacity, out_len);

    /* Clear the UTF-8 pointer so the persistent event never holds a stale pointer. */
    ghostty_key_event_set_utf8(s->key_event, NULL, 0);

    if (r == GHOSTTY_SUCCESS) return 0;
    if (r == GHOSTTY_OUT_OF_SPACE) return LABAN_KEY_ENCODE_OUT_OF_SPACE;
    return -1;
}

int laban_session_send_key(LabanSession *s, const LabanKeyEvent *event) {
    if (!s) return -1;

    uint8_t stack_buf[128];
    size_t len = 0;
    int rc = laban_session_encode_key(s, event, stack_buf, sizeof(stack_buf), &len);

    if (rc == LABAN_KEY_ENCODE_OUT_OF_SPACE) {
        /* len now holds required size; heap-allocate and re-encode. */
        uint8_t *heap_buf = malloc(len);
        if (!heap_buf) return -1;
        size_t heap_len = 0;
        rc = laban_session_encode_key(s, event, heap_buf, len, &heap_len);
        if (rc == 0 && heap_len > 0 && !s->fixture_mode && s->pty_fd >= 0) {
            if (write_pty_input(s, heap_buf, heap_len) != 0) {
                free(heap_buf);
                return -1;
            }
        }
        free(heap_buf);
        return rc;
    }

    if (rc != 0) return rc;
    if (len == 0) return 0;
    if (s->fixture_mode) return 0;
    if (s->pty_fd < 0) return -1;

    return write_pty_input(s, stack_buf, len);
}
