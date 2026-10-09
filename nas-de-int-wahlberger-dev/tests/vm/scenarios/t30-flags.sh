#!/usr/bin/env bash
# BD-AC-25 (flags false: nothing changes) and BD-AC-59 (listeners before). VM only; run from the
# `clean` snapshot (provisioned, backup disk blank, no role applied).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
TAGS=backup_disk,btrbk,db_dump,restic_server,restic_backup_decommission
dummies() { gs 'printf "[Unit]\nDescription=dummy old restic job\n[Service]\nType=oneshot\nExecStart=/bin/true\n" >/etc/systemd/system/restic-backup.service; printf "[Timer]\nOnCalendar=*-*-* 04:30:00\n[Install]\nWantedBy=timers.target\n" >/etc/systemd/system/restic-backup.timer; printf "#!/bin/sh\n" >/usr/local/bin/restic-backup.sh; mkdir -p /etc/restic-backup /var/lib/restic-backup; echo x >/etc/restic-backup/env; echo x >/var/lib/restic-backup/state; systemctl daemon-reload'; }
present() { gs 'ls /etc/systemd/system/restic-backup.timer /etc/systemd/system/restic-backup.service /usr/local/bin/restic-backup.sh /etc/restic-backup /var/lib/restic-backup >/dev/null 2>&1 && echo yes || echo no'; }
gs 'ss -tlnH | awk "{print \$4}" | sort' >"$OUT/ss-before.txt"
dummies
( cd "$NAS_DIR" && tests/vm/ans.sh ansible-playbook site.yml --tags $TAGS -e backup_disk_enabled=false -e restic_backup_decommission_enabled=false ) </dev/null >"$OUT/ac25.log" 2>&1; rc=$?
chg=$(grep -c '^changed:' "$OUT/ac25.log"); pr=$(present)
if [[ $rc -eq 0 && $chg -eq 0 ]] && grep -q 'failed=0' "$OUT/ac25.log" && [[ $pr == yes ]]; then record "BD-AC-25" PASS "flags false, five roles tagged: failed=0, 0 changed tasks, dummy units and paths still present (tags limited to the five roles: the other roles of site.yml need real third-party inputs)"
else record "BD-AC-25" FAIL "rc=$rc changed=$chg present=$pr ($OUT/ac25.log)"; fi
