#!/bin/bash
# On every new "*** gpu fault" line, record what /sys/kernel/debug/dri/0/gem
# says about the faulting IOVA (which BO/VMA, mapped or unmapped, size).
#
# Classifies each fault without any kernel patch:
#   mapped    -> VMA says mapped, yet SMMU faults   => TLB/coherence
#   unmapped  -> VMA exists but driver has it unmapped
#   ABSENT    -> no VMA at that address in any VM
set -u

OUT=${NABU_FAULT_MAP_LOG:-/var/log/nabu-gpu-dumps/fault-gem-map.log}
GEM=/sys/kernel/debug/dri/0/gem

log() { echo "$(date +%FT%T.%3N) $*" >> "$OUT"; }

log "=== watcher started (poll) ==="

last=0
while :; do
	now=$(dmesg 2>/dev/null | grep -c 'gpu fault')
	if [ "${now:-0}" -gt "$last" ]; then
		# new faults since last poll
		dmesg 2>/dev/null | grep 'gpu fault' | tail -n "$((now - last))" |
		while IFS= read -r line; do
			iova=$(printf '%s' "$line" | grep -oE 'iova=[0-9a-f]+' | head -1 | sed 's/iova=//;s/^0*//')
			ttbr0=$(printf '%s' "$line" | grep -oE 'ttbr0=[0-9a-f]+' | head -1)
			src=$(printf '%s' "$line" | grep -oE 'source=[^ ]+' | head -1)
			[ -n "$iova" ] || continue
			hit=$(grep -m1 "[, ]$iova," "$GEM" 2>/dev/null)
			if [ -n "$hit" ]; then
				state=$(printf '%s' "$hit" | grep -oE 'mapped|unmapped' | head -1)
				vm=$(printf '%s' "$hit" | sed -n 's/.*\[\([^:]*\).*/\1/p')
				sz=$(printf '%s' "$hit" | sed 's/.*vm=[^,]*,//;s/,.*//')
				log "iova=0x$iova $ttbr0 $src gem=${state} vm=$vm size_region=$sz"
			else
				log "iova=0x$iova $ttbr0 $src gem=ABSENT"
			fi
		done
		last=$now
	fi
	sleep 0.5
done
