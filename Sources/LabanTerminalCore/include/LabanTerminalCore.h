#ifndef LABAN_TERMINAL_CORE_H
#define LABAN_TERMINAL_CORE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include "laband_snapshot_ring.h"

uint64_t laban_atomic_load_u64_acquire(const void *slot);
void laban_atomic_store_u64_release(void *slot, uint64_t value);

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
    /* When non-zero, laban_session_create returns a session with its
     * libghostty parser ready but no child process spawned. Use
     * laban_session_start_spawn(session, NULL) (or with an override
     * cwd) to fork+exec the shell later. Used by the workspace
     * persistence path to replay a previous transcript into the VT
     * parser BEFORE any live shell output competes for the screen. */
    int defer_spawn;
} LabanLaunchConfig;

typedef struct {
    int rows;
    int cols;
    int pixel_width;
    int pixel_height;
    int cell_width;
    int cell_height;
} LabanTerminalSize;

enum {
    LABAN_CELL_FLAG_BOLD = 1u << 0,
    LABAN_CELL_FLAG_ITALIC = 1u << 1,
    LABAN_CELL_FLAG_FAINT = 1u << 2,
    LABAN_CELL_FLAG_INVERSE = 1u << 3,
    LABAN_CELL_FLAG_INVISIBLE = 1u << 4,
    LABAN_CELL_FLAG_UNDERLINE = 1u << 5,
    LABAN_CELL_FLAG_STRIKETHROUGH = 1u << 6,
    LABAN_CELL_FLAG_OVERLINE = 1u << 7,
    LABAN_CELL_FLAG_BLINK = 1u << 8
};

/* Underline style values (matches GhosttySgrUnderline). */
enum {
    LABAN_UNDERLINE_NONE = 0,
    LABAN_UNDERLINE_SINGLE = 1,
    LABAN_UNDERLINE_DOUBLE = 2,
    LABAN_UNDERLINE_CURLY = 3,
    LABAN_UNDERLINE_DOTTED = 4,
    LABAN_UNDERLINE_DASHED = 5
};

/* Cursor visual style values exposed in LabanSnapshot.cursor_style. */
enum {
    LABAN_CURSOR_STYLE_BLOCK = 0,
    LABAN_CURSOR_STYLE_BAR = 1,
    LABAN_CURSOR_STYLE_UNDERLINE = 2,
    LABAN_CURSOR_STYLE_BLOCK_HOLLOW = 3
};

/* Host color scheme reported to terminal color-scheme queries. */
enum {
    LABAN_COLOR_SCHEME_LIGHT = 0,
    LABAN_COLOR_SCHEME_DARK = 1
};

/* Width category for a cell (matches GhosttyCellWide). */
enum {
    LABAN_CELL_WIDE_NARROW = 0,
    LABAN_CELL_WIDE_WIDE = 1,
    LABAN_CELL_WIDE_SPACER_TAIL = 2,
    LABAN_CELL_WIDE_SPACER_HEAD = 3
};

typedef struct {
    uint32_t codepoint;      /* First codepoint; 0 if empty or multi-codepoint */
    uint32_t utf8_offset;    /* Byte offset into LabanSnapshot.utf8_storage */
    uint32_t utf8_length;    /* Byte length in utf8_storage; 0 if empty */
    uint32_t foreground_rgba;
    uint32_t background_rgba;
    uint32_t underline_color_rgba; /* 0 = unset; alpha byte is the lsb when set */
    uint32_t hyperlink_id;   /* 1-indexed into LabanSnapshot.hyperlink_uris; 0 = none */
    uint16_t flags;
    uint8_t  underline_style;     /* LABAN_UNDERLINE_* */
    uint8_t  wide;                /* LABAN_CELL_WIDE_* */
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
    int cursor_blinking;
    int cursor_style;
    int status;
    int exit_status;
    int mouse_tracking;
    int mouse_tracking_mode;
    int mouse_format;
    int focus_reporting;
    /* DEC private mode 2026 (synchronized output) active: viewers should hold
       presentation of this snapshot until the program ends the synchronized
       update, so multi-client (laband) clients don't show half-drawn frames. */
    int synchronized_output;
    int dirty;
    uint32_t default_foreground_rgba;
    uint32_t default_background_rgba;
    const char *title;
    const char *utf8_storage;
    size_t utf8_storage_len;
    const LabanCell *cells;
    size_t cell_count;
    /* Hyperlink URIs referenced by cell.hyperlink_id (1-indexed).
     * The pointer is NULL when no cell has a hyperlink; otherwise
     * hyperlink_uris[id-1] is a NUL-terminated UTF-8 URI owned by the snapshot. */
    const char *const *hyperlink_uris;
    size_t hyperlink_count;
    /* Per-row dirty flags read from libghostty (one byte per terminal row,
     * 0 = clean, 1 = dirty since the last laban_session_mark_rendered).
     * NULL when the snapshot couldn't query row state (ABI fallback).
     * Renderers use these to constrain damage and avoid re-rasterizing
     * clean rows. dirty_row_count == rows on success. */
    const uint8_t *dirty_rows;
    size_t dirty_row_count;
    /* DECSCUSR / DEC-mode-12 explicit override flags (decscusr.c).
     * 1 when a program has overridden the respective cursor attribute and
     * has not yet reset it. In-memory only — not an ABI-stable ring field.
     * CursorStyleResolver uses these to decide whether to apply the user's
     * setting or the program's libghostty-reported value. */
    int cursor_style_explicit;
    int cursor_blink_explicit;
} LabanSnapshot;

/* Creates a terminal session. On failure, *out_session is set to NULL. */
int laban_session_create(
    const LabanLaunchConfig *config,
    LabanTerminalSize initial_size,
    LabanSession **out_session
);

/*
 * Fork+exec the child process for a session created with
 * `defer_spawn = 1`. The session keeps its libghostty parser; this
 * call only attaches a fresh PTY pair and child process. Returns 0 on
 * success, -1 on error or when the session was created without
 * deferred-spawn intent (in which case the spawn already happened).
 *
 * `override_cwd` overrides the cwd recorded on the session at create
 * time. Pass NULL to use the create-time cwd.
 */
int laban_session_start_spawn(LabanSession *session, const char *override_cwd);

/*
 * Like laban_session_start_spawn, but launches `exe` with an explicit
 * NULL-terminated `argv` instead of the user's default login shell.
 * Used by the workspace-restore path to run a coding-agent resume as
 * the shell's own argument, e.g.
 *   `$SHELL -l -i -c '<resume>; exec $SHELL -l -i'`
 * so nothing is typed into a live prompt. `argv[0]` is what the child
 * process sees (no login `-` prefix). Returns 0 on success, -1 on
 * error or when the session was not created with deferred-spawn intent.
 */
int laban_session_start_spawn_argv(LabanSession *session, const char *override_cwd,
                                   const char *exe, const char *const *argv);

/*
 * Opens a PTY and launches a child process without constructing a
 * libghostty terminal session. This is the ADR 0002 launch primitive
 * shared by app-local sessions, laband, and labpty:
 * parent-side openpty, initial winsize before fork, constrained fork
 * child branch, parent-only master fd.
 *
 * `argv` is NULL-terminated; when argv is NULL or argv[0] is empty, the
 * user's shell is launched as a login shell. `envp` is a NULL-terminated
 * override list merged with the inherited environment. Returns 0 on success
 * and stores the nonblocking master fd plus child pid in the out parameters.
 */
int laban_pty_open(
    int rows,
    int cols,
    const char *const *argv,
    const char *const *envp,
    const char *cwd,
    int *out_master_fd,
    pid_t *out_child_pid
);

/*
 * Drop PTY output from a deferred-spawn restore until the first input
 * write reaches the shell. Restored tabs replay the old transcript
 * before launching a replacement shell; the replacement shell's
 * startup prompt must not visibly or persistently stack on top of the
 * already-restored prompt. Returns 0 on success, -1 on NULL session.
 */
int laban_session_suppress_pty_output_until_input(LabanSession *session, int enabled);

void laban_session_destroy(LabanSession *session);
int laban_session_poll(LabanSession *session);

/*
 * laban_session_poll_blocking:
 *   Block until pty_fd is readable or `timeout_ms` elapses, then drain
 *   available bytes through the VT parser. Holds the session lock only
 *   while draining (read+vt_write); the select(2) wait happens lock-free
 *   so the main thread can take the lock to call snapshot/write/resize/
 *   etc. while the reader is parked. A negative timeout blocks
 *   indefinitely. Returns the number of bytes drained (0 on timeout or
 *   nothing to read), or -1 on a permanent select error. The caller is
 *   responsible for stopping any thread that calls this before
 *   laban_session_destroy() runs.
 */
int laban_session_poll_blocking(LabanSession *session, int timeout_ms);

/*
 * Microbench observability for the PTY drain loop. Returns the running
 * totals of read(2) calls and bytes drained on this session. Counters
 * are monotonic and updated under the session lock. Not used by product
 * code; intended for Tools/BenchPtyDrain.
 */
void laban_session_drain_stats(LabanSession *session, uint64_t *out_reads, uint64_t *out_bytes);

/* Build-time read-buffer size used by the drain loop (per syscall). */
size_t laban_session_drain_buf_bytes(void);

/* Build-time per-drain byte ceiling (drains bail after this many bytes
 * to bound session-lock hold time). */
size_t laban_session_drain_max_bytes_per_poll(void);

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

/* Allocates a render snapshot. On failure, *out_snapshot is set to NULL. */
int laban_session_snapshot(LabanSession *session, LabanSnapshot **out_snapshot);
void laban_snapshot_destroy(LabanSnapshot *snapshot);

/* Dirty lifecycle: lightweight query and snapshot-backed render marking. */
int laban_session_render_dirty(LabanSession *session, int *out_dirty);
int laban_session_mark_rendered(LabanSession *session);

/*
 * laban_session_dirty_generation:
 *   Returns the current dirty-generation counter in *out_generation.
 *   The counter is incremented at every terminal-content mutation (VT write,
 *   resize, replay, viewport scroll, child exit) and wraps past 0 to 1,
 *   so it is never 0 after the first mutation. Callers can compare the
 *   returned value against a stored previous value to determine whether
 *   any session content has changed since the last comparison — without
 *   taking a full snapshot. Returns 0 on success, -1 on NULL session or
 *   NULL out_generation.
 */
int laban_session_dirty_generation(
    LabanSession *session, uint64_t *out_generation);

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
 * laban_session_capture_input:
 *   Tee keyboard input bytes into the capture sink as PTY_INPUT WITHOUT
 *   writing them to any PTY. The daemon (labpty/laband) tier writes keystrokes
 *   over a socket to the daemon's PTY, so the app's PTY-less viewer session
 *   never observes input the way it observes output (laban_session_feed_output)
 *   and terminal responses. The app calls this with the same bytes it sends to
 *   the daemon so an active capture's pty-input stream is complete.
 *
 *   No-op when the session has no capture callback installed.
 */
void laban_session_capture_input(LabanSession *session, const uint8_t *bytes, size_t len);

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
 * Persistence PTY-byte tee.
 *
 * Fires on every chunk of PTY OUTPUT after the existing capture callback
 * and before the bytes reach libghostty-vt. The contract is intentionally
 * narrow: the callback MUST do nothing more than copy bytes into its own
 * buffer and return. No file IO, no truncation, no fsync, no allocation.
 * The PTY drain holds the session lock while invoking the callback;
 * synchronous IO here stalls rendering.
 *
 * `bytes`/`len` are valid only for the duration of the call. Pass NULL
 * for `callback` to detach.
 */
typedef void (*LabanPersistenceBytesCallback)(
    void *userdata,
    LabanSession *session,
    const uint8_t *bytes,
    size_t len
);

int laban_session_set_persistence_callback(
    LabanSession *session,
    LabanPersistenceBytesCallback callback,
    void *userdata
);

/*
 * Returns 1 when the terminal is currently in alternate-screen-buffer
 * mode (vim/htop/less and similar full-screen TUIs), 0 otherwise.
 * Used by the workspace persistence path to decide whether transcript
 * replay would paint half-finished TUI state on restore. Returns 0 for
 * a NULL session.
 */
int laban_session_alt_buffer_active(LabanSession *session);

/*
 * iTerm2-compatible OSC 21337 ("tab status") observer. The PTY byte
 * stream is scanned alongside the VT parser; on every successfully
 * parsed `ESC ] 21337 ; key=value;... BEL/ST` sequence, this callback
 * is invoked with the three known fields.
 *
 * For each field:
 *   NULL  → key was absent from the payload; preserve the prior value
 *   ""    → key was present with empty value; clear the field
 *   other → set the field to the given UTF-8 string
 *
 * The pointers are valid only for the duration of the call. The
 * callback fires on whichever thread drove `laban_session_poll` /
 * `laban_session_feed_output`. Pass NULL for `callback` to disable.
 */
typedef void (*LabanTabStatusCallback)(
    void *userdata,
    const char *indicator,
    const char *status,
    const char *status_color,
    /* Laban extension to the OSC 21337 payload: `awaiting=1` flags the tab
     * as blocked on user input (agents emit it from hooks). NULL when the
     * payload omitted the field, "" when it was explicitly cleared. */
    const char *awaiting
);

int laban_session_set_tab_status_callback(
    LabanSession *session,
    LabanTabStatusCallback callback,
    void *userdata
);

/*
 * OSC 133 ("semantic prompt") observer. The PTY byte stream is scanned
 * alongside the VT parser; on every successfully parsed
 * `ESC ] 133 ; <action>[;<exit>] BEL/ST` sequence this callback fires with
 * the parsed action. Only the iTerm2/FinalTerm A/B/C/D subset is reported;
 * other actions (L/I/N/P) and options (aid=, cmdline=, ...) are ignored.
 *
 * `has_exit_code` is 1 only for a 'D' action carrying a numeric argument
 * (`ESC ] 133 ; D ; <n> ST`); `exit_code` is meaningful only then. For all
 * other actions `has_exit_code` is 0 and `exit_code` is 0.
 *
 * libghostty-vt parses OSC 133 internally but its C API cannot surface the
 * action letter or exit code, so Laban scans for it directly. The callback
 * fires on whichever thread drove `laban_session_poll` /
 * `laban_session_feed_output`. Pass NULL for `callback` to disable.
 */
typedef enum {
    LABAN_OSC133_PROMPT_START = 0,   /* 'A' — fresh prompt about to draw */
    LABAN_OSC133_PROMPT_END = 1,     /* 'B' — prompt drawn, input starts */
    LABAN_OSC133_COMMAND_START = 2,  /* 'C' — command now running */
    LABAN_OSC133_COMMAND_END = 3,    /* 'D' — command finished */
} LabanOSC133Action;

typedef void (*LabanOSC133Callback)(
    void *userdata,
    LabanSession *session,
    LabanOSC133Action action,
    int has_exit_code,
    int exit_code
);

int laban_session_set_osc133_callback(
    LabanSession *session,
    LabanOSC133Callback callback,
    void *userdata
);

/*
 * Terminal bell observer. libghostty invokes this when BEL (0x07) or another
 * terminal sequence requests a bell. The count is monotonically increasing for
 * the lifetime of the session and is incremented before the callback fires.
 *
 * The callback fires while the session lock is held on whichever thread drove
 * `laban_session_poll` / `laban_session_feed_output`. It should copy the count
 * or enqueue follow-up work and return quickly. Pass NULL for `callback` to
 * disable.
 */
typedef void (*LabanBellCallback)(
    void *userdata,
    LabanSession *session,
    uint64_t count
);

int laban_session_set_bell_callback(
    LabanSession *session,
    LabanBellCallback callback,
    void *userdata
);
int laban_session_bell_count(LabanSession *session, uint64_t *out_count);

/*
 * Desktop-notification observer. Fires when the program emits an OSC 9 desktop
 * notification (`ESC ] 9 ; <text> BEL/ST`) — for example, the Codex agent TUI
 * signalling "agent turn complete" or "approval requested". libghostty-vt
 * parses OSC 9 but does not surface it, so Laban scans for it directly (see
 * osc_host.c). ConEmu progress reports (`OSC 9 ; 4 ; ...`) are NOT delivered
 * here. `text` points at `len` UTF-8 bytes that are NOT NUL-terminated and are
 * only valid for the duration of the call — copy what you need.
 *
 * The callback fires while the session lock is held on whichever thread drove
 * `laban_session_poll` / `laban_session_feed_output`. It should copy the text
 * and enqueue follow-up work, then return quickly. Pass NULL to disable.
 *
 * Separately, this scanner answers default foreground/background color queries
 * (`OSC 10 ; ?` / `OSC 11 ; ?`) by replying with the session's effective theme
 * colors. That reply path is always active and needs no callback.
 */
typedef void (*LabanOSCNotificationCallback)(
    void *userdata,
    LabanSession *session,
    const uint8_t *text,
    size_t len
);

int laban_session_set_osc_notification_callback(
    LabanSession *session,
    LabanOSCNotificationCallback callback,
    void *userdata
);

/*
 * OSC 9 ; 4 progress reporting (ConEmu/iTerm2 style) —
 * `ESC ] 9 ; 4 ; <operation> ; <value> BEL/ST`.
 *
 * `operation`: 0 clear, 1 determinate, 2 error, 3 indeterminate.
 * `percent` is the parsed value clamped to [0, 100], or -1 when the payload
 * carried none. Fires on whichever thread drove `laban_session_poll` /
 * `laban_session_feed_output`. Pass NULL for `callback` to disable.
 */
typedef void (*LabanProgressCallback)(
    void *userdata,
    int operation,
    int percent
);

int laban_session_set_progress_callback(
    LabanSession *session,
    LabanProgressCallback callback,
    void *userdata
);

/*
 * OSC 52 clipboard bridge — `ESC ] 52 ; <Pc> ; <Pd> BEL/ST`.
 *
 * libghostty-vt parses OSC 52 (as `clipboard_contents`) but its VT-only C API
 * registers no clipboard sink, so the sequence is parsed and dropped. Laban's
 * osc_host.c scanner closes the gap the same observe-and-act way it answers OSC
 * 10/11 and surfaces OSC 9 — letting a program running under Laban (e.g. an
 * editor or coding agent reached over SSH, where the native clipboard is out of
 * reach) place data on, or read data from, the macOS clipboard.
 *
 * `Pc` is the selection list (`c` clipboard, `p` primary, `s`, `q`, `0`-`7`).
 * macOS has a single general pasteboard, so the selection is informational: it
 * is delivered to the callbacks and echoed verbatim in a read reply, but every
 * selection maps to the same pasteboard. `selection` points at `selection_len`
 * bytes that are NOT NUL-terminated and valid only for the call.
 *
 * WRITE (`Pd` is base64): `write_callback` fires with the raw base64 payload
 * (NOT decoded — the Swift bridge decodes with the platform base64 decoder and
 * enforces the size cap). The callback runs while the session lock is held on
 * the thread driving poll()/feed_output(); copy what you need and return fast.
 *
 * READ (`Pd` is a lone `?`): `read_callback` fires ONLY when OSC 52 read has
 * been explicitly enabled (see laban_session_set_osc52_read_enabled). When read
 * is disabled — the default — a `?` query is dropped with no reply, so a remote
 * program cannot exfiltrate the host clipboard without opt-in. The handler is
 * expected to read the system clipboard off the lock (hop to the main queue)
 * and answer with laban_session_respond_clipboard_osc52.
 *
 * Pass NULL callbacks to disable. An oversized payload (past the scanner's OSC
 * 52 cap) is dropped without firing either callback.
 */
typedef void (*LabanOSCClipboardWriteCallback)(
    void *userdata,
    LabanSession *session,
    const char *selection,
    size_t selection_len,
    const uint8_t *base64,
    size_t base64_len
);

typedef void (*LabanOSCClipboardReadCallback)(
    void *userdata,
    LabanSession *session,
    const char *selection,
    size_t selection_len
);

int laban_session_set_osc_clipboard_callbacks(
    LabanSession *session,
    LabanOSCClipboardWriteCallback write_callback,
    LabanOSCClipboardReadCallback read_callback,
    void *userdata
);

/*
 * Enable (non-zero) or disable (zero, the default) answering OSC 52 read
 * queries. While disabled, `ESC ] 52 ; c ; ? ST` fires no read callback and
 * produces no PTY reply. Returns 0 on success, -1 on a NULL/closed session.
 */
int laban_session_set_osc52_read_enabled(LabanSession *session, int enabled);

/*
 * Answer an OSC 52 read query: writes `ESC ] 52 ; <selection> ; <base64> ST`
 * back to the child PTY (the terminal-response channel, captured to
 * terminal-response.bin). `base64` is the already-encoded clipboard contents;
 * `selection` should echo the queried selection (e.g. "c"). Intended to be
 * called from the read-callback handler after it has read the system clipboard.
 * Returns 0 on success, -1 on invalid input or a failed PTY write.
 */
int laban_session_respond_clipboard_osc52(
    LabanSession *session,
    const char *selection,
    size_t selection_len,
    const uint8_t *base64,
    size_t base64_len
);

/*
 * OSC 7 working-directory report — `ESC ] 7 ; file://<host>/<path> BEL/ST`.
 *
 * A shell (via its precmd hook) emits OSC 7 on each prompt to tell the terminal
 * its current directory. libghostty-vt parses it but the VT-only API does not
 * surface it, so Laban's osc_host.c scanner observes it (same observe pattern as
 * OSC 9). The reported path is also adopted as the session's authoritative cwd:
 * `laban_session_process_metadata` returns it in preference to the
 * `proc_pidinfo` working directory, which can lag or mis-attribute when the
 * foreground process differs from the shell's logical cwd.
 *
 * The `<host>` authority is validated: an empty host, `localhost`, or a match
 * to the local hostname is accepted; any other host (e.g. a remote shell over
 * SSH reporting a path that does not exist locally) is ignored, so the local
 * `proc_pidinfo` cwd stands. The path is percent-decoded and must be absolute.
 *
 * This callback is optional — observing it is not required for the cwd-adoption
 * behaviour above, which is always active. When set, it fires with the decoded
 * absolute path (NOT NUL-terminated, valid only for the call) while the session
 * lock is held on the poll()/feed_output() thread; copy and return fast. Pass
 * NULL to disable.
 */
typedef void (*LabanOSCWorkingDirectoryCallback)(
    void *userdata,
    LabanSession *session,
    const char *path,
    size_t len
);

int laban_session_set_osc_working_directory_callback(
    LabanSession *session,
    LabanOSCWorkingDirectoryCallback callback,
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
    /* 1 when the alternate screen buffer is active (vim/htop/less and full-
     * screen TUIs), 0 otherwise. */
    int alt_screen;
    /* 1 when alternate scroll mode (DEC private 1007) is set. Only meaningful
     * while alt_screen is 1 and mouse_tracking is 0: the wheel then drives the
     * app's cursor keys instead of Laban's (absent) alt-screen scrollback. */
    int alt_scroll;
} LabanViewportState;

int laban_session_scroll_viewport(LabanSession *session, int delta_rows);

/*
 * Pin the viewport to the active bottom in a single locked operation, so a
 * concurrent reader thread streaming output cannot move the live bottom
 * between the caller reading the scrollbar and applying a delta. Computing
 * `(total - len) - offset` and then scrolling by that delta is two separate
 * lock acquisitions; output appended in between lands the viewport short of
 * the real bottom and — because it is no longer exactly at the bottom —
 * libghostty does not re-engage follow-output, leaving Laban's overlay scroll
 * indicator stuck visible. This uses GHOSTTY_SCROLL_VIEWPORT_BOTTOM under one
 * lock and reports the rows moved (>= 0) via *out_delta_rows for callers that
 * gate render invalidation on whether anything changed. Returns 0 on success.
 */
int laban_session_scroll_viewport_to_bottom(LabanSession *session, int *out_delta_rows);

int laban_session_viewport_state(LabanSession *session, LabanViewportState *out_state);

/*
 * Probe sizes for a plain-text extraction of terminal rows.
 *
 * Rows are addressed in global order: scrollback/history rows first, then the
 * active viewport rows. max_rows == 0 means "all rows after row_offset".
 * On success, *out_rows is the number of rows that would be returned and
 * *out_text_capacity is the number of UTF-8 bytes needed, including newline
 * separators between returned rows and a trailing NUL. Returns 0 on success
 * and -1 on permanent error.
 */
int laban_session_scrollback_extract_size(
    LabanSession *session,
    size_t row_offset,
    size_t max_rows,
    size_t *out_rows,
    size_t *out_text_capacity
);

/*
 * Extract terminal rows as plain text into caller-owned buffers.
 *
 * The caller allocates text_buffer and row_offsets using the probe result.
 * row_offsets receives one byte offset per returned row, relative to
 * text_buffer. Rows in text_buffer are separated by '\n' and the buffer is
 * NUL-terminated. Returns 0 on success, 1 when either buffer is too small
 * (required sizes are reported), and -1 on permanent error.
 */
int laban_session_scrollback_extract(
    LabanSession *session,
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
);

/*
 * Extract terminal rows as plain text into newly allocated caller-owned
 * buffers. This is the single-pass variant used by Swift hot paths: the
 * returned text_buffer is NUL-terminated, and row_offsets receives one byte
 * offset per returned row. Release either returned pointer with
 * laban_session_scrollback_extract_free. Returns 0 on success and -1 on
 * permanent error.
 */
int laban_session_scrollback_extract_alloc(
    LabanSession *session,
    size_t row_offset,
    size_t max_rows,
    char **out_text_buffer,
    uint32_t **out_row_offsets,
    size_t *out_rows,
    size_t *out_text_len
);

void laban_session_scrollback_extract_free(void *ptr);

typedef struct {
    int row;
    int start_column;
    int end_column;
} LabanFindMatch;

/*
 * Search terminal rows for an ASCII needle and return match coordinates
 * directly. This uses the same plain-text terminal row source as scrollback
 * extraction but avoids copying all rows into a Swift string before search.
 *
 * Rows are traversed in the same global order as scrollback extraction, and
 * returned match rows are relative to the selected range. row_offset and
 * max_rows select that range. fold_ascii is non-zero for smart-case lowercase
 * ASCII search. On success, out_complete is set to 1 when every selected row
 * was searched, or 0 when the fast path declined the input and the caller
 * must fall back to full text extraction for exact Unicode column behavior.
 * Release out_matches with
 * laban_session_find_matches_free. Returns 0 on success and -1 on permanent
 * error.
 */
int laban_session_find_matches_alloc(
    LabanSession *session,
    const uint8_t *needle,
    size_t needle_len,
    int fold_ascii,
    size_t row_offset,
    size_t max_rows,
    LabanFindMatch **out_matches,
    size_t *out_count,
    int *out_complete
);

void laban_session_find_matches_free(void *ptr);

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

typedef enum {
    LABAN_MOUSE_TRACKING_NONE = 0,
    LABAN_MOUSE_TRACKING_X10 = 1,
    LABAN_MOUSE_TRACKING_NORMAL = 2,
    LABAN_MOUSE_TRACKING_BUTTON = 3,
    LABAN_MOUSE_TRACKING_ANY = 4
} LabanMouseTrackingMode;

typedef enum {
    LABAN_MOUSE_FORMAT_X10 = 0,
    LABAN_MOUSE_FORMAT_UTF8 = 1,
    LABAN_MOUSE_FORMAT_SGR = 2,
    LABAN_MOUSE_FORMAT_URXVT = 3,
    LABAN_MOUSE_FORMAT_SGR_PIXELS = 4
} LabanMouseFormat;

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
    /*
     * Optional encoder override for daemon-backed viewers. When tracking_mode
     * is LABAN_MOUSE_TRACKING_NONE, the encoder derives its mode/format from
     * the local libghostty terminal as before. Otherwise tracking_mode and
     * format are applied directly to the encoder.
     */
    LabanMouseTrackingMode tracking_mode;
    LabanMouseFormat format;
} LabanMouseEvent;

int laban_session_encode_mouse(
    LabanSession *session,
    const LabanMouseEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
);

/*
 * Encode and send a mouse event, returning the exact bytes that were written
 * to the PTY. Returns 1 without sending when out_capacity is too small; in
 * that case out_len is set to the required byte count.
 */
int laban_session_send_mouse_encoded(
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

/* Returns 1 in *out_active if synchronized output mode (DEC private 2026) is active. */
int laban_session_synchronized_output_active(LabanSession *session, int *out_active);

/* Resets synchronized output mode (DEC private 2026), matching the renderer watchdog. */
int laban_session_reset_synchronized_output(LabanSession *session);

/* Store the host light/dark scheme used for color-scheme DSR replies. */
int laban_session_set_color_scheme(LabanSession *session, int color_scheme);

/* Returns 1 in *out_enabled if focus reporting mode (DEC private 1004) is active. */
int laban_session_focus_reporting_enabled(LabanSession *session, int *out_enabled);

/*
 * Encodes focus gained/lost bytes for mode 1004. Writes zero bytes when focus
 * reporting is disabled or the session has exited.
 * focused: non-zero encodes focus gained (CSI I), zero encodes focus lost (CSI O).
 * Returns 0 on success, 1 if out_capacity is too small (*out_len holds the
 * required size), or -1 on error.
 */
int laban_session_encode_focus(
    LabanSession *session,
    int focused,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
);

/*
 * Encodes and writes a focus event to the PTY when focus reporting is active.
 * Fixture mode returns 0 after encoding; use laban_session_encode_focus in
 * tests that need to inspect the exact bytes.
 */
int laban_session_send_focus(LabanSession *session, int focused);

/*
 * Wraps ghostty_paste_is_safe(): returns 1 when the bytes contain only
 * "safe" characters (the libghostty definition flags newlines and other
 * control bytes that could constitute command injection in a raw shell).
 * Returns 0 otherwise. Pure function; no session needed.
 */
int laban_paste_is_safe(const uint8_t *bytes, size_t len);

/*
 * Drain bytes that the terminal has produced as responses to capability
 * queries (DA1/DA2/DA3, XTWINOPS, DSR cursor position, etc.).  In PTY mode
 * these bytes are also delivered directly to the PTY master fd so the child
 * process sees them; the captured copy here is for tests, fixtures, and
 * debug observability.  Removes drained bytes from the internal buffer only
 * after validating the output buffer.
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
 * bytes must be non-NULL when len > 0. out_capacity must be >= len + 14
 * to accommodate bracketed sequences.
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
 * Encode and write paste bytes, returning the exact encoded bytes committed
 * by the terminal core. Returns 1 without sending if out_capacity is too
 * small; *out_len holds the required encoded size.
 */
int laban_session_write_paste_encoded(
    LabanSession *session,
    const uint8_t *bytes,
    size_t len,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len,
    LabanPasteResult *out_result
);

/*
 * laban_session_exit_state:
 *   Lightweight query for the session's exit state. Reads status and
 *   exit_status directly from session storage without rendering or allocating.
 *   status values match LabanSnapshot.status (0=running, 1=exited normally,
 *   2=exited by signal). Returns a zero state for NULL.
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

/*
 * laban_session_send_key_encoded:
 *   Encode and write key input to the PTY, returning the exact bytes written.
 *   In fixture mode, encoding succeeds and returns the bytes without a PTY
 *   write. Returns 1 without sending when out_capacity is too small; *out_len
 *   holds the required size.
 */
int laban_session_send_key_encoded(
    LabanSession *session,
    const LabanKeyEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
);

#endif /* LABAN_TERMINAL_CORE_H */
