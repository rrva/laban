#include "session_internal.h"

extern char **environ;

static bool env_entry_has_name(const char *entry, const char *name) {
    if (!entry || !name) return false;
    const char *eq = strchr(entry, '=');
    if (!eq) return false;
    size_t len = (size_t)(eq - entry);
    return strlen(name) == len && strncmp(entry, name, len) == 0;
}

static bool envp_has_name(const char *const *envp, const char *name) {
    if (!envp) return false;
    for (int i = 0; envp[i]; i++) {
        if (env_entry_has_name(envp[i], name)) return true;
    }
    return false;
}

static bool envp_overrides_entry(const char *const *envp, const char *entry) {
    if (!envp || !entry) return false;
    const char *eq = strchr(entry, '=');
    if (!eq) return false;
    size_t len = (size_t)(eq - entry);
    for (int i = 0; envp[i]; i++) {
        const char *override_eq = strchr(envp[i], '=');
        if (!override_eq) continue;
        size_t override_len = (size_t)(override_eq - envp[i]);
        if (override_len == len && strncmp(envp[i], entry, len) == 0) return true;
    }
    return false;
}

static char **build_spawn_env(const char *const *overrides) {
    size_t inherited_count = 0;
    while (environ && environ[inherited_count]) inherited_count++;

    size_t override_count = 0;
    while (overrides && overrides[override_count]) override_count++;

    char **env = calloc(inherited_count + override_count + 3, sizeof(char *));
    if (!env) return NULL;

    size_t out = 0;
    for (size_t i = 0; i < inherited_count; i++) {
        const char *entry = environ[i];
        if (env_entry_has_name(entry, "TERM")) continue;
        if (env_entry_has_name(entry, "COLORTERM")) continue;
        if (env_entry_has_name(entry, "NO_COLOR")) continue;
        if (envp_overrides_entry(overrides, entry)) continue;
        env[out++] = (char *)entry;
    }

    if (!envp_has_name(overrides, "TERM")) {
        env[out++] = (char *)"TERM=xterm-256color";
    }
    if (!envp_has_name(overrides, "COLORTERM")) {
        env[out++] = (char *)"COLORTERM=truecolor";
    }

    for (size_t i = 0; i < override_count; i++) {
        env[out++] = (char *)overrides[i];
    }
    env[out] = NULL;
    return env;
}

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static void init_sane_termios(struct termios *tio) {
    memset(tio, 0, sizeof(*tio));
    tio->c_iflag = BRKINT | ICRNL | IXON;
#ifdef IXANY
    tio->c_iflag |= IXANY;
#endif
#ifdef IMAXBEL
    tio->c_iflag |= IMAXBEL;
#endif
    tio->c_oflag = OPOST | ONLCR;
    tio->c_cflag = CREAD | CS8 | HUPCL;
    tio->c_lflag = ECHO | ECHOE | ECHOK | ICANON | ISIG | IEXTEN;
#ifdef ECHOCTL
    tio->c_lflag |= ECHOCTL;
#endif
#ifdef ECHOKE
    tio->c_lflag |= ECHOKE;
#endif
    for (int i = 0; i < NCCS; i++) tio->c_cc[i] = _POSIX_VDISABLE;
    tio->c_cc[VEOF] = 4;      /* ^D */
    tio->c_cc[VEOL] = _POSIX_VDISABLE;
#ifdef VEOL2
    tio->c_cc[VEOL2] = _POSIX_VDISABLE;
#endif
    tio->c_cc[VERASE] = 0x7f; /* DEL */
    tio->c_cc[VINTR] = 3;     /* ^C */
    tio->c_cc[VKILL] = 21;    /* ^U */
    tio->c_cc[VQUIT] = 28;    /* ^\ */
    tio->c_cc[VSTART] = 17;   /* ^Q */
    tio->c_cc[VSTOP] = 19;    /* ^S */
    tio->c_cc[VSUSP] = 26;    /* ^Z */
#ifdef VDSUSP
    tio->c_cc[VDSUSP] = 25;   /* ^Y */
#endif
#ifdef VREPRINT
    tio->c_cc[VREPRINT] = 18; /* ^R */
#endif
#ifdef VWERASE
    tio->c_cc[VWERASE] = 23;  /* ^W */
#endif
#ifdef VLNEXT
    tio->c_cc[VLNEXT] = 22;   /* ^V */
#endif
#ifdef VDISCARD
    tio->c_cc[VDISCARD] = 15; /* ^O */
#endif
#ifdef VSTATUS
    tio->c_cc[VSTATUS] = 20;  /* ^T */
#endif
    tio->c_cc[VMIN] = 1;
    tio->c_cc[VTIME] = 0;
}

static void free_ghostty_resources(LabanSession *s) {
    ghostty_render_state_row_cells_free(s->row_cells);
    ghostty_render_state_row_iterator_free(s->row_iter);
    ghostty_render_state_free(s->render_state);
    if (s->mouse_encoder) ghostty_mouse_encoder_free(s->mouse_encoder);
    if (s->key_encoder) ghostty_key_encoder_free(s->key_encoder);
    if (s->key_event) ghostty_key_event_free(s->key_event);
    ghostty_terminal_free(s->terminal);
    free(s->response_buf);
    s->response_buf = NULL;
    s->response_len = 0;
    s->response_cap = 0;
}

int laban_session_create(
    const LabanLaunchConfig *config,
    LabanTerminalSize initial_size,
    LabanSession **out_session
) {
    if (out_session) *out_session = NULL;
    if (!config || !out_session) return -1;

    uint16_t cols = (uint16_t)(initial_size.cols > 0 ? initial_size.cols : 80);
    uint16_t rows = (uint16_t)(initial_size.rows > 0 ? initial_size.rows : 24);

    /* PTY mode: resolve and pre-flight the executable before allocating anything. */
    const char *exe = NULL;
    if (!config->fixture_mode) {
        if (config->executable && config->executable[0])
            exe = config->executable;
        else
            exe = getenv("SHELL");
        if (!exe || !exe[0]) {
            struct passwd *pw = getpwuid(getuid());
            if (pw && pw->pw_shell && pw->pw_shell[0]) exe = pw->pw_shell;
        }
        if (!exe || !exe[0]) exe = "/bin/sh";
        if (access(exe, X_OK) != 0) return -1;
    }

    LabanSession *s = calloc(1, sizeof(struct LabanSession));
    if (!s) return -1;
    {
        pthread_mutexattr_t attr;
        if (pthread_mutexattr_init(&attr) != 0) { free(s); return -1; }
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        int mr = pthread_mutex_init(&s->lock, &attr);
        pthread_mutexattr_destroy(&attr);
        if (mr != 0) { free(s); return -1; }
    }
    s->pty_fd = -1;
    s->child_pid = -1;
    s->launch_cwd[0] = '\0';
    s->capture_fd = -1;
    s->capture_callback = NULL;
    s->capture_userdata = NULL;
    s->fixture_mode = config->fixture_mode;
    s->suppress_pty_output_until_input = 0;
    s->color_scheme = LABAN_COLOR_SCHEME_DARK;

    GhosttyTerminalOptions opts = { .cols = cols, .rows = rows, .max_scrollback = 10000000 };

    GhosttyResult r = ghostty_terminal_new(NULL, &s->terminal, opts);
    if (r != GHOSTTY_SUCCESS) { free(s); return -1; }

    /* Cache geometry for the SIZE effect; also picks up cell pixel sizes
       if the caller supplied them at create time (otherwise updated on
       the first laban_session_resize). */
    s->cols        = cols;
    s->rows        = rows;
    s->cell_width  = (uint32_t)(initial_size.cell_width  > 0 ? initial_size.cell_width  : 0);
    s->cell_height = (uint32_t)(initial_size.cell_height > 0 ? initial_size.cell_height : 0);

    /* Register effects so capability probes (DA1/DA2/DSR/XTWINOPS/XTVERSION)
       reach the child process — without these, tmux and vim hang on startup. */
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, (const void *)s);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                         (const void *)laban_effect_write_pty);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_SIZE,
                         (const void *)laban_effect_size);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
                         (const void *)laban_effect_device_attributes);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_XTVERSION,
                         (const void *)laban_effect_xtversion);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_ENQUIRY,
                         (const void *)laban_effect_enquiry);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME,
                         (const void *)laban_effect_color_scheme);
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                         (const void *)laban_title_changed_cb);

    r = ghostty_render_state_new(NULL, &s->render_state);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    r = ghostty_render_state_row_iterator_new(NULL, &s->row_iter);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_render_state_free(s->render_state);
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    r = ghostty_render_state_row_cells_new(NULL, &s->row_cells);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_render_state_row_iterator_free(s->row_iter);
        ghostty_render_state_free(s->render_state);
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    /* Create persistent mouse encoder. */
    r = ghostty_mouse_encoder_new(NULL, &s->mouse_encoder);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_render_state_row_cells_free(s->row_cells);
        ghostty_render_state_row_iterator_free(s->row_iter);
        ghostty_render_state_free(s->render_state);
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    /* Create persistent key encoder and reusable key event. */
    r = ghostty_key_encoder_new(NULL, &s->key_encoder);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_render_state_row_cells_free(s->row_cells);
        ghostty_render_state_row_iterator_free(s->row_iter);
        ghostty_render_state_free(s->render_state);
        ghostty_mouse_encoder_free(s->mouse_encoder);
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    r = ghostty_key_event_new(NULL, &s->key_event);
    if (r != GHOSTTY_SUCCESS) {
        ghostty_render_state_row_cells_free(s->row_cells);
        ghostty_render_state_row_iterator_free(s->row_iter);
        ghostty_render_state_free(s->render_state);
        ghostty_mouse_encoder_free(s->mouse_encoder);
        ghostty_key_encoder_free(s->key_encoder);
        ghostty_terminal_free(s->terminal);
        free(s);
        return -1;
    }

    if (config->fixture_mode) {
        *out_session = s;
        return 0;
    }

    const char *launch_cwd = NULL;
    if (config->cwd && config->cwd[0]) {
        launch_cwd = config->cwd;
    } else {
        launch_cwd = getenv("HOME");
        if (!launch_cwd || !launch_cwd[0]) {
            struct passwd *pw = getpwuid(getuid());
            if (pw && pw->pw_dir) launch_cwd = pw->pw_dir;
        }
    }
    if (launch_cwd && launch_cwd[0]) {
        snprintf(s->launch_cwd, sizeof(s->launch_cwd), "%s", launch_cwd);
    }

    if (config->defer_spawn) {
        /* Defer fork+exec until laban_session_start_spawn fires. The
         * VT parser is fully constructed and can absorb replayed bytes
         * (transcript restore feeds via laban_session_replay_pty_output).
         * Pixel geometry is preserved so the openpty winsize matches
         * what the renderer will report. */
        s->pending_spawn = 1;
        s->pending_pixel_width  = initial_size.pixel_width;
        s->pending_pixel_height = initial_size.pixel_height;
        *out_session = s;
        return 0;
    }

    /* Non-deferred path: honor the caller's executable / argv / envp
     * (tests rely on this — they pass /bin/sh -c "exit 7" or
     * /bin/sleep). The deferred path goes through
     * laban_session_spawn_now_ which uses $SHELL discovery instead. */
    char login_arg[256];
    char *default_argv[] = { login_arg, NULL };
    char *const *spawn_argv = NULL;
    if (config->argv) {
        spawn_argv = (char *const *)config->argv;
    } else {
        const char *base = strrchr(exe, '/');
        base = base ? base + 1 : exe;
        snprintf(login_arg, sizeof(login_arg), "-%s", base);
        spawn_argv = default_argv;
    }

    char **spawn_env = build_spawn_env(config->envp);
    if (!spawn_env) {
        free_ghostty_resources(s);
        free(s);
        return -1;
    }

    struct winsize ws = {
        .ws_row    = (unsigned short)rows,
        .ws_col    = (unsigned short)cols,
        .ws_xpixel = (unsigned short)initial_size.pixel_width,
        .ws_ypixel = (unsigned short)initial_size.pixel_height,
    };

    struct termios term;
    init_sane_termios(&term);

    int pty_fd = -1;
    int slave_fd = -1;
    if (openpty(&pty_fd, &slave_fd, NULL, &term, &ws) < 0) {
        free(spawn_env);
        free_ghostty_resources(s);
        free(s);
        return -1;
    }

    if (set_cloexec(pty_fd) < 0 || set_cloexec(slave_fd) < 0) {
        close(slave_fd);
        close(pty_fd);
        free(spawn_env);
        free_ghostty_resources(s);
        free(s);
        return -1;
    }

    pid_t child = fork();
    if (child < 0) {
        close(slave_fd);
        close(pty_fd);
        free(spawn_env);
        free_ghostty_resources(s);
        free(s);
        return -1;
    }
    if (child == 0) {
        struct sigaction sa = {0};
        sa.sa_handler = SIG_DFL;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGPIPE, &sa, NULL);
        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGQUIT, &sa, NULL);
        sigaction(SIGTSTP, &sa, NULL);
        close(pty_fd);
        if (setsid() < 0) _exit(127);
        if (ioctl(slave_fd, TIOCSCTTY, 0) < 0) _exit(127);
        if (dup2(slave_fd, STDIN_FILENO) < 0) _exit(127);
        if (dup2(slave_fd, STDOUT_FILENO) < 0) _exit(127);
        if (dup2(slave_fd, STDERR_FILENO) < 0) _exit(127);
        if (slave_fd > STDERR_FILENO) close(slave_fd);
        if (launch_cwd && launch_cwd[0] && chdir(launch_cwd) != 0) {
            _exit(127);
        }
        execve(exe, spawn_argv, spawn_env);
        _exit(127);
    }
    close(slave_fd);
    free(spawn_env);

    int flags = fcntl(pty_fd, F_GETFL, 0);
    if (flags >= 0) fcntl(pty_fd, F_SETFL, flags | O_NONBLOCK);

    s->pty_fd = pty_fd;
    s->child_pid = child;

    *out_session = s;
    return 0;
}

/* Performs the openpty + fork + exec for a session whose libghostty
 * parser was already constructed by laban_session_create. Used both
 * by create (non-deferred case) and by laban_session_start_spawn
 * (deferred case). On success leaves s->pty_fd / s->child_pid set.
 * On failure returns -1; the caller decides whether to tear down the
 * session.
 *
 * `override_cwd` is consulted only in deferred mode — when NULL, the
 * launch_cwd captured at create time is used. The non-deferred create
 * path passes NULL because launch_cwd was already populated above. */
int laban_session_spawn_now_(LabanSession *s, const char *override_cwd) {
    if (!s) return -1;
    if (s->fixture_mode) return -1;
    if (s->pty_fd >= 0) return 0;  /* already spawned */

    const char *exe = getenv("SHELL");
    if (!exe || !exe[0]) {
        struct passwd *pw = getpwuid(getuid());
        if (pw && pw->pw_shell && pw->pw_shell[0]) exe = pw->pw_shell;
    }
    if (!exe || !exe[0]) exe = "/bin/sh";
    if (access(exe, X_OK) != 0) return -1;

    /* If the caller is replaying a deferred spawn with a new cwd, prefer
     * that over the cwd captured at create time. */
    const char *launch_cwd = NULL;
    if (override_cwd && override_cwd[0]) {
        launch_cwd = override_cwd;
        snprintf(s->launch_cwd, sizeof(s->launch_cwd), "%s", launch_cwd);
    } else if (s->launch_cwd[0]) {
        launch_cwd = s->launch_cwd;
    }

    char login_arg[256];
    char *default_argv[] = { login_arg, NULL };
    const char *base = strrchr(exe, '/');
    base = base ? base + 1 : exe;
    snprintf(login_arg, sizeof(login_arg), "-%s", base);
    char *const *spawn_argv = default_argv;

    char **spawn_env = build_spawn_env(NULL);
    if (!spawn_env) return -1;

    struct winsize ws = {
        .ws_row    = (unsigned short)s->rows,
        .ws_col    = (unsigned short)s->cols,
        .ws_xpixel = (unsigned short)(s->pending_pixel_width > 0
            ? s->pending_pixel_width : 0),
        .ws_ypixel = (unsigned short)(s->pending_pixel_height > 0
            ? s->pending_pixel_height : 0),
    };

    struct termios term;
    init_sane_termios(&term);

    int pty_fd = -1;
    int slave_fd = -1;
    if (openpty(&pty_fd, &slave_fd, NULL, &term, &ws) < 0) {
        free(spawn_env);
        return -1;
    }

    if (set_cloexec(pty_fd) < 0 || set_cloexec(slave_fd) < 0) {
        close(slave_fd);
        close(pty_fd);
        free(spawn_env);
        return -1;
    }

    pid_t child = fork();
    if (child < 0) {
        close(slave_fd);
        close(pty_fd);
        free(spawn_env);
        return -1;
    }
    if (child == 0) {
        struct sigaction sa = {0};
        sa.sa_handler = SIG_DFL;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGPIPE, &sa, NULL);
        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGQUIT, &sa, NULL);
        sigaction(SIGTSTP, &sa, NULL);
        close(pty_fd);
        if (setsid() < 0) _exit(127);
        if (ioctl(slave_fd, TIOCSCTTY, 0) < 0) _exit(127);
        if (dup2(slave_fd, STDIN_FILENO) < 0) _exit(127);
        if (dup2(slave_fd, STDOUT_FILENO) < 0) _exit(127);
        if (dup2(slave_fd, STDERR_FILENO) < 0) _exit(127);
        if (slave_fd > STDERR_FILENO) close(slave_fd);
        if (launch_cwd && launch_cwd[0] && chdir(launch_cwd) != 0) {
            _exit(127);
        }
        execve(exe, spawn_argv, spawn_env);
        _exit(127);
    }
    close(slave_fd);
    free(spawn_env);

    int flags = fcntl(pty_fd, F_GETFL, 0);
    if (flags >= 0) fcntl(pty_fd, F_SETFL, flags | O_NONBLOCK);

    s->pty_fd = pty_fd;
    s->child_pid = child;
    s->pending_spawn = 0;
    return 0;
}

int laban_session_start_spawn(LabanSession *s, const char *override_cwd) {
    if (!s) return -1;
    SESSION_LOCK(s);
    if (!s->pending_spawn) return -1;  /* already spawned or not deferred */
    return laban_session_spawn_now_(s, override_cwd);
}

int laban_session_suppress_pty_output_until_input(LabanSession *s, int enabled) {
    if (!s) return -1;
    SESSION_LOCK(s);
    s->suppress_pty_output_until_input = enabled ? 1 : 0;
    return 0;
}

void laban_session_destroy(LabanSession *s) {
    if (!s) return;

    /* Flush and close the capture file before tearing down the rest. */
    if (s->capture_fd >= 0) {
        close(s->capture_fd);
        s->capture_fd = -1;
    }

    /* Close PTY first — sends SIGHUP to the child's session. */
    if (s->pty_fd >= 0) {
        close(s->pty_fd);
        s->pty_fd = -1;
    }

    /* Reap the child without blocking indefinitely. */
    if (s->child_pid > 0 && s->status == 0) {
        int ws = 0;
        int reaped = (laban_waitpid_retry(s->child_pid, &ws, WNOHANG) == s->child_pid);
        if (!reaped) {
            laban_signal_child_process_group(s->child_pid, SIGTERM);
            for (int i = 0; i < 5 && !reaped; i++) {
                struct timespec ts = { .tv_sec = 0, .tv_nsec = 10000000 }; /* 10 ms */
                nanosleep(&ts, NULL);
                reaped = (laban_waitpid_retry(s->child_pid, &ws, WNOHANG) == s->child_pid);
            }
            if (!reaped) {
                laban_signal_child_process_group(s->child_pid, SIGKILL);
                laban_waitpid_retry(s->child_pid, &ws, 0);
            }
        }
    }

    free_ghostty_resources(s);
    pthread_mutex_destroy(&s->lock);
    free(s);
}

int laban_session_resize(LabanSession *s, LabanTerminalSize size) {
    if (!s) return -1;
    SESSION_LOCK(s);
    uint16_t cols = (uint16_t)size.cols;
    uint16_t rows = (uint16_t)size.rows;
    /* libghostty rejects empty grids; keep the visible size in Laban and
     * apply the next non-empty resize to the terminal core. */
    if (cols > 0 && rows > 0) {
        GhosttyResult r = ghostty_terminal_resize(
            s->terminal, cols, rows,
            (uint32_t)size.cell_width, (uint32_t)size.cell_height);
        if (r != GHOSTTY_SUCCESS) return -1;
    }
    s->cols        = cols;
    s->rows        = rows;
    s->cell_width  = (uint32_t)size.cell_width;
    s->cell_height = (uint32_t)size.cell_height;
    if (s->pty_fd >= 0 && cols > 0 && rows > 0) {
        struct winsize ws = {
            .ws_row    = (unsigned short)rows,
            .ws_col    = (unsigned short)cols,
            .ws_xpixel = (unsigned short)size.pixel_width,
            .ws_ypixel = (unsigned short)size.pixel_height,
        };
        ioctl(s->pty_fd, TIOCSWINSZ, &ws);
    }
    return 0;
}

int laban_session_feed_output(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s) return -1;
    if (len == 0) return 0;
    if (!bytes) return -1;
    SESSION_LOCK(s);
    laban_vt_write_capture(s, bytes, len);
    return 0;
}

int laban_session_write(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s) return -1;
    if (len == 0) return 0;
    if (!bytes) return -1;
    SESSION_LOCK(s);
    if (s->fixture_mode) {
        /* Fixture mode: feed bytes directly into the VT parser — no PTY involved. */
        laban_vt_write_capture(s, bytes, len);
        return 0;
    }
    if (s->pty_fd < 0) return -1;
    return laban_write_pty_input(s, bytes, len);
}

int laban_session_replay_pty_output(LabanSession *s, const uint8_t *bytes, size_t len) {
    if (!s) return -1;
    if (len == 0) return 0;
    if (!bytes) return -1;
    SESSION_LOCK(s);
    ghostty_terminal_vt_write(s->terminal, bytes, len);
    return 0;
}

LabanExitState laban_session_exit_state(LabanSession *session) {
    LabanExitState r = { 0, 0 };
    if (!session) return r;
    SESSION_LOCK(session);
    r.status      = session->status;
    r.exit_status = session->exit_status;
    return r;
}
