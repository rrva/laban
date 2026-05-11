#include "session_internal.h"

static GhosttyMouseButton map_laban_button(LabanMouseButton btn) {
    switch (btn) {
        case LABAN_MOUSE_BUTTON_LEFT:      return GHOSTTY_MOUSE_BUTTON_LEFT;
        case LABAN_MOUSE_BUTTON_MIDDLE:    return GHOSTTY_MOUSE_BUTTON_MIDDLE;
        case LABAN_MOUSE_BUTTON_RIGHT:     return GHOSTTY_MOUSE_BUTTON_RIGHT;
        case LABAN_MOUSE_BUTTON_WHEEL_UP:  return GHOSTTY_MOUSE_BUTTON_FOUR;
        case LABAN_MOUSE_BUTTON_WHEEL_DOWN: return GHOSTTY_MOUSE_BUTTON_FIVE;
        default:                            return GHOSTTY_MOUSE_BUTTON_UNKNOWN;
    }
}

static int laban_mouse_button_can_be_held(LabanMouseButton btn) {
    return btn == LABAN_MOUSE_BUTTON_LEFT ||
           btn == LABAN_MOUSE_BUTTON_MIDDLE ||
           btn == LABAN_MOUSE_BUTTON_RIGHT;
}

static int laban_session_encode_mouse_internal(
    LabanSession *s,
    const LabanMouseEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len,
    int *out_next_button_pressed,
    LabanMouseButton *out_next_pressed_button
) {
    if (out_len) *out_len = 0;
    if (!s || !event || !out_len) return -1;
    if (!out_bytes && out_capacity > 0) return -1;

    /* Sync encoder options from terminal state. */
    ghostty_mouse_encoder_setopt_from_terminal(s->mouse_encoder, s->terminal);

    /* Set geometry from event. */
    GhosttyMouseEncoderSize enc_size = {
        .size = sizeof(GhosttyMouseEncoderSize),
        .screen_width = (uint32_t)(event->screen_width > 0 ? event->screen_width : 800),
        .screen_height = (uint32_t)(event->screen_height > 0 ? event->screen_height : 600),
        .cell_width = (uint32_t)(event->cell_width > 0 ? event->cell_width : 8),
        .cell_height = (uint32_t)(event->cell_height > 0 ? event->cell_height : 16),
        .padding_top = 0,
        .padding_bottom = 0,
        .padding_right = 0,
        .padding_left = 0,
    };
    ghostty_mouse_encoder_setopt(s->mouse_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &enc_size);

    int next_button_pressed = s->mouse_button_pressed;
    LabanMouseButton next_pressed_button = s->mouse_pressed_button;

    LabanMouseButton effective_button = event->button;
    if ((event->action == LABAN_MOUSE_ACTION_MOTION ||
         event->action == LABAN_MOUSE_ACTION_RELEASE) &&
        effective_button == LABAN_MOUSE_BUTTON_NONE &&
        laban_mouse_button_can_be_held(next_pressed_button)) {
        effective_button = next_pressed_button;
    }

    if (event->action == LABAN_MOUSE_ACTION_PRESS &&
        laban_mouse_button_can_be_held(event->button)) {
        next_button_pressed = 1;
        next_pressed_button = event->button;
    } else if (event->action == LABAN_MOUSE_ACTION_RELEASE &&
               laban_mouse_button_can_be_held(effective_button)) {
        next_button_pressed = 0;
        next_pressed_button = LABAN_MOUSE_BUTTON_NONE;
    }

    /* Set any-button-pressed state. */
    bool pressed = (next_button_pressed != 0);
    ghostty_mouse_encoder_setopt(s->mouse_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);

    /* Create a Ghostty mouse event. */
    GhosttyMouseEvent gev = NULL;
    if (ghostty_mouse_event_new(NULL, &gev) != GHOSTTY_SUCCESS) return -1;

    /* Action. */
    GhosttyMouseAction ga = GHOSTTY_MOUSE_ACTION_PRESS;
    switch (event->action) {
        case LABAN_MOUSE_ACTION_RELEASE: ga = GHOSTTY_MOUSE_ACTION_RELEASE; break;
        case LABAN_MOUSE_ACTION_MOTION:  ga = GHOSTTY_MOUSE_ACTION_MOTION; break;
        default: break;
    }
    ghostty_mouse_event_set_action(gev, ga);

    /* Button. */
    GhosttyMouseButton gb = map_laban_button(effective_button);
    if (gb == GHOSTTY_MOUSE_BUTTON_UNKNOWN) {
        ghostty_mouse_event_clear_button(gev);
    } else {
        ghostty_mouse_event_set_button(gev, gb);
    }

    /* Modifiers. */
    GhosttyMods mods = (GhosttyMods)(event->modifiers & 0xFFFF);
    ghostty_mouse_event_set_mods(gev, mods);

    /* Position. */
    GhosttyMousePosition pos = { .x = event->x, .y = event->y };
    ghostty_mouse_event_set_position(gev, pos);

    /* Encode. */
    char *buf = (char *)out_bytes;
    GhosttyResult r = ghostty_mouse_encoder_encode(
        s->mouse_encoder, gev, buf, out_capacity, out_len);

    ghostty_mouse_event_free(gev);

    if (r == GHOSTTY_SUCCESS) {
        if (out_next_button_pressed) *out_next_button_pressed = next_button_pressed;
        if (out_next_pressed_button) *out_next_pressed_button = next_pressed_button;
    }

    return (r == GHOSTTY_SUCCESS) ? 0 : -1;
}

int laban_session_encode_mouse(
    LabanSession *s,
    const LabanMouseEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (!s) return -1;
    SESSION_LOCK(s);
    return laban_session_encode_mouse_internal(
        s, event, out_bytes, out_capacity, out_len, NULL, NULL);
}

int laban_session_send_mouse(LabanSession *s, const LabanMouseEvent *event) {
    if (!s) return -1;
    SESSION_LOCK(s);
    if (!s->fixture_mode && s->pty_fd < 0) return -1;

    uint8_t buf[128];
    size_t len = 0;
    int next_button_pressed = 0;
    LabanMouseButton next_pressed_button = LABAN_MOUSE_BUTTON_NONE;
    int r = laban_session_encode_mouse_internal(
        s,
        event,
        buf,
        sizeof(buf),
        &len,
        &next_button_pressed,
        &next_pressed_button);
    if (r != 0) return r;
    if (len > 0 && !s->fixture_mode) {
        r = laban_write_pty_input(s, buf, len);
        if (r != 0) return r;
    }

    s->mouse_button_pressed = next_button_pressed;
    s->mouse_pressed_button = next_pressed_button;
    return 0;
}

int laban_session_send_mouse_encoded(
    LabanSession *s,
    const LabanMouseEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
) {
    if (out_len) *out_len = 0;
    if (!s || !event || !out_len) return -1;
    if (!out_bytes && out_capacity > 0) return -1;
    SESSION_LOCK(s);
    if (!s->fixture_mode && s->pty_fd < 0) return -1;

    uint8_t buf[128];
    size_t len = 0;
    int next_button_pressed = 0;
    LabanMouseButton next_pressed_button = LABAN_MOUSE_BUTTON_NONE;
    int r = laban_session_encode_mouse_internal(
        s,
        event,
        buf,
        sizeof(buf),
        &len,
        &next_button_pressed,
        &next_pressed_button);
    if (r != 0) return r;

    if (len > out_capacity) {
        *out_len = len;
        return 1;
    }

    if (len > 0 && !s->fixture_mode) {
        r = laban_write_pty_input(s, buf, len);
        if (r != 0) return r;
    }

    if (len > 0 && out_bytes) memcpy(out_bytes, buf, len);
    *out_len = len;

    s->mouse_button_pressed = next_button_pressed;
    s->mouse_pressed_button = next_pressed_button;
    return 0;
}

