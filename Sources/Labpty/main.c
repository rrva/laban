#include "labpty_registry.h"

#include <poll.h>

#define LABPTY_MAX_POLL_WATCHES (1 + LABPTY_MAX_CLIENTS + LABPTY_MAX_SESSIONS)

typedef enum {
    LABPTY_POLL_LISTENER = 1,
    LABPTY_POLL_CLIENT = 2,
    LABPTY_POLL_SESSION = 3,
} labpty_poll_kind_t;

typedef struct {
    int fd;
    int in_use;
    int header_parsed;
    /* Set once the client has completed at least one request/response
     * round-trip. Distinguishes legitimate long-lived clients (which may
     * sit fully idle while reading byte-ring output directly) from
     * never-said-hello slowloris attackers. */
    int established;
    int negotiated;
    size_t read_have;
    labpty_frame_header_t header;
    uint8_t read_buf[LABPTY_MAX_FRAME];
    size_t write_total;
    size_t write_sent;
    uint8_t write_buf[LABPTY_MAX_FRAME];
    uint64_t deadline_ns;
} labpty_client_t;

typedef struct {
    int listen_fd;
    labpty_client_t clients[LABPTY_MAX_CLIENTS];
    labpty_registry_t registry;
    labpty_open_request_t open_request;
    labpty_hello_request_t hello_request;
    uint8_t read_buffer[LABPTY_READ_BUFFER_BYTES];
} labpty_daemon_t;

typedef struct {
    struct pollfd fds[LABPTY_MAX_POLL_WATCHES];
    labpty_poll_kind_t kinds[LABPTY_MAX_POLL_WATCHES];
    int indexes[LABPTY_MAX_POLL_WATCHES];
    nfds_t count;
} labpty_poll_set_t;

static const uint64_t LABPTY_IO_IDLE_TIMEOUT_NS = 250000000ull;
static volatile sig_atomic_t shutdown_requested = 0;

static void usage(void) {
    fputs("usage: labpty --socket PATH --shm-dir PATH\n", stderr);
}

static uint64_t monotonic_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ((uint64_t)ts.tv_sec * 1000000000ull) + (uint64_t)ts.tv_nsec;
}

static void request_shutdown(int signo) {
    (void)signo;
    shutdown_requested = 1;
}

static int install_signal_handlers(void) {
    struct sigaction ignore = {0};
    ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    if (sigaction(SIGPIPE, &ignore, NULL) != 0) return -1;

    struct sigaction shutdown = {0};
    shutdown.sa_handler = request_shutdown;
    sigemptyset(&shutdown.sa_mask);
    if (sigaction(SIGTERM, &shutdown, NULL) != 0) return -1;
    if (sigaction(SIGINT, &shutdown, NULL) != 0) return -1;
    return 0;
}

static int parse_args(int argc, char **argv, char *socket_path, char *shm_dir) {
    assert(argc >= 1);
    assert(argv != NULL);
    socket_path[0] = '\0';
    shm_dir[0] = '\0';
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            snprintf(socket_path, LABPTY_PATH_BYTES, "%s", argv[++i]);
        } else if (strcmp(argv[i], "--shm-dir") == 0 && i + 1 < argc) {
            snprintf(shm_dir, LABPTY_PATH_BYTES, "%s", argv[++i]);
        } else {
            return -1;
        }
    }
    return socket_path[0] && shm_dir[0] ? 0 : -1;
}

static int set_nonblock(int fd) {
    assert(fd >= 0);
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int set_cloexec(int fd) {
    assert(fd >= 0);
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

/* Encodes the SocketIsLive predicate in specs/labpty/LabptyStartup.tla:
 * "the entry at the path resolves to a live, bound listening daemon". */
static int socket_path_is_stale(const char *path, int *out_stale) {
    assert(path != NULL);
    assert(out_stale != NULL);
    *out_stale = 0;

    struct stat st;
    if (lstat(path, &st) != 0) {
        if (errno == ENOENT) {
            *out_stale = 1;
            return 0;
        }
        return -1;
    }
    if (!S_ISSOCK(st.st_mode)) {
        errno = EEXIST;
        return -1;
    }

    int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe < 0) return -1;
    if (set_cloexec(probe) != 0) {
        close(probe);
        return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        close(probe);
        errno = ENAMETOOLONG;
        return -1;
    }
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    int connected = connect(probe, (struct sockaddr *)&addr, sizeof(addr));
    int saved_errno = connected == 0 ? 0 : errno;
    close(probe);
    if (connected == 0) {
        errno = EADDRINUSE;
        return 0;
    }
    if (saved_errno == ECONNREFUSED || saved_errno == ENOENT) {
        *out_stale = 1;
        return 0;
    }
    errno = saved_errno;
    return -1;
}

static int bind_unix_socket_private(int fd, const struct sockaddr_un *addr) {
    assert(fd >= 0);
    assert(addr != NULL);
    mode_t old_umask = umask(0077);
    int status = bind(fd, (const struct sockaddr *)addr, sizeof(*addr));
    int saved_errno = status == 0 ? 0 : errno;
    umask(old_umask);
    if (status != 0) errno = saved_errno;
    return status;
}

/* Modelled by specs/labpty/LabptyStartup.tla::Listen_Fixed. The
 * probe → bind → stale-unlink retry sequence is the b5e7819 fix; the
 * companion MC_StartupPreFix.cfg with UnconditionalUnlink=TRUE pins the
 * stranded-daemon counter-example without it. */
static int listen_unix_socket(const char *path) {
    assert(path != NULL);
    assert(path[0] != '\0');
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (set_cloexec(fd) != 0) {
        close(fd);
        return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        close(fd);
        return -1;
    }
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    int bind_status = bind_unix_socket_private(fd, &addr);
    if (bind_status != 0) {
        if (errno != EADDRINUSE) {
            int saved_errno = errno;
            close(fd);
            errno = saved_errno;
            return -1;
        }
        int stale = 0;
        int stale_status = socket_path_is_stale(path, &stale);
        if (stale_status != 0 || !stale) {
            int saved_errno = stale_status != 0 ? errno : EADDRINUSE;
            close(fd);
            errno = saved_errno;
            return -1;
        }
        if (unlink(path) != 0 && errno != ENOENT) {
            int saved_errno = errno;
            close(fd);
            errno = saved_errno;
            return -1;
        }
        bind_status = bind_unix_socket_private(fd, &addr);
    }
    if (bind_status != 0) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
        return -1;
    }
    /* `chmod(path, ...)` not `fchmod(fd, ...)`: on Darwin fchmod on an
     * AF_UNIX socket fd returns EINVAL — the socket fd has no vnode of
     * its own, only the path does. This leaves a tiny (<1ms) window
     * after bind where the socket file is mode 0700 (from `umask(0077)`
     * around bind) before we narrow it to 0600. Same-uid only; AF_UNIX
     * connect already requires write permission, and 0700 grants that
     * to the same uid only. Informational, not exploitable. */
    if (chmod(path, 0600) != 0) {
        close(fd);
        unlink(path);
        return -1;
    }
    if (listen(fd, 16) != 0) {
        close(fd);
        unlink(path);
        return -1;
    }
    return fd;
}

static int configure_client_fd(int fd) {
    assert(fd >= 0);
    if (set_cloexec(fd) != 0) return -1;
#ifdef SO_NOSIGPIPE
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    return set_nonblock(fd);
}

static void client_release(labpty_client_t *client) {
    assert(client != NULL);
    if (client->fd >= 0) close(client->fd);
    memset(client, 0, sizeof(*client));
    client->fd = -1;
}

static void client_reset_after_response(labpty_client_t *client) {
    assert(client != NULL);
    client->read_have = 0;
    client->header_parsed = 0;
    client->write_total = 0;
    client->write_sent = 0;
    client->deadline_ns = monotonic_ns() + LABPTY_IO_IDLE_TIMEOUT_NS;
}

/* Modelled by specs/labpty/LabptyControlChannel.tla::Accept. */
static void add_client(labpty_daemon_t *daemon) {
    assert(daemon != NULL);
    assert(daemon->listen_fd >= 0);
    int fd = accept(daemon->listen_fd, NULL, NULL);
    if (fd < 0) return;
    if (configure_client_fd(fd) != 0) {
        close(fd);
        return;
    }
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        labpty_client_t *client = &daemon->clients[i];
        if (!client->in_use) {
            memset(client, 0, sizeof(*client));
            client->fd = fd;
            client->in_use = 1;
            client->deadline_ns = monotonic_ns() + LABPTY_IO_IDLE_TIMEOUT_NS;
            return;
        }
    }
    /* All LABPTY_MAX_CLIENTS slots in use; the client sees connect() ok
     * followed by EOF on first read. This is routine under load (stress
     * runs see thousands per minute) so it is intentionally unlogged. */
    close(fd);
}

static size_t encode_descriptor_view_payload(const labpty_descriptor_view_t *descriptor, uint8_t *out, size_t cap) {
    assert(descriptor != NULL);
    assert(out != NULL);
    labpty_writer_t writer = { .cur = out, .end = out + cap };
    if (labpty_encode_descriptor(&writer, descriptor) != LABPTY_OK) return 0;
    return (size_t)(writer.cur - out);
}

static size_t encode_descriptor_payload(labpty_session_t *session, uint8_t *out, size_t cap) {
    assert(session != NULL);
    assert(out != NULL);
    labpty_descriptor_view_t descriptor = labpty_session_descriptor(session);
    return encode_descriptor_view_payload(&descriptor, out, cap);
}

static size_t encode_list_payload(labpty_registry_t *registry, uint8_t *out, size_t cap) {
    assert(registry != NULL);
    assert(out != NULL);
    labpty_writer_t writer = { .cur = out, .end = out + cap };
    uint8_t *count_ptr = writer.cur;
    if (labpty_write_u32(&writer, 0) != LABPTY_OK) return 0;
    uint32_t count = 0;
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &registry->sessions[i];
        if (!s->used) continue;
        labpty_descriptor_view_t descriptor = labpty_session_descriptor(s);
        if (labpty_encode_descriptor(&writer, &descriptor) != LABPTY_OK) return 0;
        count++;
    }
    labpty_writer_t count_writer = { .cur = count_ptr, .end = count_ptr + 4 };
    labpty_write_u32(&count_writer, count);
    return (size_t)(writer.cur - out);
}

static labpty_status_t handle_hello(labpty_daemon_t *daemon, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    labpty_status_t status = labpty_decode_hello_request(payload, len, &daemon->hello_request);
    if (status != LABPTY_OK) return status;
    status = labpty_negotiate_hello(&daemon->hello_request);
    if (status != LABPTY_OK) return status;
    return labpty_encode_hello_response(out, cap, out_len);
}

static labpty_status_t handle_open(labpty_daemon_t *daemon, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    assert(out_len != NULL);
    labpty_status_t status = labpty_decode_open_request(payload, len, &daemon->open_request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = NULL;
    status = labpty_registry_open(&daemon->registry, &daemon->open_request, &session);
    if (status != LABPTY_OK) return status;
    *out_len = encode_descriptor_payload(session, out, cap);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

static labpty_status_t handle_resize(labpty_daemon_t *daemon, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    labpty_resize_request_t request;
    labpty_status_t status = labpty_decode_resize_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    if (!session || !session->alive) return LABPTY_E_SESSION_NOT_FOUND;
    struct winsize ws = { .ws_row = (unsigned short)request.rows, .ws_col = (unsigned short)request.cols };
    if (ioctl(session->master_fd, TIOCSWINSZ, &ws) != 0) return LABPTY_E_INTERNAL;
    session->rows = request.rows;
    session->cols = request.cols;
    *out_len = encode_descriptor_payload(session, out, cap);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

static labpty_status_t handle_signal(labpty_daemon_t *daemon, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    labpty_signal_request_t request;
    labpty_status_t status = labpty_decode_signal_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    if (!session || !session->alive) return LABPTY_E_SESSION_NOT_FOUND;
    /* Try the child's process group first; if it has already been torn
     * down (ESRCH) or POSIX rejects the call because no member of the
     * group is eligible (EPERM), fall back to signalling the immediate
     * child by pid. Mirrors signal_child_process_group in
     * labpty_registry.c — no retry loop, because the millisecond-scale
     * race the prior loop papered over was inside the single-threaded
     * event loop and serialised every subsequent signal request. */
    if (killpg(session->child_pid, request.signo) != 0) {
        if ((errno != ESRCH && errno != EPERM)
                || kill(session->child_pid, request.signo) != 0) {
            return LABPTY_E_INTERNAL;
        }
    }
    *out_len = encode_descriptor_payload(session, out, cap);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

static labpty_status_t handle_terminate(labpty_daemon_t *daemon, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    labpty_handle_request_t request;
    labpty_status_t status = labpty_decode_handle_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    if (!session) return LABPTY_E_SESSION_NOT_FOUND;
    labpty_descriptor_view_t descriptor = labpty_session_descriptor(session);
    labpty_session_close(session);
    descriptor.alive = 0;
    *out_len = encode_descriptor_view_payload(&descriptor, out, cap);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

static const uint64_t LABPTY_WRITE_INPUT_BUDGET_NS = 100000000ull;  /* 100 ms */

static labpty_status_t handle_write(labpty_daemon_t *daemon, const uint8_t *payload, size_t len) {
    assert(daemon != NULL);
    labpty_write_input_request_t request;
    labpty_status_t status = labpty_decode_write_input_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    if (!session || !session->alive) return LABPTY_E_SESSION_NOT_FOUND;
    /* Wall-clock budget so a slow consumer downstream can't wedge the
     * single-threaded event loop while we drain accept/expire/reap.
     * Client sees LABPTY_E_INTERNAL and can retry. */
    uint64_t deadline = monotonic_ns() + LABPTY_WRITE_INPUT_BUDGET_NS;
    size_t sent = 0;
    while (sent < request.len) {
        ssize_t n = write(session->master_fd, request.bytes + sent, request.len - sent);
        if (n > 0) { sent += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (monotonic_ns() >= deadline) return LABPTY_E_INTERNAL;
            usleep(1000);
            continue;
        }
        return LABPTY_E_INTERNAL;
    }
    return LABPTY_OK;
}

static labpty_status_t dispatch_frame(labpty_daemon_t *daemon, labpty_client_t *client, size_t *out_len) {
    assert(daemon != NULL);
    assert(client != NULL);
    assert(out_len != NULL);
    const uint8_t *frame = client->read_buf;
    labpty_frame_header_t header = client->header;
    const uint8_t *payload = frame + LABPTY_FRAME_HEADER_BYTES;
    size_t len = (size_t)header.frame_len - LABPTY_FRAME_HEADER_BYTES;
    uint8_t *out = client->write_buf + LABPTY_FRAME_HEADER_BYTES;
    size_t cap = LABPTY_MAX_FRAME - LABPTY_FRAME_HEADER_BYTES;
    *out_len = 0;
    if (header.op == LABPTY_OP_HELLO) {
        labpty_status_t status = handle_hello(daemon, payload, len, out, cap, out_len);
        if (status == LABPTY_OK) client->negotiated = 1;
        return status;
    }
    if (!client->negotiated) return LABPTY_E_CAPABILITY_REQUIRED;
    if (header.op == LABPTY_OP_OPEN_SESSION) return handle_open(daemon, payload, len, out, cap, out_len);
    if (header.op == LABPTY_OP_LIST_SESSIONS) {
        *out_len = encode_list_payload(&daemon->registry, out, cap);
        return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
    }
    if (header.op == LABPTY_OP_RESIZE_SESSION) return handle_resize(daemon, payload, len, out, cap, out_len);
    if (header.op == LABPTY_OP_SIGNAL_SESSION) return handle_signal(daemon, payload, len, out, cap, out_len);
    if (header.op == LABPTY_OP_TERMINATE_SESSION) return handle_terminate(daemon, payload, len, out, cap, out_len);
    if (header.op == LABPTY_OP_WRITE_INPUT) return handle_write(daemon, payload, len);
    if (header.op == LABPTY_OP_PING) return labpty_encode_ping_response(out, cap, out_len);
    return LABPTY_E_UNKNOWN_OP;
}

static int stage_response(labpty_client_t *client, labpty_frame_header_t request, labpty_status_t code, size_t payload_len) {
    assert(client != NULL);
    if (payload_len > LABPTY_MAX_FRAME - LABPTY_FRAME_HEADER_BYTES) return -1;
    labpty_frame_header_t header = {
        .abi_major = 1,
        .abi_minor = 0,
        .frame_len = (uint32_t)(LABPTY_FRAME_HEADER_BYTES + payload_len),
        .op = LABPTY_OP_RESPONSE,
        .code = (uint16_t)code,
        .seq = request.seq,
    };
    if (labpty_encode_header(client->write_buf, LABPTY_FRAME_HEADER_BYTES, &header) != LABPTY_OK) return -1;
    client->write_total = LABPTY_FRAME_HEADER_BYTES + payload_len;
    client->write_sent = 0;
    return 0;
}

static int client_process_full_frame(labpty_daemon_t *daemon, labpty_client_t *client) {
    assert(daemon != NULL);
    assert(client != NULL);
    labpty_frame_header_t request_header = client->header;
    if (request_header.op == LABPTY_OP_RESPONSE) return -1;
    size_t response_len = 0;
    labpty_status_t status = dispatch_frame(daemon, client, &response_len);
    if (stage_response(client, request_header, status, response_len) != 0) return -1;
    client->read_have = 0;
    client->header_parsed = 0;
    return 0;
}

static int client_pump_read(labpty_daemon_t *daemon, labpty_client_t *client) {
    assert(daemon != NULL);
    assert(client != NULL);
    if (client->write_total > client->write_sent) return 0;
    size_t need = client->header_parsed ? client->header.frame_len : LABPTY_FRAME_HEADER_BYTES;
    while (client->read_have < need) {
        ssize_t n = read(client->fd, client->read_buf + client->read_have, need - client->read_have);
        if (n > 0) {
            client->read_have += (size_t)n;
            client->deadline_ns = monotonic_ns() + LABPTY_IO_IDLE_TIMEOUT_NS;
            if (!client->header_parsed && client->read_have >= LABPTY_FRAME_HEADER_BYTES) {
                if (labpty_decode_header(client->read_buf, LABPTY_FRAME_HEADER_BYTES, &client->header) != LABPTY_OK) return -1;
                if (client->header.frame_len < LABPTY_FRAME_HEADER_BYTES) return -1;
                if (client->header.frame_len > LABPTY_MAX_FRAME) return -1;
                client->header_parsed = 1;
                need = client->header.frame_len;
            }
            continue;
        }
        if (n == 0) return -1;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;
    }
    return client_process_full_frame(daemon, client);
}

/* Modelled by specs/labpty/LabptyControlChannel.tla::WriteComplete. The
 * `established = client->negotiated` line below is the 2aac41a fix; the
 * companion MC_ControlChannelPreFix.cfg with EstablishOnAnyRoundTrip=TRUE
 * pins the slowloris counter-example without it. */
static int client_pump_write(labpty_client_t *client) {
    assert(client != NULL);
    while (client->write_sent < client->write_total) {
        ssize_t n = write(client->fd, client->write_buf + client->write_sent, client->write_total - client->write_sent);
        if (n > 0) {
            client->write_sent += (size_t)n;
            client->deadline_ns = monotonic_ns() + LABPTY_IO_IDLE_TIMEOUT_NS;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        return -1;
    }
    client_reset_after_response(client);
    /* Only negotiated clients may sit idle while reading byte-ring output
     * directly. A rejected pre-hello client has completed a round-trip, but
     * it is still unauthenticated protocol noise and must not consume one of
     * the finite control slots forever. */
    client->established = client->negotiated;
    return 0;
}

static void drain_session(labpty_daemon_t *daemon, labpty_session_t *session) {
    assert(daemon != NULL);
    assert(session != NULL);
    assert(session->master_fd >= 0);
    ssize_t n = read(session->master_fd, daemon->read_buffer, sizeof(daemon->read_buffer));
    if (n > 0) {
        labpty_byte_ring_write(&session->ring, daemon->read_buffer, (size_t)n);
        return;
    }
    if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
        close(session->master_fd);
        session->master_fd = -1;
    }
}

static void add_poll_watch(labpty_poll_set_t *poll_set, int fd, short events, labpty_poll_kind_t kind, int index) {
    assert(poll_set != NULL);
    assert(fd >= 0);
    assert(poll_set->count < LABPTY_MAX_POLL_WATCHES);
    nfds_t slot = poll_set->count++;
    poll_set->fds[slot].fd = fd;
    poll_set->fds[slot].events = events;
    poll_set->fds[slot].revents = 0;
    poll_set->kinds[slot] = kind;
    poll_set->indexes[slot] = index;
}

static void build_poll_set(labpty_daemon_t *daemon, labpty_poll_set_t *poll_set) {
    assert(daemon != NULL);
    assert(poll_set != NULL);
    poll_set->count = 0;
    add_poll_watch(poll_set, daemon->listen_fd, POLLIN, LABPTY_POLL_LISTENER, -1);
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        labpty_client_t *client = &daemon->clients[i];
        if (!client->in_use) continue;
        short events = client->write_total > client->write_sent ? POLLOUT : POLLIN;
        add_poll_watch(poll_set, client->fd, events, LABPTY_POLL_CLIENT, i);
    }
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &daemon->registry.sessions[i];
        if (s->used && s->master_fd >= 0) {
            add_poll_watch(poll_set, s->master_fd, POLLIN, LABPTY_POLL_SESSION, i);
        }
    }
}

static int poll_revents_readable(short revents) {
    return (revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0;
}

static int poll_revents_faulted(short revents) {
    return (revents & (POLLHUP | POLLERR | POLLNVAL)) != 0;
}

static int service_client_poll(labpty_daemon_t *daemon, int index, short revents) {
    assert(daemon != NULL);
    assert(index >= 0);
    assert(index < LABPTY_MAX_CLIENTS);
    labpty_client_t *client = &daemon->clients[index];
    if (!client->in_use) return 0;
    int writing = client->write_total > client->write_sent;
    if (writing && (revents & POLLOUT)) {
        return client_pump_write(client);
    }
    if (!writing && poll_revents_readable(revents)) {
        return client_pump_read(daemon, client);
    }
    return poll_revents_faulted(revents) ? -1 : 0;
}

static void service_poll_watch(labpty_daemon_t *daemon, const labpty_poll_set_t *poll_set, nfds_t slot) {
    assert(daemon != NULL);
    assert(poll_set != NULL);
    assert(slot < poll_set->count);
    short revents = poll_set->fds[slot].revents;
    if (revents == 0) return;
    if (poll_set->kinds[slot] == LABPTY_POLL_LISTENER) {
        if (revents & POLLIN) add_client(daemon);
        return;
    }
    int index = poll_set->indexes[slot];
    if (poll_set->kinds[slot] == LABPTY_POLL_CLIENT) {
        if (service_client_poll(daemon, index, revents) < 0) client_release(&daemon->clients[index]);
        return;
    }
    if (poll_set->kinds[slot] == LABPTY_POLL_SESSION && poll_revents_readable(revents)) {
        assert(index >= 0);
        assert(index < LABPTY_MAX_SESSIONS);
        labpty_session_t *s = &daemon->registry.sessions[index];
        if (s->used && s->master_fd >= 0) drain_session(daemon, s);
    }
}

static void tick_heartbeats(labpty_daemon_t *daemon) {
    assert(daemon != NULL);
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &daemon->registry.sessions[i];
        if (s->used && s->alive) labpty_byte_ring_heartbeat(&s->ring);
    }
}

/* Modelled by specs/labpty/LabptyControlChannel.tla::Expire. Both branches
 * of the OR matter: the `!established` branch reclaims un-negotiated
 * idle clients (UnnegotiatedIdleIsNotPermanent, the 2aac41a property);
 * the `has_pending_frame` branch reclaims established clients stuck
 * mid-frame (StuckMidFrameIsNotPermanent). The companion
 * MC_ControlChannelMidFrameLeak.cfg pins the latter property by
 * setting ExpireIgnoresMidFrame=TRUE — a guard against future
 * "simplifications" that drop the half-sent-frame branch below. */
static void expire_stalled_clients(labpty_daemon_t *daemon) {
    assert(daemon != NULL);
    uint64_t now = monotonic_ns();
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        labpty_client_t *client = &daemon->clients[i];
        if (!client->in_use) continue;
        if (now < client->deadline_ns) continue;
        /* Established clients (at least one successful round-trip) may sit
         * idle while reading byte-ring output directly — don't expire
         * them unless they have a half-sent frame in flight. */
        int has_pending_frame = client->read_have > 0 || client->write_total > 0;
        if (client->established && !has_pending_frame) continue;
        client_release(client);
    }
}

static int event_loop(labpty_daemon_t *daemon) {
    assert(daemon != NULL);
    assert(daemon->listen_fd >= 0);
    while (!shutdown_requested) {
        labpty_poll_set_t poll_set;
        build_poll_set(daemon, &poll_set);
        int ready = poll(poll_set.fds, poll_set.count, 100);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) {
            perror("labpty poll");
            return -1;
        }
        for (nfds_t i = 0; i < poll_set.count; i++) {
            service_poll_watch(daemon, &poll_set, i);
        }
        tick_heartbeats(daemon);
        labpty_registry_reap(&daemon->registry);
        expire_stalled_clients(daemon);
    }
    return 0;
}

static void cleanup_daemon(labpty_daemon_t *daemon, const char *socket_path) {
    assert(daemon != NULL);
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        labpty_client_t *client = &daemon->clients[i];
        if (client->in_use) client_release(client);
    }
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &daemon->registry.sessions[i];
        if (s->used) labpty_session_close(s);
    }
    if (daemon->listen_fd >= 0) {
        close(daemon->listen_fd);
        daemon->listen_fd = -1;
    }
    if (socket_path && socket_path[0]) unlink(socket_path);
}

int main(int argc, char **argv) {
    char socket_path[LABPTY_PATH_BYTES + 1];
    char shm_dir[LABPTY_PATH_BYTES + 1];
    if (parse_args(argc, argv, socket_path, shm_dir) != 0) { usage(); return 64; }
    if (install_signal_handlers() != 0) { perror("labpty signal"); return 1; }
    /* macOS does not implement mlockall (ENOSYS), and the daemon's
     * latency-critical pages are the byte rings — those are pinned
     * per-region in labpty_byte_ring_create. The mlockall call that used
     * to live here was dead code on every supported build. */
    if (mkdir(shm_dir, 0700) != 0 && errno != EEXIST) { perror("labpty shm dir"); return 1; }
    labpty_daemon_t daemon;
    memset(&daemon, 0, sizeof(daemon));
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) daemon.clients[i].fd = -1;
    labpty_registry_init(&daemon.registry, shm_dir);
    daemon.listen_fd = listen_unix_socket(socket_path);
    if (daemon.listen_fd < 0) { perror("labpty listen"); return 1; }
    if (set_nonblock(daemon.listen_fd) != 0) {
        perror("labpty nonblock");
        cleanup_daemon(&daemon, socket_path);
        return 1;
    }
    int loop_status = event_loop(&daemon);
    cleanup_daemon(&daemon, socket_path);
    return loop_status == 0 ? 0 : 1;
}
