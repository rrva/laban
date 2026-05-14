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

typedef struct {
    LabanFindMatch *items;
    size_t count;
    size_t capacity;
} LabanFindMatchBuffer;

static uint8_t laban_fold_ascii_byte(uint8_t byte) {
    return (byte >= 'A' && byte <= 'Z') ? (uint8_t)(byte + ('a' - 'A')) : byte;
}

static int laban_bytes_are_ascii(const uint8_t *bytes, size_t len) {
    if (!bytes && len > 0) return 0;
    for (size_t i = 0; i < len; i++) {
        if (bytes[i] >= 0x80) return 0;
    }
    return 1;
}

static int laban_match_prepared_needle(
    const uint8_t *prepared_needle,
    size_t needle_len,
    const uint8_t *haystack,
    size_t index,
    int fold_ascii
) {
    for (size_t n = 0; n < needle_len; n++) {
        uint8_t byte = haystack[index + n];
        if (fold_ascii) byte = laban_fold_ascii_byte(byte);
        if (byte != prepared_needle[n]) return 0;
    }
    return 1;
}

static int laban_append_find_match(
    LabanFindMatchBuffer *buffer,
    size_t row,
    size_t start_column,
    size_t end_column
) {
    if (!buffer) return -1;
    if (row > (size_t)INT_MAX || start_column > (size_t)INT_MAX ||
        end_column > (size_t)INT_MAX) {
        return -1;
    }
    if (buffer->count == buffer->capacity) {
        size_t next_capacity = buffer->capacity == 0 ? 16 : buffer->capacity * 2;
        if (next_capacity < buffer->capacity ||
            next_capacity > SIZE_MAX / sizeof(LabanFindMatch)) {
            return -1;
        }
        LabanFindMatch *next =
            (LabanFindMatch *)realloc(buffer->items, next_capacity * sizeof(LabanFindMatch));
        if (!next) return -1;
        buffer->items = next;
        buffer->capacity = next_capacity;
    }

    buffer->items[buffer->count++] = (LabanFindMatch){
        .row = (int)row,
        .start_column = (int)start_column,
        .end_column = (int)end_column,
    };
    return 0;
}

static int laban_search_ascii_row(
    const uint8_t *prepared_needle,
    size_t needle_len,
    const uint8_t *row,
    size_t row_len,
    size_t row_index,
    int fold_ascii,
    LabanFindMatchBuffer *matches
) {
    if (needle_len == 0 || row_len < needle_len) return 0;

    size_t index = 0;
    const size_t last_start = row_len - needle_len;
    while (index <= last_start) {
        if (laban_match_prepared_needle(
                prepared_needle, needle_len, row, index, fold_ascii)) {
            if (laban_append_find_match(
                    matches, row_index, index, index + needle_len) != 0) {
                return -1;
            }
            index += needle_len;
        } else {
            index++;
        }
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

int laban_session_find_matches_alloc(
    LabanSession *s,
    const uint8_t *needle,
    size_t needle_len,
    int fold_ascii,
    size_t row_offset,
    size_t max_rows,
    LabanFindMatch **out_matches,
    size_t *out_count,
    int *out_complete
) {
    if (out_matches) *out_matches = NULL;
    if (out_count) *out_count = 0;
    if (out_complete) *out_complete = 0;
    if (!s || !out_matches || !out_count || !out_complete ||
        (!needle && needle_len > 0)) {
        return -1;
    }
    if (needle_len == 0) {
        *out_complete = 1;
        return 0;
    }
    if (!laban_bytes_are_ascii(needle, needle_len)) {
        return 0;
    }

    uint8_t *prepared_needle = (uint8_t *)malloc(needle_len);
    if (!prepared_needle) return -1;
    for (size_t i = 0; i < needle_len; i++) {
        prepared_needle[i] = fold_ascii ? laban_fold_ascii_byte(needle[i]) : needle[i];
    }

    SESSION_LOCK(s);

    uint8_t *formatted = NULL;
    size_t formatted_len = 0;
    if (laban_format_plain_locked(s, &formatted, &formatted_len) != 0) {
        free(prepared_needle);
        return -1;
    }

    LabanFindMatchBuffer matches = {0};
    const int bounded = max_rows != 0;
    size_t source_row = 0;
    size_t searched_row = 0;
    size_t pos = 0;
    int complete = 1;
    int error = 0;

    while (pos < formatted_len) {
        size_t row_start = pos;
        while (pos < formatted_len && formatted[pos] != '\n' && formatted[pos] != '\0') {
            pos++;
        }
        size_t row_len = pos - row_start;
        if (source_row >= row_offset && (!bounded || searched_row < max_rows)) {
            if (row_len > 0) {
                if (!laban_bytes_are_ascii(formatted + row_start, row_len)) {
                    complete = 0;
                    break;
                }
                if (laban_search_ascii_row(
                        prepared_needle,
                        needle_len,
                        formatted + row_start,
                        row_len,
                        searched_row,
                        fold_ascii,
                        &matches) != 0) {
                    error = 1;
                    break;
                }
            }
            searched_row++;
        }
        if (bounded && searched_row >= max_rows) break;
        while (pos < formatted_len && (formatted[pos] == '\n' || formatted[pos] == '\0')) {
            pos++;
            if (formatted[pos - 1] == '\n') break;
        }
        source_row++;
    }

    ghostty_free(NULL, formatted, formatted_len);
    free(prepared_needle);

    if (error) {
        free(matches.items);
        return -1;
    }
    if (!complete) {
        free(matches.items);
        return 0;
    }

    *out_matches = matches.items;
    *out_count = matches.count;
    *out_complete = 1;
    return 0;
}

void laban_session_find_matches_free(void *ptr) {
    free(ptr);
}
