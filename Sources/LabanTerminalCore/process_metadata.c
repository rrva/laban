#include "session_internal.h"

static void copy_cstr(char *dst, size_t dst_cap, const char *src) {
    if (!dst || dst_cap == 0) return;
    if (!src) src = "";
    snprintf(dst, dst_cap, "%s", src);
}

static int pid_parent(pid_t pid, pid_t *out_parent) {
    if (pid <= 0 || !out_parent) return 0;
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof(info));
    int rc = proc_pidinfo((int)pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (rc != (int)sizeof(info)) return 0;
    *out_parent = (pid_t)info.pbi_ppid;
    return 1;
}

static int pid_is_descendant_or_self(pid_t pid, pid_t ancestor) {
    if (pid <= 0 || ancestor <= 0) return 0;
    for (int depth = 0; depth < 64 && pid > 1; depth++) {
        if (pid == ancestor) return 1;
        pid_t parent = -1;
        if (!pid_parent(pid, &parent)) return 0;
        if (parent <= 0 || parent == pid) return 0;
        pid = parent;
    }
    return 0;
}

int laban_session_process_metadata(
    LabanSession *s,
    int *out_child_pid,
    int *out_foreground_pid,
    char *process_buf,
    size_t process_capacity,
    char *command_buf,
    size_t command_capacity,
    char *cwd_buf,
    size_t cwd_capacity
) {
    if (out_child_pid) *out_child_pid = -1;
    if (out_foreground_pid) *out_foreground_pid = -1;
    copy_cstr(process_buf, process_capacity, "");
    copy_cstr(command_buf, command_capacity, "");
    copy_cstr(cwd_buf, cwd_capacity, "");

    if (!s) return -1;
    SESSION_LOCK(s);

    if (out_child_pid) *out_child_pid = s->child_pid;

    pid_t foreground_pid = -1;
    if (!s->fixture_mode && s->pty_fd >= 0) {
        pid_t pgrp = tcgetpgrp(s->pty_fd);
        if (pid_is_descendant_or_self(pgrp, s->child_pid)) foreground_pid = pgrp;
    }
    if (foreground_pid <= 0 && s->child_pid > 0) foreground_pid = s->child_pid;
    if (out_foreground_pid) *out_foreground_pid = foreground_pid;

    if (foreground_pid <= 0) {
        copy_cstr(cwd_buf, cwd_capacity, s->launch_cwd);
        return 0;
    }

    if (process_buf && process_capacity > 0) {
        char name[256] = {0};
        if (proc_name((int)foreground_pid, name, sizeof(name)) > 0) {
            copy_cstr(process_buf, process_capacity, name);
        }
    }

    if (command_buf && command_capacity > 0) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath((int)foreground_pid, path, sizeof(path)) > 0) {
            copy_cstr(command_buf, command_capacity, path);
        }
    }

    if (cwd_buf && cwd_capacity > 0) {
        struct proc_vnodepathinfo info;
        memset(&info, 0, sizeof(info));
        int rc = proc_pidinfo(
            (int)foreground_pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            sizeof(info)
        );
        if (rc == (int)sizeof(info) && info.pvi_cdir.vip_path[0]) {
            copy_cstr(cwd_buf, cwd_capacity, info.pvi_cdir.vip_path);
        } else {
            copy_cstr(cwd_buf, cwd_capacity, s->launch_cwd);
        }
    }

    return 0;
}

