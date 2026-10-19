#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-suspend-ab.sh - A/B driver for the intermittent device-suspend hang
# (KNOWN-ISSUES 2.4.17/2.4.18/2.4.19).
#
# The hang happens inside the device-suspend phase while `c8c000.serial` (the
# Bluetooth UART, /dev/ttyHS0) is held open by the BT stack: `pm_test=devices`
# wedges about 50% of the time and the whole tablet dies (frozen tasks, no
# console, no journal).  Run one variant per boot, count the rounds you get
# through, then compare variants.
#
#   nabu-suspend-ab.sh <variant> [rounds]
#
# Variants (see the KNOWN-ISSUES 2.4.19 section for what each one is meant to
# discriminate):
#
#   baseline        BT enabled and running (the ~50% hang configuration)
#   bt-masked       bluetooth.service stopped + masked (the 2.4.17 stable config)
#   bt-stop         bluetooth.service stopped, port left as hci_uart left it
#   bt-stop-open    as bt-stop, plus /dev/ttyHS0 held open from userspace
#   bt-nocrtscts    BT running, but /dev/ttyHS0 switched to -crtscts
#   qca-unbind-open hci_uart_qca unbound, /dev/ttyHS0 held open (no BT code at
#                   all, but the geni port is still open/initialized)
#
# `bt-stop-open` vs `qca-unbind-open` splits "geni port open" from "the hci_qca
# stack is alive"; `bt-nocrtscts` splits "SE TX DMA stalled on CTS" from "a
# write lands after the SE resources are gated".
#
# Each round prints a marker to /dev/kmsg (all consoles + journal) before and
# after, and the summary greps the kernel log for the geni/qca messages that
# say the SE was grumpy.  A wedged round cannot be detected by this script: the
# machine is gone, so power-cycle it (long press), reboot, and run the same
# variant again.  The console marker tells you the round it died in if you have
# a console that survives device suspend (`console=ttyMSM0 no_console_suspend`,
# see the section in KNOWN-ISSUES).
#
# Needs root.  Touches only sysfs, systemd units, the serdev bind/unbind knobs
# and /dev/ttyHS0; it never modifies the kernel or the image.

set -u

HS_TTY=${NABU_HS_TTY:-/dev/ttyHS0}
LOG_DIR=${NABU_SUSPEND_AB_LOGDIR:-/var/log/nabu-suspend-ab}
BETWEEN_ROUNDS=${NABU_SUSPEND_AB_DELAY:-3}
QCA_DRV=/sys/bus/serial/drivers/hci_uart_qca

usage() {
	sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-1}"
}

die() { echo "nabu-suspend-ab: $*" >&2; exit 1; }

kmsg() { printf 'nabu-suspend-ab: %s\n' "$*" > /dev/kmsg 2>/dev/null || true; }
say() { printf '%s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -w /sys/power/state ] || die "/sys/power/state is not writable"
[ -w /sys/power/pm_test ] || die "/sys/power/pm_test not available (CONFIG_PM_DEBUG?)"

variant=${1:-}
rounds=${2:-10}
[ -n "$variant" ] || usage
case "$variant" in baseline|bt-masked|bt-stop|bt-stop-open|bt-nocrtscts|qca-unbind-open) ;; *) usage ;; esac
case "$rounds" in ''|*[!0-9]*) die "rounds must be a number" ;; esac

hold_fd=
hold_open() {
	# Keep the tty "initialized" without writing to it, so uart_suspend_port()
	# takes the slow path (stop_tx/shutdown) - i.e. the same geni entry points
	# that the hang is suspected to be in.
	[ -e "$HS_TTY" ] || die "$HS_TTY does not exist - is the UART bound?"
	exec {hold_fd}<>"$HS_TTY" || die "cannot open $HS_TTY"
	say "holding $HS_TTY open (fd $hold_fd)"
}

bt_state() {
	systemctl is-active bluetooth 2>/dev/null || true
}

setup() {
	say "=== variant: $variant"
	say "before: bluetooth=$(bt_state)"
	case "$variant" in
	baseline)
		systemctl unmask bluetooth.service 2>/dev/null || true
		systemctl start bluetooth.service 2>/dev/null || true
		;;
	bt-masked)
		systemctl stop bluetooth.service 2>/dev/null || true
		systemctl mask bluetooth.service 2>/dev/null || true
		;;
	bt-stop|bt-stop-open|bt-nocrtscts)
		systemctl unmask bluetooth.service 2>/dev/null || true
		if [ "$variant" = bt-stop ] || [ "$variant" = bt-stop-open ]; then
			systemctl stop bluetooth.service 2>/dev/null || true
		else
			systemctl start bluetooth.service 2>/dev/null || true
		fi
		[ "$variant" = bt-stop-open ] && hold_open
		if [ "$variant" = bt-nocrtscts ]; then
			[ -e "$HS_TTY" ] || die "$HS_TTY does not exist"
			echo "stty: $(stty -F "$HS_TTY" -crtscts 2>&1)"
			stty -F "$HS_TTY" -a | tr ' ' '\n' | grep -E 'crtscts|^-crtscts' || true
		fi
		;;
	qca-unbind-open)
		systemctl stop bluetooth.service 2>/dev/null || true
		systemctl unmask bluetooth.service 2>/dev/null || true
		qca_dev=$(ls -l "$QCA_DRV" 2>/dev/null | awk '/^l/ {print $9}' | head -1)
		[ -n "${qca_dev:-}" ] || die "no device bound to hci_uart_qca"
		say "unbinding $qca_dev from hci_uart_qca"
		echo "$qca_dev" > "$QCA_DRV/unbind" || die "unbind failed"
		hold_open
		;;
	esac
	say "after:  bluetooth=$(bt_state)"
}

restore() {
	# Leave the tablet in the shipped configuration: BT masked (2.4.17).
	say "=== restore: bluetooth masked (the shipped config)"
	if [ -n "${hold_fd:-}" ]; then exec {hold_fd}>&- 2>/dev/null || true; fi
	if [ "$variant" = qca-unbind-open ] && [ -n "${qca_dev:-}" ]; then
		echo "$qca_dev" > "$QCA_DRV/bind" 2>/dev/null || true
	fi
	systemctl stop bluetooth.service 2>/dev/null || true
	systemctl mask bluetooth.service 2>/dev/null || true
}

enable_debug() {
	# initcall_debug is a core_param: writable at runtime, otherwise ask for it
	# on the command line.
	if [ -w /sys/module/kernel/parameters/initcall_debug ]; then
		echo Y > /sys/module/kernel/parameters/initcall_debug
	else
		say "note: initcall_debug is not writable here; add initcall_debug to the cmdline"
	fi
	[ -w /sys/power/pm_print_times ] && echo Y > /sys/power/pm_print_times
	[ -w /sys/power/pm_debug_messages ] && echo Y > /sys/power/pm_debug_messages
	echo devices > /sys/power/pm_test
	say "pm_test=$(cat /sys/power/pm_test) pm_print_times=$(cat /sys/power/pm_print_times 2>/dev/null)"
}

summary() {
	local log=$1
	say "--- geni/BT messages seen in the kernel log:"
	grep -nE 'geni|hci_qca|Unable to drain transmitter|M_CMD_ABORT_EN not set|TX DMA reset failed|Failed to send SLEEP|SSR or FW download time out|nobody cared|PM: suspend of device.*(c8c000|a600000)' "$log" |
		tail -n 40 || say "  (none)"
	say "--- slowest device suspends of the whole run:"
	grep -oE 'PM: suspend of device .* \([a-z0-9_]+\) \[[0-9.]+ ms\]' "$log" 2>/dev/null | sort -t'[' -k2 -rn | head -8 ||
		grep -E 'suspend of device' "$log" | tail -8
}

main() {
	local stamp log i
	stamp=$(date +%Y%m%d-%H%M%S)
	mkdir -p "$LOG_DIR"
	log=$LOG_DIR/$variant-$stamp.log

	setup
	enable_debug
	trap 'restore' EXIT

	say ""
	say "Starting $rounds rounds of pm_test=devices."
	say "If the machine wedges, long-press power, boot, then reboot-into this"
	say "variant and count how many rounds you got.  Log: $log"
	say ""

	for i in $(seq 1 "$rounds"); do
		kmsg "round $i/$rounds starting (variant $variant)"
		printf '\n######## round %d/%d (%s) %s ########\n' \
			"$i" "$rounds" "$variant" "$(date +%FT%T)" >> "$log"
		if echo mem > /sys/power/state 2>>"$log"; then
			kmsg "round $i/$rounds completed"
			say "round $i/$rounds: OK"
		else
			kmsg "round $i/$rounds FAILED to suspend"
			say "round $i/$rounds: suspend refused (see $log)"
		fi
		# collect what this round produced
		dmesg 2>/dev/null | tail -n 400 >> "$log"
		sleep "$BETWEEN_ROUNDS"
	done

	kmsg "variant $variant finished $rounds rounds"
	say ""
	say "=== $variant: $rounds/$rounds rounds completed"
	summary "$log"
	say "full log: $log"
}

main "$@"
