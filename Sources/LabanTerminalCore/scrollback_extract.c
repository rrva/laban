#include "session_internal.h"

static int laban_format_plain_locked(LabanSession *s, uint8_t **out_ptr, size_t *out_len) {
    if (!s || !out_ptr || !out_len) return -1;
    *out_ptr = NULL;
    *out_len = 0;

    GhosttyFormatterTerminalOptions opts = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    opts.unwrap = false;
    opts.trim = false;
    opts.extra = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalExtra);
    opts.extra.screen = GHOSTTY_INIT_SIZED(GhosttyFormatterScreenExtra);

    GhosttyFormatter formatter = NULL;
    if (ghostty_formatter_terminal_new(NULL, &formatter, s->terminal, opts) != GHOSTTY_SUCCESS) {
        return -1;
    }
    GhosttyResult result = ghostty_formatter_format_alloc(formatter, NULL, out_ptr, out_len);
    ghostty_formatter_free(formatter);
    return result == GHOSTTY_SUCCESS ? 0 : -1;
}

static int laban_measure_rows(
    const uint8_t *text,
    size_t text_len,
    size_t row_offset,
    size_t max_rows,
    size_t *out_rows,
    size_t *out_capacity
) {
    if (!out_rows || !out_capacity) return -1;
    *out_rows = 0;
    *out_capacity = 1; /* trailing NUL */
    if (!text || text_len == 0) return 0;

    const int bounded = max_rows != 0;
    size_t source_row = 0;
    size_t pos = 0;
    while (pos < text_len) {
        size_t row_start = pos;
        while (pos < text_len && text[pos] != '\n' && text[pos] != '\0') {
            pos++;
        }
        size_t row_len = pos - row_start;
        if (source_row >= row_offset && (!bounded || *out_rows < max_rows)) {
            if (*out_capacity > SIZE_MAX - row_len) return -1;
            *out_capacity += row_len;
            if (*out_rows > 0) {
                if (*out_capacity == SIZE_MAX) return -1;
                *out_capacity += 1; /* separator before this row */
            }
            *out_rows += 1;
        }
        if (bounded && *out_rows >= max_rows) break;
        while (pos < text_len && (text[pos] == '\n' || text[pos] == '\0')) {
            pos++;
            if (text[pos - 1] == '\n') break;
        }
        source_row++;
    }
    return 0;
}

int laban_session_scrollback_extract_size(
    LabanSession *s,
    size_t row_offset,
    size_t max_rows,
    size_t *out_rows,
    size_t *out_text_capacity
) {
    if (out_rows) *out_rows = 0;
    if (out_text_capacity) *out_text_capacity = 0;
    if (!s || !out_rows || !out_text_capacity) return -1;
    SESSION_LOCK(s);

    uint8_t *formatted = NULL;
    size_t formatted_len = 0;
    if (laban_format_plain_locked(s, &formatted, &formatted_len) != 0) {
        return -1;
    }
    int rc = laban_measure_rows(
        formatted, formatted_len, row_offset, max_rows, out_rows, out_text_capacity);
    ghostty_free(NULL, formatted, formatted_len);
    return rc;
}

int laban_session_scrollback_extract(
    LabanSession *s,
    size_t row_offset,
    size_t max_rows,
    char *text_buffer,
    size_t text_capacity,
    uint32_t *row_offsets,
    size_t row_offsets_capacity,
    size_t *out_rows,
    size_t *out_text_len,
    size_t *out_required_text_capacity,
    size_t *out_required_row_offsets
) {
    if (out_rows) *out_rows = 0;
    if (out_text_len) *out_text_len = 0;
    if (out_required_text_capacity) *out_required_text_capacity = 0;
    if (out_required_row_offsets) *out_required_row_offsets = 0;
    if (!s || !out_rows || !out_text_len ||
        !out_required_text_capacity || !out_required_row_offsets) {
        return -1;
    }
    SESSION_LOCK(s);

    uint8_t *formatted = NULL;
    size_t formatted_len = 0;
    if (laban_format_plain_locked(s, &formatted, &formatted_len) != 0) {
        return -1;
    }

    size_t required_rows = 0;
    size_t required_capacity = 0;
    if (laban_measure_rows(
            formatted, formatted_len, row_offset, max_rows,
            &required_rows, &required_capacity) != 0) {
        ghostty_free(NULL, formatted, formatted_len);
        return -1;
    }
    *out_required_text_capacity = required_capacity;
    *out_required_row_offsets = required_rows;

    if (text_capacity < required_capacity || row_offsets_capacity < required_rows) {
        ghostty_free(NULL, formatted, formatted_len);
        return 1;
    }
    if ((required_capacity > 0 && !text_buffer) || (required_rows > 0 && !row_offsets)) {
        ghostty_free(NULL, formatted, formatted_len);
        return -1;
    }

    const int bounded = max_rows != 0;
    size_t source_row = 0;
    size_t dest_len = 0;
    size_t rows_written = 0;
    size_t pos = 0;
    while (pos < formatted_len) {
        size_t row_start = pos;
        while (pos < formatted_len && formatted[pos] != '\n' && formatted[pos] != '\0') {
            pos++;
        }
        size_t row_len = pos - row_start;
        if (source_row >= row_offset && (!bounded || rows_written < max_rows)) {
            if (dest_len > UINT32_MAX) {
                ghostty_free(NULL, formatted, formatted_len);
                return -1;
            }
            if (rows_written > 0) {
                text_buffer[dest_len++] = '\n';
            }
            row_offsets[rows_written] = (uint32_t)dest_len;
            if (row_len > 0) {
                memcpy(text_buffer + dest_len, formatted + row_start, row_len);
                dest_len += row_len;
            }
            rows_written++;
        }
        if (bounded && rows_written >= max_rows) break;
        while (pos < formatted_len && (formatted[pos] == '\n' || formatted[pos] == '\0')) {
            pos++;
            if (formatted[pos - 1] == '\n') break;
        }
        source_row++;
    }

    if (text_capacity > 0) {
        text_buffer[dest_len] = '\0';
    }
    *out_rows = rows_written;
    *out_text_len = dest_len;
    ghostty_free(NULL, formatted, formatted_len);
    return 0;
}

int laban_session_scrollback_extract_alloc(
    LabanSession *s,
    size_t row_offset,
    size_t max_rows,
    char **out_text_buffer,
    uint32_t **out_row_offsets,
    size_t *out_rows,
    size_t *out_text_len
) {
    if (out_text_buffer) *out_text_buffer = NULL;
    if (out_row_offsets) *out_row_offsets = NULL;
    if (out_rows) *out_rows = 0;
    if (out_text_len) *out_text_len = 0;
    if (!s || !out_text_buffer || !out_row_offsets || !out_rows || !out_text_len) {
        return -1;
    }
    SESSION_LOCK(s);

    uint8_t *formatted = NULL;
    size_t formatted_len = 0;
    if (laban_format_plain_locked(s, &formatted, &formatted_len) != 0) {
        return -1;
    }

    size_t required_rows = 0;
    size_t required_capacity = 0;
    if (laban_measure_rows(
            formatted, formatted_len, row_offset, max_rows,
            &required_rows, &required_capacity) != 0) {
        ghostty_free(NULL, formatted, formatted_len);
        return -1;
    }

    char *text_buffer = (char *)malloc(required_capacity > 0 ? required_capacity : 1);
    if (!text_buffer) {
        ghostty_free(NULL, formatted, formatted_len);
        return -1;
    }

    uint32_t *row_offsets = NULL;
    if (required_rows > 0) {
        if (required_rows > SIZE_MAX / sizeof(uint32_t)) {
            free(text_buffer);
            ghostty_free(NULL, formatted, formatted_len);
            return -1;
        }
        row_offsets = (uint32_t *)malloc(required_rows * sizeof(uint32_t));
        if (!row_offsets) {
            free(text_buffer);
            ghostty_free(NULL, formatted, formatted_len);
            return -1;
        }
    }

    const int bounded = max_rows != 0;
    size_t source_row = 0;
    size_t dest_len = 0;
    size_t rows_written = 0;
    size_t pos = 0;
    while (pos < formatted_len) {
        size_t row_start = pos;
        while (pos < formatted_len && formatted[pos] != '\n' && formatted[pos] != '\0') {
            pos++;
        }
        size_t row_len = pos - row_start;
        if (source_row >= row_offset && (!bounded || rows_written < max_rows)) {
            if (dest_len > UINT32_MAX) {
                free(row_offsets);
                free(text_buffer);
                ghostty_free(NULL, formatted, formatted_len);
                return -1;
            }
            if (rows_written > 0) {
                text_buffer[dest_len++] = '\n';
            }
            row_offsets[rows_written] = (uint32_t)dest_len;
            if (row_len > 0) {
                memcpy(text_buffer + dest_len, formatted + row_start, row_len);
                dest_len += row_len;
            }
            rows_written++;
        }
        if (bounded && rows_written >= max_rows) break;
        while (pos < formatted_len && (formatted[pos] == '\n' || formatted[pos] == '\0')) {
            pos++;
            if (formatted[pos - 1] == '\n') break;
        }
        source_row++;
    }

    text_buffer[dest_len] = '\0';
    *out_text_buffer = text_buffer;
    *out_row_offsets = row_offsets;
    *out_rows = rows_written;
    *out_text_len = dest_len;
    ghostty_free(NULL, formatted, formatted_len);
    return 0;
}

void laban_session_scrollback_extract_free(void *ptr) {
    free(ptr);
}
