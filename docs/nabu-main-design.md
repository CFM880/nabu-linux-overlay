# nabu-main design

How the Xiaomi Pad 5 (nabu) Linux kernel is assembled from independent repositories, and the
rationale behind the `nabu-module.toml` contract.

## Goals

1. **One kernel, many concerns.** Display, camera, audio, sensors, power and video decode are
   developed and reviewed separately, but must compile into a single kernel with a single DTS.
2. **Reproducible.** A commit of `nabu-main` plus `repos.lock` must rebuild the exact same tree
   from public sources, without a private fork of the kernel carrying the port as history.
3. **`nabu-main` stays generic.** It must not contain a single module name literal; everything it
   does is driven by data each module declares.

## Shape

```
parent/
├── nabu-main/          orchestration: pipeline, products, repos.lock
├── linux-7.2/          the kernel build tree (checked out at the pinned base)
├── nabu-platform/      ┐
├── nabu-display/       │
├── nabu-touchscreen/   │
├── nabu-iris/          ├─ module repositories, each with a nabu-module.toml
├── nabu-camera/        │
├── nabu-audio/         │
├── nabu-accelerometer/ │
└── nabu-power/         ┘
```

`nabu-main` finds every module through `repos.lock`; each module answers four questions through
its contract:

| Contract key | Question |
|---|---|
| `[provides]` | What do I contribute to the kernel/userspace? (overlay, DTSI, config, firmware, ...) |
| `[build]` | What must be built, and does it need a hook? |
| `[artifacts]` | Which build outputs are mine? |
| `[install]` | Where do those outputs go on the target? |

## Why overlays rather than a kernel fork

A board port is easy to do as a private kernel branch — and hard to maintain. The branch diverges,
upstream renames symbols, and the port becomes a merge conflict generator. Instead:

- `repos.lock` pins a **clean upstream base** — the 7.2.7 product pins the upstream tag `v7.2.7`.
- Each module ships a **`kernel-overlay/`**: the exact files that product needs, copied verbatim
  over the base. `apply` resets the kernel to the base, then copies each module's overlay in a
  deterministic (topologically sorted, name-stable) order.
- Nothing in the kernel tree carries port history, so the tree is disposable: `apply` can rebuild
  it from scratch at any time, and the build does not depend on a private commit range.

The trade-off is that an overlay is a full file, not a patch, so a one-line change carries the
whole file. That is deliberate: it makes `apply` a pure copy (no context-matching, no ordering
surprises) at the cost of a larger diff to review. Patches remain available via `[provides].patches`
for changes that are genuinely patch-shaped.

## Device tree composition

`sm8150-xiaomi-nabu.dts` (base, owned by `nabu-platform`) includes nothing board-specific beyond
the SoC base; each module contributes a `.dtsi`:

```
sm8150-xiaomi-nabu.dts
├── sm8150-xiaomi-nabu-iris.dtsi           (nabu-iris)
├── sm8150-xiaomi-nabu-camera.dtsi         (nabu-camera)
├── sm8150-xiaomi-nabu-accelerometer-...   (nabu-accelerometer)
└── sm8150-xiaomi-nabu-power.dtsi          (nabu-power)
```

`compose` generates the product DTS (the include list) and registers the DTB in `qcom/Makefile`
in the kernel tree. The generated file is **not** stored in any overlay — it is a product of the
module order in `products/<product>.toml`.

## Products

A product selects a subset of modules and the release/packaging metadata:

- `production-7.2` — the 7.2.7 kernel, all 8 modules, packaged as a UKI.
- `production` — the 6.14.11 kernel, same modules, pinned by `repos.lock`'s kernel base.
- `audio-only` — an iteration product building a single module against a shared `out/`.

Kernel-version-specific variants are handled by suffix: `foo-6.18.patch` / `foo-6.18.dtsi` take
precedence over the unsuffixed name, and a `foo-6.18.skip` marker skips that patch on 6.18.

## Pipeline stages

```
bootstrap → apply → compose → config → build → collect → package → verify
```

- **bootstrap** — fetch the kernel base and every module at the pinned commits (detached).
- **apply** — reset the kernel to the base, replay each module's overlay/patches.
- **compose** — generate the product DTS and register the DTB.
- **config** — defconfig + `sm8150.config` + each module's config fragments, `olddefconfig`.
- **build** — `Image`, modules, DTB, then per-module build hooks.
- **collect** — copy declared artifacts into `artifacts/<product>/`.
- **package** — assemble the UKI (Image + DTB + cmdline) with `ukify`.
- **verify** — check each `.ko`'s vermagic and the UKI contents.

## Reproducibility notes

- Module order is deterministic (topological sort, stable by name), so overlays and DTS includes
  apply in the same order everywhere.
- `repos.lock` pins commits, not branches, and `bootstrap` checks them out detached.
- The one input that is *not* fully pinned is the toolchain: kernel binaries are compiler-version
  sensitive. The 7.2.7 product is built with GCC 15; reproduce with the same major version.
