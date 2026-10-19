# nabu-linux-overlay

Companion repository for the Xiaomi Pad 5 (nabu) Linux port: the **documentation and tooling**
that do not belong in any single kernel-module repository.

The build itself lives in [`nabu-main`](https://github.com/CFM880/nabu-main); the kernel and
device support live in the `nabu-*` module repositories. This repo collects the cross-cutting
material that used to sit loose next to the working tree.

## Contents

```
docs/
├── nabu-main-design.md     build/port design and the module contract rationale
├── port-7.2.7.md           the 7.2.7 port log (every change to the port is appended here)
└── KNOWN-ISSUES.md         known issues and TODO (evidence-based snapshot)
tools/
├── nabu-devcdump-capture.sh    capture GPU devcoredumps before the 5-minute timeout
├── nabu-gpu-fault-watch.sh     classify each gpu fault against the live gem map
├── nabu-gpu-dump-parse.py      parse a devcoredump: fault-info / bos / pgtable / vm-log
├── nabu-dump-search.py         search a dump for a symbol/offset
└── nabu-suspend-ab.sh          run pm_test=devices rounds per BT/UART A/B variant
```

## Relationship to the build

| Repository | Role |
|---|---|
| [`nabu-main`](https://github.com/CFM880/nabu-main) | pipeline, `repos.lock`, products, packaging |
| `nabu-platform` / `nabu-display` / `nabu-touchscreen` / `nabu-iris` / `nabu-camera` / `nabu-audio` / `nabu-accelerometer` / `nabu-power` | module overlays and contracts |
| **nabu-linux-overlay** (this repo) | documentation + debugging tooling |

See `docs/nabu-main-design.md` for how the pipeline assembles one kernel from the module
repositories, and `docs/port-7.2.7.md` for the current port state.
