#include "LabanTerminalCore.h"
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/render.h>
#include <ghostty/vt/mouse.h>
#include <util.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pwd.h>
#include <time.h>

struct LabanSession {
    GhosttyTerminal terminal;
    GhosttyRenderState render_state;
    GhosttyRenderStateRowIterator row_iter;   /* pre-allocated; reused each snapshot */
    GhosttyRenderStateRowCells row_cells;     /* pre-allocated; reused each snapshot */
    int pty_fd;          /* master side; -1 in fixture mode */
    pid_t child_pid;     /* -1 in fixture mode */
    int status;          /* 0=running, 1=exited normally, 2=signaled */
    int exit_status;
    int fixture_mode;
    GhosttyMouseEncoder mouse_encoder;
    int mouse_button_pressed;  /* boolean: is any mouse button currently down */
    LabanMouseButton mouse_pressed_button;
};

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

static void free_ghostty_resources(LabanSession *s) {
    ghostty_render_state_row_cells_free(s->row_cells);
    ghostty_render_state_row_iterator_free(s->row_iter);
    ghostty_render_state_free(s->render_state);
    if (s->mouse_encoder) ghostty_mouse_encoder_free(s->mouse_encoder);
    ghostty_terminal_free(s->terminal);
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
    s->fixture_mode = config->fixture_mode;

    GhosttyTerminalOptions opts = { .cols = cols, .rows = rows, .max_scrollback = 1000 };

    GhosttyResult r = ghostty_terminal_new(NULL, &s->terminal, opts);
    if (r != GHOSTTY_SUCCESS) { free(s); return -1; }

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

    if (config->fixture_mode) {
        *out_session = s;
        return 0;
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

        /* Change to home directory if no explicit cwd is provided. */
        if (config->cwd && config->cwd[0]) {
            chdir(config->cwd);
        } else {
            const char *home = getenv("HOME");
            if (!home || !home[0]) {
                struct passwd *pw = getpwuid(getuid());
                if (pw && pw->pw_dir) home = pw->pw_dir;
            }
            if (home && home[0]) chdir(home);
        }

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
            ghostty_terminal_vt_write(s->terminal, buf, (size_t)n);
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

int laban_session_write(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s || !bytes) return -1;
    if (s->fixture_mode) {
        /* Fixture mode: feed bytes directly into the VT parser — no PTY involved. */
        ghostty_terminal_vt_write(s->terminal, bytes, len);
        return 0;
    }
    if (s->pty_fd < 0) return -1;
    ssize_t n = write(s->pty_fd, bytes, len);
    return (n < 0) ? -1 : 0;
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

    /* Populate the pre-allocated row iterator from the render state. */
    ghostty_render_state_get(s->render_state,
        GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &s->row_iter);

    int row_idx = 0;
    while (ghostty_render_state_row_iterator_next(s->row_iter) && row_idx < rows) {
        /* Populate the pre-allocated cells container for this row. */
        ghostty_render_state_row_get(s->row_iter,
            GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &s->row_cells);

        int col_idx = 0;
        while (ghostty_render_state_row_cells_next(s->row_cells) && col_idx < cols) {
            LabanCell *cell = &cells[row_idx * cols + col_idx];

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

            col_idx++;
        }
        row_idx++;
    }
    utf8_storage[utf8_used] = '\0';

    /* Cursor state from render state. */
    int cursor_row = 0, cursor_col = 0, cursor_visible = 1;
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
        }
        _Bool vis = 1;
        ghostty_render_state_get(s->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &vis);
        cursor_visible = vis ? 1 : 0;
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
            title_copy = malloc(title_str.len + 1);
            if (title_copy) {
                memcpy(title_copy, title_str.ptr, title_str.len);
                title_copy[title_str.len] = '\0';
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

    *out_snapshot = snap;
    return 0;
}

void laban_snapshot_destroy(LabanSnapshot *snap) {
    if (!snap) return;
    free((void *)snap->title);
    free((void *)snap->utf8_storage);
    free((void *)snap->cells);
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

    ssize_t n = write(s->pty_fd, buf, len);
    return (n < 0) ? -1 : 0;
}
