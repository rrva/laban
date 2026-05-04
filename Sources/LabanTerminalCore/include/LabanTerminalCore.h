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
    uint32_t default_foreground_rgba;
    uint32_t default_background_rgba;
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

/*
 * laban_session_feed_output:
 *   Feeds bytes directly into the VT parser (ghostty_terminal_vt_write) in
 *   both fixture and PTY modes.  Used to inject OSC palette sequences before
 *   the first render so the terminal adopts the application theme regardless
 *   of what the child process does.
 */
int laban_session_feed_output(LabanSession *session, const uint8_t *bytes, size_t len);
int laban_session_snapshot(LabanSession *session, LabanSnapshot **out_snapshot);
void laban_snapshot_destroy(LabanSnapshot *snapshot);

/* Dirty lifecycle: lightweight query and render-marking without snapshot allocation. */
int laban_session_render_dirty(LabanSession *session, int *out_dirty);
int laban_session_mark_rendered(LabanSession *session);

/*
 * PTY-byte capture: mirrors every byte fed into the VT parser (PTY drain,
 * direct vt_write, paste injection, and feedOutput palette injection) to a
 * file. The file is opened with O_WRONLY|O_CREAT|O_TRUNC; existing contents
 * are overwritten. Replay the resulting file through a fixture session via
 * laban_session_feed_output to reproduce the captured terminal state.
 *
 * Capture is per-session. Returns 0 on success, -1 on error (open failure
 * or already capturing). Stop returns 0 if active or inactive; -1 only on
 * a closed session.
 */
int laban_session_capture_start(LabanSession *session, const char *path);
int laban_session_capture_stop(LabanSession *session);
int laban_session_capture_active(LabanSession *session);

/*
 * laban_session_consume_title:
 *   Returns 1 if the title changed since the last consume and copies the new
 *   title (null-terminated, bounded by capacity) into buf. Returns 0 if no
 *   title change is pending. Returns -1 on error.
 */
int laban_session_consume_title(LabanSession *session, char *buf, size_t capacity);

/* --- Viewport scrolling and state --- */

typedef struct {
    int total_rows;
    int scrollback_rows;
    int viewport_offset;
    int viewport_rows;
    int mouse_tracking;
} LabanViewportState;

int laban_session_scroll_viewport(LabanSession *session, int delta_rows);
int laban_session_viewport_state(LabanSession *session, LabanViewportState *out_state);

/* --- Mouse event ABI (no Ghostty handles exposed) --- */

typedef enum {
    LABAN_MOUSE_ACTION_PRESS = 0,
    LABAN_MOUSE_ACTION_RELEASE = 1,
    LABAN_MOUSE_ACTION_MOTION = 2
} LabanMouseAction;

typedef enum {
    LABAN_MOUSE_BUTTON_NONE = 0,
    LABAN_MOUSE_BUTTON_LEFT = 1,
    LABAN_MOUSE_BUTTON_MIDDLE = 2,
    LABAN_MOUSE_BUTTON_RIGHT = 3,
    LABAN_MOUSE_BUTTON_WHEEL_UP = 4,
    LABAN_MOUSE_BUTTON_WHEEL_DOWN = 5
} LabanMouseButton;

typedef struct {
    LabanMouseAction action;
    LabanMouseButton button;
    /* Terminal-surface pixel position with (0,0) at the top-left. */
    float x;
    float y;
    int screen_width;
    int screen_height;
    int cell_width;
    int cell_height;
    /* GhosttyMods bit order: shift=1, ctrl=2, alt=4, super=8. */
    int modifiers;
} LabanMouseEvent;

int laban_session_encode_mouse(
    LabanSession *session,
    const LabanMouseEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
);

int laban_session_send_mouse(LabanSession *session, const LabanMouseEvent *event);

/* --- Paste ABI --- */

typedef struct {
    int bracketed;       /* non-zero if bracketed paste sequences were added */
    size_t bytes_written; /* number of bytes written to the PTY / VT parser */
} LabanPasteResult;

/* Returns 1 in *out_enabled if bracketed paste mode is active, 0 otherwise. */
int laban_session_bracketed_paste_enabled(LabanSession *session, int *out_enabled);

/*
 * Drain bytes that the terminal has produced as responses to capability
 * queries (DA1/DA2/DA3, XTWINOPS, DSR cursor position, etc.).  In PTY mode
 * these bytes are also delivered directly to the PTY master fd so the child
 * process sees them; the captured copy here is for tests, fixtures, and
 * debug observability.  Removes drained bytes from the internal buffer.
 *
 * Returns 0 on success, -1 on error.  On success *out_len holds the number
 * of bytes copied into out_bytes (0 if no responses pending).
 */
int laban_session_drain_response(
    LabanSession *session,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len);

/*
 * Encode paste bytes for terminal input.
 * - Strips unsafe control bytes.
 * - Replaces newlines with CR if not bracketed.
 * - Wraps in ESC[200~ / ESC[201~ if bracketed is true.
 * out_capacity must be >= len + 12 to accommodate bracketed sequences.
 * Returns 0 on success, -1 on error.
 */
int laban_session_encode_paste(
    LabanSession *session,
    const uint8_t *bytes,
    size_t len,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len,
    int *out_bracketed
);

/*
 * Encode and write paste bytes to the PTY (or VT parser in fixture mode).
 * Returns 0 on success, -1 on error.
 */
int laban_session_write_paste(
    LabanSession *session,
    const uint8_t *bytes,
    size_t len,
    LabanPasteResult *out_result
);

/*
 * laban_session_exit_state:
 *   Lightweight query for the session's exit state. Reads status and
 *   exit_status directly from session storage without rendering or allocating.
 *   status values match LabanSnapshot.status (0=running, 1=exited normally,
 *   2=exited by signal). Safe to call on any live session handle.
 */
typedef struct {
    int status;      /* 0=running, 1=exited normally, 2=exited by signal */
    int exit_status; /* exit code or signal number when status != 0 */
} LabanExitState;

LabanExitState laban_session_exit_state(LabanSession *session);

#endif /* LABAN_TERMINAL_CORE_H */
