#!/usr/bin/env python3
"""Parse an msm/freedreno GPU devcoredump (YAML-ish, !!ascii85 blobs ignored).

Prints:
  * header (kernel, comm/cmdline of the offending task)
  * fault-info / pgtable-fault-info (only present on SMMU fault dumps)
  * the "bos:" list (the offending VM's buffers) with, when a faulting IOVA is
    known, which BO contains it / the nearest BOs around it
  * the "vm-log:" map/unmap history (present when msm.vm_log_shift>0), filtered
    to the ops overlapping the faulting IOVA.

Usage: nabu-gpu-dump-parse.py <dump.txt> [iova-hex]
"""
import re
import sys

BO_START = re.compile(r"^\s*-\s*iova:\s*(0x[0-9a-fA-F]+)")
VMLOG = re.compile(
    r"^\s*-\s*([A-Za-z_]+):(-?\d+):\s*"
    r"(0x[0-9a-fA-F]+)-(0x[0-9a-fA-F]+)(?:\s+(\d+))?\s*$")


def parse(path):
    header, fault, pgfault = {}, {}, {}
    bos, vmlog = [], []
    section = None
    cur = None

    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")

            m = re.match(r"^([A-Za-z][\w-]*):\s*$", line)
            if m:
                section = m.group(1)
                cur = None
                continue

            if section is None:
                m = re.match(r"^([A-Za-z][\w-]*):\s*(.*)$", line)
                if m:
                    header[m.group(1)] = m.group(2)

            if section == "fault-info":
                m = re.match(r"^\s*-\s*(\w+)=(.*)$", line)
                if m:
                    fault[m.group(1)] = m.group(2)
            elif section == "pgtable-fault-info":
                m = re.match(r"^\s*-\s*(\w+):\s*(.*)$", line)
                if m:
                    pgfault[m.group(1)] = m.group(2)
            elif section == "vm-log":
                m = VMLOG.match(line)
                if m:
                    vmlog.append((m.group(1), int(m.group(2)),
                                  int(m.group(3), 16), int(m.group(4), 16),
                                  int(m.group(5)) if m.group(5) else 0))
            elif section == "bos":
                m = BO_START.match(line)
                if m:
                    cur = {"iova": int(m.group(1), 16), "size": 0,
                           "flags": None, "name": ""}
                    bos.append(cur)
                    continue
                if cur is not None:
                    m = re.match(r"^\s+size:\s*(\d+)", line)
                    if m:
                        cur["size"] = int(m.group(1))
                        continue
                    m = re.match(r"^\s+flags:\s*(0x[0-9a-fA-F]+)", line)
                    if m:
                        cur["flags"] = m.group(1)
                        continue
                    m = re.match(r"^\s+name:\s*(.*)$", line)
                    if m:
                        cur["name"] = m.group(1).strip()
    return header, fault, pgfault, bos, vmlog


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: nabu-gpu-dump-parse.py <dump.txt> [iova-hex]")
    path = sys.argv[1]
    header, fault, pgfault, bos, vmlog = parse(path)

    print(f"== file: {path}")
    for k in ("kernel", "comm", "cmdline", "rbbm-status",
              "gpu-initialized", "revision"):
        if k in header:
            print(f"  {k}: {header[k]}")

    if fault:
        print("\n== fault-info (SMMU page fault path)")
        for k, v in fault.items():
            print(f"  {k}: {v}")
    else:
        print("\n== no fault-info (hang/recover dump, fault task unknown)")

    if pgfault:
        print("\n== pgtable-fault-info")
        for k, v in pgfault.items():
            print(f"  {k}: {v}")

    iova = int(sys.argv[2], 16) if len(sys.argv) > 2 else None
    if iova is None and fault.get("iova"):
        iova = int(fault["iova"], 16)

    print(f"\n== bos: {len(bos)} entries")
    for b in sorted(bos, key=lambda b: b["iova"]):
        if iova is not None and not (b["iova"] <= iova + 0x100000
                                     and b["iova"] + b["size"] >= iova - 0x100000):
            # only show BOs near the fault (or everything if no fault)
            continue
        print(f"  0x{b['iova']:012x}-0x{b['iova']+b['size']:012x} "
              f"{b['size']:>9}  flags={b['flags']}  {b['name']}")

    if iova is not None:
        print(f"\n== fault iova = 0x{iova:012x}")
        containing = [b for b in bos
                      if b["iova"] <= iova < b["iova"] + b["size"]]
        below = [b for b in bos if b["iova"] + b["size"] <= iova]
        above = [b for b in bos if b["iova"] > iova]
        if containing:
            for b in containing:
                print(f"  CONTAINED in BO 0x{b['iova']:012x} "
                      f"size={b['size']} at offset +0x{iova-b['iova']:x}")
        else:
            print("  NOT within any listed BO")
            if below:
                b = below[-1]
                print(f"  nearest below: 0x{b['iova']:012x} "
                      f"size={b['size']} end=0x{b['iova']+b['size']:012x} "
                      f"-> gap +0x{iova-(b['iova']+b['size']):x}")
            if above:
                b = above[0]
                print(f"  nearest above: 0x{b['iova']:012x} "
                      f"size={b['size']} -> gap -0x{b['iova']-iova:x}")

    print(f"\n== vm-log: {len(vmlog)} entries"
          + ("" if vmlog else "  (set msm.vm_log_shift=8 to populate)"))
    if vmlog:
        if iova is not None:
            hit = [e for e in vmlog if e[2] <= iova < e[3]]
            print(f"  ops overlapping 0x{iova:012x}: {len(hit)}")
            for op, q, a, b, t in hit:
                print(f"    {op}:{q}  0x{a:012x}-0x{b:012x}  t={t}")
        for op, q, a, b, t in vmlog[-12:]:
            print(f"    {op}:{q}  0x{a:012x}-0x{b:012x}  t={t}")


if __name__ == "__main__":
    main()
