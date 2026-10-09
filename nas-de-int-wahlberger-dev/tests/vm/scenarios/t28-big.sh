#!/usr/bin/env bash
# BD-AC-33 (no concurrent btrbk) and BD-AC-34 (interrupted transfer). VM only.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
res() { gs "systemctl show -p Result --value $1"; }
quiet_timers
gs 'df -h /mnt/data /mnt/backup/btrbk | tail -2; dd if=/dev/urandom of=/mnt/data/random5g.bin bs=1M count=5120 2>&1 | tail -1; sync'
# --- BD-AC-33
nextday
gs 'systemctl start --no-block btrbk.service; systemctl start --no-block btrbk.service; max=0; for i in $(seq 1 25); do n=$(pgrep -c -x btrbk); [ "$n" -gt "$max" ] && max=$n; [ $i = 5 ] && { btrbk run >/tmp/second.log 2>&1; echo second_rc=$? >/tmp/second.rc; }; sleep 1; done; echo max=$max' >"$OUT/ac33.txt" 2>&1
while [[ $(gs 'systemctl is-active btrbk.service') == activating ]]; do sleep 5; done
max=$(grep -o 'max=[0-9]*' "$OUT/ac33.txt" | cut -d= -f2); src=$(gs 'cat /tmp/second.rc'); lockmsg=$(gs 'grep -i "lock" /tmp/second.log | head -1')
if [[ ${max:-9} -le 1 && $src != second_rc=0 && -n $lockmsg ]]; then record "BD-AC-33" PASS "max concurrent btrbk processes=$max; manual 'btrbk run' $src, '$lockmsg'; unit Result=$(res btrbk.service)"
else record "BD-AC-33" FAIL "max=$max $src lock='$lockmsg' ($OUT/ac33.txt)"; fi
# --- BD-AC-34
gs 'echo more >>/mnt/data/random5g.bin'
nextday
gs 'systemctl start --no-block btrbk.service; for i in $(seq 1 120); do pgrep -f "btrfs receive" >/dev/null && break; sleep 0.5; done; pgrep -fa "btrfs receive" | head -1; systemctl kill btrbk.service; sleep 3; systemctl is-active btrbk.service' >"$OUT/ac34-kill.txt" 2>&1
r1=$(res btrbk.service)
gs 'systemctl start btrbk.service'; r2=$(res btrbk.service)
bad=$(gs 'for s in $(btrfs subvolume list -o /mnt/backup/btrbk | awk "{print \$NF}"); do p=/mnt/backup/btrbk/${s#@btrbk/}; u=$(btrfs subvolume show $p 2>/dev/null | grep "Received UUID" | awk "{print \$3}"); [ "$u" = "-" -o -z "$u" ] && echo "BAD $p"; done; true')
if grep -q 'btrfs receive' "$OUT/ac34-kill.txt" && [[ $r2 == success && -z $bad ]]; then record "BD-AC-34" PASS "killed during btrfs receive (first unit Result=$r1); next start Result=success; every subvolume has a Received UUID"
else record "BD-AC-34" FAIL "kill=$(head -c 200 $OUT/ac34-kill.txt) r2=$r2 bad=$bad"; fi
gs 'rm -f /mnt/data/random5g.bin'
