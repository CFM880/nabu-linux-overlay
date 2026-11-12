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
