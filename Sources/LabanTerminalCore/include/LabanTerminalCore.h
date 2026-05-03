#ifndef LABAN_TERMINAL_CORE_H
#define LABAN_TERMINAL_CORE_H

#include <stddef.h>
#include <stdint.h>

/* Smoke functions from Milestone 1 */
const char *laban_terminal_core_smoke_version(void);
int laban_ghostty_vt_link_smoke(void);

/* --- Session ABI --- */

typedef struct LabanSession LabanSession;

typedef struct {
    const char *executable;
    const char *const *argv;
    const char *const *envp;
    const char *cwd;
    int fixture_mode;
} LabanLaunchConfig;

typedef struct {
    int rows;
    int cols;
    int pixel_width;
    int pixel_height;
    int cell_width;
    int cell_height;
} LabanTerminalSize;

typedef struct {
    uint32_t codepoint;      /* First codepoint; 0 if empty or multi-codepoint */
    uint32_t utf8_offset;    /* Byte offset into LabanSnapshot.utf8_storage */
    uint32_t utf8_length;    /* Byte length in utf8_storage; 0 if empty */
    uint32_t foreground_rgba;
    uint32_t background_rgba;
    uint16_t flags;
} LabanCell;

/*
 * LabanSnapshot.status values:
 *   0 = running
 *   1 = exited normally (exit_status is the exit code)
 *   2 = exited by signal
 *
 * title, utf8_storage, and cells are owned by the snapshot.
 * Call laban_snapshot_destroy() to free them.
 */
typedef struct {
    int rows;
    int cols;
    int cursor_row;
    int cursor_col;
    int cursor_visible;
    int status;
    int exit_status;
    int mouse_tracking;
    int focus_reporting;
    int dirty;
    const char *title;
    const char *utf8_storage;
    size_t utf8_storage_len;
    const LabanCell *cells;
    size_t cell_count;
} LabanSnapshot;

int laban_session_create(
    const LabanLaunchConfig *config,
    LabanTerminalSize initial_size,
    LabanSession **out_session
);
void laban_session_destroy(LabanSession *session);
int laban_session_poll(LabanSession *session);
int laban_session_resize(LabanSession *session, LabanTerminalSize size);

/*
 * laban_session_write:
 *   fixture_mode: writes bytes directly to ghostty_terminal_vt_write (no PTY).
 *   pty mode: writes bytes to the PTY master fd (keyboard input to shell).
 */
int laban_session_write(LabanSession *session, const uint8_t *bytes, size_t len);
int laban_session_snapshot(LabanSession *session, LabanSnapshot **out_snapshot);
void laban_snapshot_destroy(LabanSnapshot *snapshot);

#endif /* LABAN_TERMINAL_CORE_H */
