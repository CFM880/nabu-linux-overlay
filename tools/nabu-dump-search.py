#!/usr/bin/env python3
"""Decode the !!ascii85 BO blobs in an msm GPU devcoredump and search for a
value (e.g. the faulting IOVA) to find which buffer references it.

Kernel encoder: include/linux/ascii85.h: each u32 (little-endian in memory) is
emitted as 5 chars = base85 of that integer (big-endian digits); a zero u32 is
"z".

Usage:
  nabu-dump-search.py <dump.txt> <hexvalue> [--all]
Prints, for every BO whose decoded contents contain <hexvalue> as a 32- or
64-bit little-endian word, the BO range/size/flags and the matching offsets.
"""
import re
import sys


def a85_decode(s):
    s = "".join(s.split())
    out = bytearray()
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == "z":
            out += b"\x00\x00\x00\x00"
            i += 1
            continue
        if i + 5 > n:
            break
        v = 0
        for ch in s[i:i + 5]:
            v = v * 85 + (ord(ch) - 33)
            if v > 0xFFFFFFFF:
                v &= 0xFFFFFFFF
        out += (v & 0xFFFFFFFF).to_bytes(4, "little")
        i += 5
    return bytes(out)


def parse_bos(path):
    """Yield (iova, size, flags, decoded_bytes_or_None)."""
    cur = None
    blob = []
    in_blob = False

    def flush():
        if cur is not None and cur.get("data") is not None:
            cur["bytes"] = a85_decode("".join(blob))

    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            m = re.match(r"^\s*-\s*iova:\s*(0x[0-9a-fA-F]+)", line)
            if m:
                flush()
                if cur is not None:
                    yield cur
                cur = {"iova": int(m.group(1), 16), "size": 0,
                       "flags": None, "data": None, "bytes": None}
                blob = []
                in_blob = False
                continue
            if cur is None:
                continue
            if re.match(r"^\s+data:\s*!!ascii85", line):
                cur["data"] = True
                in_blob = True
                continue
            if in_blob:
                # blob lines are indented; a non-indented or new "key:" ends it
                if re.match(r"^\s{2,}\S", line) and not re.match(r"^ {4}\w", line):
                    blob.append(line)
                    continue
                in_blob = False
            m = re.match(r"^\s+size:\s*(\d+)", line)
            if m:
                cur["size"] = int(m.group(1))
                continue
            m = re.match(r"^\s+flags:\s*(0x[0-9a-fA-F]+)", line)
            if m:
                cur["flags"] = m.group(1)
    flush()
    if cur is not None:
        yield cur


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: nabu-dump-search.py <dump.txt> <hexvalue>")
    path = sys.argv[1]
    val = int(sys.argv[2], 16)
    pats = []
    if val <= 0xFFFFFFFF:
        pats.append(("32", val.to_bytes(4, "little")))
    pats.append(("64", (val & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "little")))

    n = 0
    for bo in parse_bos(path):
        b = bo.get("bytes")
        if not b:
            continue
        for name, pat in pats:
            off = 0
            hits = []
            while True:
                k = b.find(pat, off)
                if k < 0:
                    break
                hits.append(k)
                off = k + 1
            if hits:
                n += 1
                print(f"BO 0x{bo['iova']:012x} size={bo['size']} flags={bo['flags']}"
                      f"  ({name}-bit LE) hits at offsets: "
                      + ", ".join(f"+0x{h:x}" for h in hits[:16])
                      + (f" ... (+{len(hits)-16} more)" if len(hits) > 16 else ""))
    if not n:
        print(f"no BO in {path} contains 0x{val:x} as 32/64-bit LE")
        print("(note: only BOs with 'data:' blobs are covered; needs rd_full=Y)")


if __name__ == "__main__":
    main()
