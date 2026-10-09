#!/usr/bin/env bash
# (row 11: the PV needs an active LV to have a holder; a VG without LVs has none)
# BD-AC-20 rows 1-17: the init playbook refuses without writing. VM only.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
SIZE=21474836480
ROOTID=/dev/disk/by-id/virtio-FIXTUREROOT
cat >"$OUT/second-host.yml" <<'Y'
all:
  children:
    nas:
      hosts:
        nas-vm-second:
          ansible_host: 127.0.0.1
          ansible_port: 2222
          ansible_ssh_private_key_file: "{{ lookup('env', 'FIXTURE_VM_DIR') ~ '/id_fixture' }}"
          ansible_ssh_common_args: -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes
Y

row() { # row <n> <rid> <setup-cmd or ''> <device> <size> [extra play args...]
  local n=$1 rid=$2 setup=$3 dev=$4 size=$5; shift 5
  disk_blank $BK; disk_blank $SC
  [[ -n "$setup" ]] && gs "$setup" >"$OUT/row$n.setup" 2>&1
  local before after
  before=$(fp "$dev"); 
  play backup_disk_init.yml -e "backup_disk_expected_size_bytes=$size" "$@" >"$OUT/row$n.log" 2>&1; local rc=$?
  after=$(fp "$dev")
  if [[ $rc -ne 0 ]] && grep -Eq "(hold|holding): .*$rid" "$OUT/row$n.log" && [[ "$before" == "$after" ]]; then
    record "BD-AC-20 row $n" PASS "rc=$rc, message names $rid, fingerprint unchanged"
  else
    record "BD-AC-20 row $n" FAIL "rc=$rc rid_in_msg=$(grep -Ec "(hold|holding): .*$rid" "$OUT/row$n.log") fp_same=$([[ "$before" == "$after" ]] && echo y || echo n) (see $OUT/row$n.log)"
  fi
}
C="-e backup_disk_init_confirm=$BK"
row 1 R-01 '' $BK $SIZE
row 2 R-01 '' $BK $SIZE -e "backup_disk_init_confirm=${BK}x"
row 3 R-02 '' $BK $SIZE $C -i "$OUT/second-host.yml"
row 4 R-03 '' /dev/vdd $SIZE -e backup_disk_device=/dev/vdd -e backup_disk_init_confirm=/dev/vdd
row 5 R-04 "parted -s $BK mklabel gpt mkpart p 1MiB 100% && udevadm settle" $BK-part1 $SIZE -e backup_disk_device=$BK-part1 -e backup_disk_init_confirm=$BK-part1
row 6 R-05 '' $BK 22548578304 $C
row 7 R-06 "mkfs.ext4 -q -E lazy_itable_init=0,lazy_journal_init=0 $BK && mkdir -p /mnt/t27 && mount $BK /mnt/t27" $BK $SIZE $C
row 8 R-06 "parted -s $BK mklabel gpt mkpart p 1MiB 100% && udevadm settle && mkfs.ext4 -q -E lazy_itable_init=0,lazy_journal_init=0 $BK-part1 && mkdir -p /mnt/t27 && mount $BK-part1 /mnt/t27" $BK $SIZE $C
row 9 R-06 '' $ROOTID $(gs "blockdev --getsize64 $ROOTID") -e backup_disk_device=$ROOTID -e backup_disk_init_confirm=$ROOTID
row 10 R-07 "mkswap $BK && swapon $BK" $BK $SIZE $C
row 11 R-08 "pvcreate -ff -y $BK && vgcreate fixturevg $BK && lvcreate -y -L 100M -n lv fixturevg" $BK $SIZE $C
row 12 R-08 "mdadm --create /dev/md0 --run --level=1 --raid-devices=2 --metadata=1.2 $BK $SC" $BK $SIZE $C
row 13 R-08 "echo -n fixture | cryptsetup luksFormat --batch-mode --type luks2 $BK - && echo -n fixture | cryptsetup open $BK fixtureluks -" $BK $SIZE $C
row 14 R-09 "mkfs.ext4 -q -E lazy_itable_init=0,lazy_journal_init=0 $BK" $BK $SIZE $C
row 15 R-09 "parted -s $BK mklabel gpt mkpart p 1MiB 100% && udevadm settle" $BK $SIZE $C
row 16 R-09 "parted -s $BK mklabel gpt mkpart backups 1MiB 100% && udevadm settle && mkfs.btrfs -q -L backups $BK-part1" $BK $SIZE $C
row 17 R-10 "dd if=/dev/urandom of=$BK bs=1M seek=\$((\$(blockdev --getsize64 $BK)/1048576-1)) count=1 conv=fsync 2>/dev/null" $BK $SIZE $C
disk_blank $BK; disk_blank $SC
