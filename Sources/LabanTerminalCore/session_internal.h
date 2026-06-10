#ifndef LABAN_SESSION_INTERNAL_H
#define LABAN_SESSION_INTERNAL_H

#include "LabanTerminalCore.h"
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/render.h>
#include <ghostty/vt/style.h>
#include <ghostty/vt/mouse.h>
#include <ghostty/vt/paste.h>
#include <ghostty/vt/modes.h>
#include <ghostty/vt/device.h>
#include <ghostty/vt/focus.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/formatter.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/screen.h>
#include <ghostty/vt/point.h>
#include <ghostty/vt/size_report.h>
#include <ghostty/vt/key/encoder.h>
#include <ghostty/vt/key/event.h>
#include <stdbool.h>
#include <util.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <termios.h>
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
#include <pthread.h>
#include <time.h>

#define LABAN_TITLE_MAX_BYTES 1024

/* Every public laban_session_* entry point holds this lock for the body
 * of the call. Internal helpers that require the caller to hold the lock
 * use a `_locked` suffix and must not acquire it again. The mutex remains
 * recursive as a defensive callback contract: capture/tab-status callbacks
 * can run while the lock is held, and external callback code may re-enter a
 * session method. The destructor (laban_session_destroy) deliberately does
 * NOT lock — it is the caller's contract to have stopped all other access
 * first.
 *
 * SESSION_LOCK(s) acquires the lock and registers an automatic release
 * on scope exit via __attribute__((cleanup)), so every return path —
 * including the many existing early returns scattered through this
 * target — unlocks correctly without needing UNLOCK at each return. */
#define SESSION_LOCK(s)                                                 \
    pthread_mutex_lock(&(s)->lock);                                     \
    LabanSession *_session_lock_guard                                   \
        __attribute__((cleanup(laban_session_unlock_cleanup_))) = (s);  \
    (void)_session_lock_guard

/* Vectorized skip for the raw-output scanners below (tab_status.c, osc133.c,
 * osc_host.c). In their bulk "skip" states the state machines react only to
 * ESC — plus BEL inside OSC/DCS string bodies — so instead of stepping the
 * switch per byte they jump straight to the next interesting byte with
 * memchr (SIMD-accelerated in libsystem). On plain-text/SGR-heavy streams,
 * the overwhelmingly common case, this collapses three per-byte passes over
 * every PTY chunk into a few short vectorized scans (the scanners were ~25%
 * of all CPU under a flood workload before this).
 *
 * Both helpers return the index of the first ESC (or BEL) at or after `i`,
 * or `len` when the chunk has no such byte. The caller transitions on
 * bytes[result] exactly as the per-byte loop would have. */
static inline size_t laban_scan_skip_to_esc(
    const uint8_t *bytes, size_t len, size_t i) {
    const uint8_t *p = memchr(bytes + i, 0x1B, len - i);
    return p ? (size_t)(p - bytes) : len;
}

static inline size_t laban_scan_skip_to_esc_or_bel(
    const uint8_t *bytes, size_t len, size_t i) {
    const uint8_t *esc = memchr(bytes + i, 0x1B, len - i);
    size_t bound = esc ? (size_t)(esc - bytes) : len;
    const uint8_t *bel = memchr(bytes + i, 0x07, bound - i);
    return bel ? (size_t)(bel - bytes) : bound;
}

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
#define TAB_STATUS_PAYLOAD_MAX 1024 /* observed payloads < 100 bytes */

typedef struct {
    TabStatusState state;
    char num[TAB_STATUS_NUM_MAX];
    size_t num_len;
    char payload[TAB_STATUS_PAYLOAD_MAX];
    size_t payload_len;
    int payload_overflow;
} LabanTabStatusScanner;

/* OSC 133 ("semantic prompt") scanner state. Sniffs
 * `ESC ] 133 ; <action>[;<exit>] ST/BEL` out of the PTY byte stream in
 * parallel with libghostty's parser. libghostty-vt parses OSC 133 internally
 * but its C API exposes no way to read the action letter or exit code (only
 * GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR), so Laban scans for it directly —
 * the same approach as the OSC 21337 scanner above. Observe-only: every byte
 * still flows unchanged to libghostty. */
typedef enum {
    O133_NORMAL = 0,
    O133_AFTER_ESC,
    O133_OSC_NUM,
    O133_BODY_133,
    O133_BODY_133_AFTER_ESC,
    O133_BODY_OTHER,
    O133_BODY_OTHER_AFTER_ESC,
    /* Inside a DCS/SOS/PM/APC string (ESC P / X / ^ / _ ... ST). Bytes here
     * are skipped, not scanned for OSC, so a 133-looking byte run embedded in
     * such a string is not mis-parsed as a real marker. */
    O133_STRING,
    O133_STRING_AFTER_ESC,
} OSC133State;

#define OSC133_NUM_MAX 8        /* "133" + room */
#define OSC133_PAYLOAD_MAX 64   /* action char + optional ";<digits>" */

typedef struct {
    OSC133State state;
    char num[OSC133_NUM_MAX];
    size_t num_len;
    char payload[OSC133_PAYLOAD_MAX];
    size_t payload_len;
    int payload_overflow;
} LabanOSC133Scanner;

/* OSC host-integration scanner. Sniffs a small set of OSCs out of the PTY byte
 * stream that libghostty-vt parses but neither answers nor surfaces:
 *   - OSC 10;? / OSC 11;?  -> default foreground/background color query.
 *     libghostty parses it but the handler is a no-op, so Laban replies here
 *     with the theme's effective fg/bg (Codex probes this to match its theme).
 *   - OSC 9;<text>         -> desktop notification (e.g. Codex turn-complete).
 *     Delivered to osc_notification_callback. ConEmu progress (OSC 9;4;...) is
 *     skipped.
 *   - OSC 52;<Pc>;<Pd>     -> clipboard set (Pd base64) / query (Pd '?').
 *     Bridged to the macOS clipboard via osc_clipboard_{write,read}_callback so
 *     a program reached over SSH can copy to / read from the host pasteboard.
 *   - OSC 7;file://<host>/<path> -> shell working-directory report. Adopted as
 *     the session's authoritative cwd (preferred over proc_pidinfo in
 *     laban_session_process_metadata) when the host is local; also delivered to
 *     osc_cwd_callback. A remote host (e.g. an SSH shell) is ignored.
 * Same observe-and-act-in-parallel approach as the OSC 133 / OSC 21337 scanners
 * above; every byte still flows unchanged to libghostty. */
typedef enum {
    OH_NORMAL = 0,
    OH_AFTER_ESC,
    OH_OSC_NUM,
    OH_BODY,                /* payload of an OSC we care about (7/9/10/11/52) */
    OH_BODY_AFTER_ESC,
    OH_BODY_OTHER,          /* payload of an OSC we ignore: skip to terminator */
    OH_BODY_OTHER_AFTER_ESC,
    OH_STRING,              /* inside a DCS/SOS/PM/APC string: skip, do not scan */
    OH_STRING_AFTER_ESC,
} OSCHostState;

#define OSC_HOST_NUM_MAX 8        /* "11" + room */
/* Color queries are tiny and notification text is short, but an OSC 7
 * `file://host/path` cwd report can approach a percent-encoded PATH_MAX, so the
 * inline payload is sized to hold a realistic file:// URL. (Clipboard data is
 * far larger and uses the separate osc52_buf below, not this buffer.) */
#define OSC_HOST_PAYLOAD_MAX 2048

/* OSC 52 clipboard payloads can be large (Codex caps copies at 100 KB raw, so
 * ~133 KB base64), far past the inline OSC_HOST_PAYLOAD_MAX. They accumulate in
 * a separate heap buffer (osc52_buf) allocated lazily on the first OSC 52 byte,
 * grown up to this cap, and freed at session destroy. A payload past the cap is
 * dropped (clipboard left untouched) rather than truncated. 256 KiB leaves
 * comfortable headroom over Codex's limit while staying well under the 10 MiB
 * paste ceiling. */
#define OSC_HOST_OSC52_MAX (256 * 1024)

typedef struct {
    OSCHostState state;
    char num[OSC_HOST_NUM_MAX];
    size_t num_len;
    int osc_number;           /* parsed number once ';' is seen; -1 before then */
    char payload[OSC_HOST_PAYLOAD_MAX];
    size_t payload_len;
    int payload_overflow;

    /* OSC 52 accumulation (used only when osc_number == 52). */
    char *osc52_buf;          /* lazily heap-allocated; NULL until first use */
    size_t osc52_len;
    size_t osc52_cap;
    int osc52_overflow;
} LabanOSCHostScanner;

struct LabanSession {
    /* Serializes access to every field below. Recursive (PTHREAD_MUTEX_RECURSIVE). */
    pthread_mutex_t lock;

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

    /* Active screen and viewport tracking for renderer damage.
     * libghostty's per-row dirty bits track cell mutations, not every way the
     * visible grid can be reinterpreted. Restoring the primary screen on
     * ?1049l leaves untouched rows clean even though every visible row changed;
     * changing scrollback viewport offset likewise shifts which absolute rows
     * occupy the viewport even when the reported dirty set is row-local. A
     * snapshot forces all rows dirty when either identity differs from the one
     * that was last *rendered*, so a persistent renderer target does not keep
     * pixels from the previous screen or viewport.
     *
     * last_snapshot_active_screen is observed by every snapshot under the
     * session lock; last_rendered_active_screen is committed to that observed
     * value by mark_rendered. The viewport offset fields follow the same
     * snapshot-observed/rendered-committed pattern. Comparing against the
     * *rendered* values — not live re-queries — keeps the signal race-free
     * against the pty thread advancing terminal state between a frame's
     * snapshot and its mark_rendered, and keeps out-of-band snapshots from
     * consuming the transition before the next rendered frame sees it. */
    int last_snapshot_active_screen;
    int last_rendered_active_screen;
    int last_snapshot_viewport_offset;
    int last_snapshot_viewport_offset_valid;
    int last_rendered_viewport_offset;
    int last_rendered_viewport_offset_valid;
    uint8_t *last_snapshot_dirty_rows;
    size_t last_snapshot_dirty_row_count;
    size_t last_snapshot_dirty_row_cap;
    int last_snapshot_dirty_rows_valid;
    uint64_t dirty_generation;
    uint64_t last_snapshot_dirty_generation;

    int capture_fd;      /* file descriptor for PTY-byte capture; -1 if inactive */
    LabanCaptureBytesCallback capture_callback;
    void *capture_userdata;

    /* Persistence tee: fires from laban_vt_write_capture after the
     * capture callback and before ghostty_terminal_vt_write. The
     * callback MUST do nothing more than memcpy bytes into a Swift-side
     * ring buffer and return — see LabanPersistenceBytesCallback
     * comment in the public header. */
    LabanPersistenceBytesCallback persistence_callback;
    void *persistence_userdata;

    LabanTabStatusScanner tab_status_scanner;
    LabanTabStatusCallback tab_status_callback;
    void *tab_status_userdata;

    LabanOSC133Scanner osc133_scanner;
    LabanOSC133Callback osc133_callback;
    void *osc133_userdata;

    LabanOSCHostScanner osc_host_scanner;
    LabanOSCNotificationCallback osc_notification_callback;
    void *osc_notification_userdata;

    /* OSC 52 clipboard bridge (osc_host.c). Write is always honored when a
     * write callback is set; read fires only when osc52_read_enabled is set
     * (default 0 — a remote query cannot read the host clipboard unasked). */
    LabanOSCClipboardWriteCallback osc_clipboard_write_callback;
    LabanOSCClipboardReadCallback osc_clipboard_read_callback;
    void *osc_clipboard_userdata;
    int osc52_read_enabled;

    /* OSC 7 working-directory report (osc_host.c). osc7_cwd holds the last
     * local-host cwd a shell reported; laban_session_process_metadata prefers it
     * over the proc_pidinfo cwd once valid. osc_cwd_callback observes reports. */
    char osc7_cwd[PATH_MAX];
    int osc7_cwd_valid;
    LabanOSCWorkingDirectoryCallback osc_cwd_callback;
    void *osc_cwd_userdata;

    uint64_t bell_count;
    LabanBellCallback bell_callback;
    void *bell_userdata;

    /* Cached geometry for the SIZE effect (XTWINOPS replies). */
    uint16_t cols;
    uint16_t rows;
    uint32_t cell_width;
    uint32_t cell_height;
    int color_scheme;

    /* True for a session created with `defer_spawn=1` whose
     * laban_session_start_spawn has not been called yet. While true
     * the session has no PTY and no child process; the VT parser still
     * accepts bytes via laban_session_feed_output /
     * laban_session_replay_pty_output, which is how restored
     * transcripts paint scrollback before the live shell starts. */
    int pending_spawn;
    /* Pixel/row geometry captured at create time so a later deferred
     * spawn can reproduce the openpty winsize correctly even if the
     * caller no longer holds the original LabanTerminalSize. */
    int pending_pixel_width;
    int pending_pixel_height;

    /* Deep copy of config->envp captured at create time. The caller's
     * envp strings live only for the duration of laban_session_create
     * (Swift's withCStringArray scope), so a deferred spawn — which runs
     * much later in laban_session_spawn_now_ — must read from this owned
     * copy, not the freed originals. NULL when no overrides were given.
     * NULL-terminated array of owned C strings; freed in destroy. */
    char **stored_envp;

    /* Restore handoff guard. When true, PTY output from the newly
     * spawned shell is drained and discarded until the first input
     * write. A restored tab already painted the prior prompt from the
     * transcript; keeping the replacement shell's startup prompt out
     * of the VT parser prevents quit/reopen cycles from stacking zsh
     * PROMPT_SP markers or prompt rows. */
    int suppress_pty_output_until_input;

    /* Capture of bytes the terminal wants written back to the pty
       (capability replies: DA1/DA2/DA3, XTWINOPS, DSR, XTVERSION, ...).
       In pty mode these are also forwarded to pty_fd; in fixture mode
       this is the only place they live. Drained via
       laban_session_drain_response. */
    uint8_t *response_buf;
    size_t   response_len;
    size_t   response_cap;

    /* Drain-loop microbench counters. Incremented inside
     * laban_session_drain_locked_; sampled via laban_session_drain_stats.
     * Wraps after 2^64 reads — bench-only, not used by product code. */
    uint64_t drain_reads;
    uint64_t drain_bytes;
};

static inline void laban_session_unlock_cleanup_(LabanSession **sp) {
    if (sp && *sp) pthread_mutex_unlock(&(*sp)->lock);
}

void laban_emit_capture_bytes(
    LabanSession *s,
    LabanCaptureBytesDirection direction,
    const uint8_t *bytes,
    size_t len
);
void laban_scan_tab_status(LabanSession *s, const uint8_t *bytes, size_t len);
void laban_scan_osc133(LabanSession *s, const uint8_t *bytes, size_t len);
/* Scans for host-integration OSCs AND owns the ghostty_terminal_vt_write of
 * the chunk: bytes are flushed into the parser up to each interesting OSC
 * terminator before its dispatch so replies land in stream order relative to
 * parser-emitted replies (CPR/DA). The caller must NOT vt_write the chunk. */
void laban_scan_osc_host_vt_write(LabanSession *s, const uint8_t *bytes, size_t len);
void laban_vt_write_capture(LabanSession *s, const uint8_t *bytes, size_t len);
void laban_session_note_terminal_dirty(LabanSession *s);
int laban_write_pty_bytes(
    LabanSession *s,
    const uint8_t *bytes,
    size_t len,
    LabanCaptureBytesDirection direction
);
int laban_write_pty_input(LabanSession *s, const uint8_t *bytes, size_t len);
pid_t laban_waitpid_retry(pid_t pid, int *status, int options);
void laban_signal_child_process_group(pid_t child_pid, int sig);
int laban_session_mode_active_locked(LabanSession *s, GhosttyMode mode, int *out_active);
int laban_write_terminal_response(LabanSession *s, const uint8_t *data, size_t len);
int laban_session_spawn_now_(LabanSession *s, const char *override_cwd,
                             const char *exe_override,
                             const char *const *argv_override);

void laban_title_changed_cb(GhosttyTerminal terminal, void *userdata);
void laban_bell_cb(GhosttyTerminal terminal, void *userdata);
void laban_effect_write_pty(GhosttyTerminal terminal, void *userdata,
                            const uint8_t *data, size_t len);
bool laban_effect_size(GhosttyTerminal terminal, void *userdata,
                       GhosttySizeReportSize *out_size);
bool laban_effect_device_attributes(GhosttyTerminal terminal, void *userdata,
                                    GhosttyDeviceAttributes *out_attrs);
GhosttyString laban_effect_xtversion(GhosttyTerminal terminal, void *userdata);
GhosttyString laban_effect_enquiry(GhosttyTerminal terminal, void *userdata);
bool laban_effect_color_scheme(GhosttyTerminal terminal, void *userdata,
                               GhosttyColorScheme *out_scheme);

#endif /* LABAN_SESSION_INTERNAL_H */
