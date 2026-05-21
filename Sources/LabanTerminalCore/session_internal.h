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

    /* Active screen (primary/alternate) tracking for renderer damage.
     * libghostty's per-row dirty bits track cell mutations, not screen swaps:
     * restoring the primary screen on ?1049l leaves its untouched rows clean
     * even though every visible row changed. A snapshot forces all rows dirty
     * when the active screen differs from the one that was last *rendered*, so
     * the renderer's persistent target does not keep the old screen's pixels
     * (the "black flash" between two full-screen TUIs).
     *
     * last_snapshot_active_screen is observed by every snapshot under the
     * session lock; last_rendered_active_screen is committed to that observed
     * value by mark_rendered. Comparing against the *rendered* value — not a
     * live re-query — keeps the signal race-free against the pty thread
     * advancing terminal state between a frame's snapshot and its
     * mark_rendered, and keeps out-of-band snapshots from consuming the
     * transition before the next rendered frame sees it. */
    int last_snapshot_active_screen;
    int last_rendered_active_screen;

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
void laban_vt_write_capture(LabanSession *s, const uint8_t *bytes, size_t len);
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
