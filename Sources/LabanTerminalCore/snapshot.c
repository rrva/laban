#include "session_internal.h"

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

static LabanMouseTrackingMode laban_snapshot_mouse_tracking_mode_locked(LabanSession *s) {
    int active = 0;
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_ANY_MOUSE, &active) == 0 && active) {
        return LABAN_MOUSE_TRACKING_ANY;
    }
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_BUTTON_MOUSE, &active) == 0 && active) {
        return LABAN_MOUSE_TRACKING_BUTTON;
    }
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_NORMAL_MOUSE, &active) == 0 && active) {
        return LABAN_MOUSE_TRACKING_NORMAL;
    }
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_X10_MOUSE, &active) == 0 && active) {
        return LABAN_MOUSE_TRACKING_X10;
    }
    return LABAN_MOUSE_TRACKING_NONE;
}

static LabanMouseFormat laban_snapshot_mouse_format_locked(LabanSession *s) {
    int active = 0;
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_SGR_PIXELS_MOUSE, &active) == 0
            && active) {
        return LABAN_MOUSE_FORMAT_SGR_PIXELS;
    }
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_SGR_MOUSE, &active) == 0 && active) {
        return LABAN_MOUSE_FORMAT_SGR;
    }
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_URXVT_MOUSE, &active) == 0 && active) {
        return LABAN_MOUSE_FORMAT_URXVT;
    }
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_UTF8_MOUSE, &active) == 0 && active) {
        return LABAN_MOUSE_FORMAT_UTF8;
    }
    return LABAN_MOUSE_FORMAT_X10;
}

static int ensure_utf8_capacity(char **storage, size_t *cap, size_t used, size_t extra) {
    if (used > SIZE_MAX - 1) return -1;
    if (extra > SIZE_MAX - used - 1) return -1;
    size_t required = used + extra + 1;
    if (required <= *cap) return 0;

    size_t new_cap = *cap ? *cap : 1;
    while (new_cap < required) {
        if (new_cap > SIZE_MAX / 2) {
            new_cap = required;
            break;
        }
        new_cap *= 2;
    }

    char *new_storage = realloc(*storage, new_cap);
    if (!new_storage) return -1;
    *storage = new_storage;
    *cap = new_cap;
    return 0;
}

static size_t utf8_valid_prefix_len(const uint8_t *bytes, size_t len) {
    if (!bytes) return 0;
    size_t i = 0;
    size_t valid = 0;
    while (i < len) {
        uint8_t b = (uint8_t)bytes[i];
        size_t need = 0;
        if (b < 0x80) {
            need = 1;
        } else if (b >= 0xC2 && b <= 0xDF) {
            need = 2;
        } else if (b >= 0xE0 && b <= 0xEF) {
            need = 3;
        } else if (b >= 0xF0 && b <= 0xF4) {
            need = 4;
        } else {
            break;
        }
        if (need > len - i) break;
        int ok = 1;
        for (size_t j = 1; j < need; j++) {
            uint8_t c = (uint8_t)bytes[i + j];
            if ((c & 0xC0) != 0x80) {
                ok = 0;
                break;
            }
        }
        if (!ok) break;

        /* Reject overlongs, surrogates, and values above U+10FFFF. */
        if (need == 3) {
            uint8_t c1 = (uint8_t)bytes[i + 1];
            if ((b == 0xE0 && c1 < 0xA0) || (b == 0xED && c1 >= 0xA0)) break;
        } else if (need == 4) {
            uint8_t c1 = (uint8_t)bytes[i + 1];
            if ((b == 0xF0 && c1 < 0x90) || (b == 0xF4 && c1 >= 0x90)) break;
        }

        i += need;
        valid = i;
    }
    return valid;
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

static int store_last_snapshot_dirty_rows(
    LabanSession *s,
    const uint8_t *dirty_rows,
    size_t row_count
) {
    if (!s || (!dirty_rows && row_count > 0)) return -1;
    if (row_count > s->last_snapshot_dirty_row_cap) {
        uint8_t *new_rows = realloc(s->last_snapshot_dirty_rows, row_count);
        if (!new_rows) return -1;
        s->last_snapshot_dirty_rows = new_rows;
        s->last_snapshot_dirty_row_cap = row_count;
    }
    if (row_count > 0) {
        memcpy(s->last_snapshot_dirty_rows, dirty_rows, row_count);
    }
    s->last_snapshot_dirty_row_count = row_count;
    s->last_snapshot_dirty_rows_valid = 1;
    s->last_snapshot_dirty_generation = s->dirty_generation;
    return 0;
}

static int clear_all_render_dirty_rows(LabanSession *session) {
    ghostty_render_state_get(session->render_state,
        GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &session->row_iter);

    bool row_clean = false;
    while (ghostty_render_state_row_iterator_next(session->row_iter)) {
        if (ghostty_render_state_row_set(session->row_iter,
                GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &row_clean)
                != GHOSTTY_SUCCESS) {
            return -1;
        }
    }
    return 0;
}

int laban_session_snapshot(LabanSession *s, LabanSnapshot **out_snapshot) {
    if (out_snapshot) *out_snapshot = NULL;
    if (!s || !out_snapshot) return -1;
    SESSION_LOCK(s);

    /* Sync render state from the terminal. */
    GhosttyResult r = ghostty_render_state_update(s->render_state, s->terminal);
    if (r != GHOSTTY_SUCCESS) return -1;

    /* Read dimensions. */
    uint16_t rs_cols = 80, rs_rows = 24;
    {
        const GhosttyRenderStateData keys[] = {
            GHOSTTY_RENDER_STATE_DATA_COLS,
            GHOSTTY_RENDER_STATE_DATA_ROWS,
        };
        void *values[] = { &rs_cols, &rs_rows };
        ghostty_render_state_get_multi(s->render_state, 2, keys, values, NULL);
    }
    int rows = (int)rs_rows;
    int cols = (int)rs_cols;
    if (s->rows == 0 || s->cols == 0) {
        rows = (int)s->rows;
        cols = (int)s->cols;
    }
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

    LabanCell *cells = NULL;
    if (cell_count > 0) {
        cells = calloc(cell_count, sizeof(LabanCell));
        if (!cells) { free(snap); return -1; }
    }

    /* Pre-fill default colors for every cell. */
    for (size_t i = 0; i < cell_count; i++) {
        cells[i].foreground_rgba = default_fg;
        cells[i].background_rgba = default_bg;
    }

    /* UTF-8 storage starts with the common one-scalar-per-cell case and grows for long graphemes. */
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

    /* Per-row soft-wrap bytes — one byte per terminal row, 1 = this row is
     * soft-wrapped (its text continues onto the next row with no program
     * newline). Read from libghostty's GHOSTTY_ROW_DATA_WRAP on the same raw
     * row we already pull for the hyperlink check. Selection/copy uses these to
     * rejoin a wrapped logical line. NULL-tolerant like dirty_rows. */
    uint8_t *wrapped_rows = calloc((size_t)rows, sizeof(uint8_t));

    /* Populate the pre-allocated row iterator from the render state. */
    ghostty_render_state_get(s->render_state,
        GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &s->row_iter);

    int snapshot_error = 0;
    int row_idx = 0;
    while (!snapshot_error && row_idx < rows &&
           ghostty_render_state_row_iterator_next(s->row_iter)) {
        /* Populate the pre-allocated cells container and get the raw row in
         * one libghostty call. Renderer damage must come from render-state
         * row dirtiness: ghostty_render_state_update consumes terminal row
         * dirtiness before copying the raw row, so GHOSTTY_ROW_DATA_DIRTY on
         * the raw row is already stale by this point. */
        GhosttyRow raw_row = 0;
        bool row_dirty = false;
        {
            const GhosttyRenderStateRowData keys[] = {
                GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                GHOSTTY_RENDER_STATE_ROW_DATA_RAW,
                GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
            };
            void *values[] = { &s->row_cells, &raw_row, &row_dirty };
            if (ghostty_render_state_row_get_multi(s->row_iter, 3, keys, values, NULL)
                    != GHOSTTY_SUCCESS) {
                snapshot_error = 1;
                break;
            }
        }
        if (dirty_rows) {
            dirty_rows[row_idx] = row_dirty ? 1 : 0;
        }

        bool row_has_hyperlink = false;
        bool row_wrapped = false;
        const GhosttyRowData row_keys[] = {
            GHOSTTY_ROW_DATA_HYPERLINK,
            GHOSTTY_ROW_DATA_WRAP,
        };
        void *row_values[] = { &row_has_hyperlink, &row_wrapped };
        (void)ghostty_row_get_multi(raw_row, 2, row_keys, row_values, NULL);
        if (wrapped_rows) {
            wrapped_rows[row_idx] = row_wrapped ? 1 : 0;
        }

        static const GhosttyRenderStateRowCellsData cell_keys[] = {
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
        };

        static const GhosttyCellData cell_width_keys[] = {
            GHOSTTY_CELL_DATA_WIDE,
        };

        static const GhosttyCellData cell_width_link_keys[] = {
            GHOSTTY_CELL_DATA_WIDE,
            GHOSTTY_CELL_DATA_HAS_HYPERLINK,
        };

        int col_idx = 0;
        while (col_idx < cols && ghostty_render_state_row_cells_next(s->row_cells)) {
            LabanCell *cell = &cells[row_idx * cols + col_idx];

            GhosttyCell raw_cell = 0;
            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            uint32_t grapheme_len = 0;
            void *cell_values[] = { &raw_cell, &style, &grapheme_len };
            if (ghostty_render_state_row_cells_get_multi(
                    s->row_cells, 3, cell_keys, cell_values, NULL) != GHOSTTY_SUCCESS) {
                snapshot_error = 1;
                break;
            }

            cell->flags = laban_cell_flags_from_style(&style);
            cell->underline_style = (uint8_t)style.underline;
            cell->underline_color_rgba =
                resolve_style_color_rgba(s->render_state, style.underline_color);

            /* Width category (narrow / wide / spacer-tail / spacer-head). */
            bool cell_has_link = false;
            {
                GhosttyCellWide w = GHOSTTY_CELL_WIDE_NARROW;
                if (row_has_hyperlink) {
                    void *cell_meta_values[] = { &w, &cell_has_link };
                    if (ghostty_cell_get_multi(
                            raw_cell, 2, cell_width_link_keys, cell_meta_values, NULL)
                            == GHOSTTY_SUCCESS) {
                        cell->wide = (uint8_t)w;
                    }
                } else {
                    void *cell_meta_values[] = { &w };
                    if (ghostty_cell_get_multi(
                            raw_cell, 1, cell_width_keys, cell_meta_values, NULL)
                            == GHOSTTY_SUCCESS) {
                        cell->wide = (uint8_t)w;
                    }
                }
            }

            if (grapheme_len > 0) {
                uint32_t stack_codepoints[64];
                uint32_t *codepoints = stack_codepoints;
                if ((size_t)grapheme_len > sizeof(stack_codepoints) / sizeof(stack_codepoints[0])) {
                    codepoints = malloc((size_t)grapheme_len * sizeof(uint32_t));
                    if (!codepoints) {
                        snapshot_error = 1;
                        break;
                    }
                }

                if (ghostty_render_state_row_cells_get(s->row_cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints)
                        == GHOSTTY_SUCCESS) {
                    if ((size_t)grapheme_len > SIZE_MAX / 4) {
                        snapshot_error = 1;
                    } else if (ensure_utf8_capacity(
                                   &utf8_storage, &utf8_cap, utf8_used,
                                   (size_t)grapheme_len * 4) != 0) {
                        snapshot_error = 1;
                    } else {
                        /* Fast-path: single ASCII printable → store as codepoint. */
                        if (grapheme_len == 1 && codepoints[0] >= 0x20 && codepoints[0] <= 0x7E) {
                            cell->codepoint = codepoints[0];
                        }

                        /* Encode all codepoints to UTF-8. */
                        cell->utf8_offset = (uint32_t)utf8_used;
                        for (uint32_t i = 0; i < grapheme_len; i++) {
                            uint8_t tmp[4];
                            int nb = encode_utf8(codepoints[i], tmp);
                            memcpy(utf8_storage + utf8_used, tmp, (size_t)nb);
                            utf8_used += (size_t)nb;
                        }
                        cell->utf8_length = (uint32_t)(utf8_used - cell->utf8_offset);
                    }
                }

                if (codepoints != stack_codepoints) free(codepoints);
                if (snapshot_error) break;
            }

            /* Foreground color (GHOSTTY_INVALID_VALUE if unset → keep default). */
            GhosttyColorRgb fg;
            if (ghostty_render_state_row_cells_get(s->row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS) {
                cell->foreground_rgba = ((uint32_t)fg.r << 24) |
                                        ((uint32_t)fg.g << 16) |
                                        ((uint32_t)fg.b << 8) | 0xFF;
            }

            /* Background color (GHOSTTY_INVALID_VALUE if unset → keep default).
             * Preserve whether the lookup succeeded: comparing the resolved
             * color with the theme default cannot distinguish an explicit
             * background that happens to use the same RGB value. */
            GhosttyColorRgb bg;
            const int has_explicit_background =
                ghostty_render_state_row_cells_get(s->row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS;
            if (has_explicit_background) {
                cell->background_rgba = ((uint32_t)bg.r << 24) |
                                        ((uint32_t)bg.g << 16) |
                                        ((uint32_t)bg.b << 8) | 0xFF;
            }

            if ((cell->flags & LABAN_CELL_FLAG_INVERSE) != 0) {
                uint32_t swapped = cell->foreground_rgba;
                cell->foreground_rgba = cell->background_rgba;
                cell->background_rgba = swapped;
            }
            if (has_explicit_background
                    || (cell->flags & LABAN_CELL_FLAG_INVERSE) != 0) {
                cell->flags |= LABAN_CELL_FLAG_EXPLICIT_BACKGROUND;
            }

            /* Hyperlink URI lookup via grid ref. Only consult when the row is
             * marked as containing hyperlinks (avoid a per-cell grid_ref walk
             * on the common no-hyperlink path). */
            if (row_has_hyperlink) {
                if (cell_has_link) {
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
    if (snapshot_error) {
        snap->utf8_storage = utf8_storage;
        snap->cells = cells;
        snap->hyperlink_uris = (const char *const *)hyperlink_uris;
        snap->hyperlink_count = hyperlink_count;
        snap->dirty_rows = dirty_rows;
        snap->wrapped_rows = wrapped_rows;
        laban_snapshot_destroy(snap);
        return -1;
    }
    utf8_storage[utf8_used] = '\0';

    /* Cursor state from render state. The viewport-relative position is only
     * defined when the active screen is on screen; if the user has scrolled
     * into history libghostty reports HAS_VALUE = false, and we must report
     * cursor_visible = 0 so the renderer does not draw a stale (0,0) cursor. */
    int cursor_row = 0, cursor_col = 0, cursor_visible = 0;
    int cursor_blinking = 0;
    int cursor_style = LABAN_CURSOR_STYLE_BLOCK;
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
        _Bool blinking = 0;
        if (ghostty_render_state_get(s->render_state,
                GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking) == GHOSTTY_SUCCESS) {
            cursor_blinking = blinking ? 1 : 0;
        }
        GhosttyRenderStateCursorVisualStyle style =
            GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
        if (ghostty_render_state_get(s->render_state,
                GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style) == GHOSTTY_SUCCESS) {
            switch (style) {
                case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
                    cursor_style = LABAN_CURSOR_STYLE_BAR;
                    break;
                case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
                    cursor_style = LABAN_CURSOR_STYLE_UNDERLINE;
                    break;
                case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
                    cursor_style = LABAN_CURSOR_STYLE_BLOCK_HOLLOW;
                    break;
                case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
                default:
                    cursor_style = LABAN_CURSOR_STYLE_BLOCK;
                    break;
            }
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
            title_len = utf8_valid_prefix_len(title_str.ptr, title_len);
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
    LabanMouseTrackingMode mouse_tracking_mode = laban_snapshot_mouse_tracking_mode_locked(s);
    LabanMouseFormat mouse_format = laban_snapshot_mouse_format_locked(s);

    snap->rows                   = rows;
    snap->cols                   = cols;
    snap->cursor_row             = cursor_row;
    snap->cursor_col             = cursor_col;
    snap->cursor_visible         = cursor_visible;
    snap->cursor_blinking        = cursor_blinking;
    snap->cursor_style           = cursor_style;
    snap->status                 = s->status;
    snap->exit_status            = s->exit_status;
    snap->mouse_tracking         = mouse_tracking;
    snap->mouse_tracking_mode    = mouse_tracking_mode;
    snap->mouse_format           = mouse_format;
    int focus_reporting = 0;
    (void)laban_session_mode_active_locked(s, GHOSTTY_MODE_FOCUS_EVENT, &focus_reporting);
    snap->focus_reporting        = focus_reporting;
    int synchronized_output = 0;
    (void)laban_session_mode_active_locked(s, GHOSTTY_MODE_SYNC_OUTPUT, &synchronized_output);
    snap->synchronized_output    = synchronized_output;
    int grapheme_cluster_2027 = 0;
    (void)laban_session_mode_active_locked(s, GHOSTTY_MODE_GRAPHEME_CLUSTER, &grapheme_cluster_2027);
    snap->grapheme_cluster_2027  = grapheme_cluster_2027;
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
    if (dirty_rows && rows > 0 && dirty_state == GHOSTTY_RENDER_STATE_DIRTY_FULL) {
        memset(dirty_rows, 1, (size_t)rows);
    }
    /* libghostty's per-row dirty bits track cell mutations, not every visible
     * grid identity change. Entering/exiting the alternate screen
     * (?1049/?1047/?47) restores a buffer whose untouched rows stay clean even
     * though every visible row changed. Bottom-follow output and user scrollback
     * can also change the viewport offset: the cells are valid, but they now
     * refer to different absolute rows. Force all rows dirty when either value
     * differs from the one last rendered, so partial damage does not leave the
     * previous screen/viewport pixels in the renderer's persistent target.
     * last_rendered_* is committed by mark_rendered. */
    {
        GhosttyTerminalScreen active_screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,
                &active_screen) == GHOSTTY_SUCCESS) {
            if (dirty_rows && rows > 0 &&
                (int)active_screen != s->last_rendered_active_screen) {
                memset(dirty_rows, 1, (size_t)rows);
            }
            s->last_snapshot_active_screen = (int)active_screen;
        }
        GhosttyTerminalScrollbar scrollbar;
        if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar)
                == GHOSTTY_SUCCESS) {
            int viewport_offset = (int)scrollbar.offset;
            if (dirty_rows && rows > 0 &&
                (!s->last_rendered_viewport_offset_valid ||
                 viewport_offset != s->last_rendered_viewport_offset)) {
                memset(dirty_rows, 1, (size_t)rows);
            }
            s->last_snapshot_viewport_offset = viewport_offset;
            s->last_snapshot_viewport_offset_valid = 1;
        } else {
            s->last_snapshot_viewport_offset_valid = 0;
        }
    }

    if (store_last_snapshot_dirty_rows(s, dirty_rows, dirty_rows ? (size_t)rows : 0) != 0) {
        snap->utf8_storage = utf8_storage;
        snap->cells = cells;
        snap->hyperlink_uris = (const char *const *)hyperlink_uris;
        snap->hyperlink_count = hyperlink_count;
        snap->dirty_rows = dirty_rows;
        snap->wrapped_rows = wrapped_rows;
        laban_snapshot_destroy(snap);
        return -1;
    }

    snap->dirty_rows      = dirty_rows;
    snap->dirty_row_count = dirty_rows ? (size_t)rows : 0;
    snap->wrapped_rows    = wrapped_rows;
    snap->wrapped_row_count = wrapped_rows ? (size_t)rows : 0;

    /* DECSCUSR override flags: copied from the session's scanner state so
     * CursorStyleResolver can decide whether to apply the user setting or the
     * program-reported libghostty value. */
    snap->cursor_style_explicit = s->cursor_style_overridden;
    snap->cursor_blink_explicit = s->cursor_blink_overridden;

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
    free((void *)snap->wrapped_rows);
    free(snap);
}

int laban_session_render_dirty(LabanSession *session, int *out_dirty) {
    if (out_dirty) *out_dirty = 0;
    if (!session || !out_dirty) return -1;
    SESSION_LOCK(session);
    ghostty_render_state_update(session->render_state, session->terminal);
    GhosttyRenderStateDirty dirty_state = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_get(session->render_state,
        GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty_state);
    *out_dirty = (dirty_state != GHOSTTY_RENDER_STATE_DIRTY_FALSE) ? 1 : 0;
    return 0;
}

int laban_session_mark_rendered(LabanSession *session) {
    if (!session) return -1;
    SESSION_LOCK(session);

    GhosttyRenderStateDirty next_dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE;

    if (!session->last_snapshot_dirty_rows_valid) {
        if (clear_all_render_dirty_rows(session) != 0) return -1;
    } else if (session->dirty_generation != session->last_snapshot_dirty_generation) {
        next_dirty = GHOSTTY_RENDER_STATE_DIRTY_PARTIAL;
    } else {
        ghostty_render_state_get(session->render_state,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &session->row_iter);

        bool row_clean = false;
        bool any_remaining_dirty = false;
        size_t row_idx = 0;
        while (ghostty_render_state_row_iterator_next(session->row_iter)) {
            bool row_dirty = false;
            if (ghostty_render_state_row_get(session->row_iter,
                    GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &row_dirty)
                    != GHOSTTY_SUCCESS) {
                return -1;
            }
            if (row_idx < session->last_snapshot_dirty_row_count &&
                session->last_snapshot_dirty_rows[row_idx] != 0) {
                if (ghostty_render_state_row_set(session->row_iter,
                        GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &row_clean)
                        != GHOSTTY_SUCCESS) {
                    return -1;
                }
                row_dirty = false;
            }
            if (row_dirty) {
                any_remaining_dirty = true;
            }
            row_idx++;
        }

        if (row_idx != session->last_snapshot_dirty_row_count) {
            any_remaining_dirty = true;
        }
        if (any_remaining_dirty) {
            next_dirty = GHOSTTY_RENDER_STATE_DIRTY_PARTIAL;
        }
    }

    ghostty_render_state_set(session->render_state,
        GHOSTTY_RENDER_STATE_OPTION_DIRTY, &next_dirty);
    session->last_snapshot_dirty_rows_valid = 0;

    /* Commit the active screen the most recent snapshot observed as the one
     * now on the renderer's persistent target. The next snapshot compares
     * against this to force full damage across an alt-screen swap, whose
     * restored rows libghostty leaves clean. Copying the snapshot-observed
     * value (rather than re-querying the terminal here) keeps the comparison
     * race-free against the pty thread mutating state between snapshot and
     * mark_rendered. */
    session->last_rendered_active_screen = session->last_snapshot_active_screen;
    if (session->last_snapshot_viewport_offset_valid) {
        session->last_rendered_viewport_offset = session->last_snapshot_viewport_offset;
        session->last_rendered_viewport_offset_valid = 1;
    }

    return 0;
}

int laban_session_consume_title(LabanSession *s, char *buf, size_t capacity) {
    if (!s || !buf || capacity == 0) {
        if (buf && capacity > 0) buf[0] = '\0';
        return -1;
    }
    SESSION_LOCK(s);
    if (!s->title_dirty) return 0;
    s->title_dirty = 0;
    GhosttyString title_str = {0};
    if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title_str)
            != GHOSTTY_SUCCESS || title_str.len == 0) {
        buf[0] = '\0';
        return 1;
    }
    size_t copy_len = title_str.len < capacity - 1 ? title_str.len : capacity - 1;
    copy_len = utf8_valid_prefix_len(title_str.ptr, copy_len);
    memcpy(buf, title_str.ptr, copy_len);
    buf[copy_len] = '\0';
    return 1;
}

int laban_session_scroll_viewport(LabanSession *s, int delta_rows) {
    if (!s) return -1;
    SESSION_LOCK(s);
    GhosttyTerminalScrollViewport behavior = {
        .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA,
        .value.delta = (intptr_t)delta_rows,
    };
    ghostty_terminal_scroll_viewport(s->terminal, behavior);
    /* Mark render state dirty so next snapshot picks up the change. */
    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
    ghostty_render_state_set(s->render_state,
        GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty);
    laban_session_note_terminal_dirty(s);
    return 0;
}

int laban_session_scroll_viewport_to_bottom(LabanSession *s, int *out_delta_rows) {
    if (out_delta_rows) *out_delta_rows = 0;
    if (!s) return -1;
    SESSION_LOCK(s);

    /* Measure how far the viewport moves while still holding the lock the pin
     * below acquires, so the reported delta matches the scroll that actually
     * lands and no streamed row can wedge between the read and the scroll. */
    GhosttyTerminalScrollbar scrollbar;
    int delta = 0;
    if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar)
            == GHOSTTY_SUCCESS) {
        long bottom_offset = (long)scrollbar.total - (long)scrollbar.len;
        if (bottom_offset < 0) bottom_offset = 0;
        long moved = bottom_offset - (long)scrollbar.offset;
        delta = moved > 0 ? (int)moved : 0;
    }

    GhosttyTerminalScrollViewport behavior = {
        .tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
    };
    ghostty_terminal_scroll_viewport(s->terminal, behavior);
    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
    ghostty_render_state_set(s->render_state,
        GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty);
    laban_session_note_terminal_dirty(s);

    if (out_delta_rows) *out_delta_rows = delta;
    return 0;
}

int laban_session_viewport_state(LabanSession *s, LabanViewportState *out_state) {
    if (out_state) memset(out_state, 0, sizeof(*out_state));
    if (!s || !out_state) return -1;
    SESSION_LOCK(s);

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

    GhosttyTerminalScreen active = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active)
            == GHOSTTY_SUCCESS) {
        out_state->alt_screen = active == GHOSTTY_TERMINAL_SCREEN_ALTERNATE ? 1 : 0;
    }

    int alt_scroll = 0;
    (void)laban_session_mode_active_locked(s, GHOSTTY_MODE_ALT_SCROLL, &alt_scroll);
    out_state->alt_scroll = alt_scroll;

    return 0;
}
