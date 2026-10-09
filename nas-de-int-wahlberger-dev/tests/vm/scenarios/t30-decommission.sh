#!/usr/bin/env bash
# BD-AC-38: the old restic job is removed only by its own flag, idempotently. VM only; `stack` snapshot.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source <(sed -n '/^dummies()/,/^present()/p' "$SCEN_DIR/t30-flags.sh")
present() { gs 'ls /etc/systemd/system/restic-backup.timer /etc/systemd/system/restic-backup.service /usr/local/bin/restic-backup.sh /etc/restic-backup /var/lib/restic-backup >/dev/null 2>&1 && echo yes || echo no'; }
dummies
stack -e restic_backup_decommission_enabled=false >"$OUT/ac38-a.log" 2>&1; a=$(present)
stack -e restic_backup_decommission_enabled=true >"$OUT/ac38-b.log" 2>&1; rcb=$?; b=$(present)
unit=$(gs 'systemctl cat restic-backup.timer 2>&1 | head -1; systemctl cat restic-backup.service 2>&1 | head -1' | tr '\n' ' ')
stack -e restic_backup_decommission_enabled=true >"$OUT/ac38-c.log" 2>&1
badtasks=$(awk '/^TASK \[/{t=$0} /^changed:/{print t}' "$OUT/ac38-c.log" | grep -c restic_backup_decommission)
if [[ $a == yes && $rcb -eq 0 && $b == no && $unit == *"No files found"* && $badtasks -eq 0 ]]; then record "BD-AC-38" PASS "flag false: dummies kept; flag true: units and 3 paths gone (systemctl cat: no such unit); second run: no decommission task changed"
else record "BD-AC-38" FAIL "a=$a rcb=$rcb b=$b unit='$unit' second_changed=$badtasks"; fi
