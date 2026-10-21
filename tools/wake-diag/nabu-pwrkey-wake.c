// SPDX-License-Identifier: GPL-2.0-only
/*
 * nabu-pwrkey-wake - diagnose the "power key does not wake from s2idle" bug.
 *
 * KNOWN-ISSUES 2.4.26: the suspend/resume itself is fine (an RTC alarm wakes
 * the tablet every time), but pressing the power key does not.  The pwrkey is
 * registered as a wakeup source (driver + SPMI irq_set_wake look correct), so
 * the open question is whether the IRQ is really armed as a wake IRQ when the
 * system goes down.
 *
 * The pwrkey's own ->suspend runs in the device phase, where the USB console
 * (the only serial the tablet has) is already gone and journald is frozen, so
 * its output would be lost whether the tablet wakes or not.  This notifier runs
 * at PM_SUSPEND_PREPARE instead - before the freeze - so its lines are
 * persisted in the journal of the boot, readable after a reset.
 *
 * Build (against the configured output tree of the port):
 *
 *   make -C /path/to/linux-6.14 O=/path/to/nabu-main/out \
 *        ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=$(pwd) modules
 *   insmod nabu-pwrkey-wake.ko irq_num=135      # IRQ from /proc/interrupts
 *
 * Then suspend with the power key and read:
 *
 *   journalctl -k -b -1 | grep nabu-pwrkey-wake
 *
 * It also *forces* enable_irq_wake() so one test tells both things: if the key
 * starts waking the tablet with this module loaded but not without it, the IRQ
 * simply was not armed.
 */

#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kthread.h>
#include <linux/ktime.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/uaccess.h>
#include <linux/notifier.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/suspend.h>

static int irq_num = -1;
static bool fix_pon_timers;
static unsigned int pon_base = 0x840;
module_param(irq_num, int, 0444);
module_param(fix_pon_timers, bool, 0644);
MODULE_PARM_DESC(fix_pon_timers, "raise the PMIC PON S1 timer so a long sleep keeps the power key as a wake source");
MODULE_PARM_DESC(irq_num, "IRQ number of pm8941_pwrkey (see /proc/interrupts)");

static int force_wake;

/*
 * journald writes /dev/kmsg asynchronously, and both the serial console and the
 * network are gone while the tablet sleeps, so a journal-only record can be lost
 * by a hard reset.  Write the answer straight to a file and force it to disk
 * before the suspend proceeds - after that nothing that happens to the tablet
 * can erase it.
 */
#define DIAG_FILE "/var/log/nabu-wake-diag.txt"

static void write_diag(const char *fmt, ...)
{
	struct file *f;
	va_list args;
	char buf[256];
	loff_t pos = 0;
	int n;

	va_start(args, fmt);
	n = vscnprintf(buf, sizeof(buf), fmt, args);
	va_end(args);
	if (n <= 0)
		return;

	f = filp_open(DIAG_FILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (IS_ERR(f))
		return;
	kernel_write(f, buf, n, &pos);
	vfs_fsync(f, 1);	/* the whole point: survive a hard reset */
	filp_close(f, NULL);
}

/*
 * Snapshot the PMIC PON block (read only) before every suspend.  The RTC alarm
 * wakes this tablet through the very same SPMI summary IRQ that a power-key
 * press would use, so the IRQ path is proven good; the open question is whether
 * the PON stops detecting KPDPWR while the PMIC sleeps.
 */
static void pon_snapshot(void)
{
	struct device *dev;
	struct regmap *map;
	unsigned int reg, val;
	char line[512];
	int len;

	dev = bus_find_device_by_name(&platform_bus_type, NULL,
				      "c440000.spmi:pmic@0:pon@800");
	if (!dev) {
		write_diag("pon: device not found\n");
		return;
	}
	map = dev_get_regmap(dev, NULL);
	if (!map && dev->parent)
		map = dev_get_regmap(dev->parent, NULL);
	if (!map && dev->parent && dev->parent->parent)
		map = dev_get_regmap(dev->parent->parent, NULL);
	if (!map) {
		write_diag("pon: no regmap (dev=%s parent=%s)\n", dev_name(dev),
			   dev->parent ? dev_name(dev->parent) : "none");
		put_device(dev);
		return;
	}
	len = scnprintf(line, sizeof(line), "pon:");
	if (fix_pon_timers) {
		/*
		 * The regmap's address space is not the debugfs one: probe the
		 * three plausible bases and keep the S1 timer pair (base+4/5)
		 * that actually reads 0x0f/0x07, then raise it so a long sleep
		 * keeps KPDPWR as a wake source (KNOWN-ISSUES 2.4.26).
		 */
		static const unsigned int bases[] = { 0x40, 0x840, 0x1040 };
		unsigned int i, lo, hi;

		for (i = 0; i < ARRAY_SIZE(bases); i++) {
			if (regmap_read(map, bases[i] + 4, &lo) ||
			    regmap_read(map, bases[i] + 5, &hi))
				continue;
			write_diag("pon: base %#x -> S1 %02x/%02x\n", bases[i],
				   lo & 0xff, hi & 0xff);
			if ((lo & 0xff) == 0x0f && (hi & 0xff) == 0x07) {
				regmap_write(map, bases[i] + 4, 0xff);
				regmap_write(map, bases[i] + 5, 0x07);
				pon_base = bases[i];
				write_diag("pon: S1 timer raised at base %#x\n",
					   pon_base);
				break;
			}
		}
	}
	len = scnprintf(line, sizeof(line), "pon:");
	if (fix_pon_timers) {
		unsigned int old_s1l = 0, old_s1h = 0;

		regmap_read(map, 0x844, &old_s1l);
		regmap_read(map, 0x845, &old_s1h);
		if (old_s1l != 0xff || old_s1h != 0x07) {
			regmap_write(map, 0x844, 0xff);
			regmap_write(map, 0x845, 0x07);
			write_diag("pon: S1 timer %02x/%02x -> ff/07\n",
				   old_s1l, old_s1h);
		}
	}
	for (reg = pon_base + 0; reg <= pon_base + 0x27; reg++) {
		if (regmap_read(map, reg, &val))
			continue;
		len += scnprintf(line + len, sizeof(line) - len, " %03x=%02x",
				 reg, val & 0xff);
	}
	len += scnprintf(line + len, sizeof(line) - len, "\n");
	put_device(dev);
	write_diag("%s", line);
}

static int pwrkey_pm_notify(struct notifier_block *nb, unsigned long action,
			    void *data)
{
	int rc;

	if (action != PM_SUSPEND_PREPARE)
		return NOTIFY_DONE;

	if (irq_num < 0) {
		pr_info("nabu-pwrkey-wake: load with irq_num=<pwrkey irq>\n");
		return NOTIFY_DONE;
	}

	pon_snapshot();
	write_diag("suspend prepare: forcing wake arming on irq %d\n", irq_num);
	pr_info("nabu-pwrkey-wake: forcing wake arming on irq %d\n", irq_num);
	rc = enable_irq_wake(irq_num);
	write_diag("enable_irq_wake(%d) = %d\n", irq_num, rc);
	pr_info("nabu-pwrkey-wake: enable_irq_wake(%d) = %d\n", irq_num, rc);
	force_wake = 1;

	return NOTIFY_DONE;
}

static struct notifier_block pwrkey_pm_nb = {
	.notifier_call = pwrkey_pm_notify,
};

/*
 * Black box: a non-freezable kthread appends a heartbeat plus the current
 * system_state to a file every NABU_HB_PERIOD_MS and forces it to disk.  The
 * freeze does not stop kernel threads and s2idle keeps timers running, so the
 * file keeps growing through a suspend; when the SoC really dies the heartbeat
 * stops, and the last line (with state=4 = SYSTEM_SUSPEND, or 0 right after a
 * resume) plus its timestamp says where and when.
 */
#define HB_FILE "/var/log/nabu-wake-hb.txt"
static unsigned int hb_period_ms = 5000;
module_param(hb_period_ms, uint, 0644);
static struct task_struct *hb_task;

static int nabu_hb_thread(void *unused)
{
	char buf[160];
	loff_t pos = 0;

	while (!kthread_should_stop()) {
		struct file *f = filp_open(HB_FILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
		if (!IS_ERR(f)) {
			int n = scnprintf(buf, sizeof(buf), "hb boottime=%llu state=%d\n",
					  ktime_get_boottime_seconds(), system_state);
			kernel_write(f, buf, n, &pos);
			vfs_fsync(f, 1);
			filp_close(f, NULL);
		}
		msleep(hb_period_ms);
	}
	return 0;
}

static int __init pwrkey_wake_init(void)
{
	int ret = register_pm_notifier(&pwrkey_pm_nb);

	hb_task = kthread_run(nabu_hb_thread, NULL, "nabu-wake-hb");
	if (IS_ERR(hb_task))
		hb_task = NULL;
	return ret;
}

static void __exit pwrkey_wake_exit(void)
{
	unregister_pm_notifier(&pwrkey_pm_nb);
	if (hb_task)
		kthread_stop(hb_task);
	if (force_wake && irq_num >= 0)
		disable_irq_wake(irq_num);
}

module_init(pwrkey_wake_init);
module_exit(pwrkey_wake_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("nabu: report/force the PMIC pwrkey wake IRQ before suspend");
