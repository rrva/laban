#include "LabanTerminalCore.h"
#include <ghostty/vt/terminal.h>

int laban_ghostty_vt_link_smoke(void) {
    GhosttyTerminalOptions opts = {.cols = 80, .rows = 24, .max_scrollback = 1000};
    GhosttyTerminal t = NULL;
    GhosttyResult r = ghostty_terminal_new(NULL, &t, opts);
    if (r != GHOSTTY_SUCCESS) return (int)r;
    ghostty_terminal_free(t);
    return 0;
}
