# nabu debugging tools

Small host-side helpers used while chasing the suspend/resume problems.  All of
them are *debug* tools: nothing here ships in the image, and nothing changes the
kernel by itself.

| Tool | What it does |
|---|---|
| `nabu-install-uki.sh` | put a UKI on the tablet's ESP. The sudo password comes from `NABU_PW` (it now fails fast instead of sending an empty password when there is no terminal), and after the reboot it prints the *live* `/proc/cmdline` so you can see the installed kernel really booted. The ESP cannot be mounted (`-EIO`) and mtools refuses it directly (hidden-sector mismatch), so this copies the partition to a file, `mcopy`s the UKI into it and writes it back, keeping the file as a full ESP backup. Pushes with `ssh 'cat >'` because minimal images lack `openssh-sftp-server` (which breaks `scp`). |
| `nabu-serial-console.sh` | keep the USB-gadget console (`console=ttyGS0`, `/dev/ttyACM0` on the host) readable: reopens across unplug/replug, appends to a log. It dies with dwc3 when the device suspends, so it shows the boot log, `suspend_prepare()` and a *successful* resume - never a wedge. |
| `nabu-suspend-ab-loop.sh` | run real `systemctl suspend` cycles against the tablet over SSH and count wedges by `boot_id`: same boot after a round = it resumed, different = it had to be reset. Ignores sleep inhibitors, keeps a BT scan running, disables the desktop's idle suspend. |
| `nabu-suspend-stackwatch.sh` | userspace watchdog: triggers SysRq-w/-t and copies the kernel log to disk when a suspend never returns. Only useful for a stall *before* the task freeze; the filesystem and the disk are frozen afterwards, so it cannot see a device-phase wedge. |
| `wake-diag/` | kernel module (built into the test UKI, or `insmod` with a matching vermagic) that logs the PMIC pwrkey IRQ arming at `PM_SUSPEND_PREPARE`, snapshots the PON registers, and runs a non-freezable heartbeat thread to `/var/log/nabu-wake-hb.txt`. |

## Things the tools learned the hard way

- **A wedge after the task freeze cannot be logged to disk.** The kernel freezes
  filesystems *and* suspends the disk (UFS), `pstore/ramoops` does not survive
  the reset on this tablet, and the only console is the USB gadget, which dies
  with dwc3. A heartbeat thread keeps running (it is not freezable) but its
  `write()` blocks on the frozen filesystem, so the file just stops at the
  freeze. Everything written *before* `PM_SUSPEND_PREPARE` is persisted, which
  is why the diagnostics live there.
- **The ESP install path matters**: the UKI lives at `EFI/debian/nabu-debian.efi`
  (not `debian/…` at the root), and a half-written UKI on a full ESP silently
  leaves the tablet booting the previous kernel. Keep at most one backup on the
  ESP; `nabu-install-uki.sh` keeps one in `/tmp` instead.
- **`scp` is not available** on the minimal rootfs; use `ssh 'cat >'`.
- **`ignore_loglevel` floods the gadget console** and the host side drops bytes
  (`[missed … bytes]`), which is exactly the part of a crash trace you want. Use
  `loglevel=4` when capturing crashes over the console.
- **Never `pkill -f` a script name from inside a shell whose command line
  contains that name** - it matches itself and kills your own session. Use the
  bracketed pattern (`pgrep -f '[n]abu…'`) plus an explicit `kill <pid>`.
