/*
 * Kitty clipboard protocol (OSC 5522) bridge — ADR 0040.
 *
 * libghostty-vt implements the protocol: request parsing, MIME lists,
 * one-time passwords, and paste events (DEC private mode 5522). Laban
 * installs its clipboard_read effect and serves exactly one kind of read:
 * the follow-up read a program makes after the user pressed ⌘V while the
 * program had paste events enabled. Those reads arrive with `granted` set
 * and are answered from the snapshot of the pasteboard taken at that paste
 * (laban_session_encode_paste_event), so the effect never touches the live
 * clipboard and never needs the main thread. Every other read is denied
 * (EPERM), keeping ADR 0014's default-deny stance for unsolicited reads.
 *
 * OSC 52 `?` reads stay with osc_host.c (ADR 0014). Installing a
 * clipboard_read effect makes libghostty route them here too and answer
 * with an empty clipboard when the effect does not reply; that duplicate
 * reply is dropped by laban_effect_write_pty_intercept.
 */
#include "session_internal.h"

#include <stdlib.h>
#include <string.h>

void laban_paste_snapshot_clear(LabanPasteSnapshot *snapshot) {
    if (!snapshot) return;
    for (size_t i = 0; i < snapshot->count; i++) {
        free(snapshot->items[i].mime);
        free(snapshot->items[i].data);
    }
    memset(snapshot, 0, sizeof(*snapshot));
}

/* True while osc_host.c is flushing an OSC 52 sequence into libghostty, i.e.
 * the clipboard_read effect is firing for an OSC 52 `?`, not OSC 5522. */
static int osc52_in_flight(const LabanSession *s) {
    const LabanOSCHostScanner *sc = &s->osc_host_scanner;
    return (sc->state == OH_BODY || sc->state == OH_BODY_AFTER_ESC)
        && sc->osc_number == 52;
}

static int mime_eq(const LabanPasteSnapshotItem *item, GhosttyString mime) {
    return item->mime_len == mime.len
        && (mime.len == 0 || memcmp(item->mime, mime.ptr, mime.len) == 0);
}

void laban_effect_clipboard_read(GhosttyTerminal terminal, void *userdata,
                                 const GhosttyClipboardRead *read) {
    (void)terminal;
    LabanSession *s = (LabanSession *)userdata;
    if (!s || !read || !read->reply) return;

    if (osc52_in_flight(s)) {
        /* osc_host answers (or silently drops) this read; suppress the
         * empty reply libghostty sends when we return without one. */
        s->drop_osc52_read_reply = 1;
        return;
    }

    GhosttyClipboardReadReply reply;
    memset(&reply, 0, sizeof(reply));
    reply.size = sizeof(reply);

    const LabanPasteSnapshot *snap = &s->paste_snapshot;
    int list_only = read->mimes_len == 0;
    if (!list_only && !read->granted) {
        reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_DENIED;
        read->reply(read, &reply);
        return;
    }

    GhosttyClipboardContent contents[LABAN_PASTE_SNAPSHOT_MAX_ITEMS];
    GhosttyString available[LABAN_PASTE_SNAPSHOT_MAX_ITEMS];
    size_t contents_len = 0;
    for (size_t m = 0; m < read->mimes_len && read->mimes; m++) {
        for (size_t i = 0; i < snap->count; i++) {
            const LabanPasteSnapshotItem *item = &snap->items[i];
            if (!mime_eq(item, read->mimes[m])) continue;
            int dup = 0;
            for (size_t c = 0; c < contents_len; c++) {
                if (contents[c].mime.ptr == (const uint8_t *)item->mime) dup = 1;
            }
            if (dup || contents_len >= LABAN_PASTE_SNAPSHOT_MAX_ITEMS) break;
            contents[contents_len].mime =
                (GhosttyString){ (const uint8_t *)item->mime, item->mime_len };
            contents[contents_len].data = (GhosttyString){ item->data, item->data_len };
            contents_len++;
            break;
        }
    }
    for (size_t i = 0; i < snap->count; i++) {
        available[i] = (GhosttyString){
            (const uint8_t *)snap->items[i].mime, snap->items[i].mime_len };
    }

    reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS;
    reply.contents = contents_len ? contents : NULL;
    reply.contents_len = contents_len;
    if (read->list) {
        reply.available = snap->count ? available : NULL;
        reply.available_len = snap->count;
    }
    read->reply(read, &reply);
}

static void byte_buffer_append(LabanByteBuffer *buf, const uint8_t *data, size_t len) {
    if (buf->failed || len == 0) return;
    size_t needed = buf->len + len;
    if (needed > buf->cap) {
        size_t new_cap = buf->cap ? buf->cap : 256;
        while (new_cap < needed) new_cap *= 2;
        uint8_t *nb = realloc(buf->bytes, new_cap);
        if (!nb) { buf->failed = 1; return; }
        buf->bytes = nb;
        buf->cap = new_cap;
    }
    memcpy(buf->bytes + buf->len, data, len);
    buf->len += len;
}

int laban_effect_write_pty_intercept(LabanSession *s, const uint8_t *data, size_t len) {
    if (s->drop_osc52_read_reply) {
        s->drop_osc52_read_reply = 0;
        if (len >= 5 && memcmp(data, "\x1b]52;", 5) == 0) return 1;
    }
    if (s->paste_event_capture) {
        byte_buffer_append(s->paste_event_capture, data, len);
        return 1;
    }
    return 0;
}

int laban_session_paste_events_enabled(LabanSession *s, int *out_enabled) {
    if (out_enabled) *out_enabled = 0;
    if (!s || !out_enabled) return -1;
    SESSION_LOCK(s);
    return laban_session_mode_active_locked(s, GHOSTTY_MODE_PASTE_EVENTS, out_enabled);
}

/* The paste event lists MIME types only; libghostty never reads data for it. */
static bool paste_event_reader(void *userdata, GhosttyString mime, GhosttyWriter writer) {
    (void)userdata;
    (void)mime;
    (void)writer;
    return false;
}

static int snapshot_store(LabanPasteSnapshot *snap, const LabanPasteItem *items, size_t count) {
    laban_paste_snapshot_clear(snap);
    size_t total = 0;
    for (size_t i = 0; i < count && snap->count < LABAN_PASTE_SNAPSHOT_MAX_ITEMS; i++) {
        const LabanPasteItem *in = &items[i];
        if (!in->mime || in->mime_len == 0) continue;
        if (in->data_len > 0 && !in->data) continue;
        if (in->data_len > LABAN_PASTE_SNAPSHOT_MAX_BYTES - total) continue;
        LabanPasteSnapshotItem *out = &snap->items[snap->count];
        out->mime = malloc(in->mime_len);
        out->data = malloc(in->data_len ? in->data_len : 1);
        if (!out->mime || !out->data) {
            free(out->mime);
            free(out->data);
            laban_paste_snapshot_clear(snap);
            return -1;
        }
        memcpy(out->mime, in->mime, in->mime_len);
        if (in->data_len) memcpy(out->data, in->data, in->data_len);
        out->mime_len = in->mime_len;
        out->data_len = in->data_len;
        total += in->data_len;
        snap->count++;
    }
    return 0;
}

int laban_session_encode_paste_event(
    LabanSession *s,
    const LabanPasteItem *items,
    size_t count,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (out_len) *out_len = 0;
    if (!s || !out_len || (count > 0 && !items)) return -1;
    if (!out_bytes && out_capacity > 0) return -1;
    SESSION_LOCK(s);

    int enabled = 0;
    if (laban_session_mode_active_locked(s, GHOSTTY_MODE_PASTE_EVENTS, &enabled) != 0) return -1;
    if (!enabled) return 0;
    if (snapshot_store(&s->paste_snapshot, items, count) != 0) return -1;
    if (s->paste_snapshot.count == 0) return 0;

    GhosttyString mimes[LABAN_PASTE_SNAPSHOT_MAX_ITEMS];
    for (size_t i = 0; i < s->paste_snapshot.count; i++) {
        mimes[i] = (GhosttyString){
            (const uint8_t *)s->paste_snapshot.items[i].mime,
            s->paste_snapshot.items[i].mime_len };
    }
    GhosttyPaste paste;
    memset(&paste, 0, sizeof(paste));
    paste.size = sizeof(paste);
    paste.location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD;
    paste.source = GHOSTTY_PASTE_SOURCE_CLIPBOARD;
    paste.mimes = mimes;
    paste.mimes_len = s->paste_snapshot.count;
    paste.reader = (GhosttyMimeReader){ paste_event_reader, NULL };

    LabanByteBuffer capture = {0};
    s->paste_event_capture = &capture;
    bool written = false;
    GhosttyResult r = ghostty_terminal_paste(s->terminal, &paste, &written);
    s->paste_event_capture = NULL;

    int rc = 0;
    if (r != GHOSTTY_SUCCESS || capture.failed) {
        rc = -1;
    } else if (capture.len > out_capacity) {
        *out_len = capture.len;
        rc = 1;
    } else {
        if (capture.len) memcpy(out_bytes, capture.bytes, capture.len);
        *out_len = capture.len;
    }
    free(capture.bytes);
    return rc;
}
