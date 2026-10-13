# Linux 7.2.7 nabu 移植记录

小米平板 5（nabu，SM8150）从 6.14.11 移植到 Linux 7.2.7 的修改记录。
**每次对 7.2.7 移植的改动都必须追加到本文件。**

- 内核树：`linux-7.2/`，分支 `v7.2.7-nabu-display`
- 上游基线：`f42acb367842`（Linux 7.2.7）
- 移植提交：`7c2c95a1922d`（sm8150: port the nabu support to Linux 7.2.7）、`e490383191ba`
- 构建/安装：`nabu-main/`（产品 `production-7.2`，release `7.2.7-nabu-full`）
- 参考仓库（**不作为代码来源**）：https://github.com/MCC45TR/nabu-linux-kernel.git

---

## 修改日志（最新在上）

### 2026-10-13 Debian 镜像“开机首个会话不旋转”：三处根因（getty 卡 boot / helper 提前 ON / proxy 启动竞态）
- 现象：刷机后开机，**首个图形会话（GDM 登录页）与登录后的用户会话都不自动旋转**，注销重登后恢复。
- 实机（`6.14.11-nabu-full`，`nabu-debian`，192.168.0.67）定位到三层，缺一不可：
  1. **`serial-getty@ttyGS0.service` 卡住 boot 90 s**：它被 symlink 进 `getty.target.wants`，
     而无 USB 主机时 `/dev/ttyGS0` 不会出现（legacy `g_serial` 在 UDC 未连接时不建端口）→
     `dev-ttyGS0.device` 走满 systemd 默认 `JobTimeoutSec=90s` → `getty.target`/
     `multi-user.target` 被拖到 **1min30s** → `hexagonrpcd`（Debian 单元 `After=multi-user.target`）
     → `iio-sensor-proxy` 直到 ~113s 才起（`systemd-analyze`：userspace 1min30.6s；
     `journalctl`：`dev-ttyGS0.device: Job ... timed out`）。
     修复（`nabu-main/debian/build.sh`）：**删除该 getty**（`console=ttyGS0` 早已移除，串口只用于
     `dmesg`）→ boot 降到 **~12.6s**，`multi-user.target` @10.8s。
  2. **`nabu-tablet-mode` 的 30s 兜底提前置 ON**：传感器栈晚到，兜底在真实 `ClaimAccelerometer`
     之前触发（日志 `SW_TABLET_MODE=ON (no claim seen, timeout)`）；Mutter 在 claim 前看到 ON →
     `update_panel_orientation_managed()` 先 `uninhibit_tracking()`（`inhibited_count=-1`）→
     永不 claim → 本次会话不旋转。修复：**删掉该兜底**，只在真实 claim 后 ON
     （`nabu-accelerometer/userspace/nabu-tablet-mode.c`）。
  3. **`iio-sensor-proxy` 启动竞态（最关键）**：它**先持有 `net.hadess.SensorProxy` 名字、后
     `find_sensors()`/`driver_open()`**。Mutter 一看到名字就 `ClaimAccelerometer`，此时 SSC 驱动
     尚未建立：`handle_generic_method_call()` 把 client 记入 `data->clients[]` 但**无法开流**，而
     **启动路径 `name_acquired_handler()` 不会为“已 claim”的传感器补 `driver_set_polling()`**
     （只有热插拔路径会）。结果加速度计永不推数据：`Accel sent by driver` 计数 **0**、
     `AccelerometerOrientation=undefined`（而 `ssccli --sensor accelerometer` 直读有数据）。注销
     重登时新 Mutter 在代理就绪后才 claim → 正常。修复：新增
     `nabu-accelerometer/patches/0005-ssc-startup-claim.patch`，在 `name_acquired_handler()` 里对
     已有 client 的传感器补 `driver_set_polling(TRUE)`（对齐热插拔路径）。
- 验证（三处都部署后 reboot，实机）：`iio-sensor-proxy` 日志
  `ClaimAccelerometer` → `Found SSC accelerometer` → `Emitted orientation changed: from undefined to left-up`；
  `Accel sent by driver` 1581 条；`AccelerometerOrientation=left-up`、`AccelerometerTilt=tilted-up`；
  helper `OFF → ClaimAccelerometer → ON (accelerometer claimed)`；boot 12.5s。
- 说明：三处改动对 6.14.11 与 7.2.7 两个产品都生效（`nabu-accelerometer` 与 Debian 镜像共用）。

### 2026-09-30 GPU fault 深挖：devcoredump 抓取/解析 + 逐条 fault↔VMA 状态分类
- 结论（**2026-09-30 已由 fault 时插桩钉死**）：故障 iova 在**故障时刻**属于 GPUVM 的某个
  VMA 且 `mapped=1`，同时 SMMU 页表 walk 的 L3 叶子**有效**（例：
  `nabu-fault iova=106b90000 vma=HIT below=106af8000/1 above=106b9c000/1` +
  `contained va=106afc000+0a0000 mapped=1`，`ptes[3]=0000017cef6e43`）——即
  「映射存在、页表有效，SMMU 却报 TRANSLATION fault」⇒ **SMMU 翻译缓存/TLB 不一致**，
  **不是悬空地址**。最可能机制：per-process pagetable 全部用 **ASID 0**
  （`msm_iommu_pagetable_create()` 的 TODO），而 map 路径**不做 TLB 失效**、切换 pagetable
  （`a6xx_set_pagetable()`）只发 GPU `CACHE_INVALIDATE`（不清 SMMU TLB），于是复用/跨上下文
  的 VA 命中陈旧翻译条目。
  - 注：`nabu-gpu-fault-watch`（gem）对**触发 recover 的 fault 不可靠**——recover 会很快
    teardown 该 VM，watcher 在 ~0.1s 后查 gem 已是 ABSENT；故应以 fault 时的插桩为准。
  - 早前 dump 里出现的 `ptes L3=0` 可能是 recover 之后/不同子情形，需以后再取数。
- 现象（不变）：`*** gpu fault: ... dir=READ type=TRANSLATION source=CCU`（Adreno 640，
  CCU=颜色缓存/UBWC/2D resolve），开机/使用中成簇复现（同一地址反复），驱动 hangcheck 自愈，
  offending task 多为 `gnome-shell`（`--mode=gdm`/`--mode=ubuntu`）。`renderD128` 正常。
- **新增常驻设施**（均随 boot 自启）：
  - `tools/nabu-devcdump-capture.sh` + `nabu-devcdump-capture.service`：抓
    `/sys/class/devcoredump/devcd*/data` → `/var/log/nabu-gpu-dumps/`（保留最近 20）。
    **dump 消失的真因**：`DEVCD_TIMEOUT=5min`（`include/linux/devcoredump.h:16`）自动回收，
    之前 `devcd1/2` 就是这样丢的（不是 apport，也不是 5 分钟超时外的别的原因）。
  - `tools/nabu-gpu-fault-watch.sh` + `nabu-gpu-fault-watch.service`：每条新 `gpu fault`
    即时对照 `/sys/kernel/debug/dri/0/gem`（列出每个 BO 的 VMA + `mapped`/`unmapped`），
    分类写入 `/var/log/nabu-gpu-dumps/fault-gem-map.log`。
  - `tools/nabu-gpu-dump-parse.py`：解析 dump 的 `fault-info` / `pgtable-fault-info` /
    `bos` / `vm-log`，并做 fault IOVA↔BO 关联。用法
    `python3 tools/nabu-gpu-dump-parse.py <dump>`。
  - cmdline（`nabu-main/config/production-7.2.cmdline`）加 **`msm.vm_log_shift=8`**
    （内置模块前缀必须是 `msm.`，已随 `Boot0008` 打包安装；见 `ukify` `.cmdline`）。
- 关键证据（`#84` 之后的 boot）：
  - dump 的 `pgtable-fault-info.ptes` 是**逐级**描述符（`io-pgtable-arm.c:793 data->ptes[lvl]`，
    `start_level=0`，L0..L3）：出现两种——`ptes[3]=0`（L3 叶子无效，**未映射**）或
    L3 有效（已映射）。
  - 最新 fault dump（`gnome-shell`，`iova=0x10f5f0000`，`ttbr0=0x17f880000`）：
    `ptes L3=0` 且运行时 `gem` 该地址 **ABSENT** → 两条证据一致，确为悬空地址。
  - 运行时 gem 分类：某 boot 36 条 fault 中 **34 条 `gem=ABSENT`**（任何 VM 都无该 VMA），
    仅 2 条 `mapped`（早期 greeter 的 `0x10d440000`/`0x10d460000`）。
- 排除/注意：
  - **vm-log 对合成器无用**：msm 只对 user-managed（VM_BIND）VM 分配日志
    （`msm_gem_vm_create()` 里 `if (!managed) vm->log_shift=...`），gnome-shell 是
    kernel-managed。`msm.vm_log_shift=8` 仅对 VM_BIND 客户端（如某些 Vulkan 应用）有效。
  - kernel-managed dump 的 `bos:` 只是**该次 submit 的 BO**（`crashstate_get_bos()` 非
    vmbind 分支用 `submit->bos`），不是整个 VM，所以「不在 bos 里」不等于未映射，必须配合
    `gem`/`ptes` 判断。
  - 固件不缺（`a630_sqe.fw` + `a640_gmu.bin`，GMU v2.0.261）。
- 下一步：**实验**——在 map 路径补 SMMU TLB 失效（`msm_iommu_pagetable_map()` 成功
  `map_pages()` 后 `iommu_flush_iotlb_all(domain)`），或给 pagetable 分配唯一 ASID /
  切换 pagetable 时失效 TLB；观察 fault 是否消失以确认。
  - **实验 1（map 后 flush）已应用并验证（部分成功）**：在 `msm_iommu_pagetable_map()` 与
    `msm_iommu_pagetable_map_prr()` 成功末尾各加一次
    `iommu_flush_iotlb_all(to_msm_iommu(pagetable->parent)->domain)`。
    **结果**：之前每次开机 greeter 首次绘制（~15s）必 fault，本 boot greeter 从 20:38:46
    运行到登录（~11min）**零 fault**；fault 推迟到 688s（用户登录/首次交互）才出现，仍带
    `vma=HIT mapped=1` 签名。→「新上下文首次 map」这一类被消掉，剩下的是**切 pagetable 时**
    命中上一上下文的陈旧条目（ASID 0 共享）。
  - **实验 2（切 TTBR0 时 flush）结果**：本 boot fault 依旧（13 条、1 recover），无内核告警；
    且本次 recover 那条是 **`mapped=0`**（VMA 在但驱动标为未映射），与之前 `mapped=1`
    （页表有效）是**两种不同机制**，TLB flush 修不了 `mapped=0`。
  - **实验 2b（改用正确 API 重试，已打包安装，待重启验证）**：之前的
    `iommu_flush_iotlb_all(domain)` 走的是 domain 的 flush_ops，**不一定**能失效 per-process
    pagetable 的 TLB。改为 io-pgtable 回调（unmap 路径依赖的同一套）并强制上电：
    `msm_iommu_pagetable_tlb_flush()` 内做
    `pm_runtime_get_sync(iommu_dev)` → `pagetable->tlb->tlb_flush_all(adreno_smmu->cookie)`
    → `pm_runtime_put_sync()`；map 路径与切上下文都调它。判据：`gpu fault`/`recover` 归零。
  - **实验 3（BO 生命周期 / unmap reason，已打包安装，待重启验证）**：让 kernel-managed VM
    也分配 VM op 日志（`msm_gem_vma.c` `msm_gem_vm_create()` 去掉 `if (!managed)` 守卫），
    使故障 dump 的 `vm-log:` 带上该地址的 map/unmap 及 **reason**（`evict`/`purge`/`close`/
    `vma_put`）。解析：`python3 tools/nabu-gpu-dump-parse.py <dump>`（会打印与 fault iova 重叠
    的 op）。动机：`mapped=1` 是**采集时机**（`pm_runtime_get_sync` 睡眠之后）造成的，真故障
    瞬间更可能是未映射/已 unmap，需看 unmap 时间线。
  - **实验 3 结果（决定性）**：managed VM 的 `vm-log` 现已可取。两类签名：
    1. 用户会话 fault（`iova=0x111fc0000`）：`vm-log` 为 `map:0 0x111fb8000-0x111fc4000`
       → **`close:0 同范围`**，且 `ptes[3]=0`（真未映射）⇒ **use-after-unmap（GEM_CLOSE）**。
       `nabu-fault vma=MISS`。
    2. greeter 开机 fault（`iova=0x109690000`）：`vm-log` 全是 `map`、无 unmap，`ptes[3]` 有效
       ⇒ 表面矛盾；且该地址作为 64-bit 值出现在一个 4MB 命令缓冲 BO（`0x104d9f000`, flags=0x80002,
       偏移 +0x180070）里，说明命令流确实指向它。
    合并解释：**同一机制——VA 复用 + `close` 后 GPU(CCU) 预取仍读旧地址**；故障落在「close →
    该 VA 被重新 map」的窗口内。采样（`nabu-fault`/`ptes`/`gem`）都在 `pm_runtime_get_sync`
    睡眠**之后**，故 greeter 那条看到的是已重新映射的状态。
    `close` 出处：`msm_gem_close_vma()`（`msm_gem.c:84`，GEM_CLOSE 时 `dma_resv_wait_timeout
    (BOOKKEEP)` 后 `put_iova_spaces(..., "close")`）。
  - **根因（对比 6.14.11，已定位）**：`msm_gem_close()` 在两版行为不同——
    - **6.14**：只 `update_ctx_mem(file, -obj->size);`，**不动 GPU 映射**。
    - **7.2**：`msm_gem_vma_put()` + 对非 VM_BIND 上下文
      `dma_resv_wait_timeout(BOOKKEEP)` 后 `put_iova_spaces(obj, ctx->vm, true, "close")`
      —— **GEM_CLOSE 即拆 VMA**。
    引入于 VM_BIND 系列 `feb8ef4636a4`（`drm/msm: Add opt-in for VM_BIND`，v6.17 起 → 7.x）。
    ⇒ kernel-managed 上下文在 close 时拆映射，与 GPU(CCU) 残留/预取读竞态（读在 fence 之后
    才落地）→ TRANSLATION fault；VA 复用后采样看到「已重新映射」→ 造成 `mapped=1` 的假矛盾。
    这解释了 `close` reason、以及为何「SMMU TLB flush 无效」。
  - 修复方向（待定）：kernel-managed 上下文也像 VM_BIND 一样**延迟拆 VMA 到 VM/设备关闭**，
    或让 close 前的 drain 覆盖 CCU 预取；属上游 msm 行为，建议上报。
  - **2026-09-30 修复实验（已打包安装，待重启验证）**：`msm_gem_close()`（`msm_gem.c`）
    对 **kernel-managed 也直接 return、不在 GEM_CLOSE 拆 VMA**（删掉
    `dma_resv_wait_timeout` + `put_iova_spaces(..., "close")`），交回 `msm_gem_vm_close()`。
    预期：`gpu fault`/`hangcheck recover` 归零。副作用风险：长生命周期上下文（gnome-shell）
    的 VMA/iova 不再于 close 释放，可能累积 VA（a640 VM 仅 4GB），需留意 drm_mm 分配失败。
  - **2026-09-30 6.14.11 实机对照（已确认回归）**：启动 `6.14.11-nabu-full-build1.efi`
    （`Boot0008 nabu-6.14.11`），开机后 `gpu fault=0`、`recover=0`；7.2.7 同机十几条。回归坐实。
  - **机制收口（fault 时插桩 + 代码次序）**：
    - 故障瞬间页表无效（`nabu-fault-pre ptes[3]=0`）、`vma=HIT`、vm-log 无该地址条目；时间戳显示该地址
      的 `map` 在故障后 ~3.6ms → **读到尚未映射的 VA**。
    - `msm_gem_submit()` 次序：`submit_pin_objects`(map, 685) → `drm_sched_entity_push_job`(807)，
      **先 map 后入队**，故本次 submit 的 BO 必已映射。
    - ⇒ 命令流引用了**不属于本次 submit**的 BO 地址（典型：用户态 `GET_IOVA` 拿到地址却未把该 BO
      放进引用了它的 submit）。**非** SMMU/TLB/一致性，**非** UBWC（`FD_MESA_DEBUG=noubwc,noblit,inorder`
      无效），**非** close 竞态（已 patch 排除）。
  - **已建工具**：`crashdec`/`cffdump`（mesa-26.0.8，`./mesa/build/src/freedreno/decode/`）；dump 需先把
    `revision: 640 (06040001)` 改成 `(6.4.0.1)` 才能被 crashdec 解析。crashdec 未在命令流中找到对该地址的
    显式引用 → 疑为硬件派生（UBWC flag）或来自未入 submit 的 BO。
  - **crashdec 定位（渲染目标 UBWC flag）**：对最新 fault dump 解码寄存器，引用 `0x10b6ab000` 的字段为
    `RB_MRT[0].BASE`、`RB_COLOR_FLAG_BUFFER[0].ADDR`(pitch=0)、`RB_RESOLVE_SYSTEM_BUFFER_BASE`
    （pitch 6400 → 1600×2560 RGBA = 16MB，正是平板分辨率）。**故障地址 `0x10b6a0000` = `0x10b6ab000`
    − `0xB000`**，即该 16MB 渲染目标的**最后 0xB000 = UBWC flag/meta 区**；该 BO 在故障后才 map（+83ms）。
    ⇒ CCU 在 resolve/render 时读渲染目标的 UBWC flag 区，而该 BO 当时未映射。
  - 一致现象：早期 dump 也出现「故障地址恰在某 BO 下方 0xB000」。
  - `FD_MESA_DEBUG=noubwc` 无效 ⇒ 这条 **render target/resolve 的 UBWC** 路径未被该开关覆盖（可能仅作用于
    internal buffers，public/scanout 仍 UBWC）。
  - 下一步（继续）：查为何该渲染目标 BO 在其 flag 被读时未映射（是否未进本次 submit / 被 evict / flag 与 color
    分属不同 BO 而只 map 了其一）；或整理为上游报告（msm + freedreno，附本条与 6.14 对照）。
  - **2026-10-01 实验：UBWC `amsbc`（已打包安装，待重启验证）**：对比 6.14/7.2 的 UBWC 寄存器编程，
    唯一差异是 `a6xx_set_ubwc_config()` 的 **`amsbc`**：6.14 为 0，7.2 的
    `qcom_ubwc_enable_amsbc()` 对 `enc_version >= UBWC_3_0`（sm8150=UBWC3.0）返回 **1**，写进
    `RB_NC_MODE_CNTL` bit4。AMSBC 影响 UBWC 的 **flag 布局/地址计算**，且**未通过 `MSM_PARAM_UBWC_*`
    暴露给 Mesa**（Mesa 按 amsbc=0 布局）⇒ GPU 按 amsbc=1 算 flag 地址可能与 Mesa 布局错位，正是
    「CCU 读 `MRT.BASE − 0xB000` 的 flag 区」现象。实验：`a6xx_gpu.c` 里强制 `amsbc = false`（对齐 6.14）。
    判据：重启后 `gpu fault`/`recover` 是否归零。若成立，正解是让 UBWC 参数（含 amsbc）与 Mesa 一致
    （暴露参数或按 SoC 设 0）。
  - **2026-10-01 再插桩：遍历 ring 所有在飞 submit**（结果）：`ring fence=446`，在飞 submit
    `seqno=447(77 BO) / 448(34 BO)`，**两者的 BO 表都不含故障地址**（`contains=0`），且当前 submit
    `refs_total=0`。⇒ 故障地址**不属于任何在飞 submit** ⇒ 排除「用户态漏交 BO」⇒ 是 **CCU 硬件派生/预取**
    的地址（渲染目标/UBWC flag/resolve 派生），落在尚未映射的 16MB 渲染目标 VA 区间。
  - 另：`amsbc=false` 实验**无效**（已回退），UBWC 寄存器唯一差异不是原因。
  - 结论：根因在 **GPU/驱动映射模型**（6.14 无、7.2 有），非用户态漏交、非 SMMU/TLB、非 UBWC 配置。
    建议整理为上游 bug report（msm + freedreno）。
  - **新工具**：`tools/nabu-dump-search.py <dump> <hex>`——解码 dump 的 `!!ascii85` BO 数据
    （kernel `include/linux/ascii85.h`：u32 小端→5 字符 base85，全零→`z`），搜某地址作为
    32/64-bit LE 出现在哪个 BO（需 `rd_full=Y` 才有全量 BO 数据；`rd_full` 已恢复 `N`）。
  - 代价/正解：这两次 flush 都是全量 SMMU TLB 失效（每次 map / 每次切上下文），性能回退；
    确认有效后应改为**唯一 ASID**（`CP_SMMU_TABLE_UPDATE` 的 ASID 由 0 改为每 pagetable 唯一）
    或更精细的按范围失效。
- 插桩代码（临时，验证后可删）：`linux-7.2/drivers/gpu/drm/msm/msm_gpu.c`
  `msm_gpu_crashstate_capture()` 里，`if (submit && state->fault_info.ttbr0)` 块内追加
  GPUVA 树查找并 `DRM_DEV_ERROR` 打印 `nabu-fault ...`（vma=HIT/MISS、contained、mapped、
  below/above）。仅对触发 coredump 的 fault（burst 首条）打印。

### 2026-09-30 功耗排查：cluster idle 想开但固件不支持（强制 OSI 无效，已回退）
- **现状**：DT 里其实**已有** cluster 域 idle 状态（`cluster_pd` + `cluster-sleep-0`、`psci` genpd 层级），
  配置 `ARM_PSCI_CPUIDLE_DOMAIN=y`，日志 `CPUidle PSCI: Initialized CPU PM domain topology using OSI mode`。
  但 `/sys/devices/system/cpu/*/cpuidle/` 只有 `WFI` + `cpu-sleep-*-0` 两档，`power-domain-cpu-cluster0`
  空闲时仍 `on`（L2/集群 rail 不塌）。（CPU 级是好的：`power-domain-cpu7 off-0`。）
- **试验**：把 `psci_1_0_init()` 里的 `psci_set_osi_mode(false)` 改成 `true`（强制 OSI），重编 Image 实测：
  - `psci_set_osi_mode(true)` **不报错**——说明固件**本来就在 OSI**，之前那条
    `[Firmware Bug]: failed to set PC mode: -3` 只是「切不回 PC」而已。
  - 结果：cluster 域**仍 `on`**、cpuidle 仍 2 档；熄屏 idle 1.07~1.48 W（≈ 无变化）。
- **结论**：**cluster idle 由固件决定，内核改不动**。已 `git checkout` 还原 `psci.c`、重编 Image、
  重打包 UKI、删除 ESP 上的测试项（正式 UKI 未动）。
- 熄屏 idle 最终停在 **~1.1–1.2 W**。

### 2026-09-30 功耗排查：`modem`(MPSS/WPSS) **不能关**——它同时负责 WiFi 固件；运行时 `stop` 会挂机（勿做）
- 确认 nabu 是 **Wi-Fi only**（只 `lo`/`wld0`，无 wwan），但 `remoteproc_mpss` 仍 `status="okay"` 并 boot
  `modem.mbn`（6.14 起就如此）。一度以为纯浪费。
- **实测 1（运行时 stop）**：`echo stop > /sys/class/remoteproc/remoteproc1/state` 会让整机**硬挂起**
  （无 panic/oops、`pstore` 空、journal 直接断），实测 2 次（`16:06`、`16:10`）。**勿做。**
- **实测 2（DT `disabled` + 独立测试 UKI）**：改 `&remoteproc_mpss { status="disabled"; }` 后能启动，
  但 **WiFi 直接没了**——说明这个 MPSS/WPSS 还负责 **WCN3990(ath10k) 固件加载**，不是纯蜂窝。
  → **必须保留 `status="okay"`**。已 `git revert`（`linux-7.2` `4d640adb`、`nabu-platform` `888ca58`），
  ESP 上的测试 `7.2.7-nabu-nomod.efi` 已删除，DTB/UKI 已重建回一致。
- 结论：熄屏 idle ≈ **1.17 W**（VPU resume 修复后从 1.46 降下来）。常开项（MPSS/WPSS、adsp、cdsp、
  slpi、DDR）都是必需的，当前手段下**没有安全可降的空间**，到此为止。

### 2026-09-30 resume 后 VPU 不回落：`iris_hfi_pm_resume()` 没重新安排 idle collapse（已修）
- 现象：一次挂起/恢复后 `venus_gdsc`/`vcodec0_gdsc`/`vcodec1_gdsc` 卡在 `on`（挂起前是 `off-0`），
  VPU 一直供电，白耗电。
- 根因：VPU5 用 `pc_work`（2s 延迟）做 idle power collapse，只有实例关闭 / collapse 重试时才会
  `iris_pc_schedule()`。系统 suspend 前 idle worker 已把 VPU 收起（`vpu_suspended=true`）；
  `iris_hfi_pm_resume()` 会把它重新上电 + boot 固件，但**没有重新安排 collapse** → 无会话时也一直开着
  （旧注释写的“之后 idle work 再次收起”实际没发生）。resume 里的 power-on 本身是为了重 boot 固件。
- 修复：`linux-7.2` `4da9aa32`（树，权威源）与 `nabu-iris` overlay `b5d839f`——resume 末尾调用
  `iris_pc_schedule(core)`。
- 验证：装新模块、重载后挂起/恢复：日志 `Iris1 firmware booted` → 2s 后 `VPU entered power collapse`，
  `venus/vcodec` 均回到 `off-0`。
- 备注：7.2.7 产品**不走 `apply`**，内核代码以 `linux-7.2/` 树为准（overlay 仅 6.14/参考）；所以树和
  overlay 两份都改了。

### 2026-09-30 登录瞬间「竖屏闪一下」：logind 把关开关改早了，改为等新会话 shell 起来再切
- 现象（用户）：横屏在登录页输密码 → Enter → 屏幕**闪一下竖屏**再回横屏。
- 时序（boot `14:54`）：
  ```
  14:54:46  greeter Mutter claim → SW_TABLET_MODE=ON      (登录页横屏)
  14:54:52  logind: New session '6' class=user            (按 Enter，会话建立)
  14:54:52  helper: SW_TABLET_MODE=OFF; graphical session changed  ← 比新 shell 早 ~2s
  14:54:54  gnome-shell[7011]: Registering session with GDM        (用户 Mutter 起来)
  14:54:54  ClaimAccelerometer → SW_TABLET_MODE=ON
  ```
  中间 ~2s `touch_mode=false` → Mutter 不接管方向 → 用**面板 builtin 方向（竖屏）**；此时 greeter
  还在屏上，于是「闪一下」。旧版 `/proc` 是在 **gnome-shell 进程出现**时才 OFF，窗口很短；改成
  logind 后按「会话建立」就 OFF，提前了 ~2s——**这是那次 logind 改动带出来的回退**。
- 修复（`nabu-accelerometer` `c80da1c`）：logind 仍负责会话身份，但**切换前先等新会话 uid 的
  `gnome-shell` 真的出现**再 OFF（只在切换 pending 时做限时 `/proc` 探测，平时依旧零轮询），
  这样旧 shell 不被打扰、新 Mutter 仍能在 claim 前看到 OFF。日志新增
  `shell <uid> not up yet, deferring switch reset`。
- 验证：`shell` 已在运行时**不进入 defer**（正常启动/resume 仍零轮询，实测 CPU 0.0%）；
  **2026-09-30 用户「注销→登录」实测：竖屏闪烁消失**。日志确认走了 defer 路径：
  ```
  15:04:53  shell 1000 not up yet, deferring switch reset
  15:04:54  SW_TABLET_MODE=OFF; graphical session changed   (用户 shell 起来后才关)
  15:04:56  ClaimAccelerometer → SW_TABLET_MODE=ON
  ```
  产物 SHA256 `78c616ab…`，已装 `out/`、artifacts 与 `/usr/local/libexec/`。

### 2026-09-30 s2idle 后 SLPI 复位的根因与修复：挂起前停 `hexagonrpcd`（FastRPC），proxy 与 Mutter claim 全程不动
- 现象延续下一条：带传感器流挂起 → resume 后 SLPI 复位 → `iio-sensor-proxy` 退出/SEGV → 重启丢
  D-Bus 名字 → Mutter 丢 claim → 自动旋转消失。
- **根因（本次定位）**：只要传感器在持续流，**每次挂起**都会在 **AP 仍处于挂起状态时**崩：
  ```
  PDM: service 'sensor_process' crash: 'EX:sensor_process:0x1:frpc_dsp:0x6d:PC=...'
  qcom_q6v5_pas 2400000.remoteproc: fatal error received: ...:frpc_dsp:...
  hexagonrpcd[...]: Could not fetch next FastRPC message: Broken pipe
  ```
  即 DSP 的 `sensor_process` 崩在 **FastRPC 路径**（`frpc_dsp`）。而 `fastrpc.c` / `qcom_q6v5_pas`
  **没有任何 suspend/pm 处理**。
- **关键发现**：`libssc`（`iio-sensor-proxy`）用 **QRTR** 直连 SLPI，sensors PD attach 之后
  **不需要 FastRPC**。于是挂起前 `systemctl stop hexagonrpcd`：传感器照流、proxy 不退出，
  而 DSP 没有会崩的 FastRPC 会话。
- **修复（`nabu-accelerometer` `215eb57`）**：`nabu-sensors-suspend.service`（`Before=suspend.target`）
  停 `hexagonrpcd`；`nabu-sensors-resume.service`（`After=suspend.target`）再起；**`iio-sensor-proxy`
  全程不动** → D-Bus 名字 / Mutter claim 不丢 → 旋转跨挂起保留。
- **验证**（带传感器流 + `systemctl suspend`，4 个 cycle）：**SLPI 0 崩溃、`iio-sensor-proxy` 0 重启、
  数据流连续、`AccelerometerOrientation` resume 后仍有效**。
- 兜底（`8a84037`）：`iio-sensor-proxy` `Restart=on-failure` + resume hook 的 start-if-not-active。
- 待办：这是「避免触发」，固件层 FastRPC/s2idle 根因仍在；`hexagonrpcd` attach 之后为何停掉不影响
  数据流值得后续确认。建议用户先手动验证一次「熄屏→唤醒→旋转」，再开自动挂起。

### 2026-09-30 s2idle 排查：`c8c000.serial` 虚假唤醒已修（s2idle 能保持）；但 SLPI resume 崩溃 + `iio-sensor-proxy` 段错误仍在
- 背景：`KNOWN-ISSUES.md` 2.3（s2idle resume 后 SLPI 崩溃、屏幕唤不醒）证据来自 **6.14.11**，7.2.7 上没人复测。
- **s2idle 以前根本睡不着**：`c8c000.serial`（SM8150 GENI 调试 UART）唤醒 IRQ 虚假触发，把 s2idle 在 **~1s**
  内打断（`pm_wakeup_irq=176`、`msmgpio 46 c8c000.serial:wakeup`）。`PM: suspend entry/exit` 都出现但没睡着，
  所以 2.1 的“5 周期无失败”实为快速弹跳，不省电。
  - 隔离：serial 开 + rtc-efi 关 → 1s 醒；serial 关 + rtc-efi 开 → 保持整 10s。**只有 UART 需要修**。
  - 修复（`nabu-platform`）：`config/99-nabu-serial-wakeup.rules`
    （`ACTION=="add", SUBSYSTEM=="platform", KERNEL=="c8c000.serial", ATTR{power/wakeup}="disabled"`）
    + `nabu-module.toml` 的 `rules`/`[install]`。已装本机并 `udevadm trigger` 验证；装后 s2idle 保持整个 RTC 闹钟时长。
- **但 2.3 本身没修掉**（7.2.7 仍可复现，低概率）：
  - 代理**空闲**时 6 次 `rtcwake -d rtc1 -m freeze`（10–18s）0 崩溃；
  - 用 `monitor-sensor` **持续读罗盘/光感**后再挂，resume 时**复现**（13:53:07）：
    `PM: suspend exit` → `remoteproc0: crash detected in slpi (fatal error)` → `iio-sensor-proxy`
    `status=11/SEGV` + `Failed with result 'core-dump'` → `hexagonrpcd` 退出；随后 SLPI 每 ~40s 崩溃循环。
  - 之后再跑 7 个 cycle（含 3 个边流边挂）未再崩 → **竞态/低概率，非每次必现**。
  - 后果：`iio-sensor-proxy` 无 `Restart=`，崩后停在 failed、`net.hadess.SensorProxy` 消失；
    即便不崩，`hexagonrpcd` 也会在挂起时退出 → **息屏挂起会丢传感器/自动旋转**。
- 上游 `hexagonrpcd-suspend/resume.service` 的 `ConditionFirmware=…(qcom,sdm670)` 在 nabu（SM8150）不满足 → 从没执行过。
- **已加 stopgap（`nabu-accelerometer` `8a84037`）**：
  - `iio-sensor-proxy` 加 `Restart=on-failure`（2s）+ 放宽 start limit（SLPI 重置把它打崩后能自己起来；
    实测 `kill -SEGV` 后 2s 自动重启、`HasAccelerometer=true`）；
  - 新增 `nabu-sensors-resume.service`（`After=suspend.target`）：resume 后 `systemctl start
    hexagonrpcd + iio-sensor-proxy`。对**运行中**的 unit 是 no-op，所以**干净 resume 不会动 Mutter 的
    claim/旋转**；只拉起「干净退出」的 unit（崩溃的靠 `Restart=on-failure`）。
  - 实测：`systemctl suspend`（走 systemd hook；注意 `rtcwake` 直接写 `/sys/power/state`，**不走** hook）
    后 hook 正常执行；干净 resume 时 `AccelerometerOrientation=right-up`，旋转保留。
  - **仍存的限制**：Mutter 在 `iio-sensor-proxy` 重启后**不会**自动 re-claim（实测重启 helper+proxy、
    再等 helper 30s 强制 ON，Mutter 仍不 claim）→ **崩溃后自动旋转仍需重新登录**；光感/罗盘会恢复。
- 待办：**根因（SLPI resume 崩溃）仍未解决**，在它修好前**不建议开自动挂起**；可继续修 SLPI/QRTR
  （现在有较稳的复现条件：挂起时保持传感器流）。自动挂起目前仍关
  （`sleep-inactive-*-type='nothing'`）。量化较难：`qcom-battery` 无 `charge_counter`/`energy_now`，
  短时挂起电流读不到。

### 2026-09-30 `nabu-tablet-mode` 改为事件驱动：logind 会话监听取代 200ms `/proc` 轮询
- 动机：旧实现每 200ms 扫 `/proc`（找 `gnome-shell`、读其 `cmdline` 里的 `--mode=gdm`）来检测图形
  会话变化，常驻 **~2.1% 单核**（`ps` TIME 27 分钟里 34.9s，基本都在 `sy`）。
- 改动（`nabu-accelerometer/userspace/nabu-tablet-mode.c`）：
  - 新增第二个 sd-bus 连接监听 `org.freedesktop.login1` 的 `SessionNew`/`SessionRemoved`；事件到达时用
    `ListSessions` + 每个会话的 `Class`（`greeter`/`user`）与 `Type`（`wayland`/`x11`=图形，
    `tty`/`unspecified`=非图形）重新判定会话，取代 `/proc` 扫描；
  - 主循环改用 `poll()` 同时等 claim-monitor 与 logind 两条总线
    （`sd_bus_get_fd`/`sd_bus_get_events`），超时由 200ms 提到 1s（仅用于兜底 30s claim 超时）；
  - 删除 `current_shell_state()`（`/proc` 扫描）与 `sleep_us()`/`POLL_USEC`，新增
    `query_shell_state()`/`start_logind_watch()`/`wait_for_events()`。
- 为什么不用 `/proc`：内核没有“进程启动”事件，Mutter/iio-sensor-proxy 也不广播会话身份；logind 在
  会话创建时就带 `Class`+`Type`（实测日志：`New session 'c1' ... class 'greeter' and type 'wayland'`、
  `New session '2' ... class 'user' and type 'wayland'`），与旧 `--mode=gdm` 判定等价。
- 验证（实机，boot `12:14` / 12:52）：
  - 新版单独运行：启动即判定当前 `user` 会话 → 收到 `ClaimAccelerometer from :1.84` →
    `SW_TABLET_MODE=ON (accelerometer claimed)`；
  - `busctl emit` 伪造 `SessionNew`/`SessionRemoved` → 日志出现两次 `logind session event`（信号路径通）；
  - 安装后 service：启动 → 30s 兜底 `ON (no claim seen, timeout)` → 随后 Mutter 重新 claim；
  - **CPU 由 ~2.1% 降到 0.0%**（`ps` TIME `00:00:00`）。
- 产物 SHA256 `fb8740e39828f9baf8979732edc509b6de76c126466826feaf2ad73bb82d1a0a`；已用
  `libexec/install-tablet-mode.sh` 安装并重启服务，`nabu-accelerometer/out/` 与
  `nabu-main/artifacts/production-7.2/nabu-tablet-mode` 已同步刷新（三者一致）。
- 待验证：完整开机流程（greeter `Class=greeter` → 用户会话 `Class=user`）需下次重启确认；逻辑上
  与原 `/proc` 路径等价，greeter 同样会拿到 OFF→ON 边沿。

### 2026-09-30 精简 production-7.2 cmdline（去掉 `clk_ignore_unused`/`pd_ignore_unused` 等），已构建安装 `Boot0008`
- 起因：用户反馈耗电偏快。实测亮屏约 2.27 W；待机受两层结构性问题影响：cmdline 的
  `clk_ignore_unused pd_ignore_unused` 让未使用时钟/电源域永不掉电（`clk_summary` 有 117 个
  时钟硬件使能而 `enable_cnt=0`，含整棵 LPASS），以及 s2idle 不可用（见 2.3）。
- 改动（`nabu-main/config/production-7.2.cmdline`，152→87 B；`production.cmdline` 同步）：
  ```
  -root=PARTLABEL=linux rw fw_devlink=permissive modprobe.blacklist=venus_core module_blacklist=venus_core clk_ignore_unused pd_ignore_unused console=tty0 ignore_loglevel
  +root=PARTLABEL=linux rw fw_devlink=permissive module_blacklist=venus_core console=tty0
  ```
  - `modprobe.blacklist=` 内核里根本不存在（只有 `module_blacklist` 是真实 `core_param`，
    `blacklisted()` 在 `load_module` 检查），纯冗余；
  - `ignore_loglevel` 仅调试用，去掉可减少 console 刷屏/关机拖慢；
  - `clk_ignore_unused pd_ignore_unused` 是 9/28 为保开机 console 加的 bring-up 妥协
    （`0c6f95f`/`6735c4e`），去掉后内核会正常关掉未使用时钟/域 → 省电。
- 行为代价：`genpd_power_off_unused()` 会在 ~1.3s 关显示域，而面板是模块、msm ~2.7s 才点屏，
  故 **开机头 ~1.3–2.7s 的 framebuffer console 会黑**（之后正常）。6.14 产品一直不带这两个参数、
  面板 `=m`，功能上安全。
- 构建/安装：`make package`（UKI SHA256 `a7475c476ee769810f800d926a0216e454597766368ef02355a6d00f74b87267`）
  → `sudo make install`，写入 `/boot/efi/EFI/ubuntu/7.2.7-nabu-full-build1.efi`，新 UEFI 项
  `Boot0008 nabu-7.2.7-nabu-full` 置顶；旧 UKI 备份
  `/var/lib/nabu-main/7.2.7-nabu-full-build1.efi.pre-nabu-main`，回退
  `sudo ./scripts/nabu --product production-7.2 rollback`。
- **功耗实测（拔掉适配器）**：亮屏（1023/2047，背景含 opencode ~16–25% CPU）约 **2.38 W**，
  与改动前同亮度 2.27 W 基本持平——亮屏由屏幕主导，本次改动无明显影响；熄屏且显示子系统
  runtime-suspend（`dpms=Off`/`dpu=suspended`/`bl_power=4`）**待机约 1.46 W**（两次一致，窗口内
  CPU 82–92% idle，核心多在 `cpu-sleep-0-0`/`cpu-sleep-1-0` PSCI 深状态）。
  **结论**：cmdline 精简与 unused 时钟/域清理已生效且无副作用，但待机 1.46 W 的瓶颈是
  「没有系统挂起」（2.3）而非 cmdline；按 33.6 Wh 电池粗算待机 ~23h、**约 40%/夜**——这才是
  用户说"耗电快"的主因。
- **已重启验证（boot `12:14`）**：`/proc/cmdline` 为新串；`clk: Disabling unused clocks` +
  `PM: genpd: Disabling unused power domains` 于 1.43s 执行；`pm_genpd_summary` 里
  `venus_gdsc`/`vcodec0_gdsc`/`vcodec1_gdsc`/`gpu_cx_gdsc`/`gpu_gx_gdsc`/camera gdsc 均已 `off-0`
  （原先被 `pd_ignore_unused` 扣着，这是本次主要的省电点）；显示（`msmdrmfb`）、音频（card0）、
  WiFi、四路 remoteproc 均正常。开机 console 只在 1.43s 前后瞬间切到 dummy 再切回，无感。
  **未变（与本次改动无关）**：GPU 地址翻译 fault 风暴（本 boot 27 次：启动 burst + 后台约 30s 一次）；
  `systemd-modules-load` 因 `alsa-base.conf` 的 `install snd` 钩子返回 1 而报 failed（历史 198 次，
  音频仍正常）；固件又把自建 `Boot0008` 从 NVRAM 丢掉（本机已知怪癖；此次经 rEFInd 加载 ESP 上
  已更新的 UKI，cmdline 仍生效）。**待机功耗待拔掉适配器后实测**。
- 未做（后续候选）：`console=tty0` 是否可去（需重启实测）、`module_blacklist` 移到 modprobe.d、
  `fw_devlink=permissive` 的依赖梳理；`nabu-accelerometer/config/production.cmdline` 仍是旧串残留副本。

### 2026-09-30 登录后“短暂错位”：改为事件驱动（sd-bus 监听 `ClaimAccelerometer`），彻底去掉 settle/busctl
- 现象：登录页修复后，登录瞬间有数秒“先横后竖”的错位。
- 测量：`iio-sensor-proxy` 冷启动、驱动枚举完成后，`ClaimAccelerometer` 返回（=首帧就绪）只需
  **~0.1s**；之前 greeter 首帧被 helper 测到要 ~3.8s，是因为 helper 每 200ms `popen(busctl)` 在
  开机繁忙时会长时间阻塞（实测 `busctl` 调用可卡住数十秒）。**所以错位不是传感器慢**，而是
  用户会话用了保守 settle（错位期间 mutter 只用面板 builtin 方向）。
- 最终方案：**事件驱动**。helper 用 `sd_bus_open_system()` 连上系统总线后**显式调用
  `org.freedesktop.DBus.Monitoring.BecomeMonitor`**（root；`sd_bus_set_monitor()` 对已启动的连接会被
  拒，所以像 dbus-monitor 一样直接发起该调用），只匹配
  `type='method_call',destination='net.hadess.SensorProxy',member='ClaimAccelerometer'`。
  Mutter 一 claim 就**立刻** `OFF→ON`，不再有 settle，也不再 spawn `busctl`。
  为什么必须用 monitor：iio-sensor-proxy 的 `PropertiesChanged` 是**单播给 claim 者**的，没有广播事件
  （对比 TouchpadEmulator 用的是 libdbus 查询 + Wayland transform 事件）。
- 状态机：`/proc` 每 200ms 找 `gnome-shell`（greeter/user）→ 变化就把开关切 OFF 并 `waiting`；
  收到**新 sender** 的 `ClaimAccelerometer` → 立刻 ON；无 claim（proxys 缺失）→ 30s 兜底；
  monitor 建立失败 → 每 5s 重试并靠兜底。
- **踩坑（第一次上机无旋转）**：最初给了 5s 兜底。但 **Mutter 的 `ClaimAccelerometer` 在开机时被
  推迟到 shell 起后 ~4–9s**（系统总线/gnome-shell 启动繁忙，`iio_proxy_ready` 回调被拖后），
  5s 兜底先于 claim 触发 → 开关提前 ON → Mutter 在 proxy-ready 时看到 ON → `uninhibit` 先于 claim
  → 永不 claim（`journalctl` 里全是 `(no claim seen, timeout)`，无旋转）。**修法：绝不提前兜底**，
  等真正的 claim 事件；兜底改成 30s（仅在 proxy 缺失时用）。这也说明“claim 前不能 ON”。
- 实测：`systemctl restart nabu-tablet-mode` 后手动 `ClaimAccelerometer` → 日志立即
  `ClaimAccelerometer from :1.x` + `SW_TABLET_MODE=ON (accelerometer claimed)`（unit sandbox 内也通过）。
- 构建：helper 现在链接 `-lsystemd`（`libexec/build-tablet-mode.sh`）；产物 SHA256
  `a715767a02a26260b35a49a4aabd34f0d330a80e378cca6fb9663f283c08d47d`，已安装。
  `/proc` 轮询 200ms（约 2% 单核空闲占用）用于在 claim 之前把开关切 OFF。
- 附带认识：**旋转的真正等待时间是“Mutter claim 的时刻”**，即 shell 起后数秒（当前 ~4–9s），
  与我们的 helper 无关；helper 只能保证在 claim 后立刻 ON。
- **已实机验证（boot `10:00`）**：greeter shell `11.43s` → claim `14.71s`（shell+3.3s）→ 立即 ON；
  用户 shell `40.80s` → claim `43.31s`（shell+2.5s）→ 立即 ON。`PanelOrientationManaged=true`，
  用户确认**自动旋转恢复正常**。日志形如：
  ```
  ClaimAccelerometer from :1.40
  SW_TABLET_MODE=ON (accelerometer claimed)
  ```
- 结论：claim 距 shell 起约 **2.5–3.3s**（这就是旋转开始前的固有等待）；helper 在 claim 后**立即**
  ON，不再有额外 settle。

### 2026-09-29 GNOME 登录页不自动旋转：不是传感器慢，是 `nabu-tablet-mode` 在整个 greeter 期间把 `SW_TABLET_MODE` 关着
- 现象（用户）：登录页（GDM greeter）不随方向自动旋转，怀疑“传感器驱动加载过慢”。
- 实测（本 boot，`#83`）**传感器不慢**：`hexagonrpcd` 10.28s、`iio-sensor-proxy` 10.38s 就绪，
  `HasAccelerometer=true`；而 greeter 的 `gnome-shell --mode=gdm` 到 **~12.9s** 才起来
  （`gdm.service` 8.18s，session c1 10.25s）。传感器都在 greeter 之前，排除“加载慢”。
- 根因（Mutter 50.1）：`panel_orientation_managed = touch_mode && has_accelerometer && builtin_monitor`
  （`meta-monitor-manager.c: update_panel_orientation_managed`），而 `touch_mode` 在**存在 tablet
  switch 时完全由 switch 决定**（`meta-seat-impl.c: update_touch_mode`）。`nabu-tablet-mode` 此前
  刻意把 greeter 排除（`--mode=gdm` 直接跳过）并始终保持 `SW_TABLET_MODE=OFF`，直到**用户会话**
  出现后 5s 才 ON。于是 greeter 期间 `touch_mode=false` → `PanelOrientationManaged=false` →
  登录页永不旋转（用户会话因为之后拿到 OFF→ON 边沿，所以登录后正常）。
- 另一层：本机面板 preferred mode 是 **2560x1600（横屏）**，Mutter 的
  `handle_initial_orientation_change()`“原生竖屏”特例不成立，首个方向事件被忽略并
  `inhibit_tracking()`；所以**必须**有一次 `OFF→ON` 边沿才能开启连续方向跟踪。
- 修复（`nabu-accelerometer`，userspace helper）：`current_shell_state()` 区分
  `SHELL_NONE/SHELL_GREETER/SHELL_USER`，greeter 也纳入；当活动 shell 类型变化
  （greeter→用户会话）时**重置回 OFF**，保证每个 Mutter 实例都有自己的 `OFF→ON` 边沿，且不会把
  greeter 的 ON 状态泄漏给新起的用户 Mutter。
- 为什么不能“开机就 ON”：Mutter 若在启动时就看到 tablet switch = ON，`update_panel_orientation_managed()`
  会在**尚未 claim 传感器**时就走到 `uninhibit_tracking()`，把内部 `inhibited_count` 置成 -1；
  随后 `sync_accelerometer_claimed()` 因 `!= 0` 被跳过 → 该 Mutter 永不 claim → 永不旋转
  （`meta-orientation-manager.c`）。所以必须先 OFF 让 Mutter claim，再 ON。旧代码用固定 5s 纯属保守。
- 改为**信号驱动**：`iio-sensor-proxy` 在无客户端 claim 时 `AccelerometerOrientation` 恒为
  `"undefined"`，而 `ClaimAccelerometer` 的调用**要等第一帧读数算完才返回**（`iio-sensor-proxy.c`
  `handle_driver_method_call`）。所以 helper 轮询该属性（`busctl --system get-property`，systemd 自带），
  一旦从 `undefined` 变成真实方向，说明 greeter 的 Mutter 已消费首帧，立即 ON（`加速计首帧` 路径，
  ~1 tick）；属性一开始就非 `undefined` 的会话（登录后的用户会话，`previous_orientation` 在 release
  时**不重置**）仍走原 5s 保守 settle。busctl 失败/设备平放→5s 超时兜底，行为不劣于旧版。
  `libexec/install-tablet-mode.sh` 的提示文案同步更新。
- 产物/安装：`nabu-accelerometer/out/nabu-tablet-mode` 与
  `nabu-main/artifacts/production-7.2/nabu-tablet-mode` 已更新
  （SHA256 `6aacf8dde52d9e4e93f0ec086f648bdd64b2f81f4869fc0dd91e3a965a14b5d5`），已安装到
  `/usr/local/libexec/nabu-tablet-mode`。日志会区分路径：首帧触发为
  `SW_TABLET_MODE=ON (after first accelerometer reading)`，兜底为 `(settle timeout)`。
- 验证（上一版实机）：boot 时序 —— helper `OFF 7.84s → ON 16.39s`（greeter 的
  `gnome-shell --mode=gdm` 约 11.3s 起，+5s）`→ OFF 26.69s`（检测到用户会话，重置）
  `→ ON 31.64s`（用户会话）。即 **greeter 运行期间开关确实被置 ON**，正是缺少的那次 `OFF→ON`
  边沿。旁证：greeter 的 `gnome-shell[1351]` 在 `26.346s` 报
  `Failed to release accelerometer: Not Authorized: Sensor claim not allowed`——说明该 greeter 的
  Mutter 确实 claim 过加速度计（方向管理生效）。
- 顺带发现（独立问题，未修）：`systemctl restart iio-sensor-proxy` 之后，已存在的 Mutter
  **不会重新 claim** 加速度计（`HasAccelerometer=true` 但 `AccelerometerOrientation/Tilt` 一直
  `undefined`），即运行中重启传感器代理会丢掉本次会话的旋转，需重新登录/重启。与本条无关，仅记录。
- 另：上一 boot 的 GPU fault/DPU recover（15.2s，`offending task: gnome-shell --mode=gdm`）
  是既有问题，与本条无关。
- **待验证**：新“首帧信号”路径需下次重启确认（登录页应在首帧后立即跟随方向；日志里
  `SW_TABLET_MODE=ON` 应紧跟在 greeter 首帧之后，而不是固定 5s）。
- **2026-09-30 重启验证通过**：boot `08:39` 实测 —— helper `OFF 8.85s → ON 16.36s
  (after first accelerometer reading)`（greeter 的 shell 刚起 ~0.15s），再 `OFF 24.20s → ON
  29.14s`（用户会话）。即 **登录页确实在首帧后立即拿到 `OFF→ON` 边沿**。用户实测“登录前方向 OK”。
- 用户会话跟踪实测（转动平板逐方向）：`normal→transform90(横) / bottom-up→270(倒横) /
  right-up→0(竖) / left-up→180(竖)`，即 `final = 面板 builtin(90) + orientation`，
  与 `meta_orientation_to_transform` 完全一致；`xrandr` 显示当前 logical 2560x1600（横）。
  **说明 mount matrix 与面板 builtin 均正确，mutter 也在持续跟踪（并非“卡在竖向”）。**
- 备注（方向/mount matrix **不是**问题）：用户实测确认 `ACCEL_MOUNT_MATRIX=-1,0,0;0,-1,0;0,0,1`
  **正确**（手持实测：自然横屏原始 `Y≈-10`、竖屏 `X≈+9.5`、屏幕朝上 `Z≈+9.9`，与 udev 矩阵相符），
  传感器方向无需改动；TouchpadEmulator 仅作为“开机初期读数无效”的参考。本条只修登录页时序。

### 2026-09-29 内建（`=y`）首屏黑屏**已解决并验证**：根因是 **DPU 的遗留状态**，在 DPU init 时给显示断电重来（`0502f05d50fc`；构建 `#83` 验证，`#84` 去掉诊断）
- **结论（用户实测：连重启 10+ 次，0 次黑屏）**：稳定。
- **机制（关键，且与前面判断相反）**：加了 `DSI{n} pre-on: …` 直读后发现——
  **即使加了 DPU 电源循环，power_on 时 DSI 仍是 `ctrl=0x77 status0=0x8`（遗留的"活"状态）**，
  但屏幕已稳定点亮。→ 说明**让面板首帧不 latch 的根因在 DPU，不在 DSI**；
  DSI 的 `ctrl=0x77` 本身无害（`dsi_ctrl_disable`+`dsi_sw_reset`+`dsi_ctrl_enable` 会正确重配它）。
- 因此：`=m` 之所以稳，是内核 late init 把**整条显示（含 DPU）**断电一次；只清 INTF（早关）不够，
  只对 DSI 做 runtime PM 更不够（塌不了域）。**必须让 DPU 复位**。
- 修法（`0502f05d50fc`）：`dpu_kms_hw_init()` 取到 runtime-PM 引用后立刻
  `pm_runtime_put_sync()`（挂起 → mdss 域断电 → DPU 复位）→ `msleep(50)` →
  `pm_runtime_resume_and_get()`。发生在 KMS init、**任何 modeset 之前**，所以不会引发
  之前在 modeset 中途断电造成的 `-110` / 双 DSI 半屏错位。
- 前面两版（`6ed414722cb3`、`66e6dc73936e`，`#80`/`#81`）方向错了（只动 DSI），已由本版取代；
  `#81` 那 3s 空等也一并去掉。
- 诊断用的 `DSI{n} pre-on: …` 打印在 `#84`（`683745b5cf03`）移除——它的结论（冷启动后 DSI
  仍为 `ctrl=0x77`、而屏幕稳定）已记在本条。
- 仍未解决（与本条无关，另案）：GPU 地址翻译 fault 风暴（偶发冻屏）；19:40 那次"卡死"实为
  **面板没 latch（黑屏）+ WiFi 未就绪（SSH 连不上）**，内核/用户态都没死（详见下方时间线）。

### 2026-09-29 内建（`=y`）首屏可靠化（第 3 版）：改为在 **DPU init** 时给显示断电重来（`0502f05d50fc`，构建 `#83`，待重启多次验证）
- 第 1/2 版（`#80`/`#81`）都**无效**：实测每次开机都 `DSI0 still enabled after 3s (ctrl=0x77)`
  —— **只对 DSI 做 runtime PM 塌不了 mdss 电源域**，反而把首次点屏推迟 3s（黑窗更长）。已移除。
- 关键认识：KMS init 期间**真正占着 mdss 电源域的是 DPU**（`dpu_kms_hw_init()` 一开始就
  `pm_runtime_resume_and_get()`）。所以改在 `dpu_kms_hw_init()` 里、取到引用后立刻
  `pm_runtime_put_sync()`（suspend → mdss 域断电 → **DPU 与 DSI 一起复位**）→ `msleep(50)` →
  `pm_runtime_resume_and_get()` 重新上电。由于这发生在 **任何 modeset 之前**，不会碰到之前
  中途断电导致的"面板 init -110 / 双 DSI 半屏错位"。
- 另加一行诊断：`DSI{n} pre-on: ctrl=… status0=… fifo=…`（power_on 时打印），
  用来直接判定是否真的冷启动：冷 = `ctrl=0x0`，仍旧残 = `ctrl=0x77`。
- 判据：每次开机日志里 `pre-on` 应为 `ctrl=0x0 status0=0x0 fifo=0x11111010`，且多次重启都亮。

### 2026-09-29 "重启后卡死"复核：不是内核卡死，是**首屏没 latch（黑屏）+ WiFi 未就绪（SSH 连不上）**
- 用户报告 19:40 左右一次"启动卡死、SSH 连不上、屏幕黑"。查 `journalctl`（boot `-1`，`#81`）：
  - **系统一直活着**：全量日志无 >2s 间隔、无 panic/oops/BUG/hung-task、`pstore` 空；
    正常到 `network.target`/`multi-user.target`/`graphical.target` 与图形会话；关机**干净走完**。
  - **SSH 连不上 = 没 IP**：`ssh.socket` 19:40:08 已在听，但 `wld0` 到 19:40:16 还只是
    `disconnected`/刚开始关联，**到关机都没 `ip-config`/`activated`**。对照当前 boot：
    `wld0` **~24s** 才 `activated`、`ssh.service` **25.6s** 才起。用户在 ~21s 就去连，自然连不上。
  - **屏幕黑 = 面板没 latch**（就是上面那条的偶发问题；该 boot 日志里也有
    `DSI0 still enabled after 3s`，说明 `#81` 的强制冷启动没生效）。
- 另有真实存在的**独立**问题：GPU 地址翻译 fault 风暴（如 boot `-18` 150s 起一串、boot `-10`
  25s 起对同一 IOVA `0x107ad0000` 连刷 10+ 次且不再恢复 → 会冻住合成器）。
  见 `port-7.2.7.md` 9/24 的 GPU fault 条目（7.2 msm GPUVM 大改，未解）。

### 2026-09-29 内建（`=y`）首屏可靠化（第 2 版）：改为显式强制"冷启动"（`66e6dc73936e`，构建 `#81`，**待重启多次验证**）
- 第 1 版（`6ed414722cb3`，`#80`）"**等**内核把显示断电"实测**不成立**：日志 `DSI0 still enabled after 3s (ctrl=0x77)`
  —— `=y` 下那个时刻没有任何东西会断电（cmdline 有 `clk_ignore_unused pd_ignore_unused`，clk/genpd 清理被跳过），
  白等最多 3s，反而把黑窗拉长（`#80` 比 `#75` 差）。
- 第 2 版：不改"等"，改"**强制**"。`dsi_bind()` 里若发现控制器仍 enabled（bootloader 遗留），
  对 DSI host 做一次**配平的 runtime-PM `get_sync`+`sleep(20)`+`put_sync`**，促使 **mdss 电源域塌一次**
  → 随后的 bring-up 从确定性冷状态开始（就是模块面板拿到的那个状态）。之后仍以 100ms 步进、
  最多 3s 轮询 `REG_DSI_CTRL.ENABLE` 并打印 `DSI0 cold after N ms` / `still enabled after 3s` 作为判据。
- 为什么只能走 runtime PM：这颗 SoC 的 DSI **没有 `resets` 属性**（无复位线可断言），
  `refgen-supply` 是**共享**参考（不能 force-off），`power-domains` 是共享的 `MMCX`，
  唯一属于显示子系统的可关闭单元就是 mdss GDSC（由显示设备的 runtime PM 驱动）。
- 判据/预期：日志出现 `DSI0 cold after 0 ms`（说明塌域成功）且多次重启都能亮；
  若仍 `still enabled after 3s`，说明单靠 DSI 的 runtime PM 塌不了域，下一步要把 DPU 设备的 runtime PM 一起循环。

### 2026-09-29 内建（`=y`）首屏可靠化：首个 bring-up 前等 DSI 变"冷"（`6ed414722cb3`，构建 `#80`，已被上一条取代）
- 思路：首屏失败不是配置问题（黑/亮在寄存器层一致），而是**首屏是在 bootloader 遗留的"活"状态上重配**；
  `=m` 稳是因为内核 late init（~1.3s）先把显示断电，msm 拿到的是**冷控制器**。
- 处置（`linux-7.2` `6ed414722cb3`）：`dsi_bind()` 里在首个 modeset 之前，
  `msm_dsi_host_wait_for_cold()` 以 100ms 步进、最多 3s 等 `REG_DSI_CTRL` 的 `ENABLE` 位清 0 再继续。
  这样内建面板也能拿到和模块面板一样的确定性冷启动状态。等待期间**不占用**任何时钟/电源引用，
  所以内核自己的 unused-power 清理仍能正常断电。
- 顺带清理：`方案 1` 留下的两个编译告警（`dsi_mgr_bridge_pre_enable()` 未用局部变量、
  `dsi_mgr_bridge_power_off()` 无调用者）——删局部变量 + 给函数加 `__maybe_unused`。
- 诊断价值：日志里会打印 `DSI0 cold after N ms`（或 `still enabled after 3s`），可确认清理是否发生。
- 预期：`=y` 下首屏稳定点亮（bring-up 落到 ~1.5s，仍早于 `=m` 的 ~2.7s）。

### 2026-09-29 内建（`=y`）首屏偶发黑屏：试过"整屏 re-init 自愈"，**因触发双 DSI scanout fault 已回退**（`660ae9c3a31c` → revert `6b6433f4c8d0`，构建 `#78`）
- 现象（用户）：`=y` 下**偶尔**开机黑屏；**按电源键唤醒（或息屏再唤醒）必定点亮**。
- 现场（同一次黑屏 boot，直接读寄存器）：DSI `CTRL=0x173`、`STATUS0=0x8`（video 引擎在跑）、
  `FIFO_STATUS=0x10001010`（干净）、DRM `crtc-0 active=1 1600x2560@120`、connector `dpms=On`、
  背光 `brightness=628 bl_power=0`；**`dsi_err_worker` / `-110` 都是 0**。
  → 这层**不是**下面那条修的"bootloader 残留"（那层症状已消失），而是**面板首帧没有 latch**；
  面板驱动自己就写着 *"until the dual-DSI scanout fault is resolved"*。
- 尝试（已回退）：在首个打开 CRTC 的 commit 之后 1.5s，调度一次性工作做
  `drm_atomic_helper_suspend()` → `msleep(120)` → `drm_atomic_helper_resume()`（等价于唤醒时的显示 off/on）。
  - 实测自愈**确实执行了**（`synchronized pen scan rate` 出现 2 次、无 re-init 报错），
    但屏幕变成 **下半部分亮横条、上半部分不亮** —— 即踩中了这颗双 DSI 面板的
    scanout fault（半屏错位）。
  - 结论：**在 boot 早期用整屏 modeset 自愈不适用于 bonded 双 DSI**。已 `git revert`，
    回到 `#78`（= `#75` 行为，无自愈）。
- 若还要继续追，方向应是**让首屏 bring-up 本身可靠**（而不是事后重来）：
  - 首屏与"唤醒后"的差异在"显示域/PHY 是否先被真正断电"；`=m` 之所以稳，就是内核 late init
    自己先把显示断电了一次（见上一条）。
  - 候选：在 **probe 阶段**（任何 modeset 之前）做一次真正的显示/DPU/PHY 电源循环，或让
    首屏 bring-up 延后到内核自身的 unused-power 清理之后（就是 `=m` 的做法，代价 ~2.7s 黑窗）。
- 现场对比（黑 vs 亮）在寄存器层完全一致，说明问题在面板 latch/双 DSI 时序，不在 DSI/DPU 配置。

### 2026-09-29 内建（`=y`）早期点屏点亮：根因是 bootloader 遗留的 DPU INTF 还在喂 DSI，改成"编码器创建时就关掉"（`946ad42c1646` + `bab7fee`）
- **目标达成**：面板内建（`=y`）、msm 早期点屏，开机日志连续（上一条记录的黑屏已解决）。
  构建 `#75`，装 `EFI/ubuntu/7.2.7-nabu-full-build1.efi`（`Boot0008 nabu-7.2.7`）。
- **根因（实机寄存器探针对比）**：
  - bootloader（UEFI/rEFInd）把整条显示流水线留在运行态：DSI `REG_DSI_CTRL=0x77`
    （`ENABLE|VID_MODE_EN|CMD_MODE_EN|LANEn`）、`STATUS0=0x8`（`VIDEO_MODE_ENGINE_BUSY`），
    并且 **DPU 的 `INTF_TIMING_ENGINE_EN=1`，仍在往 DSI 送流**。
  - `=y` 时 msm 在 ~0.93s 就接管，那时 bootloader 引擎还在跑（实测它在 3s+ 内**自己不会停**）；
    `=m` 到 ~3.1s 时已是 `REG_DSI_CTRL=0x0`、`fifo=0x11111010`——是内核 late init 的
    "unused regulator/power domain" 清理在 ~1.3s 先把显示断电一次，msm 才拿到干净状态。
  - 早期接管有两层后果：
    1. **面板 init 命令 DMA 超时 `-110`**（`dsi_cmds2buf_tx: cmd dma tx failed … ret=-110`，报在从机
       `ae96000.dsi.0`）：面板 init 的 DCS 由 `mipi_dsi_dual_dcs_write_seq_multi` 同时发给 DSI0/DSI1，
       遗留 DPU 流把命令引擎挡住；
    2. 编好时序后 **DSI 输入 FIFO 持续溢出+欠载**：`FIFO_STATUS=0x15551019`
       （`VIDEO_MDP_FIFO_OVERFLOW|UNDERFLOW`），`dsi_err_worker: status=4`，面板黑。
- **修法（`linux-7.2` `946ad42c1646`）**：把 INTF timing engine 在**编码器创建时**就先关掉（远早于任何 modeset）：
  - `dpu_encoder_phys_vid_init()`：`p->hw_intf->ops.enable_timing(p->hw_intf, 0)`；
  - `dpu_encoder_phys_vid_enable()`：重编时序前再 `enable_timing(…, 0)`（防御）。
  实测：`init` 后 INTF `en=0`；`host_enable` 时 `status0=0x0 fifo=0x11111010`（干净，不再溢出/欠载）；
  面板 init 成功（`synchronized pen scan rate for 120 Hz`）、`msmdrmfb` 起来，**屏幕亮、日志连续**。
- 同轮保留的 **方案 1**（`dsi_manager.c`：`msm_dsi_host_enable()` 从 DSI bridge `pre_enable` 挪到
  `enable`，让面板 init 先于视频使能）随本次一并提交（`946ad42c1646`）。
- **面板/背光改回内建**（`nabu-display` `bab7fee`）：`CONFIG_DRM_PANEL_NOVATEK_NT36523=y`、
  `CONFIG_BACKLIGHT_KTZ8866=y`，删 `config/nabu-display.conf`（modules-load）与 `nabu-module.toml`
  里的 `.ko` build/artifacts/install 段。之前"面板必须是模块"的结论，只在 bootloader 残留未清时才成立。
- **走过的弯路（勿重复）**：
  - 在 `power_on` 里**轮询等** bootloader 引擎自己停：`=y` 下 `ctrl=0x77` **一直不停**（>3s），无效。
  - 只在 `msm_dsi_host_power_on` 路径做**整体电源循环**（`power_off`+`msm_dsi_phy_disable`+sleep+重启）：
    **确实消掉了 `status=4`/FIFO 欠载**，但把**面板 init 打成 -110**、屏幕仍黑。
  - 先循环 DSI、再在 `dpu_encoder_phys_vid_init` 补"INTF 早关"（`#73`）：`host_enable` 的 FIFO 已干净，
    证明 **INTF 早关才是关键**；去掉电源循环后（`#74`/`#75`）面板 init 也恢复。
  - `devmem` 读 DPU INTF（`0xae06c000` 等）被 `CONFIG_STRICT_DEVMEM` 拦（`mmap: Operation not permitted`），
    DSI 段（`0xae94000`）可读——INTF 只能用内核探针。
  - 排障提示：`dmesg` 环形缓冲会被刷掉，用 `journalctl -k -b 0`；`uname -v` 的 `#NN`/构建时间可确认
    实际启动的是哪一版内核（本次曾误判一次）。
- 备注：`=y` 下 GPU 固件 `a630_sqe.fw` 仍要等 rootfs（~12.9s）才加载，GNOME 首次提交会触发一次
  `hangcheck recover`（6.14 同样如此），与显示点亮无关。

### 2026-09-29 深挖内建（`=y`）早期点屏黑屏：定位到 bootloader DSI 引擎残留，未能压住，已回退 `=m`
- 目标：让面板内建（`=y`）、msm 早期点屏，做到启动日志连续（见下条）。用**探针**（`PROBE ...`）逐项实测。
- **有效改动（方案 1，保留价值）**：把 DSI 视频使能 `msm_dsi_host_enable()` 从 DSI bridge
  `pre_enable` 挪到 `enable`（在 DPU encoder `atomic_enable` 之后）。这样面板 init（`prepare`，DCS）
  在视频使能之前完成，消除 `ff 10/-110` 与 `sync_pen_fps` 超时。**实测 `=m` + 方案 1 屏幕正常点亮**，
  证明方案 1 本身没问题（此前 #24 方案 1 失败是因为当时 `dsi_ctrl_disable` 修复还没落库）。
- **`=y` 仍黑的决定性现场**（同一探针，`=y` vs `=m` 对比）：

  | | `power_on` 前 `DSI_CTRL`/`STATUS0` | `host_enable`（视频使能）时 `FIFO_STATUS` | 结果 |
  |---|---|---|---|
  | `=y`（msm @1.2s） | `0x77` / `0x8`（bootloader 视频引擎仍在跑） | `0x19991018`（`VIDEO_MDP_FIFO_UNDERFLOW`） | 黑 |
  | `=m`（msm @3.7s） | `0x0` / `0x0`（bootloader 引擎已自停） | `0x11111010`（干净） | 亮 |

  即 **`=y` 时内核在 bootloader DSI 视频引擎还没停时就接管**，`dsi_ctrl_disable`+`dsi_sw_reset` 清不彻底 →
  DSI 视频 FIFO 欠载 → 面板收不到正确数据 → 黑。
- 已尝试但**无效**：
  1. reset 后**轮询等 `VIDEO_MODE_ENGINE_BUSY` 清 0 + 清 FIFO**：post-reset 确实干净
     （`status0=0x0 fifo=0x11111010`），但 `host_enable` 时 FIFO 又欠载（`0x19991018`）。
  2. `dpu_core_perf.c` 的 `clk_rate==0` 提前返回（7.2 上游 `54b17a858b8b`，6.14/7.2.2 没有）：
     实测 `clk_rate=556012800`（非 0），`dev_pm_opp_set_rate` 正常调用 —— **不是它**。
  3. 方案 1 本身：`=m` + 方案 1 正常点亮 —— **不是它**。
  4. GPU 固件：内建使 msm 提前到 rootfs 之前，`a630_sqe.fw` 首次加载失败、12.6s 重试成功；
     但 **6.14 同样如此且显示正常** —— 不是它。
  5. **`=y` 去掉 `clk_ignore_unused`/`pd_ignore_unused`**（让内核尽早关掉 bootloader 显示时钟/域）：
     `power_on` 前引擎**仍在跑**（`ctrl=0x77 status0=0x8`）；内核 `genpd: Disabling unused power domains`
     在 1.3s、**晚于** msm 点屏（~0.9s），没帮上。
  6. **首次 power_on 前 `msleep(500)`**：引擎仍在跑，且 `host_enable` 后 `status=4` 连续刷十几次，更差。
  7. **首次 power_on 多做一次 `disable/reset/enable` 循环**（模拟 #19 的"第二次 bring-up 干净"）：
     `status=4` 依旧、黑屏。
  8. **用 6.14 的老 DSI PHY**（把 6.14 的 `dsi_phy_7nm.c`/`dsi_phy.c` 覆盖进 7.2，适配
     `round_rate→determine_rate`、补回 `struct msm_dsi_phy.ahb_clk`）：**有部分效果**——
     `host_enable` 时 FIFO 变干净（`0x11111010`，bit3 初始欠载消失），证明 7.2 PHY 是初始欠载的原因之一；
     但**视频开始后 `status=4` 仍刷十几次、屏幕仍黑**（流式欠载），说明还有第二层不在 PHY。
  9. **整套 6.14 老 DSI 驱动覆盖**（`dsi_host.c`/`dsi_manager.c`/`dsi_cfg.c`/`dsi.c` + PHY 整套；
     适配了 `msm_gem_address_space`→`drm_gpuvm`、`devm_drm_bridge_add`→`alloc`、bridge
     `attach` 新签名（多 `encoder` 参数）、`priv->dsi[]`→`priv->kms->dsi[]`、
     `round_rate`→`determine_rate`、补 `ahb_clk`，并把 7.2 的 seamless DFPS 做成 stub）——
     **编译通过、能启动**：面板 init 成功（`synchronized pen scan rate`）、`host_enable`
     初始 FIFO 干净（`0x11111010`）、`msmdrmfb` 也起来了；但 **`dsi_err_worker: status=4`
     流式欠载依旧（×10+）**，屏幕花/冻（用户手动 `systemd-reboot`，日志无内核 hang）。
     → **决定性结论：根因不在 DSI 驱动**（6.14 老驱动和 7.2 新驱动表现一样），
     而在 **7.2 的 DPU/时钟/互联链路**（早期点屏时 DPU→DSI 供数欠载；`=m` 到 ~3.7s 时正常）。
  10. **DPU 带宽探针**（`=y`+方案1，`_dpu_core_perf_crtc_update_bus`/`dpu_hw_intf`/`post_kickoff`/bridge enable）：
      现场显示 **起始 commit 时 DPU 带宽投票 `avg_bw=0`**，DSI 视频使能后才 ~2ms 涨到 `1270886 B/s`
      （`PROBE dpu bw: crtc=92 avg_bw=0` → `...dpu bw: crtc=92 avg_bw=1270886`）；期间 `status=4` ×2。
      `msm_atomic_commit_tail` 顺序与 6.14 一致（disables→planes→enables），但起始 commit 里 plane 的
      `bw_ctl` 还没聚合进 `avg_bw`。**但屏幕仍黑/不可用**（显示链路表象是活的：`msmdrmfb`、DSI-1
      `connected enabled`、gnome-shell 在跑）→ 说明除了这 2ms 欠载，还有面板 latch 一层。
- 结论：`=y` 的黑屏是**早期（~1s）硬件/时序层面**的问题（bootloader 显示状态在 ~1s 与 ~4s 不同），
  纯软件清理（reset/轮询/双复位/延时/去掉 ignore_unused）都压不住，6.14 PHY 也只解决了一层；
  要真正内建点屏需要先搞清「bootloader DSI/DPU 引擎何时/为何停下」以及「1s 时 DPU→DSI 流式欠载」
  （`=m` 到 3.7s 时 `ctrl=0`、无欠载）——值得下一步用寄存器 trace 追。
- 附：6.14↔7.2 的 DSI 差异规模：`dsi_host.c` 541 行、`dsi_phy_7nm.c` 289 行、`dsi_manager.c` 126 行、
  `dsi_cfg.c` 49 行；`dsi.xml`（寄存器）0 行。主要 API 变化：`msm_gem_address_space`→`drm_gpuvm`、
  `devm_drm_bridge_add`→`devm_drm_bridge_alloc`、`clk_ops.round_rate`→`determine_rate`、
  `struct drm_atomic_state`→`struct drm_atomic_commit`、AHB 时钟从 PHY 移到 host。
- **处置：全部回退**。探针 / 方案 1 / 轮询 / core_perf / 延时 / 双复位改动都已 `git checkout` 还原；
  `nabu-display` 恢复 `=m` + `modules_load`；`cmdline` 恢复（保留 `clk_ignore_unused`+`pd_ignore_unused`）；
  删掉 probe UKI 与启动项，重建 `Boot0008 nabu-7.2.7`（指向能用的 `=m` UKI）。
  （注：本机固件 NVRAM 会周期性地丢掉自建的 `Boot##` 项，需要时用 `efibootmgr -c` 重建。）

### 2026-09-28 开机早期屏幕看不到内核日志：试内建 panel（对齐 6.14.11）会复现 #27，已回退到 `=m`
- 现象（用户）：开机先看到"Linux 企鹅 icon"，然后一段黑屏（~2.7s），之后才出现内核日志，且日志不是从 0 开始；
  "正常应该是一个连续的过程"。
- 定位（实机 + ESP 检查）：
  - 那只企鹅是 **rEFInd** 给 Linux 启动项显示的图标（`EFI/BOOT/themes/.../os_linux.png`，`refind.conf` 里
    `use_graphics_for linux`），**不是内核 logo**；即 rEFInd 交接后，内核早期的 framebuffer console 没显示出来。
  - 面板驱动加载的时刻就是显示点亮的时刻——`[2.725s] systemd-modules-load` 载入
    `panel_novatek_nt36523`/`ktz8866` → `[2.738s] msm_dpu: bound ae94000.dsi` → `[2.746s]` dummy →
    `[3.10s]` msmdrmfb。原因：`dsi_bind()` 需要**面板桥（panel bridge）**，而它由面板驱动提供；面板是模块，
    所以 msm 必须等用户态加载面板后才点屏。
- 对照 **6.14.11**：6.14.11 的 `.config` 里 `CONFIG_DRM_PANEL_NOVATEK_NT36523=y`、`CONFIG_BACKLIGHT_KTZ8866=y`
  ——**内建**，面板桥开机即存在，msm 在 kernel init 阶段就点屏，所以 6.14 的启动日志是连续的。
- 尝试（`nabu-display` `cdc2610`）：照 6.14.11 把 7.2.7 也改成 `=y`，重编 `#44` 并装机、重启实测。
  **结果：屏幕点不亮**——`#44` 每次启动都刷 `dsi_err_worker: status=4` 十几次，面板 init 失败；
  对照同一台机器的 `#43`（面板 `=m`）**0 次** `status=4` 且面板正常。
  即 #27 记录的问题在 7.2.7 上依然存在：**内建时面板在"第一次 DSI power-on（控制器仍带 bootloader 的
  video-mode 状态）"就 probe，7.2 的 DSI bring-up 会出错**；`dsi_ctrl_disable` 修复只解决了 `ff 10` 超时，
  没有解决这里的 `status=4`。6.14.11 没有这个问题，所以它能内建。
- 回退（`nabu-display` `b20d049`，已重编 `#45` 并 `make install`）：`=m` + `modules_load`
  （`/etc/modules-load.d/nabu-display.conf`）——面板/背光保持模块、由 systemd-modules-load 在 ~2.7s 加载，
  保证面板 bring-up 干净。
- 保留 cmdline 的 `clk_ignore_unused`+`pd_ignore_unused`（`nabu-main` `6735c4e`/`0c6f95f`）：已把 msm
  bring-up 从 ~6.3s 提前到 ~2.7s。
- 结论/待办：**7.2.7 上无法像 6.14.11 那样内建面板**；要做成"从 0s 连续"必须先修掉 7.2 DSI 在
  第一次 power-on / 早期 modeset 的 `status=4`（FIFO 欠载）问题，或让 bootloader 交接时保持面板点亮。

### 2026-09-28 电量计重启掉电 10%：profile 一致时不再重启 SOC（`36064cebda8a`，待重启验证）
- 现象（用户）：电量计不准，**重启一次掉 ~10%**。
- 根因：`qcom_fg` 每次启动都强制写 profile + `qcom_fg_gen4_restart()` 重启 SOC 算法；重启后
  电量计按"松弛后的开路电压"重新估 SOC，于是从充电时的 100%（端电压被 IR 抬高）掉到 ~90%。
  厂商 FG 有 `is_profile_load_required()`：读 SRAM `PROFILE_INTEGRITY`，若 `PROFILE_LOAD` 已置位
  且已存 profile 与 DT 一致，则**跳过加载与重启**，从而跨（热）重启保住 SOC。
- 处置（`qcom_fg.c`）：新增 `qcom_fg_gen4_profile_load_required()`，在写 profile 前先读
  `PROFILE_INTEGRITY_WORD`(299) 与 `PROFILE_LOAD_WORD`(65) 比对；一致则打印
  "battery profile unchanged, keeping gauge SOC" 并直接返回，不再重启算法。冷启动/换 profile 仍会重载。

### 2026-09-28 电量计 100% 对齐浮充点：qcom_fg 写厂商 `VBATT_FULL`（`0bcdc37f69a9`，待重启验证）
- 背景：要让电量计 100% 正好落在充电 CC-CV 满点（和 Android/厂商一致），需要在 SRAM 里写
  `qcom,fg-cc-cv-threshold-mv`（厂商对应 `VBATT_FULL`，SRAM word 23，15-bit 电压编码）。
- 处置：
  - `qcom_fg.c`：新增 `VBATT_FULL_WORD=23`，在 `qcom_fg_gen4_write_params()` 读取
    `qcom,fg-cc-cv-threshold-mv`（默认 4450mV），用与 `CUTOFF_VOLT` 相同的电压编码写入
    `VBATT_FULL`；`gen4` 的 profile/参数写入路径一并生效。
  - `sm8150-xiaomi-nabu-power.dtsi`：`&pm8150b_fg` 补 `qcom,fg-cc-cv-threshold-mv = <4450>;`
    `qcom,fg-ffc-cc-cv-threshold-mv = <4480>;`（取自厂商 K82 profile）。
- 预期：重启后电量计 100% 与 SMB5 的 CV 满点对齐（不再明显提前/滞后）。

### 2026-09-28 充电缓降向 Android 对齐：按厂商 FFC 终止电流判满（`122924498679`，待重启验证）
- 反馈（用户）：缓降时间偏短；希望和 Android 一致。
- 处置：
  - `qcom_pmi8998_charger.c`：**去掉"电压到浮充附近就判满"的提前触发**，改为只在
    `容量≥100% 且电流缓降到 ~1.3A`（对齐厂商 `qcom,ffc-*-term-current-ma ≈ -1278/-1363mA`）时
    才锁存 Full 并停充；≤98% 恢复。这样 CV 缓降段不再被截断。
  - `ln8000_charger.c`：泵退场门限 `4350mV → 4400mV`，让泵在恒流段多做一点、
    更接近厂商"泵管大电流、SMB5 管 CV/终止"的分工。
- 对照 Android：厂商是 FFC 到 4.48V、CV 缓降、按 ~1.3A 终止；我们受 A-to-C/硬件上限，
  FCC 是 3A（非 5.9A），但"CC→CV→按终止电流判满"的过程一致。
- 备注：要让电量计 100% 精确对齐浮充点，还需给 `qcom_fg` 补厂商的
  `qcom,fg-cc-cv-threshold-mv`（4450/4480）写入（`VBATT_FULL`），属后续可选项。

### 2026-09-28 满电充电行为：保留 CC→CV 缓降（`429004f6a979`，待重启验证）
- 反馈（用户）：正常应是"恒流满功率→到一定程度恒压缓降"，不是一路 3A 到 100% 突然停。
- 细化（接上一条 `2ade714095c0`）：
  - `ln8000_charger.c`：泵不再只按"容量 100%"停，而是**电池电压接近浮充（`vbat ≥ 4350mV`）或容量≥100%**
    时停泵退场，让 SMB5 独自走 CV；`full_stopped` 在容量≤92% 或拔线时清除；
  - `qcom_pmi8998_charger.c`：软件判满改为 `容量≥100% 且（电流<1A 或 电池已达浮充-30mV）`，
    即**等 CV 电流真的缓降下来**才锁存 FULL 并 inhibit；≤98% 恢复。
- 预期：满电前一段电流会从 ~3A 逐步下降（SMB5 CV），功率随之下降，缓降到门限后才停。

### 2026-09-28 A-to-C 满电不停充（输入仍 ~16W）：到 100% 停充/停泵，≤98% 恢复（待重启验证）
- 现象（用户）：满电后输入功率仍 ~16W。
- 根因：**电量计把 100% 报早**（拔掉后 `voltage_now≈4.26V`，OCV≈4.28V，对 4.48V 电池约 90%），
  而 LN8000 泵把充电电流顶在 ~3A，SMB5 的软件充满判据（`容量≥100% 且电流<400mA`）永不满足，
  于是持续以 ~16W 充电、`STATUS` 一直是 Charging。
- 处置（`linux-7.2` `2ade714095c0`）：
  - `qcom_pmi8998_charger.c`：软件满电状态改为按**容量**锁存（≥100% 锁存、≤98% 清除），
    锁存期间 inhibit 充电（`CHARGING_ENABLE_CMD=0`）并上报 FULL；
  - `ln8000_charger.c`：新增 `full_stopped`，按容量（≥100% 停、≤98% 恢复）停/启电荷泵，
    并在 thermal/notifier 路径同样受限；
  - 泵 1s 轮询先停，SMB5 15s 轮询后 inhibit；VBUS 仍在供系统，只是电池充电停止。
- 备注：这是按"显示 100% 即停"的行为修复；要真正做到"物理满充再停"需校准电量计满点
  （厂商用 `qcom,fg-cc-cv-threshold-mv`/`VBATT_FULL`，我们的 `qcom_fg` 尚未写该参数）。
- 顺带：为排查 PD 给内核加了 `CONFIG_DYNAMIC_DEBUG`（`nabu-power/config`）。已确认用户的
  xiaomi MDY-08-ES 是 **USB-A QC3 18W** 头，配 A-to-C 无 PD（PD 需 C-to-C + PD 源）。

### 2026-09-28 厂商 SMB5/PD 充电栈对齐：尝试后已回滚（见 tag `archive/vendor-smb5-port`）
- 已把厂商 `drivers/power/supply/qcom/*`、`drivers/usb/pd/*`、`class-dual-role`、`pmic-voter`/`of_batterydata`/`qpnp-revid` 及 DTS 切换全部回退；尝试版本留在 tag `archive/vendor-smb5-port`。
- 回滚原因：厂商栈在 nabu（仅移植充电栈、缺厂商 qg/typec 对接）上 probe 崩溃/卡死，导致无法启动。

### 2026-09-28 PD 充电不通：补 `vdd-pdphy-supply`（PM8150 LDO2），待重启验证
- 现象（用户）：PD 充电。实测：端口 PD 能力正常（`usb_power_delivery_revision=3.0`、sink PDO
  5V+9V、27W、`vdd-pdphy` 硬件在 0x1700），但**接上 PD 源后没做 PD 发现**：`tcpm-source-psy`
  `VOLTAGE_MAX/MIN=5V`、`CURRENT_MAX=0`，partner `usb_power_delivery_revision=0.0`、
  `supports_usb_power_delivery=no`、无 source PDO；只按 5V DCP 充（`pm8150b-charger` `[DCP]`，
  电池 ~600mA）。
- 根因：`&pm8150b_typec` **没设 `vdd-pdphy-supply`**。`qcom_pmic_typec` 的 PD PHY 驱动会
  `regulator_enable(vdd_pdphy)`，但没有 supply 时用的是 dummy → **PM8150 LDO2 从没上电** →
  PD PHY 没供电 → PD 收发失败 → 回落到 5V DCP。厂商 DT 用 `pm8150_l2` 供 PD PHY。
- 修复（`linux-7.2` 见提交）：`sm8150-xiaomi-nabu-power.dtsi` 给 `&pm8150b_typec` 加
  `vdd-pdphy-supply = <&vreg_l2a_3p1>;`（PM8150 LDO2，3.1V，对应厂商 `pm8150_l2`）。DTB 已确认。
- 构建/安装：DTB/UKI 重装。**重启验证**：`vdd-pdphy` 现在真的由 PM8150 LDO2（3072mV）供电
  （debugfs `...typec@1500-vdd-pdphy` 用上 ldo2），但 **TCPM 侧 PD 合约仍未建立**
  （partner `rev 0.0`、无 source PDO、`tcpm-source-psy` 5V）。
- **但快充确实生效**：重启后重新拔插充电器 —— `pm8150b-charger voltage_now≈8.88V`、
  `ln8000 present=1`（9V+ 才接入的 2:1 电荷泵）、电池 `current_now≈3.06A`（此前 5V/~0.6A）。
  即 **9V 快充通路工作**，但看起来是走 SMB5 的高压/QC(HVDCP) 而非 TCPM PD 合约（待用户确认
  充电器是 PD 还是 QC）。

### 2026-09-27 前摄 1080p 不工作：尝试 4-lane（待重启验证）
- 现象（用户）：GNOME 相机（Snapshot→PipeWire 门户）**前摄不工作**。定位：门户请求
  **1920x1080**；前摄只要 libcamera 选中 ov8856 **`3280x2464`（2-lane, 720MHz）** 模式的输出
  （1080p、1640x1232）就失败 —— CSID 只收几十个包、**VFE 报错**、停止卡死；而 `1640x1232`
  模式的输出（1632x1224/1600x1200/720p/480p）都正常。
- 已排除：去掉 2-lane `3280x2464` 模式**不可行**（1080p 无法上采样，协商直接失败）；
  CSIPHY settle 计算/lane 表与 6.14 一致。
- 尝试（`linux-7.2` `5b27a0e5e5cb`）：怀疑移植 DT 的 lane 数写错（厂商细节也对不上）。把前摄两个
  endpoint 改为 **4 lane**（`camss_front_ep data-lanes=<0 1 2 3>`、`ov8856_ep <1 2 3 4>`），
  让驱动走 4-lane 模式表（含 `3264x2448`/`1632x1224`）。
- 第一次重启：前摄 **probe 失败** `ov8856 4-0010: no link frequency 180000000 supported`
  （4-lane 的 `lane_cfg_4` 链路频率表是 **{360M,180M}**，而 DTS 还是 2-lane 的 {720M,360M}）。
  据此把前摄 `link-frequencies` 改为 `<360000000 180000000>`（物理上等价：4×360 ≈ 2×720）。
- 构建/安装：DTB/UKI 重装（已确认 DTB 前摄 4 lane + 360M/180M）。
- **结论（第二次重启验证）：4-lane 不成立**。probe 成功（默认模式 3280x2464），但**所有分辨率
  都不出流**（`packets=0`、停止挂起）→ 硬件就是 **2-lane**。已 `git revert 5b27a0e5e5cb`
  （`ecb57a5b5318`），DTB 恢复 2-lane/720M·360M。**前摄 1080p 问题仍未解决**（根因仍是
  `3280x2464` 2-lane 模式本身），低分辨率可用。
- 又试了「去掉坏的 `3280x2464` 模式、把前摄上限降到 ~2MP」：**无效且有副作用** —— 请求正好
  `1640x1232`/`1920x1080` 会协商失败（libcamera 要求 sensor 模式严格大于输出），且 PipeWire
  上前摄反而取不到帧。已回退（`ov8856.c` 恢复），重载后前后摄在 PipeWire 均正常。
- **深挖 `3280x2464`（结论：模式本身在 nabu 上不可用）**：
  - 把该模式的 link freq 从 720MHz 改 360MHz（PLL `regs_1`）**并**把 `0x4837` 改成 0x16 匹配，
    仍 `packets≈0x160` 失败 → **不是速率/PHY 问题，是模式寄存器/读出本身**。
  - 该模式与可用的 `1640x1232` 差异集中在分辨率/HTS/VTS、`0x3820/0x3821`（binning/mirror）、
    `0x4009`、`0x4837`、模拟寄存器 `0x5795..0x57a1`；与 4-lane 版相比只差 `0x3018/0x4837`
    和几个模拟寄存器。上游这套 2-lane 表是 Intel 平台用的，nabu 这颗 OV8856 可能不适用。
  - 对照厂商：Android 内核树里**没有 OV8856 驱动**（在单独闭源仓库），无模式表可移植/对照。
  - 结论：前摄只能停留在可用的 `1640x1232` 模式（输出 ≤ ~1632x1224），**1080p/高分辨率前摄
    在现有驱动下无法实现**；再往上需拿到厂商 sensor 设置（闭源）或重写模式表，投入大、把握低。
- 用户态兜底（`nabu-camera`）：改 Snapshot 补丁，**只对前摄**把取景钉到可出流的 **1280x720**、
  拍照钉到 **1600x1200**（后摄不动），绕过“门户选 1080p → 前摄黑”。**已实机验证通过**：
  GNOME 相机前摄正常出画面（~2MP 上限）。
- 排障坑（勿误判）：GNOME 相机（Snapshot 走 PipeWire 相机门户）在前摄**独占**时，若同时有
  其它 libcamera 客户端占用相机，会 `pipeline handler in use by another process` /
  `-16 (Device or resource busy)` → not-negotiated → 前/后摄都黑。用 CLI（`gst`/`nabu-autofocus`）
  取流调试时**会占住相机**，务必先关掉 App/结束测试再判断；这**不是驱动损坏**。

### 2026-09-27 加速计开机加载慢：禁用遗留调试服务 `nabu-regdump`
- 现象：开机后加速计/传感器要 ~50s 才可用（用户反馈“加载过慢”）。本 boot 实测：内核
  fastrpc/SLPI root-PD 在 **7.37s** 就 up，但 `hexagonrpcd`/`iio-sensor-proxy` 到
  **36.8s / 50.5s** 才启动。
- 根因：`/etc/systemd/system/nabu-regdump.service`（显示调试期手工留下的 DPU/DSI 寄存器
  dump）带 `ExecStartPre=/bin/sleep 30` 且 `WantedBy=multi-user.target`，把
  `multi-user.target` 拖后 30s；而 `hexagonrpcd` 的 Debian unit 是 `After=multi-user.target`
  → 被连带拖后。`systemd-analyze blame` 里 `nabu-regdump.service` = 30.1s（第一）。
- 处置：`systemctl disable --now nabu-regdump.service`（**保留 unit 文件，可逆**；需要时
  `enable` 回来）。
- 预期：下次开机 `multi-user.target` ~7s 完成、`hexagonrpcd` 紧随其后，加速计提前 ~30s 可用。
- 备注：`nabu-regdump.service` 不在各 nabu 仓库中（非 port 产物）。

### 2026-09-26 前摄方向修正：DTS `rotation` 270 → 180
- 现象：前摄画面方向相对显示不对。实测把前摄原图旋转 **CW180** 后为正（空调在画面上方、
  用户手机在下方）；后摄旋转 **CW90** 后为正。
- 语义：libcamera 的 `Rotation` 属性表示相机相对设备的**顺时针**安装角，应用需按该角度
  **逆时针**旋转来摆正。故后摄 `270` 正确（CCW270 = CW90），前摄应为 **180**，但 DTS 写成
  了 `270` → 前摄偏 90°。
- 修复（`linux-7.2` `eef8a2d8edc4`）：`sm8150-xiaomi-nabu-camera.dtsi` 的 `ov8856` 节点
  `rotation = <180>`（`ov13b10` 后摄保持 `270`）。核对编出的 DTB：前摄 `0xb4`(180)、后摄 `0x10e`(270)。
- 构建/安装：`production-7.2` `build collect package verify install` 全过；UKI 重装
  （`Image` 不变，仅 DTB 变化），**待重启生效**。
- 备注：Snapshot 把 180 写死在通用取景管线里 → 前摄对、后摄会多转 90°；本行 DTS 修正对
  “遵守 `api.libcamera.rotation` 元数据”的应用（PipeWire/门户类）生效。Snapshot 侧的
  按相机修正本次未做（控制改动面）。

### 2026-09-26 相机不出流根因修复：SM8150 CSIPHY 漏选 lane 寄存器表
- 现象：7.2.7 上相机**完全取不到帧**（`nabu-autofocus` 超时、`gst-launch libcamerasrc` 不出帧）；
  内核 `CSID0 stop: packets=00000000 ecc=00000000 crc=00000000`、`RDI0 ... bytes=00000000`
  —— CSIPHY 一个 CSI-2 包都没收到（非 libcamera/App 问题）。
- 根因（`linux-7.2` `267c823b5b89`）：7.2 把旧 CSIPHY 拆成新驱动后，把「按 SoC 选 lane 寄存器表」
  挪进了 `csiphy_init()`，但**漏了 `CAMSS_8150`**。而 `csiphy_is_gen2(CAMSS_8150)=true`，
  lanes enable 走 `csiphy_gen2_config_lanes()`，它遍历 `regs->lane_regs`；该表为 NULL、
  `lane_array_size=0` → **一条 lane 寄存器都没写**，D-PHY 从未配置。6.14（可用）在 gen2 路径把
  `CAMSS_8150` 映射到 `lane_regs_sc8280xp`，且该表 6.14/7.2 **逐字节一致**，故补回该映射。
- 根因 2（`linux-7.2` `50c1e4b6b73a`）：7.2 的 `msm_csiphy_subdev_init()` 用
  `res->csiphy_res[i].csiphy.id` 作 id（6.14 直接传下标 `i`），而 `csiphy_res_sm8150[]`
  **没设 `.id`** → 4 个 PHY 都是 id 0，csiphy1..3 的时钟名匹配 `"csiphy%d"` 全落空、PHY 时钟
  没配 → 前摄（csiphy1 上的 OV8856）`packets=0`。补 `.id = 0..3`（对齐其它 SoC 的表）。
- 验证（**热重载 `qcom-camss`，不重启**）：
  - 后摄 OV13B10 出流 `CSID0 packets=0002276d ecc=00000000 crc=00000000`；
    `nabu-autofocus --once` 完整 coarse+fine 扫描、`Locked focus=1023 score=98`；
    `gst-launch libcamerasrc ... ! jpegenc` 静拍 2104×1560 JPEG 成功（~3.9MB/张）。
  - 前摄 OV8856 出流 `CSID0 packets=000279e7 ecc=00000000 crc=00000000`，
    `nabu-autofocus --once` 同样锁定对焦。
- 相机用户态（`nabu-camera`）：恢复被 `40a5620` 删掉的 GNOME Snapshot 50.0 拍照补丁 + 安装器
  （`9fba47d`），并修安装器 `meson cargo-test` 在 build 目录找不到 `Cargo.toml` 导致安装中止的
  问题（`65b3f36`）；已按补丁构建安装 Snapshot 50.0。
- 备注（3A）：libcamera 0.7.0 无 ov8856/ov13b10 的 `CameraSensorHelper`（`Failed to create
  camera sensor helper`）。已实现并验证该 helper（`AnalogueGainLinear{1,0,0,128}`，日志变
  `gain 1-15.5`），但结论是**基本只是外观**：无 helper 时 simple IPA 用原始增益码，而这两颗
  sensor 的原始码恰好 128=1×、默认也是 128，AGC 的 1× 基准与钳位范围与标定模型一致，AE 行为
  等价。要系统级生效需**整套重编并替换发行版 libcamera**（IPA 与发行版 core 混用会触发
  `pipeline_handler::stop()` 断言崩溃），风险大于收益，故未安装；补丁记录在
  `nabu-camera/patches/`（`e3324c3`）。

### 2026-09-26 清理：归档并删除两个过期 stash（iris stash 随后按要求恢复）
- `linux-7.2` 的两个 stash 都已过期、且与当前树不兼容。为可逆，先各打 tag 归档再
  `stash drop`：
  - `stash@{0}`（iris SM8150 platform-data WIP，`514dbe124a34`）→ tag
    `archive/stash-iris-sm8150-platform-data`。该方案已被"覆盖模式"（`3865d25922a0`）取代：
    现 overlay 的 `iris_probe.c` 已含 `qcom,sm8150-iris`，platform data 在
    `iris_platform_sm8250.c`。
  - `stash@{1}`（DFPS/seamless WIP，引 MCC45TR 7.2.2，`d80f8a23ae6f`）→ tag
    `archive/stash-dfps-seamless`。已被 7.2.2 显示栈移植（`b0bbb8b6052a`，含 seamless DFPS）
    取代。
- **更新（同日）**：按要求**把 iris 那个 stash 恢复回来**：
  `git stash store 514dbe124a34` → 现 `stash@{0}` = iris SM8150 platform-data WIP（SHA 与
  内容、`git stash show` 均与原 stash 一致）；`archive/stash-iris-sm8150-platform-data`
  tag 保留作双保险。**DFPS 那个仍只作 tag 归档、未恢复。**
- 取回方式：`git stash pop` / `git show <tag|stash>` / `git worktree add <dir> <ref>`。
- 状态更新（见本文件对应条目）：充电回滚 `#31` 已重启生效并实机确认；
  触摸 ESD workqueue 回归、iris 卸载时钟告警均已修并免重启验证。

### 2026-09-26 触摸 ESD workqueue 告警回归修复 + iris 卸载时钟告警修复
- 触摸（`linux-7.2` `975cb8026712`）：`nt36xxx.c` 的
  `alloc_workqueue("nvt_esd_check_wq", WQ_MEM_RECLAIM, 1)` 在 7.2 会告警
  `workqueue: nvt_esd_check_wq is using neither WQ_PERCPU or WQ_UNBOUND`（boot #31
  `[8.726]` 实测）。9/24 的工作区修复从未提交，9/25 `b0bbb8b6052a` 用 7.2.2 版本整套
  覆盖 `nt36xxx.c` 时又把它丢掉了（之前"已修、验证通过"的记录因此失效）。现补回
  `WQ_MEM_RECLAIM | WQ_PERCPU`。
- iris（`linux-7.2` `193edc7dac93`）：`modprobe -r qcom_iris` 在 boot #31 288.149s 一次
  卸载刷 **14 条** WARNING：`video_cc_mvs{0,1}_core_clk` / `gcc_video_axi{0,1}_clk` /
  `video_cc_mvsc_core_clk` / `video_cc_iris_ahb_clk` / `gcc_video_axic_clk` 的
  `already disabled` + `already unprepared`（内核 Tainted W），栈为
  `iris_disable_unprepare_clock → iris_vpu_power_off_hw → iris_vpu_power_off →
  iris_core_deinit → iris_remove`。根因：空闲掉电 `iris_pc_enter()` 已经
  `iris_vpu_power_off()` 并置 `vpu_suspended=true`，卸载时 `iris_core_deinit()`
  不查该标志又关一次时钟。现改为 `vpu_suspended` 时只清标志、不再 power-off（未掉电的
  路径行为不变）。影响的是 Fluster/VA-API 反复重载模块的场景。
- 构建/安装：`production-7.2` `build collect package verify` 全过（仅两个 `.ko` 变化，
  `Image` 仍 `#31`）；`sudo make install` 后模块树/UKI 更新。
- **免重启实机验证（2026-09-26 15:0x，boot #31）**：
  - 触摸：重载 `nt36523_ts` → **无** workqueue 告警，`request irq 252 succeed`、
    `NVTCapacitiveTouchScreen`/`NVTCapacitivePen` 均注册。
  - iris：解码 640x480 H.264 60 帧 → `VPU entered power collapse`（1045.25s）后
    `modprobe -r qcom_iris`，**0 条** `already disabled/unprepared`；随后
    `modprobe qcom_iris` 正常。

### 2026-09-26 iris 的 `system_wq` 废弃告警修正
- `iris_hfi_common.c` 的 `iris_pc_schedule()` 用 `queue_delayed_work(system_wq, ...)`，7.2
  下会在空闲掉电时告警（`work func iris_pc_handler [qcom_iris] enqueued on deprecated
  workqueue`）。改为 `system_percpu_wq`（提交 `d9e91a144c9d`）。
- 验证（重载模块，不重启）：解码 640x480 H.264 60 帧 → `VPU entered power collapse`
  （handler 确实执行），**无新告警**（仅剩本 boot 里旧模块 12.13s 的那条，重启后消失）。

### 2026-09-26 回滚 nabu `qcom_smbx` 充电栈（7.2.2 参考实现有 bug）
- 置换成 senemos `qcom_smbx` 后实机 `pm8150b-charger/voltage_now = 81284352`（81V）。
  直接读 IIO 通道 `in_voltage_usbin_v_input = 5085456`（已有正确 5.08V），证明
  senemos 驱动又对 SMB5 做了 `val->intval *= 16`（`qcom_smbx.c` VOLTAGE_NOW）→ 双重换算。
  **7.2.2 参考并非正确**，故按用户意见回滚。
- 回滚：`d3f4a1326af5` Revert `ecfa28e52990`。回到充电器 = `qcom_pmi8998_charger`
  （含 `CONSTANT_CHARGE_CURRENT` `4040a4a0ba16` + JEITA workqueue `67105a8a5adf`）；
  DTS 保留 Type-C 对齐 `90999fad5838`（`try-power-role=sink` / 27W / 9V PDO）。
- 构建 `#31`（UKI sha `5bb230144641a8cf5b85143db946a4ed856252ab5f22a877f2edf3b12bc9bd2b`）。
  **已重启生效并实机确认**（2026-09-26，boot `#31`）：`pm8150b-charger` type USB、
  `Charging/Full`；`qcom-battery` `100% Full`；`fuel-gauge@4000` 不再 deferred。

### 2026-09-26 充电器换用 nabu `qcom_smbx`（PD 合约 + 热降级 + DTS JEITA，覆盖模式）
- 背景：6.14 那套 `qcom_pmi8998_charger` 没有 PD 合约处理；7.2.2 senemos 的 `qcom_smbx`
  是完整实现。按"覆盖模式"移植（和 iris 一样，先验证编译）。
- 处置（`linux-7.2` `ecfa28e52990`）：
  - `drivers/power/supply/qcom_smbx.c` ← 7.2.2 senemos 版（含 `input_psy` PD 合约、
    `smb_update_input_contract()`、thermal cooling、`qcom,jeita-ranges` 解析、
    `CONSTANT_CHARGE_CURRENT`/`CHARGE_CONTROL_LIMIT`）；顺手把 11 处 `system_wq`
    改为 `system_percpu_wq`（7.2 已废弃）。
  - `Makefile`：`CONFIG_CHARGER_QCOM_SMB2` → `qcom_smbx.o`（不再用 `qcom_pmi8998_charger.o`）。
  - `sm8150-xiaomi-nabu-power.dtsi`：充电器节点加 `input-power-supply=<&pm8150b_typec>`、
    `#cooling-cells=<2>`、`qcom,thermal-mitigation-{,-input,-dcp,-pd}-microamp`、
    `qcom,jeita-ranges`；`&battery` 加 `constant-charge-current-max-microamp=1950000`、
    `constant-charge-voltage-max-microvolt=4450000`、`alert-celsius`、`operating-range-celsius`。
  - 编译验证：`qcom_smbx.o` + DTB 均 0 error；构建 `#30`（UKI sha `42db98c5…`）已安装。
- 覆盖前提交（同区域，保留在历史里）：
  - `4040a4a0ba16`：给旧驱动加 `CONSTANT_CHARGE_CURRENT`（新驱动自带，已不需要）。
  - `67105a8a5adf`：旧驱动 JEITA workqueue 修正（新驱动已改 system_percpu_wq）。
- **待重启验证**：充电器节点能否 probe（thermal/jeita 属性解析）、电池/FG 正常、PD 合约
  生效（需 PD 源）、`CONSTANT_CHARGE_CURRENT`/`CHARGE_CONTROL_LIMIT` 属性出现。
  热 map（`cooling-device`）暂未接（可选，需要 trip label）。

### 2026-09-26 充电对齐参考实现：Type-C sink/DRP + 27W，及 JEITA workqueue 修正
- 背景：7.2.7 的充电已能用（SMB5 输入上限、FG 报电量、100% Full），但 Type-C 取电能力
  与参考（7.2.2 senemos）不一致。
- 对照发现（基础 DTS vs 7.2.2 senemos）：
  - 7.2 连接器**没有 `try-power-role`**（DRP 无偏好，可能自发 source）；
  - `op-sink-microwatt = 10000000`（**10W**）vs 参考 **27W**；
  - sink PDO 只有 `PDO_VAR(5000,9000,3000)`，参考是 `PDO_FIXED(5000,3000)` +
    `PDO_FIXED(9000,3000)`。
- 处置（`linux-7.2`）：
  - `90999fad5838` `arm64: dts: qcom: nabu: align Type-C sink power ...`：在
    `sm8150-xiaomi-nabu-power.dtsi` 的 `&pm8150b_typec/connector` 上补
    `vbus-supply`、`try-power-role = "sink"`、`op-sink-microwatt = <27000000>`、
    并把 sink PDO 改为固定 5V/3A + 9V/3A。
  - `67105a8a5adf` `power: supply: qcom_pmi8998: queue the JEITA work on
    system_percpu_wq`：7.2 废弃了 `system_wq`（`mod_delayed_work(system_wq,…)` 会告警），
    改用 `system_percpu_wq`。
- 验证（DTS 改动，已重启生效，boot `#28`）：live DT `try-power-role=sink`、
  `op-sink-microwatt=27000000`、`preferred_role=sink`；插入非 PD 充电器时
  `APSD: charger type DCP, input limit 3000000uA`、电池 `Full/100%`。当前手边没有 PD
  充电器，PD 取电行为待有 PD 源时复测。
- workqueue 修正为内建（`CONFIG_CHARGER_QCOM_SMB2=y`），编入 `#29`（UKI sha `fa535e63…`），
  **下次重启生效**。

### 2026-09-26 SLPI `Handover signaled` 风暴排查：是 7.2 新增日志，非故障；已降级
- 现象：每次启动 SLPI（`2400000.remoteproc`，`qcom_q6v5_pas`）都刷
  `Handover signaled, but it already happened`，本 boot 1161 次，**间隔恒定 ~195ms**
  （即 SLPI 固件周期性拉 `slpi_smp2p_in 2`，不是随机/悬空 IRQ）。关机那次更多（512）。
- 定位（对照 6.14/7.2.2）：
  - 消息在 `drivers/remoteproc/qcom_q6v5.c` 的 `q6v5_handover_interrupt`；
  - **6.14 的同一 handler 根本没有这个判断**——它每次静默重跑 `handover()`/`icc_set_bw(0,0)`
    （幂等），从不打印；
  - **7.2/7.2.2 新增** `if (handover_issued) dev_err(...)`，于是把固件的周期性信号当错误刷屏；
  - 功能无影响（handover 早已执行，早退只是不再重复释放资源）；SLPI/传感器正常。
- 处置（`linux-7.2`）：把这条重复日志从 `dev_err` 降为 `dev_dbg`（cmdline 带
  `ignore_loglevel`，`dev_err` 会全部打到 console，关机 512 条尤其拖慢/刷屏）。
  `qcom_q6v5.ko` 已重编安装。**已重启验证（2026-09-26 14:19）**：本 boot
  `Handover signaled` = **0** 次；同 boot 显示 `connected enabled`、iris 解码 60 帧、
  电池 100% Full、声卡在、`hexagonrpcd`/`iio-sensor-proxy` active、camss 绑定、
  `dsi_err_worker`/`-110`/iris probe 失败均为 0。
- 关机卡住复核：最近一次 7.2.7→7.2.7 重启（boot -1，13:52）**干净走完**
  `reboot.target → systemd-shutdown → Journal stopped`，未复现卡死；此前那次更像
  "模块树被搞乱"那段的副作用。
- 顺带 audit：port 提交 `7c2c95a1922d` 新增的所有驱动文件现在都已接上——
  `cn3927/ov8856/ov13b10`（camss/cci）绑定、`qcom_fg`+`qcom_pmi8998_charger`、
  `ln8000_charger`、`sound/soc/qcom/sm8150.c`、`drm_notifier`、`nt36523`、iris（覆盖模式）。

### 2026-09-26 iris 改用"覆盖模式"：整套 nabu-iris overlay 驱动覆盖 7.2（待验证）
- 背景：把 SM8150 塞进 7.2 上游 iris 结构太绕（platform data 模型不同）。
  改为用户建议的**覆盖模式**：把 `nabu-iris/kernel-overlay` 的 iris 驱动整套覆盖到
  `linux-7.2/drivers/media/platform/qcom/iris/`（56 个文件 + 其 `Makefile`/`Kconfig`），
  即把 6.14 移植那套 fork（含 `sm8150_data`、`legacy_vpu5`、`cached_capture` 等）直接用于 7.2。
- 接口差异**极小**：唯一编译错误是把 `iris_v4l2_fh_init/deinit` 适配 7.2 的
  `v4l2_fh_add(fh, filp)` / `v4l2_fh_del(fh, filp)`（7.2 多了 `filp` 参数）；其余
  **0 error / 0 warning**，`qcom-iris.ko` 链接通过。
- 安装：`make collect` + `install` 后
  `/lib/modules/7.2.7-nabu-full/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko`
  为 fork 版（含 `qcom,sm8150-iris`、`legacy_vpu5`、`qcom/sm8150/xiaomi/nabu/venus.mbn`），
  vermagic `7.2.7-nabu-full`。UKI 仍为 `#28`（`34d93b5d…`）。
- 注意：`nabu-iris` 的 `[install]` 会把 artifact 里的 `qcom-iris.ko` 覆盖到模块树，所以
  必须先 `make collect` 再 `install`，否则会被上一次 collect 的旧 ko 覆盖回去。
- 状态：已提交 `3865d25922a0`（50 个文件覆盖，工作区 clean）。
- **已重启验证（`#28`，2026-09-26）**：
  - 7.2.7 正常启动；`qcom-iris` 绑定 `aa00000.video-codec`，出现 `Iris Decoder`
    `/dev/video0`、`/dev/video1`；
  - dmesg：`Iris1 firmware booted; leaving Iris2-only controls untouched`、
    `VPU resumed from power collapse`；
  - 解码：`ffmpeg -c:v h264_v4l2m2m` 解 640x480 H.264 **60 帧成功**，dmesg 有完整
    `session_start` → buffer → `SESSION_FLUSH` → `session_stop` → 释放资源流程；
  - 同 boot 显示 0 条 `dsi_err_worker`/`failed: -110`，音频声卡在、电池 `100% Full`、
    `hexagonrpcd`/`iio-sensor-proxy` active。
- 结论：iris（SM8150 硬解）在 7.2.7 上**可用**。原先"把 SM8150 塞进 7.2 上游 iris"的
  尝试已不需要；其改动曾归档为 tag `archive/stash-iris-sm8150-platform-data`，2026-09-26
  按要求又恢复为 `stash@{0}`（见本文件最新条目）。

### 2026-09-26 7.2.7 启动卡住 → 干净重编恢复上一版
- 现象：`#28` 在 12:41 能正常进 GNOME；之后为测 iris 跑了 `install --no-uki`
  （`modules_install`）+ 手动覆盖过 `qcom-iris.ko` + 一次被中断的 `make modules`，随后
  7.2.7 启动在 **~1.5s（persistent journal flush 之后）卡死**，硬重启后仍卡；同一 rootfs
  的 `6.14.11 #38` 正常 → 排除 rootfs，指向 7.2.7 模块树/服务那一步。`/sys/fs/pstore` 空
  （非 panic，是 hang）。
- 处置：
  - `git -C linux-7.2 stash push` 暂存 iris SM8150 platform data WIP（含 `opp_clk_tbl` 修复，
    `stash@{0}`），使源码回到已提交状态；
  - 删掉 iris 目录的 `.o`/`.ko` 残留，干净重编 `production-7.2`（`Image` 未变，仍是 `#28`、
    UKI sha256 `34d93b5d…`）并 `sudo install` 覆盖整套模块树；`Boot0008` 置首，ESP 上 UKI
    sha 与产物一致。
- 备注：`install-uki.sh --rollback` 的备份是 **9/24 的旧 UKI**（首次安装时备份、之后不再更新），
  不能用它"回滚到上一版"，否则会退回到没有今日修复的旧内核。
- 待验证：**冷断电**后启动 7.2.7（热重启不复位 SLPI/PMIC，冷启动更稳）。若仍卡在 ~1.5s，
  则不是模块树问题，下一步查 7.2.7 启动/关机时 SLPI `qcom_q6v5_pas ... Handover signaled`
  风暴（该消息在各次 7.2.7 启动都有）。
- iris WIP 恢复：`git -C linux-7.2 stash pop`（该 stash 于 2026-09-26 短暂归档为 tag
  `archive/stash-iris-sm8150-platform-data`，同日已恢复为 `stash@{0}`，tag 保留作双保险）。

### 2026-09-26 其他模块迁移（充电）：接上 nabu PM8150B SMB5 充电器（#28，待重启）
- 现象：`#27` 上 `/sys/class/power_supply/` 只有 `ln8000-charger`（`present=0`）和
  `tcpm-source-psy-...`，没有电池、没有电量；DT 的 `pmic@2/fuel-gauge@4000`
  一直在 `devices_deferred`，`charger@1000` 无驱动绑定。
- 根因：
  - 7.2 的 `drivers/power/supply/Makefile` 把 `CONFIG_CHARGER_QCOM_SMB2` 映射到上游
    `qcom_smbx.o`，只匹配 `qcom,pmi8998-charger`/`qcom,pm660-charger`；nabu DT 的
    `charger@1000` 是 `qcom,pm8150b-charger`，所以没有驱动；
  - 移植时抄进来的 nabu 充电驱动 `qcom_pmi8998_charger.c`（同时匹配 `qcom,pm8150b-charger`，
    来自 `nabu-power` overlay）**没进 Makefile**，又是一份死代码；
  - `qcom_fg.c` 通过 `devm_power_supply_get_by_reference(dev, "power-supplies")` 依赖该
    充电器；充电器不绑定 → FG 永久 `-EPROBE_DEFER`（这解释了"只见 ln8000、没有电池"）。
- 处置（`linux-7.2` `1daa8e597b1a`）：
  - `drivers/power/supply/Makefile`：`CONFIG_CHARGER_QCOM_SMB2` → `qcom_pmi8998_charger.o`；
  - `qcom_pmi8998_charger.c`：适配 7.2 的 `power_supply_config.fwnode`（6.14 的 `.of_node`
    在 7.2 已移除）。
- 构建/安装：`production-7.2` 重编通过（`Image` `#28`，`UTS_VERSION "#28 SMP PREEMPT
  Sat Sep 26 12:35:13 CST 2026"`，vmlinux 含 `smb2_probe`）；UKI sha256 `34d93b5d…`，
  已装 `Boot0008`。
- **已重启验证（`#28`，2026-09-26）**：`/sys/class/power_supply/` 出现
  `pm8150b-charger`（type USB, **Charging**, online=1, 4.95V, health Good）与
  `qcom-battery`（type Battery, **Charging**, **capacity=98%**, 4.48V, 916mA, present=1）；
  `fuel-gauge@4000` 不再出现在 `devices_deferred`。`ln8000-charger` `present=0` 属正常
  （2:1 电荷泵仅在 9V+ 快充适配器下接入，5V 走 SMB5）。

### 2026-09-26 其他模块迁移（第 2 步）iris：移植恢复/VP9，但发现 iris 在 7.2.7 上从未绑定
- 已提交（`linux-7.2` `bb09176cddb8`）：`media: qcom: iris: recover a wedged core and
  publish the VP9 visible crop`
  - 自动 core recovery：任一实例转入 `IRIS_INST_ERROR` 时置 `recovery_pending`，在最后一个
    firmware session 消失后（session open / close / SYS_ERROR worker）做 deinit+init
    power-cycle；`iris_open()` 遇到 `IRIS_CORE_ERROR` 时也主动 power-cycle，不再永久 -EINVAL；
  - VP9 充分资源 resize：`VIDEO.IR.1.2` 的就地缩小不发 sequence change，改为在 FILL_BUFFER_DONE
    里按帧记录可见矩形、保留 CAPTURE 分配、发 `V4L2_EVENT_SOURCE_CHANGE`，并在 DQBUF 后经
    `G_SELECTION` 返回该 buffer 的矩形（逐 buffer，因为输出滞后一帧）。
  - 代码编译通过（`qcom-iris.ko`）。
- **但实机核对发现 iris 在 7.2.7 上根本没有 probe**（因此上面两项暂为死代码）：
  - DT 节点 `/sys/firmware/.../video-codec@aa00000` 存在且 `status=okay`、
    `compatible="qcom,sm8150-iris"`，平台设备 `aa00000.video-codec` 也在，但没有 /dev/video*；
  - 根因 1：`iris_probe.c` 的 `iris_dt_match[]` **没有 `qcom,sm8150-iris` 条目**
    （`linux-7.2.2` 与 `nabu-iris` overlay 都有），平台设备无法匹配驱动；
  - 根因 2：移植提交 `7c2c95a1922d` 新增的 `drivers/media/platform/qcom/iris/iris_platform_sm8250.c`
    （含 `sm8150_data`）用的是 **6.14 fork 的 `struct iris_platform_data`**（含
    `fwname`/`pas_id`/`inst_fw_caps_*`/`legacy_vpu5`/`use_vcodec_hw_control`…
    这些 7.2 结构里没有），且该文件**未加入 `Makefile`**（7.2.7 上游的 platform data 在
    `iris_platform_vpu2.c`），所以它从未参与编译；sm8150 需要的 clk 类型
    （`IRIS_BUS_CLK`/`IRIS_HW_AXI_CLK`/`IRIS_AUX_*`）在 7.2 的 `enum platform_clk_type`
    里也不存在。
  - 结论：7.2.7 的 iris 是"模块能加载但平台设备不绑定"的死状态。要真正启用，需要把 SM8150 的
    platform data 按 **7.2 的结构**重做进 `iris_platform_vpu2.c`（clk/pmdomain/opp 表、
    `inst_caps`、`firmware_desc`、`num_vpp_pipe=2`），加回 of_match，并确认 7.2 的 vpu2 路径是否
    具备 6.14 fork 的 secure VPU5 处理（overlay 的 `iris_set_hw_state()`/`legacy_vpu5`）。
- 处置：先 revert 掉临时加的 of_match（`4e96f2c50330`），保持构建与运行不变
  （`bb09176cddb8` 的恢复/VP9 代码保留，待绑定修好后再验证）。**第 2 步 b：SM8150 iris
  platform data 移植待做。**

### 2026-09-26 其他模块迁移（第 1 步）：传感器栈 fastrpc PDR + SM8150 SDSP 高 IOVA + pd_mapper SLPI 域，已实机验证
- 背景：`#27` 上 `hexagonrpcd` 反复 `Could not attach to FastRPC node: Broken pipe`
  （`INIT_ATTACH_SNS`）。定位为 9/24 的一批修复**从没提交**、创建 display 分支时被丢弃：
  `linux-7.2` 的 `fastrpc.c` 没有 PDR 等待/SDSP IOVA，`sm8150_domains[]` 缺 SLPI 域；
  `nabu-audio`、`nabu-accelerometer` 也还留着未提交的工作区改动。
- 移植（源：`nabu-accelerometer/patches/0001-sm8150-slpi-fastrpc-pdr.patch`，手工适配
  7.2 的 `dma_addr`/`fastrpc_soc_data` 结构，因为 7.2 已用 `fastrpc_sid_offset()`）：
  - `linux-7.2` `fff7aa8301b1` `soc: qcom: qcom_pd_mapper: expose the SM8150 SLPI
    protection domains`：`sm8150_domains[]` 补 `slpi_root_pd`/`slpi_sensor_pd`；
  - `linux-7.2` `aa341149e18b` `misc: fastrpc: wait for the SLPI root PD and map the
    SM8150 SDSP IOVA alias`：`qcom,protection-domain` PDR 等待（15s 超时）+
    `fastrpc_buf_map_sdsp_alias()`；同步补 binding `qcom,protection-domain`；
  - `nabu-audio` `8529b20`：cs35l41 走 `modules_load` +
    `/etc/modules-load.d/nabu-audio.conf`（开机自动加载）；
  - `nabu-accelerometer` `a1cc3cd`：安装时 `disable --now` + `mask pd-mapper.service`
    （避免 userspace pd-mapper 与内核 `qcom_pd_mapper` 抢 `tms/servreg`）。
- 免重启验证（本次改动只在模块侧，`Image` 未变、仍是 `#27`/sha `7cc87d5f…`；重装模块后
  重载 `qcom_pd_mapper`+`fastrpc`）：
  - dmesg：`enabling SM8150 SDSP high-IOVA workaround`、
    `protection domain msm/slpi/root_pd is up (state 0x1fffffff)`；
  - `hexagonrpcd` active；`ssccli --sensor accelerometer` 有真实读数
    （`X=-0.14 Y=-3.39 Z=8.18 m/s²`）；
  - D-Bus `HasAccelerometer=true`、`HasAmbientLight=true`。
- 备注：重载前出现过一次 `handling crash #40 in slpi`（旧 pd-mapper 状态切换所致），
  重载后稳定。**开机路径待下次重启复核**（预期无需再手动 reload）。

### 2026-09-26 重启验证：#27 通过 —— 面板/触摸/背光正常，DSI 错误归零
- 实机重启到 `Boot0008`（UKI `#27`，`UTS_VERSION "#27 SMP PREEMPT Sat Sep 26 08:49:41
  CST 2026"`，sha256 `7cc87d5f91f79df27b6fe1a9fc698c2be543690c456625f331be9ec446d5d30a`）。
- 运行内核配置：`CONFIG_DRM_PANEL_NOVATEK_NT36523=m`、`CONFIG_BACKLIGHT_KTZ8866=m`、
  `# CONFIG_GPIO_SHARED is not set`。
- dmesg：boot 全程 `dsi_err_worker: status=4` **0** 次、`failed: -110` **0** 次；
  `[7.023371] panel-novatek-nt36523 ae94000.dsi.0: synchronized pen scan rate for 120 Hz`。
  对比 `#26` 同一现象要拖到 `[1971s]` 的第二次 modeset 才成功、且 boot 阶段有 9 次
  `status=4`——证实"首次 bring-up 黑屏"已修。
- 模块由 udev 自动加载：`panel_novatek_nt36523`、`ktz8866`、`nt36523_ts`；连接器
  `card0-DSI-1: connected enabled`。触摸与背光正常。
- 结论：三条修复（`dsi_ctrl_disable` 于复位前 / 面板·背光 `=m` / `GPIO_SHARED` 可关）
  共同解决黑屏。`dpu_core_perf.c` 的 `clk_rate==0` 差异仍未对齐，暂未观察到影响。

### 2026-09-26 找回丢失的 #19 修复 + 对齐 7.2.2 的模块化面板/背光 + 让 GPIO_SHARED 真正可关（#27，待重启）
- 起因：核对发现 `linux-7.2` 的显示/触摸源文件已与 `linux-7.2.2`（senemos）逐字节
  一致（`panel-novatek-nt36523.c`、`dsi_host.c`、`dsi_manager.c`、`dsi_phy_7nm.c`、
  `msm_atomic.c`、`dpu_crtc.c`、`nt36xxx.[ch]` 等），但 7.2.7 仍黑；实机 `#26`
  （2026-09-25 23:29）dmesg 仍反复 `dsi_err_worker: status=4` +
  `sending dcs data ff 10/ff 2a failed: -110`。→ 根因不在这些驱动文件，而在
  bring-up 时机与两个此前**未提交、被 reset 丢弃**的修复。
- 改动（三处，均已提交）：
  1. `linux-7.2` `57c920b3fdd4` `drm/msm/dsi: disable the controller before
     sw_reset on power-on`：在 `msm_dsi_host_power_on()` 的 `dsi_timing_setup()` 后、
     `dsi_sw_reset()` 前加 `dsi_ctrl_disable(msm_host);`。`dsi_sw_reset()` 会
     保存/恢复 `REG_DSI_CTRL`，不清掉 bootloader 遗留的 `VID_MODE_EN` 就会在面板
     init 前把视频引擎打开并 busy → 命令 DMA 超时 -110。即 #19 的修复，本次真正
     落库（此前只存在于工作区；`v7.2.7-nabu-probe` 的 HEAD 仍是 `e490383191ba`，
     reflog 里有一次 `reset` 把它和 #22 的 Kconfig 改动一并丢了）。
  2. `nabu-display` `3688096`：`CONFIG_DRM_PANEL_NOVATEK_NT36523=m`、
     `CONFIG_BACKLIGHT_KTZ8866=m`（7.2.2 senemos 即 `=m`）。内建会让面板在
     **第一次** DSI power-on（控制器仍带 bootloader 状态）时就 init；模块延后
     bring-up。`nabu-module.toml` 增加两个 `.ko` 的 `build/artifacts/install`。
  3. `linux-7.2` `6ef995bfa169` `gpio: make GPIO_SHARED configurable`：
     `GPIO_SHARED` 由 `def_bool y`（无 prompt，片段关不掉）改为
     `bool "..." default y`，使 `nabu-display.config` 的
     `# CONFIG_GPIO_SHARED is not set` 真正生效。
- 配置核对（`nabu-main/out-7.2/.config`）：`# CONFIG_GPIO_SHARED is not set`、
  `CONFIG_DRM_PANEL_NOVATEK_NT36523=m`、`CONFIG_BACKLIGHT_KTZ8866=m`。
- 构建/安装：`production-7.2` `compose config build collect package verify` 全过；
  `panel-novatek-nt36523.ko`、`ktz8866.ko` 已生成/verify 并随 `modules_install`
  装入 `/lib/modules/7.2.7-nabu-full/kernel/drivers/{gpu/drm/panel,video/backlight}/`
  （depmod 别名含 `of:N*T*Cxiaomi,nabu-csot-nt36523`，udev 可自动加载）。UKI `#27`
  （`UTS_VERSION "#27 SMP PREEMPT Sat Sep 26 08:49:41 CST 2026"`）sha256
  `7cc87d5f91f79df27b6fe1a9fc698c2be543690c456625f331be9ec446d5d30a`，已装
  `EFI/ubuntu/7.2.7-nabu-full-build1.efi`（在 ESP 上核对一致），`Boot0008` 置首。
- **待重启确认**：`dsi_err_worker: status=4` 与 `ff 10 failed: -110` 是否消失、面板
  点亮；再确认 touch（`nt36523_ts`）与背光正常。
- 备注：若面板模块加载过晚导致无显示，需要把这两个 `.ko` 纳入早期加载
  （initramfs 或 `/etc/modules-load.d`）。`dpu_core_perf.c` 的 `clk_rate==0`
  提前返回（7.2.7 独有）本次未对齐，留作后续候选。

### 2026-09-25 移植后仍黑屏续：换回 7.2.2 的 DSI 7nm PHY（PLL 引用计数）+ DPU DSPP 预留
- 现象：整套显示栈移植后，7.2.7 启动（boot -1，23:19）仍反复
  `dsi_err_worker: status=4`（DSI FIFO 错误），面板黑；同机 7.2.2（boot 0）0 条。
  说明黑屏根因不在 panel/touch 驱动，而在未移植的 PHY/DPU 差异。
- 根因（疑似，已处理）：7.2.7 upstream 的 `dsi_7nm_phy_enable()` 新增「`pll_enable_cnt++`
  已非 0 就直接 return、不重开 PLL」，并在 `dsi_7nm_pll_restore()` 置 `pll_enable_cnt=1`、
  `dsi_7nm_phy_disable()` 置 0，经 `phy->pll_data` 访问。**7.2.2 没有这套引用计数短路**
  （总是上电）。nabu 是 **bonded 双 DSI 共用一个 7nm PLL**，该短路会破坏 bring-up →
  `VIDEO_MDP_FIFO` 欠载。
- 处置（提交 `dd2e62d32889`）：
  - `drivers/gpu/drm/msm/dsi/phy/dsi_phy_7nm.c` 与 `dsi_phy.h` 换回 7.2.2 版本
    （删 `struct msm_dsi_phy.pll_data`）；
  - 采纳 7.2.2 `disp/dpu1/dpu_crtc.c` 的 nabu Night Light DSPP 预留
    （`of_machine_is_compatible("xiaomi,nabu")`）。
- 构建/安装：`production-7.2` 重编通过；UKI 重装
  `EFI/ubuntu/7.2.7-nabu-full-build1.efi`（sha256 `377a809d…`），`Boot0008` 置首。
  **待重启确认黑屏是否消失。**
- 若仍黑屏，下一步候选：把 `CONFIG_DRM_PANEL_NOVATEK_NT36523` 由 `=y` 改 `=m`
  （7.2.2 为 `=m`，bring-up 时机不同）；再对照 `dpu_core_perf.c`（7.2.7 有
  `clk_rate==0` 提前返回，7.2.2 无）。

### 2026-09-25 从 7.2.2 senemos 树移植整套 nabu 显示/触摸栈到 7.2.7（新分支，待实机）
- 背景：同机 6.14 与 MCC45TR 7.2.2（senemos）显示/触摸可用，7.2.7 移植的 DSI 视频引擎
  黑屏（见下条）。故把 7.2.2 那套已知可用的显示+触摸实现整体移植到 7.2.7。
- 分支（**新建，不改原 probe 分支**）：`v7.2.7-nabu-display`（基于 `v7.2.7-nabu-probe`
  `e490383191ba`），移植提交 `b0bbb8b6052a`。worktree `/home/cfm880/sources/nabu-linux/linux-7.2`。
- 从 `linux-7.2.2`（senemos）按文件移植（16 个文件，+1293/-471）：
  - 面板：`drivers/gpu/drm/panel/panel-novatek-nt36523.c`（nabu CSOT 120/90/60Hz 模式、
    pen-FPS 同步、7.2.2 init 序列）；
  - DRM 核心：`include/drm/drm_panel.h`（`drm_panel_funcs.mode_set`）、
    `drivers/gpu/drm/bridge/panel.c`（转发）、`include/drm/drm_crtc.h`
    （`struct drm_crtc_state.seamless_dfps`）、`drivers/gpu/drm/drm_notifier.[ch]`；
  - msm：`dsi/dsi_host.c`、`dsi/dsi_manager.c`、`dsi/dsi.h`、`msm_atomic.c`、
    `disp/dpu1/dpu_encoder.c`（仅 seamless 一处）、`dpu_encoder_phys.h`、
    `dpu_encoder_phys_vid.c`（`seamless_mode_set`）；
  - 触摸：`drivers/input/touchscreen/nt36523/nt36xxx.[ch]`；
  - DTS：面板 `rotation = <90>`、背光 `bl_en_state` 拍平、触摸节点
    `compatible="novatek,nt36523-spi"` + `irq-gpios=<&tlmm 39 GPIO_ACTIVE_LOW>`
    + `wakeup-source` + `novatek,double-tap-to-wake`，`&spi18` 删 `reg-names`/
    `spi-max-frequency`。
- 注意：**未**移植 7.2.2 独有的 `msm_dp_is_yuv_420_enabled` hunk（`dpu_encoder.c`），
  它 7.2.7 DP 侧不存在会链接失败；只保留 nabu seamless hunk。`msm_drv.h` 保持 7.2.7。
- 构建/安装：`nabu-main` product `production-7.2`（release `7.2.7-nabu-full`）
  `compose config build collect package verify` 全部通过；`sudo make install` 在
  `nabu-accelerometer` 的 `install-tablet-mode.sh` 处中止——因其要求 DT model 为
  `Xiaomi Pad 5 (nabu)`，而当时运行的 7.2.2 senemos DTS model 仅为 `Xiaomi Pad 5`
  （7.2.7 DTS model 正确，从 7.2.7 启动时该 hook 可通过）。模块树已装；UKI 用
  `scripts/install-uki.sh` 手动安装：`EFI/ubuntu/7.2.7-nabu-full-build1.efi`
  （sha256 与 artifacts 一致），UEFI 启动项 `Boot0008 nabu-7.2.7-nabu-full` 置首。
- 验证编译：`Image`、`sm8150-xiaomi-nabu-production-7.2.dtb`、`nt36523_ts.ko`
  （vermagic `7.2.7-nabu-full`）均生成；DTB 反编译确认含 `rotation=0x5a`、
  `irq-gpios`、`novatek,nt36523-spi`、`double-tap-to-wake`。**实机（黑屏是否修复）待重启确认。**

### 2026-09-25 显示排查续：找到 7.2 gpiolib-shared 抓走面板 reset 的真 bug + 用 modetest 证明 DSI/面板本身不显示（#22，仍未点亮）
- 关键实机对照（同机，直接读 GPIO 调试节点）：
  - **6.14（正常）**：`gpio6   : out high`（tlmm 6 = 面板 `reset-gpios`，
    低有效 → high = 已退出复位），且**没有**任何 `reset` 代理线。
  - **7.2（黑屏）**：`gpio6   : out low`（复位被拉低），并且多出 4 条
    `gpio-0 ( |reset ) out hi`（`gpiolib_shared.proxy.*`）。
- 根因：7.2 新增的 **`gpiolib-shared`**（`CONFIG_GPIO_SHARED`，`def_bool y`）会在启动时
  扫描**所有 `*-gpios` 属性**，把面板的 `reset-gpios = <&tlmm 6 GPIO_ACTIVE_LOW>` 也
  注册成“共享 GPIO”，并给 remoteproc 建 4 个 proxy（`drivers/gpio/gpiolib-shared.c`
  `gpio_shared_of_traverse()` / `gpio_shared_setup_reset_proxy()`）。面板驱动经
  `devm_gpiod_get(dev,"reset")` 取到的是被重定向后的代理，实际 tlmm 6 被留在低电平
  → **面板一直处于复位状态**。6.14 没有这个自动共享，直接由面板驱动驱动该脚。
- 处置：
  - `linux-7.2/drivers/gpio/Kconfig`：给 `GPIO_SHARED` 加 prompt（否则 `def_bool y`
    无法在 config 里关掉）；
  - `nabu-display/config/nabu-display.config`：`# CONFIG_GPIO_SHARED is not set`、
    `# CONFIG_GPIO_SHARED_PROXY is not set`。
  - 验证（#22）：`CONFIG_GPIO_SHARED is not set`、`gpio6 : out high`、reset 代理线只剩
    `ufs_reset` 一条。**但屏幕仍然黑**（见下）。
- **决定性判据：DSI/面板本身在 7.2 上不显示，不是 GNOME/GPU 的问题**。
  停掉 `gdm`（GNOME 释放 DRM master）后用 `modetest -s 36:1600x2560` 直接向 CRTC/DSI
  输出 CPU 绘制的 SMPTE 测试条纹（完全不经过 GPU/GNOME）：**屏幕依旧全黑**。
  → 排除 GPU fault / GNOME / fbdev 虚拟地址那些噪声，问题在 DSI→面板链路或面板初始化。
- 另一决定性现场：**7.2 的 DSI video MDP FIFO 持续欠载**（DPU 正在扫描、`underrun: 0`）：
  - `DSI0/1 FIFO_STATUS=0x15551019`（`VIDEO_MDP_FIFO_OVERFLOW|UNDERFLOW` + 各 lane
    HS FIFO EMPTY）；6.14 为 `0x10001010`（无错误位）。
  - 用 `devmem` 对 `REG_DSI_FIFO_STATUS` 写 1 清位后 1s 内立刻重新置成 `0x15551019`
    → **不是陈旧 sticky 位，是持续欠载**。
  - 同时 `STATUS0=0x8`（video engine busy）、`CTRL=0x173`、DPU `INTF` 配置/`vsync` 计数
    正常。→ DPU 没有按 DSI 期望的时序喂数，或 DSI 侧取数速率不匹配。
- 已逐一排除（6.14 与 7.2 完全一致）：
  - 面板 init 序列：把 7.2 的 `nabu_csot_init_sequence()`（188 条）与 vendor
    `dsi-panel-k82-42-02-0a-video.dtsi` 的 `qcom,mdss-dsi-on-command` 逐条比对
    **完全一致**（含 `lp11-init` / LP 模式）；reset 时序 4 步也一致。
  - DSI timing（ACTIVE_H/TOTAL/h_total/hdisplay）、`dsi_get_pclk_rate()` /
    `dsi_byte_clk_get_rate()` / `dsi_calc_pclk()`、`dsi_ctrl_enable()` /
    `dsi_op_mode_config()` / `dsi_sw_reset()` / `dsi_wait4video_*()` /
    `dsi_cmd_dma_tx()` 均与 6.14 逐字节相同；
  - 时钟：dsi0 VCO 1.024GHz、byte 146.284MHz、pclk 292.568MHz，dsi1 用 dsi0 PLL；
    `ideal_bclk == link_bclk`（`d152b582d852` 在本 mode 下是 no-op）；
  - DPU INTF cfg/cfg2/hsync/dhctl/data_width（`0x800000/0x10/0x3740014/0x3470028/800`）
    与 6.14 相同；SSPP 选择换成 VIG0 也一样黑（已回退该实验）；
  - DSI PHY/PLL 寄存器 dump（devmem 0xae94400/0xae94600）与 6.14 基本相同，仅 7.2 多置
    `CMN_RBUF_CTRL=1`（`b63f008f395c` 的 back-buffer resync）及个别 lane 状态位。
- 仍未定位的根因：7.2 上 DSI video FIFO 持续欠载（且 6.14 不欠载）。下一步方向：
  对比 6.14/7.2 在 **`dsi_op_mode_config()` 写完 VID_MODE_EN 之后**的寄存器现场
  （DPU INTF timing-engine 使能状态 / INTF→DSI 握手 / 字节时钟门控 / `CMN_RBUF_CTRL`
  的 back-buffer resync 对 CPHY 的影响），以及 `dsi_wait4video_eng_busy()` 在 7.2 上
  为何会在无数据时仍显示 busy。
- 构建：`#19`（ctrl_disable）、`#20`（deferred enable）、`#21`（SSPP 实验，已回退源码）、
  `#22`（GPIO_SHARED 关闭）。**#22 已 install，屏幕仍黑。**

### 2026-09-25 黑屏根因（可稳定复现）：首次上电沿用 bootloader 的 DSI 视频模式 → 命令引擎卡死；已修致命路径，但 init 期间 FIFO 欠载仍在（#19，显示仍未恢复）
- 复现场景：重启后**第一次** `msm_dsi_host_power_on()` 会沿用 bootloader 留在 DSI
  控制器里的状态；随后 `blank/unblank`（或任何后续 modeset）触发的**第二次** bring-up
  日志完全干净（`status0=0x0`、0 条 FIFO 错误），与 6.14 一致。坏 boot 时首条面板命令
  `ff 10` 命令 DMA 超时（-110）→ init 中断 → 黑屏/局部；好 boot 时首条命令虽慢但成功。
- 实机证据（新增探针 `DSI%d power_on: pre-reset ctrl=.. status0=.. fifo=..`，见 #19）：
  ```
  DSI0 power_on: pre-reset ctrl=0x77 status0=0x8 fifo=0x10001010
  DSI1 power_on: pre-reset ctrl=0x77 status0=0x8 fifo=0x10001010
  ```
  - `ctrl=0x77` = `ENABLE(1)|VID_MODE_EN(2)|CMD_MODE_EN(4)|LANE0..2(0x10|0x20|0x40)`
    → **bootloader 把 DSI 控制器留在视频模式**；
  - `status0=0x8` = `VIDEO_MODE_ENGINE_BUSY` → 视频引擎已在跑。
  - 第二次 bring-up 时 ctrl 已被 `power_off → dsi_ctrl_disable()` 清零，故正常。
- 根因：`dsi_sw_reset()` 会保存/恢复 `dsi_ctrl` 的使能与模式位：
  ```c
  ctrl = dsi_read(REG_DSI_CTRL);              // = 0x77，含 VID_MODE_EN
  if (ctrl & DSI_CTRL_ENABLE)
          dsi_write(REG_DSI_CTRL, ctrl & ~DSI_CTRL_ENABLE);
  /* ... toggle REG_DSI_RESET ... */
  if (ctrl & DSI_CTRL_ENABLE)
          dsi_write(REG_DSI_CTRL, ctrl);      // ← 恢复成 0x73，视频模式又被打开
  ```
  于是**在面板 init 之前视频引擎被（未重新配置地）打开并 latch busy**，命令引擎被
  `VIDEO_MODE_ENGINE_BUSY` 卡住 → `dsi_cmd_dma_tx()` 等不到 `CMD_DMA_DONE`
  → 200ms 超时（`status0=0xb=CMD_ENG_BUSY|CMD_DMA_BUSY|VIDEO_ENG_BUSY`）→ `ff 10`
  `failed: -110`。第二次 bring-up 时 `ctrl` 无模式位，reset 干净，所以正常。
- 修复（`linux-7.2/drivers/gpu/drm/msm/dsi/dsi_host.c` `msm_dsi_host_power_on()`）：
  在 `dsi_sw_reset()` 之前先 `dsi_ctrl_disable()`（写 CTRL=0），强制 reset 从干净状态
  开始，等价于后续每次 power-on：
  ```c
  dsi_timing_setup(msm_host, is_bonded_dsi);
  dsi_ctrl_disable(msm_host);   /* 新增：清掉 bootloader 遗留的模式位 */
  dsi_sw_reset(msm_host);
  dsi_ctrl_enable(msm_host, phy_shared_timings, phy);
  ```
  另外保留探针 `DSI%d power_on: pre-reset ctrl=.. status0=.. fifo=..`。
- 验证（`#19`，`UTS_VERSION "#19 SMP PREEMPT Thu Sep 24 23:42:45 CST 2026"`，已 install/重启）：
  首次 bring-up `pre-reset ctrl=0x77 status0=0x8` → `op_mode: video=1 enable=1
  ctrl=0x171->0x173 fifo=0x11111010`，**无 `cmd dma timeout`、无 `ff 10 failed: -110`**，
  面板 init 完整跑完。→ **致命路径已修**。
- **仍未解决（显示仍然是黑 / 曾出现左上 1/4）：**
  - 首条命令之后 DSI 仍报 **21 次** `FIFO_STATUS=0x1ddd1019`（`VIDEO_MDP_FIFO_UNDERFLOW`
    + 各 lane `HS_FIFO_EMPTY`/`UNDERFLOW`），集中在本 boot 的
    `op_mode enable=1`（6.576316s）到 DPU `post_kickoff → enable_timing(1)`（6.584712s）
    之间的 ~8.6ms 窗口（最后一条 6.584917s），**DPU 开始送数后不再报错**。
  - 6.14 在同样窗口 **0 条**。→ 7.2 的 DSI video engine 在 DPU 供数前就自由运行并
    欠载，仍会破坏面板 init（表现为黑屏，或此前看到的左上 1/4 + 左下一条线）。
  - 面板 init 全部 376 条命令在该 ~8ms 窗口内瞬时发完（~21µs/条）→
    `dsi_wait4video_eng_busy()` 未按预期等待（VIDEO_DONE 来得异常频繁），亦印证
    视频引擎处于非正常自由运行状态。
- 其它已排除 / 记录：
  - `ideal_bclk == link_bclk == 146284250`、`pclk=292568500`、
    `bonded=1 lane=3 cphy=1`；`clk_summary`：dsi0 VCO 1.024GHz、byte 146.284MHz、
    pclk 292.568MHz，dsi1（slave）用 dsi0 PLL（byte1=146.284MHz）。
    → 时钟/字节率正常，**`d152b582d852` 的 round 在本 mode 下是 no-op，不能解释黑屏**。
  - `nabu_csot_init_sequence()` 命令序列与 6.14 **逐条一致**（188 条；`_multi` 重写后
    数值相同）。`dsi_ctrl_enable()` / `dsi_op_mode_config()` / `dsi_sw_reset()` /
    `dsi_wait4video_*()` / `dsi_cmd_dma_tx()` 与 6.14 **逐字节相同**。
  - 面板驱动 `nabu_csot_init_sequence()` 用 `_multi` API 但**不检查
    `dsi_ctx.accum_err`**：一旦某条命令失败，后续 `_multi` 调用会静默变 no-op、init 被
    截断（潜在风险，应补检查）。
- 下一步：
  1. 让面板 init 在 **DSI 视频使能之前**完成（对齐 vendor 的 `qcom,mdss-dsi-lp11-init`
     + `on-command-state = "dsi_lp_mode"`）：重做「方案 1」，把 `msm_dsi_host_enable()`
     从 DSI bridge `pre_enable` 挪到 `enable`，并确认 7.2 的
     `drm_atomic_bridge_chain_enable()` 确实会调用 legacy `.enable`（否则改
     `.atomic_enable`）；随后实测首条 `ff 10` 与 0 条 FIFO 错误。
  2. 若上一步不可行，定位 7.2 为何 `VIDEO_MODE_ENGINE_BUSY` 会自行置位：对比
     6.14/7.2 的 PHY `pll_enable_cnt`/RBUF、`DSI_VID_CFG0`、PHY 时钟门控与 DPU
     INTF timing-engine 启动顺序，找到「自由运行」的源头并关掉。
  3. `nabu_csot_init_sequence()` 结束后检查 `dsi_ctx.accum_err` 并向上返回错误。

### 2026-09-24 DPU INTF timing 探针 + #17 实机数据：DPU/DSI 半宽一致，推翻"除半不匹配"（#18 已安装，待重启）
- 新增探针：
  - `dpu_hw_intf.c`（19:37，**已编入 #17**）：`dpu_hw_intf_setup_timing_engine()` 打印
    `cfg/cfg2/hsync/dhctl/ahctl/data_width/width/xres`。
  - `dpu_encoder_phys_vid.c`（23:08，**晚于 #17，已编入 #18**）：`dpu_encoder_phys_vid_enable()`、
    `dpu_encoder_phys_vid_handle_post_kickoff()` 打印 intf/role/state。
- build `#17`（`7.2.7-nabu-full #17`，23:00:30 CST，23:04 启动）实机寄存器：
  - `DSI0/1 6g clk: pclk=292568500 ideal_bclk=146284250 link_bclk=146284250 (bonded=1 lane=3 cphy=1)`
  - `DSI0 timing: bonded=1 ACTIVE_H=0x3480028 ACTIVE_V=0xaac00ac TOTAL=0xac50373
    (h_total=884 ha_start=40 ha_end=840 hdisplay=800 mode=1600x2560)`
  - `INTF3(72) cfg=0x800000 cfg2=0x10 hsync=0x3740014 dhctl=0x3470028 ahctl=0x0
    dwidth=800 width=800 hdis=800`（`INTF2(72)` 相同）
  - 0.943s：`FIFO_STATUS=0x1ddd1018 ctrl=0x171 status0=0x8` →
    `op_mode: video=1 enable=1 ctrl=0x171->0x173 fifo=0x15551018`；
    1.077s：`dsi_cmds2buf_tx: wait for video done timed out`。
- 解读：
  - `hsync=0x3740014` = hsync_period `0x374`=884、pulse `0x14`=20；
    `dhctl=0x3470028` = active_h_start `0x28`=40、active_h_end `0x347`=839（800 宽）。
    → **DPU 每个 INTF 就是 800 半宽、h_total=884，与 DSI bonded（hdisplay=800/h_total=884）
    完全一致**。**推翻**上上条"DSI 除半、DPU 全宽不匹配"的假设。
  - `ctrl=0x171` = `ENABLE|CLK_EN|LANE0..2`，**未置 `VID_MODE_EN(0x2)`**；enable 后为 `0x173`。
    即视频模式尚未使能时 `STATUS0` 已 `0x8`（`VIDEO_MODE_ENGINE_BUSY`）→ 再次坐实
    "7.2 在 DSI 视频使能前引擎已 busy"。
  - `ideal_bclk == link_bclk`（146284250）→ "方案 2" 的 round 修复在此 mode 下与理论值相同，
    **是 no-op，不能解释黑屏**。
  - 注意：`INTF setup` 打印在 1.358s，**晚于** DSI `op_mode enable` 的 0.943s，与"DPU 提前
    向 DSI 推数"不符；`dpu_encoder` 探针正是为确认 INTF timing-engine 的真实启动时机而加。
- 构建/安装：`#18`（`UTS_VERSION "#18 SMP PREEMPT Thu Sep 24 23:38:18 CST 2026"`）
  —— `build collect package verify` 通过，encoder 探针已确认编入 `Image`，`sudo install`
  已更新模块树与 UKI（`Boot0008` 置首）。**待重启**后看
  `dpu phys_vid_enable(72)` / `post_kickoff(72)` 打印。

### 2026-09-24 黑屏根因最终定位：7.2 的 DSI STATUS0.VIDEO_MODE_ENGINE_BUSY 在视频使能前已置位
- 6.14/7.2 A/B 对照（同机同面板，探针逐字段相同）：
  | 项 | 6.14 成功 | 7.2 失败 |
  |---|---|---|
  | DPU INTF cfg/cfg2/hsync/dhctl/ahctl/data_width | 全相同 | 全相同 |
  | DSI ACTIVE_H / TOTAL / h_total / ha_end / hdisplay | 全相同 | 全相同 |
  | `op_mode` 前 `FIFO_STATUS` | `0x11111010` | `0x11111010`（相同基线） |
  | **`op_mode` 前 `STATUS0`** | **`0x0`** | **`0x8`（VIDEO_MODE_ENGINE_BUSY）** |
  | xfer 时 `STATUS0` | `0x0` | `0x8`→`0x2008` |
  | DSI 错误数 | **0** | 27 |
- 机制：`dsi_wait4video_eng_busy()`（`dsi_host.c:1266`）——
  ```c
  data = dsi_read(REG_DSI_STATUS0);
  if (!(data & DSI_STATUS0_VIDEO_MODE_ENGINE_BUSY)) return;      // 6.14 走这里，不等待
  if (power_on && enabled) dsi_wait4video_done(msm_host);        // 7.2 走这里 → 等 70ms → 超时
  ```
  7.2 在 DSI 视频尚未使能时 `VIDEO_MODE_ENGINE_BUSY` 就为 1，导致面板 init 命令
  误入「等待 video-done」，而视频还没跑 → 70ms 超时 → `ff 10` 失败 → 黑屏。
- **结论：不是 DSI/DPU 的寄存器配置差异，而是 7.2 在 DSI 视频使能前
  `VIDEO_MODE_ENGINE_BUSY` 已被置起**（DPU INTF 已向 DSI 推数据，或 DSI video engine
  被提前启动）。下一步对比 6.14/7.2 的 DPU INTF timing-engine 启动时机与 DRM bridge
  enable 顺序（`dpu_encoder_phys_vid_enable` → `setup_timing_engine` →
  `intf->ops.enable_timing`）。

### 2026-09-24 黑屏修复（方案 2）：6G byteclk 的 round 值只用于时钟表决 —— 已应用，待实机验证
- 根因（见下条诊断）：7.2 独有提交 `d152b582d852`（6.14 没有）在
  `dsi_calc_clk_rate_6g()` 里用 `clk_round_rate()` 的结果**覆盖 `byte_clk_rate`**。
  而 `byte_clk_rate` 还被 `byte_intf_clk_rate`(= /2 或 /4)、PLL `bitclk_rate`、
  ESC 分频等**时序相关**计算复用 → round 后的值污染了时序，使 DSI 送数速率与
  pclk/面板时序失配 → **video MDP FIFO 同时 overflow+underflow、所有 lane HS FIFO
  欠载** → 命令 DMA 卡住（`status0=CMD_ENG_BUSY|CMD_DMA_BUSY`）→ 面板 init
  `ff 10` 超时 → 黑屏。
- 修复（`dsi_host.c`）：
  - 新增字段 `link_byte_clk_rate`（仅用于时钟表决）；
  - `dsi_calc_pclk()` 默认 `link_byte_clk_rate = byte_clk_rate`；
  - `dsi_calc_clk_rate_6g()`：**保留** `byte_clk_rate` 为理论值（供时序/PLL/ESC），
    round 值只写入 `link_byte_clk_rate`；
  - `dsi_link_clk_set_rate_6g()`：`dev_pm_opp_set_rate()` 改用
    `link_byte_clk_rate`（保留 patch 原意：让重复 set_rate 变 no-op、不重锁 PLL）。
- 保留探针：`DSI<id> 6g clk: pclk=.. ideal_bclk=.. link_bclk=..`。
- 验证：`dsi_host.o` 编译通过；**待实机确认 FIFO 错误消失、面板点亮**。

### 2026-09-24 黑屏根因锁定：DSI bonded 时序被除半，与 DPU 全宽不匹配 —— 待确认
- 诊断数据（`#11` 实机）：面板 init 超时时
  `DSI0 FIFO_STATUS=0x1ddd1019`（`VIDEO_MDP_FIFO_OVERFLOW(1)|UNDERFLOW(8)` +
  4 条 lane 的 HS FIFO 全 EMPTY/UNDERFLOW）、`CTRL=0x173`（VIDEO 已开）、
  `STATUS0=0x8`（VIDEO_MODE_ENGINE_BUSY）。
  → **DSI 视频 FIFO 溢出+欠载、所有 lane HS FIFO 空** = 供数时序与 DSI 期望不符。
- 根因：`dsi_timing_setup()` 里有 **上游自带的**（6.14/7.2 都有，非本 port）
  `if (is_bonded_dsi) { h_total/=2; hs_end/=2; ha_start/=2; ha_end/=2; hdisplay/=2; }`，
  假设「两个面板各占半宽」。但 nabu 是**单一 `panel@0` 全宽 1600×2560 接两路 DSI**，
  DPU 按全宽 1600 送数据，而 DSI 侧按 800 配置 → FIFO overflow+underflow →
  command DMA 等不到 video-done → 面板 init `ff 10` 超时 → 黑屏。
  （6.14 同代码但显示正常，说明还有别的变量；先用探针确认 DSI 侧寄存器值。）
- 探针（临时）：`dsi_timing_setup()` 打印
  `DSI<id> timing: bonded=.. ACTIVE_H/V/TOTAL .. h_total/ha_start/ha_end/hdisplay mode=..`。
- 验证：`dsi_host.o` 编译通过；已打包安装，**待重启取寄存器确认再改**。

### 2026-09-24 黑屏诊断探针（临时）—— 已应用，待实机取数
- 目的：面板 init 的 DSI 命令 DMA 超时时，打印寄存器现场，定位是 FIFO 欠载、
  时钟/PLL 未就绪，还是 DSI 控制器状态异常。
- 改动（临时，定位后移除）：
  - `dsi_fifo_status()`：出错时打印
    `DSI<id> FIFO_STATUS=0x.. ctrl=0x.. status0=0x..`；
  - `dsi_cmd_dma_tx()`：命令 DMA 超时时打印
    `DSI<id> cmd dma timeout: ctrl/status0/fifo/clk_status`。
- 验证：`dsi_host.o` 编译通过；已随构建打包安装，**待重启一次取 dmesg**。

### 2026-09-24 黑屏修复（方案 1）：DSI 视频使能推迟到面板 init 之后 —— 已应用，待实机验证
- 背景：见下一条「黑屏排查」。面板 init 命令在 DSI 视频引擎已使能后发送，导致
  命令 DMA 等待 VIDEO_DONE 超时、init 中断、黑屏（7.2 间歇）。
- 参考：小米 vendor（Android）内核 `dsi-panel-k82-42-02-0a-video.dtsi` 用
  `qcom,mdss-dsi-lp11-init` + `on-command-state = "dsi_lp_mode"`，即**在视频开始前、
  用 LP 模式发 init**。逐项对比确认主线面板时序/复位/init/DSI 寄存器配置与 vendor
  一致，唯一差异就是这个时序。
- 改动（`linux-7.2/drivers/gpu/drm/msm/dsi/dsi_manager.c`）：
  - `dsi_mgr_bridge_pre_enable()` 只做 `dsi_mgr_bridge_power_on()`（PHY/时钟）+
    blank notifier，**不再** `msm_dsi_host_enable()`；
  - 新增 `dsi_mgr_bridge_enable()`，在其中调用 `msm_dsi_host_enable()`（master+slave）
    真正开启 DSI 视频；
  - bridge 回调表加 `.enable = dsi_mgr_bridge_enable`；
  - 删除随之不再使用的 `dsi_mgr_bridge_power_off()`。
- 原理：DRM 的 enable 顺序是 `crtc_enable`(DPU INTF) → bridge `pre_enable`(DSI+面板)
  → bridge `enable`。把视频使能挪到 `enable` 后，面板 init（panel bridge 的
  `pre_enable`）发生在视频之前，`dsi_wait4video_eng_busy()` 因 `enabled=false` 不再
  等 VIDEO_DONE → init 不再超时。
- 验证：`dsi_manager.o` 编译通过（无警告）；已随 `#9`（16:58:26）打包安装；
  **实机验证：未生效**——DSI `ff 10` 超时依旧、面板仍黑（且期间 `systemctl
  restart gdm` 把设备搞卡死重启）。**已回退**（`git checkout -- dsi_manager.c`），
  并重编安装为 `#10`（17:43:08），设备回到改动前状态。根因分析继续（见下）。

### 2026-09-24 黑屏排查：7.2 DSI 视频 bring-up 间歇性失败（进行中）
- 现象：屏幕黑（或只在左半显示 console），gdm/gnome-shell 在跑、DRM 显示
  `enabled`、DPU 在扫描两半（plane 用两个 SSPP：`800x2560+0+0` /
  `800x2560+800+0`）、背光开，但实际黑屏。
- 定位：7.2 上 DSI bring-up 间歇性报错：
  `dsi_err_worker: status=4`（= `DSI_ERR_STATE_FIFO`，DSI FIFO 错误）+
  `dsi_wait4video_done: wait for video done timed out`（70ms 内无 VIDEO_DONE），
  随后面板初始化第一条命令 `dcs data ff 10 failed: -110` 超时 → 面板 init 序列
  中断 → 面板未配置 → 黑屏。
- 对比：同机 6.14.11 各次启动 **0 次** DSI 错误；7.2 各次启动 **0~13 次**
  （间歇：有的 boot 0 次、有的十几次）。当前 boot 13 次（最多）→ 黑屏。
- 已排除：`dsi_cmds2buf_tx` / `dsi_wait4video_done` / ISR / `msm_dsi_host_enable` /
  `dsi_op_mode_config` / DSI 错误掩码，6.14 与 7.2 **完全一致**；`dsi_manager.c`
  关键函数也一致；DFPS 有无都出现（与回滚无关）。
- 结论：7.2 DSI/DPU 视频时序的 bring-up 竞态（`dsi_host.c` 相对 6.14 有 ~349 行
  差异），导致部分启动时 DSI FIFO 欠载、视频引擎卡住、VIDEO_DONE 不来。
- 下一步：① 重启试运气（间歇，好 boot 应 0 错误、显示正常）；② 深挖 7.2 DSI/DPU
  时序差异（`dsi_timing_setup` / DPU INTF 时序）。

### 2026-09-24 GPU fault 排查（结论：7.2 msm 行为，非固件/非 drm.debug）
- 现象：7.2.7 上 boot 时 GPU 报翻译 fault 并 hangcheck 恢复：
  `*** gpu fault: ttbr0=... iova=0000000106690000 dir=READ type=TRANSLATION source=CCU`
  → `[drm:recover_worker] hangcheck recover!`，offending task 均为
  `gnome-shell (--mode=gdm)`。**每次 IOVA 都是同一个 `0x106690000`**；boot -2 上
  周期性复发（8/20 分钟间隔）。
- 已排除：
  - **固件不缺**：GPU 是 Adreno 640（SM8150），加载 `a640_gmu.bin`（GMU v2.0.261）
    + `a630_sqe.fw`（去 4 字节头后版本 0x190，达标）；首次 `-2` 是
    `adreno_request_fw` 先试 `request_firmware_direct` 的时序回退。
  - **不是 `drm.debug`**：曾从 `production-7.2.cmdline` 移除 `drm.debug=0x1e`
    并实测，fault 依旧（该 cmdline 清理仍保留，dmesg 干净很多）。
- 定位：`ADRENO_VM_START = 0x100000000`（4GB），a640 带 `ADRENO_QUIRK_4GB_VA`，
  用户 VM 范围 `[4GB, 8GB)`；fault 地址 `0x106690000`（4GB+107MB）在范围内但
  **那一页未映射** → 某个 BO 被 unmount/unmap 后 CCU（2D blit / resolve 的颜色缓存）
  仍在读它。6.14 同 Mesa 无此 fault，7.2 msm（`msm_gem_vma.c` 等 6.14→7.2 大改）
  才有 → 属 7.2 msm/GEM-VM 行为。
- 影响：驱动自动 hangcheck 恢复，GPU 继续可用；主要是日志噪声 / 偶发闪一下。
- 处置：暂不改（深挖需 bisect 6.14→7.2 的 msm 改动，或对照 Mesa）。已在文档记录，
  若后续出现可见异常再跟进。

### 2026-09-24 GPU fault 排查：移除 cmdline 的 drm.debug=0x1e —— 已应用（清理，非根因）
- 现象：7.2.7 上 boot 时 GPU 报翻译 fault 并 hangcheck 恢复：
  `*** gpu fault: ... iova=0000000106690000 dir=READ type=TRANSLATION source=CCU`
  → `[drm:recover_worker] hangcheck recover!`，offending task 均为
  `gnome-shell (--mode=gdm)`。**每次 IOVA 都是同一个 `0x106690000`**；boot -2 上
  周期性复发（8/20 分钟间隔）。
- 对比：同一天的 6.14.11 启动（boot -3）**0 次 fault**；7.2 启动（boot -2/-1/0）
  均有。两者关键差异之一是 **7.2 的 `production-7.2.cmdline` 多了
  `drm.debug=0x1e`**（verbose DRM 调试，也是满屏 `[drm:...]` 的来源），6.14 的
  cmdline 没有。全量 DRM debug 会大幅拖慢/改变 GPU、KMS、atomic 路径时序。
- 另确认 **GPU 固件不缺**：GPU 是 Adreno 640（SM8150），加载 `a640_gmu.bin`
  （GMU v2.0.261）+ `a630_sqe.fw`（去掉 4 字节头后版本 0x190，达标）；日志里的
  首次 `-2` 是 `adreno_request_fw` 先试 `request_firmware_direct` 的时序回退。
- 处置：从 `nabu-main/config/production-7.2.cmdline` 移除 `drm.debug=0x1e`，
  重打 UKI 并安装（保留，dmesg 干净很多）。
- 验证：**重启实测 fault 依旧** → 排除 drm.debug；根因见上一条（7.2 msm 行为）。

### 2026-09-24 SLPI SDSP 高 IOVA workaround 移植 —— 已应用，已实机验证
- 现象：上一条修复后 `msm/slpi/root_pd` 已能上报 up，但 `sensor_process` PD 仍崩：
  `EX:sensor_process:0x1:frpck_0_0:0x5a:PC=0xb218b1a8` /
  `USER-PD DOG detects stalled initialization`，hexagonrpcd `INIT_ATTACH_SNS`
  报 `Broken pipe`（attach 期间 SLPI 崩溃 → `-EPIPE`），SLPI 反复恢复。
- 根因：SM8150 的 SDSP 期望 fastrpc buffer 落在「bit32 以上编码 sid」的高 IOVA 窗口。
  7.2 上游只用 `fastrpc_sid_offset()` 加偏移，**没有在 SMMU 里映射该高地址**，
  DSP 一访问就 fault。6.14 的 patch 用 `fastrpc_buf_map_sdsp_alias()` 映射别名，
  这部分之前没移植。
- 修复（`linux-7.2/drivers/misc/fastrpc.c`）：
  - `struct fastrpc_buf` 增加 `alias_domain/alias_iova/alias_size`；
    `fastrpc_buf_free()` 先 `iommu_unmap` 别名；
  - 新增 `fastrpc_buf_map_sdsp_alias()`（`iommu_get_domain_for_dev` +
    `iommu_iova_to_phys` + `iommu_map` 映射 `dma_addr + (sid<<32)`）；
  - `fastrpc_buf_alloc()`：当 `sdsp_iova_workaround` 时走别名映射，否则维持
    `fastrpc_sid_offset()`；
  - `struct fastrpc_channel_ctx` 增加 `sdsp_iova_workaround`；
    `fastrpc_rpmsg_probe()` 在 `SDSP_DOMAIN_ID && qcom,sm8150` 时置位。
  - 补 `#include <linux/dma-map-ops.h>` / `<linux/iommu.h>`。
- 验证：`fastrpc.ko` 编译通过；**待实机确认 `sensor_process` 不再崩、
  hexagonrpcd 正常 attach、SLPI 传感器可用**。
  - 实机（2026-09-24 15:47，免重启重载 fastrpc）：出现
    `enabling SM8150 SDSP high-IOVA workaround`；`sensor_process` 停止崩溃，
    SLPI 稳定；`hexagonrpcd` active；`ssccli --sensor accelerometer` 有数据
    （`X=7.5 Y=-0.33 Z=6.44 m/s²`）、`--sensor light` `93.3 Lux`；
    D-Bus `HasAccelerometer=true`、`HasAmbientLight=true`。**SLPI/SSC 栈恢复。**

### 2026-09-24 SLPI servreg 根因修复：qcom_pd_mapper 缺 SM8150 SLPI 域 —— 已应用，已实机验证
- 现象：上一条 fastrpc PDR 等待补上后，重启仍失败，且 lookup 直接报
  `PDR: service lookup for tms/servreg failed: -6`（-ENXIO），root PD 永远不上报 up。
- 根因（两个）：
  1. **7.2 树 `qcom_pd_mapper.c` 的 `sm8150_domains[]` 漏了 `slpi_root_pd` /
     `slpi_sensor_pd`**（上游 sm8150 数组里没有；6.14 的 patch 加过）。于是内核
     servreg 服务对 `tms/servreg` 返回的域列表里没有 `msm/slpi/root_pd`，
     `pdr_locate_service()` 返回 -ENXIO。（此前误以为"7.2 已有"，实为
     sm8250/sm8350 的数组，非 sm8150。）
  2. 系统里还跑着一个 **userspace `pd-mapper.service`**
     （`protection-domain-mapper` 包，随 `apt install hexagonrpcd` 拉入），
     它注册同一个 `tms/servreg` locator，但从 `/lib/firmware/` 读 JSON，
     而本机**没有任何 JSON**，只会返回空域列表，形成抢答干扰。
- 修复：
  - `linux-7.2/drivers/soc/qcom/qcom_pd_mapper.c`：给 `sm8150_domains[]` 补
    `&slpi_root_pd, &slpi_sensor_pd`。
  - `nabu-accelerometer/libexec/install-hexagonrpcd.sh`：安装 hexagonrpcd 后
    `systemctl disable --now pd-mapper.service` + `systemctl mask`，改由内核
    `qcom_pd_mapper` 提供 servreg 服务。
- 验证：`qcom_pd_mapper.ko` 编译通过；**待实机确认 `protection domain ... is up`
  且 hexagonrpcd/SLPI 正常**。

### 2026-09-24 音频 CS35L41 开机自动加载 —— 已应用，待实机验证
- 现象：7.2.7 开机声卡不注册，`platform sound: deferred probe pending:
  snd-sm8150: Speaker Playback: codec dai not found`；4 颗功放 I2C 设备
  `2-0040..2-0043` 存在但 `snd-soc-cs35l41-i2c` 未加载。手动
  `modprobe snd-soc-cs35l41-i2c` 后声卡正常（`0 [X5]: sm8150 - Xiaomi Pad 5`）。
- 修复：新增 `nabu-audio/config/nabu-audio.conf`（内容 `snd-soc-cs35l41-i2c`），
  并在 `nabu-audio/nabu-module.toml` 声明 `modules_load` 及安装映射
  `"modules_load/nabu-audio.conf" = "/etc/modules-load.d/nabu-audio.conf"`，
  由 systemd-modules-load 在开机时显式加载。
- 遗留：加载后有 `cs35l41 2-0040: Mixed provider/consumer mode unsupported` /
  `snd_soc_dai_set_fmt() on cs35l41-pcm (-22)`，播放是否受影响待测。

### 2026-09-24 SLPI fastrpc PDR 等待移植 —— 已应用，待实机验证
- 现象：SLPI `sensor_process` 反复崩溃并触发 remoteproc 恢复循环
  （crash #30、#31 …）：
  `qcom_q6v5_pas 2400000.remoteproc: fatal error received:
  err_qdi.c:964:EF:sensor_process:0x1:TMR_CLNT_1:0x80:dog_virtual_user.c:240:
  USER-PD DOG detects stalled initialization`。
- 根因：`nabu-accelerometer/patches/0001-sm8150-slpi-fastrpc-pdr.patch` 给 fastrpc
  增加了 `qcom,protection-domain`（`tms/servreg` / `msm/slpi/root_pd`）PDR 等待：
  必须在 SLPI root PD ready 之后才 attach sensors PD。7.2 分支 `apply=false`，
  模块 patch 不会应用，`linux-7.2/drivers/misc/fastrpc.c` 缺少该逻辑
  （DT 里已有 `qcom,protection-domain`，但驱动不读）。
- 修复（手工移植进 7.2 树 `drivers/misc/fastrpc.c`）：
  - 新增 `fastrpc_attach_pd_status/init/release`（`#if
    IS_REACHABLE(CONFIG_QCOM_PDR_HELPERS)`，配置为 `=y`）；
  - `struct fastrpc_channel_ctx` 增加 `dev`/`attach_pdr`/`attach_pdr_service`/
    `attach_pd_wait`/`attach_pd_up`；
  - `fastrpc_init_attach()` 在 `SENSORS_PD` 且 PDR 未 up 时
    `wait_event_interruptible_timeout()` 等待（`FASTRPC_ATTACH_PD_TIMEOUT=15s`）；
  - `fastrpc_rpmsg_probe()` 初始化等待队列并注册 PDR lookup，错误路径释放；
    `fastrpc_rpmsg_remove()` 唤醒等待并释放 PDR；
  - 同步补 `Documentation/devicetree/bindings/misc/qcom,fastrpc.yaml`。
  - **未移植** 6.14 patch 里的 SDSP IOVA workaround：7.2 上游已用
    `fastrpc_sid_offset()` 处理 SID 前缀 IOVA。
  - `qcom_pd_mapper.c` 的 `slpi_root_pd`/`slpi_sensor_pd` 在 7.2 已存在，无需改。
- 验证：`fastrpc.ko` 编译通过；**待实机确认 SLPI 不再崩溃循环、hexagonrpcd 正常**。

### 2026-09-24 触摸 IRQ GPIO 解析修复 —— 已应用，待实机验证
- 文件：`drivers/input/touchscreen/nt36523/nt36xxx.c`
- 现象：7.2.7 下 `nt36523_ts` 探测失败，日志
  `[NVT-ts-spi] nvt_ts_probe 1483: request irq failed. ret=-22`
  （6.14 下为 `request irq 251 succeed`），触摸不可用。
- 根因：7.2 移除了 `linux/of_gpio.h` / `of_get_named_gpio()`，移植时机械替换为
  `devm_gpiod_get_index(dev, "novatek,irq-gpio", 0, GPIOD_ASIS)`，但第二个参数是
  **consumer id**，gpiod 会去找 `novatek,irq-gpio-gpios`（不存在）→ 返回错误 →
  `gpio_to_irq()` 得到无效值 → `request_threaded_irq()` 返回 `-EINVAL`。
- 修复：`nvt_of_get_named_gpio()` 改为
  `fwnode_gpiod_get_index(of_fwnode_handle(np), con_id, index, GPIOD_ASIS, "NVT-touch")`
  → `desc_to_gpio()` 取回 legacy GPIO 号 → `gpiod_put()` 释放描述符，从而保留驱动
  原有的 `gpio_request_one()` / `gpio_to_irq()` / `gpio_free()` 流程不变。
  调用点传 consumer id：`"novatek,irq"`（对应属性 `novatek,irq-gpio`）；
  reset 同理传 `"novatek,reset"`（`NVT_TOUCH_SUPPORT_HW_RST=0`，未编译）。
- 涉及符号均已 `EXPORT_SYMBOL_GPL`：`fwnode_gpiod_get_index`、`gpiod_put`、`desc_to_gpio`。
- 验证：**实机重启（2026-09-24 14:52，`7.2.7-nabu-full #8`）通过**：
  `nvt_parse_dt: novatek,irq-gpio=585`、`request irq 245 succeed`，
  输入设备 `event5 NVTCapacitiveTouchScreen`、`event7 NVTCapacitivePen` 均出现。

### 2026-09-24 触摸 ESD workqueue flags 修复 —— 已应用，待实机验证
- 文件：`drivers/input/touchscreen/nt36523/nt36xxx.c`
- 现象：`alloc_workqueue("nvt_esd_check_wq", WQ_MEM_RECLAIM, 1)` 触发
  `WARNING: kernel/workqueue.c:5851 ... nvt_ts_probe` —— 7.2 要求 workqueue
  必须显式带 `WQ_PERCPU` 或 `WQ_UNBOUND`，否则告警并默认 `WQ_PERCPU`。
- 修复：改为 `WQ_MEM_RECLAIM | WQ_PERCPU`（保持原 per-CPU 语义；
  `event_wq` 已带 `WQ_UNBOUND`，无需改）。
- 验证：待重编安装后确认 dmesg 不再出现该 WARNING。
  已重编安装（2026-09-24 15:0x，模块随 `make install` 更新），**待重启确认**。

### 2026-09-24 回滚 DFPS/seamless 显示改动 —— 已回滚
- 背景：未提交的 display DFPS/seamless 改动参考了
  https://github.com/MCC45TR/nabu-linux-kernel.git（7.2.2 分支：`msm_atomic.c` 28 处、
  `dsi_host.c` 25 处、`dsi_manager.c` 15 处等含 seamless/dfps 逻辑）。
  按要求回滚到不含该参考的 port 提交 `e490383191ba`。
- 处置：改动当时保存在 `git -C linux-7.2 stash@{0}`
  （`DFPS/seamless display work (MCC45TR 7.2.2 referenced) - saved before rollback 2026-09-24-1439`）。
  该 stash 已于 2026-09-26 归档为 tag `archive/stash-dfps-seamless`（`d80f8a23ae6f`）并删除
  （已被 `b0bbb8b6052a` 的 7.2.2 显示栈移植取代）；取回用 `git show`/`git worktree`。
- 备注：为使该 DFPS 代码编译，期间曾临时补
  `include/drm/drm_panel.h`（`drm_panel_funcs.mode_set`）与
  `drivers/gpu/drm/bridge/panel.c`（转发 `adjusted_mode`），随回滚一并撤销。
- 结果：源码与产物中已无 `seamless_dfps` / `TIMING_DB_MODE`。

### 2026-09-24 构建 / 安装
- `#7` 2026-09-24 14:15:24（含 DFPS，已弃用）
- `#8` 2026-09-24 14:40:54（回滚后：port 提交）
- `#8` + 触摸修复：2026-09-24 14:50 重编 `nt36523_ts.ko` 并安装
  （Image 未变仍为 `#8`，仅模块更新）
- `#17` 2026-09-24 23:00:30（含 `dpu_hw_intf.c` timing 探针）
- `#18` 2026-09-24 23:38:18（含 `dpu_encoder_phys_vid.c` enable/post_kickoff 探针；
  `build collect package verify` + `sudo install` 均通过，模块树/UKI 已更新）
- 安装：UKI `/boot/efi/EFI/ubuntu/7.2.7-nabu-full-build1.efi`，UEFI 启动项
  `Boot0008 nabu-7.2.7-nabu-full`（启动顺序置首），模块 `/lib/modules/7.2.7-nabu-full/`。
- 回退：`sudo ./scripts/nabu --product production rollback`

---

## 7.2.7 已知问题
- 触摸 IRQ GPIO 解析 —— **已修，实机验证通过**（见日志最新条目）。
- 音频声卡开机不注册 —— **已修，实机验证通过**：`snd-soc-cs35l41-i2c` 加入
  `/etc/modules-load.d/nabu-audio.conf`，开机自动加载，`0 [X5]: sm8150 - Xiaomi
  Pad 5` 正常出现。加载后仍有 `cs35l41 2-0040: Mixed provider/consumer mode
  unsupported` / `snd_soc_dai_set_fmt() on cs35l41-pcm (-22)`，播放是否受影响待测。
- SLPI sensor PD 崩溃循环 —— **已修，实机验证通过**：`qcom_pd_mapper` 补 SM8150
  SLPI 域 + 停用 userspace pd-mapper + fastrpc PDR 等待 + SM8150 SDSP 高 IOVA
  workaround（见对应日志条目）。SLPI 稳定、hexagonrpcd 正常、传感器可用。
- 触摸 ESD workqueue WARNING —— **修复曾被 7.2.2 触摸移植覆盖（回归）**；2026-09-26
  重新修复（`975cb8026712`，补 `WQ_PERCPU`）并**免重启实机验证通过**（dmesg 不再出现）。
- iris 卸载（`modprobe -r qcom_iris`）在空闲掉电后刷 14 条时钟 `already disabled`/
  `already unprepared` WARNING —— **已修，免重启实机验证通过**（`193edc7dac93`）。
- 相机前后摄**完全不出流**（CSIPHY 漏选 SM8150 lane 寄存器表 + 漏设 `.id`）——
  **已修，免重启实机验证通过**（`linux-7.2` `267c823b5b89`、`50c1e4b6b73a`）；通用拍照
  App（GNOME Snapshot）同时恢复（`nabu-camera` `9fba47d`/`65b3f36`）。3A 的 AE 增益标定
  helper 已实现并验证（`nabu-camera/patches/`），但对这两颗 sensor 属外观改进、未安装。
- 面板初始化 `dsi_cmds2buf_tx ... wait for video done timed out` /
  `dcs ff 10 failed: -110`（`#17` 实测 3 次；同 boot `FIFO_STATUS=0x1ddd*` 4 次）。
  当前最好解释：7.2 在 DSI 视频使能前 `STATUS0.VIDEO_MODE_ENGINE_BUSY` 已置位、
  `VIDEO_MDP_FIFO` 同时 overflow+underflow（见日志最新条目）；"DSI 半宽 vs DPU 全宽
  不匹配"已被 `#17` 的 INTF 寄存器否定。`#18` encoder 探针待重启取数。
  **2026-09-26 更新（已解决）**：根因锁定为「`dsi_sw_reset()` 恢复 bootloader 遗留的
  `VID_MODE_EN`」+「面板内建导致首次 bring-up 时机不对」。修复
  （`dsi_ctrl_disable` 于复位前 + 面板/背光改 `=m` + `GPIO_SHARED` 可关）已提交，
  并在 `#27` 实机重启**验证通过**（`status=4`/`-110` 归零，面板开机即亮；见日志
  最新条目）。
- GPU 固件：**不缺**。`/lib/firmware/qcom/a630_sqe.fw` 存在；开机首次
  `Direct firmware load ... failed -2` 是驱动先试旧路径、随后回退到
  "new location" 成功加载（`a630_sqe.fw` + `a640_gmu.bin`，`GMU v2.0.261`）。
- GPU 开机时有一次地址翻译 fault + hangcheck 恢复（独立于固件，待观察）：
  `*** gpu fault: ... dir=READ type=TRANSLATION source=CCU` →
  `[drm:recover_worker] hangcheck recover!`；之后 GPU 正常（`renderD128` 可用）。
  **2026-09-30 更新**：已抓 dump + 运行时分类，主流是「CCU 读悬空（任何 VM 无映射）地址」
  （ptes L3=0 + gem ABSENT），属 7.2 per-context GPUVM 的 BO 生命周期问题；详见文首
  「2026-09-30 GPU fault 深挖」条目（含常驻抓取/分类工具）。
- `iio-sensor-proxy` 开机时序：**重启确认正常**（`After=hexagonrpcd.service`，
  开机即 active，无需手动重启）。
- 其余 6.14 时代遗留问题见上级 `KNOWN-ISSUES.md`（如 s2idle 后 SLPI 崩溃无法唤醒）。
