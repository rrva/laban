#include "LabanTerminalCore.h"
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/render.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

struct LabanSession {
    GhosttyTerminal terminal;
    GhosttyRenderState render_state;
    GhosttyRenderStateRowIterator row_iter;   /* pre-allocated; reused each snapshot */
    GhosttyRenderStateRowCells row_cells;     /* pre-allocated; reused each snapshot */
    int pty_fd;          /* master side; -1 in fixture mode */
    pid_t child_pid;     /* -1 in fixture mode */
    int status;          /* 0=running, 1=exited, 2=signaled */
    int exit_status;
    int fixture_mode;
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

int laban_session_create(
    const LabanLaunchConfig *config,
    LabanTerminalSize initial_size,
    LabanSession **out_session
) {
    if (!config || !out_session) return -1;
    if (!config->fixture_mode) return -1; /* PTY lifecycle not implemented in this shard */

    LabanSession *s = calloc(1, sizeof(struct LabanSession));
    if (!s) return -1;
    s->pty_fd = -1;
    s->child_pid = -1;
    s->fixture_mode = 1;

    uint16_t cols = (uint16_t)(initial_size.cols > 0 ? initial_size.cols : 80);
    uint16_t rows = (uint16_t)(initial_size.rows > 0 ? initial_size.rows : 24);
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

    *out_session = s;
    return 0;
}

void laban_session_destroy(LabanSession *s) {
    if (!s) return;
    if (s->pty_fd >= 0) close(s->pty_fd);
    ghostty_render_state_row_cells_free(s->row_cells);
    ghostty_render_state_row_iterator_free(s->row_iter);
    ghostty_render_state_free(s->render_state);
    ghostty_terminal_free(s->terminal);
    free(s);
}

int laban_session_poll(LabanSession *s) {
    if (!s) return -1;
    if (s->fixture_mode) return 0; /* no PTY to drain */
    return -1; /* PTY poll not implemented in this shard */
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
            .ws_row  = (unsigned short)rows,
            .ws_col  = (unsigned short)cols,
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

    snap->rows           = rows;
    snap->cols           = cols;
    snap->cursor_row     = cursor_row;
    snap->cursor_col     = cursor_col;
    snap->cursor_visible = cursor_visible;
    snap->status         = s->status;
    snap->exit_status    = s->exit_status;
    snap->mouse_tracking = mouse_tracking;
    snap->focus_reporting = 0;
    snap->dirty          = (dirty_state != GHOSTTY_RENDER_STATE_DIRTY_FALSE) ? 1 : 0;
    snap->title          = title_copy;
    snap->utf8_storage   = utf8_storage;
    snap->utf8_storage_len = utf8_used;
    snap->cells          = cells;
    snap->cell_count     = cell_count;

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
