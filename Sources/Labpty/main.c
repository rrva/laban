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
    int supports_output_wake;
    int output_wake;
    int wake_armed;
    int wake_pending;
    char client_id[LABPTY_LOGICAL_ID_BYTES + 1];
    size_t read_have;
    labpty_frame_header_t header;
    uint8_t read_buf[LABPTY_MAX_FRAME];
    size_t write_total;
    size_t write_sent;
    uint8_t write_buf[LABPTY_MAX_FRAME];
    uint64_t deadline_ns;
    /* Absolute wall-clock deadline for the in-flight request frame,
     * set on the first byte and never bumped by subsequent bytes.
     * Defends against trickle slowloris: a client that drips one byte
     * just before every idle deadline keeps `deadline_ns` moving
     * forward, but `frame_deadline_ns` is fixed at frame-start and
     * eventually catches the slot. 0 when no frame is in flight. */
    uint64_t frame_deadline_ns;
} labpty_client_t;

typedef struct {
    int listen_fd;
    int output_wake_armed_count;
    /* Identity of the socket file we successfully bound at startup,
     * captured immediately after bind. cleanup_daemon's final unlink
     * compares against this so we don't clobber a successor daemon's
     * socket if one bound at the same path between our close(listen_fd)
     * and our unlink — the LabptyStartup.tla gap that becomes visible
     * once Stop is no longer atomic on the wire. */
    dev_t socket_dev;
    ino_t socket_ino;
    int socket_identity_known;
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
/* Maximum wall-clock time we'll wait for a single request frame to
 * arrive in full, measured from the first byte. Two seconds is well
 * above any legitimate round-trip on a local UNIX socket and below the
 * Swift client's default rpcTimeoutMilliseconds (2000ms) so the daemon
 * reclaims its slot before the client times out and retries. */
static const uint64_t LABPTY_FRAME_TOTAL_TIMEOUT_NS = 2000000000ull;
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
    /* Survive a stray SIGHUP (controlling-terminal close in dev/CI, a
     * group-wide signal): the daemon is meant to outlive its launcher
     * (ADR 0006), so the default terminate-on-HUP would kill every live
     * session. (L1) */
    if (sigaction(SIGHUP, &ignore, NULL) != 0) return -1;

    struct sigaction shutdown = {0};
    shutdown.sa_handler = request_shutdown;
    sigemptyset(&shutdown.sa_mask);
    if (sigaction(SIGTERM, &shutdown, NULL) != 0) return -1;
    if (sigaction(SIGINT, &shutdown, NULL) != 0) return -1;
    return 0;
}

/* Refuse to use a pre-existing shm_dir whose mode or ownership opens
 * the door to foreign-uid symlink-staging attacks against the
 * predictable `labpty-N.br` paths. The companion fix is
 * O_EXCL|O_NOFOLLOW in open_ring_backing, which already defeats the
 * same-uid case; this validator catches the cross-uid case where the
 * dir is owned by someone else, or world-writable so any user can
 * drop a symlink in it. We tolerate world-readable (0o755) since
 * that's the umask default and read-only access doesn't help an
 * attacker — what we reject is any group/other write bit. */
static int labpty_private_dir_ok(const char *path) {
    assert(path != NULL);
    assert(path[0] != '\0');
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
    if (!S_ISDIR(st.st_mode)) return 0;
    if (st.st_uid != geteuid()) return 0;
    if ((st.st_mode & 0022) != 0) return 0;
    return 1;
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

static int client_index(const labpty_daemon_t *daemon, const labpty_client_t *client) {
    assert(daemon != NULL);
    assert(client != NULL);
    return (int)(client - daemon->clients);
}

/* Runtime trace conformance (the frontier that turns "// Modelled by" from a
 * claim into a checked fact). When LABPTY_TRACE names a file, append one
 * NDJSON record per attachment transition capturing the observable state the
 * model abstracts: inUse[client] (slot occupied), alive[session] (slot used),
 * and attached[session] (the bits of attached_clients, gated on `used` so a
 * freed slot carries no phantom owner). scripts/check-trace replays the trace
 * through specs/labpty/LabptyAttachment.tla, so a real daemon run and the
 * deterministic proofs/labpty/trace harness both have every transition checked
 * against the spec. Zero-cost (one cached getenv) when the var is unset. */
static void labpty_trace_emit(const labpty_daemon_t *daemon, const char *action) {
    static FILE *fp = NULL;
    static int resolved = 0;
    if (!resolved) {
        const char *path = getenv("LABPTY_TRACE");
        if (path != NULL && path[0] != '\0') fp = fopen(path, "a");
        resolved = 1;
    }
    if (fp == NULL) return;
    fprintf(fp, "{\"action\":\"%s\",\"inUse\":[", action);
    for (int c = 0; c < LABPTY_MAX_CLIENTS; c++)
        fprintf(fp, "%s%d", c ? "," : "", daemon->clients[c].in_use ? 1 : 0);
    fprintf(fp, "],\"alive\":[");
    for (int s = 0; s < LABPTY_MAX_SESSIONS; s++)
        fprintf(fp, "%s%d", s ? "," : "", daemon->registry.sessions[s].used ? 1 : 0);
    fprintf(fp, "],\"attached\":[");
    for (int s = 0; s < LABPTY_MAX_SESSIONS; s++) {
        const labpty_session_t *sess = &daemon->registry.sessions[s];
        fprintf(fp, "%s[", s ? "," : "");
        int first = 1;
        if (sess->used) {
            for (int c = 0; c < LABPTY_MAX_CLIENTS; c++) {
                if (sess->attached_clients & (uint8_t)(1u << c)) {
                    fprintf(fp, "%s%d", first ? "" : ",", c);
                    first = 0;
                }
            }
        }
        fprintf(fp, "]");
    }
    fprintf(fp, "]}\n");
    fflush(fp);
}

static void client_release(labpty_daemon_t *daemon, labpty_client_t *client) {
    assert(daemon != NULL);
    assert(client != NULL);
    /* Scrub this connection's attachment bit from every session so the
     * connected-client count drops the instant the socket goes away.
     * Output is read on a separate byte-ring fd, so a socket disconnect
     * is the daemon's only signal that this client is gone. Every
     * teardown path (poll fault, idle/frame expiry, shutdown) funnels
     * through here, which is why no per-session counter has to be
     * decremented anywhere else. Modelled by
     * specs/labpty/LabptyAttachment.tla::Disconnect. */
    uint8_t bit = (uint8_t)(1u << client_index(daemon, client));
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        daemon->registry.sessions[i].attached_clients &= (uint8_t)~bit;
    }
    if (client->wake_armed && daemon->output_wake_armed_count > 0) {
        daemon->output_wake_armed_count--;
    }
    if (client->fd >= 0) close(client->fd);
    memset(client, 0, sizeof(*client));
    client->fd = -1;
    labpty_trace_emit(daemon, "Disconnect");
}

static void client_reset_after_response(labpty_client_t *client) {
    assert(client != NULL);
    client->read_have = 0;
    client->header_parsed = 0;
    client->write_total = 0;
    client->write_sent = 0;
    client->frame_deadline_ns = 0;
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
            labpty_trace_emit(daemon, "Connect");
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
        /* Each record is length-delimited so future descriptor
         * extensions can be appended without breaking decoders of
         * the surrounding list shape (ADR 0007). The length is a
         * u32 prefix that covers the existing descriptor bytes
         * plus any future trailer the daemon chooses to append. */
        if ((writer.end - writer.cur) < 4) return 0;
        uint8_t *record_len_ptr = writer.cur;
        if (labpty_write_u32(&writer, 0) != LABPTY_OK) return 0;
        uint8_t *record_start = writer.cur;
        if (labpty_encode_descriptor(&writer, &descriptor) != LABPTY_OK) return 0;
        uint32_t record_len = (uint32_t)(writer.cur - record_start);
        labpty_writer_t record_len_writer = { .cur = record_len_ptr, .end = record_len_ptr + 4 };
        labpty_write_u32(&record_len_writer, record_len);
        count++;
    }
    labpty_writer_t count_writer = { .cur = count_ptr, .end = count_ptr + 4 };
    labpty_write_u32(&count_writer, count);
    return (size_t)(writer.cur - out);
}

static void arm_output_wake_clients(labpty_daemon_t *daemon, const char *client_id);

static int hello_request_has_capability(const labpty_hello_request_t *request, const char *capability) {
    assert(request != NULL);
    assert(capability != NULL);
    for (uint32_t i = 0; i < request->capability_count; i++) {
        if (strcmp(request->capabilities[i], capability) == 0) return 1;
    }
    return 0;
}

static labpty_status_t handle_hello(labpty_daemon_t *daemon, labpty_client_t *client, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    assert(client != NULL);
    labpty_status_t status = labpty_decode_hello_request(payload, len, &daemon->hello_request);
    if (status != LABPTY_OK) return status;
    status = labpty_negotiate_hello(&daemon->hello_request);
    if (status != LABPTY_OK) return status;
    snprintf(client->client_id, sizeof(client->client_id), "%s", daemon->hello_request.client_id);
    client->supports_output_wake = hello_request_has_capability(&daemon->hello_request, "output-wake/v1");
    return labpty_encode_hello_response(out, cap, out_len);
}

static labpty_status_t handle_open_output_wake(labpty_daemon_t *daemon, labpty_client_t *client, const uint8_t *payload, size_t len, size_t *out_len) {
    assert(daemon != NULL);
    assert(client != NULL);
    assert(out_len != NULL);
    if (payload == NULL && len > 0) return LABPTY_E_TRUNCATED_FRAME;
    if (!client->supports_output_wake) return LABPTY_E_CAPABILITY_REQUIRED;
    if (len != 0) return LABPTY_E_PAYLOAD_TOO_LARGE;
    client->output_wake = 1;
    if (!client->wake_armed) {
        client->wake_armed = 1;
        daemon->output_wake_armed_count++;
    }
    client->wake_pending = 0;
    *out_len = 0;
    return LABPTY_OK;
}

static labpty_status_t handle_park_output_wake(labpty_daemon_t *daemon, labpty_client_t *client, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    assert(client != NULL);
    assert(out != NULL);
    assert(out_len != NULL);
    if (!client->supports_output_wake) return LABPTY_E_CAPABILITY_REQUIRED;
    labpty_output_wake_park_request_t request;
    labpty_status_t status = labpty_decode_output_wake_park_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    int parked = 1;
    for (uint32_t i = 0; i < request.count; i++) {
        labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handles[i]);
        if (session == NULL) return LABPTY_E_SESSION_NOT_FOUND;
        if (session->ring.output_offset != request.observed_offsets[i]) {
            parked = 0;
            break;
        }
    }
    if (parked) {
        /* A control-socket reconnect scrubs the old connection slot from
         * attached_clients before the app re-parks the already-open wake socket.
         * Treat a successful park over handles this client is actively reading as
         * an idempotent re-claim of those live sessions; otherwise the subsequent
         * notify path suppresses the wake because no attached slot has the same
         * logical client_id. */
        uint8_t bit = (uint8_t)(1u << client_index(daemon, client));
        for (uint32_t i = 0; i < request.count; i++) {
            labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handles[i]);
            if (session != NULL && session->alive) session->attached_clients |= bit;
        }
        arm_output_wake_clients(daemon, client->client_id);
    }
    labpty_writer_t writer = { .cur = out, .end = out + cap };
    status = labpty_write_u8(&writer, (uint8_t)(parked ? 1 : 0));
    if (status != LABPTY_OK) return status;
    *out_len = (size_t)(writer.cur - out);
    return LABPTY_OK;
}

static labpty_status_t handle_open(labpty_daemon_t *daemon, labpty_client_t *client, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    assert(client != NULL);
    assert(out_len != NULL);
    labpty_status_t status = labpty_decode_open_request(payload, len, &daemon->open_request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = NULL;
    status = labpty_registry_open(&daemon->registry, &daemon->open_request, &session);
    if (status != LABPTY_OK) return status;
    /* The opening connection is implicitly attached to its new session. */
    session->attached_clients |= (uint8_t)(1u << client_index(daemon, client));
    labpty_trace_emit(daemon, "OpenSession");
    *out_len = encode_descriptor_payload(session, out, cap);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

/* ATTACH/DETACH let a connection claim or release an already-open
 * session it did not create — the reattach-after-restart and adopt-orphan
 * flows. Idempotent: attaching twice from one connection is a single bit,
 * detaching when not attached is a no-op. Both return the descriptor so
 * the caller observes the updated connected-client count. */
static labpty_status_t handle_attach(labpty_daemon_t *daemon, labpty_client_t *client, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    assert(client != NULL);
    labpty_handle_request_t request;
    labpty_status_t status = labpty_decode_handle_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    if (!session || !session->alive) return LABPTY_E_SESSION_NOT_FOUND;
    session->attached_clients |= (uint8_t)(1u << client_index(daemon, client));
    labpty_trace_emit(daemon, "Attach");
    *out_len = encode_descriptor_payload(session, out, cap);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

static labpty_status_t handle_detach(labpty_daemon_t *daemon, labpty_client_t *client, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    assert(client != NULL);
    labpty_handle_request_t request;
    labpty_status_t status = labpty_decode_handle_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    if (!session) return LABPTY_E_SESSION_NOT_FOUND;
    session->attached_clients &= (uint8_t)~(1u << client_index(daemon, client));
    labpty_trace_emit(daemon, "Detach");
    *out_len = encode_descriptor_payload(session, out, cap);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

static labpty_status_t handle_resize(labpty_daemon_t *daemon, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    assert(daemon != NULL);
    labpty_resize_request_t request;
    labpty_status_t status = labpty_decode_resize_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    /* master_fd < 0 means the child hung up and drain_session closed it but
     * the reap tick has not yet flipped alive; ioctl on -1 would EBADF →
     * E_INTERNAL. Report the truthful SESSION_NOT_FOUND so the client's
     * fresh-handle retry can recover. (L2) */
    if (!session || !session->alive || session->master_fd < 0) return LABPTY_E_SESSION_NOT_FOUND;
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
    /* Reject a client-controlled out-of-range signal number rather than
     * forwarding it to killpg/kill; the daemon defines the accepted set. (L9) */
    /* signo 0 is the valid POSIX null signal (permission/existence probe). */
    if (request.signo < 0 || request.signo >= NSIG) return LABPTY_E_INTERNAL;
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
    /* Already mid-teardown — the previous terminate's reap tick is
     * what eventually frees this slot, not a fresh request_close.
     * Return SESSION_NOT_FOUND so callers don't loop on double-
     * terminate; both racing terminators see the slot as gone. */
    if (session->close_pending) return LABPTY_E_SESSION_NOT_FOUND;
    labpty_descriptor_view_t descriptor = labpty_session_descriptor(session);
    if (session->alive) {
        /* The hot path: dispatch SIGHUP, defer reap to the next
         * event-loop tick. Returns immediately so the single-threaded
         * loop is free to service other clients while a HUP-ignoring
         * child waits out the SIGKILL budget. */
        labpty_session_request_close(session, monotonic_ns());
    } else if (session->child_pid <= 0) {
        /* Dead-leak slot: child already exited naturally and
         * labpty_registry_reap left used=1 with the ring still open
         * so output could still be drained from the byte ring.
         * Finish the cleanup synchronously now that the client has
         * acknowledged the death by calling terminate; the work is
         * just labpty_byte_ring_close, no syscalls that can block
         * the event loop. */
        if (session->slave_inspect_fd >= 0) {
            close(session->slave_inspect_fd);
            session->slave_inspect_fd = -1;
        }
        labpty_byte_ring_close(&session->ring);
        session->used = 0;
        session->alive = 0;
    }
    descriptor.alive = 0;
    *out_len = encode_descriptor_view_payload(&descriptor, out, cap);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

/* Conservative slack against MAX_INPUT / MAX_CANON. Reserves headroom
 * for in-flight bytes the line discipline may have already consumed
 * from the master but not yet drained out the canonical queue, and for
 * minor termios quirks (IUTF8 expanding multibyte characters, etc). */
#define LABPTY_BACKPRESSURE_SAFETY_MARGIN 64

/* Returns 1 when the byte is a canonical-mode line delimiter under the
 * given termios: \n is unconditional, VEOL/VEOL2/VEOF are configurable
 * but treated as delimiters when set to a non-_POSIX_VDISABLE value. */
static int is_canonical_delimiter(uint8_t byte, const struct termios *tio) {
    if (byte == (uint8_t)'\n') return 1;
    cc_t veol = tio->c_cc[VEOL];
    if (veol != (cc_t)_POSIX_VDISABLE && byte == (uint8_t)veol) return 1;
#ifdef VEOL2
    cc_t veol2 = tio->c_cc[VEOL2];
    if (veol2 != (cc_t)_POSIX_VDISABLE && byte == (uint8_t)veol2) return 1;
#endif
    cc_t veof = tio->c_cc[VEOF];
    if (veof != (cc_t)_POSIX_VDISABLE && byte == (uint8_t)veof) return 1;
    return 0;
}

static labpty_status_t handle_write(labpty_daemon_t *daemon, const uint8_t *payload, size_t len) {
    assert(daemon != NULL);
    labpty_write_input_request_t request;
    labpty_status_t status = labpty_decode_write_input_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    if (!session || !session->alive || session->master_fd < 0) return LABPTY_E_SESSION_NOT_FOUND;
    /* A prior payload still draining to a backed-up master means the consumer
     * is behind; refuse new input atomically rather than growing an unbounded
     * daemon-side queue. Bounds pending_input to one in-flight payload. */
    if (session->pending_input_total > session->pending_input_sent) return LABPTY_E_INPUT_BACKPRESSURE;

    /* Preflight admission check (ADR 0008). Under ICANON the slave's
     * line discipline silently drops bytes once (rawQ + canQ) reaches
     * MAX_INPUT, and a single canonical line silently truncates past
     * MAX_CANON. write(2) on the master still reports the full count.
     * Without this check we'd return LABPTY_OK for bytes the child
     * will never see — the bug the regression in
     * Tests/LabptyTests/LabptyAdversarialTests.swift pins. We can't
     * make the write succeed for an oversized cooked payload, but we
     * can refuse it atomically: no byte reaches the master, the caller
     * gets a typed error and can chunk/retry. Raw-mode writes (no
     * ICANON) are unaffected. If the inspection fd is unavailable we
     * skip preflight; that's a graceful degradation rather than a hard
     * failure. */
    int icanon = 0;
    struct termios tio;
    if (session->slave_inspect_fd >= 0 &&
        tcgetattr(session->slave_inspect_fd, &tio) == 0 &&
        (tio.c_lflag & ICANON)) {
        icanon = 1;
        long max_canon = fpathconf(session->slave_inspect_fd, _PC_MAX_CANON);
        if (max_canon <= 0) max_canon = 1024;
        long max_input = fpathconf(session->slave_inspect_fd, _PC_MAX_INPUT);
        if (max_input <= 0) max_input = 1024;
        int pending_raw = 0;
        if (ioctl(session->slave_inspect_fd, FIONREAD, &pending_raw) != 0 || pending_raw < 0) {
            pending_raw = 0;
        }
        uint64_t pending_canq = (uint64_t)pending_raw;
        uint64_t pending_rawq = session->canonical_pending_estimate;
        uint64_t margin = LABPTY_BACKPRESSURE_SAFETY_MARGIN;
        uint64_t limit_input = (uint64_t)max_input > margin ? (uint64_t)max_input - margin : 0;
        uint64_t limit_canon = (uint64_t)max_canon > margin ? (uint64_t)max_canon - margin : 0;
        uint64_t used_input = pending_canq + pending_rawq;
        uint64_t headroom_input = limit_input > used_input ? limit_input - used_input : 0;
        uint64_t headroom_canon = limit_canon > pending_rawq ? limit_canon - pending_rawq : 0;
        uint64_t admissible = headroom_input < headroom_canon ? headroom_input : headroom_canon;
        if ((uint64_t)request.len > admissible) {
            return LABPTY_E_INPUT_BACKPRESSURE;
        }
    }

    /* Push as much as the master accepts right now without blocking. The
     * preflight already admitted the whole payload, so the daemon owns its
     * delivery: any unsent tail is staged on the session and the event loop
     * drains it on POLLOUT (mirrors the client response path). The single-
     * threaded loop NEVER spins on a slow consumer — the 100 ms blocking spin
     * this replaced could starve every other client past its idle deadline and
     * force-expire them (commit d4177eb's stall symptom, client-triggerable). */
    size_t sent = 0;
    while (sent < request.len) {
        ssize_t n = write(session->master_fd, request.bytes + sent, request.len - sent);
        if (n > 0) { sent += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        return LABPTY_E_INTERNAL;
    }
    if (sent < request.len) {
        size_t tail = request.len - sent;
        memcpy(session->pending_input, request.bytes + sent, tail);
        session->pending_input_total = tail;
        session->pending_input_sent = 0;
    }

    /* Update canonical_pending_estimate using the just-accepted payload.
     * Bytes after the last delimiter sit in the raw queue waiting for
     * the next delimiter; everything up to and including the last
     * delimiter has already been promoted to the canonical queue, where
     * FIONREAD will see it on subsequent calls. */
    if (icanon) {
        size_t after_last_delim = request.len;
        for (size_t i = request.len; i > 0; i--) {
            if (is_canonical_delimiter(request.bytes[i - 1], &tio)) {
                after_last_delim = request.len - i;
                session->canonical_pending_estimate = after_last_delim;
                goto estimate_updated;
            }
        }
        session->canonical_pending_estimate += request.len;
    estimate_updated:
        ;
    } else {
        /* Raw mode resets the canonical raw-queue estimate. KNOWN LIMITATION
         * (M3): bytes written in raw mode that the child never reads stay
         * physically queued in the slave, yet we drop them from the estimate.
         * After a raw->canonical flip, canonical-mode FIONREAD reports only
         * completed lines (not the carried-over partial line), so the next
         * canonical preflight can over-admit into a near-full queue and the
         * line discipline silently drops the overflow. NOT fixed: the only
         * accurate fix is an ioctl(FIONREAD) on every raw-mode write (you can't
         * know which raw write precedes the flip), which is too costly on the
         * hot input path for a narrow window — a child flipping to canonical
         * almost always drains first, and the loss is bounded to the overflow.
         * See ADR 0008's mode-flip caveat. */
        session->canonical_pending_estimate = 0;
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
        labpty_status_t status = handle_hello(daemon, client, payload, len, out, cap, out_len);
        if (status == LABPTY_OK) client->negotiated = 1;
        return status;
    }
    if (!client->negotiated) return LABPTY_E_CAPABILITY_REQUIRED;
    if (header.op == LABPTY_OP_OPEN_OUTPUT_WAKE) return handle_open_output_wake(daemon, client, payload, len, out_len);
    if (header.op == LABPTY_OP_PARK_OUTPUT_WAKE) return handle_park_output_wake(daemon, client, payload, len, out, cap, out_len);
    if (header.op == LABPTY_OP_OPEN_SESSION) return handle_open(daemon, client, payload, len, out, cap, out_len);
    if (header.op == LABPTY_OP_LIST_SESSIONS) {
        *out_len = encode_list_payload(&daemon->registry, out, cap);
        return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
    }
    if (header.op == LABPTY_OP_RESIZE_SESSION) return handle_resize(daemon, payload, len, out, cap, out_len);
    if (header.op == LABPTY_OP_SIGNAL_SESSION) return handle_signal(daemon, payload, len, out, cap, out_len);
    if (header.op == LABPTY_OP_TERMINATE_SESSION) return handle_terminate(daemon, payload, len, out, cap, out_len);
    if (header.op == LABPTY_OP_WRITE_INPUT) return handle_write(daemon, payload, len);
    if (header.op == LABPTY_OP_PING) return labpty_encode_ping_response(out, cap, out_len);
    if (header.op == LABPTY_OP_ATTACH_SESSION) return handle_attach(daemon, client, payload, len, out, cap, out_len);
    if (header.op == LABPTY_OP_DETACH_SESSION) return handle_detach(daemon, client, payload, len, out, cap, out_len);
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
            uint64_t now = monotonic_ns();
            /* First byte of a new frame: arm the absolute frame deadline.
             * Subsequent bytes within the same frame must not bump it,
             * otherwise a trickle attacker would keep pushing the
             * deadline forward and hold the slot indefinitely. */
            if (client->read_have == 0) {
                client->frame_deadline_ns = now + LABPTY_FRAME_TOTAL_TIMEOUT_NS;
            }
            client->read_have += (size_t)n;
            client->deadline_ns = now + LABPTY_IO_IDLE_TIMEOUT_NS;
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

/* Drain a session's staged writeInput tail to the master, non-blocking. The
 * event loop calls this on POLLOUT for a session with pending input. A hard
 * write error drops the tail — the reap path tears the dead session down. */
static void flush_pending_input(labpty_session_t *session) {
    assert(session != NULL);
    while (session->pending_input_sent < session->pending_input_total) {
        ssize_t n = write(session->master_fd,
                          session->pending_input + session->pending_input_sent,
                          session->pending_input_total - session->pending_input_sent);
        if (n > 0) { session->pending_input_sent += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return; /* retry next POLLOUT */
        session->pending_input_total = 0;
        session->pending_input_sent = 0;
        return;
    }
    session->pending_input_total = 0;
    session->pending_input_sent = 0;
}

static int client_id_matches(const labpty_client_t *client, const char *client_id) {
    assert(client != NULL);
    assert(client_id != NULL);
    return client->in_use && client->client_id[0] != '\0' && strcmp(client->client_id, client_id) == 0;
}

static int session_has_attached_client_id(const labpty_daemon_t *daemon, const labpty_session_t *session, const char *client_id) {
    assert(daemon != NULL);
    assert(session != NULL);
    assert(client_id != NULL);
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        if ((session->attached_clients & (uint8_t)(1u << i)) == 0) continue;
        if (client_id_matches(&daemon->clients[i], client_id)) return 1;
    }
    return 0;
}

static void arm_output_wake_clients(labpty_daemon_t *daemon, const char *client_id) {
    assert(daemon != NULL);
    assert(client_id != NULL);
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        labpty_client_t *client = &daemon->clients[i];
        if (!client->in_use || !client->output_wake) continue;
        if (!client_id_matches(client, client_id)) continue;
        if (!client->wake_armed) {
            client->wake_armed = 1;
            daemon->output_wake_armed_count++;
        }
    }
}

static int queue_output_wake(labpty_client_t *client) {
    assert(client != NULL);
    if (client->wake_pending) return 0;
    if (client->write_total > client->write_sent) {
        client->wake_pending = 1;
        return 0;
    }
    uint8_t byte = 1;
    for (;;) {
        ssize_t n = write(client->fd, &byte, 1);
        if (n == 1) return 0;
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            client->wake_pending = 1;
            return 0;
        }
        return -1;
    }
}

static int flush_output_wake(labpty_client_t *client) {
    assert(client != NULL);
    if (!client->wake_pending) return 0;
    uint8_t byte = 1;
    for (;;) {
        ssize_t n = write(client->fd, &byte, 1);
        if (n == 1) {
            client->wake_pending = 0;
            return 0;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        return -1;
    }
}

static void notify_output_wake_clients(labpty_daemon_t *daemon, labpty_session_t *session) {
    assert(daemon != NULL);
    assert(session != NULL);
    if (daemon->output_wake_armed_count <= 0) return;
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        labpty_client_t *client = &daemon->clients[i];
        if (!client->in_use || !client->output_wake || client->client_id[0] == '\0') continue;
        if (!client->wake_armed) continue;
        if (!session_has_attached_client_id(daemon, session, client->client_id)) continue;
        client->wake_armed = 0;
        daemon->output_wake_armed_count--;
        if (queue_output_wake(client) != 0) client_release(daemon, client);
    }
}

static void drain_session(labpty_daemon_t *daemon, labpty_session_t *session) {
    assert(daemon != NULL);
    assert(session != NULL);
    assert(session->master_fd >= 0);
    ssize_t n = read(session->master_fd, daemon->read_buffer, sizeof(daemon->read_buffer));
    if (n > 0) {
        labpty_byte_ring_write(&session->ring, daemon->read_buffer, (size_t)n);
        notify_output_wake_clients(daemon, session);
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
        short events;
        if (client->output_wake) {
            events = POLLIN;
            if (client->write_total > client->write_sent || client->wake_pending) events |= POLLOUT;
        } else {
            events = client->write_total > client->write_sent ? POLLOUT : POLLIN;
        }
        add_poll_watch(poll_set, client->fd, events, LABPTY_POLL_CLIENT, i);
    }
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &daemon->registry.sessions[i];
        if (s->used && s->master_fd >= 0) {
            short events = POLLIN;
            if (s->pending_input_total > s->pending_input_sent) events |= POLLOUT;
            add_poll_watch(poll_set, s->master_fd, events, LABPTY_POLL_SESSION, i);
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
    if (client->output_wake) {
        if (client->wake_pending && (revents & POLLOUT)) {
            if (flush_output_wake(client) != 0) return -1;
        }
        if (poll_revents_faulted(revents)) return -1;
        if (revents & POLLIN) {
            uint8_t discard[64];
            for (;;) {
                ssize_t n = read(client->fd, discard, sizeof(discard));
                if (n == 0) return -1;
                if (n > 0) return -1;
                if (errno == EINTR) continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
                return -1;
            }
        }
        return 0;
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
        if (service_client_poll(daemon, index, revents) < 0) client_release(daemon, &daemon->clients[index]);
        return;
    }
    if (poll_set->kinds[slot] == LABPTY_POLL_SESSION) {
        assert(index >= 0);
        assert(index < LABPTY_MAX_SESSIONS);
        labpty_session_t *s = &daemon->registry.sessions[index];
        if (!s->used || s->master_fd < 0) return;
        if (revents & POLLOUT) flush_pending_input(s);
        if (poll_revents_readable(revents)) drain_session(daemon, s);
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
 * "simplifications" that drop the half-sent-frame branch below.
 *
 * The `frame_deadline_ns` branch defends against a trickle attacker
 * that the abstract TLA+ model does not see: TLC treats Expire as
 * eligible to fire any tick while a slot is mid-frame, but the
 * C implementation only fires it once `deadline_ns` has elapsed, and
 * a one-byte-every-200ms drip refreshes `deadline_ns` forever.
 * Pinned by testTrickleFrameCannotOccupyAllClientSlotsForever in
 * Tests/LabptyTests/LabptyAdversarialTests.swift. */
static void expire_stalled_clients(labpty_daemon_t *daemon) {
    assert(daemon != NULL);
    uint64_t now = monotonic_ns();
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        labpty_client_t *client = &daemon->clients[i];
        if (!client->in_use) continue;
        /* Absolute frame-arrival deadline takes precedence over the
         * per-read idle deadline: it is set on the first byte of a frame
         * and is not refreshed by subsequent bytes, so a trickle attacker
         * that keeps `deadline_ns` moving forward still expires here. */
        if (client->frame_deadline_ns != 0 && now >= client->frame_deadline_ns) {
            if (client->established) {
                fprintf(stderr,
                    "labpty: force-expiring established client %d on frame deadline "
                    "(read_have=%zu write_total=%zu write_sent=%zu) — request frame "
                    "incomplete %llums past the frame budget (slow/trickle client or "
                    "event-loop stall)\n",
                    client_index(daemon, client), client->read_have,
                    client->write_total, client->write_sent,
                    (unsigned long long)((now - client->frame_deadline_ns) / 1000000ull));
            }
            client_release(daemon, client);
            continue;
        }
        if (now < client->deadline_ns) continue;
        /* Established clients (at least one successful round-trip) may sit
         * idle while reading byte-ring output directly — don't expire
         * them unless they have a half-sent frame in flight. */
        int has_pending_frame = client->read_have > 0 || client->write_total > 0;
        if (client->established && !has_pending_frame) continue;
        /* Releasing an established client here is abnormal: it means the idle
         * deadline elapsed while a frame was in flight. A pending RESPONSE
         * (write_total > 0) is the daemon's own write, not client
         * delinquency, so this almost always means the single-threaded loop
         * stalled past the idle budget (e.g. a blocking syscall in a
         * handler). Log it so the resulting client-side ECONNRESET is
         * diagnosable instead of a mystery. */
        if (client->established) {
            fprintf(stderr,
                "labpty: force-expiring established client %d on idle deadline "
                "(read_have=%zu write_total=%zu write_sent=%zu) — event-loop stall "
                "suspected, stalled %llums past the idle budget\n",
                client_index(daemon, client), client->read_have,
                client->write_total, client->write_sent,
                (unsigned long long)((now - client->deadline_ns) / 1000000ull));
        }
        client_release(daemon, client);
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
        int used_before = 0;
        for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) used_before += daemon->registry.sessions[i].used;
        labpty_registry_reap(&daemon->registry);
        int used_after = 0;
        for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) used_after += daemon->registry.sessions[i].used;
        if (used_after != used_before) labpty_trace_emit(daemon, "TerminateSession");
        expire_stalled_clients(daemon);
    }
    return 0;
}

static void cleanup_daemon(labpty_daemon_t *daemon, const char *socket_path) {
    assert(daemon != NULL);
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        labpty_client_t *client = &daemon->clients[i];
        if (client->in_use) client_release(daemon, client);
    }
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &daemon->registry.sessions[i];
        if (s->used) labpty_session_close(s);
    }
    if (daemon->listen_fd >= 0) {
        close(daemon->listen_fd);
        daemon->listen_fd = -1;
    }
    /* Only unlink the socket path if the file on disk is still the
     * inode we bound. Otherwise a successor daemon may have already
     * unlinked-and-rebound after probing our path as stale (we just
     * closed listen_fd above, so SocketIsLive would now report
     * stale), and removing the path here would strand the successor.
     * The TOCTOU window between lstat and unlink is one syscall, so
     * not fully race-free, but the worst-case foreign-inode unlink
     * still requires another daemon to win the race twice.
     * Modelled by specs/labpty/LabptyStartup.tla::UnlinkPath; the
     * companion MC_StartupCleanupTOCTOU.cfg with
     * InodeValidatedCleanup=FALSE pins the strand counter-example. */
    if (socket_path && socket_path[0] && daemon->socket_identity_known) {
        struct stat st;
        if (lstat(socket_path, &st) == 0 &&
            st.st_dev == daemon->socket_dev &&
            st.st_ino == daemon->socket_ino) {
            unlink(socket_path);
        }
    }
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
    if (!labpty_private_dir_ok(shm_dir)) {
        fprintf(stderr, "labpty: refusing non-private shm dir: %s\n", shm_dir);
        return 1;
    }
    /* static: the per-session pending-input buffers make this struct several MB
     * — too large for the stack. The daemon is single-instance per process. */
    static labpty_daemon_t daemon;
    memset(&daemon, 0, sizeof(daemon));
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) daemon.clients[i].fd = -1;
    labpty_registry_init(&daemon.registry, shm_dir);
    daemon.listen_fd = listen_unix_socket(socket_path);
    if (daemon.listen_fd < 0) { perror("labpty listen"); return 1; }
    {
        struct stat st;
        if (lstat(socket_path, &st) == 0 && S_ISSOCK(st.st_mode)) {
            daemon.socket_dev = st.st_dev;
            daemon.socket_ino = st.st_ino;
            daemon.socket_identity_known = 1;
        }
    }
    if (set_nonblock(daemon.listen_fd) != 0) {
        perror("labpty nonblock");
        cleanup_daemon(&daemon, socket_path);
        return 1;
    }
    int loop_status = event_loop(&daemon);
    cleanup_daemon(&daemon, socket_path);
    return loop_status == 0 ? 0 : 1;
}
