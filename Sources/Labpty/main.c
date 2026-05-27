#include "labpty_registry.h"

typedef struct {
    int listen_fd;
    int clients[LABPTY_MAX_CLIENTS];
    labpty_registry_t registry;
    labpty_open_request_t open_request;
    uint8_t frame[LABPTY_MAX_FRAME];
    uint8_t response[LABPTY_MAX_FRAME];
    uint8_t read_buffer[LABPTY_READ_BUFFER_BYTES];
} labpty_daemon_t;

static void usage(void) {
    fputs("usage: labpty --socket PATH --shm-dir PATH\n", stderr);
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
    assert(fd < FD_SETSIZE);
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int listen_unix_socket(const char *path) {
    assert(path != NULL);
    assert(path[0] != '\0');
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        close(fd);
        return -1;
    }
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) return -1;
    if (listen(fd, 16) != 0) return -1;
    return fd;
}

static ssize_t read_exact(int fd, uint8_t *buf, size_t len) {
    assert(fd >= 0);
    assert(buf != NULL || len == 0);
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, buf + got, len - got);
        if (n == 0) return 0;
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { usleep(1000); continue; }
        if (n < 0) return -1;
        got += (size_t)n;
    }
    return (ssize_t)got;
}

static int write_exact(int fd, const uint8_t *buf, size_t len) {
    assert(fd >= 0);
    assert(buf != NULL || len == 0);
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, buf + sent, len - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { usleep(1000); continue; }
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static int send_response(int fd, labpty_frame_header_t request, labpty_status_t code, const uint8_t *payload, size_t len) {
    assert(fd >= 0);
    assert(len <= LABPTY_MAX_FRAME - LABPTY_FRAME_HEADER_BYTES);
    uint8_t header[LABPTY_FRAME_HEADER_BYTES];
    labpty_frame_header_t response = {
        .abi_major = 1,
        .abi_minor = 0,
        .frame_len = (uint32_t)(LABPTY_FRAME_HEADER_BYTES + len),
        .op = LABPTY_OP_RESPONSE,
        .code = (uint16_t)code,
        .seq = request.seq,
    };
    if (labpty_encode_header(header, sizeof(header), &response) != LABPTY_OK) return -1;
    if (write_exact(fd, header, sizeof(header)) != 0) return -1;
    return len == 0 ? 0 : write_exact(fd, payload, len);
}

static int read_frame(int fd, uint8_t *buffer, labpty_frame_header_t *header) {
    assert(fd >= 0);
    assert(buffer != NULL);
    ssize_t n = read_exact(fd, buffer, LABPTY_FRAME_HEADER_BYTES);
    if (n <= 0) return (int)n;
    labpty_status_t status = labpty_decode_header(buffer, LABPTY_FRAME_HEADER_BYTES, header);
    if (status != LABPTY_OK) return -1;
    size_t body_len = (size_t)header->frame_len - LABPTY_FRAME_HEADER_BYTES;
    if (body_len == 0) return 1;
    n = read_exact(fd, buffer + LABPTY_FRAME_HEADER_BYTES, body_len);
    return n <= 0 ? (int)n : 1;
}

static void add_client(labpty_daemon_t *daemon) {
    assert(daemon != NULL);
    assert(daemon->listen_fd >= 0);
    int fd = accept(daemon->listen_fd, NULL, NULL);
    if (fd < 0) return;
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        if (daemon->clients[i] < 0) {
            daemon->clients[i] = fd;
            return;
        }
    }
    close(fd);
}

static size_t encode_descriptor_payload(labpty_session_t *session, uint8_t *out, size_t cap) {
    assert(session != NULL);
    assert(out != NULL);
    labpty_writer_t writer = { .cur = out, .end = out + cap };
    labpty_descriptor_view_t descriptor = labpty_session_descriptor(session);
    if (labpty_encode_descriptor(&writer, &descriptor) != LABPTY_OK) return 0;
    return (size_t)(writer.cur - out);
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

static labpty_status_t handle_open(labpty_daemon_t *daemon, const uint8_t *payload, size_t len, size_t *out_len) {
    assert(daemon != NULL);
    assert(out_len != NULL);
    labpty_status_t status = labpty_decode_open_request(payload, len, &daemon->open_request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = NULL;
    status = labpty_registry_open(&daemon->registry, &daemon->open_request, &session);
    if (status != LABPTY_OK) return status;
    *out_len = encode_descriptor_payload(session, daemon->response, LABPTY_MAX_FRAME);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

static labpty_status_t handle_resize(labpty_daemon_t *daemon, const uint8_t *payload, size_t len, size_t *out_len) {
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
    *out_len = encode_descriptor_payload(session, daemon->response, LABPTY_MAX_FRAME);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

static labpty_status_t handle_signal(labpty_daemon_t *daemon, const uint8_t *payload, size_t len, size_t *out_len) {
    assert(daemon != NULL);
    labpty_signal_request_t request;
    labpty_status_t status = labpty_decode_signal_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    if (!session || !session->alive) return LABPTY_E_SESSION_NOT_FOUND;
    if (killpg(session->child_pid, request.signo) != 0) return LABPTY_E_INTERNAL;
    *out_len = encode_descriptor_payload(session, daemon->response, LABPTY_MAX_FRAME);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

static labpty_status_t handle_terminate(labpty_daemon_t *daemon, const uint8_t *payload, size_t len, size_t *out_len) {
    assert(daemon != NULL);
    labpty_handle_request_t request;
    labpty_status_t status = labpty_decode_handle_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    if (!session) return LABPTY_E_SESSION_NOT_FOUND;
    labpty_session_close(session);
    *out_len = encode_descriptor_payload(session, daemon->response, LABPTY_MAX_FRAME);
    return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
}

static labpty_status_t handle_write(labpty_daemon_t *daemon, const uint8_t *payload, size_t len) {
    assert(daemon != NULL);
    labpty_write_input_request_t request;
    labpty_status_t status = labpty_decode_write_input_request(payload, len, &request);
    if (status != LABPTY_OK) return status;
    labpty_session_t *session = labpty_registry_find(&daemon->registry, request.handle);
    if (!session || !session->alive) return LABPTY_E_SESSION_NOT_FOUND;
    if (write_exact(session->master_fd, request.bytes, request.len) != 0) return LABPTY_E_INTERNAL;
    return LABPTY_OK;
}

static labpty_status_t dispatch(labpty_daemon_t *daemon, labpty_frame_header_t header, size_t *out_len) {
    assert(daemon != NULL);
    assert(out_len != NULL);
    const uint8_t *payload = daemon->frame + LABPTY_FRAME_HEADER_BYTES;
    size_t len = (size_t)header.frame_len - LABPTY_FRAME_HEADER_BYTES;
    *out_len = 0;
    if (header.op == LABPTY_OP_HELLO) return labpty_encode_hello_response(daemon->response, LABPTY_MAX_FRAME, out_len);
    if (header.op == LABPTY_OP_OPEN_SESSION) return handle_open(daemon, payload, len, out_len);
    if (header.op == LABPTY_OP_LIST_SESSIONS) {
        *out_len = encode_list_payload(&daemon->registry, daemon->response, LABPTY_MAX_FRAME);
        return *out_len > 0 ? LABPTY_OK : LABPTY_E_INTERNAL;
    }
    if (header.op == LABPTY_OP_RESIZE_SESSION) return handle_resize(daemon, payload, len, out_len);
    if (header.op == LABPTY_OP_SIGNAL_SESSION) return handle_signal(daemon, payload, len, out_len);
    if (header.op == LABPTY_OP_TERMINATE_SESSION) return handle_terminate(daemon, payload, len, out_len);
    if (header.op == LABPTY_OP_WRITE_INPUT) return handle_write(daemon, payload, len);
    if (header.op == LABPTY_OP_PING) return labpty_encode_ping_response(daemon->response, LABPTY_MAX_FRAME, out_len);
    return LABPTY_E_VERSION_MISMATCH;
}

static void handle_client(labpty_daemon_t *daemon, int index) {
    assert(daemon != NULL);
    assert(index >= 0 && index < LABPTY_MAX_CLIENTS);
    int fd = daemon->clients[index];
    labpty_frame_header_t header;
    int r = read_frame(fd, daemon->frame, &header);
    if (r <= 0 || header.op == LABPTY_OP_RESPONSE) {
        close(fd);
        daemon->clients[index] = -1;
        return;
    }
    size_t response_len = 0;
    labpty_status_t status = dispatch(daemon, header, &response_len);
    if (send_response(fd, header, status, daemon->response, response_len) != 0) {
        close(fd);
        daemon->clients[index] = -1;
    }
}

static void drain_session(labpty_daemon_t *daemon, labpty_session_t *session) {
    assert(daemon != NULL);
    assert(session != NULL);
    ssize_t n = read(session->master_fd, daemon->read_buffer, sizeof(daemon->read_buffer));
    if (n > 0) {
        labpty_byte_ring_write(&session->ring, daemon->read_buffer, (size_t)n);
    } else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
        close(session->master_fd);
        session->master_fd = -1;
        session->alive = 0;
    }
}

static int build_fd_set(labpty_daemon_t *daemon, fd_set *fds) {
    assert(daemon != NULL);
    assert(fds != NULL);
    FD_ZERO(fds);
    FD_SET(daemon->listen_fd, fds);
    int max_fd = daemon->listen_fd;
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
        int fd = daemon->clients[i];
        if (fd >= 0) { FD_SET(fd, fds); if (fd > max_fd) max_fd = fd; }
    }
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &daemon->registry.sessions[i];
        if (s->used && s->alive && s->master_fd >= 0) { FD_SET(s->master_fd, fds); if (s->master_fd > max_fd) max_fd = s->master_fd; }
    }
    return max_fd;
}

static void tick_heartbeats(labpty_daemon_t *daemon) {
    assert(daemon != NULL);
    assert(daemon->listen_fd >= 0);
    for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
        labpty_session_t *s = &daemon->registry.sessions[i];
        if (s->used && s->alive) labpty_byte_ring_heartbeat(&s->ring);
    }
}

static void event_loop(labpty_daemon_t *daemon) {
    assert(daemon != NULL);
    assert(daemon->listen_fd >= 0);
    while (1) {
        fd_set fds;
        int max_fd = build_fd_set(daemon, &fds);
        struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };
        int ready = select(max_fd + 1, &fds, NULL, NULL, &tv);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) break;
        if (FD_ISSET(daemon->listen_fd, &fds)) add_client(daemon);
        for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) {
            if (daemon->clients[i] >= 0 && FD_ISSET(daemon->clients[i], &fds)) handle_client(daemon, i);
        }
        for (int i = 0; i < LABPTY_MAX_SESSIONS; i++) {
            labpty_session_t *s = &daemon->registry.sessions[i];
            if (s->used && s->alive && s->master_fd >= 0 && FD_ISSET(s->master_fd, &fds)) drain_session(daemon, s);
        }
        tick_heartbeats(daemon);
        labpty_registry_reap(&daemon->registry);
    }
}

int main(int argc, char **argv) {
    char socket_path[LABPTY_PATH_BYTES + 1];
    char shm_dir[LABPTY_PATH_BYTES + 1];
    if (parse_args(argc, argv, socket_path, shm_dir) != 0) { usage(); return 64; }
    signal(SIGPIPE, SIG_IGN);
    if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0) { /* best effort on developer machines */ }
    mkdir(shm_dir, 0700);
    labpty_daemon_t daemon;
    memset(&daemon, 0, sizeof(daemon));
    for (int i = 0; i < LABPTY_MAX_CLIENTS; i++) daemon.clients[i] = -1;
    labpty_registry_init(&daemon.registry, shm_dir);
    daemon.listen_fd = listen_unix_socket(socket_path);
    if (daemon.listen_fd < 0) { perror("labpty listen"); return 1; }
    set_nonblock(daemon.listen_fd);
    event_loop(&daemon);
    return 0;
}
