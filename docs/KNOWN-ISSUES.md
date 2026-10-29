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

### 1.5 2026-10-23：Chrome / mpv 黑屏的真正原因 —— `/dev/dma_heap/system` 权限（已修，已固化）

**现象**：VA-API 一切正常（`vainfo` 有 `VAProfileHEVCMain{,10} : VLD`、mpv 日志
`v4l2-dec: device /dev/video0 driver 'iris_driver'`），但：
- **Chrome 硬解 HEVC 完全黑屏** ✗，日志只有 `eglCreateImage failed 0x00003003` ✗，
  之后**不报任何错** ✗（也不回退，就是黑屏）；
- mpv `--vo=gpu --hwdec=vaapi` 打 `[vo/gpu] Loading failed.` ✗ 后**静默退回软解** ✗。

**根因**：`/dev/dma_heap/system` 默认是 `crw------- root root` ✗ ⇒ 每次
`vaCreateSurfaces` 都退回 **memfd** ✗ ⇒ **EGL 无法导入 memfd** ✗ ⇒ 整个"硬解呈现"
链路断掉 ✓。驱动自己的注释写得很清楚（`99-qcom-iris-dmaheap.rules`）：

> the default root-only mode makes every vaCreateSurfaces fall back to memfd,
> which EGL cannot import, and Chrome then falls back to software decoding.

**修复**：安装 `nabu-iris/config/99-qcom-iris-dmaheap.rules`
（`SUBSYSTEM=="dma_heap", KERNEL=="system", MODE="0666"` ✓）。
`iris-vaapi/install-system.sh` 本来就会装 ✓，但**镜像构建没走模块 install** ✗ ⇒
新刷的 rootfs 里根本没有这条规则 ✗。已在 `nabu-main/debian/build.sh` 的
`overlay_nabu_userspace()` 里补上（`nabu-main cf42a2d` ✓）。

**修复后实测**（Chrome 156.0.8078.47，4K HEVC 8bit，`benchmarks/seek_harness`）：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `dma_heap unavailable` | 出现 ✗ | **0 次** ✓ |
| `eglCreateImage failed` | 一堆 ✗ | **0 次** ✓ |
| Canvas 帧哈希 | 恒定（黑帧）✗ | 445 样本 / **442 个不同** ✓ |
| **seek 后旧帧（`stale_repeats`）** | 100%（无效测量）✗ | **0 / 445 = 0%** ✓ |
| `stale_serial`（`VPU_FRAME_STAMP=1`）| — | **0 / 363 = 0%** ✓ |

⇒ **M153 的 `ExtendedVideoBitstreamValidation` HEVC seek 回归（2.4 里记录的 70–90%）
在 Chrome 156 上已经不存在** ✓，**不需要**再带
`--disable-features=ExtendedVideoBitstreamValidation` ✓。

**排查要点（下次别再走弯路）**：
- Chrome 黑屏时**先看** `ls -l /dev/dma_heap/system` ✓，`crw-rw-rw-` 才是对的 ✓；
- `vainfo` 正常 **不能**证明呈现链路正常 ✗（它只用 surface 不导入 ✓）；
- mpv 用 **`--vo=dmabuf-wayland`** ✓：这是本机唯一真正零拷贝出画面的路径 ✓
  （走 Wayland 原生 dmabuf ✓，绕开 EGL ✗）；`--vo=gpu` ✗ 会 `Loading failed` ✓，
  `--vo=x11`（XWayland）✗ 直接退软解 ✓；
- Chrome 没有 `dmabuf-wayland` 等价物 ✗，所以它**必须**靠 EGLImage ✓ —— 也就是说
  `dma_heap` 那条规则对 Chrome **是硬性前提** ✓。

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

**【更正 2026-10-18 晚：这个修复已回退（`nabu-display` `25adb51`）】**

A/B 实测（`pm_test=devices`，不真正睡眠 ✓）：

| mdss 版本 | 结果 |
|---|---|
| 端口版本（`pm_runtime_force_*` ✓） | **第 1 轮正常返回** ✓ |
| 上游版本（本次"修复" ✗） | **第 1 轮就挂死** ✗ |

⇒ 回退到上游写法虽然**消掉了时钟计数泄漏** ✓，却让偶发挂起**明显更糟** ✗
（挂起 ≫ 少量时钟泄漏 ✓）。因此**已回退，保留端口版本** ✓。

泄漏本身仍然是真的 ✗，但要**在不改变 mdss 参与系统睡眠方式的前提下**去修 ✓
（例如显式 balance 时钟，而不是整段跳过 mdss 的那一次 transition ✓）。

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

#### 2.4.16 2026-10-18：camcc 的 PLL 配置同样是 sm8250 的值（已修）

现象：相机在**任何一次挂起/恢复之后**就失效 ✗ —— `cam -l` 从 2 台变 0 台：

```
qcom-camss: clock enable failed: -110
  camss_enable_clocks <- csiphy_set_power
MediaDevice: Failed to setup link 'msm_csid0'[1] -> 'msm_vfe0_rdi0'[0]: timed out
```

`-110` 是 ETIMEDOUT ⇒ `clk_prepare()` 里 PLL 锁不上 ✓。与 2.4.11 的显示 PLL
**完全同源** ✓：`camcc-sm8150.c` 里 `cam_cc_pll0/pll1/pll3/pll4` 的
`test_ctl_hi_val` 是 **`0x00000000`**（sm8150 的 **v2** 值 ✗），而厂家 v1 配置是
**`0x00000002`** ✓（`pll2` 两边都是 `0x4000` ✓）。nabu 是 v1 芯片 ✓
（显示 PLL 用 v1 值修好就是证据 ✓）。

改法（`nabu-camera` `c3bede2`）：新增
`kernel-overlay/drivers/clk/qcom/camcc-sm8150.c`，把四处改成 `0x2` ✓。

验证：一次 `pm_test=devices` 挂起/恢复后，**相机仍枚举到 2 台** ✓
（修复前会掉到 0 ✗）。

**注意**：这个修复**没有**解决偶发的设备挂起挂死 ✗ —— 第 2 轮 `pm_test`
仍然挂死 ✓，说明那是另一个问题 ✓。

#### 2.4.17 2026-10-19：偶发「设备挂起阶段」挂死已修 —— 蓝牙占用 UART（闭环）

**方法**（终于有可用的观测手段 ✓）：`initcall_debug=1` + `pm_print_times=1` +
一次**成功**的 `pm_test=devices` 轮次 ⇒ 每个设备的挂起耗时直接打出来 ✓：

```
127,365 µs  qcom_geni_serial c8c000.serial   ← 挂起路径上最慢（其它 ≤22ms）
104,656 µs  dwc3 a600000.usb                 （恢复侧）
 93,889 µs  usb 1-1                          （恢复侧）
103,574 µs  i2c-qcom-cci → 返回 -110         （恢复侧失败）
```

`c8c000.serial` 是 geni UART，也就是**蓝牙那条 UART** ✓。

**验证**：

| 条件 | 结果 |
|---|---|
| 原样 | 约 50% 挂死 ✗ |
| `c8c000.serial` 解绑 | **16/16 轮全过** ✓ |
| 串口绑定 + **`bluetooth.service` 禁用** | **10/10 轮 + 2 次真实挂起全部成功** ✓✓ |

⇒ 元凶：**蓝牙用户态栈持续占用 `c8c000.serial`** ✗，使该 UART 的系统挂起
（平时 127ms ✓、偶尔永不返回 ✗）卡死整个 suspend ✓。平板**本来就没有可用 BT
适配器**（UART 解绑时 `hci=0` ✓），禁用无损失 ✓。

**修复**：镜像里 **mask `bluetooth.service`** ✓ ——
新 rootfs 在 `debian/config/customize.sh` ✓，复用 rootfs 在
`overlay_nabu_userspace()` ✓。

**至此**：「按电源键休眠 → 再按唤醒」链路上已知的坑都修掉了 ✓
（显示 PLL ✓、iris 幂等 ✓、camcc PLL ✓、相机 vdig ✓、蓝牙 UART ✓）。

#### 2.4.18 2026-10-19：蓝牙 UART 挂起 —— `disable_irq_nosync` 实验失败，保留「禁蓝牙」

承接 2.4.17（`c8c000.serial` 的挂起卡死 ✓）。尝试过的**根治**：

- 假设：`qcom_geni_serial_shutdown()` 里的 `disable_irq()` 在等 in-flight 中断 ✗。
- 改动：换成 `disable_irq_nosync()`（ISR 已有 `uport->suspended` 早退，安全 ✓）。
- 结果：**蓝牙保持启用时，第 2 轮 `pm_test` 依旧挂死** ✗ ⇒ 假设不成立 ✓，改动已回退 ✓
  （`nabu-serial` 无 overlay、工作区干净 ✓）。

**当前结论**：

- **蓝牙关闭 = 已验证稳定** ✓（26 轮 `pm_test` + 2 次真实挂起全部通过 ✓）
- 根因仍在 ✗：**BT 用户态栈持有 `c8c000.serial` 时，该 UART 的系统挂起会卡死** ✗
- 下一个方向：`hci_uart` 的 serdev suspend（挂起前关闭/冲刷 UART ✓），
  或 geni `.shutdown` 里 **TX 排空**那一段（127ms 的超时正是它 ✗）

**其余所有条目均已修复** ✓ —— 唯一仍开放的就是这一条 ✗（有稳定的规避 ✓）。

#### 2.4.19 2026-10-19：蓝牙 UART 挂起的代码级复核 + A/B 工具（根因假设，待实机验证）

承接 2.4.17/2.4.18（`c8c000.serial` 的系统挂起偶尔永不返回 ✗）。本轮**不动内核**，
只把代码读透、给出可判别的假设和工具。

**前提更正（重要 ✓）**：`hci_uart` 的**公共层**确实没有 PM 回调 ✗ ——
`drivers/bluetooth/hci_serdev.c` 里没有任何 `pm_ops/_suspend/_resume` ✓；但 nabu 用的是
`qcom,wcn3991-bt` ⇒ `hci_qca` ✓，它**已经有** serdev PM：`SIMPLE_DEV_PM_OPS(qca_pm_ops,
qca_suspend, qca_resume)` 挂在 `qca_serdev_driver.driver.pm` 上 ✓，而 `qca_suspend()`
也已经做了 `serdev_device_write_flush()` + `serdev_device_wait_until_sent()` + 等 IBS
`SLEEP_IND` ✓（全部有界超时 ✓）。⇒「补一个 hci_uart suspend 回调」不是缺的那块 ✗。

**固件**：本轮实测跑的是 **`6.14.11-nabu-full`** ✓（`main` 分支 product）⇒ 下面的代码引用都是
`linux-6.14/` ✓（7.2 的 geni 驱动差异很大 ✗：它把资源开关挪到 **runtime PM**
（`10904d725f6e serial: qcom-geni: Enable PM runtime`），`ops->pm` 走
`pm_runtime_put_sync`；6.14 是**直接** `geni_se_resources_off()` ✓）。

**1) 127 ms 的来源（6.14 ✓）**

`qcom_geni_serial_suspend()` → `uart_suspend_port()`（`drivers/tty/serial/serial_core.c`）：
端口被 BT 打开（`tty_port_initialized` ✓）⇒ 走完整路径 ✓：
`ops->stop_tx()` = `qcom_geni_serial_stop_tx_dma()` → `geni_se_cancel_m_cmd()` +
`qcom_geni_serial_poll_bit(M_CMD_CANCEL_EN)` ✗ 失败 → `geni_se_abort_m_cmd()` +
poll `M_CMD_ABORT_EN` ✗ → 3×`msleep(10)` 排水 → `ops->shutdown()` =
`qcom_geni_serial_shutdown()`（`disable_irq` + 再来一遍 stop_tx/stop_rx/cancel_tx_cmd）。

每个 poll 的上限就是 `port->poll_timeout_us` ✓（`qcom_geni_serial_set_termios()` 里
`jiffies_to_usecs(uart_fifo_timeout())` + 3/FIFO 深度 ✓）；3.2 Mbaud / 32 B FIFO ≈ 20 ms 一次 ✓，
几次相加 ≈ **127 ms** ✓ ⇒ **这个数是"cancel/abort 超时被打满"** ✗，不是正常排水 ✓。
即挂起时 SE 的 TX DMA 本来就没能在超时内停下 ✓。

**2) 关键结构性问题：SE 资源关掉之后，端口仍然是 open ✓**

`uart_suspend_port()` 最后一行是 `uart_change_pm(state, UART_PM_STATE_OFF)` ✓
（`serial_core.c:2434`）⇒ 6.14 的 `.pm = qcom_geni_serial_pm` ✓
（`qcom_geni_serial.c:1617/1634`）⇒

```
geni_se_resources_off(&port->se);   /* clk_disable_unprepare(se->clk)+wrapper clks,
                                       pinctrl_pm_select_sleep_state */
dev_pm_opp_set_rate(uport->dev, 0);
geni_icc_disable(&port->se);        /* NoC 通路也关 */
```

而**端口并没有被 close** ✗：`state->port.xmit_buf` 还在 ✓，`port->state->port.tty` 还在 ✓，
`uart_write()`/`__uart_start()` 里**没有任何 `uport->suspended` 检查** ✗，geni 侧
`qcom_geni_serial_start_tx_dma()` / `set_termios()` 也**没有** ✗（只有 ISR 有
`if (uport->suspended) return IRQ_NONE;` ✓）。⇒ 挂起窗口内任何一次 UART 写都会
`readl(SE_GENI_STATUS)` **在 SE 时钟/ICC 已关的情况下访问寄存器** ✗。

**3) 谁会在那个窗口里写 UART？——BT 栈 ✓**

- `qca_suspend()` 只 `cancel_work_sync()` 了 `ws_awake_device` 和 `ws_awake_rx` ✗，
  **没有取消** `ws_tx_vote_off` / `ws_rx_vote_off` ✗（`hci_qca.c`）。
- `hci_ibs_tx_idle_timeout()`（定时器，**挂起时照样会 fire** ✗）**不检查
  `QCA_SUSPENDING`** ✗ ⇒ 会 `queue_work(ws_tx_vote_off)` ⇒
  `qca_wq_serial_tx_clock_vote_off()` 最后是 `hci_uart_tx_wakeup(hu)` ✗
  ⇒ `serdev_device_write_buf()` ⇒ tty 写。
- 这些 workqueue（`hu->write_work` 在 `system_wq` ✓、qca 自己的
  `alloc_ordered_workqueue()` ✓）**都不是 `WQ_FREEZABLE`** ✗ ⇒ 设备挂起阶段仍然会跑 ✓
  （`system_freezable_wq` 才是会被冻的那个 ✓）。
- 对比：`qca_ibs_wake()`/`hci_ibs_wake_retrans_timeout()` 都检查了 `QCA_SUSPENDING` ✓
  —— 说明作者知道要挡，**但 IBS tx 空闲那条路漏了** ✗。

**⇒ 根因假设 ✓（可判别）**：`qca_suspend()` 返回后、geni 把 SE 资源关掉之后，
BT 栈仍有一个在飞/待跑的 UART 写落到寄存器上 ⇒ interconnect 访问停住 ⇒
**整机在设备挂起阶段永久卡死且无输出** ✗。

它一次解释全部现象 ✓：必须 bluetoothd 持住 HCI ✓（IBS 定时器/work 才有）、约 50% ✓（竞态）、
`disable_irq_nosync` 无关 ✓（2.4.18）、解绑 UART / 禁蓝牙都好 ✓、成功轮 127 ms ✓、
卡死轮无输出 ✓（console 是 dwc3 上的 ttyGS0，比 `c8c000.serial` 先挂起 ✗）。

**4) 观测通道（唯一可行的 ✓）**

`console=ttyGS0`（USB gadget）在 dpm 里跟 dwc3 一起没了 ✗，`pstore/ramoops` 又因 DDR 被清而无效 ✗
⇒ printk 拿不到卡死那轮 ✗。**`a90000.serial` 才是那条不会随挂起消失的 UART** ✓：
它是 `qcom,geni-debug-uart`（`serial0` ⇒ **`/dev/ttyMSM0`** ✓）。把它**当成 console**
（cmdline 加 `console=ttyMSM0,115200`）之后 ✓，geni console 端口在
`uart_suspend_port()` 里因为 `console_suspend_enabled=0`（`no_console_suspend` ✓）
会在 `uport->suspended = 1` 之前 **early-return** ✓ ⇒ 它的资源**不会被关** ✓
⇒ 挂起过程中一直能出字 ✓。做法：cmdline 加
`console=tty0 console=ttyMSM0,115200 no_console_suspend` ✓
（`serial-debug` 那份已经带 `no_console_suspend pm_debug_messages` ✓），板上接 UART 适配器 ✓。
代价是这个口在挂起期间一直供电 ✓（调试期可接受 ✓）。
**`c8c000.serial` 是 `hsuart0`** —— 但 **`/dev/ttyHS0` 根本不存在** ✗（实机核实，
见 2.4.20）：它挂在 **serdev** 上，serdev 只创建 tty/class 设备、**不建 `/dev` 节点** ✗
（`/sys/class/tty/` 里也没有 `ttyHS0`）✓ ⇒ **用户态完全够不到这条 UART** ✓
（唯一能打开它的是 `hci_uart` 自己）✓。

**5) A/B 工具（本轮交付，见 2.4.20 的修订版 ✓）**

`tools/nabu-suspend-ab.sh <variant> [rounds]` ✓ —— 每轮前后往 `/dev/kmsg` 打标记，
结束时汇总内核日志里的 QCA/geni/各设备挂起耗时 ✓；挂死那轮脚本检测不到 ✗（整机没了 ✓）：
长按重启后**再跑同一个变体**，数通过了多少轮 ✓。变体见 2.4.20 的最终表 ✓
（早先设想的 `bt-stop-open` / `qca-unbind-open` / `bt-nocrtscts` **不可行** ✗：
没有 `/dev/ttyHS0` 可以"持住"或改 termios ✓）。

**6) 下一步（见 2.4.20 的修订 ✓）**

早先设想的"一行守卫 `if (uport->suspended) return;`"仍是候选 ✓，但**先做
`pm_test` 阶段二分**（`freezer` vs `devices`）✓ —— 它能先判定挂死到底在不在这儿 ✓，
而 2.4.20 的实机证据显示"挂死在设备挂起阶段"这个前提**并没有被验证过** ✗。

**落点待定**：现在**没有任何模块**拥有 `drivers/tty/serial` 或 `drivers/bluetooth`
（`nabu-serial` 明确无 overlay ✗）⇒ 定下正式修法后，要么扩展 `nabu-platform` 的
`kernel-overlay/`（它已经管 `sm8150.dtsi` 的 uart13 与 `c8c000.serial` 的 wakeup 规则 ✓），
要么新开一个模块 ✓。

**顺便记下（7.2 才有，6.14 不涉及）**：`e3c04834ae1a serial: qcom-geni: fix TX DMA buffer
flush` ✓（"挂起时若正在 TX DMA 去 flush ⇒ UART 卡死反复发坏帧，随后 `tcdrain` 永久挂" ✓，
正是我们这片代码 ✗）与 `59faa59c25a0 do not advance stale DMA completions` ✓；
另外 `serial: qcom-geni: add force suspend/resume to system sleep callbacks`
（Praveen Talari，2026-07）**不在** 7.2.7 里 ✗，它说"端口被 open 持住时系统挂起不会触发
runtime-suspend" ✓ —— 与 2.4.19 同源的问题面，将来升 7.2 时要一起复核 ✓。

**规避不变 ✓**：镜像里仍然 **mask `bluetooth.service`** ✓（26 轮 + 2 次真实挂起全过 ✓）。

#### 2.4.20 2026-10-19：实机现状取证（`6.14.11-nabu-full`，192.168.0.67）+ 修正 2.4.17/2.4.19 的两个前提

设备重新联网后（`ssh cfm880@192.168.0.67`，内核 `6.14.11-nabu-full` ✓，
cmdline 带 `console=ttyGS0 no_console_suspend pm_debug_messages ignore_loglevel` ✓）
把 2.4.17/2.4.19 的前提逐条核实，**有两条不成立** ✗：

**A. `/dev/ttyHS0` 不存在 ✗（2.4.19 的 A/B 因此不成立）**

```
crw-rw---- root dialout 241,0 /dev/ttyMSM0     ← a90000（geni-debug-uart, serial0）✓
crw------- root tty     237,0 /dev/ttyGS0      ← USB gadget console ✓
                                              ← 没有 /dev/ttyHS0 ✗
/sys/bus/serial/devices/serial0-0 → compatible qcom,wcn3991-bt，driver hci_uart_qca ✓
```
`hsuart0 = &uart13` ⇒ tty 名确实该是 ttyHS，但 **serdev 不注册 `/dev` 节点** ✓
（`/sys/class/tty/` 里也没有）⇒ 用户态**无法**把 BT 那条 UART 打开或改 termios ✗
⇒ 2.4.19 设想的 `bt-stop-open` / `qca-unbind-open` / `bt-nocrtscts` 三个变体**做不到** ✗，
已从工具里删掉 ✓。

**B. "蓝牙开启 → 约 50% 挂死"在**今天这几次启动**上不是这样 ✗**

今天这台平板在两种状态之间摇摆 ✓（**绝大多数 boot 芯片是好的** ✓，
boot 0 是例外 ✗）：

| boot | QCA 固件（`QCA setup on UART is completed`）| 挂起行为 |
|---|---|---|
| -5 … -1 | **都有** ✓（`QCA SOC Version :0x40010320` ✓）| boot -2/-3：连续 4 轮**成功** ✓（`suspend of devices complete after 37–57 ms` ✓）；boot -3 最后一轮（12:53:12）失联 ✗ |
| 0（13:15，当前）| **没有** ✗：`command 0xfc00 tx timeout` ×3 + `Retry BT power ON:1..3` + `Opcode 0x0c03 failed: -110` | **每次挂起都在 3.0 s 后中止** ✗ |

当前 boot 的每一次挂起都是**确定性中止**而不是挂死 ✓：

```
PM: suspend entry (s2idle)
Freezing user space processes            (+0.42 s，因为适配器没上电 ✓)
hci_uart_qca serial0-0: PM: dpm_run_callback(): qca_suspend [hci_uart] returns -110
Bluetooth: hci0: SSR or FW download time out
PM: suspend of devices aborted after 3007.860 msecs
PM: suspend exit
```
⇒ 根因是 `qca_suspend()` 里那句
`wait_on_bit_timeout(&qca->flags, QCA_IBS_DISABLED, TASK_UNINTERRUPTIBLE, FW_DOWNLOAD_TIMEOUT)`
✓：**固件下载失败后 `QCA_IBS_DISABLED` 永远不复位** ✗ ⇒ 该 boot 之后**再也挂不起来** ✓
（`/sys/class/bluetooth/hci0` 在、`Powered: no`、`PowerState: on`、
Controller `AD:5A:00:00:00:21`、Manufacturer 0x001d、Version 0x0b ✓）。
这本身是**另一个 bug**（"BT 开着就再也睡不了" ✗），和"挂死"不是一回事 ✓，
但在实机上很容易被当成同一个现象 ✗。

**B2. 顺带修正 2.4.17 的"127 ms"含义 ✓**：boot -2/-3 里适配器**上电**的那几轮，
**整段** `suspend of devices` 只花 37–57 ms ✓ ⇒ 那时 `c8c000.serial` 并没有 127 ms ✓。
`qcom_geni_serial_stop_tx_dma()` 在 `!qcom_geni_serial_main_active()`（空闲）时**立刻返回** ✓
⇒ 127 ms 只在**挂起瞬间有在飞的 TX 命令**时出现 ✓，
也就是**蓝牙栈正在写 UART**（例如 bluetoothd 正在做固件下载/重试）的时候 ✓
—— 与 2.4.19 的"写竞态"假设一致 ✓，而且给出了更具体的复现条件 ✓：
**挂起时要有活跃的 BT 写入** ✓。（另记：每设备耗时需要
`initcall_debug` **和** `pm_print_times` 同时开 ✓，`initcall_debug_report()` 只看后者 ✓。）

**C. 有效的新观测点：`suspend_prepare()` 那段窗口 ✓**

对比同一批日志里 `PM: suspend entry (s2idle)` 到 `Freezing user space processes` 的间隔 ✓：

| 适配器状态 | 间隔 |
|---|---|
| **已上电**（boot -2/-3）| **6 s**（12:58:37→12:58:43、12:59:15→12:59:21、13:00:03→13:00:09）|
| 未上电（当前 boot）| **0.42 s** |

这段窗口就是 `suspend_prepare()` ✓：`pm_prepare_console()` + **`PM_SUSPEND_PREPARE`
通知链** ✓（`kernel/power/suspend.c:358`）。而 `hci_suspend_notifier()` →
`hci_suspend_dev()` → `hci_suspend_sync()` 正是那条链上的重活 ✓
（`hci_serdev` 只为 `hci_h5` 设 `HCI_QUIRK_NO_SUSPEND_NOTIFIER` ✗ ⇒ **QCA 的通知器是注册的** ✓，
见 `hci_serdev.c:360`）。`HCI_CMD_TIMEOUT` = 2 s ✓ ⇒ **3 条超时命令 ≈ 6 s** ✓
—— 说明"适配器上电"时，挂起的头 6 秒花在 **BT 栈的命令序列**上，而不是设备挂起 ✓。

**D. 纠正 2.4.15/2.4.19 的一条推理 ✗**：挂死 boot 的 journal 都停在
`PM: suspend entry (s2idle)`、没有 `Freezing …` 行 ✗ —— 这**不能**用来说明挂死点在
freeze **之前** ✓，因为 journald 是用户态 ✓，被冻住后就不再读 `/dev/kmsg` ✓；
而**成功**的轮次里那些 `Freezing …`/`suspend of devices …` 行之所以在，
是**解冻后** journald 重新读 `/dev/kmsg` 补记的 ✓ ⇒ 挂死轮自然会缺 ✓。
（`pstore` 不可用 ✓ 的老结论仍成立 ✗ —— 所以卡死点确实取不到 ✓。）

**E. 顺带看到的两处噪音（与本条无关 ✓）**
- `qcom-iris aa00000.video-codec: skip VPU power collapse (-16)` 每 **2 s** 一次、持续不断 ✗
  —— 是 `iris_pc_handler()` 的 2 s 闲置重试 ✓（`IRIS_PC_DELAY_MS`，`hfi_common.c:263`），
  有界、只是日志噪音 ✓。
- 一次挂起尝试后相机起不来 ✗：`qcom-camss: CSID/VFE reset timeout`、
  `Failed to power up pipeline: -5` ✓（与 2.4.16 的 camcc PLL 是同一片区域 ✓）。

**F. 修正后的下一步（先二分，再谈修法 ✓）**

既然"挂死在设备挂起阶段"从未被直接验证 ✗，先用 **`pm_test` 阶段二分** ✓（不用改内核 ✓）：

| 变体（工具已实现 ✓）| 跑到哪 | 若挂死 ⇒ 结论 |
|---|---|---|
| `freezer-bt` | `suspend_prepare()` + 冻结，**不挂任何设备** ✓ | 挂死点**不在**设备挂起 ⇒ 回到 BT 通知器/`hci_suspend_dev` ✓ |
| `devices-bt` | 再加设备挂起 ✓ | 只有它挂 ⇒ 2.4.17 的"设备挂起阶段"成立 ✓ |

关键优势 ✓：`hci_suspend_dev` 在 **freeze 之前**跑 ✓ ⇒ 它打的 debug 会**留在 journal 里** ✓
（那时 journald 还活着 ✓）⇒ 给 BT 栈开 **dynamic debug**（实机可用 ✓，
`/sys/kernel/debug/dynamic_debug/control` 有 6364 条 ✓）后，挂死 boot 的
`journalctl -k -b -1` 就能指出卡在哪一步 ✓。工具已自动打开
`initcall_debug` + `pm_print_times` + `pm_debug_messages` + BT 五个文件的 dyn-debug ✓。

前提 ✗：**必须在一台 `QCA setup on UART is completed` 的 boot 上跑** ✓（否则只会看到
3 s 中止 ✗，永远复现不出挂死 ✓）—— 工具会在固件没下来时直接拒绝运行 `*-bt` 变体 ✓。

#### 2.4.21 2026-10-19：`pm_test` 阶段二分完成 —— **只有真挂起才复现**；挂死期间机器不再响应（唤醒也失效）

今天在实机（`6.14.11-nabu-full`，192.168.0.67，`~/nabu-suspend-ab.sh` +
`~/nabu-suspend-stackwatch.sh`）把 2.4.15/2.4.17 的复现前提彻底验了一遍 ✓。

**1) `pm_test` 不复现 ✗（四个阶段都试过 ✓）**

| 变体 | 轮数 | 结果 |
|---|---|---|
| `real-bt` + `NABU_SUSPEND_AB_PMTEST=freezer`（走 systemd ✓）| 30 | **28/30 返回** ✓（0 挂死 ✓）|
| `real-bt` + `NABU_SUSPEND_AB_PMTEST=platform` | 20 | **20/20 返回** ✓ |
| `devices-bt`（空闲 + 后台 `scan on` 流量）| 40 | **40/40 返回** ✓ |
| `freezer-bt`（直接 `echo mem`）| 10 | **10/10 返回** ✓ |
| **`real-bt`（真 s2idle ✓）** | ~10 次 | **挂了 2–3 次** ✗ |

⇒ 2.4.15/2.4.17 里"`pm_test=devices` 可以复现"**是错的** ✗：`pm_test=devices`
把"设备挂起 + 恢复"整段都跑完了（40 轮 ✓）却一次不挂 ✗ ⇒ **挂死点不在设备挂起回调里** ✗，
而在**只有真 s2idle 才会走到的那一段**（进入最深 idle / 唤醒路径）✓✓。
复现配方 ✓：真 `systemctl suspend`（systemd 全流程：`nabu-sensors-suspend` →
NM `PrepareForSleep` 断 WiFi → 内核）+ **BT 适配器已上电** + 后台 `bluetoothctl scan on`；
每次约 10–30% ✓。

**2) 挂死期间机器整体不再响应 ✓（而且**不会**自己重启 ✗ —— 初稿误判，已更正 ✓）**

**更正（2026-10-19 晚）**：2.4.21 初稿写"`qcom_wdt` 约 30 s 自动重启、不用长按" ✗ —— **错的**：
实机 `RuntimeWatchdogUSec=0`、运行时**没有** `/dev/watchdog` 持有者、
`/sys/class/watchdog/watchdog0/` 甚至不存在（只有 systemd 在关机时短暂打开 ✓）
⇒ **挂死后不会自动恢复 ✗，仍然只能长按电源 ✓**（那两次"自己回来了"其实都是长按 ✓）。

挂死的**可靠特征** ✓（可为 A/B 判据 ✓）：
- journal/内核日志**只有 `PM: suspend entry (s2idle)`、没有 `PM: suspend exit`** ✓
  （整条 sleep→resume 链路一次都没走完 ✓，与"唤醒失效"一致 ✓）；
- 用户态心跳（`nabu-suspend-stackwatch.sh` 的 `beat.log`，只依赖 `dmesg`+`sleep` ✓）
  **在挂死那一刻停住** ✗ ⇒ 用户态（或整个 SoC）已不再推进 ✓；
- **按电源键唤不醒** ✓（连 IRQ 都不再被处理 ⇒ 更像"卡在一次访问/持锁"而非普通死锁 ✓）。

**零交互复现 ✓（最有价值的一条）**：2026-10-19 16:06 那次**根本没人操作** ——
GNOME 闲置 → 真 s2idle（`wlan0 … DEAUTH_LEAVING` ⇒ NM `PrepareForSleep` → `PM: suspend entry`）
⇒ **再也没有 `suspend exit`** ✗ ⇒ 按电源键无效 ⇒ 长按重启（16:21 新 boot ✓）。
⇒ 这就是用户报的"按电源键休眠 → 按电源键唤不醒" ✓✓，且说明机器是在
**睡眠/唤醒这段里就死了**（不是设备挂起回调里 ✓）。

**3) 排除"蓝牙作为唤醒源"✗**

- `/sys/class/bluetooth/hci0/power/wakeup` **不存在** ✗ ⇒ hci0 不是唤醒源 ✓；
- `c8c000.serial/power/wakeup` = `disabled` ✓（2.4 的 udev 规则 ✓）；
  `msmgpio 46 Edge c8c000.serial:wakeup` 中断计数 **0** ✓；
- `wakeup_sources` 无 hci/bt/serial 条目 ✓；
- 而 `GICv3 617 qcom_geni_serial_uart0` 计数 1043 ✓（BT 那条 UART 的 RX 一直在动 ✓）。
⇒ 蓝牙与挂死的联系是 **UART 上有真实流量** ✓（扫描时尤甚 ✓），不是唤醒中断 ✗。

**4) "127 ms" 继续降级 ✓**：今天 BT 上电 + 扫描时 `suspend of devices` 总耗时
**135–285 ms** ✓（与 2.4.17 的 127 ms 同量级 ✓），而 `pm_test=devices` 40 轮不挂 ✗
⇒ 那 135–285 ms **本身不是**挂死原因 ✓（2.4.20-B2 继续成立 ✓）。

**5) 下一步：唯一可行的取证路线 ✓**

挂死在 freeze + 设备挂起之后 ⇒ UFS 也已挂起 ✗、`pstore/ramoops` 又被清 ✗
⇒ **没有任何可写的持久介质** ✗ ⇒ 只有**不随挂起消失的 console** ✓：

1. cmdline 加 `console=ttyMSM0,115200` + `no_console_suspend` ✓
   （`a90000.serial` = `/dev/ttyMSM0` ✓；见 2.4.19-§4 ✓），板上接 UART 适配器 ✓；
2. 配齐 `pm_debug_messages` + `initcall_debug` ✓ ⇒ 卡死前最后一条
   `PM: calling/resume of device …` 就是答案 ✓（不用打补丁 ✓）；
3. 需要更细时临时 `pr_emerg()` 到 geni 的 `shutdown`/`startup`/ISR ✓。

**备用（不用硬件 ✓）**：挂死仍需长按 ✗，所以 A/B 要短（每变体 5–8 次真挂起 ✓，
人要在旁边 ✓）：`bluetooth.service` mask（已知 0% ✓，对照 ✓）、
geni `if (uport->suspended) return;` 守卫 ✓、
`hci_qca` 睡前静默（取消全部 work + 停 IBS 定时器 + `HCI_UART_SUSPENDING` 门 ✓，
补丁见 2.4.22 ✓）。

**工具已改 ✓**：stackwatch 的 stall 降到 20 s ✓（要快过看门狗 ✓，但只对 freeze 前的挂死有效 ✓）；
`nabu-suspend-ab.sh` 新增 `real-bt|real-nobt` 与 `NABU_SUSPEND_AB_PMTEST=<阶段>` ✓。

#### 2.4.22 2026-10-19：机制闭环 —— 挂起窗口里 BT 栈仍会写 UART（补丁已编译验证，待实机 A/B）

**为什么 `pm_test` 复现不了、真挂起却挂** ✓：freeze **不冻结定时器** ✓，而
`system_wq` 与 `qca_wq` **都不是 `WQ_FREEZABLE`**（`alloc_workqueue("events", 0, 0)`、
`alloc_ordered_workqueue("qca_wq", 0)` ✓）⇒ 整个睡眠期里：
`hci_ibs_tx_idle_timeout()`（定时器 ✓）→ `queue_work(ws_tx_vote_off)` →
`qca_wq_serial_tx_clock_vote_off()` → `hci_uart_tx_wakeup()` → `write_work`(system_wq) →
`serdev_device_write_buf()` → geni 寄存器 ✓，**而此时 `qcom_geni_serial_shutdown()` 已把
SE 时钟 / OPP / ICC 关掉 ✗** ⇒ 访问停住 ⇒ 整机不再响应（含电源键唤醒 ✓）。
`pm_test` 里这个窗口只有 ~0.3 s（BT 栈还是冻的 ✓）⇒ 40 轮不挂 ✗；真挂起是整段睡眠 ⇒ 10–30% ✓。

**候选修复 A（`/tmp/opencode/fix-A-hci-quiesce.patch` ✓，已用
`nabu-main/out/.config` + `aarch64-linux-gnu-gcc` 单目录编译验证 ✓，树已还原 ✓）**：
1. `hci_uart.h`：新增 `HCI_UART_SUSPENDING`（proto flag bit 5 ✓）；
2. `hci_ldisc.c`：`hci_uart_tx_wakeup()` 在 `HCI_UART_SUSPENDING` 时 `goto no_schedule`
   ✓（一个点挡住所有发送方 ✓：IBS 定时器 / 重传定时器 / HCI 命令队列 ✓）；
3. `hci_qca.c`：`qca_suspend()` 里 `set_bit(HCI_UART_SUSPENDING)` 后再
   `cancel_work_sync(ws_tx_vote_off/ws_rx_vote_off)` + `timer_delete_sync(tx_idle_timer)`
   ✓；`error:` 与 `qca_resume()` 里 clear ✓。

**候选修复 B（次要 ✓）**：`qcom_geni_serial_start_tx_dma()/start_tx_fifo()` 开头
`if (uport->suspended) return;` ✓（与 ISR 里既有的检查对齐 ✓，防止任何迟到的写落到寄存器 ✓）。

**落点**：现在**没有模块拥有 `drivers/bluetooth`** ✗ ⇒ 用 A 的话，正式落地是把
`kernel-overlay/drivers/bluetooth/{hci_ldisc.c,hci_qca.c,hci_uart.h}` 挂到
**`nabu-platform`** ✓（它已管 uart13 的 DTS 与 `c8c000.serial` 的 wakeup udev 规则 ✓）。

**测法** ✓：`tools/nabu-suspend-ab-loop.sh <轮数> <标签>`（host 侧 ✓）—— 每轮一次真挂起，
**用 `boot_id` 判定**（挂死 ⇒ 长按重启 ⇒ boot_id 变 ✓；正常 ⇒ 不变 ✓，不受 NM 那 2 分钟
WiFi 恢复影响 ✓）；顺带开 `scan on` 流量、关掉桌面闲置休眠 ✓。

**当前缓解 ✓（2026-10-19 16:2x 已在实机执行 ✓）**：`systemctl mask bluetooth.service` ✓
（镜像本来就该 mask ✓，实机上却是 `enabled` ✗ —— 见 2.4.17 的 `customize.sh` 条目 ✓）。

#### 2.4.23 2026-10-19：三组内核补丁实测全败 —— geni UART 方向排除，嫌疑转向 BT 芯片自身持有的资源

**实测（每轮都是真 `systemctl suspend` + BT 上电 + 扫描流量，挂死由 boot_id 判定 ✓）**

| 补丁 | 内容 | 结果 |
|---|---|---|
| A | `hci_ldisc.c` 加 `HCI_UART_SUSPENDING` 门 + `hci_qca` 取消全部 work/停 IBS 定时器 | **1/1 仍挂** ✗，且疑似有害（中止路径漏清标志 ⇒ BT 后面发不出包 ⇒ 固件下载失败 ⇒ 之后每次挂起都 -110 中止 ✗）；已撤 ✓ |
| A+B | 再加 `qcom_geni_serial` 的 `resources_off` 守卫（start_tx/flush/ISR） | **1/1 仍挂** ✗ |
| B+C | 再加"挂起时**不给 SE 断电**"（`system_state == SYSTEM_SUSPEND` 跳过 gating ✓） | **1/1 仍挂** ✗ |

⇒ **geni UART（写路径/寄存器守卫/资源 gating）都不是死因** ✗。
剩下唯一在"BT 开着"时才成立的差异是**BT 芯片自己持有资源** ✓：
`qca_serdev_probe()` 打开 `susclk`（32 kHz ✓）并让 `vddio/vddxo/vddrf/vddch0` 四路 vreg 常开 ✓
—— 这解释了为什么只有"mask 蓝牙"和"解绑 UART"（两者都让这些全关 ✓）稳定 ✓。

**下一个验证（模块级，最快 ✓）**：在 `hci_qca.c` 的 `qca_suspend()/qca_resume()` 里
`susclk` 关/开 ✓（编在 `hci_uart.ko` ⇒ 只换一个 .ko + modprobe ✓，不刷机不重启 ✓），
按挂死率 A/B ✓。

**顺带确认的两件事 ✓**
- **看门狗**：`RuntimeWatchdogUSec=0`、运行时没人持有 `/dev/watchdog` ✗ ⇒ 挂死后**不会自己重启** ✗（此前"自己回来了"都是长按 ✓）。已在平板加 `/etc/systemd/system.conf.d/watchdog.conf`（`RuntimeWatchdogSec=60s` ✓）⇒ `wdctl` 报 `qcom_wdt, Timeout: 30 seconds` ✓ ⇒ 之后挂死约 30 s 自愈 ✓✓，A/B 可无人值守 ✓。
- **唤醒后触屏失效**：与上述补丁无关 ✓（触屏走 geni **SPI**，不是 UART ✓）。属 2.4.14 的遗留面（`nvt_check_fw_reset_state` 重试 ≈32 s ✗ / resume 重下固件 ✗），需在**成功唤醒**的 journal 里看 `NVT-ts-spi` 行 ✓。

**观测现状（重要 ✗）**：平板**没有物理调试 UART**（只有 Type-C ✓，CP2102 是给 ESP32 用的 ✗）⇒ gadget console 随 dwc3 一起挂 ✗ ⇒ 崩溃瞬间**没有可用通道** ✗；而 freeze 之后 UFS 也挂了 ✗、`pstore` 又被清 ✗ ⇒ 目前只能靠**统计 A/B** ✓，不能抓栈 ✓。

#### 2.4.24 2026-10-19：Type-C 口卡在 host/source 角色 ⇒ USB gadget console（唯一的串口）出不来

现象：平板上 `nabu-usb-console.service` 是 active ✓、`printk: legacy console [ttyGS0] enabled` ✓、
`dwc3`/`typec` 都探测正常 ✓，但**主机侧看不到任何 USB 设备** ✗（`lsusb` 没有 Xiaomi/QCOM gadget ✗）。

实机取证 ✓：

```
cat /sys/class/udc/a600000.usb/state   → not attached     ✗（gadget 永远 enumerate 不了）
cat /sys/class/typec/port0/data_role   → host [device]    ✗（当前是「主机」角色）
cat /sys/class/typec/port0/power_role  → source [sink]    ✗（当前是「供电方」）
ls  /sys/class/typec/port0-partner/    → （空）           ✗（没识别到对端）
```

尝试强制回 device 角色都失败 ✗：
- `echo device > /sys/class/typec/port0/data_role` → **EAGAIN**（tcpm 拒绝 ✗）
- `echo sink   > /sys/class/typec/port0/power_role` → **EIO** ✗
- `/sys/class/usb_role/a600000.usb-role-switch/` 里**没有 `role` 属性** ✗（只有 `power/`、`subsystem`、`uevent` ✓）
⇒ 角色由 **tcpm/PD 状态机**独占 ✓，它 latch 在 host/source ✗ ⇒ sysfs 改不动 ✓。

**影响 ✓**：这是目前唯一可用的"串口"（USB gadget console = `console=ttyGS0` ✓）✗ ⇒ 它出不来时，
崩溃/唤醒都**无串口可读** ✗（而平板没有独立调试 UART ✓，见 2.4.23 ✓）。

**观察到的规避 ✓**：同一天早些时候（13:5x–18:xx）这条 console 是**可用**的 ✓（cmdline 一直是 `console=ttyGS0` ✓）
⇒ 口本身能在 device 角色工作 ✓，只是**当前这次 latch 成了 host** ✗。下次要串口时：
**先把 Type-C 数据线插好、再冷启动平板** ✓（让 tcpm 在 boot 时就带着对端做角色判定 ✓）；
插拔后 `cat /sys/class/typec/port0/data_role` 应该变成 `device` ✓、`cat /sys/class/udc/a600000.usb/state` 变成 `configured` ✓。

**待查（真 bug ✓）**：为什么 tcpm 会把对端识别成需要 host/source 角色 ✗
（`serial-debug` 黑名单只去掉了 `ln8000_charger` ✓；`pmic-typec`（`c440000.spmi:pmic@2:typec@1500` ✓）
与 `i2c@890000/typec-mux@43` ✓ 仍在管事 ✗）—— 记下待办 ✓。

#### 2.4.25 2026-10-19：唤醒后触屏失效 —— NVT resume 不再重下固件（已修，已装，待唤醒验证）

串口取证（`console=ttyGS0` + getty ✓，全程只走串口 ✓）：

```
nvt_ts_resume 1784: resume start
nvt_check_fw_reset_state 537: error, retry=51, buf[1]=0x00 0x00 0x00 0x00 0x00
nvt_ts_resume 1844: end                     ← 检查失败但没有任何补救 ✗
```

⇒ 2.4.14 删掉"无条件重下固件"是对的 ✓，但它把**失败分支**也一起丢了 ✗：
resume 时 IC 状态读回全 0 ✗、reset-state 检查失败 ✗ ⇒ 控制器一直死着 ✗，
只有 `modprobe -r/-r nt36523_ts` 才能救回来 ✓（实测重下固件只要 **167 ms** ✓，
`fw_ver=0x35` ✓、`PID=5953` ✓、`input11/12` 重新注册 ✓）。

**修复（`nabu-touchscreen` `6459da9`）**：`nvt_ts_resume()` 里**只在检查失败时**
`nvt_update_firmware()` + 再检查一次 ✓（正常路径不变 ✓）。已编进 `nt36523_ts.ko` ✓
并用串口 `dd`+base64 传上去装好 ✓（`MD5_OK`/`INSTALLED`/`RELOADED` ✓）。

**待验证 ✗**：装好后触发的那次 `systemctl suspend -i` **没有醒过来** ✗
（串口停在 `PM: suspend entry (s2idle)` ✗、SSH/网络都没回来 ✗）⇒ 自动重下那条路
还没在**成功的唤醒**里看到日志 ✗。下次唤醒成功时看 `reloading firmware` 行即可 ✓。

**顺带记下两条环境事实 ✓**：
- **串口现在可用且可登录** ✓（Type-C gadget = `console=ttyGS0` + getty ✓，
  主机侧 `/dev/ttyACM0` ✓，抓取器 `tools/nabu-serial-console.sh` ✓）——这是以后
  所有崩溃/唤醒取证的首选通道 ✓；但它在 dwc3 挂起时会消失 ✗（挂死瞬间仍看不到 ✗）。
- 主机与平板换到 `192.168.1.0/24` ✓（平板 `192.168.1.5` ✓、构建机 `192.168.1.13` ✓）。

#### 2.4.26 2026-10-21：~~真正的挂死链~~（**已被 2.4.27 推翻**：当时的结论只是链的下游现象）

串口 console（`cat /dev/ttyACM0 >> log` ✓，`loglevel=4` ✓）终于抓到完整现场 ✓：

```
PM: suspend entry (s2idle)
disp_cc_pll0 failed to enable!
  wait_for_pll ← clk_trion_pll_enable ← clk_bulk_prepare ← mdss_runtime_resume
  ← genpd_runtime_resume ← rpm_resume ← dpu_kms_enable_commit ← msm_atomic_commit_tail
  ← drm_fb_helper_set_par ← fbcon_blank ← do_unblank_screen ← vt_ioctl     ★
  （userspace = systemd-logind 的 VT ioctl ✗）
Failed to prepare clk 'core': -110 → msm-mdss clock enable failed → msm_dsi_phy_enable -16
→ panel init -22 → dpu irq timeout → 然后 Freezing → panel set display off -22
→ WARNING: unbalanced disables for ldo5（msm_dsi_phy_disable ✗）→ 整机挂死
```

⇒ **挂起入口时 logind 通过 VT ioctl 做了一次 unblank** ✗ ⇒ 触发完整 DRM modeset ✗ ⇒
`mdss_runtime_resume` 要求重新锁定 `disp_cc_pll0` ✗ ⇒ **PLL 锁不上（-110）** ✗ ⇒
显示/DSI/面板拆解全部失败 ✗ ⇒ `ldo5` 关闭不平衡 ✗ ⇒ 挂死 ✓。

**已做的尝试与结果 ✓**

| 改动 | 结果 |
|---|---|
| 去掉 `no_console_suspend`（让 console 先挂起）✗ | **仍然挂** ✗ —— 不是唯一触发者 ✓ |
| `msm_mdss` 对 **`core` 时钟持永久引用**（2.4.11 那条，之前丢失 ✗，已补回 ✓）| **唤醒成功** ✓：短按后机器恢复、`wlan0` 重新关联 ✓✓ |

⇒ 现在**电源键唤醒通了** ✓，只剩**屏幕不亮** ✗：查出来是
`/sys/class/backlight/ktz8866-backlight/bl_power = 4`（`FB_BLANK_POWERDOWN` ✗）——
**面板在（`card0-DSI-1 = connected` ✓）、背光被关掉** ✗ ⇒ 下次修 `nabu-display`：
resume 时把背光 `bl_power` 恢复成 0 ✓（或让 ktz8866 驱动在 resume 里恢复 ✓）。

**工具与流程（已固化 ✓，见 `tools/README.md`）**：`nabu-install-uki.sh`（ESP 不能 mount ✗、
mtools 直连报 hidden-sector ✗ ⇒ `dd` 出来 → `mcopy` → `dd` 回去 ✓；UKI 在
`EFI/debian/nabu-debian.efi` ✗ 不是根 `debian/` ✗）、`nabu-serial-console.sh`（宿主端常驻抓取 ✓）、
`nabu-suspend-ab-loop.sh`、`nabu-suspend-stackwatch.sh`、`wake-diag/` ✓。

**观测结论（硬约束 ✓）**：freeze 之后文件系统与磁盘都挂起 ✗、`pstore` 不保 ✗、唯一 console 是
USB gadget（随 dwc3 消失 ✗）⇒ **挂死点只能靠串口在挂起前/恢复后抓** ✗；崩溃 trace 建议
`loglevel=4`（`ignore_loglevel` 会把 gadget 缓冲冲爆 ✗ ⇒ `[missed … bytes]` ✗）。

#### 2.4.27 2026-10-23：真根因 —— `msm_mdss` overlay 的 `pm_runtime_force_suspend`（已修，实机验证）

**结论（推翻 2.4.26）**：挂起卡死不在 `disp_cc_pll0`，也不在 VT unblank ✗。真正的原因是
`nabu-display` 的 `msm_mdss.c` overlay 在系统挂起时用 `pm_runtime_force_suspend()` 把 mdss
**提前强制 runtime 挂起** ✗ —— 这发生在面板 `disable` 回调发出 DCS 命令之前 ✗：

```
[ 46.7] Freezing user space processes completed
[ 49.7] dsi_cmds2buf_tx: cmd dma tx failed, type=0x5, data0=0x28, len=4, ret=-110
[ 49.7] panel-novatek-nt36523 ae94000.dsi.0: failed to set display off: -110
[ 49.9] dsi_cmds2buf_tx: cmd dma tx failed, … data0=0x10 … ret=-110
[ 49.9] panel-novatek-nt36523: failed to enter sleep mode: -110
[ 50.2] panel-novatek-nt36523: Skipping unprepare of already unprepared panel
[108.2] dsi_cmds2buf_tx: … data0=0xff … ret=-110        ← 恢复时也发不出去
[108.2] panel-novatek-nt36523: failed to initialize panel: -110
[113.7] dpu error: enc32 intl ctl 1 reset failure: -22
[114.8] dpu error: wait for commit done returned -110
[144.9] Restarting tasks … done. → PM: suspend exit      ← 卡了约 100 秒才回滚
```

⇒ 显示电源域已断 ✗ ⇒ DSI 命令 DMA 永远等不到完成（`-110`）✗ ⇒ 面板状态错乱 ✗ ⇒ 回滚时 DPU
复位失败 ✗ ⇒ **屏幕只剩背光**（就是用户看到的"蓝底"）✓。

**A/B/C 对照（同一台机器、最小产品、串口取证）**

| 变体 | `msm_mdss` | `dsi_host` | 结果 |
|---|---|---|---|
| A | overlay | overlay | 挂起 ~100 s ✗、屏幕不回来 ✗ |
| B | 上游 | 上游 | **挂起 1.25 s ✓、屏幕正常 ✓** |
| C | overlay | 上游 | 挂起 ~100 s ✗（与 A 相同）|

⇒ 元凶是 `msm_mdss.c` ✓。修复：`nabu-display` **删除** `msm_mdss.c` 与 `dsi_host.c` 两个
overlay（`c137a27`）✓，只保留面板驱动 ✓。此前的 `core` 时钟永久引用和 D-PHY reset 都是在给
这个时序问题打补丁 ✓，一并删除 ✓。

**模块二分（最小产品，每次加一个模块，实机验证）**

| 组合 | 结果 |
|---|---|
| platform + display + serial | ✓ 可用 |
| + touchscreen | ✓ 可用 |
| + iris | ✓ 可用 |
| + audio + accelerometer | ✓ 可用 |
| **+ camera** | **✗ 唤不醒** |
| **+ power**（不带 camera）| **✗ 唤不醒** |

⇒ 还剩两个独立问题：`nabu-camera` 与 `nabu-power` 各自都会让唤醒失败 ✗（生产版两个都带 ✗，
所以生产版必挂 ✗）。

**方法论（以后查挂起必须照这个来）**

- 串口节点是 `ttyACM0` / `ttyACM1` ✓（编号不固定 ✓），由 `nabu-serial` 的 gadget 提供 ✓。
- **必须加 `no_console_suspend`** ✓：否则内核打印 `Suspending console(s)` 之后的所有输出
  （包括失败的 suspend 回调与随后的 oops）**全部丢失** ✗ —— 这是之前一直抓不到栈的原因 ✓。
- `initcall_debug` 会打印每个设备的 suspend/resume 回调与耗时 ✓，失败点一目了然 ✓。
- `netconsole` 在本内核**不可用** ✗（`CONFIG_NETPOLL` 未开 ✗，而 `netconsole` 依赖它 ✓）；
  `pstore`/`ramoops` 已证实在本机**不保** ✓（`/dev/kmsg` 标记在普通重启与
  panic + `panic=10` 热重启后都不存在 ✓）。
- 屏幕"蓝底" = 背光还在、DPU 已坏 ✓；此时整机通常**还活着** ✓（WiFi 会重连 ✓），
  看起来像"整机挂死"其实是显示坏了 + 串口断了 ✓。

**已修但仍有的小问题**

- `qcom-iris`：VPU 掉电后重新上电，时钟 `status stuck at 'off'` ✗
  （`clk_branch_toggle` WARN ✓，触发者是 `wireplumber` 打开解码器 ✓）—— 独立问题 ✓。
- 触屏：resume 时重载固件 ✓ 正常 ✓；但在 suspend 过程中被 `blank=1` 触发重载会失败 ✗
  （`Download Firmware failed (-1)` ✓，因为 IC 已断电 ✓），随后由 `nvt_ts_suspend` 收尾 ✓。

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

### 2.6 USB 控制器的 runtime PM 属于内核层，不再用 udev 规则规避（2026-10-27）
- **旧做法**：`nabu-power/config/99-nabu-runtime-pm.rules` 把 `a600000.usb`（Type-C 的
  dwc3）、`a800000.usb`（键盘盖）、`xhci-hcd.*.auto` 的 `power/control` 改成 `auto`。
  实测（熄屏）idle 从 **1.1 W 降到 0.6 W**，所以动机是真实的。
- **问题（2026-10-27 实机）**：`a600000.usb` 正是 CDC-ACM 串口控制台所在的控制器。
  PM8150B 的 TCPM（`c440000.spmi:pmic@2:typec@1500`）在 nabu 上**永远 `-EPROBE_DEFER`**
  （`deferred probe pending`），CC 检测不存在 ⇒ 插线事件没有任何人转告 dwc3 ⇒ 控制器已
  runtime suspend 时**无法被唤醒**。表现为：开机后再插 USB，`/sys/class/udc/a600000.usb`
  一直是 `not attached`，`/dev/ttyACM0` 永远不出现，唯一的调试通道无声消失，只能 SSH 进去
  `echo on > .../power/control` 救回来。提交信息里“Type-C 控制台照常工作”只在**开机时线已插好**
  时成立，热插拔场景没有验证过。
- **决定（2026-10-27）**：删除该 udev 规则。这类策略应该在**驱动/内核层**做，而不是用
  udev 从应用层强改 —— 应用层规避掩盖了内核缺陷。
- **已按内核层实现（`nabu-power` `15e6eda`）**：
  1. `qcom_pmi8998_charger.c` 把电缆状态发布成 extcon（`EXTCON_USB`，来自
     `pm8150b-charger.online`）。这个中断走 **SPMI 常开域**，是 USB 模块断电后唯一还能
     报事的来源 —— 这就是唤醒源。
  2. `drivers/usb/dwc3/core.c`：外设端口消费该 extcon（`EPROBE_DEFER` 等充电器 probe），
     自己 `pm_runtime_allow()`；VBUS 变化时调 `usb_gadget_connect()/disconnect()`。
     **必须显式拉掉 pullup**：这个端口没有硬件断开事件，不这么做 `dwc->connected` 一直是
     true，`dwc3_runtime_checks()` 永远拒绝 autosuspend（实测 `udc` 一直 `configured`）。
  3. dtsi 把 extcon 接到 `&usb_1_dwc3`，并给 `&usb_1` 标 `wakeup-source`。
- **实机验证（2026-10-27 18:44）**：拔线 → `ext=USB=0`、`udc=not attached`、
  约 2 s 后 `runtime_status=suspended`；插回 → `active` + 重新枚举，全程不冻结。
- **仍然待办**：
  1. 熄屏 idle 功耗的复测（此前 udev 方案是 1.1 W → 0.6 W，现在应由内核方案拿回同样的收益）。
  2. `pm8150b` TCPM 的 deferred probe 仍未解决，所以 `dr_mode` 仍是 `peripheral`（无 host/OTG）。
  3. `xhci-hcd` / VPU 的 runtime PM 见 **1.1 / 2.2**。

### 2.6.2 电量百分比会跳 20 点、充电“四分钟充满”（P1，跳变已修 2026-10-28）
- **现象**：一晚 91% → 56%，重启后 4 分钟内 56% → 77% → 100%；
  `8720 mAh` 的电池 4 分钟涨 21% 需要 26 A，而充电器只有 3 A ⇒ 是**电量计重估**，不是充电 ✗。
- **根因**：`qcom_fg_gen4_load_profile()` **每次开机**都写 profile 并 `HLOS_RESTART`。
  restart 让电量计算法丢掉累计状态、从开路电压重新估算 SOC ⇒ 每次重启都跳点 ✗。
  （profile 存在 PMIC SRAM 里，AP 重启不影响 PMIC 供电，本来就该只写一次 ✓。）
- **修复（`nabu-power` `29c2178`）**：先读 `PROFILE_INTEGRITY` 的 `PROFILE_LOAD_BIT`，
  已置位就跳过 profile 写入与 restart；只有 profile 缺失（PMIC 掉电后首次开机）才写。
- **验证**：`integrity=0x9` → 日志 `battery profile already present ... keeping gauge state`；
  连续重启 93% → 92% → 91% ✓（修前一次重启跳 ~20 点）。
- **仍未解决（精度，非跳变）**：SOC 模型本身仍然偏快。修复后重测（2026-10-28 12:40–12:53，
  13 分钟充电、平均 0.73 A）：

  | 指标 | 数值 |
  |---|---|
  | ∫I·dt（实测充入）| **148 mAh** |
  | ΔSOC | **90% → 96%**（+6% ⇒ 按 8720 mAh 是 523 mAh）|
  | 比例 | **3.5×** ✗ |

  也就是说电量计认为充进去的电荷是实测的 3.5 倍 —— 相当于它以为电池只有 ~2500 mAh。
- **profile 已排除**：DT 里的 `qcom,fg-profile-data`（416 B）经确认就是设备原厂那份
  （vendor `fg-gen4-batterydata-nabu-sunwoda-8720mah.dtsi`，见 `sm8150-xiaomi-nabu-power.dtsi`），
  且现在只加载一次 ✓。所以问题在 gauge 的 SOC 参数/模型，不在 profile 缺失。
- **已做的两个修复**（`nabu-power` `29c2178`、`3b56988`）：profile 只加载一次；
  `ACT_BATT_CAP`（SRAM word 285）从未初始化 ⇒ 用 `qcom,fg-batt-capacity-mah = <8720>`
  种入。效果：报告电荷从实测的 **3.5×** 降到 **2.3×** ✓（仍是错的，但方向对）。
- **已排除**：
  - profile：`profile_dump` 读回 SRAM 内容与 DT 那 416 B **逐字节一致** ✓；
  - KI 系数：值与编码（315/183，1000/61035）与 vendor `qpnp-fg-gen4.c` **完全一致** ✓；
  - vendor 对 nabu 只有一份 profile（`fg-gen4-batterydata-nabu-sunwoda-8720mah.dtsi`）✓。
- **~~实测（2026-10-28，满载放电 15 min）~~（结论已更正，见下）**：
  ∫I·dt = 341 mAh，电量 100% → 91%（-9%）⇒ 曾据此推断“模型等效容量 ≈ 3790 mAh”。
- **更正（2026-10-28 17:00，用 USB 功率计复核）**：上面那类“SOC 偏快 N 倍”的结论**不成立** ✗。
  原因是评测基准错了，不是电量计错了：
  - 充电末段（96–97%）功率计稳定 2.17 W，但**电池电流只有 20 mA** ——
    输入功率几乎全部供给了正在运行的系统，电池几乎不充电 ✗；
  - 所以“∫I·dt（电池侧）”在顶部附近接近 0，拿它和 SOC 变化相比必然得出“SOC 偏快”✗；
  - 反推也自相矛盾：同一时刻 PEM 侧 2.17 W、电池侧按燃料计为 2.7 W（>100% 效率）✗。
  ⇒ **电量计本身很可能是准的**，目前没有任何可信证据表明 SOC 有系统性偏差 ✓。
- **与 Android 对照（2026-10-28 17:1x，最有力的验证）**：同一块电池、同一状态，
  **Android 也报 97%**，USB 功率计也显示 **~2.3 W（4.925 V × 0.472 A）** ✓。
  ⇒ 我们的 gauge 读数与厂商实现**一致** ✓；97% 的平台期是厂商“平滑 SOC”的固有行为，
  不是我们的 bug ✓。今天补的几项（profile 只加载一次、v2 容量字、KI 阈值、ESR 门限）
  至少已经**追平 vendor 实现** ✓。
- **充电协商也与 Android 一致（2026-10-28 17:2x）**：拔插后 Debian 的输入功率同样
  从 ~2.2 W 升到 **5.2 W**（USB 功率计实测）✓，日志对应
  `APSD: charger type DCP, input limit 3000000uA`（重插触发重跑 ✓）与
  `ln8000_change_opmode: [0] -> [1]`（电荷泵/旁路切换 ✓）。
- **待查（2026-10-28，充电速度）**：99% 时 `pm8150b-charger/current_max` 读到
  **1.35 A**，而同一驱动在 APSD 日志里设的是 `input limit 3000000uA`（DCP 满档）✗。
  顶部恒压阶段本来只要 0.6 A，所以现在看不出问题 ✓；但**低电量（~40%）时若仍是
  1.35 A，充电就只有 ~6.5 W 而不是 DCP 的 ~15 W** ✗。
  怀疑 ICL 被 SDP 分支（1.35 A）覆盖了，需要在低电量插一次充电器复测
  `current_max` 与功率计读数。
- **满电后不停充（2026-10-29 修复，待满电验证）**：根因是 ADC 终止阈值**硬编码 400 mA** ✗，
  而满电后电池正好浮动在 **400–410 mA** ✗ —— 阈值与浮动电流重合 ⇒ 比较器永远跨不过去 ✗。
  已改为读 DT 的 `qcom,fg-sys-term-current = <(-500)>`（vendor 用同一数值 ✓，并做 100–2000 mA
  钳位 ✓，`nabu-power` `273ec90`）。**验证方法**：充满后 `status` 应变 `Full`、电流降到接近 0 ✓。
- **~~满电后不停充（2026-10-28，待查）~~**：100% 后充电电流只从 502 mA 缓慢降到 411 mA
  （10 分钟），SMB5 **没有触发硬件终止** ✗，一直以 ~0.4 A（≈1.8 W）浮动充电；
  Android 在同样状态会停充 ✓。
  - 软件锁存条件是 `cap >= 100 && cur < 400 mA`，411 mA 差一点点，所以 `status`
    仍显示 `Charging`（再等几分钟会翻成 `Full`）✓；
  - 硬件终止门限来自 DT `qcom,fg-sys-term-current = <(-500)>`，按说 411 mA 已低于它
    却未停充 ✗，怀疑还需要 vendor 的 `qcom,chg-term-current-ma = <(-400)>`
    配合 `CHGR_ADC_TERM_CFG` 的编码 ✗。
  - 影响：满电长插会持续小电流灌电池（有 JEITA/过压保护，安全 ✓，但比 Android 差）。
- **仍可选的验证（需要功率计累计 mAh/Wh）**：在中段（如 50% → 90%）充电，
  读功率计累计值 ≈ 40% × 8720 ≈ 3500 mAh（电芯侧）或 3600–3700（输入侧）；
  与 SOC 变化对照即可一次判定 ✓。没有累计功能的表只能靠多点实时读数积分 ✗，误差大。
- **已修（`nabu-power` `87c0d49`）**：vendor 有 v1/v2 两套 SRAM 参数表，
  **v2 才是默认**（v1 只给 PM8150B rev 1.0）。我们原来用的是 v1 的 word
  （`ACT_BATT_CAP` 285 / `BATT_SOC` 449），在 v2 芯片上属于别的参数 ✗ ⇒
  容量种错位置、读到乱数。改成 v2（287 / 455 / 461 / 466 / 469）后，
  `ACT_BATT_CAP` 回读 `0x2210` = 8720 mAh ✓（种对了）。
- **仍未解决（关键）**：即便用正确的 v2 word，**`BATT_SOC` 读出来仍是噪声**
  （`0xdf76c4c0`，越界 ⇒ 代码回退到 monotonic 寄存器），`CC_SOC`/`MONOTONIC`
  同样不合理。这说明**电量计算法本身没有在维护这些值** —— vendor 驱动为此还有：
  `SOC_UPDATE` 中断驱动的原子访问、ESR 快校准状态机、容量学习（写回 SDAM）、
  PBS/profile 处理等一整条流水线，我们都没移植 ✗。
- **结论**：要让硬件电量计真正可用 = **整体移植 vendor 的 `qpnp-fg-gen4`**
  （估 500–1000 行 + 多轮实机校准），不是“再补两个参数”能解决的 ✗。
- **下一步（尚未做完，留给后续）**：
  1. `BATT_SOC` 需要一个正确维护它的算法：vendor 的 `fg_gen4` 初始化 + 校准流水线；

  2. vendor `fg_gen4_hw_init()` 还写 `ESR`(w331)、`ESR_PULSE_THRESH`(w12, 默认 47 mA)、
     `RCONN`(w275)、`BATT_TEMP_COLD/HOT`（`BATT_TEMP_CONFIG_WORD`），我们都没写；
  3. vendor 还有 ESR 快校准 / 容量学习（`ACT_BATT_CAP` 由充放电循环学习并备份到 SDAM），
     我们只是种了一个固定值。
- **测量工具（已随驱动安装）**：`…/fuel-gauge@4000/soc_params`（vendor 那几个 SRAM 参数）、
  `…/profile_dump`（416 B profile）、`…/sram_dump`（寄存器 0x180–0x1fe）。
- **库仑计调查结论（2026-10-28）**：试图用 FG SRAM 里的硬件计数器替代 SOC ——
  候选字 `0x1ac/0x1ae` 在充电/放电两侧的 `Δ/mAh` 不一致（+229 vs −444 /mAh），
  不是电荷计数器 ✗；这块 SRAM 映射没有可用的计数寄存器，驱动里也没定义。

### 2.5.1 充电功率不稳定（15 秒周期性抖动）（已修 2026-10-29）
- **现象**：充电时功率计在 2–6 W 之间来回跳，周期约 15 秒 ✓（用户报告“充电功率不稳定”）。
- **根因**：软件 JEITA 监控（`smb2_jeita_work`）**每 15 秒无条件重写**快充电流与浮充电压 ✗
  （`SMB2_JEITA_POLL_MS = 15000` ✓ 周期完全吻合 ✓）。SMB5 每次被重设 setpoint 都会重启
  调节环 ⇒ 电流下陷 ⇒ 4–6 W 抖动 ✗，而且**整体充电也变慢**（被反复压下 ✗）。
- **修复（`nabu-power` `616ceeb`）**：在两个 setter 里缓存最后写入值，
  值没变就不动硬件 ✓（JEITA 只在温度跨档时才需要改 ✓）。
- **实测**：修复前 `1.02 / 1.50 / 1.47 / 1.10 A` 来回跳 ✗；修复后 60 秒内稳定 **2.99 A**
  （≈12.6 W 进电池）✓✓。

### 2.5.2 插着充电器却“不充电”（2026-10-29，已修 `nabu-power 9a15b9b`）
- **现象**：充电器插着，`online=1`、`status=Charging`，但电池电流 −0.2 ~ −0.4 A ✗
  （净放电）⇒ 用户看到“没充电”✓。
- **根因（三个，全部对照 vendor 找到）**：
  1. 驱动把 `TYPE_C_CFG`(0x1358) 的 `BC1P2_START_ON_CC`(bit7) **设成 1** ✗ ⇒ BC1.2/APSD
     只在 **CC 检测到插入**时才启动 ✗；而本板 Type-C 块对充电器经常读不到 CC
     （`MISC=0x22`，bit0=0 ✗）⇒ **APSD 一次都没跑**（`APSD_STATUS=0x00` ✗）⇒ 适配器
     从未分类 ⇒ 输入上限停在 USB 默认 **500 mA** ✗。vendor（`qpnp-smb5.c:4139`）
     明确把这一位**清零**，让检测只靠 VBUS 启动 ✓。
  2. 写入 >500 mA 的 `USBIN_CURRENT_LIMIT` 时**没有切到软件 ICL 覆盖（HC 模式）** ✗
     ⇒ 硬件继续按 APSD/USB 默认值限制 ✗。vendor 的 `smblib_set_icl_current()`
     在 >500 mA 时会写 `ICL_OVERRIDE_AFTER_APSD` 并清 `CMD_ICL_OVERRIDE` ✓。
  3. `USBIN_ADAPTER_ALLOW` 被设成 **5V-or-9V** ✗ ⇒ QC 充电器把 VBUS 拉到
     **9.6–10.2 V** 并**跨重启保持** ✗；高压通路属于 LN8000 电荷泵（需要它自己的
     调节环 ✓），只靠 SMB5 时输入上限反而塌到 **100 mA** ✗、电池继续放电 ✗。
- **修复**：
  - 清 `BC1P2_START_ON_CC` ✓（BC1.2 只靠 VBUS 启动 ✓）；
  - `smb2_set_current_limit()` 在 >500 mA 时切 **HC 模式** ✓；
  - `USBIN_ADAPTER_ALLOW` 改为 **5V only** ✓，并在 probe 时写 `CMD_HVDCP_2 = FORCE_5V`
    把已经锁在高压的适配器拉回 5 V ✓；
  - 充电器/PC 存在时端口保持 **DRP** ✓（钉成 SNK_ONLY 会让充电器以 500 mA 的 SDP 出现 ✗）；
  - `typec_regs` 增加 APSD/ICL/充电状态寄存器转储，便于下次直接看 ✓。
- **实测**：`APSD: charger type DCP, input limit 3000000uA` ✓、`VBUS 4.63 V`、
  输入上限 1.45–1.5 A（AICL 收敛值）、电池 **+0.96 A** ✓、电量 90% → 91% ✓。

### 2.6.0 Type-C host 已打通（2026-10-28，手工切换）
- **根因（两个，都在 `nabu-power` `ba7bf92` 修好）**：
  1. **Type-C 块基址错了** ✗：SMB5 的 Type-C 寄存器在 **0x1500**（`MODE_CFG`=0x1544，
     `SNK/SRC/STATE/MISC` 状态=0x1506/0x1508/0x1509/0x150B），而驱动一直用
     `chip->base(0x1000)+0x368 = 0x1368` ✗ —— 写到了完全无关的寄存器，
     状态也全读回 0 ✗（正好对上日志里的 `drp write rc=0`、`ctrl=0x0`）；
  2. **电源角色位定义反了** ✗：`smb5-reg.h` 里 `BIT(2)=EN_SRC_ONLY`、
     `BIT(1)=EN_SNK_ONLY`，而驱动把 BIT(2) 叫 `UFP_EN`、BIT(1) 叫 `DFP_EN` ✗，
     “开 DRP”时写 `BIT(1)|BIT(2)` 是**无效组合** ✗ ⇒ 端口一直停在上电默认角色 ✗。
- **效果**：`echo host > .../typec_role` 后
  - 端口电压 `usbin_v` 从 **0 V → ~4.99 V** ✓✓（SMB5 真正进入 source ✓）
  - Type-C 耳机枚举为 `AB13X USB Audio`（Bus 003 Device 002）✓，
    `snd-usb-audio` 绑定 ✓，`/proc/asound` 多出 card 1 ✓
  - PORTCS 从 `0000.0100`（只有 power）变成 **`0000.0103`（power|enable|connect）** ✓
- **自动检测已完整工作（`nabu-power` `024a7f5`/`3ec979f`/`03ec52a`）**：
  - 每 2 s 读 `TYPE_C_MISC_STATUS`（0x150B：`CC_ATTACHED` / `SNK_SRC_MODE` / `CC_ORIENTATION`）
    自动决定角色；空闲时端口跑 **DRP（try-sink）**，dwc3 留在 device；
  - **实机验证（2026-10-29 14:20，全程无命令）**：
    | 插入 | 日志 | 结果 |
    |---|---|---|
    | Type-C 耳机 | `attached=1 we_are_source=1` → `role 2 -> 1` | PORT 5V **4.99 V** ✓、6 个 `usb 3-x` 节点 ✓、声卡 2 张 ✓ |
    | 充电器 / PC | `attached=1 we_are_source=0` → `role 0 -> 2` | 保持 device ✓、充电不受影响 ✓ |
  - 稳定：30 秒采样 `role=auto`、4.99 V 恒定、设备数不变、日志仅 3 次开机切换（无抖动 ✓）；
  - **host → device 时补跑 APSD（`355ce3e`）**：从 host 模式退出时，充电器**一直看到 VBUS 存在** ✗
    ⇒ 它的 plug 中断不触发 ✗ ⇒ 不做充电器分类 ✗ ⇒ “拔耳机后插充电器不被识别、要再插一次” ✗。
    现在在 host→device 切换时主动 `schedule status_change_work`（即重跑 APSD ✓）。
  - **改用中断（`8dd2fd0`）**：轮询之外再加上 Type-C 的 `attach-detach`(0x15/0x05) 与
    `cc-state-change`(0x15/0x02) 中断（DT 已挂到充电器节点 ✓，实测
    `/proc/interrupts` 计数在增长 ✓），插拔一发生就立刻触发判定 ✓。
    实测 `MODE_CFG = 0x10`（DRP + try-sink ✓ 我们写的值确实生效 ✓），
    **DRP 轮转周期实测 2–4 秒**（之前目测 10 秒是采样混叠 ✗），
    端到端识别约 **3–7 秒** ✓（之前 11 秒且需重插 ✗）。剩下那段是双角色口的物理轮转，
    软件消不掉 ✓（Android 同样如此 ✓）。
  - 实测一次插拔序列（拔充电器 → 插耳机 → 拔耳机 → 插充电器）：
    `role 2→1`（host ✓）→ `role 1→2`（回 device ✓）→ `attached=1 we_are_source=0` →
    `APSD: charger type DCP, input limit 3000000uA` ✓，端到端约 11 s
    （其中约 8 s 是 Type-C 双角色轮转的固有延迟 ✓）；
  - **关键坑（`03ec52a`）**：模式缓存初值是 `0 == USB_ROLE_NONE` ✗，与“空闲模式”相同
    ⇒ 第一次 DRP 写入被当成“没变化”跳过 ✗ ⇒ 端口一直停在 sink-only ✗、不供 5 V ✗
    ⇒ sink 设备（耳机/U盘）永远检测不到 ✗。改成初值 `-1` 后立刻正常 ✓。
  - 调试工具：`typec_regs`（sysfs，打印 MODE_CFG/CURRSRC/DEBOUNCE/U_USB/状态等 ✓）
    就是靠它发现 `MODE_CFG = 0x02`（sink-only）✗ 才定位的 ✓。
- **“一会充一会不充”（2026-10-29 15:40，已修 `26af39f`）**：DRP 轮转时端口偶尔把
  **充电器误判成 sink** ✗ ⇒ 我们切 HOST 并**打开 OTG 5V 反向灌进充电器** ✗ ⇒ 充电中断 ✗
  ⇒ 下一轮又切回，表现为充电状态来回跳 ✗。两道保险：
  1. **只要充电器报 VBUS 存在就绝不切 host** ✓（sink 设备本身不供电，不会误伤 ✓）；
  2. **host 判定需连续两次一致** ✓（过滤轮转毛刺 ✓）。
  实测 90 秒：`online=1`、`status=Charging`、`role=auto` 全程恒定 ✓（94% 涓流 10–20 mA ✓）。
- **“拔掉充电器后插耳机识别不到”（2026-10-29 15:51，已修 `1df196c`）**：
  host 判定要求**连续两次一致** ✓，而轮询周期在“稳定”时是 30 秒 ✗ ⇒ 第二次采样要等 30 秒 ✗
  ⇒ 明明已经读到 `MISC=0xc9`（attached + we_are_source ✓）却迟迟不切 host ✗。
  改为：**只要判定未落定就 1 秒轮询** ✓（投票中 / 刚发生状态变化 / dwc3 settle / sink-hold ✓），
  稳定后回到 30 秒兜底 ✓（省电 ✓）。
  实测：耳机插着 → `MODE_CFG=0x04`(source) ✓、端口 4.98 V ✓、6 个 `usb 3-x` ✓、声卡 2 张 ✓。
- **耳机识别“很慢”（2026-10-29 16:12，已改善 `526dc7e`）**：根因不是轮询 ✗，而是空闲时
  **Type-C 块停在了 sink 相位、几乎不再试 source** ✗（实测 MISC 连续 20 秒都是 `0x02` ✗）
  ⇒ 插进来的 sink 设备（耳机/U盘/键盘）只能等它下一次“试 source” ✗。
  写 `TAPER_TIMER_SEL_CFG.TYPEC_DRP_DFP_TIME_CFG`（0x1364 bit5 ✓）后实测轮转变成
  `0x02 ↔ 0x42` 每 **1–2 秒**一次（周期 2–4 秒 ✓）⇒ 设备最坏等待从几十秒降到 **2–4 秒** ✓。
  **充电器不受影响** ✓：它靠 VBUS 到达被立刻发现 ✓（不走这个轮转 ✓）。
- **旧的“部分生效”记录（保留）**：
  - 已实现：每 2 s 读 `TYPE_C_MISC_STATUS`（0x150B，`CC_ATTACHED` / `SNK_SRC_MODE` /
    `CC_ORIENTATION`）自动决定角色；空闲时端口保持 **DRP**（try-sink ✓），
    dwc3 留在 device（插电脑仍可用 ✓）；
  - **已验证**：插充电器 → `attached=1 we_are_source=0` → 自动选 **device** ✓、充电不受影响 ✓；
  - **未生效**：空闲 DRP 下**插设备（耳机/U盘）检测不到** ✗ —— `misc` 一直是 `0x02`
    （attached=0 ✗），端口不供 5 V ⇒ sink 无电 ⇒ 拉不高 D+ ✗。手动 `nabu-typec host`
    则完全正常 ✓（耳机枚举 + 声卡 ✓）。
  - **下一步**：查 Type-C 状态机的 DRP/try-source 配置 —— `TYPE_C_MODE_CFG` 的
    try-mode 时序、`TYPE_C_CURRSRC_CFG`(0x1552) 的 Rp 选择（`TYPEC_SRC_RP_SEL_MASK`）、
    以及 `TYPE_C_DEBOUNCE_OPTION`。自动检测补齐之前，host 模式请用命令 ✓。
- **用法（`nabu-power` `747e7a1`，已封装成命令）**：
  ```sh
  sudo nabu-typec host      # 主机模式：对外 5V，U盘/耳机/键盘可用（充电同时停止）
  sudo nabu-typec device    # 设备模式：充电器 / 接电脑
  sudo nabu-typec status    # 打印当前角色、端口电压、USB 树
  ```
  脚本内部就是“`auto` → 等 3 秒 → `host`”那两步 ✓，并顺手把端口电压和总线状态打出来
  （失败时一眼可见 ✓）。
- **已知限制**：dwc3 会**丢弃开机后第一次角色切换**（host 控制器不出现，而
  `usb_role_switch_get_role()` 因为缓存仍报成功 ✗）⇒ 所以必须两步 ✓。
  在驱动内部做重试/回弹试过，反而把状态搞坏 ✗（还一度把 boost 开关弄丢 ✗，已修 ✓）。
- **实机验证（2026-10-28 20:10）**：`sudo nabu-typec host` →
  `port 5V: 4.99 V` ✓、`Bus 003 Port 001: Dev 002`（Audio ×3 `snd-usb-audio` + HID ×1）✓、
  `/proc/asound` 从 1 张变 2 张 ✓、设备 `001f:0b21 Walmart AB13X Headset Adapter` ✓。

### 2.6.1 Type-C host 模式：控制器与供电已就绪，数据通路不通（P1，待查 2026-10-27）
- **已实现（`nabu-power`）**：用 SMB5 的角色开关取代 TCPM ——
  `/sys/bus/platform/devices/c440000.spmi:pmic@2:charger@1000/typec_role`
  写 `host` / `device` / `auto`；`host` 会切 dwc3 到 host 并打开 SMB5 的
  `usb-otg-vbus` 5V boost。
- **实测（2026-10-27）**：
  - `echo host` → `typec: role 0 -> 1`、`usb3/usb4 xHCI` 正常注册 ✓
  - 5V boost 真的在供电：电池电流从 ~-400 mA 跳到 **-765 mA**（移动硬盘在转）✓
  - 但 **`usb3` 上没有 `3-1` 设备**、dmesg 没有 `new high-speed USB device` ✗
    （换 Type-C 耳机同样不枚举，电流回到 -481 mA）
- **结论**：主机控制器 + VBUS 都 OK，**数据线（D+/D-）在 host 模式下没有到达 dwc3 PHY**。
  设备模式是通的（`udc=configured`、能枚举），所以 PHY/走线本身没问题。
- **2026-10-28 19:00 追加排查结果**：
  - xHCI `PORTSC` 实测 **`0x0100`（只有 PP=port power，没有 CCS=connect）** ✗ ——
    确认端口**完全看不到设备**，不是“看到了但枚举失败”；
  - 此时 **OTG boost 正常**（`usb-otg-vbus` 5000 mV，电池电流 -0.75 A ≈ 3.2 W 对外供电 ✓），
    说明设备在吃电、供电链路通 ✓；
  - `dpdm-supply = <&usb_1_hsphy>` 已加回（原来删掉了 ✗），驱动只在 APSD 期间 enable，
    其余时间 disable ⇒ D+/D- 应归 PHY ✓；
  - 发现并修了主线 PHY 驱动的 bug ✗：`dpdm_disable()` 只清标志、**不恢复
    `OPMODE_NONDRIVING` / `UTMI_PHY_DATAPATH_CTRL_OVERRIDE_EN` 那些位** ✗ ⇒ PHY 永久高阻 ✗。
    已补 `dpdm_disable()` + `phy_init()` 两处恢复（`nabu-power` `f6cd14f`）✓；
  - **但修完 PORTSC 仍是 `0x0100`** ✗（连 USB2 的 Type-C 耳机都不枚举 ✗）。
- **排查中排除的**：角色切换 ✓（`typec: role 0 -> 1`）、主机控制器注册 ✓（`xhci-hcd.5.auto`
  与 usb3/usb4 ✓）、供电 ✓、PHY DPDM 归属 ✗（已修但不生效）。
  注意：**开机后第一次切 host 会丢** ✗（第二次 `auto` → `host` 才生效 ✓），
  这是驱动里 `usb_role_switch_set_role()` 返回值的时序问题，需要重试 ✓。
- **2026-10-28 19:20 决定性实验（结论收敛到一点）**：
  - 固定 `dr_mode = "host"`（绕过 role switch）+ `nabu,otg-force-on`（强制开 boost）后：
    `OTG boost forced on` ✓、`usb-otg-vbus enabled=1` ✓，但
    **端口电压 `usbin_v = 0`** ✗、PORTCS 仍 `0x0100` ✗；
  - ⇒ **5V 根本没出到端口** ✗，所以“数据线”从来不是首要问题 ✓；
  - ⇒ 根因收敛到：**SMB5 的 Type-C 电源角色没有真正切到 source/DFP** ✗。
    证据：Type-C 块的寄存器**读回恒为 0**（`typec init: drp write rc=0` 但 `ctrl=0x0` ✗），
    而 SMB5 只有在 DFP/source 状态下才会把 boost 的 5V 接到 VBUS 上 ✗。
  - 同时确认了“不是 role switch 的问题” ✓：`dr_mode=host` 时 dwc3 的
    `GCTL.PrtCapDir = 1 (HOST)` ✓、PHY `UTMI_CTRL0` 的 OPMODE = NORMAL ✓、
    `DATAPATH_OVERRIDE` 未置位 ✓、`GUSB2PHYCFG(0)` TRDTIM 正常 ✓。
- **下一步（收敛后的单点）**：
  1. 让 Type-C 块真正进入 source/DFP：核实 `TYPE_C_INTRPT_ENB_SOFTWARE_CTRL`(0x1368)
     的写入为什么读回 0（是否需要先置 `TYPE_C_CFG.TYPEC_OR_U_USB`、
     或该块需要独立使能/时钟 ✗）；写出后 `usbin_v` 应变成 ~5000 mV ✓；
  2. 一旦端口有 5V，再回到 PORTCS 看 `connect`（数据线问题此时才需要查 fsa4480 ✓）。
- **旧的排查记录（保留）**：
  1. 临时把 DT 改成 `dr_mode = "host"` 并**固定**，绕过 role-switch 路径 ——
     如果这样能枚举 ⇒ 问题在角色切换/时序 ✗；仍不能 ⇒ 在 PHY/硬件 ✗；
  2. 用 devmem 读 dwc3 的 `GUSB2PHYCFG` / `GCTL`（看 PRTCAP 是否真的切到 HOST）与
     PHY 的 `USB2_PHY_USB_PHY_UTMI_CTRL0`（看 OPMODE 是否真的 NORMAL）✓；
  3. 查 `i2c4/typec-mux@43`（fsa4480）在 host 下的 orient 是否影响 D+/D-（通常只切 SBU/SS）。

### 2.7 `console=ttyGS0` 会让关机卡死（P0，已修 2026-10-27）
- **现象**：`systemctl reboot` 后屏幕停在 "The system will reboot now"，机器不重启、
  不断电，只能长按电源键；journal 停在 `Reached target final.target`。
- **串口证据**（`console=ttyGS0`，2026-10-27）：
  ```
  … reg-dummy reg-dummy: shutdown
  … PM: Calling ledtrig_cpu_syscore_shutdown
  … PM: Calling irq_gc_shutdown
  … PM: Calling printk_kthreads_shutdown     ← 停在这里，永远等不到 "Restarting system"
  ```
- **根因**：内核控制台就是 USB gadget 本身。`device_shutdown()` 里 dwc3 先被拆掉，
  `ttyGS0` 的主机端消失，而 printk 线程仍在往它写；紧接着
  `printk_kthreads_shutdown()` 等这些线程收尾 ⇒ 死锁。
  同一路径也解释了“拔插 USB 后整机冻结”：主机重枚举时 printk 正在写，日志里出现
  `dwc3 a600000.usb: request … was not queued to ep1in` 之后整机卡死。
- **修复**：`nabu-main/config/minimal.cmdline` 改成 `console=tty0`（production 本来就是），
  gadget 只作为普通 tty 保留。实测连续 3 次重启 43–44 s 全部正常。
- **注意**：**不要**再把 gadget 配成 printk 控制台；要远程内核日志请用 `netconsole`
  （`config/nabu-netconsole.config` 已编入）而不是 USB gadget。


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
