#!/usr/bin/env bash
# BD-AC-21 (--check), BD-AC-22 (init blank disk), BD-AC-23 (re-run changed=0). VM only.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
SIZE=21474836480
C="-e backup_disk_init_confirm=$BK"
OTHERS="/dev/disk/by-id/virtio-FIXTUREDATA /dev/disk/by-id/virtio-FIXTURECONTAINERS $SC"
disk_blank $BK; disk_blank $SC
gs 'podman stop fixture-postgres >/dev/null; umount /mnt/data /mnt/containers; sync'
sums() { gs "for d in $OTHERS; do sha256sum \$(readlink -f \$d); done; dd if=/dev/vda bs=1M count=1 2>/dev/null|sha256sum; dd if=/dev/vda bs=1M skip=\$((\$(blockdev --getsize64 /dev/vda)/1048576-1)) count=1 2>/dev/null|sha256sum"; }
S0=$(sums); F0=$(fp $BK)

play backup_disk_init.yml $C --check >"$OUT/ac21.log" 2>&1; rc=$?
F1=$(fp $BK)
nR=$(grep -Ec 'TASK \[backup_disk : R-(0[1-9]|10)' "$OUT/ac21.log")
if [[ $rc -eq 0 && "$F0" == "$F1" ]] && grep -Eq 'failed=0' "$OUT/ac21.log" && [[ $nR -ge 10 ]]; then
  record "BD-AC-21" PASS "--check rc=0 failed=0, $nR R-check tasks ran, fingerprint unchanged"
else record "BD-AC-21" FAIL "rc=$rc nR=$nR fp_same=$([[ $F0 == $F1 ]] && echo y || echo n)"; fi

play backup_disk_init.yml $C >"$OUT/ac22.log" 2>&1; rc=$?
uuid=$(grep -o 'Backup filesystem UUID: [0-9a-f-]*' "$OUT/ac22.log" | tail -1 | awk '{print $NF}')
dump=$(gs "sfdisk --dump $BK")
pu=$(gs "blkid -p -s UUID -o value $BK-part1")
bl=$(gs "blkid -p -o export $BK-part1 | tr '\n' ' '")
subs=$(gs 'm=$(mktemp -d); mount -o ro,subvolid=5 '"$BK-part1"' $m && btrfs subvolume list $m; umount $m; rmdir $m')
last=$(gs "p=\$(readlink -f $BK-part1); echo \$(( \$(cat /sys/class/block/\$(basename \$p)/start) )) \$(cat /sys/class/block/\$(basename \$p)/size) \$(( \$(blockdev --getsz $BK) ))")
S1=$(sums)
ok=1
[[ $rc -eq 0 ]] || ok=0
grep -q 'label: gpt' <<<"$dump" || ok=0
[[ $(grep -c 'start=' <<<"$dump") -eq 1 ]] || ok=0
grep -q 'start= *2048' <<<"$dump" || ok=0
grep -q 'TYPE=btrfs' <<<"$bl" && grep -q 'LABEL=backups' <<<"$bl" || ok=0
[[ "$(wc -l <<<"$subs")" -eq 1 ]] && grep -q 'top level 5 path @btrbk' <<<"$subs" || ok=0
[[ -n $uuid && $uuid == "$pu" ]] || ok=0
[[ $S0 == "$S1" ]] || ok=0
# partition end within last 2048 sectors
read -r st sz tot <<<"$last"; (( tot - (st+sz) <= 2048 )) || ok=0
if [[ $ok -eq 1 ]]; then record "BD-AC-22" PASS "rc=0; GPT 1 partition @2048, btrfs LABEL=backups, only @btrbk, UUID $uuid == part1, other disks' sha unchanged (end gap $((tot-(st+sz))) sectors)"
else record "BD-AC-22" FAIL "rc=$rc uuid=$uuid part=$pu dump=$(tr '\n' ' ' <<<"$dump" | cut -c1-200) subs=$subs sums_same=$([[ $S0 == $S1 ]] && echo y || echo n) $last"; fi

play backup_disk_init.yml $C >"$OUT/ac23.log" 2>&1; rc=$?
uuid2=$(grep -o 'Backup filesystem UUID: [0-9a-f-]*' "$OUT/ac23.log" | tail -1 | awk '{print $NF}')
if [[ $rc -eq 0 ]] && grep -Eq 'changed=0' "$OUT/ac23.log" && [[ $uuid2 == "$uuid" ]]; then record "BD-AC-23" PASS "second run changed=0, same UUID"
else record "BD-AC-23" FAIL "rc=$rc uuid2=$uuid2 $(grep -E 'ok=' "$OUT/ac23.log")"; fi
gs 'mount /mnt/data; mount /mnt/containers; podman start fixture-postgres >/dev/null'
