#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-serial-console.sh - keep a nabu console readable on the host.
#
# The tablet has no separate debug UART, so the only console is the USB gadget
# (console=ttyGS0) on the Type-C port: plug the tablet into the host running
# this script and it enumerates as /dev/ttyACM*.  The script logs to $LOG and
# stays out of the way (start it from a systemd --user unit or a crontab
# @reboot line).
#
#   nabu-serial-console.sh [device] [log]
#
# The port is opened exactly once and then held open until the gadget actually
# goes away.  An earlier version used "read -t 5" and re-opened the port after
# every quiet period; every close drops DTR on the gadget side and the ACM
# console does not survive that cleanly - it logs
#
#   dwc3 a600000.usb: request ... was not queued to ep1in
#
# and the tablet has been seen to freeze right afterwards.  Keeping the fd open
# avoids poking the gadget at all.
#
# Note: this console dies with dwc3 when the system suspends, so it shows the
# boot log, the suspend_prepare phase and any *successful* resume - not a wedge.

PORT=${1:-/dev/ttyACM0}
LOG=${2:-$HOME/nabu-serial.log}
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }

was_up=
while :; do
	if [ ! -e "$PORT" ]; then
		[ "$was_up" = no ] || log "[capture: $PORT absent, waiting]"
		was_up=no
		sleep 2
		continue
	fi
	if [ "$was_up" = no ]; then
		log "[capture: $PORT open, holding it]"
		was_up=yes
	fi
	# cat holds the fd open and only returns when the device is gone (unplug,
	# reboot) or the driver errors out; then the loop re-opens it.
	stdbuf -oL -eL cat "$PORT" 2>/dev/null |
	while IFS= read -r line; do
		printf '%s %s\n' "$(date +%H:%M:%S)" "$line"
	done >> "$LOG"
	log "[capture: reader ended, reopening]"
	sleep 1
done
