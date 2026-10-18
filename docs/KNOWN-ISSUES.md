# nabu Linux 已知问题与待办

小米平板 5（nabu，SM8150）Linux 支持的问题清单，按严重程度排序。
内容来自各模块仓库的 README / docs 与 git 历史，是**基于证据的快照**；
若某条已在后续提交中解决，请更新对应条目而不是删除。

- 生产内核：`6.14.11-nabu1`（`nabu-main/repos.lock` 锁 `linux-6.14` @ `5181e135`）
- 模块：`nabu-iris` / `nabu-camera` / `nabu-audio` / `nabu-accelerometer` / `nabu-power`
- 用户态硬解：`iris-vaapi`
- 维护者记录：`nabu-main/README.md`、各模块 `README.zh.md`、`iris-vaapi/docs/`

---

## 优先级待办

| 优先级 | 问题 | 影响面 | 证据 |
|---|---|---|---|
| P0 | 中断解码会话楔死固件 → **已修复并实机验证**（2026-09-21 Fluster 全量不重载跑通） | 硬解稳定性、测试可信度 | `nabu-iris` 6 文件、`benchmark-results/fluster-full-postfix.md` |
| P0 | WCD934x TX5/TX6 FIFO overflow/underflow → **已修复并验证** | 录音时序 | `nabu-audio` `wcd934x.c`、3.2 |
| P0 | 启动偶发无声卡（SLIM NGD QMI 1 秒超时）→ **已修复并验证** | 音频可用性 | `nabu-audio` `qcom-ngd-ctrl.c`、3.1 |
| P0 | 生产配置对 `qcom_iris` 自相矛盾 → **已修复**（统一到 nabu-main，只屏蔽 `venus_core`） | 部署一致性 | `nabu-accelerometer` `config/production.cmdline`、README |
| P1 | suspend → 内核 PM 已修复；`c8c000.serial` 虚假唤醒**已修**（s2idle 能保持）；**但 resume 后 SLPI 仍会（低概率）崩溃 → `iio-sensor-proxy` 段错误、传感器/旋转失效（2.3，未解决）** | 待机功耗、稳定性 | `nabu-iris` `72077a2`、2.1/2.3 |
| P1 | VP9 动态分辨率 → **V4L2 已修（8 对齐高度仍受限）** | 硬解正确性 | `iris-vaapi/benchmark-results/vp9-v4l2-resize.md`、1.2 |
| P1 | 无串口/USB console 恢复通道 | 排障、变砖恢复 | `nabu-iris` `e23405e` 被 `239f933` revert |
| P1 | 相机无完整 3A/通用拍照集成（Snapshot 已移除） | 相机可用性 | `nabu-camera` `40a5620` |
| P1 | suspend/resume → **已验证**；显示链路 **已验证（无 HDR 通路）** | 回归风险 | 2.1、8 |
| P1 | s2idle resume 后 SLPI 复位 → 传感器/旋转失效 **已修**（挂起前停 `hexagonrpcd`，`nabu-accelerometer` `215eb57`）；`c8c000.serial` 虚假唤醒亦已修 | 可用性、待机 | 2.3 更新、`nabu-accelerometer` `215eb57`/`8a84037` |
| P1 | s2idle resume 后**显示子系统**起不来（`disp_cc_pll0` 锁不上 → `mdss_runtime_resume` -110 → KMS 线程同步外部中止）→ **亮屏时**按电源键休眠后无法唤醒 → **已修（`nabu-display`：对 `core` 时钟持永久引用，PLL 不再解锁），待实机验证** | 待机可用性 | 2.4、`nabu-display` |
| P1 | 睡前 hook `nabu-sensors-suspend.service` 用 `Before=suspend.target` 与挂起**并发**执行 → 整机卡死（连 RTC 也唤不回）→ **已修（改 `Before=sleep.target`），待实机验证** | 待机可用性 | 2.5、`nabu-accelerometer` |
| P1 | 刷机后开机首个图形会话不自动旋转（登录页/用户会话都不转，注销重登才恢复）→ **已修复并实机验证**（2026-10-13：删 ttyGS0 getty、helper 不再提前置 ON、iio-sensor-proxy 启动竞态补丁） | 传感器/旋转可用性 | `nabu-accelerometer` `patches/0005`、`nabu-main/debian/build.sh`、`port-7.2.7.md` 2026-10-13 条 |
| P2 | 充电硬限制（电荷泵温度窗、仅 A 口 QC、无 PD/PPS、电池 profile 单一） | 充电体验 | `nabu-power/README.zh.md` |
| P2 | 6.18 移植存在但未成为受支持配置 | 内核升级 | `linux-6.18/`、`repos.lock` |
| P2 | 传感器仅导出桌面子集 → **陀螺仪/原始磁力计已导出（D-Bus）** | 功能覆盖 | `nabu-accelerometer/README.md`、7 |
| P2 | Fluster 能力边界（tiny/422/444/交错/>8192） | 硬解覆盖 | `fluster-full.md:86`、`nabu-iris/docs/fluster-debug.md` |

---

## 1. 视频硬解（Iris / VA-API）

### 1.1 中断会话楔死固件（P0，代码已修，待实机验证）
- **现象**：会话被中断/异常结束后，后续所有会话报 `SESSION_INIT -110` 或
  `output VIDIOC_REQBUFS failed: I/O error`，直到 `modprobe -r/modprobe qcom_iris`。
- **影响**：播放器异常退出、测试失败都会污染后续结果；Fluster 完整套件必须
  **每个 pass 之间重载模块**才有干净数字。
- **证据**：`iris-vaapi/docs/fluster.md`、`benchmark-results/fluster-full.md:43`。
- **根因（2026-09-21 定位）**：原恢复逻辑只在「session error / unsupported stream」
  两类事件上置位，且只在 `iris_close()` 时执行；以下路径不会触发恢复：
  1. `SESSION_INIT` 超时：`iris_hfi_session_open()` 直接返回，漏清
     `hfi_session_opened` 且不请求恢复，使核心永久被占；
  2. 其它命令（streamon/stop/flush）超时虽把实例置 ERROR，但没有统一请求恢复；
  3. 长生命周期 fd（如浏览器/VA context）只做 streamoff、不 close，
     `iris_run_pending_core_recovery()` 永不执行；
  4. `iris_core_init()` 失败后核心停在 `IRIS_CORE_ERROR`，之后每次 init 都 `-EINVAL`。
- **修复（nabu-iris，未提交）**：
  - 在唯一的 `IRIS_INST_ERROR` 入口 `iris_inst_change_state()` 统一置位
    `recovery_pending`（覆盖所有 fatal 路径）；
  - `iris_request_core_recovery()` 改为无锁 `WRITE_ONCE`，可从持有 `core->lock`
    的 SYS_ERROR 路径调用；
  - `iris_hfi_session_open()` 失败/超时时请求恢复并释放槽位，不再泄漏
    `hfi_session_opened`；`iris_hfi_session_close()` 失败时也请求恢复；
  - 新增 `iris_core_recover()`（deinit+init），`iris_open()` 检测到
    `IRIS_CORE_ERROR` 时自动 power-cycle；
  - 在 `iris_hfi_session_open()` 开头执行挂起的恢复，使长生命周期 fd 在下一个
    会话开始前从干净 VPU 启动，无需重载模块；
  - `sys_error_handler` 完成 power-cycle 后清除 pending，避免重复。
- **验证状态（2026-09-21 已实机验证）**：安装新模块（build-id 与构建产物一致）
  后重启，跑 Fluster 完整四套、**pass 之间未重载模块**：
  - 所有 pass 均跑到完整分母（H.264 135、HEVC 147、VP9 305、VP9-HIGH 6），
    不再中途 EIO 中止；
  - VA-API 数字与「每次重载」基线完全一致（H.264 97、HEVC 130、VP9 174、
    VP9-HIGH 2）；V4L2 同量级（H.264 111、HEVC 128、VP9 176）；
  - 内核日志出现 3 次 `entered ERROR` → `power-cycling core after fatal session
    error`，每次约 40ms 后固件重新 boot，之后测试继续；
  - 全程无 `timed out waiting for HFI system response` / core init 失败。
  - 结果与日志见 `iris-vaapi/benchmark-results/fluster-full-postfix.md`。
- **遗留**：V4L2 路径相对旧基线小降（H.264 116→111、HEVC 130→128，多出若干
  `Error`），是否为 power-cycle 时序或运行波动待查；会话内部一旦内部解码错误，
  同一码流后续包会持续 EIO（per-vector，跨 vector 不再污染）。
- **相关历史**：`dd5ff82`、`e32ecfc` 为此前的部分修复。

### 1.2 VP9 动态分辨率（P1，V4L2 主体已修复，8 对齐高度仍受限）
- **现象**：VP9 变尺寸码流（如 1280x720 → 640x360）的逐帧可见尺寸没有正确传到前端；
  V4L2 直通路径需人工裁剪才能与软解一致，VA-API 路径已修复。
- **证据**：`fluster-extended.md:78`、`:152`；固件 `FILL_BUFFER_DONE` 的
  frame_width/height 未被处理函数读取。
- **根因（2026-09-22 硬件确认）**：`VIDEO.IR.1.2` 对「现有 CAPTURE 分配已足够」的
  in-place resize **不发** `HFI_EVENT_SESSION_SEQUENCE_CHANGED`，且**不实现**
  `HFI_PROPERTY_PARAM_VDEC_ENABLE_SUFFICIENT_SEQCHANGE_EVENT`（只有 `SEQCHNG_AT_RAP`），
  所以此前的属性实验失败是固件不支持，不是 host 端 bug。固件字符串
  `Seq changed at INTER frame. Not calling update ds info. We will continue to use
  old values for now.` 表明它保留 OUTPUT2 配置；此时 host 侧 FLUSH/reinit 会让固件
  assert（`sys error` + `session error 0x1004` + 自动 power-cycle，已实测）。固件只在
  每帧 `FILL_BUFFER_DONE` 里给出可见矩形（frame_width/height + origin）。
- **修复（`nabu-iris` + FFmpeg V4L2 m2m 客户端）**：
  - 驱动在 FTB 检测 VP9 可见矩形**缩小**（legacy VPU5、首个 IPSC 之后、非 DRC），
    更新 `crop` 并发 `V4L2_EVENT_SOURCE_CHANGE`，但**不改 CAPTURE 格式**（避免客户端
    重分配、避免触发固件 assert）；
  - 每个 CAPTURE buffer 记录自己的可见矩形，`iris_vb2_buf_finish()` 在出队时通过
    `G_SELECTION` 暴露（legacy VP9 会延迟一帧输出，必须 per-buffer，否则前退一帧）；
  - FFmpeg 客户端在 DQBUF 后查 `G_SELECTION` 并按可见矩形裁剪（不改 stride/缓冲），
    即 V4L2 语义下的「客户端裁剪」。
- **验证（2026-09-22）**：`vp90-2-21-resize_inter_1280x720_5_1-2` 连续 3 次
  **30/30 帧与软件逐字节一致**（`dac2d22f…`）；`resize_inter` 变体中所有「缩小后高度
  为 8 的倍数」的 8 个向量均逐字节一致；回归无下降（H.264 1/1、VP9 1/1、VP9-HIGH
  0/1），且客户端 HEVC smoke 由 1/2 提升到 2/2。详见
  `iris-vaapi/benchmark-results/vp9-v4l2-resize.md`。
- **遗留（固件限制）**：固件把输出高度向上取整到 8（180→184、540→544、90→96），且
  FBD 没有其它 render-height 字段；缩小后高度非 8 倍数的向量（320x180、640x360、
  960x540 等）仍只能拿到对齐值。彻底解决需内核解析 VP9 头或改固件。
- **相关历史**：`vp9-context-continuation.md`（VA-API 修复）。

### 1.3 能力边界（P2）
- VP9 160x90 因最小可见高度失败（160x96 通过）——`nabu-iris/docs/fluster-debug.md:32`。
- 高度 >8192 直接不支持（`fluster-full.md`）。
- `tiny(<64)`、4:2:2/4:4:4、10/12-bit 组合、场/交错工具在硬件路径 Fail/Error。

### 1.4 其他硬解限制
- HEVC canonical SPS **不支持 long-term reference table**；自定义 scaling list 未序列化
  （`iris-vaapi/docs/development-notes.md:250`）。
- **单引擎单实例**，不支持并发多视频流（同上 `:356`）。
- stock FFmpeg 的 `hevc_v4l2m2m` / `vp9_v4l2m2m` 不为 10-bit 输入选 P010，需自编译 FFmpeg。
- XPU 稳定 surface 每帧一次 CAPTURE→DMA-BUF CPU 拷贝是默认路径；Vulkan copy 仍属实验，
  且会引入 Turnip 内存开销。
- Chrome 153 HEVC seek 显示 seek 前旧帧为 Chromium 回归（`ExtendedVideoBitstreamValidation`），
  需 `--disable-features` 规避。
- **seek 残留帧结论**：在「不动 Chromium、只改通用 VA 驱动/内核」约束下无解，根因在
  Chromium frame-pool/合成器（`iris-vaapi/docs/seek-debug.md:317`）。

---

## 2. 系统挂起 / VPU 电源（P1，suspend 已修复并验证）

### 2.1 suspend 致命错误（已修复并验证）
- **历史**：`iris_vpu_prepare_pc()` 对 legacy VPU5 返回 `-EAGAIN` 以保持供电，但系统睡眠
  经 `pm_runtime_force_suspend()` 复用该回调，把非零当致命，**每次 suspend 以 -11 中止**；
  9/16 由 PR #2（`nabu-iris` `ea7b52f` / `42085a8`）绕过：VPU5 上直接返回成功、
  resume 不再重跑 power-on/固件重启。
- **回归（2026-09-22 实测复现）**：9/19 的 idle power collapse（`c45c31f`）重写了
  `iris_hfi_pm_suspend()`，丢掉了 VPU5 绕过。当 VPU 已被 idle work 收起
  （`vpu_suspended=true`）时，suspend 仍对**已断电**的硬件调用 `iris_vpu_prepare_pc()`，
  读回 “CPU not idle” 后转为 `-EAGAIN`，`dpm_run_callback()` 报 -11 中止 s2idle。
- **修复（`nabu-iris`）**：`vpu_suspended` 已置位时直接返回成功；legacy VPU5 上
  `prepare_pc` 失败按“保持供电”处理（s2idle 不掉电），不再中止挂起。
- **验证（2026-09-22，安装模块 build-id `b93737b7`）**：
  `rtcwake -d rtc1 -m freeze` 连续 **5 个 s2idle 周期（5 entry / 5 exit）无
  `failed to suspend/resume`**；偶数周期后跑 VP9 resize 向量逐字节通过
  （`dac2d22f…`）；随后再 3 周期复验无失败。`mem_sleep` 仅 `[s2idle]`。
  resume 时若 VPU 此前已收起，会重新上电并 boot 固件（约 1s），之后 idle work 再次收起。

### 2.2 真正电源管理仍不完整
- VPU5 上 **runtime PM 被 `pm_runtime_forbid()` 禁用**，仅靠延迟 work「idle power collapse」
  （`c45c31f`）在最后一个会话关闭且 2 秒无输入后收起 VPU；idle 与系统挂起路径共用
  `iris_vpu_prepare_pc()` / `iris_vpu_power_off()`。
- **故意省略 legacy Venus AXI halt**：`0xaa80208` 的 VBIF 寄存器会触发同步外部中止。
- **待优化**：resume 后对“挂起前就已收起”的 VPU 会多做一次固件 boot（约 1s），
  可用“是否本次挂起才断电”的标志避免；有会话打开时 s2idle 保持供电（可接受），
  runtime PM 仍未接管。
- **稳定性备注**：一次实验性 `power_collapse=0` 测试触发 VPU `SESSION_INIT` 超时
  （-110，已由自动 power-cycle 恢复），随后 SLPI 传感器 DSP 连续 `USER-PD DOG`
  崩溃导致整机卡死需硬重启；与 suspend 回调无关，但说明 SLPI/传感器仍有稳定性风险
  （另见第 7 节）。

### 2.3 s2idle resume 后 SLPI 崩溃 → 传感器失效（P1，SLPI 部分已修）
> **更正（2026-10-14）**：本条早期把「休眠后屏幕无法唤醒」也归到这里，**错了**。
> 屏幕唤不醒是**显示子系统 resume 失败**，与 SLPI 无关，见新增的 **2.4**。
> 本条只覆盖「resume 后 SLPI 复位 → 传感器/旋转失效」。
- **现象（2026-09-23 实机）**：做一次 `s2idle` 后，SLPI 复位、传感器失效
  （屏幕无反应那条见 2.4）。
- **根因（日志已定位）**：`PM: suspend exit` 的**同一秒**SLPI 被复位
  （`crash #1`），随后 PDR 注册丢失，传感器进程初始化卡死并被看门狗击杀，
  进入 **每 40 秒一次**的崩溃循环：
  ```
  13:05:17 PM: suspend entry (s2idle)
  13:05:24 PM: suspend exit
  13:05:24 remoteproc0: crash detected in slpi: type fatal error   <- crash #1
  13:05:24 PDR: service lookup for tms/servreg failed: -6
  13:06:04 qmi_decode_string_elem: String len 128 >= Max Len 65
  13:06:04 failed to decode incoming message
  13:06:04 qcom_q6v5_pas: fatal error: ... USER-PD DOG detects stalled initialization
  13:06:04 crash detected in slpi ... crash #2        <- 之后每 40s 重复
  ```
- **证据**：`nabu-main/artifacts/diagnostics/slpi-crash-after-s2idle-20260923.log`
  （含 resume 时序、crash #1..#12、PDR -6 与 40s 周期）。
- **对比**：同一内核的其它启动若**不做 suspend**，SLPI 完全健康（0 崩溃，四路
  remoteproc running）。因此触发条件是 **s2idle 往返 + SLPI/GLINK/PDR**，与内核改名、
  模块拆分、显卡/面板无关。
- **与 2.2 的关系**：此前记录的 `USER-PD DOG` 卡死（USB console 实验那次，`crash #14`）
  是同一故障模式的另一次触发。
- **影响**：suspend 实际上是**不可用**的——一旦挂起就必须硬重启，所以 2.1 的
  “suspend 已修复”只覆盖了内核 PM 路径，没有覆盖 SLPI。
- **下一步（未执行）**：先停 `hexagonrpcd`/`iio-sensor-proxy` 再测 s2idle，判断是
  传感器服务与 GLINK 的交互还是 SLPI 固件自身；再考虑 suspend 前主动释放 SLPI/QRTR
  或在 resume 后重放 PDR 注册。
- **更新（2026-09-30，7.2.7 `#84` 实机）：仍然存在——低概率，且与「挂起时传感器是否在持续流」有关。**
  - 代理**空闲**时（无客户端真正 claim、SLPI 无持续 QMI 流）连续 **6 次** `rtcwake -d rtc1 -m freeze`
    （10–18s）**0 次崩溃**，四路 remoteproc running，显示每次 resume 正常 unblank。
  - 但用 `monitor-sensor` **持续读罗盘/光感**后再挂，resume 时**复现**（13:53:07）：
    ```
    PM: suspend exit
    remoteproc0: crash detected in slpi: type fatal error
    remoteproc0: recovering slpi
    iio-sensor-proxy.service: Main process exited, code=dumped, status=11/SEGV
    iio-sensor-proxy.service: Failed with result 'core-dump'.
    hexagonrpcd.service: Deactivated successfully.
    ```
    之后 SLPI 又进入每 ~40s 的崩溃循环（13:53:47 再现一次）。
  - 之后再跑 7 个 cycle（其中 3 个边流边挂）未再崩 → **竞态/低概率，不是每次必现**；所以 6.14 那条
    证据在 7.2.7 上**没有被真正修掉**。
  - **后果：息屏挂起会让传感器/自动旋转失效**。崩溃后 `iio-sensor-proxy` 没有 `Restart=`，停在
    failed、`net.hadess.SensorProxy` 名字消失；即便不崩，`hexagonrpcd` 也会在挂起时退出而没人拉起。
  - 上游 `hexagonrpcd-suspend/resume.service` 带 `ConditionFirmware=device-tree-compatible(qcom,sdm670)`，
    nabu 是 SM8150 → **这两个 hook 从来没在 nabu 上跑过**（即使跑，也只 stop/start 守护进程，
    不解决 SLPI 崩溃）。
- **s2idle 真正的阻塞点另有其人：`c8c000.serial` 的虚假唤醒。** SM8150 GENI 调试 UART
  （`c8c000.serial`）注册了唤醒 IRQ，但端口未接、RX 悬空，唤醒会虚假触发，把 s2idle 在 **~1s**
  内打断（`pm_wakeup_irq=176`、`msmgpio 46 c8c000.serial:wakeup`）。表现是 `PM: suspend entry/exit`
  都出现、但**根本没睡着** —— 所以 2.1 的“5 个周期无失败”其实是**快速弹跳**，并不省电，
  也解释了“suspend 了但耗电没降”。
  - 隔离实测：serial 开 + rtc-efi 关 → 1s 醒；serial 关 + rtc-efi 开 → 完整 10s 保持。
    即 **只有 UART 需要处理**。
  - 修复：`nabu-platform` 新增 `config/99-nabu-serial-wakeup.rules`
    （`ACTION=="add", SUBSYSTEM=="platform", KERNEL=="c8c000.serial", ATTR{power/wakeup}="disabled"`），
    并在 `nabu-module.toml` 的 `[install]` 安装到 `/etc/udev/rules.d/`。装了之后 s2idle 能保持
    整个 RTC 闹钟时长（15–18s）。
- **根因已定位并修复（`nabu-accelerometer` `215eb57`，2026-09-30）**：只要**传感器在持续流数据**，
  每次挂起时 SLPI 的 `sensor_process` 都会在 **FastRPC 路径**崩溃（发生在 AP 还处于挂起状态时）：
  ```
  PDM: service 'sensor_process' crash: 'EX:sensor_process:0x1:frpc_dsp:0x6d:PC=...'
  remoteproc0: crash detected in slpi: type fatal error
  ```
  这个复位让 `iio-sensor-proxy` 退出（`No sensors or missing kernel drivers`）或 SEGV；proxy 每次
  重启都丢 `net.hadess.SensorProxy` → Mutter 丢 claim → 旋转消失。
  - **发现**：`libssc` 用 **QRTR** 直连 SLPI，sensors PD attach 之后**不需要 FastRPC**。挂起前停掉
    `hexagonrpcd`（FastRPC 服务）后，传感器数据照流、proxy 不退出，DSP 也没有会崩的 FastRPC 会话。
  - **修复**：新增 `nabu-sensors-suspend.service`（`Before=suspend.target`）停 `hexagonrpcd`，
    `nabu-sensors-resume.service`（`After=suspend.target`）再起；**`iio-sensor-proxy` 全程不动**，
    所以 D-Bus 名字 / Mutter 的 claim 不丢。
  - **验证**（带传感器流 + `systemctl suspend`，4 个 cycle）：**SLPI 0 崩溃、`iio-sensor-proxy` 0 重启、
    数据流连续、`AccelerometerOrientation` resume 后仍有效**。
- **兜底（`nabu-accelerometer` `8a84037`）**：`iio-sensor-proxy` 加 `Restart=on-failure`（2s）+ resume
  hook 的 start-if-not-active。即使 SLPI 仍偶发复位、proxy 真死了也能自动拉起（光感/罗盘恢复；
  Mutter 若已丢 claim 需重新登录）。
- **待办**：这是「避免触发」，不是修固件；FastRPC/s2idle 的固件层根因仍在。s2idle 现在可放心用，
  但建议先手动验证一次真实用户流程（熄屏→唤醒→旋转）再开自动挂起。待机功耗量化仍受限于
  `qcom-battery` 无 `charge_counter`/`energy_now`。

### 2.4 s2idle resume 后显示子系统无法恢复 → 亮屏时休眠后唤不醒（P1，已修，待实机验证）
- **现象（2026-10-14 实机，`6.14.11-nabu-full`）**：**屏幕亮着时**按电源键休眠，再按电源键
  无法唤醒，整块屏幕无反应，只能长按电源强制重启。
- **根因（日志已定位，与 2.3 的 SLPI 无关）**：`mdss`（`ae00000.display-subsystem`）用的是手写的
  system-sleep 回调 `mdss_pm_suspend()`/`mdss_pm_resume()`。当设备在挂起时是 runtime-active
  （屏幕亮着就是这种情况）时，前者只关时钟、**不更新设备的 runtime 状态**，于是 genpd 的 noirq
  断电把 MDSS GDSC 留在半状态（`mdss_gdsc status stuck at 'on'`），resume 时显示主 PLL 锁不上：
  ```
  PM: suspend entry (s2idle)
  WARNING: mdss_gdsc status stuck at 'on'
  WARNING: disp_cc_pll0 failed to enable!
  Failed to prepare clk 'core': -110
  msm-mdss ae00000.display-subsystem: clock enable failed, ret:-110
  msm-mdss ae00000.display-subsystem: PM: failed to resume: error -110
  [drm:dpu_runtime_resume] [dpu error]clock enable failed rc:-110
  PM: suspend exit
  ```
  显示电源域随后一直是关的，gnome-shell 下一次 atomic commit 读 DPU 寄存器即触发**同步外部中止**，
  KMS 线程被打死 → 屏幕永久黑：
  ```
  Internal error: synchronous external abort  Comm: KMS thread
    dpu_reg_read ← _dpu_crtc_blend_setup ← dpu_crtc_atomic_begin ← drm_mode_atomic_ioctl
  ```
- **对照（决定性）**：同一启动里 SLPI/remoteproc **0 崩溃、0 复位**、`iio-sensor-proxy` 未重启，
  与 2.3 的传感器路径无关；另外屏幕**已熄屏**（DPU/mdss 已 runtime-suspended）时
  `rtcwake -d rtc0 -m freeze` 干净进出、无 `pll`/`mdss` 报错 —— 这正是 2.1「验证通过」走过的那条
  路径（`mdss_pm_suspend()` 直接 `return 0`，根本没关显示时钟），所以两台测试路径不同不是矛盾。
- **修复（`nabu-display` overlay `drivers/gpu/drm/msm/msm_mdss.c`）**：
  1. 先把手写的 `mdss_pm_suspend()`/`mdss_pm_resume()` 换成与 DPU 相同的
     `pm_runtime_force_suspend()`/`pm_runtime_force_resume()`（对齐 runtime-PM 路径）。
     **实测（2026-10-15）这一步不够**：resume 仍 `disp_cc_pll0 failed to enable!` →
     `mdss_runtime_resume` → `clock enable failed, ret:-110`。即 PLL 重锁失败与 PM 回调写法无关。
  2. 真正的修法：`msm_mdss_enable()` 里对 `core` 时钟（`DISP_CC_MDSS_MDP_CLK`，父即
     `disp_cc_pll0`）**持一个永久引用**（`core_clock_kept` 标志，只取一次、不再释放）。这样
     mdss/DPU 各自 `clk_bulk_disable_unprepare` 都无法把 PLL 解开，resume 只是重新开分支门控，
     **不再等待 PLL 重锁**。代价：显示 PLL/核心时钟常开，待机功耗会略升（见 2.2 的权衡）。
     **实测（2026-10-15）**：PLL 报错消失、`PM: Triggering wakeup from IRQ 135`（电源键）也正常，
     但屏幕仍黑。
  3. 第三层（DPU/DSI resume 重建）：resume 后显示管线不出帧 ——
     `[dpu error]enc32 frame done timeout` / `[dpu error]vblank timeout: 10200c1`（触屏
     `nvt_ts_resume: download firmware failed` 同时出现）。修法：在 DPU 的 system-resume
     `complete` 回调里，先照搬开机那次「显示断电重来」（`pm_runtime_put_sync` + `msleep(50)`
     + `pm_runtime_resume_and_get`，见 `nabu-display` overlay `disp/dpu1/dpu_kms.c`），
     再调 `msm_kms_pm_complete()` 做 restore 提交，从冷状态重建管线。
- **待验证（2026-10-15 重建后）**：亮屏按电源键休眠 → 再按唤醒（应正常亮屏，旋转/传感器不受影响），
  且 `journalctl -b -k | grep disp_cc_pll0` 为空。
- **注意**：这是内建 `msm` 驱动；模块 overlay 同样会应用到 7.2 树，7.2.7 对应代码段一致，迁移时需复验。

#### 2.4.1 2026-10-16 复现：真正的失败链（诊断内核 `no_console_suspend pm_debug_messages`）
上面「PLL 常开」那一层是必要的，但它**不是** s2idle 失败的全部。让 console 在挂起期间不停后，
`serial-debug` 产品上 `systemctl suspend` 的真实时间线（串口，`6.14.11-nabu-full`）：
```
 55.80  qcom-camss ac65000.camss: VFE reset timeout / Failed to power up pipeline: -5   (x4)
 56.24  PM: suspend entry (s2idle)
 56.27  arm-smmu 15000000.iommu: Unhandled context fault: fsr=0x402, iova=0x201541c0,
        fsynr=0x760042, cbfrsynra=0x800, cb=11     → SID=0x800 == mdss（显示）读 fault
 57.06  hrtimer: interrupt took 3973922 ns           ← 4 秒关中断延迟，有东西卡在临界区
 57.54  qcom-camss ac65000.camss: CSID reset timeout
 60.22  geni_spi c84000.spi: Can't set CS when prev xfer running   ← 触屏 SPI 也卡死
 60.50  hw recovery is not complete for ctl:1                        ← DPU CTL 复位失败
 60.52  [dpu error]enc32 intf1 ctl 1 reset failure: -22
 60.80  [dpu error]enc32 frame done timeout / vblank timeout: 200c1
 68.22  Freezing user space processes                ← freeze 在 dpm_suspend *之后*
 73.41  Freezing remaining freezable tasks
 93.49  Freezing remaining freezable tasks failed after 20.077 s (1 tasks refusing to freeze)
 93.86  task:jbd2/sda32-8 state:D  __bio_queue_enter ← blk_mq_submit_bio ← jbd2_journal_commit_transaction
 93.90  Restarting kernel threads ... done / Restarting tasks ... done / PM: suspend exit
187.61  ufshcd-qcom 1d84000.ufshc: ufshcd_uic_hibern8_exit: hibern8 exit failed. ret = -110
        ufshcd_err_handler ... link is broken                      → UFS 掉链后自愈
```
**结论修正**：s2idle **不是**卡在「显示 resume」。它是被 **jbd2 拒绝冻结**（20 s 超时）而
**主动中止**（`PM: suspend exit`）；与此同时显示 SMMU fault 把 DPU 打死、UFS 掉链、USB gadget 死掉，
所以整机表现成「黑屏 + 断网 + 无 console，只能长按重启」。关键顺序：`dpm_suspend`
（含显示/UFS 拆卸）**先于** `freeze_processes`，UFS 队列此刻已被冻结 → jbd2 提交事务阻塞 →
拒绝冻结。`SID=0x800` 已确认属 `mdss`（`sm8150.dtsi:3823 iommus = <&apps_smmu 0x800 0x420>`，
在 `mdss: display-subsystem@ae00000` 内；相机是 `0x840`）。

**下一刀（决定性实验，不走 s2idle）**：只做 **DPMS-off 熄屏**
（`echo Off > /sys/class/drm/card0-DSI-1/dpms`），看是否同样触发
`iova=0x201541c0 / SID=0x800` 的 SMMU fault：
- **触发** → 是 DPU/mdss **disable 路径本身**的 bug，可在 `nabu-display` 内修；修好后
  「电源键熄屏 / 再按亮屏」即可用，不必依赖 s2idle；
- **不触发** → 属 s2idle 低功耗路径（RPMh/interconnect）的共享资源塌陷
  （显示 + 相机 + SPI + UFS 同时崩指向这一类）。

#### 2.4.2 2026-10-16 定性：真凶是 `qcom_iris` + `qcom_camss`（已修）
沿 2.4.1 那条线继续查，发现**显示/SMMU/DPU/jbd2/UFS 全都是下游症状**，最初的污染源是两个
**实验模块**在开机后被 `wireplumber`（UID 1000）自动探测时把系统电源域/时钟状态搞坏：
```
WARNING: CPU: 7 PID: 1645 Comm: wireplumber at drivers/clk/qcom/gdsc.c:178 gdsc_toggle_logic
  venus_gdsc status stuck at 'off'                 ← 视频(Venus)电源域开不起来
     gdsc_toggle_logic ← gdsc_enable ← _genpd_power_on ← genpd_runtime_resume
WARNING: ... drivers/clk/qcom/clk-branch.c:87 clk_branch_toggle
  cam_cc_ife_lite_0_clk status stuck at 'on'       ← 相机时钟关不掉
     clk_branch_toggle ← clk_branch2_disable ← clk_disable ← camss_disable_clocks [qcom_camss]
qcom-iris aa00000.video-codec: failed to resume from power collapse
```
第一个启动里这类 `stuck at` WARN 会刷出**几百行**；把两个模块拉黑后，**同一启动里 0 条**。
（另注：cmdline 里原有的 `module_blacklist=venus_core` 是**无效的旧名字**，真正加载的是
`qcom_iris`；`module_blacklist=` 连手动 `modprobe` 也会被拒，必须写进 cmdline。）

**修复（`nabu-main`，cmdline）**：把 `qcom_iris,qcom_camss,ov13b10,ov8856,cn3927` 加进
`module_blacklist=`（`debian/config/debian.cmdline`、`config/production.cmdline`，
serial-debug 同理）。实测（2026-10-16，`6.14.11-nabu-full`，`serial-debug`）：
```
PM: suspend entry (s2idle) → PM: Triggering wakeup from IRQ 230 (rtc) → PM: suspend exit
```
**亮屏状态下连续 4 轮 suspend/resume 全部干净**：`dpms=On` 回来、WiFi(ath10k) 存活、
**无** `arm-smmu ... context fault`、无 `disp_cc_pll0`/`Failed to prepare clk 'core'`、
无 `hw recovery is not complete for ctl:1`、无 `refusing to freeze`/`ufshcd ... link is broken`。
**代价**：视频硬解（`nabu-iris`/VA-API）与相机不可用，直到修好下面这条。
**遗留**：① `venus_gdsc`（`flags=0`）在 SM8150 上软件上电失败、`cam_cc_ife_lite_0_clk` 关不掉，
是这两个驱动自身的 GDSC/时钟 bug（上游 6.18 也无修法），修好即可恢复视频/相机；
② resume 时触屏 `nvt_download_firmware_hw_crc` 会重试数次后成功（`Update firmware success!`），
可用但偏慢。

#### 2.4.3 2026-10-16：按电源键唤醒后黑屏（已解决：resume 后 gnome-shell 的伪熄屏）
2.4.2 之后 s2idle 已干净，但**按电源键唤醒后屏幕仍是黑的**（`dpms=Off bl_power=4`，而系统是醒的、
SSH 可达）。journal 里每次 resume 都有：
```
gnome-shell: Object .MetaInputDeviceNative (0x...) has been already disposed
  #0 keyboard.js:1099   #1 keyboard.js:1105
gnome-shell: JS ERROR: Error: Argument descendant may not be null
  maybeHandleEvent@resource:///org/gnome/shell/ui/keyboard.js:1165
  vfunc_captured_event@resource:///org/gnome/shell/ui/unlockDialog.js:654
```
**结论（2026-10-16 实机验证，已解决）**。排查过程中误判过两次，都被实测排除：

1. **不是**解锁界面的 JS 异常：上面那段异常每次 resume 都出现（4 次），但锁屏保持开启时实测
   RTC 唤醒照样 `dpms=On bl_power=0` + `LockedHint=yes`，不影响亮屏。
2. **不是**「按键在挂起进入过程中把挂起打断」：用 2 秒的 RTC 闹钟刻意在进入阶段唤醒，
   复现不出来（`dpms=On`）。

**真正的根因**：resume 之后 gnome-shell 的 idle watch 处于残留状态，会在唤醒后**约 25–30 秒
自己把屏灭掉**（`blank=1`），而**系统是醒的**（并不是挂起）。于是出现「屏灭但没挂起」的窗口；
又因为 GNOME 的 `power-button-action='suspend'` 对**每一次**电源键按下都执行挂起，此时按下就变成
「再挂起一次」→ 表现为「按一下不亮、要按两下」。证据：
- 新锁屏（状态干净）后 90 秒不灭；resume 之后则约 30 秒就灭；
- `idle-delay=0`（或刷新会话状态）后，RTC 唤醒连续 90 秒 `dpms=On` 稳定。

**处置**（全部用 GNOME 原生配置；**未新增任何自定义服务**，也**未修改镜像 dconf 默认值**）：
- 保持 stock：`power-button-action='suspend'`、`screensaver lock-enabled=true`（唤醒停在登录页）；
- 设备上每用户把 `sleep-inactive-ac-timeout` 设成与 `idle-delay` 相等（300），让**熄屏与挂起
  同时发生**，不再有「已熄屏但未挂起」的窗口；空闲 5 分钟自动睡，按一下休眠 / 按一下唤醒。
- 该项是**用户 dconf 里的每用户设置**，按约定**不固化进镜像**（`/etc/dconf/db/` 保持原样）。

**附**：`/sys/class/drm/*/dpms` 在 6.14 已是只读，熄屏要经合成器
（`gdbus ... ScreenSaver.SetActive true/false`）或 `loginctl`；`module_blacklist=` 连手动
`modprobe` 都会被拒，实验模块只能写进 cmdline。

#### 2.4.4 2026-10-16：视频编解码（Venus/iris）的 GDSC 修复 —— `qcom_iris` 不再需要拉黑（已解决）
2.4.2 里 `qcom_iris` 之所以要拉黑，是因为它的电源域起不来：
```
venus_gdsc status stuck at 'off'
  gdsc_toggle_logic <- gdsc_enable <- _genpd_power_on <- genpd_runtime_resume
```
根因在时钟驱动：SM8150 的 **MVSC 域（`venus_gdsc`，`videocc-sm8150.c` 的 0x814）和 MVS0/MVS1
一样是「硬件控制」掉电的域**，但 mainline 把它标成了纯软件控制（`flags = 0`）。于是软件写
`PWR_ON` 被硬件忽略，`gdsc_enable()` 一直轮询 → `stuck at 'off'`，并把这一路 genpd 状态拖坏，
进而让**整个系统 suspend 崩**（就是 2.4.1 那条链的起点）。

**修复（`nabu-iris` overlay `drivers/clk/qcom/videocc-sm8150.c`）**：
```c
static struct gdsc venus_gdsc = {
	.gdscr = 0x814,
	...
	.flags = HW_CTRL_TRIGGER,   /* 原为 0 */
```
与其兄弟 `vcodec0_gdsc`/`vcodec1_gdsc` 一致。驱动侧**无需改动**：`qcom_iris` 已经会用
`dev_pm_genpd_set_hwmode()` 正确处理 `HW_CTRL_TRIGGER`。

**实测（2026-10-16，`6.14.11-nabu-full`，`serial-debug`，相机仍拉黑）**：
- 保持 `/dev/video0` 打开期间，`/sys/kernel/debug/pm_genpd/{venus,vcodec0,vcodec1}_gdsc/current_state`
  三者全部 `on`；关闭后干净回到 `off`；整次启动 `stuck at` **0 次**。
- **在三个域都是 `on` 的状态下** `rtcwake …; systemctl suspend`，**连续 3 轮**全部干净：
  `dpms=On bl=0`、WiFi 存活、无 `arm-smmu … context fault` / `dpu error` / `refusing to freeze` /
  `hw recovery`，且 resume 后三个域仍为 `on`。
- **解码实测（2026-10-16，ffmpeg 7.1.5，`hevc_v4l2m2m` 走内核 V4L2 M2M 即 iris）**：
  - `Test Jellyfin 1080p HEVC 8bit 20M.mp4`：1797 帧全解，~663 fps（约 11 倍实时）；
  - `Test Jellyfin 4K HEVC 8bit 60M.mp4`（3840x2160@60，~59 Mbps）：1797 帧全解，
    ~179 fps（约 3 倍实时）；解码期间 `venus/vcodec0/vcodec1` 三个域均 `on`，dmesg 无错误；
  - **先解码 → `systemctl suspend` → 唤醒 → 再解码**：唤醒后 `dpms=On`，解码性能不变
    （173 → 171 fps），全程无 `stuck at` / SMMU / DPU / jbd2 报错。
- 因此 cmdline 里**移除 `qcom_iris`**（`nabu-main`），视频硬解恢复。**相机仍保留拉黑**：它有另一个
  `cam_cc_ife_lite_0_clk status stuck at 'on'`（同类问题，尚未修）。
- **后续项 ①**：驱动**未注册 media device**（系统里没有 `/dev/media*`），所以依赖 media controller
  拓扑的消费者用不了它（GStreamer 的 `v4l2h265dec` 会直接拒绝 caps，`v4l2slh265dec`/`vaapih265dec`
  也不出现）；直接用 `/dev/video0` 的消费者（ffmpeg `hevc_v4l2m2m`）正常。
- **VA-API（`iris-vaapi`）实测（2026-10-16）—— 两个问题，第一个已修**：
  1. **已修：打包缺口**。原 `nabu-userspace` deb 只覆盖 `/usr/local`（`overlay_nabu_userspace()` 也是逐个手写模块文件 —— 所以 `/etc/modprobe.d/qcom-iris.conf` 在、VA 驱动却不在），
     重新刷 rootfs 后 VA 驱动会丢。改法（`nabu-main` `f4fa5a4`）：新增通用的
     `stage_module_install_entries()`，**遍历各兄弟模块的 `nabu-module.toml`**，把 `[install]` 里属于
     rootfs 的条目按其 `[artifacts]` 声明的来源落进镜像（排除 `/lib/modules`、`/lib/firmware`），
     已存在的不覆盖；fresh 与 reused rootfs 两条路径都调用。`nabu-main` 里不含任何模块名字面量。
     **实测**：构建镜像后直接检查 `debian/work/rootfs/` →
     `usr/lib/aarch64-linux-gnu/dri/vpu_drv_video.so` ✓、
     `etc/modprobe.d/qcom-iris.conf` ✓、`usr/share/libcamera/ipa/simple/ov13b10.yaml` ✓。
  2. libva 找不到入口符号：
     ```
     libva: .../vpu_drv_video.so has no function __vaDriverInit_1_0
     Failed to initialise VAAPI connection: 1 (operation failed)
     ```
     源码里**硬编码**了 `__vaDriverInit_1_23`，而 libva 按自己版本（平板 2.22）从
     `__vaDriverInit_1_<minor>` 往下找到 `1.0`。**已修**（`iris-vaapi` `125413b`：以 1.0 为入口，
     其余名字转发）。修后 `LIBVA_DRIVER_NAME=vpu ffmpeg -hwaccel vaapi` 解 1080p60 全片
     **1797 帧 / ~382 fps**，4K60 正常，全程走 `/dev/video0`。
- **VA-API 会话后的偶发 wedge（约 1/3）—— 根因找到并已加恢复**。现象：VA-API 解码结束后，驱动偶发连刷
  `failed to resume from power collapse` / `power on failed` / `core init failed`，此后
  `open /dev/video0` 直接 `EINVAL`，**再挂起会卡死**（只能重启）。
  - **真正的根因**（读代码定位，与寄存器顺序无关）：`iris_v4l2_open()` 对
    `iris_pc_resume()` 的失败**只 `dev_warn`**，流程继续；而紧跟其后的 `iris_core_init()`
    因为 `core->state` 仍是 `IRIS_CORE_INIT`，开头就 `return 0` —— 于是在「VPU 已死」的状态下
    **照常交出会话**，设备从此留在坏状态，进而把下一次系统挂起拖死。现成的
    `iris_core_recover()`（`deinit` = PAS shutdown + 断电 + 队列 deinit；`init` = 上电 + 固件重载
    + HFI 重 init）**只在 `state == ERROR` 时才被调用**，所以这条路径根本不触发。
  - **修复**（`nabu-iris` `b9c26ae`）：① PC 恢复失败 → 强制 `iris_core_recover()` 完整重启 VPU；
    ② `iris_core_deinit()` 里清 `vpu_suspended` 并取消延迟 collapse 工作，避免陈旧 worker 把刚重启
    好的 core 再压下去。
  - **实测**（`nabu-iris` `b9c26ae` + **模块真正加载**后，2026-10-17）：连续 **12 轮**
    「VA-API 4K 解码 → 挂起 → 唤醒 → 再解码」，`decode-after=ok`、`up` 单调递增（无重启）、
    `power on failed` / `failed to resume from power collapse` / `restarting the core` 计数均为 **0**
    （偶发失败本轮未复现，恢复路径未被真实触发，但代码路径已就位）。
  - **运维要点（我为此白跑了好几轮）**：`nabu-iris` 等**内核模块在 rootfs 的
    `/lib/modules/<release>/kernel/...`**，只替换 UKI **不会**更新它们（UKI 里的只是 initrd 副本，
    运行期加载的是 rootfs 里的）。改模块必须把 `.ko` 拷到对应路径 + `depmod -a`，
    或走 `make install-modules`。上面一度写的「6 轮」其实是**旧模块**跑出来的数据。
  - **反面证据 1（实测，勿重蹈）**：写 legacy VPU5 的 `WRAPPER_VCODEC0_MMCC_POWER_CONTROL`
    （`iris_vpu_set_vcodec_hw_control()`，端口自造的那套）—— **整机在启动时 wedge 死**
    （平板启动卡死，只能还原 UKI）。那些寄存器确实碰不得。
  - **反面证据 2（实测，勿重蹈）**：按厂家做法、改用**框架级** `dev_pm_genpd_set_hwmode()` 把
    MVS0/MVS1 切到硬件模式（等价于厂家 `qcom,support-hw-trigger` +
    `regulator_set_mode(REGULATOR_MODE_FAST)`，时机也对：codec 时钟之后、固件启动之前）——
    power-on 侧确认生效（`vcodec power: handing the MVS GDSCs to hardware control`），
    **但解码随即静默挂起**（`open` 不再返回，也不进入错误路径，恢复机制无从介入）。
    厂家能用硬件模式，是因为它**整条 PC 序列**都配套（`VIDEO_CTRL_STATUS_PC_READY`、
    `VIDEO_WRAPPER_CPU_STATUS` 的 WFI/idle 位轮询、`__prepare_pc`、最多 10 次重试、失败回退等）；
    只补 handoff 这一步会让解码崩掉。→ 端口「MVS 保持软件模式」的选择是**对的**，已回退。
  - 因此**没有**采用 `qcom_iris.power_collapse=0`（那等于「VPU 一直供电」）当修法；正解就是上面的
    「失败即自动完整重启 VPU」。

#### 2.4.5 2026-10-17：相机（`qcom_camss`）已解禁 —— 「必须拉黑」结论被推翻（旧模块造成的假象）
**【更正 2026-10-17 晚：下面那段「必须拉黑」的结论是错的】** 旧结论来自**rootfs 里的旧
`qcom_camss.ko` / `camcc-sm8150.ko`**（见 2.4.6 的运维要点）。换上端口当前代码编译出来的模块后实测：

- **相机 + iris 共存**：连续 3 轮「VA-API 解码 → 挂起 → 唤醒 → 再解码」全部 `decode-after=ok`，
  `Failed to power up pipeline` / `power on failed` 计数 **0**，`up` 单调递增（无重启）。
- **相机功能**：media 图里 `ov13b10 3-0010` / `ov8856 4-0010` 已 ENABLED 链到 CSIPHY；
  `cam -l` 列出 **Internal back camera / Internal front camera**；
  `cam -c 1 --capture=1 --file=…` **真的出一帧**（1,314,816 字节），事后失败计数仍为 0。
- **动作**：`qcom_camss,ov13b10,ov8856,cn3927` 已从**全部** cmdline 的 `module_blacklist` 移除。
- **遗留（功能层）**：libcamera 报 `ov13b10/ov8856 ... Unable to get rectangle … Inappropriate
  ioctl for device`（传感器驱动缺 selection/crop API），软件 ISP 报 `Algorithm 'Ccm' not found`；
  不影响出帧，完整 3A / 通用拍照仍需后续补。

**以下是被推翻的原始记录（保留下来，用来说明「旧模块」能造成多大的误判）**：那次放开实测
（**用的是旧模块**）得到的结论是「确实不能放开」，原因记成：

- **它不再破坏 s2idle**：相机模块加载后连续挂起/唤醒正常（3 轮 `up` 递增、`dpms=On`、
  `stuck at`=0、无 `refusing to freeze`）。也就是说 2.4.1 那条链的源头是 venus GDSC（已修），
  不是相机。
- **但它自己上不了电，而且会把视频一起打死**。开一次解码时同一时刻两条日志：
  ```
  [185.12] qcom-camss: video_open → vfe_pm_domain_on → vfe_get → vfe_set_power
           qcom-camss ac65000.camss: Failed to power up pipeline: -5 / -22   (反复)
  [185.12] qcom-iris: power on failed / core init failed                     ← 同一瞬间
  ```
  实测：**相机启用时 3/3 挂起后解码失败**；拉黑后 **12/12 正常**。→ 两者**共用电源资源**，
  相机上电失败会连累视频。
- 早先那条 `cam_cc_ife_lite_0_clk status stuck at 'on'` 只是同一问题的表征
  （`clk_branch2_disable` 在 `camss_disable_clocks` 里关不掉），不是根因；该时钟的定义与
  厂家**完全一致**，而 6.14 与 6.18 的 `camcc-sm8150.c` **逐字相同**。
- **不是一行 flag 能修的**：厂家 DTS 给 `bps_gdsc`/`ipe_0_gdsc`/`ipe_1_gdsc` 标了
  `qcom,support-hw-trigger`（mainline 这几个 GDSC 都没有），但**失败的是 IFE**，而厂家**也没给
  IFE 标**该属性 —— 说明 sm8150 相机在 mainline 上的 VFE 上电链路本身就没打通。
- **（已被上方更正推翻）当时的结论**：相机维持拉黑。要恢复需按 2.4.4 的方法做完整 bring-up（对比厂家
  `sm8150-camera.dtsi` 里各 GDSC 的 `parent-supply = <&VDD_MMCX_LEVEL>`、
  `GCC_CAMERA_AHB_CLK`、`msm-bus` 投票与 IFE/IPE 电源时序），属独立的大任务。

#### 2.4.6 运维要点：内核模块在 rootfs，不在 UKI 里（这个坑踩了三次）
`nabu-iris` / `nabu-camera` 等**内核模块安装在 rootfs 的
`/lib/modules/<release>/kernel/...`**。只替换 UKI 只更新 initrd 副本，**运行期 modprobe 加载的仍是
rootfs 里那份**，所以改完模块必须：
```
scp <module>.ko <tablet>:/tmp/
sudo install -m0644 /tmp/<module>.ko /lib/modules/<release>/kernel/<path>
sudo depmod -a <release>            # 或直接 make install-modules
```
**这个坑直接造成过三次错误结论**：iris 的「PC 恢复修复」在旧模块上测（2.4.4 一度写错）、
相机的「必须拉黑」在旧模块上测（2.4.5 完全误判）、以及最早那轮「解码失败」。
**判断模块是否最新**：`grep -ac "<新代码里的字符串>" /lib/modules/<release>/.../<m>.ko`，
与 `nabu-main/artifacts/<product>/<m>.ko` 对比即可。

#### 2.4.7 2026-10-17：GNOME 相机（Snapshot）出画面 —— 两个坑，其一已修

用 `cam` / GNOME Snapshot 实测相机，过程中定位到两个问题。

**坑 1：`camera-tuning/*.yaml` 会让 libcamera 0.4.0 的软件 ISP 直接失效（已修）**

镜像里是 libcamera **0.4.0**（Debian trixie），它的 simple IPA 只实现
`BlackLevel / Awb / Lut / Agc`；而 `nabu-camera` 装进镜像的调参 yaml 是给
**0.7.0** 写的，要求 `Ccm` + `Adjust`：

```
ERROR IPAModuleAlgo module.h:79         IPASoft: Algorithm 'Ccm' not found
ERROR SoftwareIsp software_isp.cpp:133  IPASoft: IPA init failed
```

`IPA init failed` 会让软件 ISP **完全不工作**（一帧都不出），比不装调参文件更糟 ——
不装时 libcamera 回落到自己的 `uncalibrated.yaml`，ISP 正常起来（只是没标定）。
**`nabu-camera` `9ad56ff`** 去掉这两个 `[install]` 条目；文件保留在树里，并新增
`camera-tuning/README.md` 说明「需要 libcamera ≥ 0.5」。

**坑 2：VFE 被失败的流“卡住”后，之后所有流都 overflow（重启即恢复）**

排查时反复起停流（尤其是 ISP 初始化失败的那些）之后，dmesg 开始出现：

```
qcom-camss: VFE0 IRQ: ... cfg=00000003 addr=00000000 width=0000ff01 ... inc=009a9a00
qcom-camss: VFE0 RDI overflow: status1=00000004 violation=00000000   （每 0.5–1 ms 刷一次）
```

此时 `cam0: Capture N frames` 之后**永远收不到帧**（连 1280x720 也一样），
而**重启后同样的命令 30fps 正常出帧**。

判断要点：
- `width/stride = 0xff01` 是上游 `WM_BUFFER_DEFAULT_WIDTH` /
  `WM_STRIDE_DEFAULT_STRIDE` 的**正常默认值**，不是异常；真实宽高在
  `VFE_BUS_WM_IMAGE_CFG_0`。
- `status1` 那段判定来自端口自己加的调试代码（`dev_err_ratelimited`），
  **“RDI overflow” 这个标签并不可靠**；判断有没有帧应该看 `cam` 输出的
  `seq:` 行或文件是否落盘。

→ **相机调试时流失败后先重启再测**，否则会把 VFE 的残留状态当成新 bug。

**验证结果（干净启动后）**

```
configuring streams: (0) 1632x1232-ABGR8888
35.99 (30.08 fps) cam0-stream0 seq: 000001 bytesused: 8042496
```

- ISP 路径稳定 **~30 fps**；raw 路径（`3272x2464-RGB888`）同样 ~30 fps
- AGC 约 **10 帧**收敛（第 0 帧很暗），AWB 约 **25 帧**收敛（前十几帧明显偏绿）
- GNOME Snapshot 48.0.1 能启动、经 `xdg-desktop-portal` → PipeWire 打开相机，
  dmesg 无 overflow / 失败

**仍存在的功能缺口（不影响出画面）**

- **颜色未标定**：0.4.0 没有 `Ccm` 算法，端口的 CCM 用不上（见坑 1）
- `IPASoft: Failed to create camera sensor helper` 是 **cosmetic**（见
  `nabu-camera/patches/README.md`），AGC 走 fallback，行为一致
- 传感器驱动缺 selection/crop API —— **已在 2.4.8 修掉**

#### 2.4.8 2026-10-17：补上传感器 selection API —— 预览从 1632x1232@30fps 变 1640x1232@60fps（已修）

libcamera 的 sensor 支持会问 `V4L2_SEL_TGT_CROP` / `_CROP_BOUNDS` /
`_CROP_DEFAULT` / `_NATIVE_SIZE`；`ov8856` 和 `ov13b10` 都没实现
`get_selection`，于是每次都刷：

```
'ov8856 4-0010': Unable to get rectangle 0/1/2 on pad 0/0: Inappropriate ioctl for device
'ov8856 4-0010': The sensor kernel driver needs to be fixed
The PixelArraySize property has been defaulted to 3280x2464
```

拿不到像素阵列还有实际后果：libcamera 在请求 1640x1232 时自己裁成
**1632x1232**，并要多做一层软件缩放。

**`nabu-camera` `3472712`**：两个驱动都实现 `get_selection` ——
`NATIVE_SIZE` / `CROP_BOUNDS` / `CROP_DEFAULT` 返回原生像素阵列
（ov8856 `3280x2464`、ov13b10 `4208x3120`），`CROP` 返回当前模式尺寸。

实机验证（同一台、重启后）：

| | 之前 | 之后 |
|---|---|---|
| 上表三条 libcamera 警告 | 有 | **0** ✓ |
| 预览配置 | `1632x1232-ABGR8888` | **`1640x1232-ABGR8888`** ✓ |
| 帧率 | ~30 fps | **~60 fps** ✓ |

#### 2.4.9 2026-10-17：标准 GNOME 相机卡 Loading —— 是 GStreamer 的问题，不在内核

底层全通（2.4.7 / 2.4.8，`cam` 30–60fps），但**未打补丁的标准 GNOME Snapshot
48.0.1 永远停在 Loading**。定位过程与结论：

- Snapshot 经 `xdg-desktop-portal` 的 Camera 接口 → PipeWire 相机节点 ✓，
  该节点确实拿到帧（`Debayer: Processed 30 frames …`）✓，但只流一阵就停 ✗
- `snapshot -d` + `GST_DEBUG=3` 显示卡点：

```
DEBUG aperture::viewfinder: Trying to set camerabin state to Playing   ← 之后 26s 无任何输出
FIXME decodebin3: Re-use existing input streams if/when possible
FIXME glcontext: wrapped context could not retrieve config
ERROR pipewiresrc gstpipewiresrc.c:586: buffer … was not recycled
```

  ⇒ **`camerabin` 卡在异步切到 PLAYING**（viewfinder sink 无法 preroll），
  与内核无关；`nabu-camera/camera-app/gnome-snapshot-50.0-nabu.patch`
  正是为此打的补丁（去掉 `decodebin3`、viewfinder 直连 capsfilter、pin 前置预览分辨率、
  180° 旋转），但**用户要求不改 Snapshot**。

- **同时证伪了该补丁注释里的一个前提**：补丁说
  "the front OV8856 (2-lane) cannot stream above ~1632x1224 — its 8 MP sensor mode
  does not work"。**在当前内核上不成立**：

```
configuring streams: (0) 3280x2464-ABGR8888
1006.676455 (29.48 fps) seq: 000004
1006.844057 (29.80 fps) seq: 000009        ← 前置 8MP 稳定 30fps
camss errors = 0
```

  所以「8MP 不能流」不是内核缺口，**不需要也不能在内核里修**。

**结论**：内核侧相机工作已完成；要让**标准** Snapshot 出预览，要动的是 userspace 的
GStreamer 链路（`decodebin3` / `pipewiresrc` 的回收语义），不是内核。

#### 2.4.10 2026-10-17：不走 portal 的取图路径 —— `libcamera-v4l2` 不可用，`cam` 可用

在 2.4.9 之后评估了「让标准 V4L2 应用直接用相机」这条替代路，结论如下。

**`libcamera-v4l2` 兼容层在 libcamera 0.4.0 上不可用**：

- 兼容层在 `/usr/libexec/aarch64-linux-gnu/libcamera/v4l2-compat.so`，`LD_PRELOAD` 后
  `/dev/video0` 的 `VIDIOC_ENUM_FMT` 确实返回 ISP 的 `NV12`/`P010`（96x96–8192x8192）✓
- 但 **`VIDIOC_QUERYCAP` 没有被虚拟化**，返回的是该节点真实驱动的能力位
  （本机 `/dev/video0`、`/dev/video1` 是 iris 的 Decoder/Encoder，`0x84204000`
  = M2M Multiplanar），于是 ffmpeg 直接拒绝：
  `[video4linux2,v4l2] Not a video capture device.`
- 用 `v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=12 --stream-to=…`
  能配置但**出 0 字节** ✗

**可用的路径是 libcamera 直连（`cam`）**：

```
cam -c 1 --capture=25 --file=/tmp/shot -s width=1640,height=1232
# → configuring streams: (0) 1640x1232-ABGR8888, ~60 fps, 25 帧连续落盘
```
ABGR8888 在 ffmpeg 里就是 `bgra`，取最后一帧即可（AGC 约 10 帧、AWB 约 25 帧收敛）：

```
tail -c $((1640*1232*4)) /tmp/shot > last.bgra
ffmpeg -f rawvideo -pix_fmt bgra -s 1640x1232 -i last.bgra shot.png
```

已封装为 **`nabu-camera/scripts/nabu-shot.sh`**：
```
nabu-shot.sh [-c 相机] [-w 宽] [-H 高] [-n 帧数] out.png
```
实测：25 帧、59.8 fps、`camss errors = 0`、输出 1640x1232 PNG（约 4.7 MB）。

注意：libcamera 相机是**独占**的，用这条路径前要先关掉占着相机的应用
（`pkill -x snapshot`；PipeWire 只是 probe 时短暂打开，不冲突）。

#### 2.4.11 2026-10-17：「电源键无法唤醒」的真正根因 —— dispcc 用了 sm8250 的 PLL 配置（已修）

按要求只动内核，把「休眠后无法唤醒」一路查到显示时钟。

**现象**：开机后**第一次**挂起正常 ✓，之后**每一次**都卡死在挂起里 ✗
（串口 15 分钟无输出 ✗，任何唤醒源都无效 ✗，只能长按强制重启 ✗）。

**现场**（`console=ttyGS0` + `no_console_suspend`）：

```
disp_cc_pll0 failed to enable!
WARNING: CPU: 2 PID: 592 at clk-alpha-pll.c:406 wait_for_pll
CPU: 2 PID: 592 Comm: systemd-logind
 wait_for_pll <- clk_trion_pll_enable <- alpha_pll_trion_prepare <- clk_core_prepare
```
随后 `disp_cc_mdss_ahb_clk already disabled / already unprepared`、
`msm_dsi_phy ae94400.phy: Runtime PM usage count underflow!`、
`Failed to disable vdds: -EIO` 连锁出现 ✗，挂起再也走不完 ✗。

**根因**：nabu 的 `compatible = "qcom,sm8150-dispcc"` 在 mainline 里由
**`dispcc-sm8250.c`** 匹配（`CLK_ALPHA_PLL_TYPE_LUCID` 就是
`CLK_ALPHA_PLL_TYPE_TRION` 的别名，**寄存器布局本身没问题**），但
`disp_cc_pll0` 的**配置值整套是 sm8250 的**：

| 字段 | sm8150（厂家 `dispcc-sm8150.c`） | sm8250（nabu 实际在用的值） |
|---|---|---|
| `config_ctl_hi_val` | `0x00002267` | `0x00002261` |
| `config_ctl_hi1_val` | `0x00000024` | `0x329A699C` |
| `test_ctl_val/hi/hi1` | `0x0` / `0x2` / `0x0` | 未设置 |
| `user_ctl_hi1_val` | `0x000000D0` | `0x00000000` |

bootloader 已经让 PLL 跑起来，所以面板一开始能亮；但 **Linux 一旦把它关掉，
就再也使能不起来**（`PLL_ACTIVE_FLAG` 永不置位）⇒ 第一次挂起（其 resume 会关/开显示）
之后，**之后每次挂起都在这里卡死**。

**修法**：`nabu-display` 新增
`kernel-overlay/drivers/clk/qcom/dispcc-sm8250.c`，把 `disp_cc_pll0_config`
换成厂家的 sm8150 值（注释里写明出处与失败模式）。

**实机验证（内核 `#78`）**：同一次挂起的串口里
`disp_cc_pll0` / `disp_cc_mdss_ahb_clk` / `underflow` / `vdds` 告警**全部为 0** ✓，
`nvt_drm_notifier_callback: event=1, *blank=0` ✓（显示正常解黑），并出现
`Debian GNU/Linux 13 nabu-debian ttyGS0` 登录提示 ✓。

**遗留**：
- **唤醒后 WiFi 不自动恢复** ✗（`ath10k_snoc` resume 路径；需 `systemctl restart
  NetworkManager` 或重启）——与本次 PLL 问题无关。
- 触摸屏 resume 时 `nvt_ts_resume: download firmware failed` ✗（触摸仍能恢复）。
- `dispcc-sm8250.c` 是 sm8250/sm8150 **共用**文件，当前改动只服务 nabu；应按
  compatible 拆分，避免影响 sm8250。

#### 2.4.12 2026-10-17：第二次挂起卡死 —— iris 的 PC 恢复链是坏的，改法已回退

2.4.11 修好显示 PLL 后，用户实测结果是「**第一次能唤醒 ✓，第二次不行 ✗**」。
现场（串口）显示第二次挂起时问题**换到了 iris 那一侧**：

```
video_cc_mvs0_core_clk / video_cc_mvs1_core_clk already disabled
video_cc_mvsc_core_clk / video_cc_iris_ahb_clk already disabled
gcc_video_axi0_clk / gcc_video_axi1_clk / gcc_video_axic_clk already disabled
genpd genpd:1:aa00000.video-codec: Runtime PM usage count underflow!
```

**尝试的改法（已回退）**：`iris_core.c` 在关闭会话断电后把 `vpu_suspended`
从 `false` 改成 `true`（它正是 `iris_hfi_pm_suspend()` 的守卫），
理由是「VPU 确实已断电，标记不该被清掉」。实测结果：

- ✓ **两次挂起都能完整走完**（journal 里 `suspend entry` / `suspend exit` 各 2 次）
- ✗ **但唤醒后解码器再也起不来**：

```
qcom-iris: power on failed
qcom-iris: failed to resume from power collapse
qcom-iris: restarting the core failed: -22
qcom-iris: core init failed
```

即标记置位后，挂起路径会去走「从 power collapse 恢复 → 重新引导固件」，
而**这条恢复链在 SM8150 上本身就是坏的**（与 2.4.2/2.4.4 的结论一致：
MVS GDSC 保持软件模式是对的，PC handoff 不可用 ✗）。
**用挂起换来解码功能丧失属于功能回归，因此已回退** ✓：
`nabu-iris` 的 `iris_core.c` 恢复原样，iris 模块重装后**解码器恢复可用** ✓。

**当前状态**

- ✓ 显示 PLL（2.4.11）已修，**用户实测确认**：第一次休眠 → 电源键唤醒可用
- ✗ 第二次挂起仍会卡死（根因：iris 的 PC 恢复链坏）

**未决的下一步**

1. **修 PC 恢复链**：查 `iris_vpu_power_on_hw()` 的 `defer_vcodec_power` 分支里
   `pm_runtime_resume_and_get(pd_dev)` 为何返回 `-22`，以及重启 core 路径为何失败。
2. **SM8150 上不进入 PC**：空闲时不尝试 power collapse；代价是 VPU 保持供电
   （用户此前否过「一直供电」式的做法）。
3. 暂不处理：第一次休眠/唤醒可用，第二次之后需重启。

#### 2.4.13 2026-10-17：「第二次挂起卡死」已修 —— iris 的 power-off 幂等

2.4.12 的带串口 + dyndbg 复现把链条定死为**两层**：

1. **硬件限制（不改）**：SM8150 的视频 GDSC 是硬件触发 ✓（`venus`/`mvs0`/`mvs1`
   都已是 `HW_CTRL_TRIGGER` ✓），但 trace 里仍会出现 `gdsc_toggle_logic`
   轮询超时 / `... status stuck at 'off'` ✗。端口早已确认软件模式同样 stuck ✗、
   wrapper handoff 会让整机启动即死 ✗ ⇒ 正确做法是**失败后能恢复** ✓
   （`failed to resume from power collapse; restarting the core` ✓）。

2. **恢复链被自己弄坏（本条目修的）**：`-22` 来自
   `pm_runtime_resume_and_get(pd_dev)` —— genpd 的 `usage_count` 已为 0 时，
   内核会打印 `Runtime PM usage count underflow!` 并返回 `-EINVAL` ✓。
   即 `pm_runtime_put_sync(pd_dev)` 比 get **多了一次** ✗，因为
   `iris_vpu_power_off()` 被跑了两次 ✗（关闭会话的 `iris_core_deinit()`
   与 PM 路径 ✓），伴随 `video_cc_*_clk already disabled` 等连锁告警 ✓。

**修法**（`nabu-iris`）：给 `iris_vpu_power_off()` 加**幂等**保护 ✓ ——
新增独立标记 `vpu_powered` ✓（**故意不复用 `vpu_suspended`** ✓：那是 PC/固件语义，
2.4.12 里正因为复用它才把 resume 引到不通的固件重启 ✗）：

- 已断电 → 直接返回 ✓（不再重复 disable 时钟 / 重复 `put` genpd ✓）
- `iris_vpu_power_on()` 一进入就置位 ✓（部分失败也能被后续 off 收拾 ✓）

**实机验证**（完整循环 ✓）：

| 步骤 | 结果 |
|---|---|
| 解码 #1 | ok ✓ |
| 挂起 #1 → 唤醒 | `up=1 分钟 dpms=On` ✓ |
| 挂起 #2 → 唤醒 | `up=2 分钟 dpms=On` ✓ |
| **解码 #2（两次唤醒后）** | **ok ✓**（恢复链跑通 ✓）|
| `already disabled` / `usage count underflow` | **0** ✓ |
| `power on failed` | **0** ✓ |
| `suspend entry / exit` | **2 / 2** ✓ |

#### 2.4.14 2026-10-17：触摸屏 resume 的「固件下载失败」已修；WiFi 恢复为间歇

**触摸屏**：`NVT_TOUCH_SUPPORT_HW_RST = 0` ✓（没有接硬件复位 ✓）⇒ suspend 只是让
IC 进 deep sleep ✓，固件一直还在跑 ✓ —— 而 `nvt_ts_resume()` 里**无条件**调用
`nvt_update_firmware()` ✗ 既多余、又必然失败 ✓（IC 不在 bootloader 模式 ✓）：

```
nvt_check_fw_reset_state: error, retry=..
nvt_download_firmware_hw_crc: nvt_check_fw_reset_state failed
nvt_ts_resume: download firmware failed
```

改法（`nabu-touchscreen`）：把 `nvt_update_firmware()` 放进
`#if NVT_TOUCH_SUPPORT_HW_RST` ✓（只有真复位过才重下 ✓）；**保留**后面的
`nvt_check_fw_reset_state(RESET_STATE_REK)` ✓ —— 它不只是检查 ✓，而是把
deep sleep 的 IC 唤醒 ✓（第一版把这条一起删了 ✗，结果挂起走不完 ✗，已纠正 ✓）。

实测：resume 里不再有 `download firmware failed` ✓，`nvt_ts_resume … end` ✓，
挂起/唤醒 1/1 ✓，触摸可用 ✓。

遗留：`nvt_check_fw_reset_state` 仍会 `retry=51` 报错 ✗ 并耗时约 32 秒 ✗
（不影响功能 ✓，但日志噪音 + resume 变慢 ✓）。

**WiFi**：同一次唤醒里 NM 完整恢复 ✓：

```
dhcp4 (wlan0): state changed new lease, address=192.168.1.5
device (wlan0): ... -> activated
Activation: successful, device activated
```

但用户遇到的情况是 `unmanaged (reason 'unmanaged-sleeping')` 之后**再无 NM 唤醒日志** ✗
⇒ 属于**间歇性**的 NM 睡眠/唤醒竞态 ✗（非驱动问题 ✓：驱动与 netdev 正常 ✓）。

#### 2.4.15 2026-10-18：修掉 resume 的时钟引用泄漏；偶发挂起仍未定位

**已修（`nabu-display` `780bc26`）**：端口把 `msm_mdss` 换成了
`pm_runtime_force_suspend/resume`（注释称"和 DPU 用同一对"）✗ ⇒ mdss 与 DPU
每次 resume 都各自使能同一套显示时钟 ⇒ 对比一次「挂起前 → 唤醒后」的
`/sys/kernel/debug/clk/clk_summary` 可见计数普遍 +1：

```
disp_cc_mdss_pclk0_clk / pclk1_clk / byte0_intf_clk   1 -> 2
gcc_qupv3_wrap_0_s_ahb_clk / m_ahb_clk                1 -> 2
bi_tcxo                                              20 -> 21
```

改回 mainline 的 `mdss_pm_suspend/mdss_pm_resume` 后，显示与 QUP 的计数**不再变化** ✓；
只剩 `bi_tcxo` 仍 +1 ✗，它来自 `17300000.remoteproc`（ath10k ✓）。
overlay 文件现与上游**逐字节相同** ✓。

**仍未定位**：`pm_test=devices` 下仍会挂死 ✗（而且这次**第一轮**就挂 ✗，
不再是"第一次必成功"✓）⇒ 属**竞态** ✗，与 mdss 那处无关 ✓。

**已排除**：相机（整组模块黑名单下依然挂 ✗）。

**已确认的取证限制（重要）**：

- `pstore/ramoops` **不可用** ✗：配置与 DTS 都在（`ramoops@b0000000` 4MB ✓、
  `printk: legacy console [ramoops-1] enabled` ✓），但受控 panic 后
  `/sys/fs/pstore/` 仍为空 ✗ ⇒ **重启会清 DDR** ✓。
- 挂死发生在设备挂起阶段 ⇒ **任务已被冻结** ✗ ⇒ journald 写不了 ✗、
  USB 串口随设备挂起 ✗、面板也已挂起（屏幕全黑 ✗）⇒ **没有任何活通道** ✗。
- `pm_test=devices` 可以"不真正睡眠"地复现 ✗，但挂死时同样失去所有通道 ✗。

**下一步建议**：

1. 按"整类卸载/黑名单"继续二分（相机已排除 ✓；下一个：`ath10k_snoc`、
   `i2c_qcom_cci`、`qcom_slim`/`wcd934x`、`pmic-typec`）。
2. 或按 probe 顺序倒序核对每个驱动的 `.suspend/.resume` 对称性
   （iris ✓、mdss ✓ 已修；其余逐个看）。

### 2.5 睡前 hook 与挂起并发 → 整机卡死（P1，已修，待实机验证）
- **现象（2026-10-15 实机）**：亮屏、已登录图形会话时 `systemctl suspend`（或按电源键），
  系统**整机卡死** —— 之后按电源键无反应，连 RTC 闹钟也唤不回来，只能长按电源强重启。
  日志停在 `PM: suspend entry (s2idle)`，之后没有任何设备 suspend/resume 输出。
- **根因**：`nabu-sensors-suspend.service` 写的是 `Before=suspend.target`，但 systemd 里
  **`suspend.target` 是在恢复之后才到达**（`suspend.target` 是 `After=systemd-suspend.service`），
  所以这个 hook 与 `systemd-suspend.service` **并发**执行。日志证据：`Starting systemd-suspend.service`
  与 `Starting nabu-sensors-suspend.service` 同时刻，且 `Stopping hexagonrpcd.service` 出现在
  `PM: suspend entry` **之后** —— 在挂起进行中去停 hexagonrpcd（FastRPC/SLPI 拆卸）导致卡死。
- **对照**：把两个 hook `disable` 后，同样的 `systemctl suspend` 能正常挂起/恢复（显示 PLL 问题见 2.4）；
  用 `rtcwake -m freeze`（不走 systemd hook）也一直正常。
- **修复（`nabu-accelerometer` `config/nabu-sensors-suspend.service`）**：改成
  `Before=sleep.target` + `WantedBy=sleep.target`（systemd 官方的睡前 hook 点），确保在
  `systemd-suspend.service` 之前**跑完**；`nabu-sensors-resume.service` 保持
  `After=suspend.target`/`WantedBy=suspend.target`（恢复之后）。
- **待验证**：重建/替换单元并重新 `enable` 后，亮屏按电源键休眠 → 唤醒，确认不再卡死。


---

## 3. 音频（P0/P2）

### 3.1 启动偶发无声卡：SLIM NGD QMI 超时（P0，根因已定位，修复待多次重启确认）
- **现象**：某些启动后 `/proc/asound/cards` 为空、`arecord -l` 无设备，
  `snd_soc_wcd934x` 不加载，整机无声。
- **证据**（`journalctl -b -k`）：
  ```
  qcom,slim-ngd-ctrl 171c0000.slim-ngd: QMI wait timeout
  platform sound: deferred probe pending: snd-sm8150: SLIM Capture 1: codec dai not found
  ```
- **根因（2026-09-22，与 Android 对比确认）**：mainline
  `qcom_slim_ngd_up_worker()` 只用
  `wait_for_completion_interruptible_timeout(&ctrl->qmi_up, 1s)`，超时就
  `QMI wait timeout` 并**返回、不重试**；若 QMI 服务 1–2 秒后才到，SLIM 控制器
  永不注册 → WCD934x 不枚举 → 无声卡。Android/vendor 的 `ngd_dom_up()` 用的是
  **无限** `wait_for_completion_interruptible(&dev->qmi_up)`。
- **对比数据**：正常启动里 `SLIM controller Registered` + `WCD934x chip id` 都出现，
  之后那条 `QMI wait timeout` 是多余的第二次 worker；失败启动里唯一一次 worker
  超时后不再有任何注册活动。
- **修复（未提交）**：`nabu-audio` 新增 `kernel-overlay/drivers/slimbus/qcom-ngd-ctrl.c`，
  把 worker 改为无限等待（对齐 Android）；`nabu-module.toml` 增加
  `slim-qcom-ngd-ctrl.ko` 的 build/artifact/install。已交叉编译通过
  （build-id `1f1bfd00…`）。
- **验证状态（2026-09-22 三次连续启动）**：`SLIM controller Registered` +
  `WCD934x chip id` 均正常、无 `QMI wait timeout`、`/proc/asound/cards` 每次都有
  `X5`、采集非静音。已修复。
- **影响**：修复前可能每次冷启动随机丢音频；FIFO 修复也因此无法稳定验证。

### 3.2 WCD934x TX5/TX6 FIFO overflow/underflow（P0，已修复并验证）
- **现象**：录音 `drop` 后约 1.3–1.7 ms 出现 `overflow error on TX port 6`，与
  `Port Closed TX5/TX6` 同时；驱动对日志限速并在 FIFO 错误后屏蔽中断。
- **根因**：`wcd934x_trigger()` 在 STOP 时只调用 `slim_stream_disable/unprepare`
  拆掉 SLIM 通道，**没有先关闭 codec 侧 TX 端口**，于是抽取器在通道被移除后继续
  写端口 FIFO，产生 overflow。
- **修复（已提交）**：STOP 时先写 `SLAVE_PORT_DISABLE`，并用 `port_disabled` 标志
  保证只在“确实被禁用过”时于 START 重新使能（避免首次 START 的多余写复位 FIFO）；
  涉及 `kernel-overlay/sound/soc/codecs/wcd934x.c`。
- **验证（`probe-capture-lifecycle.py --cycles 3`）**：两次运行 overflow 均为
  **0**（基线 2）；12 次采集中有 1 次 `underflow on TX5` 瞬态，发生在首次
  `hw_params` 阶段（原始代码同样在此写端口使能），第二次运行 0 次；采集数据始终
  完整、非静音。
- **codec-port-log 模块**（仅把 PORT_CLOSED 降为 debug）仍未安装/重启验证
  （`README.zh.md:230`）。

### 3.3 其他音频限制（P2）
- PCM 映射失败靠**多分配一页**规避，依赖特定 DSP 地址窗口，512 KiB 映射仍脆弱
  （`README.zh.md:111`）。
- **不要热卸载音频模块或重绑 APR**：会丢失 APR 服务注册/GLINK 重复设备，
  必须重启才能恢复（`README.zh.md:137`）。
- 采样对齐修复仅在 nabu + `audio1` 内核验证，未覆盖其他 Qualcomm 设备
  （`README.zh.md:169`）。

---

## 4. 恢复 / 调试通道（P1）

- 曾加入 USB CDC-ACM 控制台 gadget 以抓 VPU hang 日志（`nabu-iris` `e23405e`），
  同日被 revert（`239f933`），原因未记录。
- 当前 production cmdline 只有 `console=tty0`，**没有串口/USB console 兜底**，
  设备卡死时难以抓取内核日志。
- production cmdline 使用 `fw_devlink=permissive`（`nabu-main/config/production.cmdline`），
  说明固件/设备链接依赖尚未完全理清；同时保留 framebuffer console 与
  `ignore_loglevel` 也提示早期启动排障需求。

---

## 5. 电源 / 充电（P2）

- **PM8150B ADC 充电终止在 nabu 上根本不翻转**（门限/比较器/采样已回读确认），
  充满靠软件在电流衰减后锁存 `POWER_SUPPLY_STATUS_FULL`（`nabu-power/README.zh.md:50`）。
- **LN8000 电荷泵仅在 0..45°C 工作**；软件 JEITA 仅覆盖 -10..59°C。
- **只有 A 口（USB-A → C）会 QC2/QC3 升压**；C 口没有 PD/PPS 快充。
- 燃料计依赖内置**单一厂商 profile（K82 sunwoda 8720mAh）**，其他电池批次未验证。
- EFI RTC 读不出，开机时钟停 epoch，靠 `nabu-pmic-rtc-sync.service` 规避（`:160`）。
- `qcom_pmi8998_charger.c:1086` 仍留 Type-C 处理 FIXME。

---

## 6. 相机（P1）

- **GNOME Snapshot 50.0 补丁与安装器已移除**（`nabu-camera` `40a5620`），
  现在仅有 `camera-app/nabu-autofocus` 原型，无通用拍照/录像集成。
- 只有 libcamera simple IPA 调校文件，**无完整 3A/ISP 调优**；对焦为用户态
  Tenengrad 扫描 + CN3927 VCM。
- 前摄 OV8856 无自动对焦（CN3927 仅后摄）。
- 属于实验代码，替换 DTB 有无法启动风险。
- 代码内未完成标记：`camss-vfe-17x.c:271`（`XXX 1 for PLAIN8?`）、
  `camss-vfe.c:275`（`TODO: Replace with pix formats`）。

---

## 7. 传感器（P2，陀螺仪/原始磁力计导出已补）

- **原问题**：仅向桌面导出**加速度计、环境光、罗盘**；陀螺仪与 AK0991x 原始磁力计只能
  通过 `ssccli` 读取，无 iio/桌面接口。
- **修复（2026-09-22，`nabu-accelerometer` + iio-sensor-proxy 补丁）**：在
  `iio-sensor-proxy` 3.9 上新增 SSC 陀螺仪与磁力计驱动，并注册两个独立 D-Bus 接口：
  `net.hadess.SensorProxy.Gyroscope`（`HasGyroscope`、`(ddd) GyroscopeReadings`，
  rad/s）与 `net.hadess.SensorProxy.Magnetometer`（`HasMagnetometer`、
  `(ddd) MagnetometerReadings`，µT），复用与罗盘相同的 `Claim`/`Release` 引用计数；
  同步更新 D-Bus 策略、udev `IIO_SENSOR_PROXY_TYPE` 与安装脚本（`patches/0003`）。
  陀螺仪最高约 26 Hz，D-Bus 更新合并为最多每 20 ms 一次。
- **验证（2026-09-22）**：用持久 D-Bus 客户端 claim 后持续收到
  `GyroscopeReadings`/`MagnetometerReadings`（3 次 5 帧），罗盘/光/加速度计无回归；
  `scripts/verify.sh` 增加 `HasGyroscope`/`HasMagnetometer` 检查。
- 依赖 SLPI 固件、`hexagonrpcd`、libssc、打过补丁的 iio-sensor-proxy 3.9；
  生产 UKI 与传感器配置强绑定。
- 自动亮度滤波参数为经验值，会改变桌面 `LightLevel` 响应速度。

---

## 8. 显示 / HDR（P1，已记录：显示链路可用、无 HDR 通路）

- **硬件**：CSOT `xiaomi,nabu-csot-nt36523`（Novatek NT36523），1600x2560@120Hz，
  dual DSI CPHY 3-lane；面板本身标称 HDR10 / Dolby Vision 能力。
- **内核链路（2026-09-22 验证）**：mainline `msm` DPU+DSI；面板描述 `bpc=8`、
  `MIPI_DSI_FMT_RGB888`、无 DSC，DSI 固定 8bit。KMS 上连接器只有
  EDID/DPMS/link-status/non-desktop/TILE，**没有 `HDR_OUTPUT_METADATA` / `max bpc`
  / `Colorspace`**；CRTC 有 `VRR_ENABLED`、`CTM`；plane 支持 `AR30/XR30/P010`（10bit）
  但链路仍是 8bit；DPU 目录只导出 `DPU_DSPP_PCC`。
- **合成器/播放（验证）**：GNOME/mutter 经 `wp_color_manager_v1` 报告目标是
  **SDR（gamma2.2 / bt.709 / ~80nit、无 HDR 元数据）**；mpv 播放真实 HDR10 样本
  （VP9 P2、bt2020/smpte2084 + mastering metadata）时在 libplacebo 内做 HDR→SDR
  tone mapping。即 HDR 内容目前以 8bit SDR 呈现，无 HDR 直通、无 DV。
- **需要的改动（路线）**：连接器加 HDR 元数据/`max bpc`；DPU 走 DSPP 色彩管线 +
  10bit 输出；DSI/面板切 10bit + DSC（当前 CPHY 带宽/面板 init 只支持 8bit）；
  合成器再做 HDR 合成/映射。
- 证据：`iris-vaapi/docs/display-hdr-verification.md`、
  `iris-vaapi/benchmark-results/logs/display-hdr/`。
- suspend/resume 验证记录见 2.1（已补齐）。

---

## 9. 构建 / 发行 / 一致性

- **生产配置已统一（原 P0，已修复）**：`nabu-accelerometer/config/production.cmdline`、
  `libexec/install-production-uki.sh` 与其 README 原先把 `qcom_iris` 一并屏蔽，与
  统一构建的 `nabu-main/config/production.cmdline`（只屏蔽 `venus_core`、由
  `qcom-iris-autoload.service` 主动加载 iris）相反。现已把遗留定义对齐到 nabu-main，
  并在 README 说明独立 sensor UKI 脚本已被 nabu-main 取代。实测统一生产内核上
  `qcom_iris` 与 SLPI/SSC 传感器可共存。
- 所有模块是对 `linux-6.14` 基线的源码 overlay，**未上游化**；`repos.lock` 锁死 commit。
- 存在 `linux-6.18` 工作树与 `-6.18.dtsi` 变体，但生产仍锁 6.14，**6.18 尚未成为
  受支持配置**。
- 模块与内核必须 **vermagic 完全一致**，不能混装内核/模块。
- `make install` 会写 ESP 并新建 UEFI 启动项；建议普通用户 `make`、`sudo make install`。

---

## 10. 测试可信度（P2）

- ~~Fluster 完整套件受固件楔死影响，必须每个 pass 重载 `qcom_iris`~~：自动恢复
  落地后，2026-09-21 全量套件在**不重载**的情况下跑完所有 pass
  （见 `iris-vaapi/benchmark-results/fluster-full-postfix.md`）。
- 直接不支持的用例：`tiny(<64)`、4:2:2/4:4:4、10/12-bit 组合、场/交错、
  高度 >8192（`fluster-full.md:86`）。
- VP9 变尺寸/`resize` 向量：缩小后高度为 8 倍数的已在 V4L2 逐字节通过；
  非 8 倍数高度受固件对齐限制（见 1.2）。

---

## 变更记录

- 2026-09-21：初始版本，依据当时各模块 README、docs、fluster 结果与 git 历史整理。
- 2026-09-21：实现 Iris 自动核心恢复（覆盖 SESSION_INIT 超时、会话错误、长生命周期
  fd、核心 `IRIS_CORE_ERROR`），交叉编译通过。
- 2026-09-21：实机安装并验证：Fluster 完整四套在**不重载模块**下跑完所有 pass，
  3 次自动 power-cycle，VA-API 数字与重载基线一致（见 1.1 与
  `iris-vaapi/benchmark-results/fluster-full-postfix.md`）。
- 2026-09-21：音频：实现 WCD934x TX 端口停流顺序候选修复（3.2，待验证）；
  发现启动偶发无声卡的 SLIM NGD QMI 超时问题（3.1）。
- 2026-09-22：音频修复验证：SLIM NGD worker 改为无限等待（对齐 Android），
  连续 3 次启动无丢声卡；WCD934x STOP 先关 TX 端口，overflow 2→0
  （见 3.1、3.2）。
- 2026-09-22：统一生产配置：`nabu-accelerometer` 遗留 cmdline/README 不再屏蔽
  `qcom_iris`，对齐 nabu-main（只屏蔽 `venus_core`）；独立 sensor UKI 标记为
  已被 nabu-main 取代。
- 2026-09-22：VP9 动态分辨率（V4L2）：实测确认 `VIDEO.IR.1.2` 对足够资源的
  in-place resize 不发 sequence change 且不支持 sufficient-seqchange 属性，
  host 侧 FLUSH/reinit 会让固件 assert；改为 per-buffer 可见矩形 + `G_SELECTION`
  + 客户端裁剪。`vp90-2-21-resize_inter_1280x720_5_1-2` 连续 3 次 30/30 帧与软解
  逐字节一致，8 个高度 8 对齐的 resize 向量通过；非 8 倍数高度仍受固件对齐限制
  （见 1.2 与 `iris-vaapi/benchmark-results/vp9-v4l2-resize.md`）。
- 2026-09-22：传感器：在 iio-sensor-proxy 3.9 上新增 SSC 陀螺仪与原始磁力计驱动及
  两个独立 D-Bus 接口（`net.hadess.SensorProxy.Gyroscope`/`.Magnetometer`），更新
  D-Bus 策略、udev 规则与安装脚本（`patches/0003`）；实机 claim 后持续收到读数，
  罗盘/光/加速度计无回归（见 7）。
- 2026-09-22：VPU/suspend：定位并修复 idle collapse 重写后丢失的 VPU5 suspend 绕过
  （VPU 已收起时对断电硬件调用 prepare_pc → -11 中止 s2idle）；实机 5 个 s2idle
  周期无失败、周期后 VP9 resize 逐字节通过（见 2.1）。
- 2026-09-23：s2idle 后 SLPI 崩溃（P1，未解决）：实测一次 s2idle 往返后 SLPI
  被复位、PDR 注册丢失、传感器进程看门狗每 40s 自杀循环，导致休眠后屏幕无法唤醒、
  只能硬重启；证明 suspend 实际不可用。内核改名/模块拆分与该故障无关（不 suspend
  的启动 SLPI 全健康）。证据见 2.3 与 diagnostics 日志。
- 2026-10-14：**更正 2.3 的归属**：实测（`6.14.11-nabu-full`）发现「休眠后屏幕唤不醒」
  与 SLPI 无关，是显示子系统 resume 失败 —— 亮屏时挂起，`mdss_pm_suspend()` 关掉显示时钟
  但没改 runtime 状态，resume 时 `disp_cc_pll0` 锁不上（`mdss_pm_resume` -110），随后
  KMS 线程读 DPU 寄存器触发同步外部中止。修复：`nabu-display` 把 mdss 的 system-sleep
  改为 `pm_runtime_force_suspend/resume`（见 2.4，待实机验证）。同启动 SLPI 0 崩溃。
- 2026-10-15：2.4 深挖修正 —— 只改 mdss 的 PM 回调**不够**（resume 仍 `disp_cc_pll0
  failed to enable!`/`-110`）；改为在 `msm_mdss_enable()` 对 `core` 时钟持永久引用，使 PLL
  在 s2idle 后不被解锁、resume 无需重锁。另定位并修复 2.5：`nabu-sensors-suspend.service`
  的 `Before=suspend.target` 与挂起并发执行会让整机卡死，改为 `Before=sleep.target`。
  两项均待实机验证。
- 2026-09-22：显示/HDR：补齐显示链路验证文档。确认面板/链路可用但 mainline msm
  DPU/DSI **无 HDR 通路**（无 `HDR_OUTPUT_METADATA`/`max bpc`/`Colorspace`，DSI 固定
  8bit RGB888 无 DSC，DPU 仅 PCC），合成器报告 SDR 目标、HDR10 由 mpv/libplacebo
  tone map 成 8bit SDR（见 8 与 `iris-vaapi/docs/display-hdr-verification.md`）。
