#include "LabanTerminalCore.h"
#include <ghostty/vt/terminal.h>

int laban_ghostty_vt_link_smoke(void) {
    GhosttyTerminal t = NULL;
    GhosttyResult r = ghostty_terminal_new(NULL, &t, 80, 24);
    if (r != GHOSTTY_SUCCESS) return (int)r;
    ghostty_terminal_free(t);
    return 0;
}
