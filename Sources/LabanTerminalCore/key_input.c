#include "session_internal.h"

#define LABAN_KEY_ENCODE_OUT_OF_SPACE 1

static GhosttyKeyAction map_laban_key_action(LabanKeyAction action) {
    switch (action) {
        case LABAN_KEY_ACTION_PRESS:   return GHOSTTY_KEY_ACTION_PRESS;
        case LABAN_KEY_ACTION_REPEAT:  return GHOSTTY_KEY_ACTION_REPEAT;
        case LABAN_KEY_ACTION_RELEASE: return GHOSTTY_KEY_ACTION_RELEASE;
        default:                        return GHOSTTY_KEY_ACTION_PRESS;
    }
}

static GhosttyKey map_laban_key(LabanKey key) {
    switch (key) {
        case LABAN_KEY_BACKQUOTE:     return GHOSTTY_KEY_BACKQUOTE;
        case LABAN_KEY_BACKSLASH:     return GHOSTTY_KEY_BACKSLASH;
        case LABAN_KEY_BRACKET_LEFT:  return GHOSTTY_KEY_BRACKET_LEFT;
        case LABAN_KEY_BRACKET_RIGHT: return GHOSTTY_KEY_BRACKET_RIGHT;
        case LABAN_KEY_COMMA:         return GHOSTTY_KEY_COMMA;
        case LABAN_KEY_DIGIT_0:       return GHOSTTY_KEY_DIGIT_0;
        case LABAN_KEY_DIGIT_1:       return GHOSTTY_KEY_DIGIT_1;
        case LABAN_KEY_DIGIT_2:       return GHOSTTY_KEY_DIGIT_2;
        case LABAN_KEY_DIGIT_3:       return GHOSTTY_KEY_DIGIT_3;
        case LABAN_KEY_DIGIT_4:       return GHOSTTY_KEY_DIGIT_4;
        case LABAN_KEY_DIGIT_5:       return GHOSTTY_KEY_DIGIT_5;
        case LABAN_KEY_DIGIT_6:       return GHOSTTY_KEY_DIGIT_6;
        case LABAN_KEY_DIGIT_7:       return GHOSTTY_KEY_DIGIT_7;
        case LABAN_KEY_DIGIT_8:       return GHOSTTY_KEY_DIGIT_8;
        case LABAN_KEY_DIGIT_9:       return GHOSTTY_KEY_DIGIT_9;
        case LABAN_KEY_EQUAL:         return GHOSTTY_KEY_EQUAL;
        case LABAN_KEY_A:             return GHOSTTY_KEY_A;
        case LABAN_KEY_B:             return GHOSTTY_KEY_B;
        case LABAN_KEY_C:             return GHOSTTY_KEY_C;
        case LABAN_KEY_D:             return GHOSTTY_KEY_D;
        case LABAN_KEY_E:             return GHOSTTY_KEY_E;
        case LABAN_KEY_F:             return GHOSTTY_KEY_F;
        case LABAN_KEY_G:             return GHOSTTY_KEY_G;
        case LABAN_KEY_H:             return GHOSTTY_KEY_H;
        case LABAN_KEY_I:             return GHOSTTY_KEY_I;
        case LABAN_KEY_J:             return GHOSTTY_KEY_J;
        case LABAN_KEY_K:             return GHOSTTY_KEY_K;
        case LABAN_KEY_L:             return GHOSTTY_KEY_L;
        case LABAN_KEY_M:             return GHOSTTY_KEY_M;
        case LABAN_KEY_N:             return GHOSTTY_KEY_N;
        case LABAN_KEY_O:             return GHOSTTY_KEY_O;
        case LABAN_KEY_P:             return GHOSTTY_KEY_P;
        case LABAN_KEY_Q:             return GHOSTTY_KEY_Q;
        case LABAN_KEY_R:             return GHOSTTY_KEY_R;
        case LABAN_KEY_S:             return GHOSTTY_KEY_S;
        case LABAN_KEY_T:             return GHOSTTY_KEY_T;
        case LABAN_KEY_U:             return GHOSTTY_KEY_U;
        case LABAN_KEY_V:             return GHOSTTY_KEY_V;
        case LABAN_KEY_W:             return GHOSTTY_KEY_W;
        case LABAN_KEY_X:             return GHOSTTY_KEY_X;
        case LABAN_KEY_Y:             return GHOSTTY_KEY_Y;
        case LABAN_KEY_Z:             return GHOSTTY_KEY_Z;
        case LABAN_KEY_MINUS:         return GHOSTTY_KEY_MINUS;
        case LABAN_KEY_PERIOD:        return GHOSTTY_KEY_PERIOD;
        case LABAN_KEY_QUOTE:         return GHOSTTY_KEY_QUOTE;
        case LABAN_KEY_SEMICOLON:     return GHOSTTY_KEY_SEMICOLON;
        case LABAN_KEY_SLASH:         return GHOSTTY_KEY_SLASH;
        case LABAN_KEY_BACKSPACE:     return GHOSTTY_KEY_BACKSPACE;
        case LABAN_KEY_ENTER:         return GHOSTTY_KEY_ENTER;
        case LABAN_KEY_SPACE:         return GHOSTTY_KEY_SPACE;
        case LABAN_KEY_TAB:           return GHOSTTY_KEY_TAB;
        case LABAN_KEY_DELETE:        return GHOSTTY_KEY_DELETE;
        case LABAN_KEY_END:           return GHOSTTY_KEY_END;
        case LABAN_KEY_HOME:          return GHOSTTY_KEY_HOME;
        case LABAN_KEY_INSERT:        return GHOSTTY_KEY_INSERT;
        case LABAN_KEY_PAGE_DOWN:     return GHOSTTY_KEY_PAGE_DOWN;
        case LABAN_KEY_PAGE_UP:       return GHOSTTY_KEY_PAGE_UP;
        case LABAN_KEY_ARROW_DOWN:    return GHOSTTY_KEY_ARROW_DOWN;
        case LABAN_KEY_ARROW_LEFT:    return GHOSTTY_KEY_ARROW_LEFT;
        case LABAN_KEY_ARROW_RIGHT:   return GHOSTTY_KEY_ARROW_RIGHT;
        case LABAN_KEY_ARROW_UP:      return GHOSTTY_KEY_ARROW_UP;
        case LABAN_KEY_ESCAPE:        return GHOSTTY_KEY_ESCAPE;
        case LABAN_KEY_F1:            return GHOSTTY_KEY_F1;
        case LABAN_KEY_F2:            return GHOSTTY_KEY_F2;
        case LABAN_KEY_F3:            return GHOSTTY_KEY_F3;
        case LABAN_KEY_F4:            return GHOSTTY_KEY_F4;
        case LABAN_KEY_F5:            return GHOSTTY_KEY_F5;
        case LABAN_KEY_F6:            return GHOSTTY_KEY_F6;
        case LABAN_KEY_F7:            return GHOSTTY_KEY_F7;
        case LABAN_KEY_F8:            return GHOSTTY_KEY_F8;
        case LABAN_KEY_F9:            return GHOSTTY_KEY_F9;
        case LABAN_KEY_F10:           return GHOSTTY_KEY_F10;
        case LABAN_KEY_F11:           return GHOSTTY_KEY_F11;
        case LABAN_KEY_F12:           return GHOSTTY_KEY_F12;
        case LABAN_KEY_F13:           return GHOSTTY_KEY_F13;
        case LABAN_KEY_F14:           return GHOSTTY_KEY_F14;
        case LABAN_KEY_F15:           return GHOSTTY_KEY_F15;
        case LABAN_KEY_F16:           return GHOSTTY_KEY_F16;
        case LABAN_KEY_F17:           return GHOSTTY_KEY_F17;
        case LABAN_KEY_F18:           return GHOSTTY_KEY_F18;
        case LABAN_KEY_F19:           return GHOSTTY_KEY_F19;
        case LABAN_KEY_F20:           return GHOSTTY_KEY_F20;
        case LABAN_KEY_F21:           return GHOSTTY_KEY_F21;
        case LABAN_KEY_F22:           return GHOSTTY_KEY_F22;
        case LABAN_KEY_F23:           return GHOSTTY_KEY_F23;
        case LABAN_KEY_F24:           return GHOSTTY_KEY_F24;
        default:                       return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

static int utf8_is_c0_or_pua(const char *utf8, size_t len) {
    if (!utf8 || len == 0) return 0;
    if (len == 1) {
        uint8_t b = (uint8_t)utf8[0];
        return b <= 0x1Fu || b == 0x7Fu;
    }
    /* U+F700-U+F8FF in UTF-8: 0xEF 0x9C-0xA3 0x80-0xBF */
    if (len == 3) {
        uint8_t b0 = (uint8_t)utf8[0];
        uint8_t b1 = (uint8_t)utf8[1];
        return b0 == 0xEFu && b1 >= 0x9Cu && b1 <= 0xA3u;
    }
    return 0;
}

static int laban_session_encode_key_locked(
    LabanSession *s,
    const LabanKeyEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (out_len) *out_len = 0;
    if (!s || !event || !out_len) return -1;
    if (!out_bytes && out_capacity > 0) return -1;

    /* Sync encoder from terminal state; this resets option-as-alt to FALSE. */
    ghostty_key_encoder_setopt_from_terminal(s->key_encoder, s->terminal);

    /* Keep option-as-alt false — a future settings path can override this. */
    GhosttyOptionAsAlt opt_as_alt = GHOSTTY_OPTION_AS_ALT_FALSE;
    ghostty_key_encoder_setopt(s->key_encoder,
        GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &opt_as_alt);

    ghostty_key_event_set_action(s->key_event, map_laban_key_action(event->action));
    ghostty_key_event_set_key(s->key_event, map_laban_key(event->key));
    ghostty_key_event_set_mods(s->key_event, (GhosttyMods)(event->modifiers & 0xFFFF));
    ghostty_key_event_set_consumed_mods(s->key_event,
        (GhosttyMods)(event->consumed_modifiers & 0xFFFF));
    ghostty_key_event_set_composing(s->key_event, (bool)(event->composing != 0));
    ghostty_key_event_set_unshifted_codepoint(s->key_event, event->unshifted_codepoint);

    if (event->utf8 && event->utf8_len > 0 &&
        !utf8_is_c0_or_pua(event->utf8, event->utf8_len)) {
        ghostty_key_event_set_utf8(s->key_event, event->utf8, event->utf8_len);
    } else {
        ghostty_key_event_set_utf8(s->key_event, NULL, 0);
    }

    GhosttyResult r = ghostty_key_encoder_encode(
        s->key_encoder, s->key_event,
        (char *)out_bytes, out_capacity, out_len);

    /* Clear the UTF-8 pointer so the persistent event never holds a stale pointer. */
    ghostty_key_event_set_utf8(s->key_event, NULL, 0);

    if (r == GHOSTTY_SUCCESS) return 0;
    if (r == GHOSTTY_OUT_OF_SPACE) return LABAN_KEY_ENCODE_OUT_OF_SPACE;
    return -1;
}

int laban_session_encode_key(
    LabanSession *s,
    const LabanKeyEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (out_len) *out_len = 0;
    if (!s || !event || !out_len) return -1;
    if (!out_bytes && out_capacity > 0) return -1;
    SESSION_LOCK(s);
    return laban_session_encode_key_locked(s, event, out_bytes, out_capacity, out_len);
}

static int laban_session_send_key_encoded_locked(
    LabanSession *s,
    const LabanKeyEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (out_len) *out_len = 0;
    if (!s || !event || !out_len) return -1;
    if (!out_bytes && out_capacity > 0) return -1;

    int rc = laban_session_encode_key_locked(s, event, out_bytes, out_capacity, out_len);
    if (rc != 0) return rc;
    if (*out_len == 0) return 0;
    if (s->fixture_mode) return 0;
    if (s->pty_fd < 0) return -1;

    return laban_write_pty_input(s, out_bytes, *out_len);
}

int laban_session_send_key_encoded(
    LabanSession *s,
    const LabanKeyEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (out_len) *out_len = 0;
    if (!s || !event || !out_len) return -1;
    if (!out_bytes && out_capacity > 0) return -1;
    SESSION_LOCK(s);
    return laban_session_send_key_encoded_locked(
        s, event, out_bytes, out_capacity, out_len);
}

int laban_session_send_key(LabanSession *s, const LabanKeyEvent *event) {
    if (!s || !event) return -1;
    SESSION_LOCK(s);

    uint8_t stack_buf[128];
    size_t len = 0;
    int rc = laban_session_send_key_encoded_locked(
        s, event, stack_buf, sizeof(stack_buf), &len);

    if (rc == LABAN_KEY_ENCODE_OUT_OF_SPACE) {
        /* len now holds required size; heap-allocate and re-encode. */
        uint8_t *heap_buf = malloc(len);
        if (!heap_buf) return -1;
        size_t heap_len = 0;
        rc = laban_session_send_key_encoded_locked(s, event, heap_buf, len, &heap_len);
        free(heap_buf);
        return rc;
    }

    return rc;
}
