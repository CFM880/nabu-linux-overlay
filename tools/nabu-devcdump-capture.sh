#!/bin/bash
# Capture msm GPU devcoredumps before the kernel recycles them.
#
# The kernel creates /sys/class/devcoredump/devcdN/data on a GPU fault/hang.
# DEVCD_TIMEOUT is only 5 minutes, so a dump silently disappears if nobody
# reads it in time.  This loop polls and copies any *new* dump to a persistent
# location immediately.  Each dump gets a new devcdN, so we remember the ones
# we have already taken (the data file can stay readable for a while).
#
# Installed by: /etc/systemd/system/nabu-devcdump-capture.service
set -u

DEST=${NABU_DUMP_DIR:-/var/log/nabu-gpu-dumps}
STATE=${NABU_DUMP_STATE:-/run/nabu-devcdump-seen}
mkdir -p "$DEST" "$STATE" 2>/dev/null || exit 1

log() { logger -t nabu-devcdump -- "$*" 2>/dev/null || true; }

log "started, capturing to $DEST"

while :; do
	for d in /sys/class/devcoredump/devcd*/data; do
		# glob leaves the pattern literally when nothing matches
		[ -e "$d" ] || continue

		name=$(basename "$(dirname "$d")")
		[ -e "$STATE/$name" ] && continue

		up=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
		out="$DEST/${name}-$(date +%Y%m%d-%H%M%S)-up${up}s.txt"

		if cat "$d" > "$out" 2>/dev/null; then
			sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
			if [ "${sz:-0}" -gt 0 ]; then
				touch "$STATE/$name"
				log "captured $out ($sz bytes): $(grep -m1 '^comm:' "$out" 2>/dev/null)"
				# keep only the newest 20 captures
				ls -t "$DEST"/devcd*.txt 2>/dev/null | tail -n +21 | xargs -r rm -f
			else
				rm -f "$out"
			fi
		else
			rm -f "$out"
		fi
	done
	sleep 0.2
done
