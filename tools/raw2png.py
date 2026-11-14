#!/usr/bin/env python3
"""Turns the raw picture of src/agents_spike_test.zig (`u32 w, u32 h`, then BGRA rows) into a PNG: python3 -I raw2png.py in.raw out.png"""
import struct, sys, zlib

raw = open(sys.argv[1], "rb").read()
w, h = struct.unpack("<II", raw[:8])
px = raw[8:]
rows = []
for y in range(h):
    row = bytearray(b"\0")
    line = px[y * w * 4:(y + 1) * w * 4]
    row += b"".join(line[i + 2:i + 3] + line[i + 1:i + 2] + line[i:i + 1] for i in range(0, len(line), 4))
    rows.append(bytes(row))


def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data))


open(sys.argv[2], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))
