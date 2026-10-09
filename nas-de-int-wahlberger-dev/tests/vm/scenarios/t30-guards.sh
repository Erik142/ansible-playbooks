#!/usr/bin/env bash
# BD-AC-27 rows 1-6 (mount guards at Ansible time), BD-AC-57 (unit properties), BD-AC-55 (health check).
# VM only; run from the `stack` snapshot.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
quiet_timers
restore() { gs 'mountpoint -q /mnt/data || mount /mnt/data; mountpoint -q /mnt/containers || mount /mnt/containers; mountpoint -q /mnt/backup/btrbk || mount /mnt/backup/btrbk; systemctl start restic-server.service; podman start fixture-postgres >/dev/null 2>&1; true'; }
guard() { # guard <row> <tags> <needle>
  local row=$1 tags=$2 need=$3
  role_only "$tags" >"$OUT/ac27-$row.log" 2>&1; rc=$?
  local chg; chg=$(grep -c '^changed:' "$OUT/ac27-$row.log")
  if [[ $rc -ne 0 && $chg -eq 0 ]] && grep -E 'fatal|failed' "$OUT/ac27-$row.log" | grep -q -- "$need"; then record "BD-AC-27 row $row" PASS "fails before any change (changed=$chg), names $need"
  else record "BD-AC-27 row $row" FAIL "rc=$rc changed=$chg need=$need ($OUT/ac27-$row.log)"; fi
}
# row 1
gs 'umount /mnt/backup/btrbk'; guard 1 btrbk /mnt/backup/btrbk; restore
# row 2
gs 'systemctl stop restic-server.service; umount /mnt/data'; guard 2 btrbk /mnt/data; restore
# row 3
gs 'podman stop fixture-postgres >/dev/null; umount /mnt/containers'; guard 3 db_dump /mnt/containers; restore
# row 4
gs 'systemctl stop restic-server.service; umount /mnt/data'; guard 4 restic_server /mnt/data; restore
# row 5
gs 'systemctl stop restic-server.service; umount /mnt/data; mount -o subvolid=5 UUID=00000000-0000-4000-8000-0000000000d1 /mnt/data'; guard 5 restic_server /mnt/data
gs 'umount /mnt/data'; restore
# row 6
gs 'umount /mnt/backup/btrbk'
role_only backup_disk,btrbk >"$OUT/ac27-6.log" 2>&1; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'failed=0' "$OUT/ac27-6.log" && [[ $(gs 'mountpoint -q /mnt/backup/btrbk && echo m') == m ]]; then record "BD-AC-27 row 6" PASS "backup_disk,btrbk in one play: failed=0, path mounted by backup_disk first"
else record "BD-AC-27 row 6" FAIL "rc=$rc ($OUT/ac27-6.log)"; fi

# --- BD-AC-57
chk() { local v; v=$(gs "systemctl show $1 -p $2 --value"); [[ $v == *"$3"* ]] || echo "MISMATCH $1 $2='$v' want '$3'"; }
bad=$( {
 chk btrbk.timer OnCalendarUsec '' ; chk btrbk.timer Persistent yes
 gs 'systemctl cat btrbk.timer | grep -E "^(OnCalendar|Persistent)"' | grep -q 'OnCalendar=\*-\*-\* 01:30:00' || echo "MISMATCH btrbk.timer OnCalendar"
 gs 'systemctl cat btrbk.timer | grep -q "^Persistent=true"' || echo "MISMATCH btrbk.timer Persistent"
 chk btrbk.service OnFailure 'notify-failure-immediate@btrbk.service'
 chk db-dump.service OnFailure 'notify-failure-immediate@db-dump.service'
 chk restic-server.service OnFailure 'notify-failure@restic-server.service'
 chk restic-server.service Restart always
 gs 'systemctl cat restic-server.service | grep -q "WantedBy=default.target"' || echo "MISMATCH restic-server WantedBy"
 gs 'systemctl cat restic-server-maintenance.timer | grep -E "^(OnCalendar|Persistent|RandomizedDelaySec)" | tr "\n" " "' | grep -q 'OnCalendar=\*-\*-\* 06:00:00 Persistent=true RandomizedDelaySec=5min' || echo "MISMATCH maintenance.timer"
 chk restic-server-maintenance.service OnFailure 'notify-failure-immediate@restic-server-maintenance.service'
 chk restic-server-maintenance.service User restic-server; chk restic-server-maintenance.service Group restic-server
 gs 'systemctl cat backup-disk-health.timer | grep -E "^(OnCalendar|Persistent)" | tr "\n" " "' | grep -q 'OnCalendar=\*-\*-\* 09:00:00 Persistent=true' || echo "MISMATCH health.timer"
 chk backup-disk-health.service OnFailure 'notify-failure-immediate@backup-disk-health.service'
 chk btrbk.service RequiresMountsFor '/mnt/backup/btrbk'; chk btrbk.service RequiresMountsFor '/mnt/data'; chk btrbk.service RequiresMountsFor '/mnt/containers'
 chk db-dump.service RequiresMountsFor '/mnt/containers'
 chk restic-server.service RequiresMountsFor '/mnt/data'; chk restic-server-maintenance.service RequiresMountsFor '/mnt/data'
} 2>&1 | grep MISMATCH )
if [[ -z $bad ]]; then record "BD-AC-57" PASS "every BD-BR-05 NAS row and every BD-BR-04 RequiresMountsFor verified with systemctl show/cat"; else record "BD-AC-57" FAIL "$bad"; fi

# --- BD-AC-55
FR='[{"path":"/mnt/backup/btrbk/data","max_age_hours":26},{"path":"/mnt/backup/btrbk/containers","max_age_hours":26},{"path":"/mnt/data/restic-repos/cloud/snapshots","max_age_hours":26}]'
H=backup-disk-health.service
gs 'rcli backup /etc/hostname >/dev/null 2>&1; systemctl start btrbk.service'
T=$(now); gs "systemctl start $H"; r=$(gs "systemctl show -p Result --value $H"); sleep 3; al=$(alert_since $H "$T")
if [[ $r == success && $al == 0 ]]; then record "BD-AC-55 row 1" PASS "Result=success, no alert"; else record "BD-AC-55 row 1" FAIL "r=$r al=$al"; fi
for spec in "2|/mnt/backup/btrbk/data|$(python3 -c "import json;print(json.dumps([{'path':'/mnt/backup/btrbk/data','max_age_hours':0},{'path':'/mnt/backup/btrbk/containers','max_age_hours':26},{'path':'/mnt/data/restic-repos/cloud/snapshots','max_age_hours':26}]))")" "3|/mnt/data/restic-repos/cloud/snapshots|$(python3 -c "import json;print(json.dumps([{'path':'/mnt/backup/btrbk/data','max_age_hours':26},{'path':'/mnt/backup/btrbk/containers','max_age_hours':26},{'path':'/mnt/data/restic-repos/cloud/snapshots','max_age_hours':0}]))")"; do
  IFS='|' read -r row path ov <<<"$spec"
  role_only backup_disk -e "{\"backup_disk_freshness_checks\": $ov}" >"$OUT/ac55-$row.log" 2>&1
  T=$(now); gs "systemctl start $H"; r=$(gs "systemctl show -p Result --value $H"); sleep 3; al=$(alert_since $H "$T"); jl=$(gs "journalctl -u $H --since '$T' --no-pager -o cat | grep -c '$path'")
  if [[ $r == exit-code && $al -ge 1 && $jl -ge 1 ]]; then record "BD-AC-55 row $row" PASS "stale path $path: unit failed, alert ($al), journal names the path"; else record "BD-AC-55 row $row" FAIL "r=$r al=$al jl=$jl"; fi
done
role_only backup_disk >"$OUT/ac55-restore.log" 2>&1
gs 'mv /mnt/data/restic-repos/cloud /mnt/data/restic-repos/cloud.x'
T=$(now); gs "systemctl start $H"; r=$(gs "systemctl show -p Result --value $H"); jl=$(gs "journalctl -u $H --since '$T' --no-pager -o cat | grep -c 'absent, skipped'")
T2=$(now); gs 'systemctl start restic-server-maintenance.service'; rm=$(gs 'systemctl show -p Result --value restic-server-maintenance.service'); sleep 3; alm=$(alert_since restic-server-maintenance.service "$T2")
gs 'mv /mnt/data/restic-repos/cloud.x /mnt/data/restic-repos/cloud'
if [[ $r == success && $jl -ge 1 && $rm == exit-code && $alm -ge 1 ]]; then record "BD-AC-55 row 4" PASS "health Result=success with 'absent, skipped' in the journal; maintenance run failed and alerted"; else record "BD-AC-55 row 4" FAIL "r=$r jl=$jl rm=$rm alm=$alm"; fi
