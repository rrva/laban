#include "labpty_byte_ring.h"

#include <stdatomic.h>

static uint64_t mono_ns(void) {
    struct timespec ts;
    assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    assert(ts.tv_nsec >= 0);
    return ((uint64_t)ts.tv_sec * 1000000000ull) + (uint64_t)ts.tv_nsec;
}

static uint64_t unix_ns(void) {
    struct timespec ts;
    assert(clock_gettime(CLOCK_REALTIME, &ts) == 0);
    assert(ts.tv_nsec >= 0);
    return ((uint64_t)ts.tv_sec * 1000000000ull) + (uint64_t)ts.tv_nsec;
}

static bool is_power_of_two(uint64_t value) {
    return value > 0 && (value & (value - 1)) == 0;
}

static uint64_t fnv1a64(const char *value) {
    assert(value != NULL);
    uint64_t hash = 0xcbf29ce484222325ull;
    /* Bound the index check first so a caller passing a non-NUL-terminated
     * buffer (theoretically impossible since logical_id is snprintf'd into
     * a fixed-size buffer, but defensive) cannot read past LABPTY_LOGICAL_ID_BYTES. */
    for (size_t i = 0; i < LABPTY_LOGICAL_ID_BYTES && value[i] != '\0'; i++) {
        hash ^= (uint8_t)value[i];
        hash *= 0x100000001b3ull;
    }
    return hash;
}

static void store_u64(uint8_t *base, uint64_t offset, uint64_t value) {
    assert(base != NULL);
    assert((offset % 8) == 0);
    _Atomic uint64_t *slot = (_Atomic uint64_t *)(void *)(base + offset);
    atomic_store_explicit(slot, value, memory_order_release);
}

static void store_u32_plain(uint8_t *base, uint64_t offset, uint32_t value) {
    assert(base != NULL);
    assert(offset < LABPTY_HEADER_BYTES);
    base[offset + 0] = (uint8_t)(value & 0xFF);
    base[offset + 1] = (uint8_t)((value >> 8) & 0xFF);
    base[offset + 2] = (uint8_t)((value >> 16) & 0xFF);
    base[offset + 3] = (uint8_t)((value >> 24) & 0xFF);
}

static void store_u64_plain(uint8_t *base, uint64_t offset, uint64_t value) {
    assert(base != NULL);
    assert(offset < LABPTY_HEADER_BYTES);
    for (int i = 0; i < 8; i++) base[offset + (uint64_t)i] = (uint8_t)((value >> (i * 8)) & 0xFF);
}

/* Header field offsets, in bytes from the start of the mapping. The
 * Swift reader rediscovers most of these dynamically from the
 * header_bytes / counters_offset / reader_slot_* fields (commit
 * bef1e97), so the byte positions below are the daemon's source of
 * truth for the wire layout. Keep these mirrored with
 * Sources/LabanCore/LabptyByteRingLayout.swift's outputBytesWrittenTotalOffset
 * et al for the counters region (which starts at byte 128). */
enum {
    BR_OFF_MAGIC                  = 0,    /* 8 bytes: "LBPTY-BR" */
    BR_OFF_ABI_MAJOR              = 8,    /* u32 */
    BR_OFF_ABI_MINOR              = 12,   /* u32 */
    BR_OFF_HEADER_BYTES           = 16,   /* u32 */
    BR_OFF_COUNTERS_OFFSET        = 20,   /* u32 */
    BR_OFF_READER_SLOT_OFFSET     = 24,   /* u32 */
    BR_OFF_READER_SLOT_BYTES      = 28,   /* u32 */
    BR_OFF_READER_SLOT_COUNT      = 32,   /* u32 */
    BR_OFF_INPUT_RING_OFFSET      = 40,   /* u64 */
    BR_OFF_INPUT_RING_CAPACITY    = 48,   /* u64 (always 0 in Phase 1) */
    BR_OFF_OUTPUT_RING_OFFSET     = 56,   /* u64 */
    BR_OFF_OUTPUT_RING_CAPACITY   = 64,   /* u64 */
    BR_OFF_METADATA_RING_OFFSET   = 72,   /* u64 */
    BR_OFF_METADATA_RING_CAPACITY = 80,   /* u64 (always 0 in Phase 1) */
    BR_OFF_SESSION_HASH           = 88,   /* u64 (fnv1a64 of logical_id) */
    BR_OFF_PRODUCER_PID           = 96,   /* u32 */
    BR_OFF_CREATED_AT_UNIX_NS     = 104,  /* u64 */
};

static void initialize_header(labpty_byte_ring_writer_t *writer, const char *logical_id) {
    assert(writer != NULL);
    assert(writer->map != NULL);
    memcpy(writer->map + BR_OFF_MAGIC, labpty_ring_magic, 8);
    store_u32_plain(writer->map, BR_OFF_ABI_MAJOR,              1);
    store_u32_plain(writer->map, BR_OFF_ABI_MINOR,              0);
    store_u32_plain(writer->map, BR_OFF_HEADER_BYTES,           LABPTY_HEADER_BYTES);
    store_u32_plain(writer->map, BR_OFF_COUNTERS_OFFSET,        LABPTY_COUNTERS_OFFSET);
    store_u32_plain(writer->map, BR_OFF_READER_SLOT_OFFSET,     LABPTY_READER_SLOT_OFFSET);
    store_u32_plain(writer->map, BR_OFF_READER_SLOT_BYTES,      LABPTY_READER_SLOT_BYTES);
    store_u32_plain(writer->map, BR_OFF_READER_SLOT_COUNT,      LABPTY_READER_SLOT_COUNT);
    store_u64_plain(writer->map, BR_OFF_INPUT_RING_OFFSET,      LABPTY_INPUT_RING_OFFSET);
    store_u64_plain(writer->map, BR_OFF_INPUT_RING_CAPACITY,    0);
    store_u64_plain(writer->map, BR_OFF_OUTPUT_RING_OFFSET,     writer->output_ring_offset);
    store_u64_plain(writer->map, BR_OFF_OUTPUT_RING_CAPACITY,   writer->output_capacity);
    store_u64_plain(writer->map, BR_OFF_METADATA_RING_OFFSET,   writer->output_ring_offset + writer->output_capacity);
    store_u64_plain(writer->map, BR_OFF_METADATA_RING_CAPACITY, 0);
    store_u64_plain(writer->map, BR_OFF_SESSION_HASH,           fnv1a64(logical_id));
    store_u32_plain(writer->map, BR_OFF_PRODUCER_PID,           (uint32_t)getpid());
    store_u64_plain(writer->map, BR_OFF_CREATED_AT_UNIX_NS,     unix_ns());
}

labpty_status_t labpty_byte_ring_create(
    const char *path,
    uint64_t output_capacity,
    const char *logical_id,
    labpty_byte_ring_writer_t *out
) {
    assert(path != NULL);
    assert(logical_id != NULL);
    assert(out != NULL);
    memset(out, 0, sizeof(*out));
    out->fd = -1;
    snprintf(out->path, sizeof(out->path), "%s", path);
    if (!is_power_of_two(output_capacity)) return LABPTY_E_PAYLOAD_TOO_LARGE;
    if (output_capacity < LABPTY_MIN_OUTPUT_CAPACITY) return LABPTY_E_PAYLOAD_TOO_LARGE;
    if (output_capacity > LABPTY_MAX_OUTPUT_CAPACITY) return LABPTY_E_PAYLOAD_TOO_LARGE;
    out->fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (out->fd < 0) return LABPTY_E_RING_MAP_FAILED;
    out->output_capacity = output_capacity;
    out->output_ring_offset = LABPTY_INPUT_RING_OFFSET;
    out->map_len = (size_t)(out->output_ring_offset + output_capacity);
    if (ftruncate(out->fd, (off_t)out->map_len) != 0) {
        close(out->fd);
        out->fd = -1;
        unlink(out->path);
        return LABPTY_E_RING_MAP_FAILED;
    }
    out->map = mmap(NULL, out->map_len, PROT_READ | PROT_WRITE, MAP_SHARED, out->fd, 0);
    if (out->map == MAP_FAILED) {
        out->map = NULL;
        close(out->fd);
        out->fd = -1;
        unlink(out->path);
        return LABPTY_E_RING_MAP_FAILED;
    }
    /* Pin the ring in RAM so the writer never page-faults under load.
     * Best-effort — mlock can fail with ENOMEM if the system limit
     * (RLIMIT_MEMLOCK) is reached. The ring still works without it, just
     * with potentially higher tail latency. munmap implicitly munlocks,
     * so labpty_byte_ring_close needs no paired call. */
    (void)mlock(out->map, out->map_len);
    memset(out->map, 0, out->map_len);
    initialize_header(out, logical_id);
    labpty_byte_ring_heartbeat(out);
    return LABPTY_OK;
}

void labpty_byte_ring_close(labpty_byte_ring_writer_t *writer) {
    assert(writer != NULL);
    assert(writer->fd >= -1);
    if (writer->map && writer->map != MAP_FAILED) munmap(writer->map, writer->map_len);
    if (writer->fd >= 0 && writer->path[0]) close(writer->fd);
    if (writer->path[0]) unlink(writer->path);
    writer->map = NULL;
    writer->fd = -1;
}

/* Modelled by specs/labpty/LabptyByteRing.tla::WriteCells + WritePublish.
 * NoTornRead and WindowDoesNotContainFutureWrites hold whenever the
 * readable window leaves a margin of at least MaxWriteSize bytes;
 * MC_ByteRing_Boundary.cfg pins the torn-read counter-example at margin = 1. */
labpty_status_t labpty_byte_ring_write(labpty_byte_ring_writer_t *writer, const uint8_t *bytes, size_t len) {
    assert(writer != NULL);
    assert(bytes != NULL || len == 0);
    if (!writer->map || writer->output_capacity == 0) return LABPTY_E_RING_MAP_FAILED;
    size_t retained = len;
    const uint8_t *source = bytes;
    if ((uint64_t)retained > writer->output_capacity) {
        retained = (size_t)writer->output_capacity;
        source = bytes + (len - retained);
    }
    uint64_t next_offset = writer->output_offset + (uint64_t)len;
    uint64_t retained_start = next_offset - (uint64_t)retained;
    uint64_t pos = retained_start & (writer->output_capacity - 1);
    uint8_t *ring = writer->map + writer->output_ring_offset;
    size_t first = retained;
    if (pos + retained > writer->output_capacity) first = (size_t)(writer->output_capacity - pos);
    if (first > 0) memcpy(ring + pos, source, first);
    if (retained > first) memcpy(ring, source + first, retained - first);
    writer->output_offset = next_offset;
    uint64_t wraps = writer->output_offset / writer->output_capacity;
    store_u64(writer->map, 128, writer->output_offset);
    store_u64(writer->map, 144, wraps);
    labpty_byte_ring_heartbeat(writer);
    return LABPTY_OK;
}

void labpty_byte_ring_heartbeat(labpty_byte_ring_writer_t *writer) {
    assert(writer != NULL);
    assert(writer->map != NULL || writer->fd < 0);
    if (!writer->map) return;
    store_u64(writer->map, 160, mono_ns());
}
