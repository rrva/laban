#ifndef LABPTY_INTERNAL_H
#define LABPTY_INTERNAL_H

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "LabanTerminalCore.h"

/* Apple-shipped clang ships <ptrcheck.h> as part of the toolchain. When
 * -fbounds-safety is enabled, the macros below (__sized_by, __counted_by,
 * __single) expand to attributes that statically check buffer bounds at
 * call sites and emit runtime traps on violation; when disabled (the
 * default for our SwiftPM build) they expand to nothing, so the
 * annotations are zero-cost documentation. Falls back to empty defines
 * if the header is somehow missing. */
#if __has_include(<ptrcheck.h>)
#include <ptrcheck.h>
#endif
#ifndef __sized_by
#define __sized_by(N)
#endif
#ifndef __counted_by
#define __counted_by(N)
#endif
#ifndef __single
#define __single
#endif

#include "labpty_contracts.h"

enum {
    LABPTY_MAX_FRAME = 128 * 1024,
    LABPTY_FRAME_HEADER_BYTES = 24,
    LABPTY_MAX_SESSIONS = 64,
    LABPTY_MAX_CLIENTS = 8,
    LABPTY_ARGV_MAX = 64,
    LABPTY_ARG_BYTES = 4096,
    LABPTY_ENVP_MAX = 256,
    LABPTY_ENV_BYTES = 4352,
    LABPTY_CWD_BYTES = 4096,
    LABPTY_LOGICAL_ID_BYTES = 256,
    /* Max writeInput payload (decode_write_input_request rejects larger). Also
     * sizes the per-session pending-input buffer that lets handle_write stage a
     * slow consumer's tail and drain it on POLLOUT instead of blocking. */
    LABPTY_WRITE_INPUT_MAX = 64 * 1024,
    LABPTY_PATH_BYTES = 1024,
    LABPTY_READ_BUFFER_BYTES = 4096,
    LABPTY_DEFAULT_OUTPUT_CAPACITY = 8 * 1024 * 1024,
    LABPTY_MIN_OUTPUT_CAPACITY = 256 * 1024,
    LABPTY_MAX_OUTPUT_CAPACITY = 64 * 1024 * 1024,
    LABPTY_OUTPUT_READ_SAFETY_MARGIN_BYTES = 64 * 1024,
    LABPTY_READER_SLOT_BYTES = 64,
    LABPTY_READER_SLOT_COUNT = 8,
    LABPTY_HEADER_BYTES = 128,
    LABPTY_COUNTERS_OFFSET = 128,
    LABPTY_READER_SLOT_OFFSET = 256,
    LABPTY_INPUT_RING_OFFSET = 768,
};

typedef enum {
    LABPTY_OK = 0,
    LABPTY_E_SESSION_NOT_FOUND = 0x0001,
    LABPTY_E_SESSION_ID_IN_USE = 0x0002,
    LABPTY_E_PTY_OPEN_FAILED = 0x0003,
    LABPTY_E_RING_MAP_FAILED = 0x0004,
    LABPTY_E_CAPABILITY_REQUIRED = 0x0005,
    LABPTY_E_VERSION_MISMATCH = 0x0006,
    LABPTY_E_PERMISSION_DENIED = 0x0007,
    LABPTY_E_PAYLOAD_TOO_LARGE = 0x0008,
    LABPTY_E_TRUNCATED_FRAME = 0x0009,
    LABPTY_E_OVERSIZE_FRAME = 0x000A,
    LABPTY_E_INTERNAL = 0x000B,
    LABPTY_E_SHUTTING_DOWN = 0x000C,
    LABPTY_E_UNKNOWN_OP = 0x000D,
    /* Cooked-mode write rejected because the slave's line discipline
     * cannot atomically absorb the payload (rawQ + canQ + payload would
     * exceed MAX_INPUT/MAX_CANON). Externally atomic: no byte reached
     * the master. See docs/adr/0008. */
    LABPTY_E_INPUT_BACKPRESSURE = 0x000E,
} labpty_status_t;

typedef enum {
    LABPTY_OP_HELLO = 0x0001,
    LABPTY_OP_OPEN_SESSION = 0x0002,
    LABPTY_OP_LIST_SESSIONS = 0x0003,
    LABPTY_OP_RESIZE_SESSION = 0x0004,
    LABPTY_OP_SIGNAL_SESSION = 0x0005,
    LABPTY_OP_TERMINATE_SESSION = 0x0006,
    LABPTY_OP_WRITE_INPUT = 0x0007,
    LABPTY_OP_PING = 0x0008,
    LABPTY_OP_ATTACH_SESSION = 0x0009,
    LABPTY_OP_DETACH_SESSION = 0x000A,
    LABPTY_OP_OPEN_OUTPUT_WAKE = 0x000B,
    LABPTY_OP_PARK_OUTPUT_WAKE = 0x000C,
    LABPTY_OP_RESPONSE = 0xFFFF,
} labpty_op_t;

static const uint8_t labpty_frame_magic[4] = {'L', 'P', 'C', 'T'};
static const uint8_t labpty_ring_magic[8] = {'L', 'B', 'P', 'T', 'Y', '-', 'B', 'R'};

/* Keep these mirrored with Sources/LabanCore/LabptyByteRingLayout.swift. */
_Static_assert(LABPTY_HEADER_BYTES == 128, "Swift byte-ring header size mirror changed");
_Static_assert(LABPTY_COUNTERS_OFFSET == 128, "Swift byte-ring counters offset mirror changed");
_Static_assert(LABPTY_READER_SLOT_OFFSET == 256, "Swift byte-ring reader slot offset mirror changed");
_Static_assert(LABPTY_READER_SLOT_BYTES == 64, "Swift byte-ring reader slot size mirror changed");
_Static_assert(LABPTY_READER_SLOT_COUNT == 8, "Swift byte-ring reader slot count mirror changed");
_Static_assert(LABPTY_INPUT_RING_OFFSET == 768, "Swift byte-ring input ring offset mirror changed");
_Static_assert(LABPTY_MIN_OUTPUT_CAPACITY == 256 * 1024, "Swift byte-ring minimum capacity mirror changed");
_Static_assert(LABPTY_MAX_OUTPUT_CAPACITY == 64 * 1024 * 1024, "Swift byte-ring maximum capacity mirror changed");
_Static_assert(LABPTY_OUTPUT_READ_SAFETY_MARGIN_BYTES == 64 * 1024, "Swift byte-ring read safety margin mirror changed");

#endif
