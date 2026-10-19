#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-suspend-ab-loop.sh - run real s2idle cycles against a nabu tablet over
# SSH and count how many of them wedge.
#
# A wedged suspend does *not* recover by itself (2.4.21: RuntimeWatchdogUSec=0
# and nothing holds /dev/watchdog), so it still needs a manual long press.  What
# the loop can do is decide the outcome of every round without a console:
#
#   - the tablet is only reachable again if it either resumed (same
#     /proc/sys/kernel/random/boot_id) or was reset and rebooted (different
#     boot_id).  Same boot_id => the suspend returned normally; different or
#     never coming back => that round wedged.
#
# That makes candidate fixes testable statistically, at ~1.5 min per round
# (suspend + wake + WiFi coming back) plus a manual reset whenever a round
# wedges - so keep the runs short and stay near the tablet.  Only valid for the
# "real suspend" configuration: pm_test variants never reproduced the wedge
# (2.4.21).
#
# Usage:
#   nabu-suspend-ab-loop.sh [rounds] [label]
#
# Env:
#   NABU_HOST     ssh target                 (default cfm880@192.168.0.67)
#   NABU_PW       sudo password              (required)
#   NABU_WAKE     RTC wake alarm, seconds    (default 25)
#   NABU_TRAFFIC  1 = keep a BT scan running (default 1)
#   NABU_OUT      log file                   (default /tmp/nabu-ab-<label>.log)
#   NABU_UP_WAIT  max seconds to wait for WiFi to come back (default 900; a
#                 wedge never comes back, so keep someone next to the tablet)
#   NABU_DOWN_WAIT max seconds to wait for the tablet to leave the network
#                 after requesting a suspend (default 60); the request goes
#                 through `systemctl suspend -i` and its output lands in
#                 /tmp/nabu-ab-suspend.log on the tablet

set -u

rounds=${1:-10}
label=${2:-run}
HOST=${NABU_HOST:-cfm880@192.168.0.67}
: "${NABU_PW:?set NABU_PW to the sudo password}"
WAKE=${NABU_WAKE:-25}
TRAFFIC=${NABU_TRAFFIC:-1}
OUT=${NABU_OUT:-/tmp/nabu-ab-$label-$(date +%Y%m%d-%H%M%S).log}
UP_WAIT=${NABU_UP_WAIT:-900}
DOWN_WAIT=${NABU_DOWN_WAIT:-60}

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 $HOST"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT"; }

# Run a command as root on the tablet; empty output means it is unreachable.
root() {
	timeout 20 $SSH "echo '$NABU_PW' | sudo -S -p '' $*" 2>/dev/null
}

up() { timeout 6 $SSH 'true' >/dev/null 2>&1; }

# Cache/refresh the sudo credential; the round then uses `sudo -n`, so the
# backgrounded command needs no stdin (a `</dev/null` on a `sudo -S` call was
# silently swallowing the password and killing every round).
sudov() { timeout 25 $SSH "echo '$NABU_PW' | sudo -S -p '' -v" >/dev/null 2>&1; }

boot_id() { timeout 20 $SSH 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null; }

wait_up() {
	local deadline=$(( $(date +%s) + $1 ))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		up && return 0
		sleep 5
	done
	return 1
}

wait_down() {
	local deadline=$(( $(date +%s) + $1 ))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		up || return 0
		sleep 3
	done
	return 1
}

say "=== $label: $rounds real suspends (wake ${WAKE}s, traffic=$TRAFFIC)"
say "log: $OUT"

wait_up 120 || { say "FATAL: tablet not reachable"; exit 1; }

# Battery/thermal sanity: a wedge reboot loop is not what we want to debug.
root "cat /sys/power/pm_test" | tr -d '\r' | sed 's/^/pm_test: /' | tee -a "$OUT"
bios=$(root "cat /sys/class/power_supply/battery/capacity" | tr -d '\r')
say "battery: ${bios:-?}%"

root "systemctl unmask bluetooth.service; systemctl start bluetooth.service; \
      bluetoothctl power on; evtest >/dev/null 2>&1" >/dev/null 2>&1
timeout 20 $SSH "echo '$NABU_PW' | sudo -S -p '' bluetoothctl show" 2>/dev/null |
	grep -E 'Powered' | sed 's/^/adapter: /' | tee -a "$OUT"

if [ "$TRAFFIC" = 1 ]; then
	root "pkill -f 'bluetoothctl --timeout' ; \
	      setsid nohup bash -c 'while :; do bluetoothctl --timeout 60 scan on >/dev/null 2>&1; done' \
	      >/dev/null 2>&1 < /dev/null & echo traffic-started" >/dev/null 2>&1
	say "BT scan traffic started"
fi

# The desktop's own idle suspend would fire between rounds and look exactly
# like a wedge (unreachable, no reboot).  Turn it off for the graphical session
# (best effort: needs the user's D-Bus session).
for u in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $1}'); do
	uid=$(id -u "$u" 2>/dev/null) || continue
	timeout 20 $SSH "echo '$NABU_PW' | sudo -S -p '' -u $u \
		DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
		gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing" \
		>/dev/null 2>&1 && say "idle suspend disabled for $u"
	timeout 20 $SSH "echo '$NABU_PW' | sudo -S -p '' -u $u \
		DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
		gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type nothing" \
		>/dev/null 2>&1
done

ok=0
wedge=0
refused=0
wedged_rounds=

for i in $(seq 1 "$rounds"); do
	wait_up 240 || { say "round $i: tablet never came back - stopping"; break; }
	before=$(boot_id)
	[ -n "$before" ] || { say "round $i: no boot_id - stopping"; break; }

	# Fire and forget: the SSH session dies with the WiFi, the suspend does not.
	# -i ignores the sleep inhibitors GNOME/NetworkManager/UPower install,
	# which otherwise make logind refuse the request (2026-10-19: 7 inhibitors
	# turned every round into a silent no-op); keep the output visible.
	sudov
	timeout 20 $SSH "sudo -n setsid nohup sh -c 'rtcwake -m no -s $WAKE; \
	      systemctl suspend -i' >/tmp/nabu-ab-suspend.log 2>&1 < /dev/null &" \
	      >/dev/null 2>&1

	if wait_down "$DOWN_WAIT"; then
		: # off the network: suspend (or wedge) is in progress
	else
		refused=$((refused + 1))
		say "round $i: refused (tablet stayed reachable)"
		continue
	fi

	if wait_up "$UP_WAIT"; then
		after=$(boot_id)
		if [ "$after" = "$before" ]; then
			ok=$((ok + 1))
			say "round $i: OK (same boot)"
		else
			wedge=$((wedge + 1))
			wedged_rounds="$wedged_rounds $i"
			say "round $i: *** WEDGED *** (watchdog rebooted the tablet)"
		fi
	else
		wedge=$((wedge + 1))
		wedged_rounds="$wedged_rounds ${i}?"
		say "round $i: *** WEDGED *** (still unreachable after ${UP_WAIT}s)"
	fi
done

say "=== $label: $ok/$rounds returned, $wedge wedged, $refused refused"
say "wedged rounds:$wedged_rounds"
[ "$TRAFFIC" = 1 ] && root "pkill -f 'bluetoothctl --timeout'" >/dev/null 2>&1
exit 0
