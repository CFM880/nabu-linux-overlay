#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-serial-console.sh - keep a nabu console readable on the host.
#
# The tablet has no separate debug UART, so the only console is the USB gadget
# (console=ttyGS0) on the Type-C port: plug the tablet into the host running
# this script and it enumerates as /dev/ttyACM*.  The script reopens the port
# across unplug/replug and host reboots (start it from a systemd --user unit or
# a crontab @reboot line), logs to $LOG and stays out of the way.
#
#   nabu-serial-console.sh [device] [log]
#
# Note: this console dies with dwc3 when the system suspends, so it shows the
# boot log, the suspend_prepare phase and any *successful* resume - not a wedge.

PORT=${1:-/dev/ttyACM0}
LOG=${2:-$HOME/nabu-serial.log}
print_t() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }
was_up=
while :; do
	if [ ! -e "$PORT" ]; then
		[ "$was_up" = no ] || print_t "[capture: $PORT absent, waiting]"
		was_up=no; sleep 3; continue
	fi
	stty -F "$PORT" 115200 raw -echo -crtscts clocal 2>/dev/null
	if [ "$was_up" = no ]; then
		print_t "[capture: $PORT open @115200]"; was_up=yes
	fi
	# Bounded reads: after a host reboot the old fd stays "open" but never
	# returns data, so a plain `while read` would sit there forever.
	while IFS= read -r -t 5 line; do
		printf '%s %s\n' "$(date +%H:%M:%S)" "$line"
	done < "$PORT" >> "$LOG" 2>/dev/null
	print_t "[capture: read timed out or EOF, reopening]"
	sleep 1
done
