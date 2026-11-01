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
| Charging (qcom_pmi8998/smb2 + LN8000) | 5 V charging at ~2.3 A with a DCP charger |
| WiFi / SSH | works |
| Fast charge | the pump correctly reports `adapter did not take 9V` for a non-QC charger; needs a QC3 adapter to verify |
| iris decode (H.264/HEVC) | works: 4K H.264 uses 0.9 s CPU vs 18.5 s software, HEVC 1080p 0.47 s; iris IRQ counts confirm the VPU does the work. VA-API (`vpu_drv_video.so`) opens `/dev/video0` "Iris Decoder" and drives the same path |
| Sensors (SSC/SNOC via SLPI) | works: accelerator, gyro, magnetometer, ambient light; GNOME auto-rotates. Required adding the SLPI protection domains to the sm8150 table in qcom_pd_mapper (see below) |
| suspend/wake | **not working yet** - see below |

## Sensors

The SLPI kept crashing every ~40 s ("USER-PD DOG detects stalled
initialization") and `ssccli` never received data.  `qcom_pd_mapper` advertises
the SLPI domains for sdm845/sm8250/sm6115 but not for sm8150, although it is the
same SLPI with instance 90, so `msm/slpi/root_pd` was never announced:
fastrpc's PDR lookup failed with -ENXIO and the sensor PD could not attach.
Adding `&slpi_root_pd` and `&slpi_sensor_pd` to `sm8150_domains[]`
(`nabu-accelerometer/patches/0006-sm8150-slpi-pd-6.18.patch`) fixes it: no more
SLPI crashes, all sensors report, and `net.hadess.SensorProxy` exposes
`HasAccelerometer`/`AccelerometerOrientation`, so GNOME rotates the screen.

## Suspend / wake (open)

`systemctl suspend` reaches `PM: suspend-to-idle` with all devices suspended
(`PM: suspend of devices complete after ~33 msecs`), and the display PLL fix
below is required for that to work at all (without it the PLL never re-locks
and the display clock tree is mangled).  The system is then woken ~2 ms later:

    PM: suspend-to-idle
    PM: Triggering wakeup from IRQ 118      <- pm8941_pwrkey (power key)
    PM: resume from suspend-to-idle

Disabling that IRQ's wakeup (`.../pwrkey/power/wakeup = disabled`) keeps the
tablet suspended, so the power-key IRQ is the thing aborting it, not a device
failing to suspend.  Disabling the USB keyboard, charger, battery and RTC
wakeups made no difference, and changing the DT to `IRQ_TYPE_EDGE_FALLING`
(only the press edge) did not either, so a latched release edge is not the
cause.  The handler is a threaded `IRQF_ONESHOT` IRQ; the next step is to look
at how the PON interrupt stays pending/active across
`check_wakeup_irqs()`, and either clear the PON latch in
`pm8941_pwrkey_suspend()` or take the interrupt off the threaded path.

## Notes

- `make apply` copies overlays and now stamps them with the current time; the
  module sources are older than the objects in `out-<version>`, and without the
  timestamp refresh make linked stale objects (modpost failures, e.g.
  `iris_set_gop_size_gen1 undefined`).
- Keep the 6.14 UKI (`nabu-debian.efi`) on the ESP: a 6.18 experiment that
  hangs is recovered by picking it in the rEFInd menu.
