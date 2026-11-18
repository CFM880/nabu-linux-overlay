# Port 6.18 — mainline 6.18.y for the Xiaomi Pad 5 (nabu)

Target: upstream stable **Linux 6.18.y** (locked to `v6.18.59` in
`nabu-main/repos.lock`), carried as module overlays, exactly like the 6.14 and
7.2.7 lines. `make switch LINE=6.18` puts the kernel tree, every module and
`repos.lock` on this line; each line builds in its own `out-<kernelversion>`.

## Display (solved)

The panel never lit up with the 6.18.59 display stack. Measurements on the
tablet ruled out the pieces one by one: the DSI controller was programmed
identically to 6.14 (`ctrl=0x173`, `cfg0=0x9130`, `act_h/act_v/total/hsync`
bit-identical), the PHY PLL was running (`vco=1023989648`, `muxes=0xc0`,
`pll_cntrl=0x1`) with the same byte clock (`146284235` Hz), the DPU streamed
(vblank, both INTF timing engines on), and the panel answered DCS reads
(`GET_POWER_MODE = 0x08`). What stayed black even with the DSI's own test
pattern generator was the video link itself.

The fix is to run the DSI stack of the tree that is known to drive this panel:
pmOS' `sm8150/6.18` branch (**Linux 6.18.0**). `nabu-display` 6.18.y now ships
those files verbatim as an overlay:

```
drivers/gpu/drm/msm/dsi/{dsi.c,dsi.h,dsi_cfg.c,dsi_cfg.h,dsi_host.c,dsi_manager.c}
drivers/gpu/drm/msm/dsi/phy/{dsi_phy.c,dsi_phy.h,dsi_phy_7nm.c,...}
drivers/gpu/drm/panel/panel-novatek-nt36523.c
drivers/gpu/drm/drm_notifier.c, include/drm/drm_notifier.h, drivers/gpu/drm/Makefile
```

The DPU (and the adreno GPU) stay at 6.18.59: swapping 6.18.0's DPU/DP in as
well pulls in APIs that the 6.18 stable updates removed
(`msm_dp_is_yuv_420_enabled`, the `vsync_sel` signature) and is not needed —
with the DSI overlay alone the panel shows a complete, correct image.

A partial result was useful on the way: with the DSI overlay but the 6.18.59
DPU, the left half of the panel lit up and the right half stayed black, which
localised the problem to the DSI link rather than the DPU.

Result on hardware: full 1600x2560 image, GNOME login, no DSI errors.

### Boot console (fixed 2026-11-16)

Boot messages were invisible for the first ~24 s and the panel then jumped
straight to the login.  The cause was not the display driver but the kernel
command line the image flow baked into the UKI:

```
debian/config/debian.cmdline:  ... console=ttyGS0     <- console on the USB gadget
config/production.cmdline:     ... console=tty0 ignore_loglevel
```

`make debian-img`/`debian-uki` use the former, so every flashed image sent its
console to the serial gadget.  With `console=tty0 ignore_loglevel` the panel
shows text from the first framebuffer switch:

```
[    0.43] Console: switching to colour frame buffer device 200x160   (EFI framebuffer)
[    4.64] msm_dpu: [drm] fb0: msmdrmfb frame buffer device            (DRM takes over)
```

The panel driver stays a module (`CONFIG_DRM_PANEL_NOVATEK_NT36523=m`); the
earlier attempt to build it in (`=y`) was reverted, and the ~24 s figure that
was blamed on it came from the serial console plus a stale 6.14 UKI on the ESP.

For the very first lines (bootloader and the first half second) a serial console
is still the only option.  The `serial-debug` product that carried it was
removed on 2026-11-16 (the `nabu-serial` module stays available), and tracing
now uses the `debug` product: production's modules and kernel config with
`console=tty0 console=ttyGS0 ignore_loglevel loglevel=8 initcall_debug
no_console_suspend pm_debug_messages` on the command line, its own release, its
own module tree and its own ESP entry, so the production entry stays bootable
next to whatever is being traced.  With `CONFIG_U_SERIAL_CONSOLE=y` the gadget
serial is a real printk console (`/proc/consoles` lists `ttyGS0`, kernel log says
"console [ttyGS0] enabled", and `CON_PRINTBUFFER` replays the boot ring once the
gadget enumerates), so the same log can be captured on a host with
`screen /dev/ttyACM0 115200`.

### Kernel release carries its content

`nabu-main/scripts/nabu` appends a short hash of everything that shapes the
kernel (module overlays, kernel fragments, module manifests) to the release, so
a build is `6.18.59-nabu-full-<hash>`.  Two builds with the same inputs share
`/lib/modules/<release>` and can be booted interchangeably; anything else gets
its own module tree, which is what lets a rollback kernel in the ESP keep the
modules it was built with.  The installed image keeps the previous release's
tree (Debian-style parallel kernel packages), e.g.:

```
/lib/modules/6.18.59-nabu-full              (rollback kernel)
/lib/modules/6.18.59-nabu-full-9881eaec     (current)
```

Both UKIs also carry their release in the embedded os-release, because rEFInd
titles UKIs by it and two kernels on one ESP were indistinguishable.

A rollback entry is only valid together with the module tree it was built with.
The first attempt kept a pre-hash UKI (`#342`, release `6.18.59-nabu-full`) from
an earlier image while that release's module tree had since been replaced by a
later build: the kernel booted, but it hung on `PM: suspend entry (deep)` and
never woke.  That entry was removed; with content-hashed releases the previous
kernel now always keeps the exact modules it was built with, so the previous
release (UKI + `/lib/modules/<release>`) is the entry to keep on the ESP.

### CPU model in /proc/cpuinfo

GNOME's About page reads the processor from `libgtop`, which only accepts
`model name`, `cpu`, `Processor` or `Model Name` from `/proc/cpuinfo` - keys
the arm64 kernel never prints, so the row stayed empty.  `nabu-platform` carries
an overlay of `arch/arm64/kernel/cpuinfo.c` that adds, for `qcom,sm8150` only:

```
model name	: Qualcomm Snapdragon 860 (SM8150-AC)
```

(the same thing Qualcomm's downstream kernels do).  `lscpu` already decoded
"Kryo-4XX-Gold" and the firmware SMBIOS already had the marketing name; only
`/proc/cpuinfo` was missing it.

## Other subsystems on this line

| Area | State |
|---|---|
| Touch (NT36523 SPI) | works: firmware loads, `NVTCapacitiveTouchScreen` + pen |
| Audio (WCD934x + CS35L41 + ADSP) | works: card 0 "Xiaomi Pad 5", speakers play |
| Charging (qcom_pmi8998/smb2 + LN8000) | 5 V charging at ~2.3 A / 10 W into the pack with a DCP charger; the charge pump is opt-in (`cp_enable`) — see below |
| WiFi / SSH | works |
| Fast charge | the pump correctly reports `adapter did not take 9V` for a non-QC charger; needs a QC3 adapter to verify |
| iris decode (H.264/HEVC) | works: 4K H.264 uses 0.9 s CPU vs 18.5 s software, HEVC 1080p 0.47 s; iris IRQ counts confirm the VPU does the work. VA-API (`vpu_drv_video.so`) opens `/dev/video0` "Iris Decoder" and drives the same path |
| Sensors (SSC/SNOC via SLPI) | works: accelerator, gyro, magnetometer, ambient light; GNOME auto-rotates. Required adding the SLPI protection domains to the sm8150 table in qcom_pd_mapper (see below) |
| suspend/wake | works: s2idle and, since 2026-11-11, platform `mem` (AOSS deep sleep, power key wakes it) — see below |

## Sensors

The SLPI kept crashing every ~40 s ("USER-PD DOG detects stalled
initialization") and `ssccli` never received data.  `qcom_pd_mapper` advertises
the SLPI domains for sdm845/sm8250/sm6115 but not for sm8150, although it is the
same SLPI with instance 90, so `msm/slpi/root_pd` was never announced:
fastrpc's PDR lookup failed with -ENXIO and the sensor PD could not attach.
Adding `&slpi_root_pd` and `&slpi_sensor_pd` to `sm8150_domains[]`
(overlay of `drivers/soc/qcom/qcom_pd_mapper.c` in
`nabu-accelerometer/kernel-overlay/`) fixes it: no more
SLPI crashes, all sensors report, and `net.hadess.SensorProxy` exposes
`HasAccelerometer`/`AccelerometerOrientation`, so GNOME rotates the screen.

### Charging after suspend (fixed 2026-11-12)

Plugging a plain DCP 5 V adapter after a day of suspend cycles left the tablet
*discharging while reporting "Charging"*: `battery current -0.35 A`,
`usb current_max 100 mA`.  The driver had auto-started the LN8000 charge pump
(`cp_auto = true`), the adapter cannot provide the 9 V the 2:1 pump needs
(`cp: adapter did not take 9V`), every failed attempt re-ran APSD, and the
input limit stayed collapsed at the 100 mA USB default — less than the tablet
consumes.  A reboot restored 3 A and +2.3 A charging, which is how the state
machine was identified.

Fixes in `nabu-power`/`qcom_pmi8998_charger.c`:

- the charge pump no longer starts by itself (`cp_auto = false`); the existing
  `cp_enable` attribute still allows it for adapters that do negotiate 9 V;
- the 5 V fallback (`smb2_cp_restore_5v()`) re-applies the DCP input limit
  (3 A) instead of leaving whatever the QC ramp left behind;
- a resume callback re-runs the charger detection, because the state machine
  did not survive repeated suspend cycles on its own.

Verified on `6.18.59-nabu-full`: three suspend/resume cycles with the charger
attached keep `current_max = 3 A` and +2.3…2.5 A into the pack (≈10 W).

### Auto-brightness (GNOME's own, standard interfaces)

The port does **not** ship its own brightness daemon.  The stack exposes the
standard interfaces and the desktop decides:

- backlight: `ktz8866-backlight` (`brightness`, `max_brightness = 2047`,
  linear scale) - no curve in the driver;
- ambient light: `net.hadess.SensorProxy.LightLevel` in **lux** with the usual
  claim/refcount semantics (iio-sensor-proxy, with the SSC backend patch that
  only rejects sensor noise);
- the only writer is gnome-settings-daemon, through
  `org.gnome.SettingsDaemon.Power.Screen.Brightness`, so the OSD, the slider and
  the persistence are the desktop's own.

That is also what any laptop does, and it is why `ambient-enabled` is `true` in
`config/00-nabu-desktop`: the "Automatic Screen Brightness" switch in Settings
belongs to gsd, and it works.

**Known limitation of that arrangement (measured on the tablet).** gsd's ambient
support has no lux -> brightness table; it maps relative to a reference it
re-derives from the brightness on screen:

```
percent = 100 * LightLevel / A        A = 100 * LightLevel / percent_on_screen
```

so the absolute level follows the last manual brightness, and a reference taken
in a bright room leaves the panel dim later on (23.6 lux at 53 % measured while
the room called for more).  That is gsd's design, not an interface bug.

A fixed lux -> backlight curve was implemented and evaluated on hardware and is
deliberately **not shipped**:

- feeding gsd the curve value instead of lux fixes the shape but the level is
  still scaled by `A`: after a manual change to 30 % the whole curve shrank, and
  the reference can wedge (6 % on screen while the curve wanted 60 %);
- estimating `A` from the resulting backlight makes it exact in steady light
  (69 % held for 60 s with no correction) but it wanders while the light drifts
  (81 -> 72 -> 68 -> 59 -> 68) and stalls when the light keeps changing;
- an absolute curve therefore needs a writer of its own (a user daemon) or a
  patch inside gsd.  Neither is part of this port: the extra service was
  rejected in review and a gsd patch would have to be carried against a distro
  package.

## Suspend / wake (solved: s2idle and platform `mem` deep sleep)

`systemctl suspend` (or `echo mem > /sys/power/state`) suspends all devices,
the tablet stays asleep, and **one** press of the power key wakes it with the
screen on.  Two PMIC problems had to be fixed in
carried as an overlay of `drivers/input/misc/pm8941-pwrkey.c`
(`nabu-platform/kernel-overlay/`), enabled with
`qcom,suspend-irq-mask-ms = <1000>` on `&pon_pwrkey`:

**1. The suspend-entry transient.**  A couple of milliseconds after
`PM: suspend-to-idle` the PMIC asserts `PON_RT_STS` bit0 (KPDPWR) for ~180 ms
although nobody touches the tablet, and with the IRQ armed as a wakeup source
that aborts the suspend (`PM: Triggering wakeup from IRQ 118`, then
`resume from suspend-to-idle`).  Measured identically on `6.14.11-nabu-full`,
so it is the tablet, not a 6.18 regression.  `PON_DBC_CTL` reads back `0x8`
(default 15.6 ms) even with `debounce = <250000>` in the DT, so the hardware
debounce cannot filter it.  Leaving the IRQ unarmed (`IRQF_NO_SUSPEND` without
`enable_irq_wake()`) keeps the system asleep but makes it unwakeable: once
idle, the AP never receives the PMIC interrupt at all, so a real press does
nothing.

The fix keeps the wakeup path armed and clears the PON interrupt enable in
`pm8941_pwrkey_suspend()` (`PON_INT_EN_CLR`), so the transient never becomes
an IRQ.  A 1 s timer reads `PON_RT_STS` (dropping any latch that appeared
meanwhile) and sets `PON_INT_EN_SET` again.

**2. The waking press reached userspace.**  It was reported as `KEY_POWER`, so
logind suspended again ~1.7 s after the resume completed: the screen flashed
and went dark, and a second press was needed.  The driver now consumes the
press and its release while suspended and for 500 ms after resume.

**CPU idle states and s2idle.**  The 1 s unmask above needs kernel timers to
run across s2idle, and so does every other timer-based wakeup.  s2idle freezes
the tick (`tick_freeze()`) and `cpuidle_enter_s2idle()` never calls
`tick_broadcast_enter()`, so a PSCI state with `local-timer-stop` loses every
timer armed before the suspend: the broadcast timer (`arch_mem_timer`) is
never programmed.  Measured: with the `cpu-sleep-*` states usable for s2idle
the unmask print never appeared and the tablet could not be woken.  Removing
`local-timer-stop` hangs the boot (the arch timer really does stop), so the
states carry `qcom,no-s2idle` and `cpuidle-psci` drops their `enter_s2idle`
callback (overlay of `drivers/cpuidle/cpuidle-psci.c`).  Runtime idle still
enters them (`cpu0/cpuidle/state1/usage` keeps growing) and s2idle stays in
WFI.

**Why "real" s2idle (rail collapse while suspended) does not work.**  Two
prototypes were measured, using a black-box marker in a PM8150 SDAM byte
(`sdam@b100`, offset 0x7e): it is PMIC-internal always-on RAM, so the last
value written before a hang survives an AP reset and can be read back through
`/sys/bus/nvmem/devices/spmi_sdam1/nvmem` after the hard reset.

1. Adding the missing `tick_broadcast_enter()`/`tick_broadcast_exit()` around
   the s2idle state entry (mirroring `cpuidle_enter_state()`) and removing
   `qcom,no-s2idle`: the marker stopped at "broadcast entered, state being
   entered" (0x13) and never advanced to "state returned" (0x14).  The 1 s
   unmask timer also never ran (its mark 0x02 never appeared), so the state
   was entered with the broadcast programmed and still no timer fired.

2. To separate "timers do not work" from "nothing can wake this state", the
   power key IRQ was kept enabled and non-armed (`IRQF_NO_SUSPEND` +
   `enable_irq_wake()`, handler drops the entry transient and calls
   `pm_system_wakeup()` on a real press).  The marker showed the transient
   IRQ *was* delivered at suspend entry (0x21) but a press 20 s later never
   produced an IRQ (no 0x22), and the tablet had to be hard-reset.

So the CPU cannot be woken out of the `cpu-sleep-*` rail-collapse state during
s2idle on this port, by either the broadcast timer or the PMIC/PDC interrupt
(the SPMI arbiter is already routed through PDC pin 1), even though runtime
idle uses the same state and wakes fine (there another CPU handles timers).
All prototypes were reverted; `qcom,no-s2idle` keeps s2idle in WFI, and
standby power is therefore higher than ideal on this port.

**How the vendor kernel does it, and how far a mainline port gets.**  The 4.14
vendor kernel does not use s2idle at all: it uses `mem` deep suspend through
Quadcom's LPM framework (`drivers/cpuidle/lpm-levels.c` +
`drivers/soc/qcom/system_pm.c`).  For the cluster level marked
`qcom,notify-rpm` (PSCI mode `0xC24`, "LLCC off, AOSS sleep") it reads the
always-on arch timer compare value and writes it as the **PDC wakeup timer**
through the RPMh CONTROL TCS, then `rpmh_flush()`es the sleep/wake votes, and
only then calls PSCI `CPU_SUSPEND`, with the SPM/SAW already programmed by
`cluster_prepare()`/`cpu_prepare()`.

Mainline already has the CONTROL TCS write path
(`rpmh_rsc_write_next_wakeup()`), but it deliberately writes `~0` during
`SYSTEM_SUSPEND`, disabling timer wakeups.  A prototype changed it to write
`CNTV_CVAL_EL0` (and, in a second run, a fixed now+1s) and let s2idle use the
`cpu-sleep-*` states again: the SDAM marker showed the write happened (0x32,
"CONTROL TCS written", register layout verified identical to the vendor's
`tcs_control_write()`) but the CPU was still not woken (the 1 s unmask timer
never ran, no 0x02).  Note that the vendor does **not** use an SPM/SAW on
sm8150 either (`cpu_prepare()` only calls `cpu_pm_enter()` and the DTS has no
SAW nodes), so that was not the missing piece.

**Platform `mem` suspend (AOSS deep sleep) — works since 2026-11-11.**  A
driver registering `suspend_ops` for `mem` does what the vendor does: the PM
core offlines the secondary CPUs (its `cpu_pm_suspend` syscore op flushes the
RPMh sleep/wake votes), and the last CPU calls
`psci_cpu_suspend_enter(0x4100c244)` — reset flag, affinity 1, cluster mode
`0xC24` ("LLCC off, AOSS sleep"), CPU mode 4 ("rail power collapse"), i.e. the
exact state the vendor's LPM DT computes.  Measured results on
`6.18.59-nabu-full`: 60/60 `rtcwake` cycles resume cleanly, and the power key
suspends the tablet and wakes it with the screen on (3/3 with 30 s sleeps).

Five things had to be right; each was measured, and the wrong variants are
listed because they look plausible:

1. **Nothing but PSCI in `.enter()`.**  The SPMI arbiter and the PMIC are
   already partly gated by then: a PMIC register access from that context can
   stall the bus and hang the machine with interrupts off (the hang moves to
   wherever the access is made).  The key interrupt is armed from
   `pm8941_pwrkey_suspend()`/`suspend_noirq()` instead, where the bus is fine.
2. **Acknowledge the entry transient inside a bounded window.**  A latched
   PMIC event keeps the SPMI summary line asserted, and PSCI refuses to sleep
   while an interrupt is pending — every attempt returns in ~5 ms.  The
   platform entry enables interrupts for a moment before each attempt so the
   chained flow acks the PMIC normally, but only during the first
   `NABU_WINDOW_MS` (1.5 s).  Outside that window a pending event can only be
   a real wake press, and handling it there would swallow it (the driver drops
   events while suspended) and the tablet would sleep again with nothing left
   to wake it.  That failure looked exactly like "press, flash, sleep, never
   wakeable".
3. **Do not write the PDC wakeup timer.**  The vendor programs it from the
   arch timer compare value; on mainline the equivalent made every kernel
   timer wake the SoC (repeated ~740 ms entries, suspend lasting only 1/7 of
   the time).  Leaving mainline's `~0` (timer disabled) is what a
   key/RTC-woken suspend wants.
4. **Do not "restore" the PDC registers.**  The vendor's
   `CONFIG_QTI_PDC_SAVE_RESTORE` saves the enable banks and writes them back,
   which is harmless in their flow, but a software shadow of those banks does
   not contain the bits set by firmware/other drivers: rewriting them disarmed
   wake sources and produced deep sleeps that nothing could wake.  The PDC
   keeps its configuration across the AOSS sleep on this SoC.
5. **Deliver the wake press to userspace.**  `enable_irq_wake()` on the key
   actually succeeds (it returns 0, the nested `irq_set_irq_wake()` on the
   chained SPMI summary is a no-op because the PDC sets
   `IRQCHIP_SKIP_SET_WAKE`), but `suspend_device_irqs()` disables the key
   interrupt as a non-wakeup source *after* the driver armed it, and the
   pending press is then handled before `pm8941_pwrkey_resume()` runs, while
   the driver still has `suspended` set.  It is re-armed from
   `suspend_noirq` (after the masking) and the flag is cleared from a syscore
   resume callback (before interrupts are enabled), so logind sees the press
   and wakes the display.

The SDAM black-box marker (PM8150 `sdam@b100`, byte 0x7e plus a 16-byte ring
at 0x60..0x6f, read back through
`/sys/bus/nvmem/devices/spmi_sdam1/nvmem`) is what made this tractable: the
kernel log of a failed suspend dies with the reset, the PMIC RAM does not.
Note that writes to it must not happen from `.enter()` either (see 1).

Verified for the `mem` path on `6.18.59-nabu-full` (60/60 `rtcwake`
cycles resume cleanly; power-key suspend and wake with 30 s sleeps, 3/3):

    [   46.134348] PM: suspend entry (deep)
    [   46.207800] nabu: pwrkey wake arm ret=0 in .suspend
    [   46.215269] nabu: pwrkey re-armed in noirq
    ... (entry attempts during the transient window) ...
    [   46.633294] PM: suspend exit

Verified for s2idle on the same kernel (13 s of real sleep, one press wakes
it, the screen stays on):

    [198.674671] PM: suspend entry (s2idle)
    [199.318236] PM: suspend-to-idle
    [200.323397] ...pwrkey: key IRQ unmasked, RT_STS=0x4      <- +1s timer
    [212.763566] PM: Triggering wakeup from IRQ 118           <- power key
    [213.476425] PM: suspend exit

and the diagnostic build showed the unmask timer firing across s2idle
(`nabu: key IRQ unmasked` at +1.0 s) only once the CPU idle states were
disabled.

## Standby power (open: ~1.5 %/h vs Android's 0.125 %/h)

Deep sleep works, but the tablet still loses about **1.1-1.5 %/h** on battery
where Android loses about **0.125 %/h** (the user measured 1 % over 8 h).  At
8720 mAh that is ~100 mA versus Android's ~11 mA.

### How it is measured

`capacity` is the only usable gauge and it moves in 1 % steps (~87 mAh, i.e. a
~50 minute step at 100 mA), so every configuration needs hours:

```
22:31 cap=96  ->  06:31 cap=84   (8 h, rtcwake -s 28800, sensors stopped)
```

The fuel gauge's coulomb-counted SOC would be 100x finer, but the SRAM words
this chip needs are unreadable here - `BATT_SOC_v2` (word 455) comes back as
`0xdb036ec0` and `capacity` therefore runs on the `BATT_MONOTONIC_SOC` fallback
(`0x009`, ~0.4 % per LSB).  The `soc_raw` attribute added to read it was
dropped again; it only ever returned garbage.

### rtcwake bypasses the sensor quiesce

`rtcwake` writes `/sys/power/state` directly, so `sleep.target` does not run and
`nabu-sensors-suspend.service` (`nabu-sensors-sleep stop`) never stops
`hexagonrpcd`.  With its FastRPC session live the SLPI crashes every 50-70 s:

```
PDM: service 'sensor_process' crash: 'EX:sensor_process:0x1:frpc_dsp:0x6d:PC=0xb206aabc'
qcom_q6v5_pas 2400000.remoteproc: crash detected in slpi: type fatal error
```

Each crash/recovery aborts an in-flight suspend (the attempt "succeeds" after
1.3 s) and wakes the SoC, which is what made the first overnight attempts look
like hourly self-wakeups.  With `hexagonrpcd` stopped a 5 minute suspend sleeps
the full 300 s and the crash counter stays put, so real suspends (which go
through `sleep.target`) are already protected by the existing services.

The resume side needed a fix: the first attach right after resume can fail with
`Unsupported handle: 4294967295` while the SLPI settles, and the daemon then
exits, leaving the tablet without sensors (no auto-rotate) until the next boot.
`nabu-sensors-sleep start` now retries the start until the unit stays active
(`nabu-accelerometer` 7b6067b).  Note that a raw write to `/sys/power/state`
(`rtcwake`) bypasses `sleep.target` entirely and still crashes the SLPI - use
`rtcwake -m no -s N` plus `systemctl suspend` when measuring.

### What was ruled out

| Experiment | Result |
|---|---|
| WiFi off, `ath10k` unloaded | no change |
| `iio-sensor-proxy` stopped | no change |
| `hexagonrpcd` + sensors stopped | 8 h: 96 % -> 84 % (1.5 %/h) |
| lowest CPU OPP | no change |
| **RPMh sleep votes (LPM)** | **worse**: 1.5 %/h vs 1.09 %/h, reverted |

The RPMh experiment followed the vendor kernel: mainline
`qcom-rpmh-regulator` never writes `RPMH_SLEEP_STATE`, and the vendor device
tree asks for `RPMH_REGULATOR_MODE_LPM` on 24 LDOs.  Mirroring those votes into
the sleep set (voltage + enable + LPM mode, written once from
`PM_SUSPEND_PREPARE`) made standby *worse*, which means the bootloader's sleep
set was already cheaper for these rails than "same voltage, LPM".  The change
was reverted rather than carried.

### What is left

The vendor kernel additionally notifies the remote processors that the AP is
suspending (`subsystem_put()` / APPS_SLEEP over QMI), and the modem WPSS - which
has to stay up because the WCN3990 WLAN firmware is loaded through it - then
enters its own low power state.  Mainline has no such notification, and the
modem cannot be stopped at runtime ("Runtime 'stop' hard-hangs the SoC", see
`nabu-start-modem.sh`), so it is the remaining suspect together with the DDR
sleep votes of the interconnect (`icc-rpmh` only ever writes
`RPMH_ACTIVE_ONLY_STATE` for the BCMs).

## Battery statistics

`qcom_fg` now reports a coulomb-counted state of charge instead of the gauge's
coarse register.  The PM8150B's own SOC words are unusable here - `BATT_SOC`
(SRAM word 455) reads back as garbage (`0xdb036ec0`-style) even with the vendor
profile loaded - so `capacity` used to come from `BATT_MONOTONIC_SOC`
(`0x009`), about 0.4 % per LSB, with no `charge_now`/`energy_now` at all.

The driver integrates the battery current every 30 s, seeded from the gauge at
probe, and pulls the result back towards the monotonic SOC (1/8 of the
difference when the battery rests, 1/32 under load).  Integration is skipped
when the elapsed time is large, so a suspend is not charged with the
post-resume current; the anchor covers that gap because the gauge keeps
counting in hardware.

New properties (all on the nominal 3.85 V, so `ENERGY_NOW` stays below
`ENERGY_FULL`):

| Property | Source |
|---|---|
| `charge_now` | integrated current, uAh |
| `charge_full` | design capacity from the battery profile (8720 mAh) |
| `energy_now` / `energy_full` | `charge_now` / `charge_full` x 3.85 V |
| `health` | `Good` (no degradation model) |

Verified: `charge_now` dropped 8074 uAh in 90 s while the gauge read
330-385 mA (323 mA average), and `capacity` matched
`charge_now / charge_full` (95 %, 8.27 / 8.72 Ah).

## pstore (no usable backend on this platform)

`pstore` itself is configured and the frontend works, but **no backend on this
device can persist a log across a reset**. All three were tried on hardware:

| Backend | Result |
|---|---|
| `ramoops` (DDR) | writes correctly, content gone after a reboot |
| `efi_pstore` (UEFI variables) | registers, a panic leaves no dump variable behind |
| `pstore/blk` (raw `oops` partition) | attaches, but the panic write is refused |

### ramoops: the reset reinitialises DDR

Address first: the node started at `0xb0000000`, inside the region the loader
uses for the image/initrd (`efi: INITRD=0xb1736a98`); then at `0xb4000000`,
which is a hole in the memory map (`/proc/iomem`: System RAM ends at
`b3ffffff` and resumes at `b4400000`); finally at `0x370000000`, high DDR free
of every firmware/boot-chain range (kernel image at `0x2c7600000`, firmware
block from `0x370e78000`).

Reset type second: a PMIC restart handler programmed the vendor warm-reset
registers (`qpnp_pon_reset_config()`: `PS_HOLD_RST_CTL` type `0x01`,
`PS_HOLD_RST_CTL2` bit 7) and `reboot_mode=warm` made PSCI use
`SYSTEM_RESET2`; an SDAM marker proved the handler ran, but the PON type was
back to `0x7` afterwards and pstore stayed empty.

Then the proof, from a temporary debugfs node (diagnostics only, since
removed) that mapped the physical region and printed its `persistent_ram`
header and strings. With the buffer at `0x370000000` the ring was written
normally (`header=44424743...` = signature `DBGC`, `start=size=0x10bb5b` after
12000 `printk` marker lines), so the write path and the address are fine.
After a plain `systemctl reboot` the new boot's header started again at
`start=size=0x17b55` and **all 12000 previous marker lines were gone**.

The reset reinitialises the DRAM and rewrites the PMIC PON configuration
whatever reset path Linux takes. Android's "memory magic" for Reboot2Android
must live in always-on SRAM (IMEM/SMEM), not in DRAM.

### efi_pstore: the variable store is volatile

With ramoops gone, `efi_pstore` registered instead. A controlled panic left
`/sys/fs/pstore` empty and **no `dump`-type EFI variable** in
`/sys/firmware/efi/efivars` after the reboot, so this UEFI keeps its variables
in RAM (or does not keep them at all).

### pstore/blk: the panic path runs with interrupts off

The spare `oops` partition (`sda16`, 16 MiB, all zeroes, unused by any OS) was
the last hope, using `pstore_blk` with `best_effort=1` on `/dev/sda16`. Two
obstacles had to be solved first:

- built in, it probes from `late_initcall()` before the UFS partition scan and
  gives up with `failed to resolve 'PARTUUID=...': -2`, so it was built as a
  module and loaded from a udev rule that fires when the partition appears
  (`pstore_blk: attached /dev/sda16 (16777216)`);
- `efi_pstore` takes the backend first, so it is disabled
  (`CONFIG_EFI_VARS_PSTORE_DEFAULT_DISABLE=y`).

Even then the panic write cannot happen: `vpanic()` calls
`local_irq_disable()` before `kmsg_dump()`, and the generic block write used by
`best_effort` returns `-EBUSY` whenever `irqs_disabled()`. Measured: the panic
rebooted the tablet and the `oops` partition was still all zeroes. UFS has no
`panic_write`, so the non-best-effort path is not available either.

### What to use instead

- **USB CDC-ACM console**: the `serial-debug` product (removed 2026-11-16; the
  `nabu-serial` module remains) put `console=ttyGS0` on
  the command line; plug the tablet into a PC and the complete panic output
  arrives on `/dev/ttyACM*`. This is the "serial cable" of this tablet.
- **PMIC SDAM black box** (`sdam@b100`, see `KNOWN-ISSUES.md`) for hangs where
  nothing is printed: a few hundred bytes of markers written from the PM
  notifier and the pwrkey driver survive any reset.

The `PSTORE` frontend and the config options stay (so `/sys/fs/pstore` exists if
a future boot chain ever keeps RAM), but no backend is enabled.

## Camera (first light 2026-11-17/18)

The `nabu-camera` module now builds on 6.18 and is part of the `debug` product.
The whole chain works on hardware: `probe of ac4a000.cci returned 0`,
`probe of ac65000.camss returned 0`, `/dev/media0` carries csiphy0-3, csid0-3 and
vfe0-3 with `ov13b10 3-0010` (rear), `ov8856 4-0010` (front) and
`cn3927 focus`, and `cam -l` lists both cameras.  A rear capture delivers a
4200x3120 frame through libcamera's simple pipeline and software ISP.

What had to change: the old overlay replaced all of `camss` with a copy written
against an older API (it neither compiles nor helps on 6.18), while upstream 6.18
has no SM8150 either.  `nabu-camera` now carries only what SM8150 needs on top of
the current driver - the csiphy/csid/vfe/icc resource tables, `sm8150_resources`,
the `CAMSS_8150` version and the five places that switch on it.  The sensor, VCM,
CCI and camcc overlays are unchanged.

Colour: libcamera 0.4 (Debian trixie) has no `Ccm` algorithm, so the simple IPA
falls back to `uncalibrated.yaml` and the picture is tinted.  The CCMs recovered
from Qualcomm's tuning blobs (`camera-tuning/*.yaml`) need libcamera >= 0.5;
0.5.0 has `Ccm` but not `Adjust` (that landed later), so the profiles list `Ccm`
only.  A cross-built 0.5.0 was verified on the tablet: the same scene then comes
out with balanced channels (R/G/B roughly 9.6/9.8/9.0), and the profiles are not
installed on systems with libcamera < 0.5 because a stale copy makes the IPA
fail and the camera deliver no frames at all.

**Black frames were a tuning-file bug, not a kernel bug (2026-11-18).**  The
kernel side is proven: with the media links up (`csiphy0 -> csid0 ->
vfe0_rdi0`) `v4l2-ctl` reads three consecutive valid RAW frames (mean
389/1023), and `camss-video.c` shows one contiguous plane per buffer
(`nents 1`, `vb->planes[0].length == sizeimage == 16423680` at 4208x3120).

The simple IPA delivered `RGB 0, alpha 255` while its input was fine
(`NABU-DUMP` in `debayer_cpu.cpp`: `size 16423680`, first bytes 70/40/74/45).
The cause: `camera-tuning/*.yaml` listed `BlackLevel`, `Awb`, `Ccm` but **not
`Lut`**, so `DebayerParams::gammaLut` was never filled (`DebayerParams` is a
plain aggregate, so it stayed zero) and the CCM store path
(`GAMMA(blue.b + green.b + red.b)`) indexed an all-zero table - an all-black
image.  Upstream's `uncalibrated.yaml` always lists `Lut`.  Two further traps
found on the way:

- `Lut` must come **after** `Ccm` in the algorithm list: `Ccm::prepare()` sets
  `activeState.ccm.changed`, and `Lut::prepare()` fills the CCM/gamma lookup
  tables only when it sees that flag or a black-level change.
- `BlackLevel::init()` does `blackLevel >> 8`, i.e. the value is 16-bit.  For
  the 10-bit sensors here the correct value is `4096` (64 << 6), not `64`
  (which becomes 0) and not 255 (the "unset" default, which clamps everything
  to black).

With `Lut` and `blackLevel: 1024` present and `Ccm` removed, a rear capture is
100 % non-zero with sensible levels (R mean 103, max 255).  With `Ccm` **before**
`Lut` (the order the profiles now use) the CCM tables are filled and a
`cam --capture=5` run delivers five consecutive frames: frame 0 is the CCM
warm-up (still black), frames 1-4 are 100 % valid (`RGB 83/124/69` at this
scene).  So the earlier "only the first frame works" observation was the same
missing-`Lut` bug, not a VFE problem.

Black level: the sensors output a pedestal of about 16 in 10-bit (observed
raw bytes 17-21 in a dark scene), i.e. 4 in the 8-bit domain the ISP works in,
so the 16-bit tuning value is `1024`.  `4096` (= 64 << 6) over-subtracts and
crushes shadows (R 60 vs 83, B 39 vs 69 on the same scene); `64` shifts to 0;
the absent/default `255` makes everything black.

Open:

- the front sensor (ov8856) configures (3280x2464) but delivers no frames and
  stops after two WM updates;
- the lens is not driven by libcamera yet (CN3927 VCM is registered and its
  driver exposes `V4L2_CID_FOCUS_ABSOLUTE`; the simple pipeline handler has no
  lens handling, so focus has to be set on the subdev for now);
- the simple pipeline handler still drops the first frame while the CCM
  algorithm runs for the first time.

The camera ships in the `debug` product only.

## Notes

- `make apply` copies overlays and now stamps them with the current time; the
  module sources are older than the objects in `out-<version>`, and without the
  timestamp refresh make linked stale objects (modpost failures, e.g.
  `iris_set_gop_size_gen1 undefined`).
- Run `make config` **after** `make apply`: the touchscreen and LN8000
  Kconfig entries live in the module overlays.  If the configuration is
  generated while the tree still lacks them, the symbols silently disappear
  from `.config` and the next `make deb-install` ships a kernel without the
  touchscreen and charger modules (`lsmod` shows neither, no
  `/sys/class/power_supply/ln8000-charger`).
- Keep the 6.14 UKI (`nabu-debian.efi`) on the ESP: a 6.18 experiment that
  hangs is recovered by picking it in the rEFInd menu.
