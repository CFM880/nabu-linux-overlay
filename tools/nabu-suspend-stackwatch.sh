#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-suspend-stackwatch.sh - catch a stalled s2idle attempt and dump the task
# stacks to a file that survives the reset.
#
# The wedge leaves no console (the console is the USB gadget, which dies with
# the USB controller) and no pstore (ramoops does not survive the reset), so the
# usual "read the last breath" channels are gone.  This watcher works around
# that entirely from userspace and without D-Bus/journald (PID 1 is frozen for
# part of a suspend, so anything that talks to systemd stops working there):
#
#   - it polls `dmesg` (plain syslog(2), no daemon involved) and looks at
#     whether the newest "PM: suspend entry"/"PM: suspend exit" pair is an entry
#     older than NABU_STACKWATCH_STALL seconds;
#
#   - a heartbeat line every few seconds tells, after the reset, whether
#     userspace was still running during the wedge.  If the heartbeat stops at
#     the wedge, the task freeze had been reached (the wedge is in the
#     device-suspend phase and userspace cannot help); if it keeps going, the
#     suspend never reached the freeze, and the dump below is the answer;
#
#   - on a stall it triggers SysRq-w (blocked tasks) and SysRq-t (all tasks) and
#     copies the kernel log - which then holds the stacks of the stuck threads -
#     into a file on disk, so it survives the long-press reset.
#
# Start as root before the experiment, leave it running.  After the reset:
#
#   tail -30 /var/log/nabu-suspend-ab/beat.log      # was userspace alive?
#   grep -nE 'task:|Call trace' /var/log/nabu-suspend-ab/stacks-*.log | head
#   sed -n '1,200p' /var/log/nabu-suspend-ab/stacks-*.log
#
# Deliberately does not read /dev/kmsg in a loop: bash's read -t blocks on it.

set -u

OUT=${NABU_STACKWATCH_DIR:-/var/log/nabu-suspend-ab}
STALL=${NABU_STACKWATCH_STALL:-20}
BEAT_EVERY=${NABU_STACKWATCH_BEAT:-10}

mkdir -p "$OUT"
# SysRq-t/-w need the "debugging aids" bit; 1 enables everything.
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true

beat="$OUT/beat.log"
printf '=== stackwatch started %s (stall=%ss, sysrq=%s, pm_test=%s)\n' \
	"$(date +%FT%T)" "$STALL" "$(cat /proc/sys/kernel/sysrq)" \
	"$(cat /sys/power/pm_test 2>/dev/null)" >> "$beat"

uptime_s() { awk '{ print int($1) }' /proc/uptime; }

# Boot-relative timestamp of the newest occurrence of $1 in dmesg, or empty.
last_ts() {
	dmesg 2>/dev/null |
		grep -oE "\[ *[0-9]+\.[0-9]+\] $1" |
		tail -n 1 |
		awk '{ gsub(/[][[]/,"",$1); print int($1) }'
}

dump() {
	local reason=$1 f
	f="$OUT/stacks-$(date +%Y%m%d-%H%M%S).log"
	{
		echo "=== stalled suspend ($reason) dumped at $(date +%FT%T)"
		echo "=== pm_test=$(cat /sys/power/pm_test 2>/dev/null) sysrq=$(cat /proc/sys/kernel/sysrq)"
		echo "=== suspend_stats:"
		cat /sys/power/suspend_stats 2>/dev/null
	} >> "$f"
	echo w > /proc/sysrq-trigger
	sleep 2
	echo t > /proc/sysrq-trigger
	sleep 3
	dmesg >> "$f" 2>/dev/null
	printf '=== dump finished %s\n' "$(date +%FT%T)" >> "$f"
	printf 'dump %s -> %s\n' "$reason" "$f" >> "$beat"
}

last_beat=0
while :; do
	now=$(uptime_s)

	entry=$(last_ts "PM: suspend entry")
	if [ -n "$entry" ]; then
		exit_=$(last_ts "PM: suspend exit")
		if [ "${exit_:-0}" -lt "$entry" ] &&
		   [ $((now - entry)) -gt "$STALL" ]; then
			dump "no suspend exit within ${STALL}s"
			exit 0
		fi
	fi

	if [ $((now - last_beat)) -ge "$BEAT_EVERY" ]; then
		printf 'beat %s%s\n' "$(date +%FT%T)" \
			"${entry:+ (last suspend entry at ${entry}s)}" >> "$beat"
		last_beat=$now
	fi

	sleep 2
done
