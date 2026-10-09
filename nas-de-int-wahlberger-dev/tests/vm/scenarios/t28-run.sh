#!/usr/bin/env bash
# BD-AC-30..37. VM only. Starts from the `stack` snapshot state (+ t28-btrbk.sh row 2 restored).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
res() { gs "systemctl show -p Result --value $1"; }
newest() { gs "ls -1d /mnt/backup/btrbk/$1/$1.* 2>/dev/null | sort | tail -1"; }

quiet_timers
# --- BD-AC-30
gs 'rcli backup /etc/hostname >/dev/null 2>&1; btrbk -n run >/dev/null 2>&1; echo dry=$?' >"$OUT/ac30-dry.txt"
T0=$(now)
gs 'systemctl start btrbk.service'; r=$(res btrbk.service)
nd=$(newest data); nc=$(newest containers)
ok=1; why=""
[[ $r == success ]] || { ok=0; why+=" Result=$r"; }
for s in data containers; do
  ro=$(gs "for x in /mnt/$s/.btrbk/*; do btrfs property get -ts \$x ro; done" | sort -u | tr '\n' ' ')
  [[ $ro == "ro=true " ]] || { ok=0; why+=" ro($s)=$ro"; }
done
[[ -z $(gs 'ls -d /mnt/data/.snapshots/.btrbk /mnt/data/samba/.btrbk 2>/dev/null') ]] || { ok=0; why+=" snapdir"; }
for p in $nd $nc; do
  ru=$(gs "btrfs subvolume show $p | grep 'Received UUID' | awk '{print \$3}'")
  [[ -n $ru && $ru != - ]] || { ok=0; why+=" recv($p)=$ru"; }
done
[[ -z $(gs "find $nd/.snapshots -mindepth 1 -maxdepth 1 2>&1 | grep -v 'No such'") ]] || { ok=0; why+=" .snapshots non-empty"; }
gs "test -e $nd/restic-repos/cloud/config" || { ok=0; why+=" no restic config"; }
srcsnap=$(gs "ls -1d /mnt/containers/.btrbk/containers.* | sort | tail -1"); ct=$(gs "date -d \"\$(btrfs subvolume show $srcsnap | grep 'Creation time' | sed 's/.*time:[ \t]*//')\" +%s")
for f in fixture.sql forgejo.db; do
  mt=$(gs "stat -c %Y $nc/db-dumps/$f"); t0=$(gs "date -d '$T0' +%s")
  (( mt >= t0 && mt <= ct )) || { ok=0; why+=" mtime($f)=$mt not in [$t0,$ct]"; }
done
if [[ $ok == 1 ]]; then record "BD-AC-30" PASS "Result=success; ro snapshots in <src>/.btrbk; Received UUID set on $(basename $nd), $(basename $nc); no .snapshots content; restic-repos/cloud/config present; dumps fresh (between run start and source snapshot)"
else record "BD-AC-30" FAIL "$why"; fi

# --- BD-AC-31
nextday; T1=$(now); gs 'systemctl start btrbk.service'; r=$(res btrbk.service)
inc=$(gs "journalctl -u btrbk.service --since '$T1' --no-pager -o cat | grep -c '^>>> '")
cnt=$(gs 'for s in data containers; do ls -1d /mnt/$s/.btrbk/* | wc -l; done' | tr '\n' ' ')
if [[ $r == success && $inc -ge 2 && $cnt == "2 2 " || $cnt == "3 3 " ]]; then record "BD-AC-31" PASS "second run success; $inc incremental '>>>' receives in the journal; each .btrbk holds parent+new (counts: $cnt)"
else record "BD-AC-31" FAIL "r=$r inc=$inc cnt=$cnt"; fi

# --- BD-AC-32
nextday; T2=$(now)
gs 'btrfs property set -ts /mnt/backup/btrbk ro true; systemctl start btrbk.service; btrfs property set -ts /mnt/backup/btrbk ro false'
r=$(res btrbk.service); sleep 5; al=$(alert_since btrbk.service "$T2")
nextday; gs 'systemctl start btrbk.service'; r2=$(res btrbk.service)
if [[ $r == exit-code && $al -ge 1 && $r2 == success ]]; then record "BD-AC-32" PASS "ro target: unit failed (Result=$r), notify-failure-immediate@btrbk ran ($al journal lines), next start success"
else record "BD-AC-32" FAIL "r=$r alert=$al r2=$r2"; fi
