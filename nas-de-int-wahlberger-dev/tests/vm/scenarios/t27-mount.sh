#!/usr/bin/env bash
# BD-AC-24 rows 1-5 (fail clearly, fstab untouched), BD-AC-26, BD-AC-56. VM only.
# Needs the initialised backup disk (t27-init-happy.sh) and a prior mount run.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
U=$(cat "$FIXTURE_VM_DIR/backup_uuid")
fs() { gs 'sha256sum /etc/fstab'; }
row() { # row <n> <needle...> -- <play args...>
  local n=$1; shift; local needles=()
  while [[ $1 != -- ]]; do needles+=("$1"); shift; done; shift
  local f0 f1 rc miss=""
  f0=$(fs)
  play site.yml --tags backup_disk "$@" >"$OUT/ac24-$n.log" 2>&1; rc=$?
  f1=$(fs)
  for nd in "${needles[@]}"; do grep -Eqi "failed.*$nd" "$OUT/ac24-$n.log" || miss+=" [$nd]"; done
  failed_in=$(grep -E 'fatal:' -B3 "$OUT/ac24-$n.log" | grep -c 'TASK \[backup_disk')
  if [[ $rc -ne 0 && -z $miss && $failed_in -ge 1 && $f0 == "$f1" ]]; then record "BD-AC-24 row $n" PASS "fails in backup_disk, message has ${needles[*]}, fstab sha unchanged"
  else record "BD-AC-24 row $n" FAIL "rc=$rc missing:$miss failed_in_role=$failed_in fstab_same=$([[ $f0 == $f1 ]] && echo y || echo n) ($OUT/ac24-$n.log)"; fi
}
row 1 backup_disk_uuid 'roles/backup_disk/README.md' -- -e backup_disk_uuid=
row 2 00000000-0000-0000-0000-000000000000 -- -e backup_disk_uuid=00000000-0000-0000-0000-000000000000
gs 'btrfs filesystem label /mnt/backup/btrbk other'
row 3 label -- -e backup_disk_uuid=$U
gs 'btrfs filesystem label /mnt/backup/btrbk backups'
row 4 device -- -e backup_disk_uuid=$U -e backup_disk_device=$SC
# Row 5: a labelled filesystem without @btrbk on a partition of the "backup" device
# (the scratch disk stands in for it here, then is blanked again).
disk_blank $SC
gs "parted -s $SC mklabel gpt mkpart backups 1MiB 100% && udevadm settle && mkfs.btrfs -q -L backups $SC-part1"
U5=$(gs "blkid -p -s UUID -o value $SC-part1")
F0=$(fs)
play site.yml --tags backup_disk -e backup_disk_uuid=$U5 -e backup_disk_device=$SC -e backup_disk_expected_size_bytes=10737418240 >"$OUT/ac24-5.log" 2>&1; rc=$?
F1=$(fs)
mounts5=$(gs "grep -c $U5 /etc/fstab; findmnt -rn -S UUID=$U5 | wc -l" | tr '\n' ' ')
if [[ $rc -ne 0 ]] && grep -Eqi 'failed.*@btrbk' "$OUT/ac24-5.log" && [[ $F0 == "$F1" ]] && [[ "$mounts5" == "0 0 " ]]; then record "BD-AC-24 row 5" PASS "fails naming @btrbk, no fstab line for the filesystem, fstab unchanged"
else record "BD-AC-24 row 5" FAIL "rc=$rc mounts5='$mounts5' ($OUT/ac24-5.log)"; fi
disk_blank $SC

# BD-AC-26
a=$(gs 'findmnt -no UUID,OPTIONS /mnt/backup/btrbk'); b=$(gs 'grep " /mnt/backup/btrbk " /etc/fstab'); c=$(gs 'lsattr -d /mnt/backup/btrbk'); d=$(gs 'stat -c "%a %U:%G" /mnt/backup/btrbk')
want="UUID=$U /mnt/backup/btrbk btrfs subvol=/@btrbk,compress=zstd:1,noatime,nofail,x-systemd.device-timeout=30s 0 0"
if [[ $a == "$U "*subvol=/@btrbk* && $b == "$want" && ${c%% *} != *C* && $d == "700 root:root" ]]; then record "BD-AC-26" PASS "mount UUID+subvol=/@btrbk, fstab line exact, no C attr, 700 root:root"
else record "BD-AC-26" FAIL "$a | $b | $c | $d"; fi
# BD-AC-56
l=$(gs 'grep ^BTRFS_SCRUB_MOUNTPOINTS /etc/sysconfig/btrfsmaintenance'); t=$(gs 'systemctl is-enabled btrfs-scrub.timer; systemctl cat btrfs-scrub.timer | grep ^OnCalendar | tail -1' | tr '\n' ' ')
if [[ $l == *'/mnt/backup/btrbk'* && $l == *'"/:'* && $t == "enabled OnCalendar=monthly " ]]; then record "BD-AC-56" PASS "$l; timer $t"; else record "BD-AC-56" FAIL "$l $t"; fi
