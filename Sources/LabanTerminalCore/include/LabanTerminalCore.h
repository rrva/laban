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

typedef enum {
    LABAN_CAPTURE_BYTES_PTY_INPUT = 0,
    LABAN_CAPTURE_BYTES_PTY_OUTPUT = 1,
    LABAN_CAPTURE_BYTES_TERMINAL_RESPONSE = 2
} LabanCaptureBytesDirection;

typedef void (*LabanCaptureBytesCallback)(
    void *userdata,
    LabanSession *session,
    LabanCaptureBytesDirection direction,
    const uint8_t *bytes,
    size_t len
);

int laban_session_set_capture_callback(
    LabanSession *session,
    LabanCaptureBytesCallback callback,
    void *userdata
);

/*
 * Feed captured PTY output bytes directly into the VT parser during replay.
 * This is intentionally named for replay so callers do not confuse terminal
 * byte replay with user input written to a live child process.
 */
int laban_session_replay_pty_output(LabanSession *session, const uint8_t *bytes, size_t len);

/*
 * laban_session_consume_title:
 *   Returns 1 if the title changed since the last consume and copies the new
 *   title (null-terminated, bounded by capacity) into buf. Returns 0 if no
 *   title change is pending. Returns -1 on error.
 */
int laban_session_consume_title(LabanSession *session, char *buf, size_t capacity);

/*
 * Best-effort local process metadata for tab titles.
 * - child_pid is the original PTY child.
 * - foreground_pid is the foreground process-group leader reported by the PTY.
 * - process_buf receives a short executable name such as "zsh" or "top".
 * - command_buf receives a best-effort executable path when available.
 * - cwd_buf receives the current working directory of foreground_pid, falling
 *   back to the launch cwd when the OS query cannot provide it.
 *
 * All output strings are null-terminated when their capacities are non-zero.
 * Returns 0 on success, -1 on invalid input or a closed session.
 */
int laban_session_process_metadata(
    LabanSession *session,
    int *out_child_pid,
    int *out_foreground_pid,
    char *process_buf,
    size_t process_capacity,
    char *command_buf,
    size_t command_capacity,
    char *cwd_buf,
    size_t cwd_capacity
);

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

/* --- Key event ABI --- */

typedef enum {
    LABAN_KEY_ACTION_RELEASE = 0,
    LABAN_KEY_ACTION_PRESS   = 1,
    LABAN_KEY_ACTION_REPEAT  = 2
} LabanKeyAction;

typedef enum {
    LABAN_KEY_UNIDENTIFIED = 0,
    LABAN_KEY_BACKQUOTE,
    LABAN_KEY_BACKSLASH,
    LABAN_KEY_BRACKET_LEFT,
    LABAN_KEY_BRACKET_RIGHT,
    LABAN_KEY_COMMA,
    LABAN_KEY_DIGIT_0,
    LABAN_KEY_DIGIT_1,
    LABAN_KEY_DIGIT_2,
    LABAN_KEY_DIGIT_3,
    LABAN_KEY_DIGIT_4,
    LABAN_KEY_DIGIT_5,
    LABAN_KEY_DIGIT_6,
    LABAN_KEY_DIGIT_7,
    LABAN_KEY_DIGIT_8,
    LABAN_KEY_DIGIT_9,
    LABAN_KEY_EQUAL,
    LABAN_KEY_A,
    LABAN_KEY_B,
    LABAN_KEY_C,
    LABAN_KEY_D,
    LABAN_KEY_E,
    LABAN_KEY_F,
    LABAN_KEY_G,
    LABAN_KEY_H,
    LABAN_KEY_I,
    LABAN_KEY_J,
    LABAN_KEY_K,
    LABAN_KEY_L,
    LABAN_KEY_M,
    LABAN_KEY_N,
    LABAN_KEY_O,
    LABAN_KEY_P,
    LABAN_KEY_Q,
    LABAN_KEY_R,
    LABAN_KEY_S,
    LABAN_KEY_T,
    LABAN_KEY_U,
    LABAN_KEY_V,
    LABAN_KEY_W,
    LABAN_KEY_X,
    LABAN_KEY_Y,
    LABAN_KEY_Z,
    LABAN_KEY_MINUS,
    LABAN_KEY_PERIOD,
    LABAN_KEY_QUOTE,
    LABAN_KEY_SEMICOLON,
    LABAN_KEY_SLASH,
    LABAN_KEY_BACKSPACE,
    LABAN_KEY_ENTER,
    LABAN_KEY_SPACE,
    LABAN_KEY_TAB,
    LABAN_KEY_DELETE,
    LABAN_KEY_END,
    LABAN_KEY_HOME,
    LABAN_KEY_INSERT,
    LABAN_KEY_PAGE_DOWN,
    LABAN_KEY_PAGE_UP,
    LABAN_KEY_ARROW_DOWN,
    LABAN_KEY_ARROW_LEFT,
    LABAN_KEY_ARROW_RIGHT,
    LABAN_KEY_ARROW_UP,
    LABAN_KEY_ESCAPE,
    LABAN_KEY_F1,
    LABAN_KEY_F2,
    LABAN_KEY_F3,
    LABAN_KEY_F4,
    LABAN_KEY_F5,
    LABAN_KEY_F6,
    LABAN_KEY_F7,
    LABAN_KEY_F8,
    LABAN_KEY_F9,
    LABAN_KEY_F10,
    LABAN_KEY_F11,
    LABAN_KEY_F12,
    LABAN_KEY_F13,
    LABAN_KEY_F14,
    LABAN_KEY_F15,
    LABAN_KEY_F16,
    LABAN_KEY_F17,
    LABAN_KEY_F18,
    LABAN_KEY_F19,
    LABAN_KEY_F20,
    LABAN_KEY_F21,
    LABAN_KEY_F22,
    LABAN_KEY_F23,
    LABAN_KEY_F24
} LabanKey;

enum {
    LABAN_KEY_MOD_SHIFT        = 1 << 0,
    LABAN_KEY_MOD_CONTROL      = 1 << 1,
    LABAN_KEY_MOD_ALT          = 1 << 2,
    LABAN_KEY_MOD_SUPER        = 1 << 3,
    LABAN_KEY_MOD_CAPS_LOCK    = 1 << 4,
    LABAN_KEY_MOD_NUM_LOCK     = 1 << 5,
    LABAN_KEY_MOD_SHIFT_SIDE   = 1 << 6,
    LABAN_KEY_MOD_CONTROL_SIDE = 1 << 7,
    LABAN_KEY_MOD_ALT_SIDE     = 1 << 8,
    LABAN_KEY_MOD_SUPER_SIDE   = 1 << 9
};

typedef struct {
    LabanKeyAction  action;
    LabanKey        key;
    int             modifiers;
    int             consumed_modifiers;
    int             composing;
    uint32_t        unshifted_codepoint;
    const char     *utf8;
    size_t          utf8_len;
} LabanKeyEvent;

/*
 * laban_session_encode_key:
 *   Encode a key event into terminal input bytes using libghostty-vt.
 *   Terminal modes (application cursor, modifyOtherKeys, Kitty protocol)
 *   are read from the session's terminal state on each call.
 *   Returns 0 on success, 1 if out_capacity is too small (*out_len holds
 *   the required size), or -1 on error.
 */
int laban_session_encode_key(
    LabanSession *session,
    const LabanKeyEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
);

/*
 * laban_session_send_key:
 *   Encode and write key input to the PTY (PTY mode). In fixture mode,
 *   returns 0 after encoding so tests can call laban_session_encode_key.
 */
int laban_session_send_key(LabanSession *session, const LabanKeyEvent *event);

#endif /* LABAN_TERMINAL_CORE_H */
