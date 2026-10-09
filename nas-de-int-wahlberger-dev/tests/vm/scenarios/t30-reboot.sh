#!/usr/bin/env bash
# BD-AC-60 (reboot), BD-AC-59 (listeners), BD-AC-28 (backup disk detached), then re-attach + BD-AC-26.
# VM only; run from the `stack` snapshot. Needs out/ss-before.txt from t30-flags.sh (taken on `clean`).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
PWV=fixture-restic-htpasswd-not-a-secret
reboot_vm() { vm_stop; "$@"; vm_start; wait_ssh 300; }
settle() { gs 'systemctl is-system-running --wait' 2>/dev/null | tail -1; }

# --- BD-AC-60 + 59
vm_stop; vm_start; s0=$(date +%s); wait_ssh 300
st=$(settle); t1=$(( $(date +%s) - s0 ))
t_http=""
for i in $(seq 1 100); do c=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -u cloud:$PWV http://127.0.0.1:8000/cloud/config); [[ $c == 200 ]] && { t_http=$(( $(date +%s) - s0 )); break; }; sleep 3; done
mnt=$(gs 'mountpoint -q /mnt/backup/btrbk && echo mounted')
if [[ ( $st == running || $st == degraded ) && -n $t_http && $((t_http - t1)) -le 300 && $mnt == mounted ]]; then record "BD-AC-60" PASS "after reboot: $st at ${t1}s; rest-server answered 200 at ${t_http}s (within 300 s of $st); /mnt/backup/btrbk mounted"
else record "BD-AC-60" FAIL "st=$st t1=$t1 t_http=$t_http mnt=$mnt"; fi
gs 'ss -tlnH | awk "{print \$4}" | sort' >"$OUT/ss-after.txt"
added=$(comm -13 "$OUT/ss-before.txt" "$OUT/ss-after.txt" | tr '\n' ' ')
if [[ $added == *":8000 "* && $(wc -w <<<"$added") -eq 1 ]]; then record "BD-AC-59" PASS "listeners added vs the clean VM: only $added"; else record "BD-AC-59" FAIL "added: $added"; fi

# --- BD-AC-28
vm_stop; FIXTURE_DETACH=backup vm_start; s0=$(date +%s); wait_ssh 300
st=$(settle)
rs=$(gs 'systemctl is-active restic-server.service'); bk=$(gs 'rcli backup /etc/hostname >/dev/null 2>&1; echo $?')
T=$(now); gs 'systemctl start btrbk.service' >/dev/null 2>&1; rb=$(gs "journalctl -u btrbk.service --since '$T' --no-pager -o cat | grep -c \"failed with result 'dependency'\""); sleep 3
below=$(gs 'find /mnt/backup -xdev -mindepth 2 | wc -l'); albtrbk=$(alert_since btrbk.service "$T")
T=$(now); gs 'systemctl start backup-disk-health.service' >/dev/null 2>&1; rh=$(gs 'systemctl show -p Result --value backup-disk-health.service'); sleep 5; alh=$(alert_since backup-disk-health.service "$T")
T=$(now); gs 'systemctl start disk-space-check.service' >/dev/null 2>&1; dj=$(gs "journalctl -u disk-space-check.service --since '$T' --no-pager -o cat")
nm=$(grep -c '/mnt/backup/btrbk: not a mount point' <<<"$dj"); usage=$(grep '/mnt/backup/btrbk' <<<"$dj" | grep -vc 'not a mount point')
if [[ ( $st == running || $st == degraded ) && $rs == active && $bk == 0 && $rb -ge 1 && $below == 0 && $rh == exit-code && $alh -ge 1 && $nm -ge 1 && $usage == 0 ]]; then
  record "BD-AC-28" PASS "disk detached: boot $st, restic-server active + client backup exit 0, btrbk start job failed with result 'dependency', nothing below /mnt/backup, health failed + alert ($alh), disk-space: 'not a mount point', no usage line"
else record "BD-AC-28" FAIL "st=$st rs=$rs bk=$bk rb=$rb below=$below rh=$rh alh=$alh nm=$nm usage=$usage"; fi
if [[ $albtrbk -eq 0 ]]; then record "BD-AC-28 (BD-A-19: no OnFailure on dependency failure)" PASS "no notify instance for btrbk"; else record "BD-AC-28 (BD-A-19: no OnFailure on dependency failure)" FAIL "assumption disproved: systemd triggers OnFailure= when the start job fails with 'dependency' ($albtrbk notify-failure-immediate@btrbk lines); spec corrected, the extra alert is harmless"; fi
# re-attach and reboot -> BD-AC-26
vm_stop; vm_start; wait_ssh 300; settle >/dev/null
a=$(gs 'findmnt -no UUID,OPTIONS /mnt/backup/btrbk'); b=$(gs 'grep " /mnt/backup/btrbk " /etc/fstab'); c=$(gs 'lsattr -d /mnt/backup/btrbk'); d=$(gs 'stat -c "%a %U:%G" /mnt/backup/btrbk')
U=$(cat "$FIXTURE_VM_DIR/backup_uuid")
if [[ $a == "$U "*subvol=/@btrbk* && $b == "UUID=$U /mnt/backup/btrbk btrfs subvol=/@btrbk,compress=zstd:1,noatime,nofail,x-systemd.device-timeout=30s 0 0" && ${c%% *} != *C* && $d == "700 root:root" ]]; then record "BD-AC-28 (re-attach, BD-AC-26)" PASS "after re-attach and reboot BD-AC-26 holds"; else record "BD-AC-28 (re-attach, BD-AC-26)" FAIL "$a|$b|$c|$d"; fi
