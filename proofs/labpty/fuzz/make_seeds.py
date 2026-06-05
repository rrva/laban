#!/usr/bin/env python3
"""Generate the seed corpus for fuzz_decoders.c.

Each seed is `selector_byte || payload`, matching the harness input
layout: the first byte picks the decoder (mod 8), the rest is the op
payload fed verbatim. Valid payloads give the fuzzer good starting
coverage; it mutates outward from here. Re-run to regenerate; output is
deterministic.
"""
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")

HEADER_BYTES = 24
MAGIC = b"LPCT"


def u16(v): return struct.pack("<H", v)
def u32(v): return struct.pack("<I", v)
def i32(v): return struct.pack("<i", v)
def u64(v): return struct.pack("<Q", v)


def lp(b):
    """A length-prefixed string field: u32 length + bytes (read_string)."""
    if isinstance(b, str):
        b = b.encode()
    return u32(len(b)) + b


def header(op=2, frame_len=HEADER_BYTES, code=0, seq=0, major=1, minor=0):
    return MAGIC + u16(major) + u16(minor) + u32(frame_len) + u16(op) + u16(code) + u64(seq)


SEEDS = {
    # selector 0: frame header
    "header": bytes([0]) + header(op=2),
    # selector 1: open (rows, cols, output_capacity, argv_count=0,
    #             envp_count=0, cwd="", logical_id="")
    "open": bytes([1]) + u32(24) + u32(80) + u64(8 * 1024 * 1024)
            + u32(0) + u32(0) + lp("") + lp(""),
    # selector 2: resize (handle, rows, cols)
    "resize": bytes([2]) + u64(0) + u32(24) + u32(80),
    # selector 3: signal (handle, signo)
    "signal": bytes([3]) + u64(0) + i32(15),
    # selector 4: handle (handle)
    "handle": bytes([4]) + u64(0),
    # selector 5: write_input (handle, input_len, bytes)
    "write_input": bytes([5]) + u64(0) + u32(5) + b"hello",
    # selector 6: hello (major, minor, client_id, cap_count, the four
    #             required capabilities)
    "hello": bytes([6]) + u16(1) + u16(0) + lp("test") + u32(4)
             + lp("byte-ring/v1") + lp("write-input-rpc/v1")
             + lp("heartbeat-shm/v1") + lp("session-id-pinning/v1"),
    # selector 7: output_wake_park (count=1, handle, observed output offset)
    "output_wake_park": bytes([7]) + u32(1) + u64(0) + u64(0),
}


def main():
    os.makedirs(CORPUS, exist_ok=True)
    for name, data in SEEDS.items():
        with open(os.path.join(CORPUS, "seed_" + name), "wb") as f:
            f.write(data)
    print("wrote %d seeds to %s" % (len(SEEDS), CORPUS))


if __name__ == "__main__":
    main()
