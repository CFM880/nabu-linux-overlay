#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-suspend-ab.sh - A/B driver for the intermittent s2idle wedge
# (KNOWN-ISSUES 2.4.17/2.4.18/2.4.19/2.4.20).
#
#   nabu-suspend-ab.sh <variant> [rounds]
#
# Variants (the first pair is the decisive one - it splits "before the freeze"
# from "device suspend"):
#
#   devices-bt        pm_test=devices, Bluetooth adapter powered on
#   freezer-bt        pm_test=freezer, Bluetooth adapter powered on
#   devices-nobt      pm_test=devices, bluetooth.service stopped (2.4.17 control)
#   freezer-nobt      pm_test=freezer, bluetooth.service stopped
#
# `pm_test=freezer` runs suspend_prepare() (console, the PM_SUSPEND_PREPARE
# notifier chain - where the BT stack's hci_suspend_notifier lives - and the
# task freeze) and then rolls back without suspending a single device.  If the
# wedge shows up in freezer-bt it is *not* a device-suspend problem at all; if
# only devices-bt wedges, it is.
#
# Trying to power the adapter on requires a boot in which the QCA firmware
# download succeeded ("QCA setup on UART is completed" in the log).  This is
# flaky on nabu (some boots the chip never answers and bluetoothd only gets
# "command 0xfc00 tx timeout"); the *-bt variants warn and refuse to run when
# that happened, because a wedged round is then not reachable.  A failed
# firmware download also leaves QCA_IBS_DISABLED set, which makes every later
# suspend *abort* after ~3 s in qca_suspend() (-110) - that is not the wedge.
#
# Diagnostics enabled automatically: initcall_debug, pm_print_times,
# pm_debug_messages, and dynamic debug for the Bluetooth stack.  Because the
# adapter's suspend notifier runs before the task freeze, its debug messages
# reach the journal - so after a wedged round `journalctl -k -b -1` on the next
# boot shows how far the BT suspend path got.  A wedge *after* the freeze
# leaves nothing, which is itself the answer.
#
# A wedged round cannot be detected by this script: the tablet is gone and only
# a long press helps.  Reboot, count the rounds you got, run the same variant
# again.  Needs root; touches sysfs, dynamic debug, systemd units and
# bluetoothctl only.

set -u

LOG_DIR=${NABU_SUSPEND_AB_LOGDIR:-/var/log/nabu-suspend-ab}
BETWEEN_ROUNDS=${NABU_SUSPEND_AB_DELAY:-5}
DD=/sys/kernel/debug/dynamic_debug/control

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
die() { echo "nabu-suspend-ab: $*" >&2; exit 1; }
kmsg() { printf 'nabu-suspend-ab: %s\n' "$*" > /dev/kmsg 2>/dev/null || true; }
say() { printf '%s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -w /sys/power/state ] || die "/sys/power/state is not writable"
[ -w /sys/power/pm_test ] || die "/sys/power/pm_test not available (CONFIG_PM_DEBUG?)"

variant=${1:-}
rounds=${2:-10}
[ -n "$variant" ] || usage
case "$variant" in devices-bt|freezer-bt|devices-nobt|freezer-nobt) ;; *) usage ;; esac
case "$rounds" in ''|*[!0-9]*) die "rounds must be a number" ;; esac

stage=${variant%%-*}
case "$stage" in devices|freezer) ;; *) die "bad stage" ;; esac
want_bt=yes
case "$variant" in *-nobt) want_bt=no ;; esac

qca_setup_ok() { dmesg 2>/dev/null | grep -q 'QCA setup on UART is completed'; }
adapter_powered() { busctl get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered 2>/dev/null | grep -q true; }

enable_debug() {
	[ -w /sys/module/kernel/parameters/initcall_debug ] &&
		echo Y > /sys/module/kernel/parameters/initcall_debug
	[ -w /sys/power/pm_print_times ] && echo Y > /sys/power/pm_print_times
	[ -w /sys/power/pm_debug_messages ] && echo Y > /sys/power/pm_debug_messages
	echo "$stage" > /sys/power/pm_test
	if [ -w "$DD" ]; then
		# The BT suspend path: notifier in hci_core.c, the command
		# sequences in hci_sync.c, and the Qualcomm/serdev glue.
		for f in hci_core.c hci_sync.c hci_qca.c hci_uart.c hci_serdev.c; do
			echo "file $f +p" > "$DD" 2>/dev/null || true
		done
		say "dynamic debug: $(grep -c '=p' "$DD" 2>/dev/null) rules enabled"
	fi
	say "pm_test=$(cat /sys/power/pm_test) pm_print_times=$(cat /sys/power/pm_print_times 2>/dev/null) pm_debug_messages=$(cat /sys/power/pm_debug_messages 2>/dev/null)"
}

setup() {
	say "=== variant: $variant"
	say "bluetooth.service: $(systemctl is-active bluetooth 2>/dev/null)"
	say "adapter powered:    $(adapter_powered && echo yes || echo no)"
	say "QCA fw download ok: $(qca_setup_ok && echo yes || echo no)"
	if [ "$want_bt" = yes ]; then
		[ "$(qca_setup_ok && echo yes || echo no)" = yes ] ||
			die "the QCA firmware download did not complete this boot - a
  wedged round is unreachable (suspends will only abort with -110).
  Reboot until 'QCA setup on UART is completed' appears, then re-run."
		systemctl unmask bluetooth.service 2>/dev/null || true
		systemctl start bluetooth.service 2>/dev/null || true
		bluetoothctl power on >/dev/null 2>&1 || true
		sleep 2
		adapter_powered ||
			say "WARNING: the adapter did not power on; do not expect a wedge"
	else
		systemctl stop bluetooth.service 2>/dev/null || true
		bluetoothctl power off >/dev/null 2>&1 || true
	fi
	say "adapter powered now: $(adapter_powered && echo yes || echo no)"
}

summary() {
	local log=$1
	say "--- BT/QCA and suspend messages of this run:"
	grep -E 'Bluetooth: hci0|hci_uart_qca|qca_suspend|SSR or FW|geni|drain|ABORT|nobody cared|suspend (entry|exit)|aborted|Freezing' "$log" |
		tail -n 30 || say "  (none)"
	say "--- slowest device suspends of the whole run:"
	grep -E 'suspend of device' "$log" | tail -8 || true
}

main() {
	local stamp log i ok=0
	stamp=$(date +%Y%m%d-%H%M%S)
	mkdir -p "$LOG_DIR"
	log=$LOG_DIR/$variant-$stamp.log

	setup
	enable_debug

	say ""
	say "Starting $rounds rounds of pm_test=$stage ($variant)."
	say "A wedged round needs a long press; then reboot and re-run this variant,"
	say "counting the rounds that completed.  Afterwards, on the fresh boot:"
	say "    journalctl -k -b -1 | grep -E 'Bluetooth|hci_uart_qca|PM:'"
	say "    journalctl -k -b -1 | tail -20        # last breath of the wedged boot"
	say "Log: $log"
	say ""

	for i in $(seq 1 "$rounds"); do
		kmsg "round $i/$rounds starting (variant $variant)"
		printf '\n######## round %d/%d (%s) %s ########\n' \
			"$i" "$rounds" "$variant" "$(date +%FT%T)" >> "$log"
		if echo mem > /sys/power/state 2>>"$log"; then
			ok=$((ok + 1))
			kmsg "round $i/$rounds completed"
			say "round $i/$rounds: OK"
		else
			kmsg "round $i/$rounds: suspend refused (see log)"
			say "round $i/$rounds: suspend refused (analysis in $log)"
		fi
		dmesg 2>/dev/null | tail -n 300 >> "$log"
		sleep "$BETWEEN_ROUNDS"
	done

	kmsg "variant $variant finished $rounds rounds"
	say ""
	say "=== $variant: $ok/$rounds rounds returned"
	summary "$log"
	say "full log: $log"
}

main "$@"
