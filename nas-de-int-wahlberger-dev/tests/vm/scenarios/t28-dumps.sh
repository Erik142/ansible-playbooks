#!/usr/bin/env bash
# BD-AC-35..37 (needs the state left by t28-run.sh). VM only.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
res() { gs "systemctl show -p Result --value $1"; }
quiet_timers
# --- BD-AC-35
r1=$(gs "stat -c '%a %U:%G' /mnt/containers/db-dumps")
r2=$(gs "stat -c '%a %U:%G' /mnt/containers/db-dumps/*" | sort -u | tr '\n' ',')
r3=$(gs "for f in /var/lib/db-dump/*; do echo \$(df --output=target \$f | tail -1) \$(stat -c '%a %U:%G' \$f); done" | sort -u | tr '\n' ',')
before=$(gs 'sha256sum /etc/systemd/system/db-dump.service /usr/local/bin/db-dump.sh | sha256sum')
stack --tags db_dump -e db_dump_dir=/var/tmp/db-dumps >"$OUT/ac35-4.log" 2>&1; rc4=$?
after=$(gs 'sha256sum /etc/systemd/system/db-dump.service /usr/local/bin/db-dump.sh | sha256sum'); ch=$(grep -E "^changed" "$OUT/ac35-4.log" | grep -c db_dump)
[[ $r1 == "700 root:root" ]] && record "BD-AC-35 row 1" PASS "$r1" || record "BD-AC-35 row 1" FAIL "$r1"
[[ $r2 == "600 root:root," ]] && record "BD-AC-35 row 2" PASS "all files 600 root:root" || record "BD-AC-35 row 2" FAIL "$r2"
[[ $r3 == "/ 600 root:root," || $r3 == "/var 600 root:root," ]] && record "BD-AC-35 row 3" PASS "credentials files on the root filesystem (/ or its /var subvolume mount), 600 root:root" || record "BD-AC-35 row 3" FAIL "$r3"
if [[ $rc4 -ne 0 && $before == "$after" ]] && grep -q 'db_dump_dir' "$OUT/ac35-4.log"; then record "BD-AC-35 row 4" PASS "play failed naming db_dump_dir, no db_dump file changed"; else record "BD-AC-35 row 4" FAIL "rc=$rc4 same=$([[ $before == $after ]] && echo y || echo n)"; fi

# --- BD-AC-36
sha=$(gs 'sha256sum /mnt/containers/db-dumps/fixture.sql | cut -d" " -f1'); mt=$(gs 'stat -c %Y /mnt/containers/db-dumps/forgejo.db')
nbefore=$(gs 'ls -1d /mnt/backup/btrbk/containers/containers.* | wc -l')
gs 'podman stop fixture-postgres >/dev/null'; sleep 2; nextday; T=$(now)
gs 'systemctl start btrbk.service'; rb=$(res btrbk.service); rd=$(res db-dump.service); sleep 5; al=$(alert_since db-dump.service "$T")
sha2=$(gs 'sha256sum /mnt/containers/db-dumps/fixture.sql | cut -d" " -f1'); mt2=$(gs 'stat -c %Y /mnt/containers/db-dumps/forgejo.db')
nafter=$(gs 'ls -1d /mnt/backup/btrbk/containers/containers.* | wc -l')
gs 'podman start fixture-postgres >/dev/null'
if [[ $rd == exit-code && $al -ge 1 && $sha == "$sha2" && $mt2 -gt $mt && $rb == success && $nafter -gt $nbefore ]]; then record "BD-AC-36" PASS "db-dump failed + alert ($al lines), fixture.sql sha unchanged, forgejo.db mtime newer, btrbk success, new containers snapshot ($nbefore -> $nafter)"
else record "BD-AC-36" FAIL "rd=$rd al=$al sha_same=$([[ $sha == $sha2 ]] && echo y || echo n) mt=$mt/$mt2 rb=$rb n=$nbefore/$nafter"; fi

# --- BD-AC-37 (clock jump first: pg_sleep would end early on a jump; the holder is a stdin pipe)
sleep 10
gs 'sed -i "s/^TIMEOUT_SECONDS=.*/TIMEOUT_SECONDS=60/" /usr/local/bin/db-dump.sh'   # what db_dump_timeout=60s renders
nextday
gs '(setsid nohup sh -c "(echo \"BEGIN; LOCK TABLE t IN ACCESS EXCLUSIVE MODE;\"; sleep 400) | podman exec -i fixture-postgres psql -U fixture -d fixture" </dev/null >/tmp/lock.log 2>&1 &)'
sleep 4; T=$(now); s=$(gs 'date +%s')
gs 'systemctl start btrbk.service'; e=$(gs 'date +%s'); rb=$(res btrbk.service); rd=$(res db-dump.service)
jl=$(gs "journalctl -u db-dump.service --since '$T' --no-pager -o cat | grep -i 'stopped after'")
gs 'pkill -f "sleep 400"; true' >/dev/null 2>&1
if [[ $rd == exit-code && $rb == success && $((e - s)) -le 120 && -n $jl ]]; then record "BD-AC-37" PASS "db-dump failed after $((e - s)) s, journal: '$jl', btrbk success"
else record "BD-AC-37" FAIL "rd=$rd rb=$rb dur=$((e - s)) jl='$jl'"; fi
stack >"$OUT/ac37-restore.log" 2>&1
