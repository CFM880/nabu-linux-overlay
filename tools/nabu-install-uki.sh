#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-install-uki.sh - put a UKI on the nabu tablet's ESP, reliably.
#
# Why this exists: the ESP cannot be mounted on the tablet (`mount /dev/sda31
# /boot/efi` fails with "can't read superblock", the 4096-byte logical sector
# FAT), and `mtools -i /dev/sda31` or `-i /dev/sda31@@offset` both refuse it
# ("Hidden (656) does not match sectors (63)").  What does work is to copy the
# whole partition to a file, edit the file as a plain FAT image, and write it
# back - which also leaves a full ESP backup behind.
#
# Both `scp` and `mtools` cannot be assumed working: minimal Debian images miss
# openssh-sftp-server (scp's new protocol dies with "Connection closed"), so the
# file is pushed with `ssh 'cat >'`.
#
# Usage:
#   nabu-install-uki.sh [-H host] [-u uki] [-d esp-path] [-p esp-part] [-n] [-R]
#
#   -H host      ssh target                     (default 192.168.0.67)
#   -u uki       local UKI to install           (default nabu-main/artifacts/serial-debug/nabu-serial-debug.efi)
#   -d path      path inside the ESP            (default EFI/debian/nabu-debian.efi)
#   -p part      ESP partition on the tablet    (default /dev/disk/by-partlabel/esp)
#   -n           do not reboot afterwards
#   -R           delete the ESP backup afterwards (default: keep it on the tablet)
#
# The sudo password comes from NABU_PW (default: prompt).

set -u

HOST=192.168.0.67
UKI=nabu-main/artifacts/serial-debug/nabu-serial-debug.efi
DEST=EFI/debian/nabu-debian.efi
PART=/dev/disk/by-partlabel/esp
REBOOT=1
KEEP_BACKUP=1

while getopts "H:u:d:p:nR" opt; do
	case "$opt" in
	H) HOST=$OPTARG ;;
	u) UKI=$OPTARG ;;
	d) DEST=$OPTARG ;;
	p) PART=$OPTARG ;;
	n) REBOOT=0 ;;
	R) KEEP_BACKUP=0 ;;
	*) sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
	esac
done

[ -f "$UKI" ] || { echo "no such UKI: $UKI" >&2; exit 1; }
: "${NABU_PW:=$(read -rsp "sudo password for $HOST: " p && echo "$p")}"
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 cfm880@$HOST"

say() { printf '%s\n' "$*"; }

say "== pushing $(basename "$UKI") ($(stat -c %s "$UKI") bytes) to $HOST"
cat "$UKI" | $SSH 'cat > /home/cfm880/.nabu-uki' || { echo "push failed" >&2; exit 1; }
local_md5=$(md5sum "$UKI" | cut -d' ' -f1)
remote_md5=$($SSH 'md5sum /home/cfm880/.nabu-uki' | cut -d' ' -f1)
[ "$local_md5" = "$remote_md5" ] || { echo "md5 mismatch: $local_md5 != $remote_md5" >&2; exit 1; }
say "== md5 ok: $local_md5"

{
	printf '%s\n' "$NABU_PW"
	cat <<EOS
set -e
IMG=/tmp/esp-install-\$\$.img
dd if=$PART of=\$IMG bs=1M status=none
mcopy -o -i \$IMG /home/cfm880/.nabu-uki ::/$DEST
mdir -i \$IMG ::/\$(dirname $DEST) | tail -n 2
dd if=\$IMG of=$PART bs=1M conv=fsync status=none
sync
echo "== installed $DEST"
if [ "$KEEP_BACKUP" = 1 ]; then
	mv \$IMG /tmp/esp-backup-\$(date +%Y%m%d-%H%M%S).img && echo "== ESP backup kept: \$(ls -t /tmp/esp-backup-*.img | head -1)"
else
	rm -f \$IMG
fi
rm -f /home/cfm880/.nabu-uki
EOS
	if [ "$REBOOT" = 1 ]; then
		echo 'systemctl reboot'
	fi
} | $SSH "sudo -S -p '' bash -s" || { echo "install failed" >&2; exit 1; }

if [ "$REBOOT" = 1 ]; then
	say "== rebooting, waiting for the tablet"
	sleep 30
	for _ in $(seq 1 18); do
		$SSH 'true' >/dev/null 2>&1 && { say "== back up"; exit 0; }
		sleep 10
	done
	say "== tablet did not come back (check the screen / long press)"
fi
