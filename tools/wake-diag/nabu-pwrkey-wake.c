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

#include <linux/interrupt.h>
#include <linux/irq.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/suspend.h>

static int irq_num = -1;
module_param(irq_num, int, 0444);
MODULE_PARM_DESC(irq_num, "IRQ number of pm8941_pwrkey (see /proc/interrupts)");

static int force_wake;

static int pwrkey_pm_notify(struct notifier_block *nb, unsigned long action,
			    void *data)
{
	struct irq_data *d;
	int rc;

	if (action != PM_SUSPEND_PREPARE)
		return NOTIFY_DONE;

	if (irq_num < 0) {
		pr_info("nabu-pwrkey-wake: load with irq_num=<pwrkey irq>\n");
		return NOTIFY_DONE;
	}

	d = irq_get_irq_data(irq_num);
	if (!d) {
		pr_info("nabu-pwrkey-wake: irq %d has no irq_data\n", irq_num);
		return NOTIFY_DONE;
	}

	pr_info("nabu-pwrkey-wake: irq %d armed=%d forcing\n", irq_num,
		irqd_is_wakeup_set(d));
	rc = enable_irq_wake(irq_num);
	pr_info("nabu-pwrkey-wake: enable_irq_wake(%d) = %d, armed=%d\n",
		irq_num, rc, irqd_is_wakeup_set(d));
	force_wake = 1;

	return NOTIFY_DONE;
}

static struct notifier_block pwrkey_pm_nb = {
	.notifier_call = pwrkey_pm_notify,
};

static int __init pwrkey_wake_init(void)
{
	return register_pm_notifier(&pwrkey_pm_nb);
}

static void __exit pwrkey_wake_exit(void)
{
	unregister_pm_notifier(&pwrkey_pm_nb);
	if (force_wake && irq_num >= 0)
		disable_irq_wake(irq_num);
}

module_init(pwrkey_wake_init);
module_exit(pwrkey_wake_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("nabu: report/force the PMIC pwrkey wake IRQ before suspend");
